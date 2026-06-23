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

  grep -q '^ID=arch$' "$(target_path "${target_root}" /etc/os-release)" || \
    die "${target_root} no parece un sistema Arch instalado."

  require_directory "$(target_path "${target_root}" /usr)"
  require_directory "$(target_path "${target_root}" /var)"
  require_directory "$(target_path "${target_root}" /etc)"
}

arch_chroot_run() {
  local target_root="$1"
  shift

  [[ -n "${target_root}" ]] || die "arch_chroot_run requiere target root explicito."
  [[ "$#" -gt 0 ]] || die "arch_chroot_run requiere un comando despues del target root."
  validate_arch_target_root "${target_root}"
  require_command arch-chroot

  run_logged arch-chroot "${target_root}" "$@"
}

arch_chroot_default() {
  [[ "$#" -gt 0 ]] || die "arch_chroot_default requiere un comando."
  arch_chroot_run "${TARGET_ROOT}" "$@"
}

arch_chroot_bash() {
  local target_root="$1"
  local script="$2"

  [[ -n "${target_root}" ]] || die "arch_chroot_bash requiere target root explicito."
  validate_arch_target_root "${target_root}"
  require_command arch-chroot
  [[ -n "${script}" ]] || die "arch_chroot_bash requiere un script no vacio."

  log_step "Ejecutando script Bash dentro de ${target_root}"
  run_logged arch-chroot "${target_root}" /usr/bin/env bash -euo pipefail -c "${script}"
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

  validate_username_value "${username}"
  if arch_chroot_run "${target_root}" id -u "${username}" >/dev/null 2>&1; then
    log_info "Usuario ya existente: ${username}"
  else
    arch_chroot_run "${target_root}" useradd -m -G "${groups}" -s "${shell}" "${username}"
  fi
}

configure_target_sudo() {
  local target_root="$1"
  local sudoers_file

  validate_arch_target_root "${target_root}"
  sudoers_file="$(target_path "${target_root}" /etc/sudoers.d/00-wheel)"

  write_file_atomic "${sudoers_file}" <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
  chmod 0440 "${sudoers_file}"
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

configure_target_base_system() {
  local target_root="${1:-${TARGET_ROOT}}"

  ensure_install_config_loaded
  validate_install_config
  validate_arch_target_root "${target_root}"

  configure_target_hostname "${target_root}" "${HOSTNAME}"
  configure_target_timezone "${target_root}" "${TIMEZONE}"
  configure_target_locale "${target_root}" "${LOCALE}"
  configure_target_keymap "${target_root}" "${KEYMAP}"
  create_target_user "${target_root}" "${USERNAME}" "wheel" "/bin/bash"
  configure_target_sudo "${target_root}"
  configure_target_mkinitcpio_luks_btrfs "${target_root}"
}
