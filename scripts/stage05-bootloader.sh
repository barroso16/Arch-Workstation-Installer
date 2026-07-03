#!/usr/bin/env bash
# Stage05 Milestone 5.6: configure systemd-boot and enroll Secure Boot keys.
#
# This stage is orchestration-only. It installs systemd-boot into the mounted
# EFI System Partition using helpers from bootloader.sh, writes loader.conf and
# arch.conf, and only prepares/signs/enrolls Secure Boot artifacts when Secure
# Boot support is enabled in configs/install.conf.

set -euo pipefail

STAGE05_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE05_LIB_DIR="${STAGE05_DIR}/lib"
STAGE05_TARGET_ROOT="${STAGE05_TARGET_ROOT:-/mnt}"

# shellcheck source=lib/common.sh
source "${STAGE05_LIB_DIR}/common.sh"
# shellcheck source=lib/logging.sh
source "${STAGE05_LIB_DIR}/logging.sh"
# shellcheck source=lib/config.sh
source "${STAGE05_LIB_DIR}/config.sh"
# shellcheck source=lib/chroot.sh
source "${STAGE05_LIB_DIR}/chroot.sh"
# shellcheck source=lib/bootloader.sh
source "${STAGE05_LIB_DIR}/bootloader.sh"

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_arch_live_iso() {
  require_arch_live_or_arch

  [[ -d /run/archiso ]] || \
    die "Stage05 debe ejecutarse desde el Arch Linux Live ISO oficial."
}

require_stage05_commands() {
  require_command findmnt arch-chroot
}

stage05_secure_boot_requested() {
  is_yes "${ENABLE_SECURE_BOOT:-no}" || is_yes "${SBCTL_CREATE_KEYS:-no}"
}

run_stage05_secure_boot_if_requested() {
  if ! stage05_secure_boot_requested; then
    SECURE_BOOT_KEYS_STATUS="disabled"
    SECURE_BOOT_SIGNING_STATUS="skipped"
    SECURE_BOOT_VERIFY_STATUS="skipped"
    SECURE_BOOT_ENROLLMENT_STATUS="skipped"
    export SECURE_BOOT_KEYS_STATUS SECURE_BOOT_SIGNING_STATUS SECURE_BOOT_VERIFY_STATUS SECURE_BOOT_ENROLLMENT_STATUS
    log_warn "Secure Boot desactivado en configuracion; se omite sbctl."
    return 0
  fi

  log_step "Preparando claves Secure Boot con sbctl"
  prepare_secure_boot_keys "${STAGE05_TARGET_ROOT}"

  log_step "Firmando artefactos Secure Boot con sbctl"
  sign_secure_boot_candidates "${STAGE05_TARGET_ROOT}"

  log_step "Solicitando confirmacion y enrolando claves Secure Boot"
  enroll_secure_boot_keys "${STAGE05_TARGET_ROOT}"
}

show_stage05_bootloader_summary() {
  log_section "Resumen Stage05.6"
  log_kv "Target root" "${STAGE05_TARGET_ROOT}"
  log_kv "EFI mount" "$(target_boot_path "${STAGE05_TARGET_ROOT}")"
  log_kv "Loader path" "$(target_loader_path "${STAGE05_TARGET_ROOT}")"
  log_kv "Entries path" "$(target_loader_entries_path "${STAGE05_TARGET_ROOT}")"
  log_kv "loader.conf" "$(target_loader_conf_path "${STAGE05_TARGET_ROOT}")"
  log_kv "arch.conf" "$(target_arch_entry_path "${STAGE05_TARGET_ROOT}")"
  log_kv "systemd-boot EFI" "$(target_systemd_boot_efi_path "${STAGE05_TARGET_ROOT}")"
  log_kv "Instalacion" "${BOOTLOADER_INSTALL_STATUS}"
  log_kv "Bootloader" "instalado/configurado"
  log_kv "Firma" "${SECURE_BOOT_SIGNING_STATUS}"
  log_kv "sbctl verify" "${SECURE_BOOT_VERIFY_STATUS}"
  log_kv "Enrolamiento" "${SECURE_BOOT_ENROLLMENT_STATUS}"
  show_secure_boot_preparation_summary "${STAGE05_TARGET_ROOT}"
  success "Stage05 Milestone 5.6 completado."
}

main() {
  log_section "Stage05 - systemd-boot"
  require_root
  require_arch_live_iso
  require_uefi
  require_stage05_commands

  log_step "Cargando configuracion"
  load_install_config
  validate_install_config
  success "Configuracion cargada y validada."

  log_step "Instalando o reutilizando systemd-boot"
  install_systemd_boot "${STAGE05_TARGET_ROOT}"

  log_step "Configurando loader.conf y arch.conf"
  configure_systemd_boot_loader_and_arch_entry "${STAGE05_TARGET_ROOT}"

  run_stage05_secure_boot_if_requested

  show_stage05_bootloader_summary
}

main "$@"
