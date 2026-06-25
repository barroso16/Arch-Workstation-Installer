#!/usr/bin/env bash
# Secure Boot helpers for the Arch workstation installer.
#
# This library manages sbctl-related operations inside an already installed
# target root. It does not partition, format, install packages, or configure
# NVIDIA.

set -euo pipefail

SECUREBOOT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F die >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${SECUREBOOT_LIB_DIR}/common.sh"
fi

if ! declare -F log_section >/dev/null 2>&1; then
  # shellcheck source=logging.sh
  source "${SECUREBOOT_LIB_DIR}/logging.sh"
fi

if ! declare -F validate_install_config >/dev/null 2>&1; then
  # shellcheck source=config.sh
  source "${SECUREBOOT_LIB_DIR}/config.sh"
fi

if ! declare -F detect_secure_boot >/dev/null 2>&1; then
  # shellcheck source=hardware.sh
  source "${SECUREBOOT_LIB_DIR}/hardware.sh"
fi

if ! declare -F arch_chroot_run >/dev/null 2>&1; then
  # shellcheck source=chroot.sh
  source "${SECUREBOOT_LIB_DIR}/chroot.sh"
fi

secureboot_status() {
  detect_secure_boot
}

detect_setup_mode() {
  local setup_mode_var
  local byte

  if ! is_uefi_booted; then
    printf 'unsupported\n'
    return 0
  fi

  setup_mode_var="$(find /sys/firmware/efi/efivars -maxdepth 1 -name 'SetupMode-*' -print -quit 2>/dev/null || true)"
  if [[ -z "${setup_mode_var}" || ! -r "${setup_mode_var}" ]]; then
    printf 'unknown\n'
    return 0
  fi

  byte="$(od -An -t u1 -j 4 -N 1 "${setup_mode_var}" 2>/dev/null | tr -d '[:space:]' || true)"
  case "${byte}" in
    1) printf 'enabled\n' ;;
    0) printf 'disabled\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

target_has_sbctl() {
  local target_root="${1:-${TARGET_ROOT}}"

  validate_arch_target_root "${target_root}"
  [[ -x "$(target_path "${target_root}" /usr/bin/sbctl)" ]]
}

require_target_sbctl() {
  local target_root="${1:-${TARGET_ROOT}}"

  target_has_sbctl "${target_root}" || die "sbctl no esta instalado dentro del target: ${target_root}"
}

show_secureboot_status_summary() {
  local target_root="${1:-${TARGET_ROOT}}"
  local sbctl_status

  if target_has_sbctl "${target_root}"; then
    sbctl_status="$(arch_chroot_run "${target_root}" sbctl status 2>&1 || true)"
  else
    sbctl_status="sbctl no instalado en target"
  fi

  log_section "Estado Secure Boot"
  log_kv "Secure Boot" "$(secureboot_status)"
  log_kv "Setup Mode" "$(detect_setup_mode)"
  log_kv "sbctl" "${sbctl_status}"
}

target_sbctl_keys_exist() {
  local target_root="${1:-${TARGET_ROOT}}"

  [[ -f "$(target_path "${target_root}" /usr/share/secureboot/keys/PK/PK.key)" ]] &&
    [[ -f "$(target_path "${target_root}" /usr/share/secureboot/keys/KEK/KEK.key)" ]] &&
    [[ -f "$(target_path "${target_root}" /usr/share/secureboot/keys/db/db.key)" ]]
}

create_sbctl_keys_if_enabled() {
  local target_root="${1:-${TARGET_ROOT}}"

  ensure_install_config_loaded
  require_target_sbctl "${target_root}"

  if ! is_yes "${SBCTL_CREATE_KEYS}"; then
    log_warn "SBCTL_CREATE_KEYS no esta habilitado; no se crean claves."
    return 0
  fi

  if target_sbctl_keys_exist "${target_root}"; then
    log_info "Las claves sbctl ya existen en el target."
    return 0
  fi

  log_step "Creando claves Secure Boot con sbctl"
  arch_chroot_run "${target_root}" sbctl create-keys
}

enroll_sbctl_keys_conservative() {
  local target_root="${1:-${TARGET_ROOT}}"
  local setup_mode

  ensure_install_config_loaded
  require_target_sbctl "${target_root}"
  setup_mode="$(detect_setup_mode)"

  show_secureboot_status_summary "${target_root}"

  if [[ "${setup_mode}" != "enabled" ]]; then
    log_warn "Setup Mode disabled; enrolamiento omitido. Bootloader firmado y verificable si sbctl verify pasa."
    log_warn "Estado Setup Mode detectado: ${setup_mode}"
    return 0
  fi

  confirm_yes_no "Quieres enrolar claves Secure Boot ahora con sbctl?" || \
    { log_warn "Enrolamiento de claves omitido por el operador."; return 0; }

  if is_yes "${SBCTL_ENROLL_MICROSOFT_KEYS}"; then
    log_warn "Enrolando claves sbctl con Microsoft keys por configuracion explicita."
    arch_chroot_run "${target_root}" sbctl enroll-keys --microsoft
  else
    log_warn "Enrolando solo claves propias sbctl. Microsoft keys no se incluyen."
    arch_chroot_run "${target_root}" sbctl enroll-keys
  fi
}

target_sign_file_if_exists() {
  local target_root="$1"
  local path_in_target="$2"
  local full_path

  require_target_sbctl "${target_root}"
  validate_absolute_path "${path_in_target}"
  full_path="$(target_path "${target_root}" "${path_in_target}")"

  [[ -f "${full_path}" ]] || return 0
  log_step "Firmando ${path_in_target}"
  arch_chroot_run "${target_root}" sbctl sign -s "${path_in_target}"
}

sign_known_secureboot_artifacts() {
  local target_root="${1:-${TARGET_ROOT}}"

  require_target_sbctl "${target_root}"

  target_sign_file_if_exists "${target_root}" /boot/EFI/systemd/systemd-bootx64.efi
  target_sign_file_if_exists "${target_root}" /boot/EFI/BOOT/BOOTX64.EFI
  target_sign_file_if_exists "${target_root}" /boot/vmlinuz-linux
  target_sign_file_if_exists "${target_root}" /boot/vmlinuz-linux-lts
}

sign_all_target_efi_binaries() {
  local target_root="${1:-${TARGET_ROOT}}"
  local boot_dir
  local efi_file
  local path_in_target

  require_target_sbctl "${target_root}"
  boot_dir="$(target_path "${target_root}" /boot)"
  require_directory "${boot_dir}"

  while IFS= read -r -d '' efi_file; do
    path_in_target="${efi_file#"${target_root%/}"}"
    target_sign_file_if_exists "${target_root}" "${path_in_target}"
  done < <(find "${boot_dir}" -type f -iname '*.efi' -print0)
}

sign_secureboot_artifacts() {
  local target_root="${1:-${TARGET_ROOT}}"

  log_section "Firma Secure Boot"
  sign_known_secureboot_artifacts "${target_root}"
  sign_all_target_efi_binaries "${target_root}"
}

verify_secureboot_signatures() {
  local target_root="${1:-${TARGET_ROOT}}"

  require_target_sbctl "${target_root}"
  log_step "Verificando firmas con sbctl"
  arch_chroot_run "${target_root}" sbctl verify
}

write_secureboot_resign_script() {
  local target_root="${1:-${TARGET_ROOT}}"
  local script_path

  validate_arch_target_root "${target_root}"
  script_path="$(target_path "${target_root}" /usr/local/sbin/secureboot-resign)"
  create_directory "$(dirname -- "${script_path}")"

  write_file_atomic "${script_path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if ! command -v sbctl >/dev/null 2>&1; then
  echo "sbctl no esta instalado" >&2
  exit 1
fi

while IFS= read -r -d '' efi_file; do
  # EFI binaries can include firmware/vendor launchers or optional fallback
  # files. They are attempted, but optional EFI failures do not stop kernel
  # signing. Kernel signing and final verification remain strict below.
  sbctl sign -s "${efi_file}" || true
done < <(find /boot -type f -iname '*.efi' -print0)

for kernel in /boot/vmlinuz-linux /boot/vmlinuz-linux-lts; do
  if [[ -f "${kernel}" ]]; then
    sbctl sign -s "${kernel}"
  fi
done

sbctl verify
EOF

  chmod 0755 "${script_path}"
}

write_secureboot_pacman_hook() {
  local target_root="${1:-${TARGET_ROOT}}"
  local hook_path

  validate_arch_target_root "${target_root}"
  hook_path="$(target_path "${target_root}" /etc/pacman.d/hooks/95-secureboot-resign.hook)"
  create_directory "$(dirname -- "${hook_path}")"

  write_file_atomic "${hook_path}" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = systemd
Target = linux
Target = linux-lts
Target = sbctl
# systemd-boot is shipped by the systemd package on Arch Linux. If a derivative
# splits it into a separate package, add its package name here.

[Action]
Description = Re-signing Secure Boot EFI binaries and kernels
When = PostTransaction
Exec = /usr/local/sbin/secureboot-resign
EOF
}

install_secureboot_hooks() {
  local target_root="${1:-${TARGET_ROOT}}"

  write_secureboot_resign_script "${target_root}"
  write_secureboot_pacman_hook "${target_root}"
}

show_secureboot_bios_instructions() {
  log_section "Instrucciones posteriores de Secure Boot"
  log_info "Estado actual de Secure Boot: $(secureboot_status)"
  log_info "Despues de instalar y verificar firmas:"
  log_info "1. Reinicia el equipo."
  log_info "2. Entra en BIOS/UEFI."
  log_info "3. Activa Secure Boot o cambia a User Mode si estabas en Setup Mode."
  log_info "4. Guarda cambios y arranca Arch Linux."
  log_info "5. Ejecuta: sbctl status"
  log_info "6. Ejecuta: sbctl verify"
  log_warn "No desactives Secure Boot permanentemente; usa Setup Mode solo si tu firmware lo requiere para enrolar claves."
}

prepare_secureboot_for_target() {
  local target_root="${1:-${TARGET_ROOT}}"

  ensure_install_config_loaded
  validate_install_config
  require_target_sbctl "${target_root}"

  create_sbctl_keys_if_enabled "${target_root}"
  enroll_sbctl_keys_conservative "${target_root}"
  sign_secureboot_artifacts "${target_root}"
  install_secureboot_hooks "${target_root}"
  verify_secureboot_signatures "${target_root}"
  show_secureboot_bios_instructions
}
