#!/usr/bin/env bash
# Stage01: preflight validation for the Arch workstation installer.
#
# This stage only validates the live environment, loads configuration, detects
# hardware, shows summaries, and asks whether the operator wants to continue
# manually with Stage02. It must not modify disks, mount filesystems, install
# packages, configure bootloaders, configure Secure Boot, or enter chroot.

set -euo pipefail

STAGE01_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE01_LIB_DIR="${STAGE01_DIR}/lib"

# shellcheck source=lib/common.sh
source "${STAGE01_LIB_DIR}/common.sh"
# shellcheck source=lib/logging.sh
source "${STAGE01_LIB_DIR}/logging.sh"
# shellcheck source=lib/config.sh
source "${STAGE01_LIB_DIR}/config.sh"
# shellcheck source=lib/hardware.sh
source "${STAGE01_LIB_DIR}/hardware.sh"
# shellcheck source=lib/verify.sh
source "${STAGE01_LIB_DIR}/verify.sh"

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

STAGE01_REQUIRED_COMMANDS=(
  lsblk
  blkid
  cryptsetup
  btrfs
  pacstrap
  arch-chroot
  bootctl
  findmnt
  awk
  sed
  grep
)

require_arch_live_iso() {
  require_arch_live_or_arch

  [[ -d /run/archiso ]] || \
    die "Este stage debe ejecutarse desde el Arch Linux Live ISO oficial."
}

require_stage01_commands() {
  log_step "Comprobando comandos minimos del Live ISO"
  require_command "${STAGE01_REQUIRED_COMMANDS[@]}"
  success "Comandos minimos disponibles."
}

check_preconfigured_target_disk() {
  [[ -n "${TARGET_DISK:-}" ]] || return 0

  log_header "Disco objetivo preconfigurado"
  log_kv "TARGET_DISK" "${TARGET_DISK}"

  [[ -b "${TARGET_DISK}" ]] || \
    die "TARGET_DISK no existe o no es un dispositivo de bloque: ${TARGET_DISK}"

  warn_if_removable_disk "${TARGET_DISK}"
  success "TARGET_DISK existe. No se ha realizado ninguna accion destructiva."
}

run_live_passive_verification() {
  log_section "Verificacion pasiva del entorno Live"
  reset_verify_counters

  if [[ "${EUID}" -eq 0 ]]; then
    verify_pass "Ejecucion como root"
  else
    verify_fail "El script no se esta ejecutando como root"
  fi

  if [[ -r /etc/os-release ]] && grep -q '^ID=arch$' /etc/os-release; then
    verify_pass "Sistema base Arch Linux detectado"
  else
    verify_fail "No se detecto Arch Linux en /etc/os-release"
  fi

  if [[ -d /run/archiso ]]; then
    verify_pass "Arch Linux Live ISO detectado"
  else
    verify_fail "No se detecto /run/archiso"
  fi

  verify_uefi
  verify_secure_boot_state
  verify_setup_mode_state

  if detect_network_available; then
    verify_pass "Conectividad de red disponible"
  else
    verify_warn "No se confirmo conectividad real hacia archlinux.org"
  fi

  if [[ "$(count_available_disks)" -gt 0 ]]; then
    verify_pass "Discos candidatos detectados"
  else
    verify_fail "No se detectaron discos candidatos"
  fi

  if [[ -n "${TARGET_DISK:-}" ]]; then
    if [[ -b "${TARGET_DISK}" ]]; then
      verify_pass "TARGET_DISK existe: ${TARGET_DISK}"
      if is_removable_disk "${TARGET_DISK}"; then
        verify_warn "TARGET_DISK parece USB/removible: ${TARGET_DISK}"
      fi
    else
      verify_fail "TARGET_DISK no existe: ${TARGET_DISK}"
    fi
  else
    verify_warn "TARGET_DISK no esta preconfigurado"
  fi

  for command_name in "${STAGE01_REQUIRED_COMMANDS[@]}"; do
    if command_exists "${command_name}"; then
      verify_pass "Comando disponible: ${command_name}"
    else
      verify_fail "Comando faltante: ${command_name}"
    fi
  done

  verify_summary
}

confirm_stage02_continuation() {
  log_section "Confirmacion final de Stage01"

  if confirm_yes_no "Deseas continuar con Stage02?"; then
    success "Stage01 completado. Ejecuta Stage02 manualmente cuando estes listo."
    return 0
  fi

  die "Stage01 abortado limpiamente por el usuario. Stage02 no se ejecutara."
}

main() {
  log_section "Stage01 - Preflight"
  log_step "Comprobando privilegios y entorno Live"
  require_root
  require_arch_live_iso
  require_uefi
  require_stage01_commands

  log_step "Cargando configuracion"
  load_install_config
  validate_install_config
  success "Configuracion cargada y validada."

  show_hardware_summary
  validate_install_hardware

  show_effective_config
  show_disk_summary
  check_preconfigured_target_disk

  run_live_passive_verification
  confirm_stage02_continuation
}

main "$@"
