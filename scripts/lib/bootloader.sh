#!/usr/bin/env bash
# systemd-boot helpers for the Arch workstation installer.
#
# This library is dedicated to systemd-boot entries for an Arch Linux target
# using UEFI, LUKS2, Btrfs, mkinitcpio and linux/linux-lts kernels. It does not
# install packages, partition disks, configure Secure Boot, or configure NVIDIA.

set -euo pipefail

BOOTLOADER_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F die >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${BOOTLOADER_LIB_DIR}/common.sh"
fi

if ! declare -F log_section >/dev/null 2>&1; then
  # shellcheck source=logging.sh
  source "${BOOTLOADER_LIB_DIR}/logging.sh"
fi

if ! declare -F validate_install_config >/dev/null 2>&1; then
  # shellcheck source=config.sh
  source "${BOOTLOADER_LIB_DIR}/config.sh"
fi

if ! declare -F detect_microcode_package >/dev/null 2>&1; then
  # shellcheck source=hardware.sh
  source "${BOOTLOADER_LIB_DIR}/hardware.sh"
fi

if ! declare -F arch_chroot_run >/dev/null 2>&1; then
  # shellcheck source=chroot.sh
  source "${BOOTLOADER_LIB_DIR}/chroot.sh"
fi

if ! declare -F sign_secureboot_artifacts >/dev/null 2>&1; then
  # shellcheck source=secureboot.sh
  source "${BOOTLOADER_LIB_DIR}/secureboot.sh"
fi

BOOTLOADER_DEFAULT_TARGET="${BOOTLOADER_DEFAULT_TARGET:-/mnt}"
BOOTLOADER_DEFAULT_ROOT_SUBVOLUMES="${BOOTLOADER_DEFAULT_ROOT_SUBVOLUMES:-@}"
BOOTLOADER_TARGET_LIB_DIR="${BOOTLOADER_TARGET_LIB_DIR:-/usr/local/lib/arch-workstation-installer/scripts/lib}"
BOOTLOADER_SIGN_AFTER_REGEN="${BOOTLOADER_SIGN_AFTER_REGEN:-yes}"

bootloader_path() {
  local target_root="$1"
  local path="$2"

  target_path "${target_root}" "${path}"
}

bootloader_require_tools() {
  require_command blkid findmnt arch-chroot
}

systemd_boot_installed() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"

  validate_arch_target_root "${target_root}"
  [[ -f "$(bootloader_path "${target_root}" /boot/loader/loader.conf)" ]] &&
    [[ -f "$(bootloader_path "${target_root}" /boot/EFI/systemd/systemd-bootx64.efi)" ]]
}

install_systemd_boot() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"

  bootloader_require_tools
  validate_arch_target_root "${target_root}"
  log_step "Instalando systemd-boot con bootctl"
  arch_chroot_run "${target_root}" bootctl install
}

systemd_boot_version() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"

  bootloader_require_tools
  validate_arch_target_root "${target_root}"
  arch_chroot_run "${target_root}" bootctl --version
}

target_efi_filesystem_uuid() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"

  bootloader_require_tools
  findmnt -no UUID --target "$(bootloader_path "${target_root}" /boot)" 2>/dev/null || true
}

target_btrfs_filesystem_uuid() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"

  bootloader_require_tools
  findmnt -no UUID --target "${target_root}" 2>/dev/null || true
}

target_root_kernel_uuid() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local uuid

  uuid="$(target_btrfs_filesystem_uuid "${target_root}")"
  [[ -n "${uuid}" ]] || die "No se pudo determinar UUID Btrfs para root= en ${target_root}."
  printf '%s\n' "${uuid}"
}

target_mapper_name() {
  local crypt_name="${CRYPT_NAME:-cryptroot}"

  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  printf '%s\n' "${crypt_name}"
}

target_luks_uuid_from_crypttab() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local crypttab
  local crypt_name="${CRYPT_NAME:-cryptroot}"

  crypttab="$(bootloader_path "${target_root}" /etc/crypttab)"
  [[ -r "${crypttab}" ]] || return 1

  awk -v name="${crypt_name}" '
    $1 == name {
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^UUID=/) {
          sub(/^UUID=/, "", $i)
          print $i
          exit
        }
      }
    }
  ' "${crypttab}"
}

target_luks_uuid() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local uuid="${LUKS_UUID:-}"

  if [[ -n "${uuid}" ]]; then
    printf '%s\n' "${uuid}"
    return 0
  fi

  uuid="$(target_luks_uuid_from_crypttab "${target_root}" || true)"
  [[ -n "${uuid}" ]] || die "No se pudo determinar UUID LUKS. Define LUKS_UUID o /etc/crypttab en el target."
  blkid -U "${uuid}" >/dev/null 2>&1 || log_warn "UUID LUKS no visible desde blkid en el entorno actual: ${uuid}"
  printf '%s\n' "${uuid}"
}

target_luks_uuid_required() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local uuid

  uuid="$(target_luks_uuid "${target_root}")"
  [[ -n "${uuid}" ]] || die "No se pudo determinar UUID del volumen LUKS."
  printf '%s\n' "${uuid}"
}

target_btrfs_uuid_required() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local uuid

  uuid="$(target_btrfs_filesystem_uuid "${target_root}")"
  [[ -n "${uuid}" ]] || die "No se pudo determinar UUID del filesystem Btrfs."
  printf '%s\n' "${uuid}"
}

detect_target_uki() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local uki_dir
  local nullglob_was_set=0
  local uki_files=()

  uki_dir="$(bootloader_path "${target_root}" /boot/EFI/Linux)"
  [[ -d "${uki_dir}" ]] || return 1

  if shopt -q nullglob; then
    nullglob_was_set=1
  fi
  shopt -s nullglob
  uki_files=("${uki_dir}"/*.efi "${uki_dir}"/*.EFI)
  if ((nullglob_was_set == 0)); then
    shopt -u nullglob
  fi

  ((${#uki_files[@]} > 0))
}

warn_if_target_uki_exists() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"

  if detect_target_uki "${target_root}"; then
    log_warn "Se detectaron UKI en /boot/EFI/Linux/*.efi."
    log_warn "No se modificaran UKI; se continuara generando solo entradas BLS para systemd-boot."
  fi
}

validate_boot_mounted() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local boot_path

  boot_path="$(bootloader_path "${target_root}" /boot)"
  require_directory "${boot_path}"
  findmnt --target "${boot_path}" >/dev/null 2>&1 || die "/boot no esta montado en el target: ${boot_path}"
}

validate_loader_can_be_written() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local boot_path
  local loader_dir

  boot_path="$(bootloader_path "${target_root}" /boot)"
  loader_dir="$(bootloader_path "${target_root}" /boot/loader)"

  require_directory "${boot_path}"
  [[ -d "${loader_dir}" || -w "${boot_path}" ]] || die "No se puede crear /boot/loader en el target."
}

validate_kernel_artifacts() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"

  require_readable_file "$(bootloader_path "${target_root}" /boot/vmlinuz-linux)"
  require_readable_file "$(bootloader_path "${target_root}" /boot/initramfs-linux.img)"
  require_readable_file "$(bootloader_path "${target_root}" /boot/vmlinuz-linux-lts)"
  require_readable_file "$(bootloader_path "${target_root}" /boot/initramfs-linux-lts.img)"
}

validate_bootloader_prerequisites() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"

  validate_arch_target_root "${target_root}"
  bootloader_require_tools
  validate_boot_mounted "${target_root}"
  validate_loader_can_be_written "${target_root}"
  validate_kernel_artifacts "${target_root}"
  target_luks_uuid_required "${target_root}" >/dev/null
  target_btrfs_uuid_required "${target_root}" >/dev/null
  target_mapper_name >/dev/null
  warn_if_target_uki_exists "${target_root}"
}

target_microcode_initrd_line() {
  case "$(detect_cpu_vendor)" in
    intel) printf 'initrd  /intel-ucode.img\n' ;;
    amd) printf 'initrd  /amd-ucode.img\n' ;;
    *) return 0 ;;
  esac
}

kernel_options_for_subvolume() {
  local target_root="$1"
  local subvolume="$2"
  local luks_uuid
  local root_uuid
  local crypt_name

  [[ -n "${subvolume}" ]] || die "Subvolumen Btrfs no puede estar vacio."

  luks_uuid="$(target_luks_uuid_required "${target_root}")"
  root_uuid="$(target_root_kernel_uuid "${target_root}")"
  crypt_name="$(target_mapper_name)"

  printf 'rd.luks.name=%s=%s root=UUID=%s rootflags=subvol=%s rw quiet loglevel=3\n' \
    "${luks_uuid}" "${crypt_name}" "${root_uuid}" "${subvolume}"
}

write_loader_conf() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local loader_conf

  validate_arch_target_root "${target_root}"
  validate_boot_mounted "${target_root}"
  validate_loader_can_be_written "${target_root}"
  loader_conf="$(bootloader_path "${target_root}" /boot/loader/loader.conf)"
  create_directory "$(dirname -- "${loader_conf}")"

  write_file_atomic "${loader_conf}" <<'EOF'
default arch.conf
timeout 3
console-mode max
editor no
EOF
}

entry_filename_for() {
  local kernel_name="$1"
  local subvolume="$2"
  local suffix
  local char
  local i

  if [[ "${subvolume}" == "@" ]]; then
    case "${kernel_name}" in
      linux) printf 'arch.conf\n' ;;
      linux-lts) printf 'arch-lts.conf\n' ;;
      *) die "Kernel no soportado: ${kernel_name}" ;;
    esac
    return 0
  fi

  suffix=""
  for ((i = 0; i < ${#subvolume}; i++)); do
    char="${subvolume:i:1}"
    case "${char}" in
      [A-Za-z0-9_.@-]) suffix+="${char}" ;;
      *) suffix+="-" ;;
    esac
  done

  case "${kernel_name}" in
    linux) printf 'arch-%s.conf\n' "${suffix}" ;;
    linux-lts) printf 'arch-lts-%s.conf\n' "${suffix}" ;;
    *) die "Kernel no soportado: ${kernel_name}" ;;
  esac
}

entry_title_for() {
  local kernel_name="$1"
  local subvolume="$2"

  case "${kernel_name}" in
    linux) printf 'Arch Linux (%s)\n' "${subvolume}" ;;
    linux-lts) printf 'Arch Linux LTS (%s)\n' "${subvolume}" ;;
    *) die "Kernel no soportado: ${kernel_name}" ;;
  esac
}

write_kernel_entry() {
  local target_root="$1"
  local kernel_name="$2"
  local subvolume="$3"
  local entries_dir
  local entry_file
  local title
  local options
  local microcode_line
  local linux_image
  local initramfs_image

  validate_arch_target_root "${target_root}"
  validate_bootloader_prerequisites "${target_root}"
  entries_dir="$(bootloader_path "${target_root}" /boot/loader/entries)"
  create_directory "${entries_dir}"

  entry_file="${entries_dir}/$(entry_filename_for "${kernel_name}" "${subvolume}")"
  if [[ -f "${entry_file}" ]]; then
    backup_file "${entry_file}"
  fi
  title="$(entry_title_for "${kernel_name}" "${subvolume}")"
  options="$(kernel_options_for_subvolume "${target_root}" "${subvolume}")"
  microcode_line="$(target_microcode_initrd_line || true)"

  case "${kernel_name}" in
    linux)
      linux_image="/vmlinuz-linux"
      initramfs_image="/initramfs-linux.img"
      ;;
    linux-lts)
      linux_image="/vmlinuz-linux-lts"
      initramfs_image="/initramfs-linux-lts.img"
      ;;
    *)
      die "Kernel no soportado: ${kernel_name}"
      ;;
  esac

  write_file_atomic "${entry_file}" <<EOF
title   ${title}
linux   ${linux_image}
${microcode_line}initrd  ${initramfs_image}
options ${options}
EOF
}

configured_root_subvolumes() {
  local value="${BOOTLOADER_ROOT_SUBVOLUMES:-${BOOTLOADER_DEFAULT_ROOT_SUBVOLUMES}}"
  local subvol

  for subvol in ${value}; do
    [[ -n "${subvol}" ]] && printf '%s\n' "${subvol}"
  done
}

generate_systemd_boot_entries() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local subvolume

  validate_arch_target_root "${target_root}"
  validate_bootloader_prerequisites "${target_root}"
  log_step "Generando entradas systemd-boot"

  while IFS= read -r subvolume; do
    write_kernel_entry "${target_root}" linux "${subvolume}"
    write_kernel_entry "${target_root}" linux-lts "${subvolume}"
  done < <(configured_root_subvolumes)
}

regenerate_systemd_boot_entries() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"

  generate_systemd_boot_entries "${target_root}"
  if is_yes "${BOOTLOADER_SIGN_AFTER_REGEN}" && target_has_sbctl "${target_root}"; then
    sign_secureboot_artifacts "${target_root}"
  fi
}

write_bootloader_regen_script() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local script_path
  local crypt_name
  local root_subvolumes

  validate_arch_target_root "${target_root}"
  install_bootloader_library_snapshot "${target_root}"
  script_path="$(bootloader_path "${target_root}" /usr/local/sbin/systemd-boot-regenerate-entries)"
  create_directory "$(dirname -- "${script_path}")"
  crypt_name="$(target_mapper_name)"
  root_subvolumes="${BOOTLOADER_ROOT_SUBVOLUMES:-${BOOTLOADER_DEFAULT_ROOT_SUBVOLUMES}}"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '\n'
    printf '%s\n' 'export TARGET_ROOT="/"'
    printf 'export CRYPT_NAME=%q\n' "${crypt_name}"
    printf 'export BOOTLOADER_ROOT_SUBVOLUMES=%q\n' "${root_subvolumes}"
    printf 'export BOOTLOADER_SIGN_AFTER_REGEN=%q\n' "${BOOTLOADER_SIGN_AFTER_REGEN}"
    cat <<'EOF'

source /usr/local/lib/arch-workstation-installer/scripts/lib/bootloader.sh

# This hook runs from the installed system after pacman transactions. Reuse the
# project bootloader library, but adapt chroot helpers so the same generation
# algorithm executes directly against / without requiring arch-install-scripts.
bootloader_require_tools() {
  require_command blkid findmnt
}

arch_chroot_run() {
  local target_root="$1"
  shift || die "arch_chroot_run requiere comando."
  [[ "${target_root}" == "/" ]] || die "El hook local solo puede operar sobre /."
  (($# > 0)) || die "arch_chroot_run requiere comando."
  "$@"
}

target_has_sbctl() {
  local target_root="${1:-/}"
  [[ "${target_root}" == "/" ]] || die "target_has_sbctl local solo puede operar sobre /."
  [[ -x /usr/bin/sbctl ]]
}

regenerate_systemd_boot_entries "/"
EOF
  } | write_file_atomic "${script_path}"

  chmod 0755 "${script_path}"
}

install_bootloader_library_snapshot() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local src
  local dest_dir
  local dest
  local lib

  validate_arch_target_root "${target_root}"
  dest_dir="$(bootloader_path "${target_root}" "${BOOTLOADER_TARGET_LIB_DIR}")"
  create_directory "${dest_dir}"

  for lib in common logging config hardware chroot secureboot bootloader; do
    src="${BOOTLOADER_LIB_DIR}/${lib}.sh"
    dest="${dest_dir}/${lib}.sh"
    require_readable_file "${src}"
    write_file_atomic "${dest}" < "${src}"
    chmod 0644 "${dest}"
  done
}

write_bootloader_pacman_hook() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local hook_path

  validate_arch_target_root "${target_root}"
  hook_path="$(bootloader_path "${target_root}" /etc/pacman.d/hooks/90-systemd-boot-entries.hook)"
  create_directory "$(dirname -- "${hook_path}")"

  write_file_atomic "${hook_path}" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux
Target = linux-lts
Target = systemd
Target = mkinitcpio
Target = intel-ucode
Target = amd-ucode

[Action]
Description = Regenerating systemd-boot entries
When = PostTransaction
Exec = /usr/local/sbin/systemd-boot-regenerate-entries
EOF
}

install_bootloader_regeneration_hook() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"

  write_bootloader_regen_script "${target_root}"
  write_bootloader_pacman_hook "${target_root}"
}

validate_systemd_boot_entries() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local subvolume
  local linux_entry
  local lts_entry

  validate_arch_target_root "${target_root}"
  require_readable_file "$(bootloader_path "${target_root}" /boot/loader/loader.conf)"

  while IFS= read -r subvolume; do
    linux_entry="$(bootloader_path "${target_root}" "/boot/loader/entries/$(entry_filename_for linux "${subvolume}")")"
    lts_entry="$(bootloader_path "${target_root}" "/boot/loader/entries/$(entry_filename_for linux-lts "${subvolume}")")"
    require_readable_file "${linux_entry}"
    require_readable_file "${lts_entry}"
  done < <(configured_root_subvolumes)
}

show_bootloader_summary() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"
  local version

  log_section "Resumen systemd-boot"
  version="$(systemd_boot_version "${target_root}" 2>/dev/null || true)"
  version="${version%%$'\n'*}"
  log_kv "Target" "${target_root}"
  log_kv "Instalado" "$(systemd_boot_installed "${target_root}" && printf 'yes' || printf 'no')"
  log_kv "Version" "${version:-unknown}"
  log_kv "EFI UUID" "$(target_efi_filesystem_uuid "${target_root}")"
  log_kv "Btrfs UUID" "$(target_btrfs_filesystem_uuid "${target_root}")"
  log_kv "root= UUID" "$(target_root_kernel_uuid "${target_root}")"
  log_kv "LUKS UUID" "$(target_luks_uuid_required "${target_root}")"
  log_kv "Mapper" "$(target_mapper_name)"
  log_kv "Subvolumenes root" "${BOOTLOADER_ROOT_SUBVOLUMES:-${BOOTLOADER_DEFAULT_ROOT_SUBVOLUMES}}"
}

configure_systemd_boot_for_target() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET}}}"

  ensure_install_config_loaded
  validate_install_config
  validate_arch_target_root "${target_root}"
  bootloader_require_tools

  install_systemd_boot "${target_root}"
  write_loader_conf "${target_root}"
  regenerate_systemd_boot_entries "${target_root}"
  install_bootloader_regeneration_hook "${target_root}"
  validate_systemd_boot_entries "${target_root}"
  show_bootloader_summary "${target_root}"
}
