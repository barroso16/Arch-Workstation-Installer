#!/usr/bin/env bash
# Shared disk helpers for the Arch workstation installer.
#
# This library contains validation, selection, mount checks, live ISO detection,
# destructive confirmation gates, partition name helpers, and shared defaults.

set -euo pipefail

DISK_COMMON_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F die >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${DISK_COMMON_LIB_DIR}/common.sh"
fi

if ! declare -F log_section >/dev/null 2>&1; then
  # shellcheck source=logging.sh
  source "${DISK_COMMON_LIB_DIR}/logging.sh"
fi

if ! declare -F validate_install_config >/dev/null 2>&1; then
  # shellcheck source=config.sh
  source "${DISK_COMMON_LIB_DIR}/config.sh"
fi

if ! declare -F is_removable_disk >/dev/null 2>&1; then
  # shellcheck source=hardware.sh
  source "${DISK_COMMON_LIB_DIR}/hardware.sh"
fi

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
