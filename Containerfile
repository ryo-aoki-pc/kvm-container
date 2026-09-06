# Container that runs qemu-kvm / libvirt / cockpit / firefox under systemd (AlmaLinux 10)
# Target runtime: podman (root, --privileged). GUI apps show on the host session (WSLg / GNOME Wayland); cockpit only when there is none
FROM quay.io/almalinuxorg/almalinux:10

ENV LANG=ja_JP.UTF-8 \
    LC_ALL=ja_JP.UTF-8 \
    container=podman

RUN dnf -y install --setopt=install_weak_deps=False epel-release \
    && dnf -y install --setopt=install_weak_deps=False \
        # base / systemd
        systemd \
        dbus-daemon \
        polkit \
        passwd \
        sudo \
        shadow-utils \
        procps-ng \
        iproute \
        iputils \
        util-linux \
        # locale
        glibc-langpack-ja \
        glibc-langpack-en \
        # qemu
        qemu-kvm \
        qemu-img \
        swtpm \
        edk2-ovmf \
        # libvirt
        libvirt \
        libvirt-daemon-kvm \
        libvirt-daemon-config-network \
        libvirt-client \
        libvirt-dbus \
        # virt tools
        virt-install \
        virt-viewer \
        # cockpit
        cockpit \
        cockpit-ws \
        cockpit-bridge \
        cockpit-system \
        cockpit-machines \
        cockpit-storaged \
        # browser
        firefox \
        # mesa
        mesa-dri-drivers \
        mesa-libEGL \
        mesa-libGL \
        # fonts
        dejavu-sans-fonts \
        google-noto-sans-cjk-vf-fonts \
        # misc
        curl \
        xz \
    # virt-manager is not shipped with RHEL 10 derivatives, so take it from EPEL (skip if unavailable)
    && (dnf -y install --setopt=install_weak_deps=False virt-manager || echo "virt-manager is not available, skipping") \
    && dnf clean all && rm -rf /var/cache/dnf /var/cache/libdnf5

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
    # and the user is logged out right after logging in
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
