#!/usr/bin/env bash
# Partitioning helpers for the Arch workstation installer.

set -euo pipefail

DISK_PARTITION_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F confirm_destructive_disk_action >/dev/null 2>&1; then
  # shellcheck source=disk-common.sh
  source "${DISK_PARTITION_LIB_DIR}/disk-common.sh"
fi

DEFAULT_EFI_SIZE="${DEFAULT_EFI_SIZE:-1G}"
GPT_TYPE_EFI_SYSTEM="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
GPT_TYPE_LINUX_LUKS="CA7D7CCB-63ED-4C53-861C-1742536059CC"

verify_no_wipefs_signatures() {
  local device="$1"
  local signatures

  [[ -b "${device}" ]] || die "No es un dispositivo de bloque: ${device}"
  require_command wipefs

  signatures="$(wipefs --no-act "${device}" 2>/dev/null || true)"
  [[ -z "${signatures}" ]] || die "Persisten firmas en ${device}: ${signatures}"
  success "Sin firmas detectadas en ${device}."
}

wipe_previous_filesystem_signatures() {
  local disk="$1"
  local partition
  local partitions=()

  validate_target_disk "${disk}"
  require_command lsblk wipefs

  while IFS= read -r partition; do
    [[ -n "${partition}" ]] && partitions+=("${partition}")
  done < <(lsblk -nrpo NAME,TYPE "${disk}" 2>/dev/null | awk '$2 == "part" { print $1 }')

  if ((${#partitions[@]} == 0)); then
    log_warn "INICIO DESTRUCTIVO: eliminando firmas previas directamente en ${disk}"
    wipefs --all --force "${disk}"
    verify_no_wipefs_signatures "${disk}"
    success "Firmas previas eliminadas correctamente en ${disk}."
    return 0
  fi

  log_warn "INICIO DESTRUCTIVO: eliminando firmas previas en particiones existentes de ${disk}"
  for partition in "${partitions[@]}"; do
    [[ -b "${partition}" ]] || continue
    ensure_block_device_not_mounted "${partition}"
    log_info "Limpiando firmas de sistema de archivos en ${partition}"
    wipefs --all --force "${partition}"
    verify_no_wipefs_signatures "${partition}"
  done
  success "Firmas previas eliminadas correctamente en particiones existentes de ${disk}."
}

wipe_previous_partition_signatures_if_needed() {
  local disk="$1"

  validate_target_disk "${disk}"
  require_command wipefs

  if [[ -z "$(wipefs --no-act "${disk}" 2>/dev/null)" ]]; then
    log_step "No se detectaron firmas de particion pendientes en ${disk}."
    return 0
  fi

  log_warn "INICIO DESTRUCTIVO: eliminando firmas previas de particionado en ${disk}"
  wipefs --all --force "${disk}"
  verify_no_wipefs_signatures "${disk}"
  success "Firmas previas de particionado eliminadas correctamente en ${disk}."
}

create_empty_gpt_table() {
  local disk="$1"

  validate_target_disk "${disk}"
  require_command sfdisk
  log_warn "INICIO DESTRUCTIVO: creando tabla GPT vacia en ${disk}"
  printf 'label: gpt\n' | sfdisk --wipe always --wipe-partitions always "${disk}"
  success "Tabla GPT vacia escrita en ${disk}."
}

reload_kernel_partition_table() {
  local disk="$1"
  local expected_partitions="${2:-0}"

  validate_target_disk "${disk}"
  require_command partprobe udevadm lsblk sleep
  log_step "Recargando tabla de particiones del kernel para ${disk}"
  partprobe "${disk}"
  udevadm settle
  wait_for_kernel_partition_table_refresh "${disk}" "${expected_partitions}"
  success "Kernel y udev reflejan la tabla de particiones actualizada para ${disk}."
}

wait_for_kernel_partition_table_refresh() {
  local disk="$1"
  local attempt
  local disk_type
  local partition_count
  local expected_partitions="${2:-0}"

  validate_target_disk "${disk}"
  require_command lsblk awk sleep

  for attempt in {1..10}; do
    disk_type="$(lsblk -dnpo TYPE "${disk}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    partition_count="$(lsblk -nrpo TYPE "${disk}" 2>/dev/null | awk '$1 == "part" { count++ } END { print count + 0 }')"

    if [[ "${disk_type}" == "disk" && "${partition_count}" -eq "${expected_partitions}" ]]; then
      return 0
    fi

    log_info "Esperando actualizacion del kernel para ${disk} (${attempt}/10)"
    sleep 1
  done

  die "El kernel no reflejo la tabla esperada de ${disk} dentro del tiempo esperado."
}

verify_empty_gpt_table() {
  local disk="$1"
  local label
  local partition_count

  validate_target_disk "${disk}"
  require_command sfdisk lsblk awk

  log_step "Verificando integridad de GPT en ${disk}"
  sfdisk --verify "${disk}" >/dev/null

  label="$(sfdisk --dump "${disk}" 2>/dev/null | awk -F: '$1 == "label" { gsub(/^[ \t]+/, "", $2); print $2; exit }')"
  [[ "${label}" == "gpt" ]] || die "No se pudo verificar una tabla GPT valida en ${disk}."

  partition_count="$(lsblk -nrpo TYPE "${disk}" 2>/dev/null | awk '$1 == "part" { count++ } END { print count + 0 }')"
  [[ "${partition_count}" -eq 0 ]] || die "La tabla GPT de ${disk} no esta vacia; particiones detectadas: ${partition_count}"

  success "GPT vacia verificada correctamente en ${disk}."
}

show_partition_table() {
  local disk="$1"

  validate_target_disk "${disk}"
  require_command sfdisk lsblk
  log_section "Tabla de particiones resultante"
  sfdisk --list "${disk}"
  log_section "Vista lsblk resultante"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPENAME,MOUNTPOINTS "${disk}"
}

size_to_bytes() {
  local value="$1"
  local number
  local suffix
  local multiplier=1

  [[ "${value}" =~ ^([1-9][0-9]*)([A-Za-z]*)$ ]] || die "Tamano invalido: ${value}"
  number="${BASH_REMATCH[1]}"
  suffix="${BASH_REMATCH[2]}"

  case "${suffix}" in
    ""|B|b) multiplier=1 ;;
    K|KB|k|kB|KiB|Ki|kiB|ki) multiplier=1024 ;;
    MiB|Mi|miB|mi) multiplier=$((1024 * 1024)) ;;
    M|MB|m|mB) multiplier=$((1024 * 1024)) ;;
    GiB|Gi|giB|gi) multiplier=$((1024 * 1024 * 1024)) ;;
    G|GB|g|gB) multiplier=$((1024 * 1024 * 1024)) ;;
    TiB|Ti|tiB|ti) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
    T|TB|t|tB) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
    PiB|Pi|piB|pi) multiplier=$((1024 * 1024 * 1024 * 1024 * 1024)) ;;
    P|PB|p|pB) multiplier=$((1024 * 1024 * 1024 * 1024 * 1024)) ;;
    *) die "Sufijo de tamano no soportado: ${suffix}" ;;
  esac

  printf '%s\n' "$((number * multiplier))"
}

create_final_gpt_partition_layout() {
  local disk="$1"
  local efi_size="${2:-${EFI_SIZE:-${DEFAULT_EFI_SIZE}}}"

  validate_target_disk "${disk}"
  verify_empty_gpt_table "${disk}"
  require_command sfdisk
  validate_size_value "${efi_size}" "EFI_SIZE"

  log_warn "INICIO DESTRUCTIVO: creando particiones EFI y Linux LUKS en ${disk}"
  {
    printf 'label: gpt\n'
    printf 'unit: sectors\n\n'
    create_efi_partition_spec "${efi_size}"
    create_luks_partition_spec
  } | sfdisk --wipe never --wipe-partitions never "${disk}"
  success "Layout GPT final escrito en ${disk}."
}

wait_for_final_partition_layout() {
  local disk="$1"

  reload_kernel_partition_table "${disk}" 2
}

verify_partition_exists() {
  local partition="$1"

  [[ -b "${partition}" ]] || die "No existe la particion esperada: ${partition}"
  success "Particion detectada: ${partition}"
}

partition_field() {
  local partition="$1"
  local field="$2"

  require_command lsblk awk
  lsblk -bdnpo "${field}" "${partition}" 2>/dev/null | awk 'NR == 1 { print }'
}

verify_final_partition_layout() {
  local disk="$1"
  local efi_size="${2:-${EFI_SIZE:-${DEFAULT_EFI_SIZE}}}"
  local efi_part
  local luks_part
  local efi_size_bytes
  local actual_efi_size
  local tolerance
  local efi_type
  local luks_type
  local efi_label
  local luks_label
  local partition_count
  local first_partition
  local second_partition
  local disk_size
  local luks_size
  local minimum_luks_size

  validate_target_disk "${disk}"
  require_command lsblk awk sfdisk
  validate_size_value "${efi_size}" "EFI_SIZE"

  log_step "Verificando layout final de particiones en ${disk}"
  sfdisk --verify "${disk}" >/dev/null

  efi_part="$(efi_partition "${disk}")"
  luks_part="$(luks_partition "${disk}")"
  verify_partition_exists "${efi_part}"
  verify_partition_exists "${luks_part}"

  partition_count="$(lsblk -nrpo TYPE "${disk}" 2>/dev/null | awk '$1 == "part" { count++ } END { print count + 0 }')"
  [[ "${partition_count}" -eq 2 ]] || die "Cantidad inesperada de particiones en ${disk}: ${partition_count}"

  first_partition="$(lsblk -nrpo NAME,TYPE "${disk}" 2>/dev/null | awk '$2 == "part" { print $1; exit }')"
  second_partition="$(lsblk -nrpo NAME,TYPE "${disk}" 2>/dev/null | awk '$2 == "part" { count++; if (count == 2) { print $1; exit } }')"
  [[ "${first_partition}" == "${efi_part}" ]] || die "Orden incorrecto: la primera particion no es EFI (${first_partition})."
  [[ "${second_partition}" == "${luks_part}" ]] || die "Orden incorrecto: la segunda particion no es LUKS (${second_partition})."

  [[ "$(partition_field "${efi_part}" TYPE)" == "part" ]] || die "La primera particion no es valida: ${efi_part}"
  [[ "$(partition_field "${luks_part}" TYPE)" == "part" ]] || die "La segunda particion no es valida: ${luks_part}"

  efi_size_bytes="$(size_to_bytes "${efi_size}")"
  actual_efi_size="$(partition_field "${efi_part}" SIZE)"
  tolerance=$((2 * 1024 * 1024))
  [[ "${actual_efi_size}" -ge "$((efi_size_bytes - tolerance))" ]] || die "La particion EFI es menor de lo esperado: ${actual_efi_size} bytes"
  [[ "${actual_efi_size}" -le "$((efi_size_bytes + tolerance))" ]] || die "La particion EFI es mayor de lo esperado: ${actual_efi_size} bytes"

  disk_size="$(partition_field "${disk}" SIZE)"
  luks_size="$(partition_field "${luks_part}" SIZE)"
  tolerance=$((16 * 1024 * 1024))
  minimum_luks_size=$((disk_size - efi_size_bytes - tolerance))
  [[ "${minimum_luks_size}" -gt 0 ]] || die "El disco es demasiado pequeno para EFI_SIZE=${efi_size}."
  [[ "${luks_size}" -ge "${minimum_luks_size}" ]] || die "La particion LUKS no ocupa el espacio restante esperado: ${luks_size} bytes"
  [[ "${luks_size}" -lt "${disk_size}" ]] || die "La particion LUKS tiene tamano invalido: ${luks_size} bytes"

  efi_type="$(partition_field "${efi_part}" PARTTYPE)"
  luks_type="$(partition_field "${luks_part}" PARTTYPE)"
  [[ "${efi_type,,}" == "${GPT_TYPE_EFI_SYSTEM,,}" ]] || die "GUID GPT EFI incorrecto: ${efi_type}"
  [[ "${luks_type,,}" == "${GPT_TYPE_LINUX_LUKS,,}" ]] || die "GUID GPT LUKS incorrecto: ${luks_type}"

  efi_label="$(partition_field "${efi_part}" PARTLABEL)"
  luks_label="$(partition_field "${luks_part}" PARTLABEL)"
  [[ "${efi_label}" == "EFI System" ]] || die "Nombre de particion EFI incorrecto: ${efi_label}"
  [[ "${luks_label}" == "Linux LUKS2 Btrfs" ]] || die "Nombre de particion LUKS incorrecto: ${luks_label}"

  success "Layout GPT final verificado correctamente en ${disk}."
}

show_block_identifiers() {
  local disk="$1"
  local device

  validate_target_disk "${disk}"
  require_command blkid lsblk
  log_section "Vista blkid resultante"
  while IFS= read -r device; do
    [[ -n "${device}" ]] || continue
    blkid "${device}" || true
  done < <(lsblk -nrpo NAME "${disk}" 2>/dev/null)
}

create_efi_partition_spec() {
  local efi_size="${1:-${EFI_SIZE:-${DEFAULT_EFI_SIZE}}}"

  validate_size_value "${efi_size}" "EFI_SIZE"
  printf 'size=%s,type=%s,name="EFI System"\n' "${efi_size}" "${GPT_TYPE_EFI_SYSTEM}"
}

create_luks_partition_spec() {
  printf 'type=%s,name="Linux LUKS2 Btrfs"\n' "${GPT_TYPE_LINUX_LUKS}"
}

format_efi_fat32() {
  local efi_part="$1"

  require_command mkfs.fat
  [[ -b "${efi_part}" ]] || die "La particion EFI no existe: ${efi_part}"
  ensure_block_device_not_mounted "${efi_part}"
  log_step "Formateando EFI en FAT32: ${efi_part}"
  mkfs.fat -F32 -n EFI "${efi_part}"
}
