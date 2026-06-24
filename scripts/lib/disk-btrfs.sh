#!/usr/bin/env bash
# Btrfs helpers for the Arch workstation installer.
#
# This library owns Btrfs formatting, subvolume creation, mount options, mount
# verification, and final mount summaries. It assumes the LUKS mapper already
# exists and is active; it never partitions disks or creates/open LUKS.

set -euo pipefail

DISK_BTRFS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F ensure_block_device_not_mounted >/dev/null 2>&1; then
  # shellcheck source=disk-common.sh
  source "${DISK_BTRFS_LIB_DIR}/disk-common.sh"
fi

if ! declare -F mapper_is_active >/dev/null 2>&1; then
  # shellcheck source=disk-luks.sh
  source "${DISK_BTRFS_LIB_DIR}/disk-luks.sh"
fi

DEFAULT_BTRFS_COMPRESS="${DEFAULT_BTRFS_COMPRESS:-zstd}"
DEFAULT_BTRFS_LABEL="${DEFAULT_BTRFS_LABEL:-ARCHROOT}"

default_btrfs_subvolumes() {
  printf '%s\n' \
    @ \
    @home \
    @var \
    @snapshots
}

btrfs_filesystem_type() {
  local mapped_device="$1"

  [[ -b "${mapped_device}" ]] || die "El dispositivo Btrfs no existe: ${mapped_device}"
  require_command blkid
  blkid -s TYPE -o value "${mapped_device}" 2>/dev/null || true
}

device_is_btrfs() {
  local mapped_device="$1"

  [[ "$(btrfs_filesystem_type "${mapped_device}")" == "btrfs" ]]
}

btrfs_uuid() {
  local mapped_device="$1"

  device_is_btrfs "${mapped_device}" || die "El mapper no contiene Btrfs: ${mapped_device}"
  require_command blkid
  blkid -s UUID -o value "${mapped_device}"
}

mapper_name_from_path() {
  local mapped_device="$1"

  [[ "${mapped_device}" == /dev/mapper/* ]] || die "El dispositivo no es un mapper LUKS esperado: ${mapped_device}"
  printf '%s\n' "${mapped_device##*/}"
}

require_active_btrfs_mapper() {
  local mapped_device="$1"
  local crypt_name

  [[ -b "${mapped_device}" ]] || die "El mapper LUKS no existe: ${mapped_device}"
  crypt_name="$(mapper_name_from_path "${mapped_device}")"
  mapper_is_active "${crypt_name}" || die "El mapper LUKS no esta activo: ${mapped_device}"
}

confirm_btrfs_overwrite_if_needed() {
  local mapped_device="$1"

  require_active_btrfs_mapper "${mapped_device}"

  if device_is_btrfs "${mapped_device}"; then
    log_warn "El mapper ya contiene un sistema de archivos Btrfs valido: ${mapped_device}"
    log_warn "Para recrearlo se requiere confirmacion exacta."
    require_exact_confirmation "${mapped_device}" "Confirma el mapper exacto para sobrescribir Btrfs."
  fi
}

cleanup_btrfs_mountpoint_on_failure() {
  local mountpoint="$1"

  require_command findmnt umount

  if findmnt --mountpoint "${mountpoint}" >/dev/null 2>&1; then
    log_warn "Fallo detectado: desmontando ${mountpoint}."
    umount "${mountpoint}" || log_warn "No se pudo desmontar ${mountpoint}."
  fi
}

cleanup_btrfs_mounts_on_failure() {
  local target="${1:-/mnt}"

  cleanup_btrfs_mountpoint_on_failure "${target}/.snapshots"
  cleanup_btrfs_mountpoint_on_failure "${target}/var"
  cleanup_btrfs_mountpoint_on_failure "${target}/home"
  cleanup_btrfs_mountpoint_on_failure "${target}"
}

create_btrfs() {
  local mapped_device="$1"
  local label="${2:-${BTRFS_LABEL:-${DEFAULT_BTRFS_LABEL}}}"

  require_command mkfs.btrfs blkid
  require_active_btrfs_mapper "${mapped_device}"
  ensure_block_device_not_mounted "${mapped_device}"
  confirm_btrfs_overwrite_if_needed "${mapped_device}"

  log_step "Creando Btrfs en ${mapped_device}"
  mkfs.btrfs --nodiscard -f -L "${label}" "${mapped_device}"
  device_is_btrfs "${mapped_device}" || die "No se pudo verificar Btrfs despues de mkfs: ${mapped_device}"
  success "Btrfs creado correctamente en ${mapped_device}."
}

btrfs_subvolume_exists() {
  local mountpoint="$1"
  local subvolume="$2"

  require_command btrfs
  btrfs subvolume show "${mountpoint}/${subvolume}" >/dev/null 2>&1
}

create_btrfs_subvolumes() {
  local mapped_device="$1"
  local mountpoint="${2:-/mnt}"
  local subvolume
  local mounted="no"

  require_command btrfs mount umount
  require_active_btrfs_mapper "${mapped_device}"
  device_is_btrfs "${mapped_device}" || die "El mapper no contiene Btrfs: ${mapped_device}"
  require_directory "${mountpoint}"
  ensure_block_device_not_mounted "${mapped_device}"

  if is_mounted "${mountpoint}"; then
    die "El punto de montaje ya esta ocupado: ${mountpoint}"
  fi

  log_step "Montando Btrfs top-level temporalmente en ${mountpoint}"
  mount "${mapped_device}" "${mountpoint}"
  mounted="yes"

  log_step "Creando subvolumenes Btrfs"
  while IFS= read -r subvolume; do
    [[ -n "${subvolume}" ]] || continue
    if btrfs_subvolume_exists "${mountpoint}" "${subvolume}"; then
      log_warn "El subvolumen ya existe: ${subvolume}"
      continue
    fi

    if [[ -e "${mountpoint}/${subvolume}" ]]; then
      if [[ "${mounted}" == "yes" ]]; then
        umount "${mountpoint}" || true
      fi
      die "Existe una ruta que no es subvolumen Btrfs: ${mountpoint}/${subvolume}"
    fi

    if ! btrfs subvolume create "${mountpoint}/${subvolume}"; then
      if [[ "${mounted}" == "yes" ]]; then
        umount "${mountpoint}" || true
      fi
      die "No se pudo crear el subvolumen Btrfs: ${subvolume}"
    fi
  done < <(default_btrfs_subvolumes)

  log_step "Desmontando Btrfs top-level temporal"
  if ! umount "${mountpoint}"; then
    die "No se pudo desmontar el Btrfs top-level temporal: ${mountpoint}"
  fi
  mounted="no"
  success "Subvolumenes Btrfs creados correctamente."
}

btrfs_device_is_ssd() {
  local mapped_device="$1"

  require_command lsblk awk
  lsblk -nrpo ROTA "${mapped_device}" 2>/dev/null | awk '$1 == "0" { found = 1 } END { exit found ? 0 : 1 }'
}

btrfs_mount_options() {
  local mapped_device="${1:-}"
  local compression="${2:-${BTRFS_COMPRESS:-${DEFAULT_BTRFS_COMPRESS}}}"
  local options

  case "${compression}" in
    zstd|lzo) options="noatime,compress=${compression}" ;;
    no|none) options="noatime" ;;
    *) die "Compresion Btrfs no soportada: ${compression}" ;;
  esac

  if [[ -n "${mapped_device}" && -b "${mapped_device}" ]] && btrfs_device_is_ssd "${mapped_device}"; then
    options="${options},ssd"
  fi

  printf '%s\n' "${options}"
}

verify_btrfs_mount() {
  local mountpoint="$1"
  local expected_subvolume="$2"
  local expected_compression="${3:-${BTRFS_COMPRESS:-${DEFAULT_BTRFS_COMPRESS}}}"
  local fstype
  local options

  require_command findmnt
  fstype="$(findmnt -no FSTYPE --target "${mountpoint}" 2>/dev/null || true)"
  options="$(findmnt -no OPTIONS --target "${mountpoint}" 2>/dev/null || true)"

  [[ "${fstype}" == "btrfs" ]] || die "El montaje no es Btrfs: ${mountpoint}"

  case ",${options}," in
    *",subvol=${expected_subvolume},"*|*",subvol=/${expected_subvolume},"*) ;;
    *) die "El montaje ${mountpoint} no usa subvolumen ${expected_subvolume}." ;;
  esac

  case ",${options}," in
    *",noatime,"*) ;;
    *) die "El montaje ${mountpoint} no usa noatime." ;;
  esac

  case "${expected_compression}" in
    zstd|lzo)
      case ",${options}," in
        *",compress=${expected_compression},"*|*",compress=${expected_compression}:"*) ;;
        *) die "El montaje ${mountpoint} no usa compress=${expected_compression}." ;;
      esac
      ;;
    no|none)
      case ",${options}," in
        *",compress="*) die "El montaje ${mountpoint} usa compresion aunque BTRFS_COMPRESS=${expected_compression}." ;;
      esac
      ;;
    *) die "Compresion Btrfs no soportada: ${expected_compression}" ;;
  esac

  success "Montaje Btrfs verificado: ${mountpoint} -> ${expected_subvolume}"
}

mount_single_btrfs_subvolume() {
  local mapped_device="$1"
  local subvolume="$2"
  local mountpoint="$3"
  local options="$4"

  create_directory "${mountpoint}"

  if is_mounted "${mountpoint}"; then
    verify_btrfs_mount "${mountpoint}" "${subvolume}"
    return 0
  fi

  mount -o "${options},subvol=${subvolume}" "${mapped_device}" "${mountpoint}"
  verify_btrfs_mount "${mountpoint}" "${subvolume}"
}

mount_btrfs_subvolumes() {
  local mapped_device="$1"
  local target="${2:-/mnt}"
  local options

  require_command mount findmnt
  require_active_btrfs_mapper "${mapped_device}"
  device_is_btrfs "${mapped_device}" || die "El mapper no contiene Btrfs: ${mapped_device}"
  require_directory "${target}"

  options="$(btrfs_mount_options "${mapped_device}" "${BTRFS_COMPRESS:-${DEFAULT_BTRFS_COMPRESS}}")"
  log_step "Montando subvolumenes Btrfs en ${target}"
  mount_single_btrfs_subvolume "${mapped_device}" "@" "${target}" "${options}"
  mount_single_btrfs_subvolume "${mapped_device}" "@home" "${target}/home" "${options}"
  mount_single_btrfs_subvolume "${mapped_device}" "@var" "${target}/var" "${options}"
  mount_single_btrfs_subvolume "${mapped_device}" "@snapshots" "${target}/.snapshots" "${options}"
  success "Subvolumenes Btrfs montados correctamente en ${target}."
}

verify_btrfs_subvolume_mounts() {
  local target="${1:-/mnt}"

  verify_btrfs_mount "${target}" "@"
  verify_btrfs_mount "${target}/home" "@home"
  verify_btrfs_mount "${target}/var" "@var"
  verify_btrfs_mount "${target}/.snapshots" "@snapshots"
}

show_btrfs_mount_summary() {
  local target="${1:-/mnt}"

  require_command findmnt
  log_section "Resumen de montajes Btrfs"
  findmnt -R "${target}"
}
