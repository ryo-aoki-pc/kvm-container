# Images for the qemu-kvm/libvirt setup under systemd (AlmaLinux 10 minimal). One multi-stage file, two targets:
#   kvm  (podman build --target kvm)  libvirt + qemu-kvm + virt-install: the server. Runs --privileged --network host as
#                                     container "kvm". The VMs are managed from the command line (kvm.sh virsh / virt-install)
#   gui  (podman build --target gui)  virt-viewer: the desktop client shown on the host session (WSLg / GNOME Wayland).
#                                     Runs unprivileged as container "kvm-gui", only on hosts with a display
# Both reach libvirt through /run/libvirt, a host directory kvm.sh shares between the containers (see the libvirt group below).
# The minimal base ships microdnf instead of dnf (--setopt=install_weak_deps takes 0/1, not False/True)

# ---- base: what both images share --------------------------------------------------------------------------------
FROM quay.io/almalinuxorg/10-minimal:10 AS base

ENV LANG=ja_JP.UTF-8 \
    LC_ALL=ja_JP.UTF-8 \
    container=podman

# The libvirt sockets in the shared /run/libvirt are root:libvirt 0660 (container/kvm/virtd-socket.conf), and the GUI
# container's user reaches them as a member of "libvirt", so the group must have the same gid in both images: create it
# with a fixed gid before any package can allocate one. 985 is in the system range (never a host user's gid, which
# gui-user-setup applies to the template user's own group)
ARG LIBVIRT_GID=985
# shadow-utils (groupadd/useradd/usermod/groupmod) is not in the minimal base either; it is installed first and on its
# own so that the group is created before any package that could allocate a "libvirt" gid of its own
RUN microdnf -y install --setopt=install_weak_deps=0 shadow-utils \
    && groupadd -r -g ${LIBVIRT_GID} libvirt \
    # systemd is not in the minimal base (the images run /sbin/init); dbus-daemon over the default dbus-broker;
    # both locales so that ja and en are present, not just glibc's default langpack
    && microdnf -y install --setopt=install_weak_deps=0 \
        systemd \
        dbus-daemon \
        glibc-langpack-ja \
        glibc-langpack-en \
    && microdnf clean all && rm -rf /var/cache/dnf \
    # units that must not run in either container (masking a unit that a stage never installs is harmless):
    && systemctl mask \
        systemd-udevd.service \
        systemd-udevd-kernel.socket \
        systemd-udevd-control.socket \
        systemd-resolved.service \
    # NetworkManager is not needed by these containers and is masked in case a dependency brings it in (cockpit used to):
    # NetworkManager never reports podman's eth0 as "online", so anything wanting network-online.target waits 60 s for
    # NetworkManager-wait-online and leaves the boot "degraded" with a failed unit (gui waits for the boot before
    # launching the first app) ...
        NetworkManager-wait-online.service \
    # ... and the containers share the host's network namespace (--network host, so that VMs can be bridged onto the
    # host's segment), where NetworkManager would start managing the host's interfaces and bridges
        NetworkManager.service \
    # iscsi-initiator-utils comes in via libvirt's iSCSI storage driver. Its sockets listen in the ABSTRACT unix
    # namespace, which belongs to the network namespace: with --network host they collide with the host's iscsid
    # ("Address already in use") and leave the boot "degraded". iSCSI is not used by these containers
        iscsid.socket \
        iscsiuio.socket \
    && rm -f /etc/systemd/system/*.wants/systemd-remount-fs.service

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

# ---- common: the mirrored host user (both images) -----------------------------------------------------------------
FROM base AS common

# The images ship no unprivileged user of their own: gui-user.service creates the GUI user at boot from the host user's
# name, uid/gid and groups (see container/common/gui-user-setup), so nothing about the host has to be known at build time
COPY container/common/gui-user.service /etc/systemd/system/
COPY container/common/gui-user-setup /usr/local/bin/gui-user-setup
RUN chmod +x /usr/local/bin/gui-user-setup \
    && systemctl enable gui-user.service \
    # AlmaLinux's container base image masks systemd-logind, so unmask it explicitly: logind owns the container's
    # /run/user/<uid> and starts the GUI user's systemd --user instance at boot (the user lingers, see gui-user-setup),
    # which provides the session bus the GTK apps expect. The host's runtime dir is never mounted there
    # (kvm.sh mounts it read-only at /run/host-xdg-runtime), so logind cannot touch the host's sockets
    && systemctl unmask systemd-logind.service

# ---- kvm: libvirt + qemu-kvm + virt-install ------------------------------------------------------------------------
FROM common AS kvm

RUN microdnf -y install --setopt=install_weak_deps=0 \
    # Only packages that would not otherwise be pulled in as dependencies are listed. Their deps bring the rest:
    # libvirt-daemon-kvm -> qemu-kvm/qemu-img/edk2-ovmf/swtpm/util-linux..., libvirt -> libvirt-client (virsh)/polkit/
    # dnsmasq/iproute (ip in kvm-net-teardown.service)...
        # procps-ng for sysctl in kvm-perms.service (only a weak dep otherwise)
        iputils \
        procps-ng \
        # libvirt + qemu
        libvirt \
        libvirt-daemon-kvm \
        # VM creation from the command line (kvm.sh virt-install)
        virt-install \
    && microdnf clean all && rm -rf /var/cache/dnf

COPY container/kvm/kvm-perms.service /etc/systemd/system/
COPY container/kvm/kvm-net-teardown.service /etc/systemd/system/
COPY container/kvm/kvm-libvirt-conf.service /etc/systemd/system/
COPY container/kvm/libvirt-conf /usr/local/bin/libvirt-conf
COPY container/kvm/virtd-socket.conf /usr/local/share/kvm-container/virtd-socket.conf
# shut the running VMs down when the container stops (see the file); /etc/sysconfig is part of the image, not of data/
COPY container/kvm/libvirt-guests /etc/sysconfig/libvirt-guests
RUN chmod +x /usr/local/bin/libvirt-conf \
    # socket permissions of the client-facing libvirt daemons (root:libvirt 0660 instead of 0666 + polkit)
    && for d in virtqemud virtnetworkd virtstoraged virtnodedevd virtsecretd; do \
         install -D -m 0644 /usr/local/share/kvm-container/virtd-socket.conf "/etc/systemd/system/$d.socket.d/kvm-container.conf"; \
       done \
    && systemctl enable \
        kvm-perms.service \
        kvm-net-teardown.service \
        kvm-libvirt-conf.service \
        libvirt-guests.service \
        virtqemud.socket \
        virtnetworkd.socket \
        virtstoraged.socket \
        virtnodedevd.socket \
        virtsecretd.socket \
        virtlogd.socket

# ---- gui: virt-viewer on the host display ---------------------------------------------------------------------------
FROM common AS gui

RUN microdnf -y install --setopt=install_weak_deps=0 \
        # the VM console (pulls in gtk3 / gtk-vnc); libvirt-client for virsh (diagnostics through the shared socket).
        # No libvirt daemons in this image
        virt-viewer \
        libvirt-client \
        # runuser/setsid for container/gui/gui (weak dep of systemd only)
        util-linux-core \
        # fonts
        dejavu-sans-fonts \
        google-noto-sans-cjk-vf-fonts \
        # tar for install-desktop icon extraction; not in the minimal base and not pulled by anything
        tar \
    && microdnf clean all && rm -rf /var/cache/dnf \
    # GPU access for the GUI user (/dev/dri comes in with --device; the render nodes are also made 0666 by gui).
    # gui-user-setup puts the user it creates into these groups, so they only have to exist here
    && for g in video render; do getent group "$g" >/dev/null || groupadd -r "$g"; done

COPY container/gui/gui /usr/local/bin/gui
RUN chmod +x /usr/local/bin/gui \
    # /tmp/.X11-unix is the host's, mounted read-only; keep systemd-tmpfiles from trying to clean it
    && ln -s /dev/null /etc/tmpfiles.d/x11.conf
