#!/usr/bin/env bash
# Logging helpers for the Arch workstation installer.
#
# This library extends scripts/lib/common.sh with optional file logging and
# readable output helpers for long installation stages. It intentionally avoids
# partitioning, installation, bootloader, Secure Boot, or chroot logic.

set -euo pipefail

LOGGING_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# logging.sh can be sourced after common.sh, but it also works by itself.
if ! declare -F info >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${LOGGING_LIB_DIR}/common.sh"
fi

# Optional log file. It is disabled by default and can be enabled with
# enable_log_file /path/to/file.log
LOG_FILE="${LOG_FILE:-}"
LOG_COMMANDS="${LOG_COMMANDS:-no}"

log_file_enabled() {
  [[ -n "${LOG_FILE}" ]]
}

write_log_file() {
  local line="$*"

  log_file_enabled || return 0
  printf '%s\n' "${line}" >> "${LOG_FILE}"
}

enable_log_file() {
  local file="$1"
  local directory

  validate_absolute_path "${file}"
  directory="$(dirname -- "${file}")"
  require_directory "${directory}"
  touch "${file}"
  [[ -w "${file}" ]] || die "No se puede escribir el archivo de log: ${file}"

  LOG_FILE="${file}"
  export LOG_FILE
  write_log_file "$(timestamp) [INFO] Logging habilitado: ${LOG_FILE}"
}

disable_log_file() {
  if log_file_enabled; then
    write_log_file "$(timestamp) [INFO] Logging deshabilitado"
  fi

  LOG_FILE=""
  export LOG_FILE
}

log_to_console_and_file() {
  local level="$1"
  local color="$2"
  shift 2

  log "${level}" "${color}" "$@"
  write_log_file "$(timestamp) [${level}] $*"
}

log_info() {
  log_to_console_and_file "INFO" "${COLOR_BLUE}" "$@"
}

log_success() {
  log_to_console_and_file "OK" "${COLOR_GREEN}" "$@"
}

log_warn() {
  log_to_console_and_file "WARN" "${COLOR_YELLOW}" "$@"
}

log_error() {
  log_to_console_and_file "ERROR" "${COLOR_RED}" "$@"
}

log_section() {
  local title="$1"
  local line

  line="================================================================"
  printf '\n%s%s%s\n' "${COLOR_BOLD}${COLOR_BLUE}" "${line}" "${COLOR_RESET}"
  printf '%s%s%s\n' "${COLOR_BOLD}${COLOR_BLUE}" "${title}" "${COLOR_RESET}"
  printf '%s%s%s\n\n' "${COLOR_BOLD}${COLOR_BLUE}" "${line}" "${COLOR_RESET}"

  write_log_file "$(timestamp) [SECTION] ${title}"
}

log_header() {
  local title="$1"

  printf '\n%s%s%s\n' "${COLOR_BOLD}" "${title}" "${COLOR_RESET}"
  printf '%s\n' "----------------------------------------------------------------"
  write_log_file "$(timestamp) [HEADER] ${title}"
}

log_step() {
  local step="$1"

  printf '%s==>%s %s\n' "${COLOR_GREEN}" "${COLOR_RESET}" "${step}"
  write_log_file "$(timestamp) [STEP] ${step}"
}

log_substep() {
  local step="$1"

  printf '  %s->%s %s\n' "${COLOR_BLUE}" "${COLOR_RESET}" "${step}"
  write_log_file "$(timestamp) [SUBSTEP] ${step}"
}

log_kv() {
  local key="$1"
  local value="$2"

  printf '  %s%-24s%s %s\n' "${COLOR_BOLD}" "${key}:" "${COLOR_RESET}" "${value}"
  write_log_file "$(timestamp) [DATA] ${key}=${value}"
}

enable_command_logging() {
  LOG_COMMANDS="yes"
  export LOG_COMMANDS
}

disable_command_logging() {
  LOG_COMMANDS="no"
  export LOG_COMMANDS
}

command_logging_enabled() {
  is_yes "${LOG_COMMANDS}"
}

quote_command() {
  local quoted=()
  local arg

  for arg in "$@"; do
    quoted+=("$(printf '%q' "${arg}")")
  done

  printf '%s' "${quoted[*]}"
}

show_command() {
  local rendered

  rendered="$(quote_command "$@")"
  printf '%s$%s %s\n' "${COLOR_YELLOW}" "${COLOR_RESET}" "${rendered}"
  write_log_file "$(timestamp) [COMMAND] ${rendered}"
}

run_logged() {
  if command_logging_enabled; then
    show_command "$@"
  fi

  "$@"
}

run_logged_always() {
  show_command "$@"
  "$@"
}

log_blank() {
  printf '\n'
  write_log_file ""
}
