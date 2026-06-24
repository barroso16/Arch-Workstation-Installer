#!/usr/bin/env bash
# Partitioning helpers for the Arch workstation installer.

set -euo pipefail

DISK_PARTITION_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F confirm_destructive_disk_action >/dev/null 2>&1; then
  # shellcheck source=disk-common.sh
  source "${DISK_PARTITION_LIB_DIR}/disk-common.sh"
fi

DEFAULT_EFI_SIZE="${DEFAULT_EFI_SIZE:-1G}"

wipe_old_signatures() {
  local disk="$1"

  confirm_destructive_disk_action "${disk}"
  require_command wipefs
  log_step "Limpiando firmas antiguas en ${disk}"
  wipefs --all --force "${disk}"
}

create_gpt_table() {
  local disk="$1"

  confirm_destructive_disk_action "${disk}"
  require_command sfdisk partprobe udevadm
  log_step "Creando tabla GPT vacia en ${disk}"
  printf 'label: gpt\n' | sfdisk --wipe always --wipe-partitions always "${disk}"
  partprobe "${disk}"
  udevadm settle
}

create_efi_partition_spec() {
  local efi_size="${1:-${EFI_SIZE:-${DEFAULT_EFI_SIZE}}}"

  validate_size_value "${efi_size}" "EFI_SIZE"
  printf 'size=%s,type=uefi,name="EFI System"\n' "${efi_size}"
}

create_luks_partition_spec() {
  printf 'type=linux,name="Linux LUKS2 Btrfs"\n'
}

create_efi_and_luks_partitions() {
  local disk="$1"
  local efi_size="${2:-${EFI_SIZE:-${DEFAULT_EFI_SIZE}}}"

  confirm_destructive_disk_action "${disk}"
  require_command sfdisk partprobe udevadm
  validate_size_value "${efi_size}" "EFI_SIZE"

  log_step "Creando particiones EFI y LUKS en ${disk}"
  {
    printf 'label: gpt\n'
    printf 'unit: sectors\n\n'
    create_efi_partition_spec "${efi_size}"
    create_luks_partition_spec
  } | sfdisk --wipe always --wipe-partitions always "${disk}"

  partprobe "${disk}"
  udevadm settle
}

format_efi_fat32() {
  local efi_part="$1"

  require_command mkfs.fat
  [[ -b "${efi_part}" ]] || die "La particion EFI no existe: ${efi_part}"
  ensure_block_device_not_mounted "${efi_part}"
  log_step "Formateando EFI en FAT32: ${efi_part}"
  mkfs.fat -F32 -n EFI "${efi_part}"
}
