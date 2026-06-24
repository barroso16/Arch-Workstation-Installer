#!/usr/bin/env bash
# LUKS helpers for the Arch workstation installer.

set -euo pipefail

DISK_LUKS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F ensure_block_device_not_mounted >/dev/null 2>&1; then
  # shellcheck source=disk-common.sh
  source "${DISK_LUKS_LIB_DIR}/disk-common.sh"
fi

DEFAULT_CRYPT_NAME="${DEFAULT_CRYPT_NAME:-cryptroot}"

create_luks2() {
  local luks_part="$1"

  require_command cryptsetup
  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  ensure_block_device_not_mounted "${luks_part}"
  log_step "Creando contenedor LUKS2 en ${luks_part}"
  cryptsetup luksFormat --type luks2 --batch-mode "${luks_part}"
}

open_luks() {
  local luks_part="$1"
  local crypt_name="${2:-${CRYPT_NAME:-${DEFAULT_CRYPT_NAME}}}"

  require_command cryptsetup
  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  log_step "Abriendo LUKS ${luks_part} como ${crypt_name}"
  cryptsetup open "${luks_part}" "${crypt_name}"
}
