#!/usr/bin/env bash
# fstab generation helpers for the Arch workstation installer.
#
# This library owns passive mount validation, one-shot genfstab execution,
# atomic /etc/fstab writing, and fstab content validation. It does not chroot,
# install packages, install a bootloader, or configure the target system.

set -euo pipefail

FSTAB_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F die >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${FSTAB_LIB_DIR}/common.sh"
fi

if ! declare -F log_section >/dev/null 2>&1; then
  # shellcheck source=logging.sh
  source "${FSTAB_LIB_DIR}/logging.sh"
fi

target_fstab_path() {
  local target_root="$1"

  validate_absolute_path "${target_root}"
  printf '%s/etc/fstab\n' "${target_root%/}"
}

require_fstab_root_mount() {
  local target_root="$1"
  local fstype
  local options

  require_directory "${target_root}"
  is_mounted "${target_root}" || die "${target_root} no esta montado."

  fstype="$(findmnt -no FSTYPE --target "${target_root}" 2>/dev/null || true)"
  options="$(findmnt -no OPTIONS --target "${target_root}" 2>/dev/null || true)"

  [[ "${fstype}" == "btrfs" ]] || die "${target_root} no esta montado como Btrfs."

  case ",${options}," in
    *",subvol=@,"*|*",subvol=/@,"*) ;;
    *) die "${target_root} no esta montado con el subvolumen raiz @." ;;
  esac
}

require_fstab_efi_mount() {
  local target_root="$1"
  local boot_mount="${target_root%/}/boot"
  local fstype

  require_directory "${boot_mount}"
  fstype="$(findmnt -no FSTYPE --target "${boot_mount}" 2>/dev/null || true)"

  case "${fstype}" in
    vfat|fat|msdos) ;;
    *) die "La particion EFI no esta montada en ${boot_mount} como FAT/VFAT." ;;
  esac
}

verify_fstab_generation_preconditions() {
  local target_root="$1"

  require_command findmnt genfstab grep
  require_fstab_root_mount "${target_root}"
  require_fstab_efi_mount "${target_root}"
  success "Montajes requeridos para genfstab verificados."
}

generate_fstab_content() {
  local target_root="$1"

  require_command genfstab
  genfstab -U "${target_root}"
}

backup_existing_fstab_if_present() {
  local fstab_file="$1"
  local backup_file

  [[ -e "${fstab_file}" ]] || return 0
  require_command cp date

  backup_file="${fstab_file}.bak.$(date '+%Y%m%d-%H%M%S')"
  log_warn "Ya existe un fstab y sera reemplazado: ${fstab_file}"
  cp -a -- "${fstab_file}" "${backup_file}"
  log_warn "Backup de fstab creado: ${backup_file}"
}

write_generated_fstab() {
  local target_root="$1"
  local fstab_file

  fstab_file="$(target_fstab_path "${target_root}")"
  require_directory "$(dirname -- "${fstab_file}")"
  verify_fstab_generation_preconditions "${target_root}"
  backup_existing_fstab_if_present "${fstab_file}"
  log_step "Generando fstab con genfstab -U"
  generate_fstab_content "${target_root}" | write_file_atomic "${fstab_file}"
}

fstab_live_iso_pattern() {
  printf '%s\n' '(/hgfs|hgfs|vmhgfs|fuse[.]vmhgfs-fuse)'
}

fstab_contains_live_iso_entries() {
  local fstab_file="$1"

  grep -Eq "$(fstab_live_iso_pattern)" "${fstab_file}"
}

filter_live_iso_fstab_entries() {
  local target_root="$1"
  local fstab_file
  local backup_file
  local pattern
  local before_count
  local after_count
  local removed_count

  fstab_file="$(target_fstab_path "${target_root}")"
  backup_file="${fstab_file}.bak-before-filter"
  pattern="$(fstab_live_iso_pattern)"

  require_readable_file "${fstab_file}"
  if ! fstab_contains_live_iso_entries "${fstab_file}"; then
    log_info "fstab no contiene entradas heredadas del Live ISO."
    return 0
  fi

  require_command awk cp wc tr
  before_count="$(wc -l < "${fstab_file}" | tr -d '[:space:]')"
  cp -a -- "${fstab_file}" "${backup_file}"
  log_warn "Se detectaron entradas no-target heredadas del Live ISO en fstab."
  log_warn "Backup creado antes del filtrado: ${backup_file}"

  awk -v pattern="${pattern}" '$0 !~ pattern' "${fstab_file}" | write_file_atomic "${fstab_file}"

  after_count="$(wc -l < "${fstab_file}" | tr -d '[:space:]')"
  removed_count="$((before_count - after_count))"
  log_warn "Entradas eliminadas de fstab por filtrado Live ISO: ${removed_count}"
}

validate_no_live_iso_fstab_entries() {
  local target_root="$1"
  local fstab_file

  fstab_file="$(target_fstab_path "${target_root}")"
  require_readable_file "${fstab_file}"

  if fstab_contains_live_iso_entries "${fstab_file}"; then
    die "fstab contiene entradas heredadas del Live ISO hgfs/vmhgfs/fuse.vmhgfs-fuse: ${fstab_file}"
  fi
}

validate_generated_fstab() {
  local target_root="$1"
  local fstab_file

  fstab_file="$(target_fstab_path "${target_root}")"

  require_readable_file "${fstab_file}"
  [[ -s "${fstab_file}" ]] || die "fstab esta vacio: ${fstab_file}"
  grep -q 'UUID=' "${fstab_file}" || die "fstab no contiene entradas UUID=: ${fstab_file}"
  grep -Eq 'subvol=/?@([[:space:],]|$)' "${fstab_file}" || die "fstab no contiene el subvolumen raiz @."
  grep -Eq 'subvol=/?@home([[:space:],]|$)' "${fstab_file}" || die "fstab no contiene el subvolumen @home."
  grep -q 'compress=zstd' "${fstab_file}" || die "fstab no contiene compress=zstd."
  grep -Eq '[[:space:]]/boot[[:space:]]' "${fstab_file}" || die "fstab no contiene el montaje EFI /boot."
  validate_no_live_iso_fstab_entries "${target_root}"
  success "fstab validado correctamente: ${fstab_file}"
}

print_generated_fstab() {
  local target_root="$1"
  local fstab_file

  fstab_file="$(target_fstab_path "${target_root}")"
  require_readable_file "${fstab_file}"

  log_section "fstab generado"
  cat "${fstab_file}"
}

show_fstab_summary() {
  local target_root="$1"
  local fstab_file

  fstab_file="$(target_fstab_path "${target_root}")"

  log_section "Resumen fstab"
  log_kv "Target root" "${target_root}"
  log_kv "Archivo" "${fstab_file}"
  log_kv "Root subvolume" "@"
  log_kv "Home subvolume" "@home"
  log_kv "EFI mount" "/boot"
  success "Stage04 Milestone 4.2 completado. fstab generado atomica e idempotentemente."
}

configure_target_fstab() {
  local target_root="$1"

  write_generated_fstab "${target_root}"
  filter_live_iso_fstab_entries "${target_root}"
  validate_generated_fstab "${target_root}"
  print_generated_fstab "${target_root}"
  show_fstab_summary "${target_root}"
}
