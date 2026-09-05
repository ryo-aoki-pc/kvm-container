#!/bin/bash
# Helper script for the qemu-kvm/libvirt/cockpit/firefox container (AlmaLinux 10)
# Supported hosts: Windows + WSL2 (WSLg) / physical AlmaLinux 10 + GNOME (Wayland) / headless (cockpit only)
#   ./kvm.sh build            build the image
#   ./kvm.sh up               start the container (systemd inside; cockpit at https://localhost:9090)
#   ./kvm.sh down             stop and remove the container (VM data stays in KVM_DATA_DIR on the host)
#   ./kvm.sh firefox          open cockpit in the container's firefox on the host display
#   ./kvm.sh virt-manager     show virt-manager on the host display
#   ./kvm.sh viewer <VM>      show a VM's screen with virt-viewer on the host display
#   ./kvm.sh virsh ...        run virsh inside the container
#   ./kvm.sh shell            root shell inside the container
#   ./kvm.sh logs             GUI application logs
#   ./kvm.sh clean            remove the container and everything under KVM_DATA_DIR (asks for confirmation)
#   ./kvm.sh install-service  register as a root Quadlet (/etc/containers/systemd/kvm-container.container)
#                             (to start with sudo systemctl start kvm-container after logging in to GNOME)
#   ./kvm.sh uninstall-service  unregister the service above
#   ./kvm.sh prepare          run only the up preparation (kvm module, image, data directories); for the Quadlet ExecStartPre
#   ./kvm.sh install-desktop  install .desktop entries, icons and a sudoers rule to launch from the Activities overview
#   ./kvm.sh uninstall-desktop  remove the above
#   ./kvm.sh launch <app>     used by the .desktop entries (firefox|virt-manager): runs via sudo -n, reports failures as desktop notifications
# Environment variables:
#   KVM_HOST=auto|wsl|generic|headless  override host type detection
#   COCKPIT_BIND=127.0.0.1  COCKPIT_PORT=9090  cockpit bind address/port (use 0.0.0.0 to reach it from other PCs)
#   KVM_SOFTWARE_GL=1       force software rendering
#   HOST_UID / HOST_GID     uid/gid of the GUI user (admin) inside the container (default: the invoking user)
#   KVM_DATA_DIR=./data     host directory for persistent data (bind-mounts var-libvirt / etc-libvirt / home)
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=${IMAGE:-localhost/qemu-kvm-cockpit:latest}
CONTAINER=${CONTAINER:-kvm}   # not NAME: WSL uses NAME for the hostname
# when run as root (e.g. from the Quadlet ExecStartPre) do not go through sudo
if [ "$(id -u)" = 0 ]; then SUDO=; PODMAN=${PODMAN:-podman}; else SUDO=sudo; PODMAN=${PODMAN:-"sudo podman"}; fi
KVM_HOST=${KVM_HOST:-auto}
COCKPIT_BIND=${COCKPIT_BIND:-127.0.0.1}
COCKPIT_PORT=${COCKPIT_PORT:-9090}
HOST_UID=${HOST_UID:-$(id -u)}
HOST_GID=${HOST_GID:-$(id -g)}
KVM_DATA_DIR=${KVM_DATA_DIR:-$PWD/data}
case "$KVM_DATA_DIR" in /*) ;; *) KVM_DATA_DIR=$PWD/$KVM_DATA_DIR ;; esac   # a relative path would be taken by podman as a named volume
QUADLET_FILE=/etc/containers/systemd/kvm-container.container   # Quadlet installed by install-service (-> kvm-container.service)
QUADLET_TEMPLATE=$PWD/quadlet/kvm-container.container          # its template (@...@ placeholders and the # @GUI@ / # @UNIT_DEPS@ marker lines are replaced)
QUADLET_DEPS=$PWD/quadlet/user-runtime-dir.conf                # lines inserted at # @UNIT_DEPS@ (when GUI is available)
SUDOERS_FILE=/etc/sudoers.d/kvm-container                     # NOPASSWD rule installed by install-desktop (for launch)
DESKTOP_TEMPLATE_DIR=$PWD/desktop                              # templates for kvm-*.desktop / sudoers
DESKTOP_APPS="virt-manager firefox"                            # apps that get a .desktop entry (subcommand names of container/gui)
PODMAN_BIN=$(command -v podman || true)                        # absolute path written to sudoers; launch uses the same path with sudo -n so the rule matches exactly

is_wsl() {
  [ "$KVM_HOST" = wsl ] && return 0
  [ "$KVM_HOST" != auto ] && return 1
  [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

ensure_kvm() {
  if [ ! -e /dev/kvm ]; then
    command -v modprobe >/dev/null || { echo "!! modprobe not found: sudo dnf install kmod" >&2; exit 1; }
    echo ">> loading kvm module"
    if grep -q AuthenticAMD /proc/cpuinfo; then $SUDO modprobe kvm_amd; else $SUDO modprobe kvm_intel; fi
  fi
  if [ ! -e /dev/kvm ]; then
    if is_wsl; then
      echo "!! /dev/kvm not found. Set [wsl2] nestedVirtualization=true in %USERPROFILE%\\.wslconfig on the Windows side and run wsl --shutdown" >&2
    else
      echo "!! /dev/kvm not found. Enable SVM (AMD) / VT-x (Intel) in the firmware and check sudo modprobe kvm_amd or kvm_intel" >&2
    fi
    exit 1
  fi
  $SUDO chmod 666 /dev/kvm
}

# build the podman arguments (GUI_ARGS) that bring the host session (Wayland/X11/PulseAudio) into the container
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
    echo "!! XDG_RUNTIME_DIR ($rt) does not exist. Run this from a terminal inside a desktop session" >&2
    exit 1
  fi
  GUI_ARGS+=(-v "$rt:$rt" -e "XDG_RUNTIME_DIR=$rt" -e "HOST_UID=$HOST_UID" -e "HOST_GID=$HOST_GID")
  [ -n "${WAYLAND_DISPLAY:-}" ] && GUI_ARGS+=(-e "WAYLAND_DISPLAY=$WAYLAND_DISPLAY")
  if [ -n "${DISPLAY:-}" ]; then
    x11=$(readlink -f /tmp/.X11-unix 2>/dev/null || true)
    if [ -d "$x11" ]; then
      # mount read-only so that systemd-tmpfiles in the container cannot delete the host's X sockets (connecting works on a ro mount)
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

# where .desktop files / icons go (the login user's area). Not used by prepare running as root (Quadlet), so set only when needed
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
  $SUDO mkdir -p "$dir"
  if [ -n "$($SUDO ls -A "$dir")" ]; then return 0; fi
  echo ">> seeding $dir from image $src"
  # cp inside a container (with podman cp, paths declared as VOLUME show up as empty anonymous volumes)
  $PODMAN run --rm --network none -v "$dir:/mnt/seed" "$IMAGE" cp -a "$src/." /mnt/seed/
}

# preparation for up (also called from the Quadlet ExecStartPre)
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
      echo "!! $QUADLET_FILE is installed. Start with sudo systemctl start kvm-container (or remove it with ./kvm.sh uninstall-service)" >&2
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
          echo ">> to reach it from other PCs (firewalld): sudo firewall-cmd --add-service=cockpit --permanent && sudo firewall-cmd --reload"
        else
          echo ">> ready. cockpit: https://$COCKPIT_BIND:$COCKPIT_PORT  (user: admin / pass: admin)"
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
          echo ">> to be removed: $KVM_DATA_DIR"; $SUDO du -sh "$KVM_DATA_DIR"/* 2>/dev/null || true
          if [ "${KVM_CLEAN_YES:-0}" != 1 ]; then
            read -r -p "This deletes the VM disks and definitions as well. Continue? [y/N] " ans
            [ "$ans" = y ] || [ "$ans" = Y ] || { echo ">> aborted"; exit 1; }
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
    # register as a root Quadlet (.container). In a GNOME (Wayland) session the environment is fixed once the user and
    # desktop are known (/run/user/<uid>, wayland-0, :0, pulse/native), so read it from the current session and bake it in.
    # XAUTHORITY is the only value that changes per session, so it is left out; gui inside the container finds it at run time.
    [ "$(id -u)" != 0 ] || { echo "!! run this without sudo, as the user logged in to GNOME (the session environment is read from it)" >&2; exit 1; }
    [ -r "$QUADLET_TEMPLATE" ] && [ -r "$QUADLET_DEPS" ] || { echo "!! template $QUADLET_TEMPLATE / $QUADLET_DEPS not found" >&2; exit 1; }
    gui_args
    uid=$(id -u)
    tmp=$(mktemp); tmp_gui=$(mktemp); tmp_deps=$(mktemp)
    trap 'rm -f "$tmp" "$tmp_gui" "$tmp_deps"' EXIT
    # turn the -v / -e options from gui_args into Quadlet Volume= / Environment= lines
    i=0
    while [ $i -lt ${#GUI_ARGS[@]} ]; do
      opt=${GUI_ARGS[$i]}; val=${GUI_ARGS[$((i+1))]}
      case "$opt:$val" in
        -e:XAUTHORITY=*) ;;                                 # changes per session -> gui inside the container finds it at run time
        -v:"${XAUTHORITY:-/nonexistent}:"*) ;;
        -e:*) echo "Environment=$val" >>"$tmp_gui" ;;
        -v:*) echo "Volume=$val" >>"$tmp_gui" ;;
      esac
      i=$((i+2))
    done
    # /run/user/<uid> (tmpfs) is created by logind at login. If it exists first, sockets created after login are visible in the container too
    if grep -q "^Volume=/run/user/$uid:" "$tmp_gui"; then
      sed "s|@UID@|$uid|g" "$QUADLET_DEPS" >"$tmp_deps"
    fi
    sed -e "s|@CONTAINER@|$CONTAINER|g" -e "s|@IMAGE@|$IMAGE|g" \
        -e "s|@COCKPIT_BIND@|$COCKPIT_BIND|g" -e "s|@COCKPIT_PORT@|$COCKPIT_PORT|g" \
        -e "s|@KVM_DATA_DIR@|$KVM_DATA_DIR|g" -e "s|@TZ@|${TZ:-Asia/Tokyo}|g" -e "s|@KVM_SH@|$PWD/kvm.sh|g" \
        -e "/^# @UNIT_DEPS@\$/{r $tmp_deps" -e 'd' -e '}' \
        -e "/^# @GUI@\$/{r $tmp_gui" -e 'd' -e '}' \
        "$QUADLET_TEMPLATE" >"$tmp"
    if grep -q '@[A-Z_]*@' "$tmp"; then echo "!! unreplaced placeholders remain in the template: $(grep -o '@[A-Z_]*@' "$tmp" | sort -u | tr '\n' ' ')" >&2; exit 1; fi
    sudo install -m 0644 -o root -g root -D "$tmp" "$QUADLET_FILE"
    sudo systemctl daemon-reload
    if ! sudo systemctl cat kvm-container.service >/dev/null 2>&1; then
      echo "!! Quadlet did not generate kvm-container.service (podman 4.4 or later is required)." >&2
      echo "   check the error with sudo /usr/lib/systemd/system-generators/podman-system-generator --dryrun" >&2
      exit 1
    fi
    echo ">> installed: $QUADLET_FILE"
    [ -s "$tmp_gui" ] || echo ">> (no GUI: no session environment, cockpit only. Run from a terminal logged in to GNOME to get the GUI)"
    echo ">> start:     sudo systemctl start kvm-container     (likewise stop / status / restart)"
    echo ">> logs:      journalctl -u kvm-container"
    echo ">> note:      after logging out of / back in to GNOME, run sudo systemctl restart kvm-container"
    ;;
  uninstall-service)
    $SUDO systemctl stop kvm-container.service 2>/dev/null || true
    $SUDO rm -f "$QUADLET_FILE"
    $SUDO systemctl daemon-reload
    echo ">> removed: $QUADLET_FILE"
    ;;
  launch)
    # for .desktop entries (Activities). There is no terminal to ask for the sudo password, so run with sudo -n only the fixed
    # command (podman exec <container> gui <app>) that exactly matches the NOPASSWD rule installed by install-desktop
    app=${1:-}
    case "$app" in firefox|virt-manager) ;; *) echo "usage: $0 launch firefox|virt-manager" >&2; exit 1 ;; esac
    [ -n "$PODMAN_BIN" ] || { launch_error "podman not found (sudo dnf install podman)"; exit 1; }
    if [ -e "$QUADLET_FILE" ] && ! systemctl -q is-active kvm-container.service 2>/dev/null; then
      # if the Quadlet is installed but not running, start it via polkit (on GNOME a password dialog appears, once per login)
      systemctl start kvm-container.service \
        || { launch_error "could not start the kvm-container service. Run sudo systemctl start kvm-container in a terminal"; exit 1; }
    fi
    if ! err=$(sudo -n "$PODMAN_BIN" exec "$CONTAINER" gui "$app" 2>&1); then
      case "$err" in
        *password*) hint="run ./kvm.sh install-desktop (the sudoers NOPASSWD rule is missing)" ;;
        *)          hint="check that the container is running (./kvm.sh up or sudo systemctl start kvm-container)" ;;
      esac
      launch_error "could not start $app: $err"$'\n'"$hint"
      exit 1
    fi
    ;;
  install-desktop)
    # make the apps launchable from the Activities overview: install .desktop entries, icons and a sudoers NOPASSWD rule
    [ "$(id -u)" != 0 ] || { echo "!! run this without sudo, as the user logged in to the desktop" >&2; exit 1; }
    [ -n "$PODMAN_BIN" ] || { echo "!! podman not found" >&2; exit 1; }
    desktop_dirs
    $PODMAN image exists "$IMAGE" || "$0" build
    # 1) sudoers: allow only the fixed commands used by launch without a password. sudo ignores file names containing '.',
    #    so write to .tmp first, check the syntax with visudo, then rename to the final name
    tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
    sed -e "s|@USER@|$(id -un)|g" -e "s|@PODMAN@|$PODMAN_BIN|g" -e "s|@CONTAINER@|$CONTAINER|g" "$DESKTOP_TEMPLATE_DIR/sudoers" >"$tmp"
    if grep -q '@[A-Z_]*@' "$tmp"; then echo "!! unreplaced placeholders remain in the template: $(grep -o '@[A-Z_]*@' "$tmp" | sort -u | tr '\n' ' ')" >&2; exit 1; fi
    sudo install -m 0440 -o root -g root -D "$tmp" "$SUDOERS_FILE.tmp"
    sudo visudo -cf "$SUDOERS_FILE.tmp" >/dev/null || { sudo rm -f "$SUDOERS_FILE.tmp"; echo "!! sudoers syntax error" >&2; exit 1; }
    sudo mv -f "$SUDOERS_FILE.tmp" "$SUDOERS_FILE"
    # 2) icons: extract only the virt-manager / firefox icons from hicolor in the image (a generic icon is shown if this fails)
    mkdir -p "$ICON_DIR" "$DESKTOP_DIR"
    (set +o pipefail
     $PODMAN run --rm --network none "$IMAGE" sh -c \
       'cd /usr/share/icons && find hicolor -type f \( -path "*/apps/virt-manager.*" -o -path "*/apps/firefox.*" \) | tar -cf - -T -' \
       | tar -xf - -C "$ICON_DIR") 2>/dev/null || true
    # 3) .desktop entries (skip the virt-manager entry when the image has no virt-manager, i.e. not available from EPEL)
    for app in $DESKTOP_APPS; do
      if [ "$app" = virt-manager ] && ! $PODMAN run --rm --network none "$IMAGE" test -x /usr/bin/virt-manager; then
        echo ">> virt-manager is not in the image; skipping kvm-virt-manager.desktop"; continue
      fi
      sed "s|@KVM_SH@|$PWD/kvm.sh|g" "$DESKTOP_TEMPLATE_DIR/kvm-$app.desktop" >"$DESKTOP_DIR/kvm-$app.desktop"
      ls "$ICON_DIR"/hicolor/*/apps/"$app".* >/dev/null 2>&1 || echo ">> (could not extract the $app icon; a generic icon will be shown)"
    done
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$DESKTOP_DIR" || true
    echo ">> installed: $DESKTOP_DIR/kvm-*.desktop, $ICON_DIR/hicolor/*/apps/, $SUDOERS_FILE"
    echo ">> search for \"Virtual Machine Manager\" / \"Firefox\" in the Activities overview to launch them (keep the container running;"
    echo ">>  if install-service is set up, launch tries systemctl start when it is not running and polkit shows a password dialog)"
    ;;
  uninstall-desktop)
    [ "$(id -u)" != 0 ] || { echo "!! run this without sudo, as the user who ran install-desktop" >&2; exit 1; }
    desktop_dirs
    for app in $DESKTOP_APPS; do rm -f "$DESKTOP_DIR/kvm-$app.desktop" "$ICON_DIR"/hicolor/*/apps/"$app".*; done
    sudo rm -f "$SUDOERS_FILE"
    echo ">> removed: $DESKTOP_DIR/kvm-*.desktop, $ICON_DIR/hicolor/*/apps/{virt-manager,firefox}.*, $SUDOERS_FILE"
    ;;
  *)      sed -n '2,26p' "$0" ;;
esac
