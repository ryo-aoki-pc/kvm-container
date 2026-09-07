# Images for the qemu-kvm/libvirt/cockpit setup under systemd (AlmaLinux 10 minimal). One multi-stage file, two targets:
#   kvm  (podman build --target kvm)  libvirt + qemu-kvm + cockpit: the server. Runs --privileged --network host as container "kvm"
#   gui  (podman build --target gui)  firefox / virt-manager / virt-viewer: the desktop client shown on the host session (WSLg /
#                                     GNOME Wayland). Runs unprivileged as container "kvm-gui", only on hosts with a display
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
RUN groupadd -r -g ${LIBVIRT_GID} libvirt \
    # systemd is not in the minimal base (the images run /sbin/init); dbus-daemon over the default dbus-broker;
    # hostname for cockpit; both locales so that ja and en are present, not just glibc's default langpack
    && microdnf -y install --setopt=install_weak_deps=0 \
        systemd \
        dbus-daemon \
        hostname \
        glibc-langpack-ja \
        glibc-langpack-en \
    && microdnf clean all && rm -rf /var/cache/dnf \
    # units that must not run in either container (masking a unit that a stage never installs is harmless):
    && systemctl mask \
        systemd-udevd.service \
        systemd-udevd-kernel.socket \
        systemd-udevd-control.socket \
        systemd-resolved.service \
    # cockpit-issue.service wants network-online.target, which pulls in NetworkManager-wait-online. NetworkManager
    # never reports podman's eth0 as "online", so the unit times out after 60 s: the boot stays "starting" for a minute
    # (gui waits for it before launching the first app) and ends up "degraded" with a failed unit
        NetworkManager-wait-online.service \
    # the containers share the host's network namespace (--network host, so that VMs can be bridged onto the host's
    # segment); NetworkManager would otherwise start managing the host's interfaces and bridges
        NetworkManager.service \
    # iscsi-initiator-utils comes in via cockpit-storaged / libvirt's iSCSI storage driver. Its sockets listen in the
    # ABSTRACT unix namespace, which belongs to the network namespace: with --network host they collide with the host's
    # iscsid ("Address already in use") and leave the boot "degraded". iSCSI is not used by these containers
        iscsid.socket \
        iscsiuio.socket \
    && rm -f /etc/systemd/system/*.wants/systemd-remount-fs.service

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

# ---- common: the mirrored host user (both images) -----------------------------------------------------------------
FROM base AS common

# template user "admin" (the name gui-user-setup expects) for GUI apps and cockpit login. At boot gui-user.service
# renames it to the host user and applies the host user's uid/gid (and, in the kvm image, the password hash; see
# container/common/gui-user-setup), so no password is set here. libvirt: access to the libvirt sockets (see the base stage)
RUN microdnf -y install --setopt=install_weak_deps=0 shadow-utils \
    && microdnf clean all && rm -rf /var/cache/dnf \
    && useradd -m -u 1000 admin \
    && usermod -aG wheel admin \
    && usermod -aG libvirt admin

COPY container/common/gui-user.service /etc/systemd/system/
COPY container/common/gui-user-setup /usr/local/bin/gui-user-setup
RUN chmod +x /usr/local/bin/gui-user-setup \
    && systemctl enable gui-user.service \
    # AlmaLinux's container base image masks systemd-logind, so unmask it explicitly.
    # A cockpit login creates a logind session via pam_systemd, and pages such as "Services" open the user's
    # session bus (/run/user/<uid>/bus). Without logind that bus cannot be reached, cockpit-bridge crashes
    # and the user is logged out right after logging in.
    # logind also owns the container's /run/user/<uid>: the GUI user lingers (gui-user-setup), so that directory and
    # its session bus exist from boot and survive cockpit logouts. The host's runtime dir is never mounted there
    # (kvm.sh mounts it read-only at /run/host-xdg-runtime), so logind cannot touch the host's sockets
    && systemctl unmask systemd-logind.service

# ---- kvm: libvirt + qemu-kvm + cockpit -----------------------------------------------------------------------------
FROM common AS kvm

RUN microdnf -y install --setopt=install_weak_deps=0 \
    # Only packages that would not otherwise be pulled in as dependencies are listed. Their deps bring the rest:
    # libvirt-daemon-kvm -> qemu-kvm/qemu-img/edk2-ovmf/swtpm/util-linux..., cockpit -> cockpit-ws/-bridge/-system,
    # cockpit-machines -> libvirt-dbus/libvirt-client/qemu-kvm..., and polkit/sudo/iproute/curl/xz come in transitively.
        # passwd for the cockpit password page; procps-ng for sysctl in kvm-perms.service (only a weak dep otherwise)
        passwd \
        iputils \
        procps-ng \
        # libvirt + qemu
        libvirt \
        libvirt-daemon-kvm \
        # virt-install (also a dep of cockpit-machines; listed so that "podman exec kvm virt-install" stays available)
        virt-install \
        # cockpit (cockpit-ws/-bridge/-system arrive via the cockpit metapackage)
        cockpit \
        cockpit-machines \
        cockpit-storaged \
    && microdnf clean all && rm -rf /var/cache/dnf \
    # passwordless sudo for wheel (cockpit's administrative access); by group so it survives the rename
    && echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel-nopasswd \
    && chmod 0440 /etc/sudoers.d/wheel-nopasswd \
    # cockpit-machines talks to libvirt through libvirt-dbus, which runs as "libvirtdbus". It is normally let in by a
    # polkit rule, but the sockets use group permissions instead of polkit here (see the base stage and
    # container/kvm/virtd-socket.conf), so the user needs the libvirt group
    && usermod -aG libvirt libvirtdbus

COPY container/kvm/kvm-perms.service /etc/systemd/system/
COPY container/kvm/kvm-net-teardown.service /etc/systemd/system/
COPY container/kvm/kvm-libvirt-conf.service /etc/systemd/system/
COPY container/kvm/libvirt-conf /usr/local/bin/libvirt-conf
COPY container/kvm/virtd-socket.conf /usr/local/share/kvm-container/virtd-socket.conf
COPY container/kvm/cockpit.conf /etc/cockpit/cockpit.conf
COPY container/kvm/cockpit-listen-generator /usr/lib/systemd/system-generators/cockpit-listen
RUN chmod +x \
        /usr/local/bin/libvirt-conf \
        /usr/lib/systemd/system-generators/cockpit-listen \
    # socket permissions of the client-facing libvirt daemons (root:libvirt 0660 instead of 0666 + polkit)
    && for d in virtqemud virtnetworkd virtstoraged virtnodedevd virtsecretd; do \
         install -D -m 0644 /usr/local/share/kvm-container/virtd-socket.conf "/etc/systemd/system/$d.socket.d/kvm-container.conf"; \
       done \
    && systemctl enable \
        kvm-perms.service \
        kvm-net-teardown.service \
        kvm-libvirt-conf.service \
        virtqemud.socket \
        virtnetworkd.socket \
        virtstoraged.socket \
        virtnodedevd.socket \
        virtsecretd.socket \
        virtlogd.socket \
        cockpit.socket

EXPOSE 9091

# ---- gui: firefox / virt-manager / virt-viewer on the host display --------------------------------------------------
FROM common AS gui

RUN microdnf -y install --setopt=install_weak_deps=0 epel-release \
    && microdnf -y install --setopt=install_weak_deps=0 \
        # browser (pulls in mesa)
        firefox \
        # virt tools; libvirt-client for virsh (diagnostics through the shared socket). No libvirt daemons in this image
        virt-viewer \
        libvirt-client \
        # runuser/setsid for container/gui/gui (weak dep of systemd only)
        util-linux-core \
        # fonts
        dejavu-sans-fonts \
        google-noto-sans-cjk-vf-fonts \
        # tar for install-desktop icon extraction; not in the minimal base and not pulled by anything
        tar \
    # virt-manager is not shipped with RHEL 10 derivatives, so take it from EPEL (skip if unavailable)
    && (microdnf -y install --setopt=install_weak_deps=0 virt-manager || echo "virt-manager is not available, skipping") \
    && microdnf clean all && rm -rf /var/cache/dnf \
    # GPU access for the GUI user (/dev/dri comes in with --device; the render nodes are also made 0666 by gui)
    && for g in video render; do getent group "$g" >/dev/null || groupadd -r "$g"; done \
    && usermod -aG video,render admin

COPY container/gui/gui /usr/local/bin/gui
RUN chmod +x /usr/local/bin/gui \
    # /tmp/.X11-unix is the host's, mounted read-only; keep systemd-tmpfiles from trying to clean it
    && ln -s /dev/null /etc/tmpfiles.d/x11.conf
