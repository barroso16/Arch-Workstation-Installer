#!/usr/bin/env bash
# Stage03 Milestone 3.1: final non-destructive storage validation.
#
# This milestone validates the selected target disk and shows the future storage
# plan. It intentionally stops after exact confirmation and does not partition,
# wipe, format, encrypt, attach filesystems, install packages, or write state files.

set -euo pipefail

STAGE03_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAGE03_LIB_DIR="${STAGE03_DIR}/lib"

# shellcheck source=lib/common.sh
source "${STAGE03_LIB_DIR}/common.sh"
# shellcheck source=lib/logging.sh
source "${STAGE03_LIB_DIR}/logging.sh"
# shellcheck source=lib/config.sh
source "${STAGE03_LIB_DIR}/config.sh"
# shellcheck source=lib/hardware.sh
source "${STAGE03_LIB_DIR}/hardware.sh"
# shellcheck source=lib/disk-common.sh
source "${STAGE03_LIB_DIR}/disk-common.sh"

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_arch_live_iso() {
  require_arch_live_or_arch

  [[ -d /run/archiso ]] || \
    die "Stage03 debe ejecutarse desde el Arch Linux Live ISO oficial."
}

require_stage03_commands() {
  require_command lsblk awk basename findmnt realpath
}

require_stage03_target_disk() {
  [[ -n "${TARGET_DISK:-}" ]] || \
    die "TARGET_DISK no esta configurado. Ejecuta Stage02 antes de Stage03."
}

validate_stage03_target_disk() {
  require_stage03_target_disk

  if ! hardware_disk_in_inventory "${TARGET_DISK}"; then
    die "El disco seleccionado durante Stage02 ya no esta disponible en el inventario actual: ${TARGET_DISK}"
  fi

  hardware_validate_installable_disk "${TARGET_DISK}"
}

show_stage03_disk_review() {
  log_section "Revision del disco seleccionado"
  hardware_show_disk_details "${TARGET_DISK}"
  hardware_warn_if_removable_disk "${TARGET_DISK}"
  hardware_warn_if_live_iso_disk "${TARGET_DISK}"
  hardware_warn_if_disk_has_mounts "${TARGET_DISK}"
}

show_stage03_future_layout() {
  local subvolume

  log_section "Plan futuro de almacenamiento"
  log_warn "Esta etapa solo muestra el plan. No se ejecutara ninguna accion destructiva."
  log_kv "Disco objetivo" "${TARGET_DISK}"
  log_kv "Tabla de particiones" "GPT"
  log_kv "Particion EFI" "EFI System Partition (${EFI_SIZE})"
  log_kv "Particion cifrada" "LUKS2 con el espacio restante"
  log_kv "Mapper LUKS" "${CRYPT_NAME}"
  log_kv "Sistema de archivos" "Btrfs"

  log_header "Subvolumenes Btrfs previstos"
  while IFS= read -r subvolume; do
    [[ -n "${subvolume}" ]] || continue
    log_kv "Subvolumen" "${subvolume}"
  done < <(default_btrfs_subvolumes)
}

confirm_stage03_target_disk() {
  log_section "Confirmacion exacta"
  log_warn "La futura etapa destructiva usara este disco si continuas mas adelante."
  log_warn "En este milestone no se borrara, particionara ni formateara nada."
  require_exact_confirmation "${TARGET_DISK}" "Confirma el disco exacto validado por Stage03."
}

show_stage03_summary() {
  log_section "Resumen Stage03"
  log_kv "Disco validado" "${TARGET_DISK}"
  success "Stage03 Milestone 3.1 completado. No se ejecuto ninguna accion destructiva."
}

main() {
  log_section "Stage03 - Validacion de almacenamiento"
  require_root
  require_arch_live_iso
  require_uefi
  require_stage03_commands

  log_step "Cargando configuracion"
  load_install_config
  validate_install_config
  success "Configuracion cargada y validada."

  log_step "Actualizando inventario de discos"
  hardware_refresh_disk_inventory
  [[ "$(hardware_disk_count)" -gt 0 ]] || die "No se detectaron discos instalables."

  validate_stage03_target_disk
  show_stage03_disk_review
  show_stage03_future_layout
  confirm_stage03_target_disk
  show_stage03_summary
}

main "$@"
