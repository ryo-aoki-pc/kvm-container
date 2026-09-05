# qemu-kvm / libvirt / cockpit / firefox を systemd で動かすコンテナ (AlmaLinux 10)
# 想定ランタイム: podman (root, --privileged)。GUI はホストのセッション (WSLg / GNOME Wayland) に表示、無ければ cockpit のみ
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
    # virt-manager は RHEL10 系に同梱されないため EPEL から (無ければスキップ)
    && (dnf -y install --setopt=install_weak_deps=False virt-manager || echo "virt-manager is not available, skipping") \
    && dnf clean all && rm -rf /var/cache/dnf /var/cache/libdnf5

# GUI/cockpit ログイン用の一般ユーザー (uid=1000: WSLg の runtime-dir 所有者と合わせる)
ARG USER=admin
ARG PASSWORD=admin
RUN useradd -m -u 1000 ${USER} \
    && usermod -aG wheel ${USER} \
    && usermod -aG libvirt ${USER} \
    && usermod -aG video ${USER} \
    && usermod -aG render ${USER} \
    && echo "${USER}:${PASSWORD}" | chpasswd \
    && echo "${USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/${USER} \
    && chmod 0440 /etc/sudoers.d/${USER}

# libvirt/qemu をコンテナ向けに調整
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
    # AlmaLinux のコンテナ用ベースイメージは systemd-logind をマスクしているので明示的に解除する。
    # cockpit のログインは pam_systemd 経由で logind セッションを作り、そのユーザーセッションバス
    # (/run/user/<uid>/bus) を cockpit の「サービス」ページなどが開く。logind が無いとセッションバスに
    # 接続できず、cockpit-bridge がクラッシュしてログイン後に勝手にログアウトされる
    && systemctl unmask systemd-logind.service \
    && systemctl mask \
        systemd-udevd.service \
        systemd-udevd-kernel.socket \
        systemd-udevd-control.socket \
        systemd-resolved.service \
    && rm -f /etc/systemd/system/*.wants/systemd-remount-fs.service

EXPOSE 9090
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
