#!/usr/bin/env bash
# Disk helpers for the Arch workstation installer.
#
# This library contains conservative disk preparation primitives. It does not
# install packages, configure bootloaders, Secure Boot, NVIDIA, or chroot. Any
# destructive helper must validate the target and require exact confirmation.

set -euo pipefail

DISK_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F die >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${DISK_LIB_DIR}/common.sh"
fi

if ! declare -F log_section >/dev/null 2>&1; then
  # shellcheck source=logging.sh
  source "${DISK_LIB_DIR}/logging.sh"
fi

if ! declare -F validate_install_config >/dev/null 2>&1; then
  # shellcheck source=config.sh
  source "${DISK_LIB_DIR}/config.sh"
fi

if ! declare -F is_removable_disk >/dev/null 2>&1; then
  # shellcheck source=hardware.sh
  source "${DISK_LIB_DIR}/hardware.sh"
fi

DEFAULT_EFI_SIZE="${DEFAULT_EFI_SIZE:-1G}"
DEFAULT_CRYPT_NAME="${DEFAULT_CRYPT_NAME:-cryptroot}"
DEFAULT_BTRFS_COMPRESS="${DEFAULT_BTRFS_COMPRESS:-zstd}"

resolve_disk_realpath() {
  local disk="$1"

  validate_absolute_path "${disk}"
  realpath -m -- "${disk}"
}

list_candidate_disks_for_disk_stage() {
  local disk
  local size
  local model
  local serial
  local tran
  local rm
  local warning

  if command_exists lsblk; then
    while IFS= read -r disk; do
      size="$(lsblk -dnpo SIZE "${disk}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
      model="$(lsblk -dnpo MODEL "${disk}" 2>/dev/null | sed 's/[[:space:]]\+$//')"
      serial="$(lsblk -dnpo SERIAL "${disk}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
      tran="$(lsblk -dnpo TRAN "${disk}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
      rm="$(lsblk -dnpo RM "${disk}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
      warning=""

      if [[ "${tran}" == "usb" || "${rm}" == "1" ]]; then
        warning=" [PELIGRO: USB/REMOVIBLE]"
      fi

      printf '%-18s size=%-8s tran=%-8s rm=%-2s model=%s serial=%s%s\n' \
        "${disk}" "${size:-unknown}" "${tran:-unknown}" "${rm:-?}" "${model:-unknown}" "${serial:-unknown}" "${warning}"
    done < <(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }')
  else
    find /dev -maxdepth 1 -type b \( -name 'sd*' -o -name 'nvme*n*' -o -name 'vd*' \) -print 2>/dev/null
  fi
}

show_available_disks_for_selection() {
  log_section "Discos disponibles"
  list_candidate_disks_for_disk_stage
  log_warn "Los discos USB/removibles se muestran, pero pueden ser el medio Live USB."
}

resolve_target_disk() {
  local configured_disk="${1:-${TARGET_DISK:-}}"
  local selected_disk

  if [[ -n "${configured_disk}" ]]; then
    selected_disk="$(resolve_disk_realpath "${configured_disk}")"
    validate_target_disk "${selected_disk}"
    printf '%s\n' "${selected_disk}"
    return 0
  fi

  show_available_disks_for_selection
  printf 'Escribe el disco objetivo completo, por ejemplo /dev/nvme0n1: '
  read -r selected_disk
  selected_disk="$(trim "${selected_disk}")"
  selected_disk="$(resolve_disk_realpath "${selected_disk}")"
  validate_target_disk "${selected_disk}"
  printf '%s\n' "${selected_disk}"
}

validate_target_disk() {
  local disk="$1"

  validate_absolute_path "${disk}"
  [[ -b "${disk}" ]] || die "El disco objetivo no existe o no es bloque: ${disk}"

  if command_exists lsblk; then
    [[ "$(lsblk -dpno TYPE "${disk}" 2>/dev/null | awk 'NR == 1 { print $1 }')" == "disk" ]] || \
      die "El objetivo no es un disco completo: ${disk}"
  fi

  ensure_disk_not_mounted "${disk}"
  ensure_not_live_usb_disk "${disk}"
  warn_if_removable_disk "${disk}"
}

ensure_disk_not_mounted() {
  local disk="$1"

  if command_exists lsblk; then
    if lsblk -nrpo MOUNTPOINT "${disk}" 2>/dev/null | awk 'NF { found = 1 } END { exit found ? 0 : 1 }'; then
      die "El disco o alguna particion esta montado. Desmonta antes de continuar: ${disk}"
    fi
  fi
}

ensure_block_device_not_mounted() {
  local device="$1"

  [[ -b "${device}" ]] || die "No es un dispositivo de bloque: ${device}"

  if command_exists lsblk; then
    if lsblk -nrpo MOUNTPOINT "${device}" 2>/dev/null | awk 'NF { found = 1 } END { exit found ? 0 : 1 }'; then
      die "El dispositivo esta montado y no se puede modificar: ${device}"
    fi
  fi
}

detect_live_iso_disk() {
  local source
  local pkname

  if command_exists findmnt; then
    source="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
    if [[ -z "${source}" ]]; then
      source="$(findmnt -no SOURCE /run/archiso/cowspace 2>/dev/null || true)"
    fi

    if [[ -n "${source}" && "${source}" == /dev/* ]] && command_exists lsblk; then
      pkname="$(lsblk -no PKNAME "${source}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
      if [[ -n "${pkname}" ]]; then
        printf '/dev/%s\n' "${pkname}"
        return 0
      fi
    fi
  fi

  return 1
}

ensure_not_live_usb_disk() {
  local disk="$1"
  local live_disk

  live_disk="$(detect_live_iso_disk || true)"
  [[ -z "${live_disk}" ]] && return 0

  if [[ "$(resolve_disk_realpath "${disk}")" == "$(resolve_disk_realpath "${live_disk}")" ]]; then
    die "El disco objetivo parece ser el medio Live USB: ${disk}"
  fi
}

confirm_destructive_disk_action() {
  local disk="$1"

  validate_target_disk "${disk}"
  log_warn "ACCION DESTRUCTIVA: se borrara completamente ${disk}."
  log_warn "Esta confirmacion es obligatoria antes de modificar particiones o firmas."
  require_exact_confirmation "${disk}" "Confirma el disco exacto a destruir."
}

partition_name() {
  local disk="$1"
  local number="$2"

  case "${disk}" in
    /dev/nvme*n*|/dev/mmcblk*|/dev/loop*)
      printf '%sp%s\n' "${disk}" "${number}"
      ;;
    *)
      printf '%s%s\n' "${disk}" "${number}"
      ;;
  esac
}

efi_partition() {
  partition_name "$1" 1
}

luks_partition() {
  partition_name "$1" 2
}

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

create_luks2() {
  local luks_part="$1"

  require_command cryptsetup
  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  ensure_block_device_not_mounted "${luks_part}"
  log_step "Creando contenedor LUKS2 en ${luks_part}"
  cryptsetup luksFormat --type luks2 --batch-mode "${luks_part}"
}

open_luks() {
  local luks_part="$1"
  local crypt_name="${2:-${CRYPT_NAME:-${DEFAULT_CRYPT_NAME}}}"

  require_command cryptsetup
  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  log_step "Abriendo LUKS ${luks_part} como ${crypt_name}"
  cryptsetup open "${luks_part}" "${crypt_name}"
}

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

  require_command btrfs mount umount
  [[ -b "${mapped_device}" ]] || die "El dispositivo Btrfs no existe: ${mapped_device}"
  require_directory "${mountpoint}"
  ensure_block_device_not_mounted "${mapped_device}"

  if is_mounted "${mountpoint}"; then
    die "El punto de montaje ya esta ocupado: ${mountpoint}"
  fi

  log_step "Creando subvolumenes Btrfs"
  mount "${mapped_device}" "${mountpoint}"
  btrfs subvolume create "${mountpoint}/@"
  btrfs subvolume create "${mountpoint}/@home"
  btrfs subvolume create "${mountpoint}/@var"
  btrfs subvolume create "${mountpoint}/@log"
  btrfs subvolume create "${mountpoint}/@cache"
  btrfs subvolume create "${mountpoint}/@snapshots"
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
