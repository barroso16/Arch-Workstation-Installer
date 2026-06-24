#!/usr/bin/env bash
# Chroot helpers for the Arch workstation installer.
#
# This library operates on an already bootstrapped target root using
# arch-chroot. It does not partition, format, install bootloader, configure
# Secure Boot, or configure NVIDIA.

set -euo pipefail

CHROOT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F die >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${CHROOT_LIB_DIR}/common.sh"
fi

if ! declare -F log_section >/dev/null 2>&1; then
  # shellcheck source=logging.sh
  source "${CHROOT_LIB_DIR}/logging.sh"
fi

if ! declare -F validate_install_config >/dev/null 2>&1; then
  # shellcheck source=config.sh
  source "${CHROOT_LIB_DIR}/config.sh"
fi

if ! declare -F pacman_install_packages >/dev/null 2>&1; then
  # shellcheck source=packages.sh
  source "${CHROOT_LIB_DIR}/packages.sh"
fi

TARGET_ROOT="${TARGET_ROOT:-/mnt}"

CHROOT_LAST_EXIT_CODE=0
CHROOT_LAST_OUTPUT=""

target_path() {
  local target_root="$1"
  local path="$2"

  validate_absolute_path "${target_root}"
  validate_absolute_path "${path}"
  printf '%s%s\n' "${target_root%/}" "${path}"
}

validate_target_root() {
  local target_root="${1:-${TARGET_ROOT}}"

  validate_absolute_path "${target_root}"
  require_directory "${target_root}"
}

validate_arch_target_root() {
  local target_root="${1:-${TARGET_ROOT}}"

  validate_target_root "${target_root}"
  require_readable_file "$(target_path "${target_root}" /etc/os-release)"
  require_file "$(target_path "${target_root}" /usr/bin/bash)"

  grep -q '^ID=arch$' "$(target_path "${target_root}" /etc/os-release)" || \
    die "${target_root} no parece un sistema Arch instalado."

  require_directory "$(target_path "${target_root}" /usr)"
  require_directory "$(target_path "${target_root}" /var)"
  require_directory "$(target_path "${target_root}" /etc)"
}

require_arch_chroot_available() {
  require_command arch-chroot
}

log_chroot_event() {
  local action="$1"
  local target_root="$2"
  local detail="${3:-}"

  log_kv "chroot.${action}.target" "${target_root}"
  if [[ -n "${detail}" ]]; then
    log_kv "chroot.${action}.detail" "${detail}"
  fi
}

format_chroot_command() {
  quote_command "$@"
}

validate_chroot_infrastructure() {
  local target_root="${1:-${TARGET_ROOT}}"

  log_section "Infraestructura chroot"
  validate_arch_target_root "${target_root}"
  require_arch_chroot_available
  log_chroot_event "validated" "${target_root}" "arch-chroot disponible"
  success "Infraestructura chroot validada para ${target_root}."
}

arch_chroot_run() {
  local target_root="$1"
  local rendered_command
  shift

  [[ -n "${target_root}" ]] || die "arch_chroot_run requiere target root explicito."
  [[ "$#" -gt 0 ]] || die "arch_chroot_run requiere un comando despues del target root."
  validate_arch_target_root "${target_root}"
  require_arch_chroot_available

  rendered_command="$(format_chroot_command "$@")"
  write_log_file "$(timestamp) [CHROOT] target=${target_root} command=${rendered_command}"
  run_logged arch-chroot "${target_root}" "$@"
}

arch_chroot_default() {
  [[ "$#" -gt 0 ]] || die "arch_chroot_default requiere un comando."
  arch_chroot_run "${TARGET_ROOT}" "$@"
}

arch_chroot_bash() {
  local target_root="$1"
  local script="$2"
  local rendered_command

  [[ -n "${target_root}" ]] || die "arch_chroot_bash requiere target root explicito."
  validate_arch_target_root "${target_root}"
  require_arch_chroot_available
  [[ -n "${script}" ]] || die "arch_chroot_bash requiere un script no vacio."

  rendered_command="$(format_chroot_command /usr/bin/env bash -euo pipefail -c "${script}")"
  log_step "Ejecutando script Bash dentro de ${target_root}"
  write_log_file "$(timestamp) [CHROOT] target=${target_root} command=${rendered_command}"
  run_logged arch-chroot "${target_root}" /usr/bin/env bash -euo pipefail -c "${script}"
}

arch_chroot_capture() {
  local target_root="$1"
  local output
  local status
  local rendered_command
  shift

  [[ -n "${target_root}" ]] || die "arch_chroot_capture requiere target root explicito."
  [[ "$#" -gt 0 ]] || die "arch_chroot_capture requiere un comando despues del target root."
  validate_arch_target_root "${target_root}"
  require_arch_chroot_available

  rendered_command="$(format_chroot_command "$@")"
  write_log_file "$(timestamp) [CHROOT] target=${target_root} capture=${rendered_command}"

  set +e
  output="$(arch-chroot "${target_root}" "$@" 2>&1)"
  status=$?
  set -e

  CHROOT_LAST_EXIT_CODE="${status}"
  CHROOT_LAST_OUTPUT="${output}"
  export CHROOT_LAST_EXIT_CODE CHROOT_LAST_OUTPUT

  printf '%s' "${output}"
  return "${status}"
}

arch_chroot_script_capture() {
  local target_root="$1"
  local script="$2"

  [[ -n "${script}" ]] || die "arch_chroot_script_capture requiere un script no vacio."
  arch_chroot_capture "${target_root}" /usr/bin/env bash -euo pipefail -c "${script}"
}

arch_chroot_exit_code() {
  printf '%s\n' "${CHROOT_LAST_EXIT_CODE}"
}

write_target_file() {
  local target_root="$1"
  local destination="$2"
  local full_path

  validate_target_root "${target_root}"
  validate_absolute_path "${destination}"

  full_path="$(target_path "${target_root}" "${destination}")"
  require_same_filesystem_path "${full_path}"
  write_file_atomic "${full_path}"
}

append_target_line_if_missing() {
  local target_root="$1"
  local destination="$2"
  local line="$3"
  local full_path

  validate_target_root "${target_root}"
  full_path="$(target_path "${target_root}" "${destination}")"
  append_line_if_missing "${full_path}" "${line}"
}

enable_target_service() {
  local target_root="$1"
  local service="$2"

  validate_systemd_unit_name "${service}"
  arch_chroot_run "${target_root}" systemctl enable "${service}"
}

validate_systemd_unit_name() {
  local unit="$1"

  [[ "${unit}" != *" "* ]] || die "Unidad systemd invalida, contiene espacios: ${unit}"
  [[ "${unit}" != *".."* ]] || die "Unidad systemd invalida, contiene '..': ${unit}"
  [[ "${unit}" != *"/"* ]] || die "Unidad systemd invalida, contiene '/': ${unit}"
  [[ "${unit}" =~ ^[A-Za-z0-9@_.:-]+\.(service|timer|socket|path|mount)$ ]] || \
    die "Unidad systemd invalida: ${unit}"
}

create_target_user() {
  local target_root="$1"
  local username="$2"
  local groups="${3:-wheel}"
  local shell="${4:-/bin/bash}"
  local existing_groups

  validate_username_value "${username}"
  existing_groups="$(target_existing_groups_csv "${target_root}" "${groups}")"

  if arch_chroot_run "${target_root}" id -u "${username}" >/dev/null 2>&1; then
    log_info "Usuario ya existente: ${username}"
  else
    if [[ -n "${existing_groups}" ]]; then
      arch_chroot_run "${target_root}" useradd -m -G "${existing_groups}" -s "${shell}" "${username}"
    else
      arch_chroot_run "${target_root}" useradd -m -s "${shell}" "${username}"
    fi
  fi

  configure_target_user_groups "${target_root}" "${username}" "${groups}"
  ensure_target_user_home "${target_root}" "${username}"
}

configure_target_sudo() {
  local target_root="$1"
  local sudoers_file

  validate_arch_target_root "${target_root}"
  arch_chroot_run "${target_root}" command -v visudo >/dev/null
  sudoers_file="$(target_path "${target_root}" /etc/sudoers.d/00-wheel)"

  write_file_atomic "${sudoers_file}" <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
  chmod 0440 "${sudoers_file}"
  arch_chroot_run "${target_root}" visudo -cf /etc/sudoers.d/00-wheel
}

target_group_exists() {
  local target_root="$1"
  local group="$2"

  arch_chroot_capture "${target_root}" getent group "${group}" >/dev/null 2>&1
}

target_existing_groups_csv() {
  local target_root="$1"
  local groups="$2"
  local group
  local existing=()

  for group in ${groups//,/ }; do
    [[ -n "${group}" ]] || continue
    if target_group_exists "${target_root}" "${group}"; then
      existing+=("${group}")
    else
      log_warn "Grupo opcional no existe en el target y sera omitido: ${group}"
    fi
  done

  if ((${#existing[@]} > 0)); then
    local IFS=,
    printf '%s\n' "${existing[*]}"
  fi
}

configure_target_user_groups() {
  local target_root="$1"
  local username="$2"
  local groups="$3"
  local existing_groups

  validate_username_value "${username}"
  existing_groups="$(target_existing_groups_csv "${target_root}" "${groups}")"
  [[ -n "${existing_groups}" ]] || return 0
  arch_chroot_run "${target_root}" usermod -aG "${existing_groups}" "${username}"
}

target_user_groups() {
  local target_root="$1"
  local username="$2"

  validate_username_value "${username}"
  arch_chroot_capture "${target_root}" id -nG "${username}"
}

ensure_target_user_home() {
  local target_root="$1"
  local username="$2"
  local home_dir

  validate_username_value "${username}"
  home_dir="$(arch_chroot_capture "${target_root}" getent passwd "${username}" | awk -F: '{print $6}')"
  [[ -n "${home_dir}" ]] || die "No se pudo determinar el home de ${username}."
  validate_absolute_path "${home_dir}"

  arch_chroot_run "${target_root}" install -d -m 0750 -o "${username}" -g "${username}" "${home_dir}"
}

configure_target_root_password() {
  local target_root="$1"

  validate_chroot_infrastructure "${target_root}"
  log_warn "Se solicitara la contrasena de root dentro del sistema instalado."
  log_warn "No se almacena ni se imprime ninguna contrasena."
  arch_chroot_run "${target_root}" passwd
}

configure_target_user_password() {
  local target_root="$1"
  local username="$2"

  validate_username_value "${username}"
  arch_chroot_run "${target_root}" id -u "${username}" >/dev/null
  log_warn "Se solicitara la contrasena del usuario ${username} dentro del sistema instalado."
  log_warn "No se almacena ni se imprime ninguna contrasena."
  arch_chroot_run "${target_root}" passwd "${username}"
}

target_shell_exists() {
  local target_root="$1"
  local shell="$2"

  validate_absolute_path "${shell}"
  [[ -x "$(target_path "${target_root}" "${shell}")" ]]
}

target_select_user_shell() {
  local target_root="$1"
  local requested_shell="${TARGET_USER_SHELL:-${USER_SHELL:-${DEFAULT_USER_SHELL:-/bin/bash}}}"

  validate_absolute_path "${requested_shell}"
  case "${requested_shell}" in
    */zsh)
      if target_shell_exists "${target_root}" "${requested_shell}"; then
        printf '%s\n' "${requested_shell}"
      else
        log_warn "zsh fue solicitado pero no esta instalado en el target; usando /bin/bash."
        printf '%s\n' "/bin/bash"
      fi
      ;;
    *)
      if target_shell_exists "${target_root}" "${requested_shell}"; then
        printf '%s\n' "${requested_shell}"
      else
        log_warn "Shell solicitado no existe en el target (${requested_shell}); usando /bin/bash."
        printf '%s\n' "/bin/bash"
      fi
      ;;
  esac
}

ensure_target_shell_allowed() {
  local target_root="$1"
  local shell="$2"
  local shells_file

  validate_absolute_path "${shell}"
  target_shell_exists "${target_root}" "${shell}" || die "Shell no existe en el target: ${shell}"
  shells_file="$(target_path "${target_root}" /etc/shells)"
  touch "${shells_file}"
  append_line_if_missing "${shells_file}" "${shell}"
}

configure_target_hostname() {
  local target_root="$1"
  local hostname="$2"

  validate_hostname_value "${hostname}"

  write_target_file "${target_root}" /etc/hostname <<EOF
${hostname}
EOF

  write_target_file "${target_root}" /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${hostname}.localdomain ${hostname}
EOF
}

configure_target_timezone() {
  local target_root="$1"
  local timezone="$2"

  validate_timezone_value "${timezone}"
  arch_chroot_run "${target_root}" ln -sf "/usr/share/zoneinfo/${timezone}" /etc/localtime
  arch_chroot_run "${target_root}" hwclock --systohc
}

configure_target_locale() {
  local target_root="$1"
  local locale="$2"
  local locale_gen
  local tmp
  local old_return_trap

  validate_locale_value "${locale}"
  locale_gen="$(target_path "${target_root}" /etc/locale.gen)"
  require_readable_file "${locale_gen}"

  tmp="$(mktemp --tmpdir="$(dirname -- "${locale_gen}")" ".${locale_gen##*/}.tmp.XXXXXX")"
  old_return_trap="$(trap -p RETURN || true)"
  trap 'rm -f -- "${tmp}"' RETURN

  awk -v locale="${locale}" '
    BEGIN { found = 0 }
    $0 == "#" locale " UTF-8" {
      print locale " UTF-8"
      found = 1
      next
    }
    $0 == locale " UTF-8" {
      print
      found = 1
      next
    }
    { print }
    END {
      if (found == 0) {
        print locale " UTF-8"
      }
    }
  ' "${locale_gen}" > "${tmp}"

  chmod --reference="${locale_gen}" "${tmp}"
  mv -f -- "${tmp}" "${locale_gen}"

  if [[ -n "${old_return_trap}" ]]; then
    eval "${old_return_trap}"
  else
    trap - RETURN
  fi

  write_target_file "${target_root}" /etc/locale.conf <<EOF
LANG=${locale}
EOF

  arch_chroot_run "${target_root}" locale-gen
}

configure_target_keymap() {
  local target_root="$1"
  local keymap="$2"

  validate_keymap_value "${keymap}"
  write_target_file "${target_root}" /etc/vconsole.conf <<EOF
KEYMAP=${keymap}
EOF
}

replace_target_assignment() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  local old_return_trap

  validate_shell_identifier "${key}" "clave"
  require_readable_file "${file}"

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

configure_target_mkinitcpio_luks_btrfs() {
  local target_root="$1"
  local mkinitcpio_conf

  validate_arch_target_root "${target_root}"
  mkinitcpio_conf="$(target_path "${target_root}" /etc/mkinitcpio.conf)"
  require_readable_file "${mkinitcpio_conf}"

  log_step "Configurando mkinitcpio para systemd initramfs, LUKS2 y Btrfs"
  replace_target_assignment "${mkinitcpio_conf}" "MODULES" "()"
  replace_target_assignment "${mkinitcpio_conf}" "HOOKS" "(base systemd autodetect microcode modconf kms keyboard sd-vconsole sd-encrypt block filesystems fsck)"
  arch_chroot_run "${target_root}" mkinitcpio -P
}

configure_target_identity() {
  local target_root="$1"

  configure_target_hostname "${target_root}" "${HOSTNAME}"
}

configure_target_console() {
  local target_root="$1"

  configure_target_keymap "${target_root}" "${KEYMAP}"
}

configure_target_localization() {
  local target_root="$1"

  configure_target_timezone "${target_root}" "${TIMEZONE}"
  configure_target_locale "${target_root}" "${LOCALE}"
  configure_target_console "${target_root}"
}

configure_target_passwords() {
  local target_root="$1"
  local username="${2:-${USERNAME}}"

  if ! is_yes "${STAGE06_INTERACTIVE_PASSWORDS:-no}"; then
    log_info "Configuracion interactiva de contrasenas omitida en esta etapa."
    return 0
  fi

  configure_target_root_password "${target_root}"
  configure_target_user_password "${target_root}" "${username}"
}

configure_target_shell() {
  local target_root="$1"
  local username="${2:-${USERNAME}}"
  local selected_shell

  if ! is_yes "${STAGE06_CONFIGURE_SHELL:-no}"; then
    log_info "Configuracion de shell de usuario omitida en esta etapa."
    return 0
  fi

  validate_username_value "${username}"
  selected_shell="$(target_select_user_shell "${target_root}")"
  ensure_target_shell_allowed "${target_root}" "${selected_shell}"
  arch_chroot_run "${target_root}" usermod -s "${selected_shell}" "${username}"
  TARGET_SELECTED_SHELL="${selected_shell}"
  export TARGET_SELECTED_SHELL
}

configure_target_users() {
  local target_root="$1"
  local username="${2:-${USERNAME}}"
  local groups="${3:-wheel audio video storage input network}"

  create_target_user "${target_root}" "${username}" "${groups}" "/bin/bash"
  configure_target_passwords "${target_root}" "${username}"
  configure_target_shell "${target_root}" "${username}"
  configure_target_sudo "${target_root}"
}

configure_target_initramfs() {
  local target_root="$1"

  configure_target_mkinitcpio_luks_btrfs "${target_root}"
}

configure_target_base_system() {
  local target_root="${1:-${TARGET_ROOT}}"

  ensure_install_config_loaded
  validate_install_config
  validate_chroot_infrastructure "${target_root}"

  configure_target_identity "${target_root}"
  configure_target_localization "${target_root}"
  configure_target_initramfs "${target_root}"
}
