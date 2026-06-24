#!/usr/bin/env bash
# Common helpers for the Arch workstation installer.
#
# This file is intended to be sourced by every stage script. It deliberately
# avoids installation, partitioning, bootloader, or chroot logic. Keep it small,
# predictable, and compatible with the official Arch Linux live ISO.

set -euo pipefail

# Resolve project paths from this file location:
#   scripts/lib/common.sh -> project root is two directories above.
COMMON_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${COMMON_LIB_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/configs/install.conf"

# Color output is enabled only for interactive terminals. Non-interactive logs
# stay plain and easy to parse.
if [[ -t 1 ]]; then
  COLOR_RESET=$'\033[0m'
  COLOR_RED=$'\033[31m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_BLUE=$'\033[34m'
  COLOR_BOLD=$'\033[1m'
else
  COLOR_RESET=""
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_BLUE=""
  COLOR_BOLD=""
fi

# Print a timestamp suitable for logs without depending on GNU extensions beyond
# coreutils, which are available in the Arch live environment.
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  local level="$1"
  local color="$2"
  shift 2
  printf '%s %s[%s]%s %s\n' "$(timestamp)" "${color}" "${level}" "${COLOR_RESET}" "$*"
}

info() {
  log "INFO" "${COLOR_BLUE}" "$@"
}

success() {
  log "OK" "${COLOR_GREEN}" "$@"
}

warn() {
  log "WARN" "${COLOR_YELLOW}" "$@" >&2
}

error() {
  log "ERROR" "${COLOR_RED}" "$@" >&2
}

die() {
  error "$@"
  exit 1
}

# Error trap helper. Stage scripts can use:
#   trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
on_error() {
  local line="${1:-unknown}"
  local command="${2:-unknown}"
  error "Fallo en linea ${line}: ${command}"
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Este script debe ejecutarse como root."
}

require_not_root() {
  [[ "${EUID}" -ne 0 ]] || die "Este script no debe ejecutarse como root."
}

require_arch_live_or_arch() {
  [[ -r /etc/os-release ]] || die "No se puede leer /etc/os-release."
  grep -q '^ID=arch$' /etc/os-release || die "Este proyecto esta preparado para Arch Linux o el ISO Live oficial."
}

require_uefi() {
  [[ -d /sys/firmware/efi/efivars ]] || die "El sistema no arranco en modo UEFI."
}

require_file() {
  local file="$1"
  [[ -f "${file}" ]] || die "No existe el archivo requerido: ${file}"
}

require_readable_file() {
  local file="$1"
  [[ -r "${file}" ]] || die "No se puede leer el archivo requerido: ${file}"
}

require_directory() {
  local directory="$1"
  [[ -d "${directory}" ]] || die "No existe el directorio requerido: ${directory}"
}

require_command() {
  local command_name
  for command_name in "$@"; do
    command -v "${command_name}" >/dev/null 2>&1 || die "Falta el comando requerido: ${command_name}"
  done
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_block_device() {
  local device="$1"
  [[ -b "${device}" ]]
}

is_mounted() {
  local path="$1"
  findmnt --target "${path}" >/dev/null 2>&1
}

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

is_yes() {
  case "${1:-}" in
    yes|YES|y|Y|true|TRUE|1) return 0 ;;
    *) return 1 ;;
  esac
}

is_no() {
  case "${1:-}" in
    no|NO|n|N|false|FALSE|0) return 0 ;;
    *) return 1 ;;
  esac
}

confirm_yes_no() {
  local prompt="$1"
  local answer

  printf '%s [yes/no]: ' "${prompt}"
  read -r answer
  answer="$(trim "${answer}")"

  if is_yes "${answer}"; then
    return 0
  fi

  if is_no "${answer}"; then
    return 1
  fi

  warn "Respuesta no valida. Escribe yes o no."
  return 1
}

# Require an exact typed confirmation. Useful before dangerous operations.
# Example:
#   require_exact_confirmation "/dev/nvme0n1" "Confirma el disco a borrar"
require_exact_confirmation() {
  local expected="$1"
  local prompt="$2"
  local typed

  printf '%s\n' "${prompt}"
  printf 'Escribe exactamente "%s" para continuar: ' "${expected}"
  read -r typed

  [[ "${typed}" == "${expected}" ]] || die "Confirmacion incorrecta. Abortando."
}

safe_run() {
  info "Ejecutando: $*"
  "$@"
}

safe_run_quiet() {
  "$@" >/dev/null 2>&1
}

create_directory() {
  local directory="$1"
  local mode="${2:-0755}"
  install -d -m "${mode}" "${directory}"
}

backup_file() {
  local file="$1"
  local backup

  [[ -e "${file}" ]] || return 0
  backup="${file}.bak.$(date '+%Y%m%d-%H%M%S')"
  cp -a -- "${file}" "${backup}"
  success "Backup creado: ${backup}"
}

load_config() {
  local configs_dir
  local resolved_configs_dir
  local resolved_config_file
  local mode
  local group_digit
  local other_digit

  configs_dir="${PROJECT_ROOT}/configs"
  resolved_configs_dir="$(realpath -m -- "${configs_dir}")"
  resolved_config_file="$(realpath -m -- "${CONFIG_FILE}")"

  [[ "${resolved_config_file}" == "${resolved_configs_dir}/"* ]] || \
    die "Archivo de configuracion fuera de ${resolved_configs_dir}: ${resolved_config_file}"

  require_readable_file "${CONFIG_FILE}"

  mode="$(stat -c '%a' "${CONFIG_FILE}")"
  group_digit="${mode: -2:1}"
  other_digit="${mode: -1}"

  if (( group_digit & 2 )) || (( other_digit & 2 )); then
    die "Archivo de configuracion escribible por grupo u otros: ${CONFIG_FILE}"
  fi

  # install.conf is trusted project shell code. It is sourced intentionally so
  # stage scripts can share simple Bash variables without an extra parser.
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
}

ensure_config_loaded() {
  [[ -n "${HOSTNAME:-}" ]] || die "La configuracion no esta cargada. Ejecuta load_config primero."
}

require_variable() {
  local variable_name="$1"
  [[ -n "${!variable_name:-}" ]] || die "Variable requerida no definida: ${variable_name}"
}

validate_identifier() {
  local value="$1"
  local label="$2"
  [[ "${value}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "${label} contiene caracteres no validos: ${value}"
}

validate_absolute_path() {
  local path="$1"
  [[ "${path}" == /* ]] || die "La ruta debe ser absoluta: ${path}"
}

validate_shell_identifier() {
  local value="$1"
  local label="${2:-identificador}"
  [[ "${value}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "${label} no es un identificador shell seguro: ${value}"
}

assert_path_under_root() {
  local root="$1"
  local path="$2"
  local resolved_root
  local resolved_path

  resolved_root="$(realpath -m -- "${root}")"
  resolved_path="$(realpath -m -- "${path}")"

  [[ "${resolved_path}" == "${resolved_root}" || "${resolved_path}" == "${resolved_root}/"* ]] || \
    die "Ruta fuera del directorio permitido: ${resolved_path}"
}

write_file_atomic() {
  local target="$1"
  local target_dir
  local tmp
  local old_return_trap

  validate_absolute_path "${target}"
  require_same_filesystem_path "${target}"

  target_dir="$(dirname -- "${target}")"
  tmp="$(mktemp --tmpdir="${target_dir}" ".${target##*/}.tmp.XXXXXX")"
  old_return_trap="$(trap -p RETURN || true)"
  trap 'rm -f -- "${tmp}"' RETURN
  cat > "${tmp}"

  if [[ -e "${target}" ]]; then
    chmod --reference="${target}" "${tmp}"
  else
    chmod 0644 "${tmp}"
  fi

  mv -f -- "${tmp}" "${target}"
  if [[ -n "${old_return_trap}" ]]; then
    eval "${old_return_trap}"
  else
    trap - RETURN
  fi
}

require_same_filesystem_path() {
  local target="$1"
  local target_dir

  validate_absolute_path "${target}"
  target_dir="$(dirname -- "${target}")"
  require_directory "${target_dir}"

  # write_file_atomic creates the temporary file inside this directory. That
  # guarantees the final mv is an atomic rename on the same filesystem.
  [[ -w "${target_dir}" ]] || die "El directorio destino no es escribible: ${target_dir}"
}

append_line_if_missing() {
  local file="$1"
  local line="$2"

  touch "${file}"
  grep -qxF -- "${line}" "${file}" || printf '%s\n' "${line}" >> "${file}"
}

replace_or_append_kv() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  local old_return_trap

  validate_shell_identifier "${key}" "clave"
  touch "${file}"

  tmp="$(mktemp --tmpdir="$(dirname -- "${file}")" ".${file##*/}.tmp.XXXXXX")"
  old_return_trap="$(trap -p RETURN || true)"
  trap 'rm -f -- "${tmp}"' RETURN

  awk -v key="${key}" -v value="${value}" '
    BEGIN { replaced = 0 }
    index($0, key "=") == 1 {
      print key "=" value
      replaced = 1
      next
    }
    { print }
    END {
      if (replaced == 0) {
        print key "=" value
      }
    }
  ' "${file}" > "${tmp}"

  chmod --reference="${file}" "${tmp}"
  mv -f -- "${tmp}" "${file}"

  if [[ -n "${old_return_trap}" ]]; then
    eval "${old_return_trap}"
  else
    trap - RETURN
  fi
}
