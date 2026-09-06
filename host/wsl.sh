# WSL2 (WSLg) specifics for kvm.sh. kvm.sh sources this file unconditionally, after defining the generic host_* hooks;
# the hooks are overridden only when WSL2 is detected, so nothing in here affects other hosts.
# KVM_HOST=wsl forces WSL2 mode, KVM_HOST=generic|headless disables the detection (auto: detect)

is_wsl() {
  [ "$KVM_HOST" = wsl ] && return 0
  [ "$KVM_HOST" != auto ] && return 1
  [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

if is_wsl; then
  # /dev/kvm is still missing after modprobe: nested virtualization is disabled on the Windows side
  host_kvm_missing_hint() {
    echo "!! /dev/kvm not found. Set [wsl2] nestedVirtualization=true in %USERPROFILE%\\.wslconfig on the Windows side and run wsl --shutdown" >&2
  }
  # WSLg keeps the Wayland/PulseAudio sockets here; /run/user/<uid> only holds symlinks to them and XDG_RUNTIME_DIR may be unset
  host_default_runtime_dir() { echo /mnt/wslg/runtime-dir; }
  # WSL exposes no /dev/dri (no GPU passthrough), so always render in software
  host_force_software_gl() { return 0; }
fi
