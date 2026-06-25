#!/usr/bin/env bash
# Passive verification helpers for the Arch workstation installer.
#
# This library reports PASS/WARN/FAIL checks. It must not install packages,
# modify files, repair configuration, partition disks, or change the target.

set -euo pipefail

VERIFY_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F die >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${VERIFY_LIB_DIR}/common.sh"
fi

if ! declare -F log_section >/dev/null 2>&1; then
  # shellcheck source=logging.sh
  source "${VERIFY_LIB_DIR}/logging.sh"
fi

if ! declare -F validate_install_config >/dev/null 2>&1; then
  # shellcheck source=config.sh
  source "${VERIFY_LIB_DIR}/config.sh"
fi

if ! declare -F detect_secure_boot >/dev/null 2>&1; then
  # shellcheck source=hardware.sh
  source "${VERIFY_LIB_DIR}/hardware.sh"
fi

if ! declare -F arch_chroot_run >/dev/null 2>&1; then
  # shellcheck source=chroot.sh
  source "${VERIFY_LIB_DIR}/chroot.sh"
fi

if ! declare -F detect_setup_mode >/dev/null 2>&1; then
  # shellcheck source=secureboot.sh
  source "${VERIFY_LIB_DIR}/secureboot.sh"
fi

VERIFY_PASS_COUNT=0
VERIFY_WARN_COUNT=0
VERIFY_FAIL_COUNT=0

reset_verify_counters() {
  VERIFY_PASS_COUNT=0
  VERIFY_WARN_COUNT=0
  VERIFY_FAIL_COUNT=0
}

verify_pass() {
  local message="$1"

  VERIFY_PASS_COUNT=$((VERIFY_PASS_COUNT + 1))
  printf '%s[PASS]%s %s\n' "${COLOR_GREEN}" "${COLOR_RESET}" "${message}"
}

verify_warn() {
  local message="$1"

  VERIFY_WARN_COUNT=$((VERIFY_WARN_COUNT + 1))
  printf '%s[WARN]%s %s\n' "${COLOR_YELLOW}" "${COLOR_RESET}" "${message}"
}

verify_fail() {
  local message="$1"

  VERIFY_FAIL_COUNT=$((VERIFY_FAIL_COUNT + 1))
  printf '%s[FAIL]%s %s\n' "${COLOR_RED}" "${COLOR_RESET}" "${message}"
}

target_file_exists() {
  local target_root="$1"
  local path="$2"

  [[ -e "$(target_path "${target_root}" "${path}")" ]]
}

target_file_executable() {
  local target_root="$1"
  local path="$2"

  [[ -x "$(target_path "${target_root}" "${path}")" ]]
}

target_package_installed() {
  local target_root="$1"
  local package_name="$2"

  validate_arch_target_root "${target_root}"
  require_command arch-chroot
  arch_chroot_run "${target_root}" pacman -Q "${package_name}" >/dev/null 2>&1
}

target_has_lts_modules() {
  local target_root="$1"
  local modules_dir
  local module_dir

  modules_dir="$(target_path "${target_root}" /usr/lib/modules)"
  [[ -d "${modules_dir}" ]] || return 1

  for module_dir in "${modules_dir}"/*-lts; do
    [[ -d "${module_dir}" ]] && return 0
  done

  return 1
}

linux_lts_required_by_config() {
  is_yes "${INSTALL_LINUX_LTS:-no}" ||
    is_yes "${INSTALL_LTS_KERNEL:-no}" ||
    is_yes "${REQUIRE_LINUX_LTS:-no}" ||
    is_yes "${ENABLE_LINUX_LTS:-no}"
}

linux_lts_expected() {
  local target_root="$1"

  linux_lts_required_by_config && return 0
  target_package_installed "${target_root}" linux-lts && return 0
  target_has_lts_modules "${target_root}" && return 0

  return 1
}

verify_uefi() {
  if is_uefi_booted; then
    verify_pass "UEFI detectado"
  else
    verify_fail "UEFI no detectado"
  fi
}

verify_secure_boot_state() {
  local status

  status="$(detect_secure_boot)"
  case "${status}" in
    enabled) verify_pass "Secure Boot habilitado" ;;
    disabled) verify_warn "Secure Boot deshabilitado actualmente" ;;
    unsupported) verify_fail "Secure Boot no soportado: no hay UEFI" ;;
    *) verify_warn "Secure Boot desconocido" ;;
  esac
}

verify_setup_mode_state() {
  local status

  status="$(detect_setup_mode)"
  case "${status}" in
    enabled) verify_warn "Setup Mode habilitado" ;;
    disabled) verify_pass "Setup Mode deshabilitado" ;;
    unsupported) verify_fail "Setup Mode no soportado: no hay UEFI" ;;
    *) verify_warn "Setup Mode desconocido" ;;
  esac
}

verify_sbctl_status() {
  local target_root="${1:-${TARGET_ROOT}}"

  if ! target_has_sbctl "${target_root}"; then
    verify_fail "sbctl no instalado en target"
    return 0
  fi

  if arch_chroot_run "${target_root}" sbctl status >/dev/null 2>&1; then
    verify_pass "sbctl status ejecuta correctamente"
  else
    verify_warn "sbctl status devolvio error"
  fi
}

verify_sbctl_signatures() {
  local target_root="${1:-${TARGET_ROOT}}"

  if ! target_has_sbctl "${target_root}"; then
    verify_fail "No se puede ejecutar sbctl verify: sbctl no instalado"
    return 0
  fi

  if arch_chroot_run "${target_root}" sbctl verify >/dev/null 2>&1; then
    verify_pass "sbctl verify correcto"
  else
    verify_fail "sbctl verify reporta firmas faltantes o invalidas"
  fi
}

verify_luks2() {
  local device="${1:-}"
  local type

  if [[ -z "${device}" ]]; then
    verify_warn "LUKS2 no verificado: no se paso dispositivo"
    return 0
  fi

  if ! command_exists cryptsetup; then
    verify_warn "cryptsetup no disponible para verificar LUKS2"
    return 0
  fi

  type="$(cryptsetup luksDump "${device}" 2>/dev/null | awk -F: '/Version/ {gsub(/[[:space:]]+/, "", $2); print $2; exit}' || true)"
  if [[ "${type}" == "2" ]]; then
    verify_pass "LUKS2 detectado en ${device}"
  else
    verify_fail "No se detecto LUKS2 en ${device}"
  fi
}

verify_btrfs_root() {
  local target_root="${1:-${TARGET_ROOT}}"
  local fstype

  fstype="$(findmnt -no FSTYPE --target "${target_root}" 2>/dev/null || true)"
  if [[ "${fstype}" == "btrfs" ]]; then
    verify_pass "Root target montado como Btrfs"
  else
    verify_fail "Root target no esta montado como Btrfs"
  fi
}

verify_btrfs_subvolumes() {
  local target_root="${1:-${TARGET_ROOT}}"
  local subvol
  local path

  for subvol in / /home /var /var/log /var/cache /.snapshots; do
    path="${target_root%/}${subvol}"
    if [[ "$(findmnt -no FSTYPE --target "${path}" 2>/dev/null || true)" == "btrfs" ]]; then
      verify_pass "Subvolumen Btrfs montado: ${subvol}"
    else
      verify_fail "Subvolumen Btrfs no montado: ${subvol}"
    fi
  done
}

verify_efi_mount() {
  local target_root="${1:-${TARGET_ROOT}}"
  local boot_path
  local fstype

  boot_path="${target_root%/}/boot"
  fstype="$(findmnt -no FSTYPE --target "${boot_path}" 2>/dev/null || true)"
  if [[ "${fstype}" == "vfat" ]]; then
    verify_pass "EFI montada en /boot"
  else
    verify_fail "EFI no esta montada como vfat en /boot"
  fi
}

verify_target_fstab_no_live_iso_entries() {
  local target_root="${1:-${TARGET_ROOT}}"
  local fstab_file

  fstab_file="$(target_path "${target_root}" /etc/fstab)"
  if [[ ! -r "${fstab_file}" ]]; then
    verify_fail "fstab no es legible en target"
    return 0
  fi

  if grep -Eq '(/hgfs|hgfs|vmhgfs|fuse[.]vmhgfs-fuse)' "${fstab_file}"; then
    verify_fail "fstab contiene entradas heredadas del Live ISO hgfs/vmhgfs"
  else
    verify_pass "fstab sin entradas hgfs/vmhgfs heredadas del Live ISO"
  fi
}

verify_kernels_and_initramfs() {
  local target_root="${1:-${TARGET_ROOT}}"

  target_file_exists "${target_root}" /boot/vmlinuz-linux && verify_pass "Kernel linux existe" || verify_fail "Falta /boot/vmlinuz-linux"
  target_file_exists "${target_root}" /boot/initramfs-linux.img && verify_pass "Initramfs linux existe" || verify_fail "Falta /boot/initramfs-linux.img"

  if linux_lts_expected "${target_root}"; then
    target_file_exists "${target_root}" /boot/vmlinuz-linux-lts && verify_pass "Kernel linux-lts existe" || verify_fail "Falta /boot/vmlinuz-linux-lts"
    target_file_exists "${target_root}" /boot/initramfs-linux-lts.img && verify_pass "Initramfs linux-lts existe" || verify_fail "Falta /boot/initramfs-linux-lts.img"
  else
    verify_warn "linux-lts no instalado; se omite verificacion de kernel LTS."
  fi
}

verify_systemd_boot() {
  local target_root="${1:-${TARGET_ROOT}}"

  if target_file_exists "${target_root}" /boot/loader/loader.conf &&
    target_file_exists "${target_root}" /boot/loader/entries/arch.conf; then
    verify_pass "systemd-boot configurado"
  else
    verify_fail "systemd-boot no parece configurado"
  fi
}

verify_target_service_enabled() {
  local target_root="$1"
  local unit="$2"
  local label="$3"

  if target_service_enabled "${target_root}" "${unit}"; then
    verify_pass "${label} habilitado"
  else
    verify_warn "${label} no habilitado"
  fi
}

target_service_enabled() {
  local target_root="$1"
  local unit="$2"

  arch_chroot_run "${target_root}" systemctl is-enabled "${unit}" >/dev/null 2>&1
}

verify_network_services() {
  local target_root="${1:-${TARGET_ROOT}}"

  if is_yes "${INSTALL_NETWORK_PROFILE:-yes}"; then
    if target_service_enabled "${target_root}" NetworkManager.service; then
      verify_pass "Mecanismo de red habilitado: NetworkManager"
    elif target_service_enabled "${target_root}" systemd-networkd.service; then
      verify_pass "Mecanismo de red habilitado: systemd-networkd"
      verify_target_service_enabled "${target_root}" systemd-resolved.service "systemd-resolved"
    else
      verify_fail "No hay mecanismo de red habilitado: NetworkManager o systemd-networkd"
    fi
  else
    verify_warn "Perfil de red desactivado; se omite verificacion de red."
  fi

  if is_yes "${INSTALL_OPENSSH:-yes}"; then
    if target_service_enabled "${target_root}" sshd.service; then
      verify_pass "OpenSSH habilitado"
    else
      verify_fail "INSTALL_OPENSSH=yes pero sshd.service no esta habilitado"
    fi
  else
    verify_warn "INSTALL_OPENSSH desactivado; se omite verificacion de sshd."
  fi
}

verify_docker() {
  local target_root="${1:-${TARGET_ROOT}}"

  if target_command_exists "${target_root}" docker; then
    verify_pass "Docker instalado"
    verify_target_service_enabled "${target_root}" docker.service "Docker"
  else
    verify_warn "Docker no instalado"
  fi
}

verify_libvirt_kvm() {
  local target_root="${1:-${TARGET_ROOT}}"

  target_command_exists "${target_root}" virsh && verify_pass "libvirt instalado" || verify_warn "libvirt no instalado"
  verify_target_service_enabled "${target_root}" libvirtd.service "libvirtd"

  if [[ -e /dev/kvm ]]; then
    verify_pass "KVM disponible en /dev/kvm"
  else
    verify_warn "KVM no disponible en /dev/kvm"
  fi
}

verify_nvidia_if_installed() {
  local target_root="${1:-${TARGET_ROOT}}"
  local has_nvidia_files
  local has_nvidia_hardware
  local modeset

  if target_command_exists "${target_root}" nvidia-smi; then
    verify_pass "NVIDIA tools instaladas"
  else
    has_nvidia_files="no"
    find "$(target_path "${target_root}" /usr)" -type f \( -iname '*nvidia*.so*' -o -iname 'nvidia*.ko*' \) -print -quit 2>/dev/null | grep -q . &&
      has_nvidia_files="yes"

    if [[ "${has_nvidia_files}" == "yes" ]]; then
      verify_warn "Bibliotecas/modulos NVIDIA existen, pero nvidia-smi no esta disponible"
    fi
  fi

  has_nvidia_hardware="no"
  if detect_nvidia_gpu; then
    has_nvidia_hardware="yes"
  fi

  if [[ "${has_nvidia_hardware}" == "yes" ]] && ! target_command_exists "${target_root}" nvidia-smi; then
    verify_warn "GPU NVIDIA detectada, pero herramientas NVIDIA no estan disponibles en target"
  fi

  if lsmod 2>/dev/null | grep -q '^nvidia'; then
    verify_pass "Modulos NVIDIA cargados en el sistema actual"

    if [[ -r /sys/module/nvidia_drm/parameters/modeset ]]; then
      modeset="$(cat /sys/module/nvidia_drm/parameters/modeset)"
      case "${modeset}" in
        Y|1) verify_pass "nvidia_drm.modeset activo" ;;
        N|0) verify_warn "nvidia_drm.modeset no activo" ;;
        *) verify_warn "nvidia_drm.modeset tiene valor desconocido: ${modeset}" ;;
      esac
    else
      verify_warn "No existe /sys/module/nvidia_drm/parameters/modeset"
    fi
  elif [[ "${has_nvidia_hardware}" == "yes" ]]; then
    verify_warn "GPU NVIDIA detectada, pero modulos NVIDIA no estan cargados en el sistema actual"
  fi
}

verify_apparmor() {
  local target_root="${1:-${TARGET_ROOT}}"

  target_command_exists "${target_root}" apparmor_parser && verify_pass "AppArmor instalado" || verify_warn "AppArmor no instalado"
  verify_target_service_enabled "${target_root}" apparmor.service "AppArmor"
}

verify_nftables() {
  local target_root="${1:-${TARGET_ROOT}}"

  target_command_exists "${target_root}" nft && verify_pass "nftables instalado" || verify_warn "nftables no instalado"
  verify_target_service_enabled "${target_root}" nftables.service "nftables"
}

verify_snapper() {
  local target_root="${1:-${TARGET_ROOT}}"

  target_command_exists "${target_root}" snapper && verify_pass "Snapper instalado" || verify_warn "Snapper no instalado"
  target_file_exists "${target_root}" /etc/snapper/configs/root && verify_pass "Snapper root config existe" || verify_warn "Snapper root config no existe"
}

verify_hyprland_desktop() {
  local target_root="${1:-${TARGET_ROOT}}"
  local username="${2:-${USERNAME}}"

  if [[ "${INSTALL_DESKTOP_ENV:-none}" == "none" ]]; then
    verify_warn "INSTALL_DESKTOP_ENV=none; se omite verificacion grafica."
    return 0
  fi

  if [[ "${INSTALL_DESKTOP_ENV:-none}" != "hyprland" ]]; then
    verify_fail "INSTALL_DESKTOP_ENV no soportado en verificacion: ${INSTALL_DESKTOP_ENV}"
    return 0
  fi

  target_package_installed "${target_root}" hyprland && verify_pass "Hyprland instalado" || verify_fail "Hyprland no instalado"
  target_package_installed "${target_root}" waybar && verify_pass "Waybar instalado" || verify_fail "Waybar no instalado"
  target_package_installed "${target_root}" wofi && verify_pass "Wofi instalado" || verify_fail "Wofi no instalado"
  target_package_installed "${target_root}" kitty && verify_pass "Kitty instalado" || verify_fail "Kitty no instalado"
  target_service_enabled "${target_root}" sddm.service && verify_pass "SDDM habilitado" || verify_fail "INSTALL_DESKTOP_ENV=hyprland pero sddm.service no esta habilitado"

  target_file_executable "${target_root}" /usr/local/bin/arch-workstation-start-hyprland &&
    verify_pass "Wrapper Hyprland VMware fallback existe y es ejecutable" ||
    verify_fail "Falta wrapper ejecutable /usr/local/bin/arch-workstation-start-hyprland"

  target_file_exists "${target_root}" /usr/share/wayland-sessions/arch-workstation-hyprland.desktop &&
    verify_pass "Sesion Wayland Arch Workstation Hyprland existe" ||
    verify_fail "Falta /usr/share/wayland-sessions/arch-workstation-hyprland.desktop"

  target_file_exists "${target_root}" /etc/sddm.conf.d/10-arch-workstation.conf &&
    verify_pass "Config SDDM Arch Workstation existe" ||
    verify_fail "Falta /etc/sddm.conf.d/10-arch-workstation.conf"

  target_file_exists "${target_root}" "/home/${username}/.config/hypr/hyprland.conf" &&
    verify_pass "Config Hyprland del usuario existe" ||
    verify_fail "Falta /home/${username}/.config/hypr/hyprland.conf"

  target_file_exists "${target_root}" "/home/${username}/.config/hypr/hyprpaper.conf" &&
    verify_pass "Config hyprpaper del usuario existe" ||
    verify_fail "Falta /home/${username}/.config/hypr/hyprpaper.conf"
}

verify_summary() {
  log_section "Resumen de verificacion"
  log_kv "PASS" "${VERIFY_PASS_COUNT}"
  log_kv "WARN" "${VERIFY_WARN_COUNT}"
  log_kv "FAIL" "${VERIFY_FAIL_COUNT}"

  [[ "${VERIFY_FAIL_COUNT}" -eq 0 ]]
}

run_passive_verification() {
  local target_root="${1:-${TARGET_ROOT}}"
  local luks_device="${2:-}"

  reset_verify_counters
  validate_arch_target_root "${target_root}"

  verify_uefi
  verify_secure_boot_state
  verify_setup_mode_state
  verify_sbctl_status "${target_root}"
  verify_sbctl_signatures "${target_root}"
  verify_luks2 "${luks_device}"
  verify_btrfs_root "${target_root}"
  verify_btrfs_subvolumes "${target_root}"
  verify_efi_mount "${target_root}"
  verify_target_fstab_no_live_iso_entries "${target_root}"
  verify_kernels_and_initramfs "${target_root}"
  verify_systemd_boot "${target_root}"
  verify_network_services "${target_root}"
  verify_docker "${target_root}"
  verify_libvirt_kvm "${target_root}"
  verify_nvidia_if_installed "${target_root}"
  verify_apparmor "${target_root}"
  verify_nftables "${target_root}"
  verify_snapper "${target_root}"
  verify_hyprland_desktop "${target_root}" "${USERNAME}"
  verify_summary
}
