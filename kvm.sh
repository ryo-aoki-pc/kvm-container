#!/bin/bash
# qemu-kvm/libvirt/cockpit/firefox コンテナ (AlmaLinux 10) を扱うための操作スクリプト
# 対応ホスト: Windows + WSL2 (WSLg) / 物理 AlmaLinux 10 + GNOME (Wayland) / ディスプレイ無し (cockpit のみ)
#   ./kvm.sh build            イメージをビルド
#   ./kvm.sh up               コンテナを起動 (systemd 常駐、cockpit は https://localhost:9090)
#   ./kvm.sh down             コンテナを停止・削除 (VM データは volume に残る)
#   ./kvm.sh firefox          コンテナ内 firefox で cockpit をホスト画面に表示
#   ./kvm.sh virt-manager     virt-manager をホスト画面に表示
#   ./kvm.sh viewer <VM名>    virt-viewer で VM 画面をホスト画面に表示
#   ./kvm.sh demo             デモ VM (Alpine) を作成・起動して画面表示
#   ./kvm.sh virsh ...        コンテナ内で virsh を実行
#   ./kvm.sh shell            コンテナ内の root シェル
#   ./kvm.sh logs             GUI アプリのログ
#   ./kvm.sh clean            コンテナと volume を全部削除
# 環境変数:
#   KVM_HOST=auto|wsl|generic|headless  ホスト種別の自動判定を上書き
#   COCKPIT_BIND=127.0.0.1  COCKPIT_PORT=9090  cockpit の公開アドレス/ポート (他 PC から開くなら 0.0.0.0)
#   KVM_SOFTWARE_GL=1       ソフトウェア描画を強制
#   HOST_UID / HOST_GID     コンテナ内 GUI ユーザーの uid/gid (既定: 実行ユーザー)
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=${IMAGE:-localhost/qemu-kvm-cockpit:latest}
CONTAINER=${CONTAINER:-kvm}   # NAME は WSL がホスト名に使うので避ける
PODMAN=${PODMAN:-"sudo podman"}
KVM_HOST=${KVM_HOST:-auto}
COCKPIT_BIND=${COCKPIT_BIND:-127.0.0.1}
COCKPIT_PORT=${COCKPIT_PORT:-9090}
HOST_UID=${HOST_UID:-$(id -u)}
HOST_GID=${HOST_GID:-$(id -g)}

is_wsl() {
  [ "$KVM_HOST" = wsl ] && return 0
  [ "$KVM_HOST" != auto ] && return 1
  [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

ensure_kvm() {
  if [ ! -e /dev/kvm ]; then
    command -v modprobe >/dev/null || { echo "!! modprobe がありません: sudo dnf install kmod" >&2; exit 1; }
    echo ">> loading kvm module"
    if grep -q AuthenticAMD /proc/cpuinfo; then sudo modprobe kvm_amd; else sudo modprobe kvm_intel; fi
  fi
  if [ ! -e /dev/kvm ]; then
    if is_wsl; then
      echo "!! /dev/kvm がありません。Windows 側 %USERPROFILE%\\.wslconfig に [wsl2] nestedVirtualization=true を設定して wsl --shutdown してください" >&2
    else
      echo "!! /dev/kvm がありません。ファームウェアで SVM (AMD) / VT-x (Intel) を有効にし、sudo modprobe kvm_amd または kvm_intel を確認してください" >&2
    fi
    exit 1
  fi
  sudo chmod 666 /dev/kvm
}

# ホストのセッション (Wayland/X11/PulseAudio) をコンテナに持ち込むための podman 引数を GUI_ARGS に組み立てる
GUI_ARGS=()
gui_args() {
  local rt x11 xauth pulse ppath
  if [ "$KVM_HOST" = headless ] || { [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; }; then
    echo ">> no display found: GUI disabled, use cockpit in a browser"
    return 0
  fi
  rt=${XDG_RUNTIME_DIR:-}
  if [ -z "$rt" ] && is_wsl; then rt=/mnt/wslg/runtime-dir; fi
  if [ ! -d "$rt" ]; then
    echo "!! XDG_RUNTIME_DIR ($rt) がありません。デスクトップセッション内の端末から実行してください" >&2
    exit 1
  fi
  GUI_ARGS+=(-v "$rt:$rt" -e "XDG_RUNTIME_DIR=$rt" -e "HOST_UID=$HOST_UID" -e "HOST_GID=$HOST_GID")
  [ -n "${WAYLAND_DISPLAY:-}" ] && GUI_ARGS+=(-e "WAYLAND_DISPLAY=$WAYLAND_DISPLAY")
  if [ -n "${DISPLAY:-}" ]; then
    x11=$(readlink -f /tmp/.X11-unix 2>/dev/null || true)
    if [ -d "$x11" ]; then
      # :ro にする: コンテナの systemd-tmpfiles がホストの X ソケットを消さないようにする (ソケット接続は ro でも可)
      GUI_ARGS+=(-v "$x11:/tmp/.X11-unix:ro" -e "DISPLAY=$DISPLAY")
      xauth=${XAUTHORITY:-}
      if [ -n "$xauth" ] && [ -r "$xauth" ]; then
        GUI_ARGS+=(-e "XAUTHORITY=$xauth")
        case "$xauth" in "$rt"/*) ;; *) GUI_ARGS+=(-v "$xauth:$xauth:ro") ;; esac
      fi
    fi
  fi
  pulse=${PULSE_SERVER:-}
  if [ -z "$pulse" ] && [ -S "$rt/pulse/native" ]; then pulse="unix:$rt/pulse/native"; fi
  if [ -n "$pulse" ]; then
    GUI_ARGS+=(-e "PULSE_SERVER=$pulse")
    case "$pulse" in
      unix:*) ppath=${pulse#unix:}
              case "$ppath" in "$rt"/*) ;; *) GUI_ARGS+=(-v "$(dirname "$ppath"):$(dirname "$ppath")") ;; esac ;;
    esac
  fi
  if is_wsl || [ ! -d /dev/dri ] || [ "${KVM_SOFTWARE_GL:-0}" = 1 ]; then
    GUI_ARGS+=(-e LIBGL_ALWAYS_SOFTWARE=1)
  fi
}

running() { $PODMAN container exists "$CONTAINER" 2>/dev/null && [ "$($PODMAN inspect -f '{{.State.Running}}' "$CONTAINER")" = true ]; }

cmd=${1:-help}; shift || true
case "$cmd" in
  build)
    $PODMAN build -t "$IMAGE" -f Containerfile "$@" .
    ;;
  up)
    ensure_kvm
    $PODMAN image exists "$IMAGE" || "$0" build
    if running; then echo ">> $CONTAINER is already running"; exit 0; fi
    gui_args
    $PODMAN rm -f "$CONTAINER" >/dev/null 2>&1 || true
    $PODMAN run -d --name "$CONTAINER" --hostname "$CONTAINER" \
      --privileged --systemd=always \
      --device /dev/kvm --device /dev/net/tun \
      -p "$COCKPIT_BIND:$COCKPIT_PORT:9090" \
      -v qemu-kvm-var-libvirt:/var/lib/libvirt \
      -v qemu-kvm-etc-libvirt:/etc/libvirt \
      -v qemu-kvm-home:/home/admin \
      ${GUI_ARGS[@]+"${GUI_ARGS[@]}"} \
      -e "TZ=${TZ:-Asia/Tokyo}" --shm-size 2g \
      "$IMAGE" >/dev/null
    echo ">> waiting for libvirt/cockpit..."
    for i in $(seq 1 30); do
      if $PODMAN exec "$CONTAINER" sh -c 'systemctl is-active -q cockpit.socket 2>/dev/null && virsh -c qemu:///system list >/dev/null 2>&1'; then
        if [ "$COCKPIT_BIND" = 0.0.0.0 ] || [ "$COCKPIT_BIND" = "::" ]; then
          echo ">> ready. cockpit: https://$(uname -n):$COCKPIT_PORT  (user: admin / pass: admin)"
          echo ">> 他 PC から開く場合 (firewalld): sudo firewall-cmd --add-service=cockpit --permanent && sudo firewall-cmd --reload"
        else
          echo ">> ready. cockpit: https://$COCKPIT_BIND:$COCKPIT_PORT  (user: admin / pass: admin)"
        fi
        [ ${#GUI_ARGS[@]} -gt 0 ] && echo ">> host display: ./kvm.sh firefox | ./kvm.sh demo"
        exit 0
      fi
      sleep 1
    done
    echo "!! 起動を確認できませんでした。./kvm.sh shell で systemctl --failed を確認してください" >&2
    exit 1
    ;;
  down)   $PODMAN rm -f -t 10 "$CONTAINER" ;;
  clean)  $PODMAN rm -f -t 10 "$CONTAINER" 2>/dev/null || true
          $PODMAN volume rm -f qemu-kvm-var-libvirt qemu-kvm-etc-libvirt qemu-kvm-home ;;
  firefox|virt-manager)
    running || "$0" up
    $PODMAN exec "$CONTAINER" gui "$cmd" "$@" ;;
  viewer)
    running || "$0" up
    $PODMAN exec "$CONTAINER" gui virt-viewer "$@" ;;
  demo)
    running || "$0" up
    $PODMAN exec -it "$CONTAINER" demo-vm "$@" ;;
  virsh)  $PODMAN exec -it "$CONTAINER" virsh -c qemu:///system "$@" ;;
  shell)  $PODMAN exec -it "$CONTAINER" bash ;;
  logs)   $PODMAN exec "$CONTAINER" sh -c 'tail -n 50 /var/log/gui.log; journalctl --no-pager -n 30 -u virtqemud -u cockpit.socket -u gui-user' ;;
  *)      sed -n '2,20p' "$0" ;;
esac
