#!/usr/bin/env bash
# Stage04 Milestone 4.4: bootstrap, fstab, and target base configuration.
#
# This stage validates the mounted target and installs only the base package set
# with pacstrap, generates /mnt/etc/fstab atomically, and orchestrates the base
# target configuration through chroot.sh helpers. It does not configure
# passwords, shell customization, Secure Boot, bootloader, services, NVIDIA, or
# desktop components.

set -euo pipefail

STAGE04_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE04_LIB_DIR="${STAGE04_DIR}/lib"
STAGE04_TARGET_ROOT="${STAGE04_TARGET_ROOT:-/mnt}"
STAGE04_STATE_DIR="${STAGE04_STATE_DIR:-${STAGE04_DIR}/../state}"
STAGE04_BOOTSTRAP_PACKAGES_FILE="${STAGE04_BOOTSTRAP_PACKAGES_FILE:-${STAGE04_STATE_DIR}/bootstrap-packages.txt}"
STAGE04_BOOTSTRAP_SECONDS=0

# shellcheck source=lib/common.sh
source "${STAGE04_LIB_DIR}/common.sh"
# shellcheck source=lib/logging.sh
source "${STAGE04_LIB_DIR}/logging.sh"
# shellcheck source=lib/config.sh
source "${STAGE04_LIB_DIR}/config.sh"
# shellcheck source=lib/hardware.sh
source "${STAGE04_LIB_DIR}/hardware.sh"
# shellcheck source=lib/packages.sh
source "${STAGE04_LIB_DIR}/packages.sh"
# shellcheck source=lib/fstab.sh
source "${STAGE04_LIB_DIR}/fstab.sh"
# shellcheck source=lib/chroot.sh
source "${STAGE04_LIB_DIR}/chroot.sh"

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_arch_live_iso() {
  require_arch_live_or_arch

  [[ -d /run/archiso ]] || \
    die "Stage04 debe ejecutarse desde el Arch Linux Live ISO oficial."
}

require_stage04_commands() {
  require_command findmnt pacstrap awk df date pacman genfstab arch-chroot
}

require_target_root_mounted() {
  local target_root="$1"

  require_directory "${target_root}"
  is_mounted "${target_root}" || die "${target_root} no esta montado."
  success "${target_root} esta montado."
}

require_btrfs_root_subvolume_mounted() {
  local target_root="$1"
  local fstype
  local options

  fstype="$(findmnt -no FSTYPE --target "${target_root}" 2>/dev/null || true)"
  options="$(findmnt -no OPTIONS --target "${target_root}" 2>/dev/null || true)"

  [[ "${fstype}" == "btrfs" ]] || die "${target_root} no esta montado como Btrfs."

  case ",${options}," in
    *",subvol=@,"*|*",subvol=/@,"*) ;;
    *) die "${target_root} no esta montado con el subvolumen raiz @." ;;
  esac

  success "Subvolumen raiz Btrfs @ montado en ${target_root}."
}

require_efi_partition_mounted() {
  local target_root="$1"
  local efi_mount="${target_root}/boot"
  local fstype

  require_directory "${efi_mount}"
  fstype="$(findmnt -no FSTYPE --target "${efi_mount}" 2>/dev/null || true)"

  case "${fstype}" in
    vfat|fat|msdos) ;;
    *) die "La particion EFI no esta montada en ${efi_mount} como FAT/VFAT." ;;
  esac

  success "Particion EFI montada en ${efi_mount}."
}

require_network_for_bootstrap() {
  detect_network_available || die "No hay conectividad real hacia archlinux.org para ejecutar pacstrap."
  success "Conectividad de red verificada."
}

require_target_free_space() {
  local target_root="$1"
  local minimum_kib=$((8 * 1024 * 1024))
  local available_kib

  available_kib="$(df -Pk "${target_root}" | awk 'NR == 2 { print $4 }')"
  [[ -n "${available_kib}" ]] || die "No se pudo determinar el espacio libre en ${target_root}."
  [[ "${available_kib}" =~ ^[0-9]+$ ]] || die "Espacio libre invalido reportado por df: ${available_kib}"
  [[ "${available_kib}" -ge "${minimum_kib}" ]] || \
    die "Espacio libre insuficiente en ${target_root}: se requieren al menos 8 GiB."

  success "Espacio libre verificado en ${target_root}: $((available_kib / 1024 / 1024)) GiB disponibles."
}

confirm_reinstall_if_existing_arch() {
  local target_root="$1"
  local os_release="${target_root}/etc/os-release"

  [[ -e "${os_release}" ]] || return 0

  log_warn "Se detecto una instalacion previa en ${target_root}: ${os_release}"
  log_warn "Continuar puede sobrescribir paquetes y archivos del sistema existente."
  confirm_yes_no "Confirmas que quieres reinstalar el bootstrap sobre este target?" || \
    die "Stage04 abortado limpiamente por instalacion previa detectada."
}

verify_stage04_preconditions() {
  log_section "Validaciones previas a pacstrap"
  require_target_root_mounted "${STAGE04_TARGET_ROOT}"
  require_btrfs_root_subvolume_mounted "${STAGE04_TARGET_ROOT}"
  require_efi_partition_mounted "${STAGE04_TARGET_ROOT}"
  require_target_free_space "${STAGE04_TARGET_ROOT}"
  confirm_reinstall_if_existing_arch "${STAGE04_TARGET_ROOT}"
  require_network_for_bootstrap
  require_command pacstrap
  verify_pacman_repositories_reachable
  success "Precondiciones de bootstrap completadas."
}

verify_bootstrap_installation() {
  local target_root="$1"

  log_section "Verificacion del sistema base"
  require_readable_file "${target_root}/etc/os-release"
  require_file "${target_root}/usr/bin/bash"
  require_file "${target_root}/usr/bin/pacman"
  require_readable_file "${target_root}/etc/pacman.conf"
  require_directory "${target_root}/usr/lib/systemd"
  require_directory "${target_root}/etc"
  require_directory "${target_root}/boot"
  success "Sistema base verificado en ${target_root}."
}

show_stage04_bootstrap_summary() {
  log_section "Resumen Stage04"
  log_kv "Target root" "${STAGE04_TARGET_ROOT}"
  log_kv "Root subvolume" "@"
  log_kv "EFI mount" "${STAGE04_TARGET_ROOT}/boot"
  log_kv "Paquetes" "${STAGE04_BOOTSTRAP_PACKAGES_FILE}"
  log_kv "fstab" "$(target_fstab_path "${STAGE04_TARGET_ROOT}")"
  log_kv "Hostname" "${HOSTNAME}"
  log_kv "Timezone" "${TIMEZONE}"
  log_kv "Locale" "${LOCALE}"
  log_kv "Keymap" "${KEYMAP}"
  log_kv "Usuario" "${USERNAME}"
  log_kv "Microcode" "$(detect_microcode_package)"
  log_kv "Duracion pacstrap" "${STAGE04_BOOTSTRAP_SECONDS}s"
  success "Stage04 Milestone 4.4 completado. Configuracion base aplicada; no se configuro bootloader, Secure Boot, servicios, NVIDIA ni escritorio."
}

write_stage04_bootstrap_package_list() {
  create_directory "${STAGE04_STATE_DIR}" 0700
  write_bootstrap_package_list "${STAGE04_BOOTSTRAP_PACKAGES_FILE}"
}

run_stage04_pacstrap() {
  local start_time
  local end_time

  log_section "Pacstrap"
  start_time="$(date +%s)"
  pacstrap_bootstrap_package_file "${STAGE04_TARGET_ROOT}" "${STAGE04_BOOTSTRAP_PACKAGES_FILE}"
  end_time="$(date +%s)"
  STAGE04_BOOTSTRAP_SECONDS="$((end_time - start_time))"
}

configure_stage04_target_system() {
  log_section "Configuracion base del target"

  log_step "Aplicando configuracion base desde chroot.sh"
  configure_target_base_system "${STAGE04_TARGET_ROOT}"
  success "Configuracion base del target completada."
}

main() {
  log_section "Stage04 - Bootstrap"
  require_root
  require_arch_live_iso
  require_uefi
  require_stage04_commands

  log_step "Cargando configuracion"
  load_install_config
  validate_install_config
  success "Configuracion cargada y validada."

  verify_stage04_preconditions
  write_stage04_bootstrap_package_list
  show_bootstrap_package_file "${STAGE04_BOOTSTRAP_PACKAGES_FILE}"

  run_stage04_pacstrap

  verify_bootstrap_installation "${STAGE04_TARGET_ROOT}"
  configure_target_fstab "${STAGE04_TARGET_ROOT}"
  configure_stage04_target_system
  show_stage04_bootstrap_summary
}

main "$@"
