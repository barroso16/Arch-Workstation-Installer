#!/usr/bin/env bash
# Stage02: destructive storage preparation for the Arch workstation installer.
#
# This stage prepares the target disk as GPT + EFI + LUKS2 + Btrfs and mounts
# the Btrfs subvolumes under /mnt. It does not install packages, run pacstrap,
# enter chroot, install a bootloader, configure Secure Boot, or configure NVIDIA.

set -euo pipefail

STAGE02_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE02_LIB_DIR="${STAGE02_DIR}/lib"
STAGE02_TARGET_ROOT="${STAGE02_TARGET_ROOT:-/mnt}"
STAGE02_STATE_DIR="${STAGE02_STATE_DIR:-${STAGE02_DIR}/../state}"
STAGE02_STORAGE_STATE_FILE="${STAGE02_STORAGE_STATE_FILE:-${STAGE02_STATE_DIR}/storage.env}"
STAGE02_BTRFS_SUBVOLUMES=(
  @
  @home
  @var
  @log
  @cache
  @snapshots
)

# shellcheck source=lib/common.sh
source "${STAGE02_LIB_DIR}/common.sh"
# shellcheck source=lib/logging.sh
source "${STAGE02_LIB_DIR}/logging.sh"
# shellcheck source=lib/config.sh
source "${STAGE02_LIB_DIR}/config.sh"
# shellcheck source=lib/hardware.sh
source "${STAGE02_LIB_DIR}/hardware.sh"
# shellcheck source=lib/disk.sh
source "${STAGE02_LIB_DIR}/disk.sh"

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_arch_live_iso() {
  require_arch_live_or_arch

  [[ -d /run/archiso ]] || \
    die "Stage02 debe ejecutarse desde el Arch Linux Live ISO oficial."
}

resolve_stage02_target_disk() {
  local selected_disk

  if [[ -n "${TARGET_DISK:-}" ]]; then
    resolve_target_disk "${TARGET_DISK}"
    return 0
  fi

  read -r selected_disk
  selected_disk="$(trim "${selected_disk}")"
  resolve_target_disk "${selected_disk}"
}

show_storage_destruction_plan() {
  local disk="$1"
  local efi_part="$2"
  local luks_part="$3"
  local mapped_device="$4"
  local subvolume

  log_section "Plan de almacenamiento"
  log_warn "ACCION DESTRUCTIVA: se borrara completamente el disco seleccionado."
  log_kv "Disco a destruir" "${disk}"
  log_kv "Particion EFI resultante" "${efi_part}"
  log_kv "Particion LUKS resultante" "${luks_part}"
  log_kv "Mapper LUKS" "${mapped_device}"
  log_kv "Nombre mapper" "${CRYPT_NAME}"
  log_kv "Punto de montaje" "${STAGE02_TARGET_ROOT}"

  log_header "Subvolumenes Btrfs a crear"
  for subvolume in "${STAGE02_BTRFS_SUBVOLUMES[@]}"; do
    log_kv "Subvolumen" "${subvolume}"
  done
}

require_stage02_destructive_confirmation() {
  local destructive_confirmed="$1"

  [[ "${destructive_confirmed}" == "yes" ]] || \
    die "Accion destructiva bloqueada: el disco no fue confirmado explicitamente."
}

ensure_stage02_target_not_mounted() {
  local target_root="$1"

  validate_absolute_path "${target_root}"
  if is_mounted "${target_root}"; then
    die "${target_root} ya esta montado. Desmonta manualmente antes de ejecutar Stage02."
  fi
}

wipe_old_signatures_confirmed() {
  local disk="$1"
  local destructive_confirmed="$2"

  require_stage02_destructive_confirmation "${destructive_confirmed}"
  validate_target_disk "${disk}"
  require_command wipefs
  log_step "Limpiando firmas antiguas en ${disk}"
  wipefs --all --force "${disk}"
}

create_efi_and_luks_partitions_confirmed() {
  local disk="$1"
  local efi_size="$2"
  local destructive_confirmed="$3"

  require_stage02_destructive_confirmation "${destructive_confirmed}"
  validate_target_disk "${disk}"
  require_command sfdisk partprobe udevadm
  validate_size_value "${efi_size}" "EFI_SIZE"

  log_step "Creando GPT con particiones EFI y LUKS en ${disk}"
  {
    printf 'label: gpt\n'
    printf 'unit: sectors\n\n'
    create_efi_partition_spec "${efi_size}"
    create_luks_partition_spec
  } | sfdisk --wipe always --wipe-partitions always "${disk}"

  partprobe "${disk}"
  udevadm settle
}

verify_stage02_mounts() {
  local mapped_device="$1"
  local target_root="$2"
  local mountpoint

  log_section "Verificacion de almacenamiento"

  [[ -b "${mapped_device}" ]] || die "Mapper LUKS no abierto: ${mapped_device}"
  cryptsetup status "${CRYPT_NAME}" >/dev/null 2>&1 || die "cryptsetup no reconoce el mapper abierto: ${CRYPT_NAME}"
  success "Mapper LUKS abierto: ${mapped_device}"

  [[ "$(findmnt -no FSTYPE --target "${target_root}" 2>/dev/null || true)" == "btrfs" ]] || \
    die "${target_root} no esta montado como Btrfs."
  success "${target_root} montado como Btrfs."

  [[ "$(findmnt -no FSTYPE --target "${target_root}/boot" 2>/dev/null || true)" == "vfat" ]] || \
    die "${target_root}/boot no esta montado como vfat."
  success "${target_root}/boot montado como vfat."

  for mountpoint in \
    "${target_root}" \
    "${target_root}/home" \
    "${target_root}/var" \
    "${target_root}/var/log" \
    "${target_root}/var/cache" \
    "${target_root}/.snapshots"; do
    is_mounted "${mountpoint}" || die "Subvolumen no montado: ${mountpoint}"
    [[ "$(findmnt -no FSTYPE --target "${mountpoint}" 2>/dev/null || true)" == "btrfs" ]] || \
      die "Subvolumen no montado como Btrfs: ${mountpoint}"
    success "Subvolumen montado: ${mountpoint}"
  done
}

save_storage_state() {
  local disk="$1"
  local efi_part="$2"
  local luks_part="$3"
  local mapped_device="$4"
  local luks_uuid
  local btrfs_uuid

  luks_uuid="$(cryptsetup luksUUID "${luks_part}")"
  [[ -n "${luks_uuid}" ]] || die "No se pudo obtener UUID LUKS de ${luks_part}."

  btrfs_uuid="$(blkid -s UUID -o value "${mapped_device}")"
  [[ -n "${btrfs_uuid}" ]] || die "No se pudo obtener UUID Btrfs de ${mapped_device}."

  create_directory "${STAGE02_STATE_DIR}" 0700
  write_file_atomic "${STAGE02_STORAGE_STATE_FILE}" <<EOF
# Generated by scripts/stage02-storage.sh.
# Source this file from later stages if the values are needed.
TARGET_DISK=$(printf '%q' "${disk}")
EFI_PARTITION=$(printf '%q' "${efi_part}")
LUKS_PARTITION=$(printf '%q' "${luks_part}")
CRYPT_NAME=$(printf '%q' "${CRYPT_NAME}")
MAPPED_DEVICE=$(printf '%q' "${mapped_device}")
LUKS_UUID=$(printf '%q' "${luks_uuid}")
BTRFS_UUID=$(printf '%q' "${btrfs_uuid}")
TARGET_ROOT=$(printf '%q' "${STAGE02_TARGET_ROOT}")
EOF

  chmod 0600 "${STAGE02_STORAGE_STATE_FILE}"
  export LUKS_UUID
  success "Estado de almacenamiento guardado: ${STAGE02_STORAGE_STATE_FILE}"
}

show_storage_summary() {
  local disk="$1"
  local efi_part="$2"
  local luks_part="$3"
  local mapped_device="$4"

  log_section "Resumen final Stage02"
  log_kv "Disco preparado" "${disk}"
  log_kv "EFI" "${efi_part}"
  log_kv "LUKS" "${luks_part}"
  log_kv "Mapper" "${mapped_device}"
  log_kv "Montaje root" "${STAGE02_TARGET_ROOT}"
  log_kv "Estado" "${STAGE02_STORAGE_STATE_FILE}"
  success "Stage02 completado. Stage03 no se ejecutara automaticamente."
}

main() {
  local target_disk
  local efi_part
  local luks_part
  local mapped_device
  local destructive_confirmed="no"

  log_section "Stage02 - Storage"
  require_root
  require_arch_live_iso
  require_uefi

  log_step "Cargando configuracion"
  load_install_config
  validate_install_config
  success "Configuracion cargada y validada."
  ensure_stage02_target_not_mounted "${STAGE02_TARGET_ROOT}"

  show_disk_summary
  if [[ -z "${TARGET_DISK:-}" ]]; then
    log_header "Seleccion de disco objetivo"
    log_info "Escribe el disco objetivo completo, por ejemplo /dev/nvme0n1:"
  fi
  target_disk="$(resolve_stage02_target_disk)"
  validate_target_disk "${target_disk}"
  warn_if_removable_disk "${target_disk}"

  efi_part="$(efi_partition "${target_disk}")"
  luks_part="$(luks_partition "${target_disk}")"
  mapped_device="/dev/mapper/${CRYPT_NAME}"

  show_storage_destruction_plan "${target_disk}" "${efi_part}" "${luks_part}" "${mapped_device}"
  confirm_destructive_disk_action "${target_disk}"
  destructive_confirmed="yes"

  create_directory "${STAGE02_TARGET_ROOT}"
  wipe_old_signatures_confirmed "${target_disk}" "${destructive_confirmed}"
  create_efi_and_luks_partitions_confirmed "${target_disk}" "${EFI_SIZE}" "${destructive_confirmed}"
  require_stage02_destructive_confirmation "${destructive_confirmed}"
  format_efi_fat32 "${efi_part}"
  require_stage02_destructive_confirmation "${destructive_confirmed}"
  create_luks2 "${luks_part}"
  require_stage02_destructive_confirmation "${destructive_confirmed}"
  open_luks "${luks_part}" "${CRYPT_NAME}"
  require_stage02_destructive_confirmation "${destructive_confirmed}"
  create_btrfs "${mapped_device}"
  require_stage02_destructive_confirmation "${destructive_confirmed}"
  create_btrfs_subvolumes "${mapped_device}" "${STAGE02_TARGET_ROOT}"
  require_stage02_destructive_confirmation "${destructive_confirmed}"
  mount_btrfs_subvolumes "${mapped_device}" "${efi_part}" "${STAGE02_TARGET_ROOT}"

  verify_stage02_mounts "${mapped_device}" "${STAGE02_TARGET_ROOT}"
  save_storage_state "${target_disk}" "${efi_part}" "${luks_part}" "${mapped_device}"
  show_storage_summary "${target_disk}" "${efi_part}" "${luks_part}" "${mapped_device}"
}

main "$@"
