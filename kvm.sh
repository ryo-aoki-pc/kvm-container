#!/bin/bash
# Helper script for the qemu-kvm/libvirt/cockpit/firefox container (AlmaLinux 10)
# Supported hosts: Windows + WSL2 (WSLg) / physical AlmaLinux 10 + GNOME (Wayland) / headless (cockpit only)
#   ./kvm.sh build            build the image
#   ./kvm.sh up               start the container (systemd inside; cockpit at https://localhost:9090, log in with your host user)
#   ./kvm.sh down             stop and remove the container (VM data stays in data/ under the repository)
#   ./kvm.sh firefox          open cockpit in the container's firefox on the host display
#   ./kvm.sh virt-manager     show virt-manager on the host display
#   ./kvm.sh viewer <VM>      show a VM's screen with virt-viewer on the host display
#   ./kvm.sh virsh ...        run virsh inside the container
#   ./kvm.sh shell            root shell inside the container
#   ./kvm.sh logs             GUI application logs
#   ./kvm.sh clean            remove the container and everything under data/ (asks for confirmation)
#   ./kvm.sh install-desktop  install .desktop entries and icons to launch from the Activities overview
#   ./kvm.sh uninstall-desktop  remove the above
#   ./kvm.sh launch <app>     used by the .desktop entries (firefox|virt-manager): runs via sudo -n, reports failures as desktop notifications
# Environment variables:
#   KVM_HOST=auto|wsl|generic|headless  override host type detection
#   COCKPIT_BIND=127.0.0.1  COCKPIT_PORT=9090  cockpit bind address/port (use 0.0.0.0 to reach it from other PCs)
#   KVM_SOFTWARE_GL=1       force software rendering
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=localhost/qemu-kvm-cockpit:latest
CONTAINER=kvm                 # not NAME: WSL uses NAME for the hostname
PODMAN="sudo podman"
KVM_HOST=${KVM_HOST:-auto}
COCKPIT_BIND=${COCKPIT_BIND:-127.0.0.1}
COCKPIT_PORT=${COCKPIT_PORT:-9090}
HOST_USER=$(id -un)                    # the container's GUI/cockpit user mirrors the invoking host user (name, uid/gid, password)
HOST_UID=$(id -u)
HOST_GID=$(id -g)
KVM_DATA_DIR=$PWD/data                 # persistent data (var-libvirt / etc-libvirt / home), inside the repository
HOST_RUNTIME_DIR=/run/host-xdg-runtime # where the host's XDG_RUNTIME_DIR is mounted (read-only) inside the container
DESKTOP_TEMPLATE_DIR=$PWD/desktop      # templates for kvm-*.desktop
DESKTOP_APPS="virt-manager firefox"    # apps that get a .desktop entry (subcommand names of container/gui)

is_wsl() {
  [ "$KVM_HOST" = wsl ] && return 0
  [ "$KVM_HOST" != auto ] && return 1
  [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

ensure_kvm() {
  if [ ! -e /dev/kvm ]; then
    command -v modprobe >/dev/null || { echo "!! modprobe not found: sudo dnf install kmod" >&2; exit 1; }
    echo ">> loading kvm module"
    if grep -q AuthenticAMD /proc/cpuinfo; then sudo modprobe kvm_amd; else sudo modprobe kvm_intel; fi
  fi
  if [ ! -e /dev/kvm ]; then
    if is_wsl; then
      echo "!! /dev/kvm not found. Set [wsl2] nestedVirtualization=true in %USERPROFILE%\\.wslconfig on the Windows side and run wsl --shutdown" >&2
    else
      echo "!! /dev/kvm not found. Enable SVM (AMD) / VT-x (Intel) in the firmware and check sudo modprobe kvm_amd or kvm_intel" >&2
    fi
    exit 1
  fi
  sudo chmod 666 /dev/kvm
}

# build the podman arguments (HOST_ARGS) that describe the invoking host user: name, uid/gid and password hash.
# gui-user.service in the container renames the template user to this name and applies them, so cockpit accepts the
# host user's password. The hash is passed through an env file (never on the command line); ENV_FILE is removed on exit
HOST_ARGS=()
ENV_FILE=
host_user_args() {
  local hash
  [ "$HOST_UID" != 0 ] || { echo "!! run kvm.sh as a regular user, not root (the container user mirrors the invoking user)" >&2; exit 1; }
  HOST_ARGS+=(-e "HOST_USER=$HOST_USER" -e "HOST_UID=$HOST_UID" -e "HOST_GID=$HOST_GID")
  hash=$(sudo getent shadow "$HOST_USER" | cut -d: -f2)
  case "$hash" in
    ""|"!"*|"*"*)
      echo "!! $HOST_USER has no usable password on the host; cockpit login will not work until one is set (passwd), then ./kvm.sh down && ./kvm.sh up" >&2 ;;
    *)
      ENV_FILE=$(mktemp)
      trap 'rm -f "$ENV_FILE"' EXIT
      printf 'HOST_PASSWORD_HASH=%s\n' "$hash" >"$ENV_FILE"
      HOST_ARGS+=(--env-file "$ENV_FILE") ;;
  esac
}

# build the podman arguments (GUI_ARGS) that bring the host session (Wayland/X11/PulseAudio) into the container.
# The host's XDG_RUNTIME_DIR is mounted READ-ONLY at HOST_RUNTIME_DIR and never at /run/user/<uid>: that path belongs to
# the container's own logind, which would otherwise take over the host's sockets on a cockpit login (systemd --user,
# dbus-broker) and delete the whole directory when the session ends (user-runtime-dir@.service). The sockets are
# therefore passed as absolute paths; connecting to a unix socket works on a read-only mount
GUI_ARGS=()
RO_MOUNTS=()
HOST_RT=                      # the host's XDG_RUNTIME_DIR (set by gui_args)

# bind-mount a host path read-only at the same path in the container, once (skipped if it or a parent is already mounted).
# Used for the socket files themselves (a bind mount of a socket file works for connect()), never for their parent
# directories, which could be /tmp or $HOME and would shadow the container's own directories
add_ro_mount() {
  local path=$1 m
  for m in ${RO_MOUNTS[@]+"${RO_MOUNTS[@]}"}; do
    case "$path" in "$m"|"$m"/*) return 0 ;; esac
  done
  RO_MOUNTS+=("$path")
  GUI_ARGS+=(-v "$path:$path:ro")
}

# print the path under which a file/socket of the host session is reachable inside the container.
# A relative path is taken relative to the host runtime dir, symlinks are resolved first (WSLg links
# /run/user/<uid>/wayland-0 to /mnt/wslg/runtime-dir/wayland-0). Targets inside the host runtime dir map to
# HOST_RUNTIME_DIR (returns 0); anything else is printed as-is and returns 1 so that the caller mounts it
map_rt_path() {
  local p=$1 real
  case "$p" in /*) ;; *) p=$HOST_RT/$p ;; esac
  real=$(readlink -f "$p" 2>/dev/null || echo "$p")
  case "$real" in
    "$HOST_RT"/*) echo "$HOST_RUNTIME_DIR${real#"$HOST_RT"}"; return 0 ;;
    *)            echo "$real"; return 1 ;;
  esac
}

gui_args() {
  local wl x11 xauth pulse ppath
  if [ "$KVM_HOST" = headless ] || { [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; }; then
    echo ">> no display found: GUI disabled, use cockpit in a browser"
    return 0
  fi
  HOST_RT=${XDG_RUNTIME_DIR:-}
  if [ -z "$HOST_RT" ] && is_wsl; then HOST_RT=/mnt/wslg/runtime-dir; fi
  if [ ! -d "$HOST_RT" ]; then
    echo "!! XDG_RUNTIME_DIR ($HOST_RT) does not exist. Run this from a terminal inside a desktop session" >&2
    exit 1
  fi
  GUI_ARGS+=(-v "$HOST_RT:$HOST_RUNTIME_DIR:ro" -e "HOST_RUNTIME_DIR=$HOST_RUNTIME_DIR")
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in /*) wl=$WAYLAND_DISPLAY ;; *) wl=$HOST_RT/$WAYLAND_DISPLAY ;; esac
    if [ -S "$wl" ]; then
      # pass the socket as an absolute path (accepted by libwayland >= 1.15); mount the socket itself if it is outside the runtime dir
      wl=$(map_rt_path "$wl") || add_ro_mount "$wl"
      GUI_ARGS+=(-e "WAYLAND_DISPLAY=$wl")
    else
      echo "!! WAYLAND_DISPLAY=$WAYLAND_DISPLAY is not a socket ($wl); Wayland disabled, X11 is used if DISPLAY is set" >&2
    fi
  fi
  if [ -n "${DISPLAY:-}" ]; then
    x11=$(readlink -f /tmp/.X11-unix 2>/dev/null || true)
    if [ -d "$x11" ]; then
      # mount read-only so that systemd-tmpfiles in the container cannot delete the host's X sockets (connecting works on a ro mount)
      GUI_ARGS+=(-v "$x11:/tmp/.X11-unix:ro" -e "DISPLAY=$DISPLAY")
      xauth=${XAUTHORITY:-}
      if [ -n "$xauth" ] && [ -r "$xauth" ]; then
        xauth=$(map_rt_path "$xauth") || GUI_ARGS+=(-v "$xauth:$xauth:ro")
        GUI_ARGS+=(-e "XAUTHORITY=$xauth")
      fi
    fi
  fi
  pulse=${PULSE_SERVER:-}
  if [ -z "$pulse" ] && [ -S "$HOST_RT/pulse/native" ]; then pulse="unix:$HOST_RT/pulse/native"; fi
  case "$pulse" in
    unix:*) ppath=${pulse#unix:}
            if [ -S "$ppath" ]; then
              ppath=$(map_rt_path "$ppath") || add_ro_mount "$ppath"
              pulse=unix:$ppath
            else
              echo "!! PULSE_SERVER=$pulse is not a socket; audio disabled" >&2
              pulse=
            fi ;;
  esac
  if [ -n "$pulse" ]; then GUI_ARGS+=(-e "PULSE_SERVER=$pulse"); fi
  if is_wsl || [ ! -d /dev/dri ] || [ "${KVM_SOFTWARE_GL:-0}" = 1 ]; then
    GUI_ARGS+=(-e LIBGL_ALWAYS_SOFTWARE=1)
  fi
}

running() { $PODMAN container exists "$CONTAINER" 2>/dev/null && [ "$($PODMAN inspect -f '{{.State.Running}}' "$CONTAINER")" = true ]; }

# where .desktop files / icons go (the login user's area)
desktop_dirs() {
  DESKTOP_DIR=${XDG_DATA_HOME:-${HOME:?}/.local/share}/applications
  ICON_DIR=${XDG_DATA_HOME:-${HOME:?}/.local/share}/icons
}

# report a launch (.desktop) failure as a desktop notification; stderr only if no notification tool is available
launch_error() {
  echo "!! $*" >&2
  if command -v notify-send >/dev/null 2>&1; then notify-send -a kvm.sh -i dialog-error "kvm-container" "$*" 2>/dev/null || true
  elif command -v zenity >/dev/null 2>&1; then zenity --error --title=kvm-container --text="$*" 2>/dev/null || true
  fi
}

# prepare a host directory for persistent data; if empty, copy the initial content from the image (config files, directory layout, ownership)
# (unlike named volumes, bind mounts do not copy the image content on first use)
prepare_data_dir() {
  local dir=$1 src=$2
  sudo mkdir -p "$dir"
  if [ -n "$(sudo ls -A "$dir")" ]; then return 0; fi
  echo ">> seeding $dir from image $src"
  # cp inside a container (with podman cp, paths declared as VOLUME show up as empty anonymous volumes)
  $PODMAN run --rm --network none -v "$dir:/mnt/seed" "$IMAGE" cp -a "$src/." /mnt/seed/
}

# preparation for up: kvm module, image, data directories
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
  up)
    prepare_all
    if running; then echo ">> $CONTAINER is already running"; exit 0; fi
    host_user_args
    gui_args
    $PODMAN rm -f "$CONTAINER" >/dev/null 2>&1 || true
    $PODMAN run -d --name "$CONTAINER" --hostname "$CONTAINER" \
      --privileged --systemd=always \
      --device /dev/kvm --device /dev/net/tun \
      -p "$COCKPIT_BIND:$COCKPIT_PORT:9090" \
      -v "$KVM_DATA_DIR/var-libvirt:/var/lib/libvirt" \
      -v "$KVM_DATA_DIR/etc-libvirt:/etc/libvirt" \
      -v "$KVM_DATA_DIR/home:/home/$HOST_USER" \
      "${HOST_ARGS[@]}" \
      ${GUI_ARGS[@]+"${GUI_ARGS[@]}"} \
      -e "TZ=${TZ:-Asia/Tokyo}" --shm-size 2g \
      "$IMAGE" >/dev/null
    echo ">> waiting for libvirt/cockpit..."
    for i in $(seq 1 30); do
      if $PODMAN exec "$CONTAINER" sh -c 'systemctl is-active -q cockpit.socket 2>/dev/null && virsh -c qemu:///system list >/dev/null 2>&1'; then
        if [ "$COCKPIT_BIND" = 0.0.0.0 ] || [ "$COCKPIT_BIND" = "::" ]; then
          echo ">> ready. cockpit: https://$(uname -n):$COCKPIT_PORT  (log in with your host user: $HOST_USER)"
          echo ">> to reach it from other PCs (firewalld): sudo firewall-cmd --add-service=cockpit --permanent && sudo firewall-cmd --reload"
        else
          echo ">> ready. cockpit: https://$COCKPIT_BIND:$COCKPIT_PORT  (log in with your host user: $HOST_USER)"
        fi
        [ ${#GUI_ARGS[@]} -gt 0 ] && echo ">> host display: ./kvm.sh firefox | ./kvm.sh virt-manager"
        exit 0
      fi
      sleep 1
    done
    echo "!! could not confirm startup. Check systemctl --failed via ./kvm.sh shell" >&2
    exit 1
    ;;
  down)   $PODMAN rm -f -t 10 "$CONTAINER" ;;
  clean)  $PODMAN rm -f -t 10 "$CONTAINER" 2>/dev/null || true
          [ -d "$KVM_DATA_DIR" ] || { echo ">> $KVM_DATA_DIR does not exist"; exit 0; }
          echo ">> to be removed: $KVM_DATA_DIR"; sudo du -sh "$KVM_DATA_DIR"/* 2>/dev/null || true
          if [ "${KVM_CLEAN_YES:-0}" != 1 ]; then
            read -r -p "This deletes the VM disks and definitions as well. Continue? [y/N] " ans
            [ "$ans" = y ] || [ "$ans" = Y ] || { echo ">> aborted"; exit 1; }
          fi
          sudo rm -rf "$KVM_DATA_DIR" ;;
  firefox|virt-manager)
    running || "$0" up
    $PODMAN exec "$CONTAINER" gui "$cmd" "$@" ;;
  viewer)
    running || "$0" up
    $PODMAN exec "$CONTAINER" gui virt-viewer "$@" ;;
  virsh)  $PODMAN exec -it "$CONTAINER" virsh -c qemu:///system "$@" ;;
  shell)  $PODMAN exec -it "$CONTAINER" bash ;;
  logs)   $PODMAN exec "$CONTAINER" sh -c 'tail -n 50 /var/log/gui.log; journalctl --no-pager -n 30 -u virtqemud -u cockpit.socket -u gui-user' ;;
  launch)
    # for .desktop entries (Activities). There is no terminal to ask for the sudo password, so podman is run with sudo -n;
    # passwordless sudo for podman must be configured beforehand
    app=${1:-}
    case "$app" in firefox|virt-manager) ;; *) echo "usage: $0 launch firefox|virt-manager" >&2; exit 1 ;; esac
    if ! err=$(sudo -n podman exec "$CONTAINER" gui "$app" 2>&1); then
      case "$err" in
        *password*) hint="configure passwordless sudo for podman (launch runs sudo -n without a terminal)" ;;
        *)          hint="check that the container is running (./kvm.sh up)" ;;
      esac
      launch_error "could not start $app: $err"$'\n'"$hint"
      exit 1
    fi
    ;;
  install-desktop)
    # make the apps launchable from the Activities overview: install .desktop entries and icons
    [ "$(id -u)" != 0 ] || { echo "!! run this without sudo, as the user logged in to the desktop" >&2; exit 1; }
    desktop_dirs
    $PODMAN image exists "$IMAGE" || "$0" build
    # 1) icons: extract only the virt-manager / firefox icons from hicolor in the image (a generic icon is shown if this fails)
    mkdir -p "$ICON_DIR" "$DESKTOP_DIR"
    (set +o pipefail
     $PODMAN run --rm --network none "$IMAGE" sh -c \
       'cd /usr/share/icons && find hicolor -type f \( -path "*/apps/virt-manager.*" -o -path "*/apps/firefox.*" \) | tar -cf - -T -' \
       | tar -xf - -C "$ICON_DIR") 2>/dev/null || true
    # 2) .desktop entries (skip the virt-manager entry when the image has no virt-manager, i.e. not available from EPEL)
    for app in $DESKTOP_APPS; do
      if [ "$app" = virt-manager ] && ! $PODMAN run --rm --network none "$IMAGE" test -x /usr/bin/virt-manager; then
        echo ">> virt-manager is not in the image; skipping kvm-virt-manager.desktop"; continue
      fi
      sed "s|@KVM_SH@|$PWD/kvm.sh|g" "$DESKTOP_TEMPLATE_DIR/kvm-$app.desktop" >"$DESKTOP_DIR/kvm-$app.desktop"
      ls "$ICON_DIR"/hicolor/*/apps/"$app".* >/dev/null 2>&1 || echo ">> (could not extract the $app icon; a generic icon will be shown)"
    done
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$DESKTOP_DIR" || true
    echo ">> installed: $DESKTOP_DIR/kvm-*.desktop, $ICON_DIR/hicolor/*/apps/"
    echo ">> search for \"Virtual Machine Manager\" / \"Firefox\" in the Activities overview to launch them (start the container with ./kvm.sh up first;"
    echo ">>  launch runs sudo -n podman, so passwordless sudo for podman must be configured)"
    ;;
  uninstall-desktop)
    [ "$(id -u)" != 0 ] || { echo "!! run this without sudo, as the user who ran install-desktop" >&2; exit 1; }
    desktop_dirs
    for app in $DESKTOP_APPS; do rm -f "$DESKTOP_DIR/kvm-$app.desktop" "$ICON_DIR"/hicolor/*/apps/"$app".*; done
    echo ">> removed: $DESKTOP_DIR/kvm-*.desktop, $ICON_DIR/hicolor/*/apps/{virt-manager,firefox}.*"
    ;;
  *)      sed -n '2,20p' "$0" ;;
esac
