#!/usr/bin/env bash
# Main orchestrator for the Arch Workstation Installer.
#
# This script intentionally does not implement installation logic. Each stage is
# independent and must be executed as a separate Bash process. The orchestrator
# only validates the Live ISO environment, displays a menu, asks for destructive
# confirmation before Stage03 Storage, and stops immediately if any stage fails.

set -euo pipefail

INSTALL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_LIB_DIR="${INSTALL_DIR}/lib"

# shellcheck source=lib/common.sh
source "${INSTALL_LIB_DIR}/common.sh"
# shellcheck source=lib/logging.sh
source "${INSTALL_LIB_DIR}/logging.sh"

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

STAGE01="${INSTALL_DIR}/stage01-preflight.sh"
STAGE02="${INSTALL_DIR}/stage02-storage.sh"
STAGE03="${INSTALL_DIR}/stage03-storage.sh"
STAGE04="${INSTALL_DIR}/stage03-bootstrap.sh"
STAGE05="${INSTALL_DIR}/stage04-base-config.sh"
STAGE06="${INSTALL_DIR}/stage05-bootloader.sh"
STAGE07="${INSTALL_DIR}/stage06-system.sh"
STAGE08="${INSTALL_DIR}/stage07-hardening.sh"
STAGE09="${INSTALL_DIR}/stage08-finalize.sh"

require_arch_live_iso() {
  require_arch_live_or_arch

  [[ -d /run/archiso ]] || \
    die "El orquestador debe ejecutarse desde el Arch Linux Live ISO oficial."
}

validate_orchestrator_environment() {
  require_root
  require_arch_live_iso
  require_uefi
  require_command bash
}

show_installer_menu() {
  log_section "Arch Workstation Installer"
  printf '%s\n' "1 Stage01 Preflight"
  printf '%s\n' "2 Stage02 Disk Selection"
  printf '%s\n' "3 Stage03 Storage"
  printf '%s\n' "4 Stage03 Bootstrap"
  printf '%s\n' "5 Stage04 Base Config"
  printf '%s\n' "6 Stage05 Bootloader"
  printf '%s\n' "7 Stage06 System"
  printf '%s\n' "8 Stage07 Hardening"
  printf '%s\n' "9 Stage08 Finalize"
  printf '%s\n' "10 Ejecutar todos"
  printf '%s\n' "0 Salir"
}

read_menu_choice() {
  local choice

  printf '%s' "Selecciona una opcion: "
  read -r choice
  printf '%s\n' "$(trim "${choice}")"
}

stage_path_for_number() {
  local number="$1"

  case "${number}" in
    1) printf '%s\n' "${STAGE01}" ;;
    2) printf '%s\n' "${STAGE02}" ;;
    3) printf '%s\n' "${STAGE03}" ;;
    4) printf '%s\n' "${STAGE04}" ;;
    5) printf '%s\n' "${STAGE05}" ;;
    6) printf '%s\n' "${STAGE06}" ;;
    7) printf '%s\n' "${STAGE07}" ;;
    8) printf '%s\n' "${STAGE08}" ;;
    9) printf '%s\n' "${STAGE09}" ;;
    *) die "Stage invalido: ${number}" ;;
  esac
}

stage_name_for_number() {
  local number="$1"

  case "${number}" in
    1) printf '%s\n' "Stage01 Preflight" ;;
    2) printf '%s\n' "Stage02 Disk Selection" ;;
    3) printf '%s\n' "Stage03 Storage" ;;
    4) printf '%s\n' "Stage03 Bootstrap" ;;
    5) printf '%s\n' "Stage04 Base Config" ;;
    6) printf '%s\n' "Stage05 Bootloader" ;;
    7) printf '%s\n' "Stage06 System" ;;
    8) printf '%s\n' "Stage07 Hardening" ;;
    9) printf '%s\n' "Stage08 Finalize" ;;
    *) die "Stage invalido: ${number}" ;;
  esac
}

confirm_destructive_stage_if_needed() {
  local number="$1"

  [[ "${number}" == "3" ]] || return 0

  log_warn "ADVERTENCIA:"
  log_warn "A partir de Stage03 Storage comenzaran operaciones destructivas sobre el disco."
  confirm_yes_no "Deseas continuar con Stage03 Storage?" || die "Stage03 Storage cancelado por el usuario."
}

run_stage() {
  local number="$1"
  local stage_path
  local stage_name

  stage_path="$(stage_path_for_number "${number}")"
  stage_name="$(stage_name_for_number "${number}")"
  require_readable_file "${stage_path}"

  confirm_destructive_stage_if_needed "${number}"

  log_section "Ejecutando ${stage_name}"
  if bash "${stage_path}"; then
    success "${stage_name} completado."
  else
    log_error "${stage_name} fallo."
    return 1
  fi
}

run_all_stages() {
  local number

  for number in 1 2 3 4 5 6 7 8 9; do
    run_stage "${number}" || return 1
  done

  show_final_banner
}

show_final_banner() {
  printf '%s\n' "========================================="
  printf '%s\n' "ARCH WORKSTATION INSTALLER FINALIZADO"
  printf '%s\n' "========================================="
}

dispatch_choice() {
  local choice="$1"

  case "${choice}" in
    0)
      log_info "Salida solicitada por el usuario."
      ;;
    [1-9])
      run_stage "${choice}"
      if [[ "${choice}" == "9" ]]; then
        show_final_banner
      fi
      ;;
    10)
      run_all_stages
      ;;
    *)
      die "Opcion invalida: ${choice}"
      ;;
  esac
}

main() {
  local choice

  validate_orchestrator_environment
  show_installer_menu
  choice="$(read_menu_choice)"
  dispatch_choice "${choice}"
}

main "$@"
