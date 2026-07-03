#!/usr/bin/env bash
# Package list helpers for the Arch workstation installer.
#
# This library reads profiles/*.pkglist and builds the final package set from
# configs/install.conf. It exposes pacstrap/pacman helpers, but never runs them
# automatically.

set -euo pipefail

PACKAGES_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F die >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${PACKAGES_LIB_DIR}/common.sh"
fi

if ! declare -F log_section >/dev/null 2>&1; then
  # shellcheck source=logging.sh
  source "${PACKAGES_LIB_DIR}/logging.sh"
fi

if ! declare -F run_logged >/dev/null 2>&1; then
  # shellcheck source=logging.sh
  source "${PACKAGES_LIB_DIR}/logging.sh"
fi

if ! declare -F validate_install_config >/dev/null 2>&1; then
  # shellcheck source=config.sh
  source "${PACKAGES_LIB_DIR}/config.sh"
fi

if ! declare -F detect_microcode_package >/dev/null 2>&1; then
  # shellcheck source=hardware.sh
  source "${PACKAGES_LIB_DIR}/hardware.sh"
fi

PROFILES_DIR="${PROJECT_ROOT}/profiles"
BOOTSTRAP_BASE_PACKAGES=(
  base
  linux
  linux-firmware
  base-devel
  btrfs-progs
  cryptsetup
  sudo
  vim
)

HYPRLAND_DESKTOP_PACKAGES=(
  hyprland
  xdg-desktop-portal-hyprland
  xdg-desktop-portal
  waybar
  wofi
  kitty
  hyprpaper
  mako
  wl-clipboard
  grim
  slurp
  polkit-kde-agent
  ttf-dejavu
  noto-fonts
  noto-fonts-emoji
  mesa
  sddm
)

profile_path() {
  local profile="$1"

  printf '%s/%s.pkglist\n' "${PROFILES_DIR}" "${profile}"
}

require_pkglist_file() {
  local file="$1"
  local resolved_file
  local resolved_profiles_dir

  resolved_file="$(realpath -m -- "${file}")"
  resolved_profiles_dir="$(realpath -m -- "${PROFILES_DIR}")"

  [[ "${resolved_file}" == "${resolved_profiles_dir}/"* ]] || die "Pkglist fuera de profiles: ${resolved_file}"
  require_readable_file "${resolved_file}"
}

read_pkglist_file() {
  local file="$1"

  require_pkglist_file "${file}"
  read_package_lines "${file}"
}

read_package_lines() {
  local file="$1"

  require_readable_file "${file}"
  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      gsub(/^[[:space:]]+/, "")
      gsub(/[[:space:]]+$/, "")
      if ($0 ~ /[[:space:]]/) {
        printf "Entrada de paquete invalida con espacios en %s: %s\n", FILENAME, $0 > "/dev/stderr"
        exit 2
      }
      if ($0 !~ /^[A-Za-z0-9@._+-]+$/) {
        printf "Entrada de paquete invalida en %s: %s\n", FILENAME, $0 > "/dev/stderr"
        exit 2
      }
      print
    }
  ' "${file}" || die "Pkglist contiene entradas invalidas: ${file}"
}

append_profile_packages() {
  local profile="$1"
  local file

  file="$(profile_path "${profile}")"
  read_pkglist_file "${file}"
}

append_package_if_not_empty() {
  local package="$1"

  if [[ -n "${package}" ]]; then
    printf '%s\n' "${package}"
  fi
  return 0
}

secure_boot_bootstrap_requested() {
  is_yes "${ENABLE_SECURE_BOOT:-no}" || is_yes "${SBCTL_CREATE_KEYS:-no}"
}

hyprland_desktop_requested() {
  [[ "${INSTALL_DESKTOP_ENV:-none}" == "hyprland" ]]
}

build_package_list() {
  ensure_install_config_loaded

  {
    append_profile_packages "base"
    append_package_if_not_empty "$(detect_microcode_package)"

    if is_yes "${INSTALL_NVIDIA_IF_DETECTED}" && detect_nvidia_gpu; then
      append_profile_packages "nvidia"
    fi

    if is_yes "${INSTALL_DEV_PROFILE}"; then
      append_profile_packages "dev-tools"
    fi

    if is_yes "${INSTALL_DESKTOP_PROFILE}"; then
      append_profile_packages "desktop"
    fi

    if is_yes "${INSTALL_HARDENING_PROFILE}"; then
      append_profile_packages "hardening"
    fi

    if is_yes "${INSTALL_VIRT_PROFILE}"; then
      append_profile_packages "virtualization"
    fi

    if is_yes "${INSTALL_CONTAINERS_PROFILE}"; then
      append_profile_packages "containers"
    fi

    if is_yes "${INSTALL_AUDIT_PROFILE}"; then
      append_profile_packages "security-tools"
    fi

    if is_yes "${INSTALL_SHELL_PROFILE}"; then
      append_profile_packages "shell"
    fi

    if is_yes "${INSTALL_EDITOR_PROFILE}"; then
      append_profile_packages "editor"
    fi

    if is_yes "${INSTALL_NETWORK_PROFILE}"; then
      append_profile_packages "network"
    fi
  } | awk '!seen[$0]++'
}

bootstrap_base_packages() {
  local package_name

  for package_name in "${BOOTSTRAP_BASE_PACKAGES[@]}"; do
    printf '%s\n' "${package_name}"
  done
}

hyprland_desktop_packages() {
  local package_name

  for package_name in "${HYPRLAND_DESKTOP_PACKAGES[@]}"; do
    printf '%s\n' "${package_name}"
  done
}

build_bootstrap_package_list() {
  ensure_install_config_loaded

  {
    bootstrap_base_packages
    append_package_if_not_empty "$(detect_microcode_package)"

    if secure_boot_bootstrap_requested; then
      append_package_if_not_empty "sbctl"
    fi

    if is_yes "${INSTALL_NETWORK_PROFILE:-no}"; then
      append_package_if_not_empty "networkmanager"
    fi

    if is_yes "${INSTALL_OPENSSH:-no}"; then
      append_package_if_not_empty "openssh"
    fi

    if hyprland_desktop_requested; then
      hyprland_desktop_packages
    fi
  } | awk 'NF && !seen[$0]++'
}

show_bootstrap_package_list() {
  local count
  local tmp
  local old_return_trap

  tmp="$(mktemp)"
  old_return_trap="$(trap -p RETURN || true)"
  trap 'rm -f -- "${tmp}"' RETURN

  build_bootstrap_package_list > "${tmp}"
  count="$(awk 'NF { count++ } END { print count + 0 }' "${tmp}")"

  log_section "Paquetes base para bootstrap"
  log_kv "Total" "${count}"
  while IFS= read -r package_name; do
    [[ -n "${package_name}" ]] || continue
    log_kv "Paquete" "${package_name}"
  done < "${tmp}"

  rm -f -- "${tmp}"

  if [[ -n "${old_return_trap}" ]]; then
    eval "${old_return_trap}"
  else
    trap - RETURN
  fi
}

write_bootstrap_package_list() {
  local output_file="$1"

  validate_absolute_path "${output_file}"
  build_bootstrap_package_list | write_file_atomic "${output_file}"
  require_readable_file "${output_file}"
  validate_package_file_not_empty "${output_file}"
}

show_bootstrap_package_file() {
  local package_file="$1"
  local count
  local package_name

  require_readable_file "${package_file}"
  count="$(awk 'NF { count++ } END { print count + 0 }' "${package_file}")"

  log_section "Paquetes base para bootstrap"
  log_kv "Archivo" "${package_file}"
  log_kv "Total" "${count}"
  while IFS= read -r package_name; do
    [[ -n "${package_name}" ]] || continue
    log_kv "Paquete" "${package_name}"
  done < "${package_file}"
}

validate_package_file_not_empty() {
  local package_file="$1"
  local count

  require_readable_file "${package_file}"
  count="$(awk 'NF { count++ } END { print count + 0 }' "${package_file}")"
  [[ "${count}" -gt 0 ]] || die "La lista de paquetes esta vacia: ${package_file}"
}

verify_pacman_repositories_reachable() {
  require_command pacman

  log_step "Verificando repositorios de pacman"
  run_logged pacman -Sy --noconfirm >/dev/null
  success "Repositorios de pacman accesibles."
}

pacstrap_bootstrap_target() {
  local target="$1"
  local -a packages

  require_command pacstrap
  require_directory "${target}"

  mapfile -t packages < <(build_bootstrap_package_list)
  [[ "${#packages[@]}" -gt 0 ]] || die "La lista de paquetes base esta vacia."

  pacstrap_install_packages "${target}" "${packages[@]}"
}

pacstrap_bootstrap_package_file() {
  local target="$1"
  local package_file="$2"

  validate_package_file_not_empty "${package_file}"
  pacstrap_install_package_list "${target}" "${package_file}"
}

write_package_list() {
  local output_file="$1"

  validate_absolute_path "${output_file}"
  build_package_list > "${output_file}"
}

show_package_list() {
  local count
  local tmp
  local old_return_trap

  tmp="$(mktemp)"
  old_return_trap="$(trap -p RETURN || true)"
  trap 'rm -f -- "${tmp}"' RETURN

  build_package_list > "${tmp}"
  count="$(awk 'NF { count++ } END { print count + 0 }' "${tmp}")"

  log_section "Lista final de paquetes"
  log_kv "Total" "${count}"
  cat "${tmp}"
  rm -f -- "${tmp}"

  if [[ -n "${old_return_trap}" ]]; then
    eval "${old_return_trap}"
  else
    trap - RETURN
  fi
}

validate_package_list_not_empty() {
  local tmp
  local count
  local old_return_trap

  tmp="$(mktemp)"
  old_return_trap="$(trap -p RETURN || true)"
  trap 'rm -f -- "${tmp}"' RETURN

  build_package_list > "${tmp}"
  count="$(awk 'NF { count++ } END { print count + 0 }' "${tmp}")"
  rm -f -- "${tmp}"

  [[ "${count}" -gt 0 ]] || die "La lista final de paquetes esta vacia."

  if [[ -n "${old_return_trap}" ]]; then
    eval "${old_return_trap}"
  else
    trap - RETURN
  fi
}

pacstrap_install_packages() {
  local target="$1"
  shift

  require_command pacstrap
  require_directory "${target}"
  [[ "$#" -gt 0 ]] || die "pacstrap_install_packages requiere al menos un paquete."

  log_step "Instalando paquetes con pacstrap en ${target}"
  run_logged pacstrap -K "${target}" "$@"
}

pacstrap_install_package_list() {
  local target="$1"
  local package_file="$2"
  local -a packages

  require_readable_file "${package_file}"
  mapfile -t packages < <(read_package_lines "${package_file}")
  [[ "${#packages[@]}" -gt 0 ]] || die "La lista de paquetes esta vacia: ${package_file}"
  pacstrap_install_packages "${target}" "${packages[@]}"
}

pacman_install_packages() {
  require_command pacman
  [[ "$#" -gt 0 ]] || die "pacman_install_packages requiere al menos un paquete."

  log_step "Instalando paquetes con pacman"
  run_logged pacman -S --needed --noconfirm "$@"
}

pacman_install_package_list() {
  local package_file="$1"
  local -a packages

  require_readable_file "${package_file}"
  mapfile -t packages < <(read_package_lines "${package_file}")
  [[ "${#packages[@]}" -gt 0 ]] || die "La lista de paquetes esta vacia: ${package_file}"
  pacman_install_packages "${packages[@]}"
}
