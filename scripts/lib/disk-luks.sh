#!/usr/bin/env bash
# LUKS helpers for the Arch workstation installer.

set -euo pipefail

DISK_LUKS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F ensure_block_device_not_mounted >/dev/null 2>&1; then
  # shellcheck source=disk-common.sh
  source "${DISK_LUKS_LIB_DIR}/disk-common.sh"
fi

if ! declare -F verify_final_partition_layout >/dev/null 2>&1; then
  # shellcheck source=disk-partition.sh
  source "${DISK_LUKS_LIB_DIR}/disk-partition.sh"
fi

DEFAULT_CRYPT_NAME="${DEFAULT_CRYPT_NAME:-cryptroot}"

mapper_path() {
  local crypt_name="${1:-${CRYPT_NAME:-${DEFAULT_CRYPT_NAME}}}"

  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  printf '/dev/mapper/%s\n' "${crypt_name}"
}

mapper_is_active() {
  local crypt_name="${1:-${CRYPT_NAME:-${DEFAULT_CRYPT_NAME}}}"

  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  require_command cryptsetup
  cryptsetup status "${crypt_name}" >/dev/null 2>&1
}

cleanup_luks_mapper_on_failure() {
  local crypt_name="${1:-${CRYPT_NAME:-${DEFAULT_CRYPT_NAME}}}"

  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  require_command cryptsetup

  if mapper_is_active "${crypt_name}"; then
    log_warn "Fallo detectado: cerrando mapper LUKS ${crypt_name}."
    cryptsetup close "${crypt_name}" || log_warn "No se pudo cerrar el mapper LUKS ${crypt_name}."
  fi
}

device_is_luks() {
  local device="$1"

  [[ -b "${device}" ]] || return 1
  require_command cryptsetup
  cryptsetup isLuks "${device}" >/dev/null 2>&1
}

require_luks_partition_ready_for_format() {
  local disk="$1"
  local efi_size="${2:-${EFI_SIZE:-${DEFAULT_EFI_SIZE}}}"
  local crypt_name="${3:-${CRYPT_NAME:-${DEFAULT_CRYPT_NAME}}}"
  local luks_part

  validate_target_disk "${disk}"
  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  verify_final_partition_layout "${disk}" "${efi_size}"

  luks_part="$(luks_partition "${disk}")"
  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  ensure_block_device_not_mounted "${luks_part}"

  if mapper_is_active "${crypt_name}"; then
    die "El mapper LUKS ya esta activo: $(mapper_path "${crypt_name}")"
  fi

  if device_is_luks "${luks_part}"; then
    die "La particion ya contiene un contenedor LUKS valido: ${luks_part}"
  fi

  success "Prechecks LUKS completados para ${luks_part}."
}

confirm_luks_format() {
  local luks_part="$1"

  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  log_section "Confirmacion destructiva LUKS"
  log_warn "Se inicializara un contenedor LUKS2 en ${luks_part}."
  log_warn "Todo dato previo en esa particion sera irrecuperable."
  require_exact_confirmation "${luks_part}" "Confirma la particion exacta a cifrar."
}

format_luks2_container() {
  local luks_part="$1"

  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  ensure_block_device_not_mounted "${luks_part}"
  require_command cryptsetup

  log_warn "INICIO DESTRUCTIVO: creando contenedor LUKS2 en ${luks_part}"
  cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --hash sha256 \
    --pbkdf argon2id \
    --verify-passphrase \
    "${luks_part}"

  device_is_luks "${luks_part}" || die "No se pudo verificar LUKS despues de formatear: ${luks_part}"
  success "Contenedor LUKS2 inicializado correctamente en ${luks_part}."
}

open_luks_container() {
  local luks_part="$1"
  local crypt_name="${2:-${CRYPT_NAME:-${DEFAULT_CRYPT_NAME}}}"
  local mapper

  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  device_is_luks "${luks_part}" || die "La particion no contiene un contenedor LUKS valido: ${luks_part}"
  require_command cryptsetup udevadm

  if mapper_is_active "${crypt_name}"; then
    die "El mapper LUKS ya esta activo: $(mapper_path "${crypt_name}")"
  fi

  log_step "Abriendo contenedor LUKS ${luks_part} como ${crypt_name}"
  cryptsetup open "${luks_part}" "${crypt_name}"
  udevadm settle

  mapper="$(mapper_path "${crypt_name}")"
  [[ -b "${mapper}" ]] || die "No existe el mapper esperado: ${mapper}"
  mapper_is_active "${crypt_name}" || die "cryptsetup no reporta activo el mapper: ${crypt_name}"
  success "Contenedor LUKS abierto correctamente: ${mapper}"
}

verify_open_luks_container() {
  local luks_part="$1"
  local crypt_name="${2:-${CRYPT_NAME:-${DEFAULT_CRYPT_NAME}}}"
  local mapper

  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  require_command cryptsetup

  mapper="$(mapper_path "${crypt_name}")"
  [[ -b "${mapper}" ]] || die "No existe el mapper esperado: ${mapper}"
  cryptsetup status "${crypt_name}" >/dev/null || die "cryptsetup status fallo para ${crypt_name}"
  mapper_is_active "${crypt_name}" || die "El mapper no esta activo: ${mapper}"
  success "Mapper LUKS verificado: ${mapper}"
}

show_luks_diagnostics() {
  local luks_part="$1"
  local crypt_name="${2:-${CRYPT_NAME:-${DEFAULT_CRYPT_NAME}}}"

  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  require_command cryptsetup lsblk blkid awk

  log_section "cryptsetup status"
  cryptsetup status "${crypt_name}"
  show_luks_dump_summary "${luks_part}"
  log_section "Vista lsblk"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINTS "${luks_part}" "$(mapper_path "${crypt_name}")"
  log_section "Vista blkid"
  blkid "${luks_part}" "$(mapper_path "${crypt_name}")" || true
}

show_luks_dump_summary() {
  local luks_part="$1"

  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  require_command cryptsetup awk

  log_section "Resumen cryptsetup luksDump"
  cryptsetup luksDump "${luks_part}" | awk '
    function normalized_key(line) {
      sub(/:.*/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      return tolower(line)
    }

    {
      key = normalized_key($0)
      if (key == "version" || key == "uuid") {
        print
        next
      }
      if (key == "cipher" && cipher_printed == 0) {
        print
        cipher_printed = 1
        next
      }
      if (key == "pbkdf" && pbkdf_printed == 0) {
        print
        pbkdf_printed = 1
        next
      }
      if ($0 ~ /^Keyslots:/) {
        print
        in_keyslots = 1
        next
      }
      if (in_keyslots == 1 && $0 ~ /^[ \t]+[0-9]+:/) {
        print
        next
      }
      if (in_keyslots == 1 && $0 ~ /^[^ \t]/) {
        in_keyslots = 0
      }
    }
  '
}

luks_uuid() {
  local luks_part="$1"

  [[ -b "${luks_part}" ]] || die "La particion LUKS no existe: ${luks_part}"
  require_command cryptsetup
  cryptsetup luksUUID "${luks_part}"
}

show_luks_summary() {
  local luks_part="$1"
  local crypt_name="${2:-${CRYPT_NAME:-${DEFAULT_CRYPT_NAME}}}"
  local mapper

  mapper="$(mapper_path "${crypt_name}")"
  log_section "Resumen LUKS"
  log_kv "Particion LUKS" "${luks_part}"
  log_kv "LUKS UUID" "$(luks_uuid "${luks_part}")"
  log_kv "Mapper" "${mapper}"
  log_kv "Estado mapper" "$(mapper_is_active "${crypt_name}" && printf 'active' || printf 'inactive')"
}

create_luks2() {
  local luks_part="$1"

  format_luks2_container "${luks_part}"
}

open_luks() {
  local luks_part="$1"
  local crypt_name="${2:-${CRYPT_NAME:-${DEFAULT_CRYPT_NAME}}}"

  open_luks_container "${luks_part}" "${crypt_name}"
}
