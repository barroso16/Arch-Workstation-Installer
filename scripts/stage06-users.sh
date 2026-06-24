#!/usr/bin/env bash
# Stage06 Milestone 6.1: target users, passwords, sudo, and shell setup.
#
# This stage is intentionally interactive. It configures passwords only through
# passwd inside the installed target and never stores credentials in files.

set -euo pipefail

STAGE06_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE06_LIB_DIR="${STAGE06_DIR}/lib"
STAGE06_TARGET_ROOT="${STAGE06_TARGET_ROOT:-/mnt}"

# shellcheck source=lib/common.sh
source "${STAGE06_LIB_DIR}/common.sh"
# shellcheck source=lib/logging.sh
source "${STAGE06_LIB_DIR}/logging.sh"
# shellcheck source=lib/config.sh
source "${STAGE06_LIB_DIR}/config.sh"
# shellcheck source=lib/chroot.sh
source "${STAGE06_LIB_DIR}/chroot.sh"

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

STAGE06_APPLIED_GROUPS=""
STAGE06_SELECTED_SHELL=""

require_stage06_environment() {
  require_root
  require_arch_live_or_arch
}

load_stage06_config() {
  log_step "Cargando configuracion de instalacion"
  load_install_config
  validate_install_config
  success "Configuracion cargada y validada."
}

validate_stage06_target() {
  log_step "Validando target y chroot"
  validate_chroot_infrastructure "${STAGE06_TARGET_ROOT}"
}

configure_stage06_users() {
  export STAGE06_INTERACTIVE_PASSWORDS="yes"
  export STAGE06_CONFIGURE_SHELL="yes"

  log_step "Configurando usuario, grupos, sudo, shell y contrasenas"
  configure_target_users "${STAGE06_TARGET_ROOT}" "${USERNAME}" "wheel audio video storage input network"

  STAGE06_APPLIED_GROUPS="$(target_user_groups "${STAGE06_TARGET_ROOT}" "${USERNAME}")"
  STAGE06_SELECTED_SHELL="${TARGET_SELECTED_SHELL:-$(arch_chroot_capture "${STAGE06_TARGET_ROOT}" getent passwd "${USERNAME}" | awk -F: '{print $7}')}"
}

show_stage06_summary() {
  log_section "Resumen Stage06.1"
  log_kv "Target root" "${STAGE06_TARGET_ROOT}"
  log_kv "Usuario" "${USERNAME}"
  log_kv "Grupos aplicados" "${STAGE06_APPLIED_GROUPS}"
  log_kv "sudo wheel" "configurado y validado con visudo"
  log_kv "Shell seleccionada" "${STAGE06_SELECTED_SHELL}"
  log_kv "Contrasena root" "configurada interactivamente"
  log_kv "Contrasena usuario" "configurada interactivamente"
  success "Stage06 Milestone 6.1 completado."
}

main() {
  log_section "Stage06 - usuarios y sudo"
  require_stage06_environment
  load_stage06_config
  validate_stage06_target
  configure_stage06_users
  show_stage06_summary
}

main "$@"
