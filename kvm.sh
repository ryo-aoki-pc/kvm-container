#!/bin/bash
# Helper script for the qemu-kvm/libvirt/cockpit containers (AlmaLinux 10): "kvm" runs libvirt + qemu-kvm + cockpit
# (privileged), "kvm-gui" runs firefox / virt-manager / virt-viewer on the host display (unprivileged, only with a display)
# Supported hosts: Windows + WSL2 (WSLg) / physical AlmaLinux 10 + GNOME (Wayland) / headless (cockpit only)
#   ./kvm.sh build [kvm|gui]  build the images (both by default; extra arguments go to podman build)
#   ./kvm.sh up [kvm|gui]     start the containers (kvm, plus kvm-gui when there is a display). cockpit: https://localhost:9091,
#                             log in with your host user. After a host re-login, up recreates kvm-gui only (VMs keep running)
#   ./kvm.sh down [kvm|gui]   stop and remove the containers (VM data stays in data/ under the repository)
#                             up and down hand the kvm container over to systemctl once install-service has run
#   ./kvm.sh firefox          open cockpit in the GUI container's firefox on the host display
#   ./kvm.sh virt-manager     show virt-manager on the host display
#   ./kvm.sh viewer <VM>      show a VM's screen with virt-viewer on the host display
#   ./kvm.sh virsh ...        run virsh inside the kvm container
#   ./kvm.sh shell [kvm|gui]  root shell inside a container (default: kvm)
#   ./kvm.sh logs [kvm|gui]   libvirt/cockpit journal (kvm) and GUI application logs (gui); both by default
#   ./kvm.sh clean            remove the containers and everything under data/ (asks for confirmation)
#   ./kvm.sh install-desktop  install .desktop entries and icons to launch from the Activities overview
#   ./kvm.sh uninstall-desktop  remove the above
#   ./kvm.sh launch <app>     used by the .desktop entries (firefox|virt-manager): runs via sudo -n, reports failures as desktop notifications
#   ./kvm.sh install-service  run the kvm container as kvm-container.service (Quadlet): starts at boot, restarts on failure
#   ./kvm.sh uninstall-service  remove the above (kvm-gui is never part of it: it needs the desktop session)
#   ./kvm.sh prepare          internal: ExecStartPre of kvm-container.service (runs as root)
#   ./kvm.sh ready            internal: ExecStartPost of kvm-container.service (runs as root)
# Environment variables:
#   KVM_HOST=auto|wsl|generic|headless  override host type detection
#   COCKPIT_BIND=127.0.0.1  COCKPIT_PORT=9091  cockpit bind address/port (use 0.0.0.0 to reach it from other PCs)
#   KVM_BRIDGE=br0          attach VMs to this host bridge: it is registered as the libvirt network "bridged"
#                           (the bridge must already exist on the host; see README)
#   KVM_SOFTWARE_GL=1       force software rendering
#   install-service freezes COCKPIT_BIND / COCKPIT_PORT / KVM_BRIDGE / TZ and the host user into the unit; a system
#   service has no session to read them from at start time. Re-run install-service to change them
# WSL2-specific behaviour (detection, WSLg runtime dir, /dev/kvm hint, software rendering) lives in host/wsl.sh
set -euo pipefail
cd "$(dirname "$0")"

# two images (targets of the multi-stage Containerfile) and two containers. Names are fixed; the variable is not NAME
# because WSL uses NAME for the hostname
KVM_IMAGE=localhost/kvm-container/kvm:latest   # libvirt + qemu-kvm + cockpit
GUI_IMAGE=localhost/kvm-container/gui:latest   # firefox / virt-manager / virt-viewer
KVM_CONTAINER=kvm
GUI_CONTAINER=kvm-gui
KVM_HOST=${KVM_HOST:-auto}
COCKPIT_BIND=${COCKPIT_BIND:-127.0.0.1}
COCKPIT_PORT=${COCKPIT_PORT:-9091}     # not cockpit's usual 9090: the host often runs its own cockpit there (see check_host_network)
KVM_BRIDGE=${KVM_BRIDGE:-}             # host bridge for VMs on the host's segment (libvirt network "bridged"); empty = NAT only
KVM_DATA_DIR=$PWD/data                 # persistent data (var-libvirt / etc-libvirt / home), inside the repository
KVM_RUN_DIR=/run/kvm-container         # host directory shared by the containers: libvirt/ is /run/libvirt in both (on tmpfs, wiped by up/down)
HOST_RUNTIME_DIR=/run/host-xdg-runtime # where the host's XDG_RUNTIME_DIR is mounted (read-only) inside the GUI container
DESKTOP_TEMPLATE_DIR=$PWD/desktop      # templates for kvm-*.desktop
DESKTOP_APPS="virt-manager firefox"    # apps that get a .desktop entry (subcommand names of container/gui/gui)
# the Quadlet unit for the kvm container: template in the repository, installed copy, and the unit the generator
# makes from it. When the installed copy exists, systemd owns the container and up/down hand over to systemctl
QUADLET_TEMPLATE=$PWD/quadlet/kvm-container.container
QUADLET_FILE=/etc/containers/systemd/kvm-container.container
QUADLET_UNIT=kvm-container.service

# podman needs root. Normally that means sudo, but the Quadlet unit runs "kvm.sh prepare" / "ready" as root itself.
# root has no session of its own, so the host user it works for arrives in HOST_USER (see require_host_user below)
if [ "$(id -u)" = 0 ]; then
  SUDO=; PODMAN=podman
  HOST_USER=${HOST_USER:-}; HOST_UID=; HOST_GID=
else
  SUDO=sudo; PODMAN="sudo podman"
  HOST_USER=$(id -un)                  # the containers' GUI/cockpit user mirrors the invoking host user (name, uid/gid, password)
  HOST_UID=$(id -u)
  HOST_GID=$(id -g)
fi

# resolve the host user's uid/gid when running as root (prepare / ready only); a no-op for a normal user
require_host_user() {
  [ -n "$HOST_USER" ] || { echo "!! HOST_USER is not set. Run kvm.sh as a regular user, or through $QUADLET_UNIT" >&2; exit 1; }
  [ -n "$HOST_UID" ] || HOST_UID=$(id -u "$HOST_USER") || { echo "!! HOST_USER=$HOST_USER does not exist on this host" >&2; exit 1; }
  [ -n "$HOST_GID" ] || HOST_GID=$(id -g "$HOST_USER")
}

# host-specific behaviour: generic defaults here; host/wsl.sh overrides them when running on WSL2
host_kvm_missing_hint() {   # /dev/kvm is still missing after modprobe
  echo "!! /dev/kvm not found. Enable SVM (AMD) / VT-x (Intel) in the firmware and check sudo modprobe kvm_amd or kvm_intel" >&2
}
host_default_runtime_dir() { :; }   # runtime dir to use when XDG_RUNTIME_DIR is not set (none by default)
host_force_software_gl() { [ ! -d /dev/dri ] || [ "${KVM_SOFTWARE_GL:-0}" = 1 ]; }   # no GPU, or forced by the user
. "$PWD/host/wsl.sh"

# print the role given as the first argument of a subcommand (kvm|gui), nothing when it is not one
role_arg() { case "${1:-}" in kvm|gui) echo "$1" ;; esac; }
image_of() { case "$1" in kvm) echo "$KVM_IMAGE" ;; gui) echo "$GUI_IMAGE" ;; esac; }
container_of() { case "$1" in kvm) echo "$KVM_CONTAINER" ;; gui) echo "$GUI_CONTAINER" ;; esac; }
# is there a host display to show the GUI container's apps on?
have_display() { [ "$KVM_HOST" != headless ] && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; }

ensure_kvm() {
  if [ ! -e /dev/kvm ]; then
    command -v modprobe >/dev/null || { echo "!! modprobe not found: sudo dnf install kmod" >&2; exit 1; }
    echo ">> loading kvm module"
    if grep -q AuthenticAMD /proc/cpuinfo; then $SUDO modprobe kvm_amd; else $SUDO modprobe kvm_intel; fi
  fi
  if [ ! -e /dev/kvm ]; then
    host_kvm_missing_hint
    exit 1
  fi
  $SUDO chmod 666 /dev/kvm
}

# build the podman arguments that describe the invoking host user: name and uid/gid (HOST_ARGS, both containers) and
# the password hash (HASH_ARGS, kvm only: cockpit authenticates against the container's /etc/shadow; the GUI container
# only needs the uid to reach the host session's sockets). gui-user.service in each container renames the template
# user to this name and applies them. The hash is passed through an env file (never on the command line); ENV_FILE is
# removed on exit
HOST_ARGS=()
HASH_ARGS=()
ENV_FILE=
QUADLET_TMP=      # like ENV_FILE: referenced by an EXIT trap, so it must not be a local
# print the host user's password hash, or nothing (with a warning) when it cannot be used for a cockpit login.
# getent may fail on hosts where the user comes from LDAP/SSSD; that must not abort the script, least of all when it
# runs as an ExecStartPre at boot, so a lookup failure is treated as "no usable password"
host_password_hash() {
  local hash
  hash=$($SUDO getent shadow "$HOST_USER" 2>/dev/null | cut -d: -f2) || hash=
  case "$hash" in
    ""|"!"*|"*"*)
      echo "!! $HOST_USER has no usable password on the host; cockpit login will not work until one is set (passwd), then ./kvm.sh down kvm && ./kvm.sh up" >&2 ;;
    *)
      printf '%s' "$hash" ;;
  esac
}

host_user_args() {
  local hash
  [ ${#HOST_ARGS[@]} -eq 0 ] || return 0     # already built
  # root is refused here, not in the dispatch: prepare / ready are run as root by the Quadlet unit and never get here
  [ "$(id -u)" != 0 ] || { echo "!! run kvm.sh as a regular user, not root (the container user mirrors the invoking user)" >&2; exit 1; }
  HOST_ARGS=(-e "HOST_USER=$HOST_USER" -e "HOST_UID=$HOST_UID" -e "HOST_GID=$HOST_GID")
  hash=$(host_password_hash)
  if [ -n "$hash" ]; then
    ENV_FILE=$(mktemp)
    trap 'rm -f "$ENV_FILE"' EXIT
    printf 'HOST_PASSWORD_HASH=%s\n' "$hash" >"$ENV_FILE"
    HASH_ARGS=(--env-file "$ENV_FILE")
  fi
}

# the same hash, for the Quadlet unit: written to a file on tmpfs that EnvironmentFile= (podman --env-file) reads.
# The file is always created, and 0600 root before anything is written into it; the unit removes it again once the
# container is up. An empty value is fine: gui-user-setup then leaves the container user locked
write_env_file() {
  $SUDO install -m 0600 -o root -g root -D /dev/null "$KVM_RUN_DIR/kvm.env"
  printf 'HOST_PASSWORD_HASH=%s\n' "$(host_password_hash)" | $SUDO tee "$KVM_RUN_DIR/kvm.env" >/dev/null
}

# build the podman arguments (GUI_ARGS) that bring the host session (Wayland/X11/PulseAudio, GPU) into the GUI container.
# The host's XDG_RUNTIME_DIR is mounted READ-ONLY at HOST_RUNTIME_DIR and never at /run/user/<uid>: that path belongs to
# the container's own logind, which would otherwise take over the host's sockets (systemd --user, dbus-broker) and
# delete the whole directory when a session ends (user-runtime-dir@.service). The sockets are therefore passed as
# absolute paths; connecting to a unix socket works on a read-only mount.
# GUI_ARGS also identifies the host session: up recreates the GUI container when it changes (see start_gui)
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

gui_args() {   # the caller has checked have_display
  local wl x11 xauth pulse ppath
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
  # the GPU's render nodes (none on WSL, which has no /dev/dri); the container is not privileged, so pass them explicitly
  [ ! -d /dev/dri ] || GUI_ARGS+=(--device /dev/dri)
  if host_force_software_gl; then
    GUI_ARGS+=(-e LIBGL_ALWAYS_SOFTWARE=1)
  fi
}

running() { $PODMAN container exists "$1" 2>/dev/null && [ "$($PODMAN inspect -f '{{.State.Running}}' "$1")" = true ]; }

virsh_in() { $PODMAN exec "$KVM_CONTAINER" virsh -c qemu:///system "$@"; }

# the kvm container shares the host's network namespace (--network host): libvirt's bridges (virbr0), dnsmasq and nftables
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
  # cockpit-ws binds on the host itself, so anything already listening on that port makes the container's
  # cockpit.socket fail with "Address already in use". The default is 9091 to stay clear of the host's own cockpit
  if command -v ss >/dev/null 2>&1 && [ -n "$(ss -H -ltn "sport = :$COCKPIT_PORT" 2>/dev/null)" ]; then
    echo "!! port $COCKPIT_PORT is already in use on the host, so the container's cockpit cannot start." >&2
    echo "   Free the port, or pick another one: COCKPIT_PORT=9092 ./kvm.sh up" >&2
    exit 1
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
    | $PODMAN exec -i "$KVM_CONTAINER" virsh -c qemu:///system net-define /dev/stdin >/dev/null
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

# prepare a host directory for persistent data; if empty, copy the initial content from the kvm image (config files,
# directory layout, ownership). Unlike named volumes, bind mounts do not copy the image content on first use
prepare_data_dir() {
  local dir=$1 src=$2
  $SUDO mkdir -p "$dir"
  if [ -n "$($SUDO ls -A "$dir")" ]; then return 0; fi
  echo ">> seeding $dir from image $src"
  # cp inside a container (with podman cp, paths declared as VOLUME show up as empty anonymous volumes).
  # label=disable: the data directories live under the user's home (user_home_t) and are only ever used by containers
  # that run without SELinux label separation, so they are not relabelled; without this, SELinux denies the write on
  # Enforcing hosts
  $PODMAN run --rm --network none --security-opt label=disable -v "$dir:/mnt/seed" "$KVM_IMAGE" cp -a "$src/." /mnt/seed/
}

build_image() {   # build_image kvm|gui [podman build arguments]
  local role=$1; shift
  echo ">> building $(image_of "$role") (Containerfile target $role)"
  $PODMAN build --target "$role" -t "$(image_of "$role")" -f Containerfile "$@" .
}

# everything the kvm container needs on the host before it can be created: the kvm module and /dev/kvm, the image
# (seeding data/ runs a container from it), the persistent data directories and the host network checks.
# Used by start_kvm and by the Quadlet ExecStartPre, which differ only in what a missing image means
prepare_kvm() {   # prepare_kvm build|require
  ensure_kvm
  if ! $PODMAN image exists "$KVM_IMAGE"; then
    # the service must never build: it would hold up the boot for as long as a full image build takes
    [ "$1" = build ] || { echo "!! image $KVM_IMAGE not found. Run ./kvm.sh build kvm first" >&2; exit 1; }
    build_image kvm
  fi
  prepare_data_dir "$KVM_DATA_DIR/var-libvirt" /var/lib/libvirt
  prepare_data_dir "$KVM_DATA_DIR/etc-libvirt" /etc/libvirt
  prepare_data_dir "$KVM_DATA_DIR/home" /etc/skel
  check_host_network
}

# empty the run dir shared with the GUI container. Call this only once the old kvm container is gone: its shutdown
# (kvm-net-teardown.service) talks to libvirt through the very sockets that live in here
reset_run_dir() {
  # /run/libvirt is shared with the GUI container through a host directory (on tmpfs). Like the container's own /run it
  # must start empty: sockets, pid files and VM state of a previous run would confuse the daemons. Only the contents are
  # removed, never the directory: a running GUI container has it bind-mounted and would keep seeing the old inode
  $SUDO mkdir -p "$KVM_RUN_DIR/libvirt" && $SUDO find "$KVM_RUN_DIR/libvirt" -mindepth 1 -delete
}

# wait until cockpit and libvirt answer inside the container, at most <attempts> seconds
wait_kvm_ready() {   # wait_kvm_ready <attempts>
  local _
  for _ in $(seq 1 "$1"); do
    $PODMAN exec "$KVM_CONTAINER" sh -c 'systemctl is-active -q cockpit.socket 2>/dev/null && virsh -c qemu:///system list >/dev/null 2>&1' && return 0
    sleep 1
  done
  return 1
}

ready_message() {
  if [ "$COCKPIT_BIND" = 0.0.0.0 ] || [ "$COCKPIT_BIND" = "::" ]; then
    echo ">> ready. cockpit: https://$(uname -n):$COCKPIT_PORT  (log in with your host user: $HOST_USER)"
    echo ">> to reach it from other PCs (firewalld): sudo firewall-cmd --add-port=$COCKPIT_PORT/tcp --permanent && sudo firewall-cmd --reload"
  else
    echo ">> ready. cockpit: https://$COCKPIT_BIND:$COCKPIT_PORT  (log in with your host user: $HOST_USER)"
  fi
}

# start the kvm container (libvirt/qemu/cockpit) unless it is running
start_kvm() {
  if running "$KVM_CONTAINER"; then echo ">> $KVM_CONTAINER is already running"; return 0; fi
  prepare_kvm build
  host_user_args
  $PODMAN rm -f -i "$KVM_CONTAINER" >/dev/null 2>&1 || true
  reset_run_dir
  # --network host: VMs can be bridged onto the host's segment. cockpit then listens on the host directly, so its
  # bind address/port is passed to the container (cockpit-listen generator) instead of using podman's -p
  $PODMAN run -d --name "$KVM_CONTAINER" --hostname "$KVM_CONTAINER" \
    --privileged --systemd=always --network host \
    --device /dev/kvm --device /dev/net/tun \
    -e "COCKPIT_LISTEN=$COCKPIT_BIND:$COCKPIT_PORT" \
    -v "$KVM_DATA_DIR/var-libvirt:/var/lib/libvirt" \
    -v "$KVM_DATA_DIR/etc-libvirt:/etc/libvirt" \
    -v "$KVM_DATA_DIR/home:/home/$HOST_USER" \
    -v "$KVM_RUN_DIR/libvirt:/run/libvirt" \
    "${HOST_ARGS[@]}" \
    ${HASH_ARGS[@]+"${HASH_ARGS[@]}"} \
    -e "TZ=${TZ:-Asia/Tokyo}" --shm-size 2g \
    "$KVM_IMAGE" >/dev/null
  echo ">> waiting for libvirt/cockpit..."
  wait_kvm_ready 30 || { echo "!! could not confirm startup. Check systemctl --failed via ./kvm.sh shell" >&2; exit 1; }
  sync_bridged_network
  ready_message
}

# is the running GUI container the one for the current host session? Its podman arguments (socket paths, auth file,
# audio, GPU) are recorded in a label; in addition the sockets must still be there inside the container: after a host
# re-login the paths are often the same, but the old runtime dir stays pinned by the container's mount with the
# sockets gone, while the new session lives in a fresh one
gui_session_matches() {   # gui_session_matches <session id>
  [ "$($PODMAN inspect -f '{{index .Config.Labels "kvm.gui-session"}}' "$GUI_CONTAINER")" = "$1" ] || return 1
  # single quotes on purpose: the variables are expanded by the shell inside the container, not here
  # shellcheck disable=SC2016
  $PODMAN exec "$GUI_CONTAINER" sh -c '{ [ -z "${WAYLAND_DISPLAY:-}" ] || [ -S "$WAYLAND_DISPLAY" ]; } && { [ -z "${XAUTHORITY:-}" ] || [ -r "$XAUTHORITY" ]; }'
}

# start the GUI container for the current host session; recreate it when it was started for another session
# (GNOME re-login: new Wayland socket / Xauthority). The caller has checked have_display
start_gui() {
  local session
  gui_args
  session=$(printf '%s\n' "${GUI_ARGS[@]}" | sha256sum | cut -c1-16)
  if running "$GUI_CONTAINER"; then
    if gui_session_matches "$session"; then echo ">> $GUI_CONTAINER is already running"; return 0; fi
    echo ">> the host session has changed: recreating $GUI_CONTAINER (the kvm container and its VMs keep running)"
  fi
  host_user_args
  $PODMAN image exists "$GUI_IMAGE" || build_image gui
  $PODMAN rm -f -i "$GUI_CONTAINER" >/dev/null 2>&1 || true
  $SUDO mkdir -p "$KVM_RUN_DIR/libvirt" "$KVM_DATA_DIR/var-libvirt" "$KVM_DATA_DIR/home"
  # unprivileged, but without SELinux label separation (label=disable): it connects to the unix sockets the privileged
  # kvm container creates in the shared /run/libvirt and reads the host session's runtime dir. --network host so that
  # firefox reaches cockpit on localhost and the VNC consoles on the host's loopback
  $PODMAN run -d --name "$GUI_CONTAINER" --hostname "$GUI_CONTAINER" \
    --systemd=always --network host --security-opt label=disable \
    --label "kvm.gui-session=$session" \
    -e "COCKPIT_LISTEN=$COCKPIT_BIND:$COCKPIT_PORT" \
    -v "$KVM_DATA_DIR/var-libvirt:/var/lib/libvirt:ro" \
    -v "$KVM_DATA_DIR/home:/home/$HOST_USER" \
    -v "$KVM_RUN_DIR/libvirt:/run/libvirt" \
    "${HOST_ARGS[@]}" \
    "${GUI_ARGS[@]}" \
    -e "TZ=${TZ:-Asia/Tokyo}" --shm-size 2g \
    "$GUI_IMAGE" >/dev/null
  echo ">> $GUI_CONTAINER started. host display: ./kvm.sh firefox | ./kvm.sh virt-manager"
}

# once install-service has put the unit in place, systemd owns the kvm container: up and down hand over to it
# instead of running podman themselves, so that the container never has two owners
quadlet_installed() { [ -e "$QUADLET_FILE" ]; }

# read one of the values install-service baked into the unit. Asking systemd avoids parsing the .container file here
quadlet_env() {   # quadlet_env <name>
  systemctl show -p Environment --value "$QUADLET_UNIT" 2>/dev/null | tr ' ' '\n' | sed -n "s/^$1=//p" || true
}

# use the baked-in value and say so when the caller's environment disagrees. Adopting it (rather than just warning)
# keeps the rest of the run consistent: start_gui passes COCKPIT_LISTEN on to kvm-gui, and firefox would otherwise
# open a cockpit port that nothing is listening on
quadlet_adopt() {   # quadlet_adopt <name> <value from the environment>
  local baked
  baked=$(quadlet_env "$1")
  [ "$baked" = "$2" ] || echo "!! $1=$2 is ignored: $QUADLET_UNIT was installed with $1=$baked (./kvm.sh install-service to change it)" >&2
  printf '%s' "$baked"
}

start_kvm_service() {
  local baked_user
  baked_user=$(quadlet_env HOST_USER)
  if [ -z "$baked_user" ]; then
    echo "!! $QUADLET_UNIT is not generated yet: run sudo systemctl daemon-reload (using the current environment instead)" >&2
  else
    COCKPIT_BIND=$(quadlet_adopt COCKPIT_BIND "$COCKPIT_BIND")
    COCKPIT_PORT=$(quadlet_adopt COCKPIT_PORT "$COCKPIT_PORT")
    KVM_BRIDGE=$(quadlet_adopt KVM_BRIDGE "$KVM_BRIDGE")
    # not adopted: data/home is bind-mounted at /home/<user>, so another user needs a unit of their own
    [ "$baked_user" = "$HOST_USER" ] || echo "!! $QUADLET_UNIT was installed for $baked_user, not $HOST_USER (./kvm.sh install-service to change it)" >&2
  fi
  echo ">> $KVM_CONTAINER is managed by systemd: starting $QUADLET_UNIT"
  $SUDO systemctl start "$QUADLET_UNIT"
  ready_message
}

# fill the template with the values in effect now and install it. Everything substituted here is frozen until the
# next install-service, because a system service has no session to read them from at start time
install_service() {
  local left label
  [ "$(id -u)" != 0 ] || { echo "!! run this without sudo, as the user who will own the VMs (the container user mirrors it)" >&2; exit 1; }
  [ -d /run/systemd/system ] || { echo "!! systemd is not running on this host, so Quadlet cannot be used (WSL2: set [boot] systemd=true in /etc/wsl.conf)" >&2; exit 1; }
  [ -r "$QUADLET_TEMPLATE" ] || { echo "!! template not found: $QUADLET_TEMPLATE" >&2; exit 1; }
  $PODMAN image exists "$KVM_IMAGE" || build_image kvm   # the service itself never builds (it must not delay the boot)
  QUADLET_TMP=$(mktemp); trap 'rm -f "$QUADLET_TMP"' EXIT
  sed -e "s|@CONTAINER@|$KVM_CONTAINER|g" -e "s|@IMAGE@|$KVM_IMAGE|g" \
      -e "s|@HOST_USER@|$HOST_USER|g" -e "s|@HOST_UID@|$HOST_UID|g" -e "s|@HOST_GID@|$HOST_GID|g" \
      -e "s|@COCKPIT_BIND@|$COCKPIT_BIND|g" -e "s|@COCKPIT_PORT@|$COCKPIT_PORT|g" \
      -e "s|@KVM_BRIDGE@|$KVM_BRIDGE|g" -e "s|@TZ@|${TZ:-Asia/Tokyo}|g" \
      -e "s|@KVM_DATA_DIR@|$KVM_DATA_DIR|g" -e "s|@KVM_RUN_DIR@|$KVM_RUN_DIR|g" \
      -e "s|@KVM_SH@|$PWD/kvm.sh|g" -e "s|@REPO_DIR@|$PWD|g" \
      "$QUADLET_TEMPLATE" >"$QUADLET_TMP"
  left=$(grep -o '@[A-Z_]*@' "$QUADLET_TMP" | sort -u | tr '\n' ' ') || left=   # no match is the good case
  [ -z "$left" ] || { echo "!! the template has placeholders this version of kvm.sh does not fill: $left" >&2; exit 1; }
  $SUDO install -D -m 0644 -o root -g root "$QUADLET_TMP" "$QUADLET_FILE"
  if command -v restorecon >/dev/null 2>&1; then $SUDO restorecon -F "$QUADLET_FILE" || true; fi
  # EnvironmentFile= (podman --env-file) must exist by the time the container is created; prepare rewrites it
  $SUDO install -m 0600 -o root -g root -D /dev/null "$KVM_RUN_DIR/kvm.env"
  $SUDO systemctl daemon-reload
  systemctl cat "$QUADLET_UNIT" >/dev/null 2>&1 || {
    echo "!! $QUADLET_UNIT was not generated from $QUADLET_FILE. Check the podman version (Quadlet needs 4.4 or newer) with" >&2
    echo "   sudo /usr/lib/systemd/system-generators/podman-system-generator --dryrun" >&2
    exit 1; }
  echo ">> installed: $QUADLET_FILE -> $QUADLET_UNIT (starts at boot)"
  echo ">> sudo systemctl start|stop|restart|status kvm-container   journalctl -u kvm-container"
  echo ">> ./kvm.sh up and down now hand the $KVM_CONTAINER container over to systemctl"
  echo ">> baked in until the next install-service: HOST_USER=$HOST_USER COCKPIT_BIND=$COCKPIT_BIND COCKPIT_PORT=$COCKPIT_PORT KVM_BRIDGE=${KVM_BRIDGE:-(none)} TZ=${TZ:-Asia/Tokyo}"
  echo ">> $GUI_CONTAINER stays outside systemd (it needs the desktop session): keep using ./kvm.sh up gui"
  if running "$KVM_CONTAINER"; then
    echo "!! $KVM_CONTAINER is running right now. Run ./kvm.sh down kvm first, or the port check in prepare will find" >&2
    echo "   the cockpit of that very container and refuse to start the service" >&2
  fi
  # ExecStartPre runs kvm.sh straight out of the repository. Under a home directory it is labelled user_home_t,
  # which systemd (init_t) is not allowed to execute on an Enforcing host
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = Enforcing ]; then
    label=$(ls -Zd "$PWD/kvm.sh" 2>/dev/null) || label=
    case "$label" in
      *:bin_t:*|*:shell_exec_t:*) ;;
      *) echo "!! SELinux is Enforcing and $PWD/kvm.sh is not labelled bin_t, so systemd may not be allowed to run it." >&2
         echo "   If the service fails with \"Failed at step EXEC\": sudo semanage fcontext -a -t bin_t '$PWD/kvm.sh' && sudo restorecon -v '$PWD/kvm.sh'" >&2 ;;
    esac
  fi
}

uninstall_service() {
  [ "$(id -u)" != 0 ] || { echo "!! run this without sudo" >&2; exit 1; }
  quadlet_installed || { echo ">> $QUADLET_FILE is not installed"; exit 0; }
  $SUDO systemctl stop "$QUADLET_UNIT" || true
  $SUDO rm -f "$QUADLET_FILE"
  $SUDO systemctl daemon-reload
  echo ">> removed: $QUADLET_FILE (./kvm.sh up starts the container with podman again)"
}

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

cmd=${1:-help}; shift || true
role=
case "$cmd" in build|up|down|shell|logs) role=$(role_arg "${1:-}"); [ -z "$role" ] || shift ;; esac
case "$cmd" in
  build)
    for r in ${role:-kvm gui}; do build_image "$r" "$@"; done
    ;;
  up)
    [ $# -eq 0 ] || { usage >&2; exit 1; }
    case "$role" in
      ""|kvm) if quadlet_installed; then start_kvm_service; else start_kvm; fi ;;
    esac
    case "$role" in
      "")  if have_display; then start_gui; else echo ">> no display found: GUI disabled, use cockpit in a browser"; fi ;;
      gui) have_display || { echo "!! no display found (DISPLAY / WAYLAND_DISPLAY unset, or KVM_HOST=headless): the GUI container is not needed" >&2; exit 1; }
           start_gui ;;
    esac
    ;;
  down)
    [ $# -eq 0 ] || { usage >&2; exit 1; }
    case "$role" in ""|gui) $PODMAN rm -f -i -t 10 "$GUI_CONTAINER" ;; esac
    # -t 30 matches the unit's StopTimeout: the container's systemd needs that long to let kvm-net-teardown
    # remove virbr* before it is killed
    case "$role" in ""|kvm)
      if quadlet_installed; then $SUDO systemctl stop "$QUADLET_UNIT"
      else $PODMAN rm -f -i -t 30 "$KVM_CONTAINER"; fi ;;
    esac
    [ -n "$role" ] || $SUDO rm -rf "$KVM_RUN_DIR"
    ;;
  clean)  "$0" down
          [ -d "$KVM_DATA_DIR" ] || { echo ">> $KVM_DATA_DIR does not exist"; exit 0; }
          echo ">> to be removed: $KVM_DATA_DIR"; $SUDO du -sh "$KVM_DATA_DIR"/* 2>/dev/null || true
          if [ "${KVM_CLEAN_YES:-0}" != 1 ]; then
            read -r -p "This deletes the VM disks and definitions as well. Continue? [y/N] " ans
            [ "$ans" = y ] || [ "$ans" = Y ] || { echo ">> aborted"; exit 1; }
          fi
          $SUDO rm -rf "$KVM_DATA_DIR" ;;
  firefox|virt-manager|viewer)
    have_display || { echo "!! no display found: use cockpit in a browser (https://$COCKPIT_BIND:$COCKPIT_PORT)" >&2; exit 2; }
    "$0" up          # starts what is missing, recreates the GUI container after a host re-login
    [ "$cmd" != viewer ] || cmd=virt-viewer
    $PODMAN exec "$GUI_CONTAINER" gui "$cmd" "$@" ;;
  virsh)  $PODMAN exec -it "$KVM_CONTAINER" virsh -c qemu:///system "$@" ;;
  shell)  $PODMAN exec -it "$(container_of "${role:-kvm}")" bash ;;
  logs)
    if [ "$role" != gui ]; then
      if running "$KVM_CONTAINER"; then
        $PODMAN exec "$KVM_CONTAINER" journalctl --no-pager -n 30 -u kvm-libvirt-conf -u virtqemud -u cockpit.socket -u gui-user
      else echo ">> $KVM_CONTAINER is not running"; fi
    fi
    if [ "$role" != kvm ]; then
      if running "$GUI_CONTAINER"; then
        $PODMAN exec "$GUI_CONTAINER" sh -c 'tail -n 50 /var/log/gui.log 2>/dev/null; journalctl --no-pager -n 30 -u gui-user'
      else echo ">> $GUI_CONTAINER is not running"; fi
    fi
    ;;
  launch)
    # for .desktop entries (Activities). There is no terminal to ask for the sudo password, so podman is run with sudo -n;
    # passwordless sudo for podman must be configured beforehand
    app=${1:-}
    case "$app" in firefox|virt-manager) ;; *) echo "usage: $0 launch firefox|virt-manager" >&2; exit 1 ;; esac
    if ! err=$(sudo -n podman exec "$GUI_CONTAINER" gui "$app" 2>&1); then
      case "$err" in
        *password*) hint="configure passwordless sudo for podman (launch runs sudo -n without a terminal)" ;;
        *)          hint="check that the GUI container is running (./kvm.sh up)" ;;
      esac
      launch_error "could not start $app: $err"$'\n'"$hint"
      exit 1
    fi
    ;;
  install-desktop)
    # make the apps launchable from the Activities overview: install .desktop entries and icons
    [ "$(id -u)" != 0 ] || { echo "!! run this without sudo, as the user logged in to the desktop" >&2; exit 1; }
    desktop_dirs
    $PODMAN image exists "$GUI_IMAGE" || build_image gui
    # 1) icons: extract only the virt-manager / firefox icons from hicolor in the GUI image (a generic icon is shown if this fails)
    mkdir -p "$ICON_DIR" "$DESKTOP_DIR"
    (set +o pipefail
     $PODMAN run --rm --network none "$GUI_IMAGE" sh -c \
       'cd /usr/share/icons && find hicolor -type f \( -path "*/apps/virt-manager.*" -o -path "*/apps/firefox.*" \) | tar -cf - -T -' \
       | tar -xf - -C "$ICON_DIR") 2>/dev/null || true
    # 2) .desktop entries (skip the virt-manager entry when the image has no virt-manager, i.e. not available from EPEL)
    for app in $DESKTOP_APPS; do
      if [ "$app" = virt-manager ] && ! $PODMAN run --rm --network none "$GUI_IMAGE" test -x /usr/bin/virt-manager; then
        echo ">> virt-manager is not in the image; skipping kvm-virt-manager.desktop"; continue
      fi
      sed "s|@KVM_SH@|$PWD/kvm.sh|g" "$DESKTOP_TEMPLATE_DIR/kvm-$app.desktop" >"$DESKTOP_DIR/kvm-$app.desktop"
      ls "$ICON_DIR"/hicolor/*/apps/"$app".* >/dev/null 2>&1 || echo ">> (could not extract the $app icon; a generic icon will be shown)"
    done
    if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q "$DESKTOP_DIR" || true; fi
    echo ">> installed: $DESKTOP_DIR/kvm-*.desktop, $ICON_DIR/hicolor/*/apps/"
    echo ">> search for \"Virtual Machine Manager\" / \"Firefox\" in the Activities overview to launch them (start the containers with ./kvm.sh up first;"
    echo ">>  launch runs sudo -n podman, so passwordless sudo for podman must be configured)"
    ;;
  uninstall-desktop)
    [ "$(id -u)" != 0 ] || { echo "!! run this without sudo, as the user who ran install-desktop" >&2; exit 1; }
    desktop_dirs
    for app in $DESKTOP_APPS; do rm -f "$DESKTOP_DIR/kvm-$app.desktop" "$ICON_DIR"/hicolor/*/apps/"$app".*; done
    echo ">> removed: $DESKTOP_DIR/kvm-*.desktop, $ICON_DIR/hicolor/*/apps/{virt-manager,firefox}.*"
    ;;
  install-service)    install_service ;;
  uninstall-service)  uninstall_service ;;
  prepare)
    require_host_user
    # ExecStartPre of kvm-container.service (root). Everything the container needs on the host, then the password
    # hash for --env-file. The old container is already gone here (systemd stopped it; podman run --replace
    # handles a leftover), so emptying the run dir cannot cut short anyone's shutdown
    prepare_kvm require
    reset_run_dir
    write_env_file
    ;;
  ready)
    require_host_user
    # ExecStartPost of kvm-container.service (root), and non-fatal there: a slow host must not cost us the
    # container. More patient than the interactive path, which has a user watching it
    echo ">> waiting for libvirt/cockpit..."
    wait_kvm_ready 120 || { echo "!! could not confirm startup. Check systemctl --failed via ./kvm.sh shell" >&2; exit 1; }
    sync_bridged_network
    ready_message
    ;;
  *)      usage ;;
esac
