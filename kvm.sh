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
#   KVM_BRIDGE=br0          attach VMs to this host bridge: it is registered as the libvirt network "bridged"
#                           (the bridge must already exist on the host; see README)
#   KVM_SOFTWARE_GL=1       force software rendering
# WSL2-specific behaviour (detection, WSLg runtime dir, /dev/kvm hint, software rendering) lives in host/wsl.sh
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=localhost/qemu-kvm-cockpit:latest
CONTAINER=kvm                 # not NAME: WSL uses NAME for the hostname
PODMAN="sudo podman"
KVM_HOST=${KVM_HOST:-auto}
COCKPIT_BIND=${COCKPIT_BIND:-127.0.0.1}
COCKPIT_PORT=${COCKPIT_PORT:-9090}
KVM_BRIDGE=${KVM_BRIDGE:-}             # host bridge for VMs on the host's segment (libvirt network "bridged"); empty = NAT only
HOST_USER=$(id -un)                    # the container's GUI/cockpit user mirrors the invoking host user (name, uid/gid, password)
HOST_UID=$(id -u)
HOST_GID=$(id -g)
KVM_DATA_DIR=$PWD/data                 # persistent data (var-libvirt / etc-libvirt / home), inside the repository
HOST_RUNTIME_DIR=/run/host-xdg-runtime # where the host's XDG_RUNTIME_DIR is mounted (read-only) inside the container
DESKTOP_TEMPLATE_DIR=$PWD/desktop      # templates for kvm-*.desktop
DESKTOP_APPS="virt-manager firefox"    # apps that get a .desktop entry (subcommand names of container/gui)

# host-specific behaviour: generic defaults here; host/wsl.sh overrides them when running on WSL2
host_kvm_missing_hint() {   # /dev/kvm is still missing after modprobe
  echo "!! /dev/kvm not found. Enable SVM (AMD) / VT-x (Intel) in the firmware and check sudo modprobe kvm_amd or kvm_intel" >&2
}
host_default_runtime_dir() { :; }   # runtime dir to use when XDG_RUNTIME_DIR is not set (none by default)
host_force_software_gl() { [ ! -d /dev/dri ] || [ "${KVM_SOFTWARE_GL:-0}" = 1 ]; }   # no GPU, or forced by the user
. "$PWD/host/wsl.sh"

ensure_kvm() {
  if [ ! -e /dev/kvm ]; then
    command -v modprobe >/dev/null || { echo "!! modprobe not found: sudo dnf install kmod" >&2; exit 1; }
    echo ">> loading kvm module"
    if grep -q AuthenticAMD /proc/cpuinfo; then sudo modprobe kvm_amd; else sudo modprobe kvm_intel; fi
  fi
  if [ ! -e /dev/kvm ]; then
    host_kvm_missing_hint
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
  HOST_RT=${XDG_RUNTIME_DIR:-$(host_default_runtime_dir)}
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
  if host_force_software_gl; then
    GUI_ARGS+=(-e LIBGL_ALWAYS_SOFTWARE=1)
  fi
}

running() { $PODMAN container exists "$CONTAINER" 2>/dev/null && [ "$($PODMAN inspect -f '{{.State.Running}}' "$CONTAINER")" = true ]; }

virsh_in() { $PODMAN exec "$CONTAINER" virsh -c qemu:///system "$@"; }

# the container shares the host's network namespace (--network host): libvirt's bridges (virbr0), dnsmasq and nftables
# rules are created on the host, and VMs can be attached to a host bridge. Checks before starting
check_host_network() {
  if [ -n "$KVM_BRIDGE" ] && [ ! -d "/sys/class/net/$KVM_BRIDGE/bridge" ]; then
    echo "!! KVM_BRIDGE=$KVM_BRIDGE is not a bridge on this host. Create it first (see README: ブリッジ)" >&2
    exit 1
  fi
  if [ -e /sys/class/net/virbr0 ]; then
    echo "!! virbr0 already exists on the host (a libvirt running on the host, or a leftover from a crashed container)." >&2
    echo "   The container's default network will fail to start; remove it if it is a leftover: sudo ip link del virbr0" >&2
  fi
}

# register the host bridge as the libvirt network "bridged" (persisted in data/etc-libvirt), or drop it when KVM_BRIDGE is unset
sync_bridged_network() {
  local defined active
  defined=$(virsh_in net-list --all --name | grep -cx bridged || true)
  if [ -z "$KVM_BRIDGE" ]; then
    if [ "$defined" != 0 ]; then
      echo ">> KVM_BRIDGE is not set: removing the libvirt network \"bridged\""
      virsh_in net-destroy bridged >/dev/null 2>&1 || true
      virsh_in net-undefine bridged >/dev/null
    fi
    return 0
  fi
  active=$(virsh_in net-list --name | grep -cx bridged || true)
  [ "$active" = 0 ] || virsh_in net-destroy bridged >/dev/null
  printf '<network>\n  <name>bridged</name>\n  <forward mode="bridge"/>\n  <bridge name="%s"/>\n</network>\n' "$KVM_BRIDGE" \
    | $PODMAN exec -i "$CONTAINER" virsh -c qemu:///system net-define /dev/stdin >/dev/null
  virsh_in net-autostart bridged >/dev/null
  virsh_in net-start bridged >/dev/null
  echo ">> libvirt network \"bridged\" -> host bridge $KVM_BRIDGE (choose it when creating a VM, or virt-install --network network=bridged)"
}

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
    check_host_network
    $PODMAN rm -f "$CONTAINER" >/dev/null 2>&1 || true
    # --network host: VMs can be bridged onto the host's segment. cockpit then listens on the host directly, so its
    # bind address/port is passed to the container (cockpit-listen generator) instead of using podman's -p
    $PODMAN run -d --name "$CONTAINER" --hostname "$CONTAINER" \
      --privileged --systemd=always --network host \
      --device /dev/kvm --device /dev/net/tun \
      -e "COCKPIT_LISTEN=$COCKPIT_BIND:$COCKPIT_PORT" \
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
        sync_bridged_network
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
