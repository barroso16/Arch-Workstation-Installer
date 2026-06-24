#!/usr/bin/env bash
# Stage02: select and persist the target installation disk.
#
# This stage is non-destructive by design. It never partitions, wipes, formats,
# encrypts, mounts, installs packages, or touches bootloader state. Its only
# responsibility is choosing a full disk and persisting TARGET_DISK safely.
# It also lets the operator set the primary username before later stages create
# accounts. It never asks for or stores passwords.

set -euo pipefail

STAGE02_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE02_LIB_DIR="${STAGE02_DIR}/lib"
STAGE02_SELECTED_DISK=""
STAGE02_SELECTED_USERNAME=""

# shellcheck source=lib/common.sh
source "${STAGE02_LIB_DIR}/common.sh"
# shellcheck source=lib/logging.sh
source "${STAGE02_LIB_DIR}/logging.sh"
# shellcheck source=lib/config.sh
source "${STAGE02_LIB_DIR}/config.sh"
# shellcheck source=lib/hardware.sh
source "${STAGE02_LIB_DIR}/hardware.sh"

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_arch_live_iso() {
  require_arch_live_or_arch

  [[ -d /run/archiso ]] || \
    die "Stage02 debe ejecutarse desde el Arch Linux Live ISO oficial."
}

require_stage02_commands() {
  require_command lsblk awk basename findmnt realpath
}

validate_and_warn_selected_disk() {
  local disk="$1"

  hardware_validate_installable_disk "${disk}"
  hardware_show_disk_details "${disk}"
  hardware_warn_if_removable_disk "${disk}"
  hardware_warn_if_live_iso_disk "${disk}"
  hardware_warn_if_disk_has_mounts "${disk}"
}

configured_disk_is_reusable() {
  local disk="$1"

  [[ -n "${disk}" ]] || return 1

  if ! hardware_disk_in_inventory "${disk}"; then
    log_warn "TARGET_DISK configurado no es instalable actualmente: ${disk}"
    return 1
  fi

  log_section "TARGET_DISK existente"
  validate_and_warn_selected_disk "${disk}"
  confirm_yes_no "Quieres reutilizar TARGET_DISK=${disk}?"
}

read_disk_selection() {
  log_header "Seleccion de disco"
  log_info "Escribe el disco completo, por ejemplo /dev/nvme0n1."
  printf 'Disco objetivo: '
  read -r STAGE02_SELECTED_DISK
  STAGE02_SELECTED_DISK="$(trim "${STAGE02_SELECTED_DISK}")"
  hardware_validate_installable_disk "${STAGE02_SELECTED_DISK}"
}

select_target_disk() {
  if configured_disk_is_reusable "${TARGET_DISK:-}"; then
    STAGE02_SELECTED_DISK="${TARGET_DISK}"
    return 0
  fi

  read_disk_selection
}

confirm_selected_disk() {
  local disk="$1"

  log_section "Confirmacion final"
  printf '%s\n' "Selected disk:"
  printf '%s\n\n' "${disk}"
  log_warn "WARNING:"
  log_warn "ALL DATA ON THIS DEVICE WILL BE LOST."
  require_exact_confirmation "${disk}" "Confirma el disco exacto antes de guardar TARGET_DISK."
}

persist_target_disk() {
  local disk="$1"

  replace_or_append_kv "${CONFIG_FILE}" "TARGET_DISK" "${disk}"
  load_install_config
  validate_install_config
  [[ "${TARGET_DISK}" == "${disk}" ]] || die "TARGET_DISK no coincide despues de guardar configuracion."
  load_config >/dev/null
}

configured_username_is_placeholder() {
  local configured_username

  configured_username="$(awk -F= '
    $1 == "USERNAME" {
      value = $0
      sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^'\''|'\''$/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "${CONFIG_FILE}")"

  [[ -z "${configured_username}" || "${configured_username}" == "user" ]]
}

read_primary_username() {
  local username

  log_header "Usuario principal"
  log_info "Nombre de usuario principal [default: user]"
  printf 'Nombre de usuario principal: '
  read -r username
  username="$(trim "${username}")"
  username="${username:-user}"
  validate_username_value "${username}"
  STAGE02_SELECTED_USERNAME="${username}"
}

select_primary_username() {
  if configured_username_is_placeholder; then
    read_primary_username
    return 0
  fi

  validate_username_value "${USERNAME}"
  STAGE02_SELECTED_USERNAME="${USERNAME}"
  log_info "USERNAME configurado: ${STAGE02_SELECTED_USERNAME}"
}

persist_primary_username() {
  local username="$1"

  validate_username_value "${username}"
  replace_or_append_kv "${CONFIG_FILE}" "USERNAME" "${username}"
  load_install_config
  validate_install_config
  [[ "${USERNAME}" == "${username}" ]] || die "USERNAME no coincide despues de guardar configuracion."
  load_config >/dev/null
}

show_stage02_summary() {
  local disk="$1"

  log_section "Resumen Stage02"
  log_kv "Selected disk" "${disk}"
  log_kv "Usuario principal" "${STAGE02_SELECTED_USERNAME}"
  success "Configuration updated successfully"
}

main() {
  log_section "Stage02 - Disk Selection"
  require_root
  require_arch_live_iso
  require_uefi
  require_stage02_commands

  log_step "Cargando configuracion"
  load_install_config
  validate_install_config
  success "Configuracion cargada y validada."

  show_hardware_summary
  validate_install_hardware
  hardware_load_disk_inventory
  [[ "$(hardware_disk_count)" -gt 0 ]] || die "No se detectaron discos instalables."
  hardware_show_disk_inventory_table

  select_target_disk
  select_primary_username
  validate_and_warn_selected_disk "${STAGE02_SELECTED_DISK}"
  confirm_selected_disk "${STAGE02_SELECTED_DISK}"
  persist_target_disk "${STAGE02_SELECTED_DISK}"
  persist_primary_username "${STAGE02_SELECTED_USERNAME}"
  show_stage02_summary "${STAGE02_SELECTED_DISK}"
}

main "$@"
