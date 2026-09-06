# Container that runs qemu-kvm / libvirt / cockpit / firefox under systemd (AlmaLinux 10 minimal)
# Target runtime: podman (root, --privileged). GUI apps show on the host session (WSLg / GNOME Wayland); cockpit only when there is none
# The minimal base ships microdnf instead of dnf (--setopt=install_weak_deps takes 0/1, not False/True)
FROM quay.io/almalinuxorg/10-minimal:10

ENV LANG=ja_JP.UTF-8 \
    LC_ALL=ja_JP.UTF-8 \
    container=podman

RUN microdnf -y install --setopt=install_weak_deps=0 epel-release \
    # Only packages that would not otherwise be pulled in as dependencies are listed. Their deps bring the rest:
    # libvirt-daemon-kvm -> qemu-kvm/qemu-img/edk2-ovmf/swtpm/mesa-*/util-linux..., cockpit -> cockpit-ws/-bridge/-system,
    # cockpit-machines -> virt-install/libvirt-client..., and systemd/polkit/sudo/shadow-utils/procps-ng/iproute/curl/xz
    # come in transitively. shadow-utils (useradd), procps-ng (sysctl), util-linux (setsid/runuser) are all present as deps.
    && microdnf -y install --setopt=install_weak_deps=0 \
        # base (dbus-daemon over the default dbus-broker; passwd for the cockpit password page;
        #  procps-ng for sysctl in kvm-perms.service - it is only a weak dep of the packages below)
        dbus-daemon \
        passwd \
        iputils \
        procps-ng \
        # locale (listed explicitly so both ja and en are present, not just glibc's default langpack)
        glibc-langpack-ja \
        glibc-langpack-en \
        # libvirt + qemu (qemu-kvm/edk2-ovmf/swtpm/libvirt-client/... arrive via libvirt-daemon-kvm and cockpit-machines)
        libvirt \
        libvirt-daemon-kvm \
        # virt tools (virt-install arrives via cockpit-machines)
        virt-viewer \
        # cockpit (cockpit-ws/-bridge/-system arrive via the cockpit metapackage)
        cockpit \
        cockpit-machines \
        cockpit-storaged \
        # browser (pulls in mesa)
        firefox \
        # fonts
        dejavu-sans-fonts \
        google-noto-sans-cjk-vf-fonts \
        # misc (tar for install-desktop icon extraction; not in the minimal base and not pulled by anything)
        tar \
        hostname \
    # virt-manager is not shipped with RHEL 10 derivatives, so take it from EPEL (skip if unavailable)
    && (microdnf -y install --setopt=install_weak_deps=0 virt-manager || echo "virt-manager is not available, skipping") \
    && microdnf clean all && rm -rf /var/cache/dnf

# template user for GUI apps and cockpit login. At boot gui-user.service renames it to the host user and applies the
# host user's uid/gid and password hash (see container/gui-user-setup), so no password is set here
ARG USER=admin
RUN useradd -m -u 1000 ${USER} \
    && usermod -aG wheel ${USER} \
    && usermod -aG libvirt ${USER} \
    && usermod -aG video ${USER} \
    && usermod -aG render ${USER} \
    # passwordless sudo for wheel (cockpit's administrative access); by group so it survives the rename
    && echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel-nopasswd \
    && chmod 0440 /etc/sudoers.d/wheel-nopasswd

# tune libvirt/qemu for running inside a container
RUN sed -i \
        -e 's/^#\?security_driver = .*/security_driver = "none"/' \
        -e 's/^#\?namespaces = .*/namespaces = []/' \
        /etc/libvirt/qemu.conf \
    && sed -i 's/^#\?unix_sock_group = .*/unix_sock_group = "libvirt"/' /etc/libvirt/libvirtd.conf \
    && sed -i 's/^#\?unix_sock_rw_perms = .*/unix_sock_rw_perms = "0770"/' /etc/libvirt/libvirtd.conf

COPY container/kvm-perms.service /etc/systemd/system/
COPY container/gui-user.service /etc/systemd/system/
COPY container/gui-user-setup /usr/local/bin/gui-user-setup
COPY container/gui /usr/local/bin/gui
COPY container/cockpit.conf /etc/cockpit/cockpit.conf
RUN chmod +x \
        /usr/local/bin/gui \
        /usr/local/bin/gui-user-setup \
    && ln -s /dev/null /etc/tmpfiles.d/x11.conf \
    && systemctl enable \
        kvm-perms.service \
        gui-user.service \
        virtqemud.socket \
        virtnetworkd.socket \
        virtstoraged.socket \
        virtnodedevd.socket \
        virtsecretd.socket \
        virtlogd.socket \
        cockpit.socket \
    # AlmaLinux's container base image masks systemd-logind, so unmask it explicitly.
    # A cockpit login creates a logind session via pam_systemd, and pages such as "Services" open the user's
    # session bus (/run/user/<uid>/bus). Without logind that bus cannot be reached, cockpit-bridge crashes
    # and the user is logged out right after logging in.
    # logind also owns the container's /run/user/<uid>: the GUI user lingers (gui-user-setup), so that directory and
    # its session bus exist from boot and survive cockpit logouts. The host's runtime dir is never mounted there
    # (kvm.sh mounts it read-only at /run/host-xdg-runtime), so logind cannot touch the host's sockets
    && systemctl unmask systemd-logind.service \
    && systemctl mask \
        systemd-udevd.service \
        systemd-udevd-kernel.socket \
        systemd-udevd-control.socket \
        systemd-resolved.service \
    # cockpit-issue.service wants network-online.target, which pulls in NetworkManager-wait-online. NetworkManager
    # never reports podman's eth0 as "online", so the unit times out after 60 s: the boot stays "starting" for a minute
    # (gui waits for it before launching the first app) and ends up "degraded" with a failed unit
        NetworkManager-wait-online.service \
    && rm -f /etc/systemd/system/*.wants/systemd-remount-fs.service

EXPOSE 9090
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
