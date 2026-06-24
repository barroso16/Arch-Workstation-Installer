#!/usr/bin/env bash
# Btrfs helpers for the Arch workstation installer.

set -euo pipefail

DISK_BTRFS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F default_btrfs_subvolumes >/dev/null 2>&1; then
  # shellcheck source=disk-common.sh
  source "${DISK_BTRFS_LIB_DIR}/disk-common.sh"
fi

DEFAULT_BTRFS_COMPRESS="${DEFAULT_BTRFS_COMPRESS:-zstd}"

create_btrfs() {
  local mapped_device="$1"

  require_command mkfs.btrfs
  [[ -b "${mapped_device}" ]] || die "El dispositivo Btrfs no existe: ${mapped_device}"
  ensure_block_device_not_mounted "${mapped_device}"
  log_step "Creando Btrfs en ${mapped_device}"
  mkfs.btrfs -f -L ARCHROOT "${mapped_device}"
}

create_btrfs_subvolumes() {
  local mapped_device="$1"
  local mountpoint="${2:-/mnt}"
  local subvolume

  require_command btrfs mount umount
  [[ -b "${mapped_device}" ]] || die "El dispositivo Btrfs no existe: ${mapped_device}"
  require_directory "${mountpoint}"
  ensure_block_device_not_mounted "${mapped_device}"

  if is_mounted "${mountpoint}"; then
    die "El punto de montaje ya esta ocupado: ${mountpoint}"
  fi

  log_step "Creando subvolumenes Btrfs"
  mount "${mapped_device}" "${mountpoint}"
  while IFS= read -r subvolume; do
    [[ -n "${subvolume}" ]] || continue
    btrfs subvolume create "${mountpoint}/${subvolume}"
  done < <(default_btrfs_subvolumes)
  umount "${mountpoint}"
}

btrfs_mount_options() {
  local compression="${1:-${BTRFS_COMPRESS:-${DEFAULT_BTRFS_COMPRESS}}}"

  case "${compression}" in
    zstd|lzo) printf 'noatime,compress=%s,space_cache=v2\n' "${compression}" ;;
    no|none) printf 'noatime,space_cache=v2\n' ;;
    *) die "Compresion Btrfs no soportada: ${compression}" ;;
  esac
}

mount_btrfs_subvolumes() {
  local mapped_device="$1"
  local efi_part="$2"
  local target="${3:-/mnt}"
  local options

  require_command mount
  [[ -b "${mapped_device}" ]] || die "El dispositivo Btrfs no existe: ${mapped_device}"
  [[ -b "${efi_part}" ]] || die "La particion EFI no existe: ${efi_part}"
  require_directory "${target}"

  if is_mounted "${target}"; then
    die "El punto de montaje ya esta ocupado: ${target}"
  fi

  options="$(btrfs_mount_options)"
  log_step "Montando subvolumenes Btrfs en ${target}"
  mount -o "${options},subvol=@" "${mapped_device}" "${target}"

  create_directory "${target}/boot"
  create_directory "${target}/home"
  create_directory "${target}/var"
  create_directory "${target}/.snapshots"

  mount -o "${options},subvol=@home" "${mapped_device}" "${target}/home"
  mount -o "${options},subvol=@var" "${mapped_device}" "${target}/var"

  create_directory "${target}/var/log"
  create_directory "${target}/var/cache"

  mount -o "${options},subvol=@log" "${mapped_device}" "${target}/var/log"
  mount -o "${options},subvol=@cache" "${mapped_device}" "${target}/var/cache"
  mount -o "${options},subvol=@snapshots" "${mapped_device}" "${target}/.snapshots"
  mount "${efi_part}" "${target}/boot"
}
