#!/usr/bin/env bash
# Configuration helpers for the Arch workstation installer.
#
# This library validates configs/install.conf and exposes helpers to print the
# effective configuration before any stage performs work. It does not partition,
# format, install packages, or modify the target system.

set -euo pipefail

CONFIG_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F die >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${CONFIG_LIB_DIR}/common.sh"
fi

if ! declare -F log_section >/dev/null 2>&1; then
  # shellcheck source=logging.sh
  source "${CONFIG_LIB_DIR}/logging.sh"
fi

CONFIG_LOADED="no"
CONFIG_VALIDATED="no"

set_config_defaults() {
  HOSTNAME="${HOSTNAME:-arch-pro}"
  USERNAME="${USERNAME:-operator}"
  TIMEZONE="${TIMEZONE:-UTC}"
  LOCALE="${LOCALE:-en_US.UTF-8}"
  KEYMAP="${KEYMAP:-us}"

  EFI_SIZE="${EFI_SIZE:-1G}"
  CRYPT_NAME="${CRYPT_NAME:-cryptroot}"
  BTRFS_COMPRESS="${BTRFS_COMPRESS:-zstd}"
  BTRFS_LABEL="${BTRFS_LABEL:-ARCHROOT}"

  INSTALL_DEV_PROFILE="${INSTALL_DEV_PROFILE:-yes}"
  INSTALL_VIRT_PROFILE="${INSTALL_VIRT_PROFILE:-yes}"
  INSTALL_CONTAINERS_PROFILE="${INSTALL_CONTAINERS_PROFILE:-yes}"
  INSTALL_AUDIT_PROFILE="${INSTALL_AUDIT_PROFILE:-yes}"
  INSTALL_HARDENING_PROFILE="${INSTALL_HARDENING_PROFILE:-yes}"
  INSTALL_SHELL_PROFILE="${INSTALL_SHELL_PROFILE:-yes}"
  INSTALL_EDITOR_PROFILE="${INSTALL_EDITOR_PROFILE:-yes}"
  INSTALL_DESKTOP_PROFILE="${INSTALL_DESKTOP_PROFILE:-yes}"
  INSTALL_NETWORK_PROFILE="${INSTALL_NETWORK_PROFILE:-yes}"
  INSTALL_NVIDIA_IF_DETECTED="${INSTALL_NVIDIA_IF_DETECTED:-yes}"

  INSTALL_OH_MY_ZSH="${INSTALL_OH_MY_ZSH:-yes}"
  INSTALL_POWERLEVEL10K="${INSTALL_POWERLEVEL10K:-yes}"

  SBCTL_CREATE_KEYS="${SBCTL_CREATE_KEYS:-yes}"
  SBCTL_ENROLL_MICROSOFT_KEYS="${SBCTL_ENROLL_MICROSOFT_KEYS:-no}"

  TARGET_DISK="${TARGET_DISK:-}"
}

load_install_config() {
  load_config
  set_config_defaults
  CONFIG_LOADED="yes"
  export CONFIG_LOADED
}

ensure_install_config_loaded() {
  [[ "${CONFIG_LOADED}" == "yes" ]] || die "La configuracion no esta cargada. Ejecuta load_install_config primero."
}

validate_hostname_value() {
  local value="$1"

  [[ ${#value} -ge 1 && ${#value} -le 63 ]] || die "HOSTNAME debe tener entre 1 y 63 caracteres."
  [[ "${value}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || \
    die "HOSTNAME no es valido: ${value}"
}

validate_username_value() {
  local value="$1"

  [[ ${#value} -ge 1 && ${#value} -le 32 ]] || die "USERNAME debe tener entre 1 y 32 caracteres."
  [[ "${value}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "USERNAME no es valido: ${value}"
  [[ "${value}" != "root" ]] || die "USERNAME no puede ser root."
}

validate_timezone_value() {
  local value="$1"

  [[ "${value}" == */* || "${value}" == "UTC" ]] || die "TIMEZONE debe ser UTC o Area/Ciudad: ${value}"

  if [[ -d /usr/share/zoneinfo ]]; then
    [[ "${value}" == "UTC" || -f "/usr/share/zoneinfo/${value}" ]] || \
      die "TIMEZONE no existe en /usr/share/zoneinfo: ${value}"
  fi
}

validate_locale_value() {
  local value="$1"

  [[ "${value}" =~ ^[A-Za-z][A-Za-z0-9_@.-]*\.UTF-8$ ]] || die "LOCALE debe terminar en .UTF-8: ${value}"
}

validate_keymap_value() {
  local value="$1"

  [[ "${value}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "KEYMAP contiene caracteres no validos: ${value}"

  if [[ -d /usr/share/kbd/keymaps ]]; then
    find /usr/share/kbd/keymaps -type f \( -name "${value}.map.gz" -o -name "${value}.map" \) | grep -q . || \
      die "KEYMAP no encontrado en /usr/share/kbd/keymaps: ${value}"
  fi
}

validate_target_disk_value() {
  local value="$1"

  [[ -z "${value}" ]] && return 0
  validate_absolute_path "${value}"
  [[ "${value}" == /dev/* ]] || die "TARGET_DISK debe estar bajo /dev: ${value}"
  [[ -b "${value}" ]] || die "TARGET_DISK no es un dispositivo de bloque: ${value}"
}

validate_size_value() {
  local value="$1"
  local label="$2"

  [[ "${value}" =~ ^[1-9][0-9]*([KMGTP]i?B?|[kmgpt])?$ ]] || \
    die "${label} tiene formato de tamano invalido: ${value}"
}

validate_boolean_value() {
  local value="$1"
  local label="$2"

  is_yes "${value}" || is_no "${value}" || die "${label} debe ser yes/no, true/false o 1/0: ${value}"
}

validate_btrfs_label_value() {
  local value="$1"

  [[ ${#value} -ge 1 && ${#value} -le 64 ]] || die "BTRFS_LABEL debe tener entre 1 y 64 caracteres."
  [[ "${value}" =~ ^[A-Za-z0-9._-]+$ ]] || die "BTRFS_LABEL contiene caracteres no validos: ${value}"
}

validate_install_config() {
  ensure_install_config_loaded

  require_variable HOSTNAME
  require_variable USERNAME
  require_variable TIMEZONE
  require_variable LOCALE
  require_variable KEYMAP
  require_variable EFI_SIZE
  require_variable CRYPT_NAME
  require_variable BTRFS_COMPRESS
  require_variable BTRFS_LABEL

  validate_hostname_value "${HOSTNAME}"
  validate_username_value "${USERNAME}"
  validate_timezone_value "${TIMEZONE}"
  validate_locale_value "${LOCALE}"
  validate_keymap_value "${KEYMAP}"
  validate_target_disk_value "${TARGET_DISK}"
  validate_size_value "${EFI_SIZE}" "EFI_SIZE"
  validate_shell_identifier "${CRYPT_NAME}" "CRYPT_NAME"
  validate_btrfs_label_value "${BTRFS_LABEL}"

  case "${BTRFS_COMPRESS}" in
    zstd|lzo|no|none) ;;
    *) die "BTRFS_COMPRESS no soportado: ${BTRFS_COMPRESS}" ;;
  esac

  validate_boolean_value "${INSTALL_DEV_PROFILE}" "INSTALL_DEV_PROFILE"
  validate_boolean_value "${INSTALL_VIRT_PROFILE}" "INSTALL_VIRT_PROFILE"
  validate_boolean_value "${INSTALL_CONTAINERS_PROFILE}" "INSTALL_CONTAINERS_PROFILE"
  validate_boolean_value "${INSTALL_AUDIT_PROFILE}" "INSTALL_AUDIT_PROFILE"
  validate_boolean_value "${INSTALL_HARDENING_PROFILE}" "INSTALL_HARDENING_PROFILE"
  validate_boolean_value "${INSTALL_SHELL_PROFILE}" "INSTALL_SHELL_PROFILE"
  validate_boolean_value "${INSTALL_EDITOR_PROFILE}" "INSTALL_EDITOR_PROFILE"
  validate_boolean_value "${INSTALL_DESKTOP_PROFILE}" "INSTALL_DESKTOP_PROFILE"
  validate_boolean_value "${INSTALL_NETWORK_PROFILE}" "INSTALL_NETWORK_PROFILE"
  validate_boolean_value "${INSTALL_NVIDIA_IF_DETECTED}" "INSTALL_NVIDIA_IF_DETECTED"
  validate_boolean_value "${INSTALL_OH_MY_ZSH}" "INSTALL_OH_MY_ZSH"
  validate_boolean_value "${INSTALL_POWERLEVEL10K}" "INSTALL_POWERLEVEL10K"
  validate_boolean_value "${SBCTL_CREATE_KEYS}" "SBCTL_CREATE_KEYS"
  validate_boolean_value "${SBCTL_ENROLL_MICROSOFT_KEYS}" "SBCTL_ENROLL_MICROSOFT_KEYS"

  CONFIG_VALIDATED="yes"
  export CONFIG_VALIDATED
}

ensure_install_config_validated() {
  [[ "${CONFIG_VALIDATED}" == "yes" ]] || die "La configuracion no esta validada. Ejecuta validate_install_config primero."
}

show_effective_config() {
  ensure_install_config_loaded

  log_section "Configuracion efectiva"
  log_header "Sistema"
  log_kv "Hostname" "${HOSTNAME}"
  log_kv "Usuario" "${USERNAME}"
  log_kv "Zona horaria" "${TIMEZONE}"
  log_kv "Locale" "${LOCALE}"
  log_kv "Keymap" "${KEYMAP}"

  log_header "Disco y layout"
  log_kv "Target disk" "${TARGET_DISK:-no preconfigurado}"
  log_kv "EFI size" "${EFI_SIZE}"
  log_kv "Crypt name" "${CRYPT_NAME}"
  log_kv "Btrfs compress" "${BTRFS_COMPRESS}"
  log_kv "Btrfs label" "${BTRFS_LABEL}"

  log_header "Perfiles"
  log_kv "Dev" "${INSTALL_DEV_PROFILE}"
  log_kv "Virtualizacion" "${INSTALL_VIRT_PROFILE}"
  log_kv "Contenedores" "${INSTALL_CONTAINERS_PROFILE}"
  log_kv "Auditoria" "${INSTALL_AUDIT_PROFILE}"
  log_kv "Hardening" "${INSTALL_HARDENING_PROFILE}"
  log_kv "Shell" "${INSTALL_SHELL_PROFILE}"
  log_kv "Editor" "${INSTALL_EDITOR_PROFILE}"
  log_kv "Escritorio" "${INSTALL_DESKTOP_PROFILE}"
  log_kv "Red" "${INSTALL_NETWORK_PROFILE}"
  log_kv "NVIDIA auto" "${INSTALL_NVIDIA_IF_DETECTED}"

  log_header "Secure Boot"
  log_kv "Crear claves sbctl" "${SBCTL_CREATE_KEYS}"
  log_kv "Enrolar Microsoft keys" "${SBCTL_ENROLL_MICROSOFT_KEYS}"
}

confirm_effective_config() {
  ensure_install_config_validated
  show_effective_config

  confirm_yes_no "La configuracion anterior es correcta y quieres continuar?" || \
    die "Configuracion no confirmada. Abortando."
}
