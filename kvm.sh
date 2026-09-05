#!/bin/bash
# qemu-kvm/libvirt/cockpit/firefox コンテナ (AlmaLinux 10) を扱うための操作スクリプト
# 対応ホスト: Windows + WSL2 (WSLg) / 物理 AlmaLinux 10 + GNOME (Wayland) / ディスプレイ無し (cockpit のみ)
#   ./kvm.sh build            イメージをビルド
#   ./kvm.sh up               コンテナを起動 (systemd 常駐、cockpit は https://localhost:9090)
#   ./kvm.sh down             コンテナを停止・削除 (VM データはホストの KVM_DATA_DIR に残る)
#   ./kvm.sh firefox          コンテナ内 firefox で cockpit をホスト画面に表示
#   ./kvm.sh virt-manager     virt-manager をホスト画面に表示
#   ./kvm.sh viewer <VM名>    virt-viewer で VM 画面をホスト画面に表示
#   ./kvm.sh virsh ...        コンテナ内で virsh を実行
#   ./kvm.sh shell            コンテナ内の root シェル
#   ./kvm.sh logs             GUI アプリのログ
#   ./kvm.sh clean            コンテナと KVM_DATA_DIR のデータを全部削除 (確認あり)
#   ./kvm.sh install-service  root の Quadlet (/etc/containers/systemd/kvm-container.container) として登録
#                             (GNOME ログイン後に sudo systemctl start kvm-container で起動する用)
#   ./kvm.sh uninstall-service  上記サービスの登録解除
#   ./kvm.sh prepare          up の前処理だけ行う (kvm モジュール、イメージ、データディレクトリ)。Quadlet の ExecStartPre 用
#   ./kvm.sh install-desktop  アクティビティ (アプリ一覧) から起動する .desktop / アイコン / sudoers ルールを配置
#   ./kvm.sh uninstall-desktop  上記を削除
#   ./kvm.sh launch <app>     .desktop 用 (firefox|virt-manager)。sudo -n で起動し、失敗はデスクトップ通知で知らせる
# 環境変数:
#   KVM_HOST=auto|wsl|generic|headless  ホスト種別の自動判定を上書き
#   COCKPIT_BIND=127.0.0.1  COCKPIT_PORT=9090  cockpit の公開アドレス/ポート (他 PC から開くなら 0.0.0.0)
#   KVM_SOFTWARE_GL=1       ソフトウェア描画を強制
#   HOST_UID / HOST_GID     コンテナ内 GUI ユーザーの uid/gid (既定: 実行ユーザー)
#   KVM_DATA_DIR=./data     永続化用のホストディレクトリ (var-libvirt / etc-libvirt / home をバインドマウント)
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=${IMAGE:-localhost/qemu-kvm-cockpit:latest}
CONTAINER=${CONTAINER:-kvm}   # NAME は WSL がホスト名に使うので避ける
# root で実行されたとき (Quadlet の ExecStartPre など) は sudo を挟まない
if [ "$(id -u)" = 0 ]; then SUDO=; PODMAN=${PODMAN:-podman}; else SUDO=sudo; PODMAN=${PODMAN:-"sudo podman"}; fi
KVM_HOST=${KVM_HOST:-auto}
COCKPIT_BIND=${COCKPIT_BIND:-127.0.0.1}
COCKPIT_PORT=${COCKPIT_PORT:-9090}
HOST_UID=${HOST_UID:-$(id -u)}
HOST_GID=${HOST_GID:-$(id -g)}
KVM_DATA_DIR=${KVM_DATA_DIR:-$PWD/data}
case "$KVM_DATA_DIR" in /*) ;; *) KVM_DATA_DIR=$PWD/$KVM_DATA_DIR ;; esac   # 相対パスだと podman が named volume と解釈する
QUADLET_FILE=/etc/containers/systemd/kvm-container.container   # install-service が配置する Quadlet (→ kvm-container.service)
QUADLET_TEMPLATE=$PWD/quadlet/kvm-container.container          # そのテンプレート (@...@ と # @GUI@ / # @UNIT_DEPS@ を置き換える)
QUADLET_DEPS=$PWD/quadlet/user-runtime-dir.conf                # # @UNIT_DEPS@ に入れる行 (GUI ありのとき)
SUDOERS_FILE=/etc/sudoers.d/kvm-container                     # install-desktop が置く NOPASSWD ルール (launch 用)
DESKTOP_TEMPLATE_DIR=$PWD/desktop                              # kvm-*.desktop / sudoers のテンプレート
DESKTOP_APPS="virt-manager firefox"                            # .desktop を作るアプリ (container/gui のサブコマンド名)
PODMAN_BIN=$(command -v podman || true)                        # sudoers に書く絶対パス。launch の sudo -n でも同じパスを使い完全一致させる

is_wsl() {
  [ "$KVM_HOST" = wsl ] && return 0
  [ "$KVM_HOST" != auto ] && return 1
  [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

ensure_kvm() {
  if [ ! -e /dev/kvm ]; then
    command -v modprobe >/dev/null || { echo "!! modprobe がありません: sudo dnf install kmod" >&2; exit 1; }
    echo ">> loading kvm module"
    if grep -q AuthenticAMD /proc/cpuinfo; then $SUDO modprobe kvm_amd; else $SUDO modprobe kvm_intel; fi
  fi
  if [ ! -e /dev/kvm ]; then
    if is_wsl; then
      echo "!! /dev/kvm がありません。Windows 側 %USERPROFILE%\\.wslconfig に [wsl2] nestedVirtualization=true を設定して wsl --shutdown してください" >&2
    else
      echo "!! /dev/kvm がありません。ファームウェアで SVM (AMD) / VT-x (Intel) を有効にし、sudo modprobe kvm_amd または kvm_intel を確認してください" >&2
    fi
    exit 1
  fi
  $SUDO chmod 666 /dev/kvm
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

# .desktop / アイコンの配置先 (ログインユーザーの領域)。root で動く prepare (Quadlet) では使わないので必要なときだけ設定する
desktop_dirs() {
  DESKTOP_DIR=${XDG_DATA_HOME:-${HOME:?}/.local/share}/applications
  ICON_DIR=${XDG_DATA_HOME:-${HOME:?}/.local/share}/icons
}

# launch (.desktop からの起動) の失敗をデスクトップ通知で知らせる。通知手段が無ければ stderr のみ
launch_error() {
  echo "!! $*" >&2
  if command -v notify-send >/dev/null 2>&1; then notify-send -a kvm.sh -i dialog-error "kvm-container" "$*" 2>/dev/null || true
  elif command -v zenity >/dev/null 2>&1; then zenity --error --title=kvm-container --text="$*" 2>/dev/null || true
  fi
}

# 永続化用ホストディレクトリを用意する。空ならイメージ内の初期内容 (設定ファイル、ディレクトリ構成、所有者) をコピーする
# (バインドマウントは named volume と違い、初回にイメージ側の内容をコピーしてくれない)
prepare_data_dir() {
  local dir=$1 src=$2
  $SUDO mkdir -p "$dir"
  if [ -n "$($SUDO ls -A "$dir")" ]; then return 0; fi
  echo ">> seeding $dir from image $src"
  # コンテナ内で cp する (podman cp だと VOLUME 宣言のあるパスは空の匿名 volume が見えてしまう)
  $PODMAN run --rm --network none -v "$dir:/mnt/seed" "$IMAGE" cp -a "$src/." /mnt/seed/
}

# up の前処理 (Quadlet の ExecStartPre からも呼ぶ)
prepare_all() {
  ensure_kvm
  $PODMAN image exists "$IMAGE" || "$0" build
  prepare_data_dir "$KVM_DATA_DIR/var-libvirt" /var/lib/libvirt
  prepare_data_dir "$KVM_DATA_DIR/etc-libvirt" /etc/libvirt
  prepare_data_dir "$KVM_DATA_DIR/home" /home/admin
}

cmd=${1:-help}; shift || true
case "$cmd" in
  build)
    $PODMAN build -t "$IMAGE" -f Containerfile "$@" .
    ;;
  prepare) prepare_all ;;
  up)
    if [ -e "$QUADLET_FILE" ]; then
      echo "!! $QUADLET_FILE が登録されています。sudo systemctl start kvm-container で起動してください (解除は ./kvm.sh uninstall-service)" >&2
      exit 1
    fi
    prepare_all
    if running; then echo ">> $CONTAINER is already running"; exit 0; fi
    gui_args
    $PODMAN rm -f "$CONTAINER" >/dev/null 2>&1 || true
    $PODMAN run -d --name "$CONTAINER" --hostname "$CONTAINER" \
      --privileged --systemd=always \
      --device /dev/kvm --device /dev/net/tun \
      -p "$COCKPIT_BIND:$COCKPIT_PORT:9090" \
      -v "$KVM_DATA_DIR/var-libvirt:/var/lib/libvirt" \
      -v "$KVM_DATA_DIR/etc-libvirt:/etc/libvirt" \
      -v "$KVM_DATA_DIR/home:/home/admin" \
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
        [ ${#GUI_ARGS[@]} -gt 0 ] && echo ">> host display: ./kvm.sh firefox | ./kvm.sh virt-manager"
        exit 0
      fi
      sleep 1
    done
    echo "!! 起動を確認できませんでした。./kvm.sh shell で systemctl --failed を確認してください" >&2
    exit 1
    ;;
  down)   $PODMAN rm -f -t 10 "$CONTAINER" ;;
  clean)  $PODMAN rm -f -t 10 "$CONTAINER" 2>/dev/null || true
          [ -d "$KVM_DATA_DIR" ] || { echo ">> $KVM_DATA_DIR はありません"; exit 0; }
          echo ">> 削除対象: $KVM_DATA_DIR"; $SUDO du -sh "$KVM_DATA_DIR"/* 2>/dev/null || true
          if [ "${KVM_CLEAN_YES:-0}" != 1 ]; then
            read -r -p "VM のディスク/定義ごと削除します。よろしいですか? [y/N] " ans
            [ "$ans" = y ] || [ "$ans" = Y ] || { echo ">> 中止しました"; exit 1; }
          fi
          $SUDO rm -rf "$KVM_DATA_DIR" ;;
  firefox|virt-manager)
    running || "$0" up
    $PODMAN exec "$CONTAINER" gui "$cmd" "$@" ;;
  viewer)
    running || "$0" up
    $PODMAN exec "$CONTAINER" gui virt-viewer "$@" ;;
  virsh)  $PODMAN exec -it "$CONTAINER" virsh -c qemu:///system "$@" ;;
  shell)  $PODMAN exec -it "$CONTAINER" bash ;;
  logs)   $PODMAN exec "$CONTAINER" sh -c 'tail -n 50 /var/log/gui.log; journalctl --no-pager -n 30 -u virtqemud -u cockpit.socket -u gui-user' ;;
  install-service)
    # root の Quadlet (.container) として登録する。GNOME (Wayland) のセッション環境はユーザーとデスクトップが決まれば
    # 固定値 (/run/user/<uid>, wayland-0, :0, pulse/native) なので、今のセッションから読み取って .container に埋める。
    # 唯一セッションごとに変わる XAUTHORITY は埋めず、コンテナ内の gui が実行時に探す。
    [ "$(id -u)" != 0 ] || { echo "!! sudo を付けず、GNOME にログインしたユーザーとして実行してください (セッション環境を読み取ります)" >&2; exit 1; }
    [ -r "$QUADLET_TEMPLATE" ] && [ -r "$QUADLET_DEPS" ] || { echo "!! テンプレート $QUADLET_TEMPLATE / $QUADLET_DEPS がありません" >&2; exit 1; }
    gui_args
    uid=$(id -u)
    tmp=$(mktemp); tmp_gui=$(mktemp); tmp_deps=$(mktemp)
    trap 'rm -f "$tmp" "$tmp_gui" "$tmp_deps"' EXIT
    # gui_args の -v / -e をそのまま Quadlet の Volume= / Environment= にする
    i=0
    while [ $i -lt ${#GUI_ARGS[@]} ]; do
      opt=${GUI_ARGS[$i]}; val=${GUI_ARGS[$((i+1))]}
      case "$opt:$val" in
        -e:XAUTHORITY=*) ;;                                 # セッションごとに変わる → コンテナ内 gui が実行時に探す
        -v:"${XAUTHORITY:-/nonexistent}:"*) ;;
        -e:*) echo "Environment=$val" >>"$tmp_gui" ;;
        -v:*) echo "Volume=$val" >>"$tmp_gui" ;;
      esac
      i=$((i+2))
    done
    # /run/user/<uid> (tmpfs) はログイン時に logind が作る。先にできていればログイン後に作られるソケットもコンテナから見える
    if grep -q "^Volume=/run/user/$uid:" "$tmp_gui"; then
      sed "s|@UID@|$uid|g" "$QUADLET_DEPS" >"$tmp_deps"
    fi
    sed -e "s|@CONTAINER@|$CONTAINER|g" -e "s|@IMAGE@|$IMAGE|g" \
        -e "s|@COCKPIT_BIND@|$COCKPIT_BIND|g" -e "s|@COCKPIT_PORT@|$COCKPIT_PORT|g" \
        -e "s|@KVM_DATA_DIR@|$KVM_DATA_DIR|g" -e "s|@TZ@|${TZ:-Asia/Tokyo}|g" -e "s|@KVM_SH@|$PWD/kvm.sh|g" \
        -e "/^# @UNIT_DEPS@\$/{r $tmp_deps" -e 'd' -e '}' \
        -e "/^# @GUI@\$/{r $tmp_gui" -e 'd' -e '}' \
        "$QUADLET_TEMPLATE" >"$tmp"
    if grep -q '@[A-Z_]*@' "$tmp"; then echo "!! テンプレートに未置換のプレースホルダがあります: $(grep -o '@[A-Z_]*@' "$tmp" | sort -u | tr '\n' ' ')" >&2; exit 1; fi
    sudo install -m 0644 -o root -g root -D "$tmp" "$QUADLET_FILE"
    sudo systemctl daemon-reload
    if ! sudo systemctl cat kvm-container.service >/dev/null 2>&1; then
      echo "!! Quadlet が kvm-container.service を生成できませんでした (podman 4.4 以降が必要)。" >&2
      echo "   sudo /usr/lib/systemd/system-generators/podman-system-generator --dryrun でエラーを確認してください" >&2
      exit 1
    fi
    echo ">> installed: $QUADLET_FILE"
    [ -s "$tmp_gui" ] || echo ">> (GUI 無し: セッション環境が無いので cockpit のみ。GNOME にログインした端末から実行すると GUI 付きになります)"
    echo ">> start:     sudo systemctl start kvm-container     (stop / status / restart も同様)"
    echo ">> logs:      journalctl -u kvm-container"
    echo ">> note:      GNOME からログアウト/再ログインしたら sudo systemctl restart kvm-container"
    ;;
  uninstall-service)
    $SUDO systemctl stop kvm-container.service 2>/dev/null || true
    $SUDO rm -f "$QUADLET_FILE"
    $SUDO systemctl daemon-reload
    echo ">> removed: $QUADLET_FILE"
    ;;
  launch)
    # .desktop (アクティビティ) 用。端末が無く sudo のパスワードを聞けないので、install-desktop が置いた sudoers の
    # NOPASSWD ルールと完全一致する固定コマンド (podman exec <container> gui <app>) だけを sudo -n で実行する
    app=${1:-}
    case "$app" in firefox|virt-manager) ;; *) echo "usage: $0 launch firefox|virt-manager" >&2; exit 1 ;; esac
    [ -n "$PODMAN_BIN" ] || { launch_error "podman がありません (sudo dnf install podman)"; exit 1; }
    if [ -e "$QUADLET_FILE" ] && ! systemctl -q is-active kvm-container.service 2>/dev/null; then
      # Quadlet 登録済みで未起動なら polkit 経由で起動する (GNOME ならパスワードダイアログが出る。ログイン後 1 回)
      systemctl start kvm-container.service \
        || { launch_error "kvm-container サービスを起動できませんでした。端末で sudo systemctl start kvm-container を実行してください"; exit 1; }
    fi
    if ! err=$(sudo -n "$PODMAN_BIN" exec "$CONTAINER" gui "$app" 2>&1); then
      case "$err" in
        *password*) hint="./kvm.sh install-desktop を実行してください (sudoers の NOPASSWD ルールがありません)" ;;
        *)          hint="コンテナが起動しているか確認してください (./kvm.sh up または sudo systemctl start kvm-container)" ;;
      esac
      launch_error "$app を起動できませんでした: $err"$'\n'"$hint"
      exit 1
    fi
    ;;
  install-desktop)
    # アクティビティ (アプリ一覧) から起動できるようにする: .desktop、アイコン、sudoers の NOPASSWD ルールを配置
    [ "$(id -u)" != 0 ] || { echo "!! sudo を付けず、デスクトップにログインしたユーザーとして実行してください" >&2; exit 1; }
    [ -n "$PODMAN_BIN" ] || { echo "!! podman がありません" >&2; exit 1; }
    desktop_dirs
    $PODMAN image exists "$IMAGE" || "$0" build
    # 1) sudoers: launch が使う固定コマンドだけを NOPASSWD にする。'.' を含む名前は sudo が読まないので
    #    いったん .tmp に置き、visudo で構文を確認してから本来の名前にする
    tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
    sed -e "s|@USER@|$(id -un)|g" -e "s|@PODMAN@|$PODMAN_BIN|g" -e "s|@CONTAINER@|$CONTAINER|g" "$DESKTOP_TEMPLATE_DIR/sudoers" >"$tmp"
    if grep -q '@[A-Z_]*@' "$tmp"; then echo "!! テンプレートに未置換のプレースホルダがあります: $(grep -o '@[A-Z_]*@' "$tmp" | sort -u | tr '\n' ' ')" >&2; exit 1; fi
    sudo install -m 0440 -o root -g root -D "$tmp" "$SUDOERS_FILE.tmp"
    sudo visudo -cf "$SUDOERS_FILE.tmp" >/dev/null || { sudo rm -f "$SUDOERS_FILE.tmp"; echo "!! sudoers の構文エラー" >&2; exit 1; }
    sudo mv -f "$SUDOERS_FILE.tmp" "$SUDOERS_FILE"
    # 2) アイコン: イメージ内の hicolor から virt-manager / firefox のものだけ取り出す (取り出せなくても汎用アイコンで表示される)
    mkdir -p "$ICON_DIR" "$DESKTOP_DIR"
    (set +o pipefail
     $PODMAN run --rm --network none "$IMAGE" sh -c \
       'cd /usr/share/icons && find hicolor -type f \( -path "*/apps/virt-manager.*" -o -path "*/apps/firefox.*" \) | tar -cf - -T -' \
       | tar -xf - -C "$ICON_DIR") 2>/dev/null || true
    # 3) .desktop (virt-manager がイメージに無い (EPEL 未提供) ときはそのエントリをスキップ)
    for app in $DESKTOP_APPS; do
      if [ "$app" = virt-manager ] && ! $PODMAN run --rm --network none "$IMAGE" test -x /usr/bin/virt-manager; then
        echo ">> イメージに virt-manager がありません。kvm-virt-manager.desktop はスキップします"; continue
      fi
      sed "s|@KVM_SH@|$PWD/kvm.sh|g" "$DESKTOP_TEMPLATE_DIR/kvm-$app.desktop" >"$DESKTOP_DIR/kvm-$app.desktop"
      ls "$ICON_DIR"/hicolor/*/apps/"$app".* >/dev/null 2>&1 || echo ">> ($app のアイコンを取り出せませんでした。汎用アイコンで表示されます)"
    done
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$DESKTOP_DIR" || true
    echo ">> installed: $DESKTOP_DIR/kvm-*.desktop, $ICON_DIR/hicolor/*/apps/, $SUDOERS_FILE"
    echo ">> アクティビティで「仮想マシンマネージャー」「Firefox」を検索して起動できます (コンテナは起動しておいてください。"
    echo ">>  install-service 済みなら未起動時に systemctl start を試み、polkit のパスワードダイアログが出ます)"
    ;;
  uninstall-desktop)
    [ "$(id -u)" != 0 ] || { echo "!! sudo を付けず、install-desktop したユーザーとして実行してください" >&2; exit 1; }
    desktop_dirs
    for app in $DESKTOP_APPS; do rm -f "$DESKTOP_DIR/kvm-$app.desktop" "$ICON_DIR"/hicolor/*/apps/"$app".*; done
    sudo rm -f "$SUDOERS_FILE"
    echo ">> removed: $DESKTOP_DIR/kvm-*.desktop, $ICON_DIR/hicolor/*/apps/{virt-manager,firefox}.*, $SUDOERS_FILE"
    ;;
  *)      sed -n '2,26p' "$0" ;;
esac
