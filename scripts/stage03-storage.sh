#!/usr/bin/env bash
# Stage03 Milestone 3.5: create Btrfs on the opened LUKS mapper.
#
# This stage uses the LUKS mapper opened by Milestone 3.4 and creates the Btrfs
# root filesystem, its standard subvolumes, and the final /mnt mounts. It never
# repartitions disks, recreates LUKS, changes bootloader state, or installs
# packages.

set -euo pipefail

STAGE03_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE03_LIB_DIR="${STAGE03_DIR}/lib"

# shellcheck source=lib/common.sh
source "${STAGE03_LIB_DIR}/common.sh"
# shellcheck source=lib/logging.sh
source "${STAGE03_LIB_DIR}/logging.sh"
# shellcheck source=lib/config.sh
source "${STAGE03_LIB_DIR}/config.sh"
# shellcheck source=lib/hardware.sh
source "${STAGE03_LIB_DIR}/hardware.sh"
# shellcheck source=lib/disk-btrfs.sh
source "${STAGE03_LIB_DIR}/disk-btrfs.sh"

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_arch_live_iso() {
  require_arch_live_or_arch

  [[ -d /run/archiso ]] || \
    die "Stage03 debe ejecutarse desde el Arch Linux Live ISO oficial."
}

require_stage03_commands() {
  require_command lsblk awk findmnt realpath sfdisk cryptsetup blkid mkfs.btrfs btrfs mount umount
}

require_stage03_target_disk() {
  [[ -n "${TARGET_DISK:-}" ]] || \
    die "TARGET_DISK no esta configurado. Ejecuta Stage02 antes de Stage03."
}

validate_stage03_target_disk() {
  require_stage03_target_disk

  if ! hardware_disk_in_inventory "${TARGET_DISK}"; then
    die "El disco seleccionado durante Stage02 ya no esta disponible en el inventario actual: ${TARGET_DISK}"
  fi

  hardware_validate_installable_disk "${TARGET_DISK}"
}

show_stage03_disk_review() {
  log_section "Revision del disco seleccionado"
  hardware_show_disk_details "${TARGET_DISK}"
  hardware_warn_if_removable_disk "${TARGET_DISK}"
  hardware_warn_if_live_iso_disk "${TARGET_DISK}"
  hardware_warn_if_disk_has_mounts "${TARGET_DISK}"
}

stage03_mapped_device() {
  mapper_path "${CRYPT_NAME}"
}

precheck_stage03_btrfs() {
  local luks_part
  local mapped_device

  log_section "Prechecks Btrfs"
  luks_part="$(luks_partition "${TARGET_DISK}")"
  mapped_device="$(stage03_mapped_device)"

  verify_final_partition_layout "${TARGET_DISK}" "${EFI_SIZE}"
  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  require_active_btrfs_mapper "${mapped_device}"

  log_kv "Particion LUKS" "${luks_part}"
  log_kv "Mapper activo" "${mapped_device}"
  log_kv "Compresion Btrfs" "${BTRFS_COMPRESS}"
  log_kv "Etiqueta Btrfs" "${BTRFS_LABEL}"
}

run_stage03_btrfs() {
  local mapped_device

  mapped_device="$(stage03_mapped_device)"
  create_btrfs "${mapped_device}" "${BTRFS_LABEL}"
  create_btrfs_subvolumes "${mapped_device}" /mnt
  mount_btrfs_subvolumes "${mapped_device}" /mnt
  verify_btrfs_subvolume_mounts /mnt
  show_btrfs_mount_summary /mnt
}

install_stage03_btrfs_cleanup_trap() {
  trap 'cleanup_btrfs_mounts_on_failure /mnt; on_error "$LINENO" "$BASH_COMMAND"' ERR
}

clear_stage03_btrfs_cleanup_trap() {
  trap - ERR
}

restore_stage03_default_error_trap() {
  trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
}

run_stage03_btrfs_with_cleanup() {
  install_stage03_btrfs_cleanup_trap
  run_stage03_btrfs
  clear_stage03_btrfs_cleanup_trap
  restore_stage03_default_error_trap
}

show_stage03_summary() {
  local luks_part
  local mapped_device

  luks_part="$(luks_partition "${TARGET_DISK}")"
  mapped_device="$(stage03_mapped_device)"

  log_section "Resumen Stage03"
  log_kv "Particion LUKS" "${luks_part}"
  log_kv "LUKS UUID" "$(luks_uuid "${luks_part}")"
  log_kv "Mapper" "${mapped_device}"
  log_kv "Estado mapper" "$(mapper_is_active "${CRYPT_NAME}" && printf 'active' || printf 'inactive')"
  log_kv "Btrfs UUID" "$(btrfs_uuid "${mapped_device}")"
  log_kv "Etiqueta Btrfs" "${BTRFS_LABEL}"
  log_kv "Punto raiz" "/mnt"
  success "Stage03 Milestone 3.5 completado. Btrfs creado y montado correctamente."
}

main() {
  log_section "Stage03 - Btrfs"
  require_root
  require_arch_live_iso
  require_uefi
  require_stage03_commands

  log_step "Cargando configuracion"
  load_install_config
  validate_install_config
  success "Configuracion cargada y validada."

  log_step "Actualizando inventario de discos"
  hardware_refresh_disk_inventory
  [[ "$(hardware_disk_count)" -gt 0 ]] || die "No se detectaron discos instalables."

  validate_stage03_target_disk
  show_stage03_disk_review
  precheck_stage03_btrfs
  run_stage03_btrfs_with_cleanup
  show_stage03_summary
}

main "$@"
