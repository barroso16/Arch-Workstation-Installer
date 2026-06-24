#!/usr/bin/env bash
# Bootloader infrastructure helpers for the Arch workstation installer.
#
# This library validates the target, EFI mount, and systemd-boot prerequisites,
# then installs and configures systemd-boot when explicitly requested. Secure
# Boot helpers prepare sbctl keys and sign boot artifacts, but they do not
# enroll keys or manually modify UEFI variables.

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

if ! declare -F validate_arch_target_root >/dev/null 2>&1; then
  # shellcheck source=chroot.sh
  source "${BOOTLOADER_LIB_DIR}/chroot.sh"
fi

if ! declare -F detect_cpu_vendor >/dev/null 2>&1; then
  # shellcheck source=hardware.sh
  source "${BOOTLOADER_LIB_DIR}/hardware.sh"
fi

BOOTLOADER_DEFAULT_TARGET_ROOT="${BOOTLOADER_DEFAULT_TARGET_ROOT:-/mnt}"
BOOTLOADER_INSTALL_STATUS="${BOOTLOADER_INSTALL_STATUS:-unknown}"
SECURE_BOOT_KEYS_STATUS="${SECURE_BOOT_KEYS_STATUS:-unknown}"
SECURE_BOOT_SIGNING_STATUS="${SECURE_BOOT_SIGNING_STATUS:-not-run}"
SECURE_BOOT_VERIFY_STATUS="${SECURE_BOOT_VERIFY_STATUS:-not-run}"
SECURE_BOOT_ENROLLMENT_STATUS="${SECURE_BOOT_ENROLLMENT_STATUS:-not-run}"

target_boot_path() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  validate_absolute_path "${target_root}"
  printf '%s/boot\n' "${target_root%/}"
}

target_loader_path() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  printf '%s/loader\n' "$(target_boot_path "${target_root}")"
}

target_loader_entries_path() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  printf '%s/entries\n' "$(target_loader_path "${target_root}")"
}

target_loader_conf_path() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  printf '%s/loader.conf\n' "$(target_loader_path "${target_root}")"
}

target_arch_entry_path() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  printf '%s/arch.conf\n' "$(target_loader_entries_path "${target_root}")"
}

target_systemd_boot_efi_path() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  printf '%s/EFI/systemd/%s\n' "$(target_boot_path "${target_root}")" "$(systemd_boot_efi_binary_name)"
}

systemd_boot_efi_binary_name() {
  local architecture

  architecture="$(uname -m 2>/dev/null || printf 'x86_64')"
  case "${architecture}" in
    x86_64|amd64) printf 'systemd-bootx64.efi\n' ;;
    aarch64|arm64) printf 'systemd-bootaa64.efi\n' ;;
    *)
      log_warn "Arquitectura EFI no reconocida (${architecture}); usando systemd-bootx64.efi por defecto."
      printf 'systemd-bootx64.efi\n'
      ;;
  esac
}

validate_bootloader_target() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  log_section "Validacion target bootloader"
  validate_absolute_path "${target_root}"
  require_directory "${target_root}"
  is_mounted "${target_root}" || die "${target_root} no esta montado."
  require_readable_file "${target_root%/}/etc/os-release"
  require_file "${target_root%/}/usr/bin/bash"
  validate_arch_target_root "${target_root}"
  success "Target root valido para bootloader: ${target_root}"
}

validate_efi_mount() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local boot_path
  local efi_dir
  local fstype

  boot_path="$(target_boot_path "${target_root}")"
  efi_dir="${boot_path}/EFI"

  log_section "Validacion EFI"
  require_directory "${boot_path}"
  findmnt --target "${boot_path}" >/dev/null 2>&1 || die "/boot no esta montado en el target: ${boot_path}"

  fstype="$(findmnt -no FSTYPE --target "${boot_path}" 2>/dev/null || true)"
  case "${fstype}" in
    vfat|fat|msdos) ;;
    *) die "/boot no esta montado como FAT/VFAT: ${boot_path} (${fstype:-unknown})" ;;
  esac

  if [[ -d "${efi_dir}" ]]; then
    success "Directorio EFI existente: ${efi_dir}"
  else
    create_directory "${efi_dir}" 0755
    success "Directorio EFI creado: ${efi_dir}"
  fi
}

target_has_bootctl() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  [[ -x "${target_root%/}/usr/bin/bootctl" ]] && return 0
  arch_chroot_capture "${target_root}" command -v bootctl >/dev/null 2>&1
}

target_has_systemd_package() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  [[ -d "${target_root%/}/usr/lib/systemd" ]] || [[ -x "${target_root%/}/usr/bin/systemctl" ]]
}

validate_systemd_boot_tooling() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  if target_has_bootctl "${target_root}"; then
    success "bootctl disponible dentro del target."
    return 0
  fi

  if target_has_systemd_package "${target_root}"; then
    log_warn "bootctl no se detecto con command -v, pero systemd parece estar instalado en el target."
    return 0
  fi

  die "No se detecto bootctl ni systemd en el target."
}

target_kernel_artifacts_present() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  [[ -f "${target_root%/}/boot/vmlinuz-linux" ]] ||
    [[ -f "${target_root%/}/boot/vmlinuz-linux-lts" ]] ||
    [[ -d "${target_root%/}/usr/lib/modules" ]]
}

validate_target_kernel_artifacts() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  target_kernel_artifacts_present "${target_root}" || \
    die "No se detectaron kernels en /boot ni modulos en /usr/lib/modules del target."
  success "Artefactos de kernel detectados o verificables mas adelante."
}

validate_target_initramfs_artifacts() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  if [[ -f "${target_root%/}/boot/initramfs-linux.img" ]] ||
     [[ -f "${target_root%/}/boot/initramfs-linux-lts.img" ]]; then
    success "initramfs detectado en /boot."
    return 0
  fi

  die "No se detecto ningun initramfs en /boot despues de mkinitcpio: initramfs-linux.img o initramfs-linux-lts.img."
}

validate_systemd_boot_prerequisites() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  log_section "Prerequisitos systemd-boot"
  validate_bootloader_target "${target_root}"
  validate_efi_mount "${target_root}"
  require_arch_chroot_available
  validate_systemd_boot_tooling "${target_root}"
  validate_target_kernel_artifacts "${target_root}"
  validate_target_initramfs_artifacts "${target_root}"
  success "Prerequisitos systemd-boot validados para ${target_root}."
}

detect_target_root_partition_uuid() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local source

  require_command findmnt blkid
  source="$(findmnt -no SOURCE --target "${target_root}" 2>/dev/null || true)"
  [[ -n "${source}" ]] || die "No se pudo detectar el dispositivo raiz montado en ${target_root}."
  blkid -s PARTUUID -o value "${source}" 2>/dev/null || blkid -s UUID -o value "${source}"
}

detect_target_root_filesystem_uuid() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local source
  local uuid

  require_command findmnt blkid
  source="$(findmnt -no SOURCE --target "${target_root}" 2>/dev/null || true)"
  [[ -n "${source}" ]] || die "No se pudo detectar el filesystem raiz montado en ${target_root}."

  uuid="$(findmnt -no UUID --target "${target_root}" 2>/dev/null || true)"
  if [[ -z "${uuid}" ]]; then
    uuid="$(blkid -s UUID -o value "${source}" 2>/dev/null || true)"
  fi

  [[ -n "${uuid}" ]] || die "No se pudo detectar UUID Btrfs para ${source}."
  printf '%s\n' "${uuid}"
}

detect_target_luks_source_device() {
  local crypt_name="${CRYPT_NAME:-cryptroot}"
  local device

  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  require_command cryptsetup

  device="$(cryptsetup status "${crypt_name}" 2>/dev/null | awk -F: '
    $1 ~ /^[[:space:]]*device$/ {
      gsub(/^[[:space:]]+/, "", $2)
      print $2
      exit
    }
  ')"

  [[ -b "${device}" ]] || die "No se pudo detectar la particion cifrada de ${crypt_name}."
  printf '%s\n' "${device}"
}

detect_target_luks_uuid() {
  local luks_device
  local uuid

  require_command cryptsetup blkid
  luks_device="$(detect_target_luks_source_device)"
  uuid="$(cryptsetup luksUUID "${luks_device}" 2>/dev/null || true)"
  if [[ -z "${uuid}" ]]; then
    uuid="$(blkid -s UUID -o value "${luks_device}" 2>/dev/null || true)"
  fi

  [[ -n "${uuid}" ]] || die "No se pudo detectar UUID LUKS desde ${luks_device}."
  printf '%s\n' "${uuid}"
}

verify_loader_directory_exists() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local loader_dir
  local entries_dir

  loader_dir="$(target_loader_path "${target_root}")"
  entries_dir="$(target_loader_entries_path "${target_root}")"

  require_directory "${loader_dir}"
  require_directory "${entries_dir}"
  success "Directorios loader verificados: ${loader_dir}, ${entries_dir}"
}

verify_systemd_boot_efi_binary_exists() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local efi_systemd_dir
  local efi_binary

  efi_systemd_dir="$(target_boot_path "${target_root}")/EFI/systemd"
  efi_binary="$(target_systemd_boot_efi_path "${target_root}")"

  require_directory "${efi_systemd_dir}"
  require_file "${efi_binary}"
  success "Binario systemd-boot EFI verificado: ${efi_binary}"
}

verify_systemd_boot_installed() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  verify_loader_directory_exists "${target_root}"
  verify_systemd_boot_efi_binary_exists "${target_root}"
  success "systemd-boot aparece instalado en ${target_root}."
}

systemd_boot_appears_installed() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  [[ -d "$(target_loader_path "${target_root}")" ]] &&
    [[ -d "$(target_loader_entries_path "${target_root}")" ]] &&
    [[ -f "$(target_systemd_boot_efi_path "${target_root}")" ]]
}

install_systemd_boot() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  validate_systemd_boot_prerequisites "${target_root}"

  if systemd_boot_appears_installed "${target_root}"; then
    BOOTLOADER_INSTALL_STATUS="already_present"
    export BOOTLOADER_INSTALL_STATUS
    log_step "systemd-boot ya parece estar instalado; reutilizando instalacion existente."
    verify_systemd_boot_installed "${target_root}"
    return 0
  fi

  log_step "Instalando systemd-boot con bootctl install --no-variables dentro del target"
  arch_chroot_run "${target_root}" bootctl install --no-variables
  BOOTLOADER_INSTALL_STATUS="installed"
  export BOOTLOADER_INSTALL_STATUS
  verify_systemd_boot_installed "${target_root}"
}

backup_bootloader_file_if_exists() {
  local file="$1"
  local backup

  [[ -e "${file}" ]] || return 0
  require_command cp date
  backup="${file}.bak.$(date '+%Y%m%d-%H%M%S')"
  log_warn "Ya existe y sera reemplazado: ${file}"
  cp -a -- "${file}" "${backup}"
  log_warn "Backup creado: ${backup}"
}

write_loader_conf() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local loader_conf

  loader_conf="$(target_loader_conf_path "${target_root}")"
  create_directory "$(dirname -- "${loader_conf}")"
  backup_bootloader_file_if_exists "${loader_conf}"

  write_file_atomic "${loader_conf}" <<'EOF'
default arch.conf
timeout 3
console-mode max
editor no
EOF
  success "loader.conf escrito: ${loader_conf}"
}

target_microcode_initrd_line() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local microcode_image

  case "$(detect_cpu_vendor)" in
    intel) microcode_image="/intel-ucode.img" ;;
    amd) microcode_image="/amd-ucode.img" ;;
    *) return 0 ;;
  esac

  require_file "$(target_boot_path "${target_root}")/${microcode_image#/}"
  printf 'initrd %s\n' "${microcode_image}"
}

quiet_boot_enabled() {
  is_yes "${BOOT_QUIET:-${QUIET_BOOT:-no}}"
}

kernel_options_line() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local luks_uuid
  local crypt_name="${CRYPT_NAME:-cryptroot}"
  local options

  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  luks_uuid="$(detect_target_luks_uuid "${target_root}")"
  detect_target_root_filesystem_uuid "${target_root}" >/dev/null

  options="rd.luks.name=${luks_uuid}=${crypt_name} root=/dev/mapper/${crypt_name} rootflags=subvol=@ rw"
  if quiet_boot_enabled; then
    options="${options} quiet"
  fi

  printf '%s\n' "${options}"
}

write_arch_entry() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local entry_file
  local microcode_line
  local options

  require_file "$(target_boot_path "${target_root}")/vmlinuz-linux"
  require_file "$(target_boot_path "${target_root}")/initramfs-linux.img"

  entry_file="$(target_arch_entry_path "${target_root}")"
  create_directory "$(dirname -- "${entry_file}")"
  backup_bootloader_file_if_exists "${entry_file}"
  microcode_line="$(target_microcode_initrd_line "${target_root}" || true)"
  options="$(kernel_options_line "${target_root}")"

  {
    printf '%s\n' "title Arch Linux"
    printf '%s\n' "linux /vmlinuz-linux"
    if [[ -n "${microcode_line}" ]]; then
      printf '%s\n' "${microcode_line}"
    fi
    printf '%s\n' "initrd /initramfs-linux.img"
    printf '%s\n' "options ${options}"
  } | write_file_atomic "${entry_file}"

  success "Entrada Arch escrita: ${entry_file}"
}

verify_loader_conf() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local loader_conf

  loader_conf="$(target_loader_conf_path "${target_root}")"
  require_readable_file "${loader_conf}"
  grep -q '^default arch\.conf$' "${loader_conf}" || die "loader.conf no contiene default arch.conf."
  grep -q '^timeout 3$' "${loader_conf}" || die "loader.conf no contiene timeout 3."
  grep -q '^console-mode max$' "${loader_conf}" || die "loader.conf no contiene console-mode max."
  grep -q '^editor no$' "${loader_conf}" || die "loader.conf no contiene editor no."
}

verify_arch_entry() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local entry_file
  local boot_path
  local initrd_line
  local crypt_name="${CRYPT_NAME:-cryptroot}"
  local luks_uuid

  entry_file="$(target_arch_entry_path "${target_root}")"
  boot_path="$(target_boot_path "${target_root}")"
  validate_shell_identifier "${crypt_name}" "CRYPT_NAME"
  luks_uuid="$(detect_target_luks_uuid "${target_root}")"

  require_readable_file "${entry_file}"
  grep -q '^title Arch Linux$' "${entry_file}" || die "arch.conf no contiene title Arch Linux."
  grep -q '^linux /vmlinuz-linux$' "${entry_file}" || die "arch.conf no referencia /vmlinuz-linux."
  require_file "${boot_path}/vmlinuz-linux"
  grep -q '^initrd /initramfs-linux.img$' "${entry_file}" || die "arch.conf no referencia /initramfs-linux.img."
  require_file "${boot_path}/initramfs-linux.img"

  initrd_line="$(awk '$1 == "initrd" && ($2 == "/intel-ucode.img" || $2 == "/amd-ucode.img") { print $2; exit }' "${entry_file}")"
  if [[ -n "${initrd_line}" ]]; then
    require_file "${boot_path}/${initrd_line#/}"
  fi

  grep -q "rd.luks.name=${luks_uuid}=${crypt_name}" "${entry_file}" || \
    die "arch.conf no contiene rd.luks.name=${luks_uuid}=${crypt_name}."
  grep -q "root=/dev/mapper/${crypt_name}" "${entry_file}" || \
    die "arch.conf no contiene root=/dev/mapper/${crypt_name}."
  grep -q 'rootflags=subvol=@' "${entry_file}" || die "arch.conf no contiene rootflags=subvol=@."
  grep -Eq '(^|[[:space:]])rw([[:space:]]|$)' "${entry_file}" || die "arch.conf no contiene rw."

  if grep -Eq '/dev/(sd[a-z]|nvme[0-9]+n[0-9]+|vd[a-z])' "${entry_file}"; then
    die "arch.conf contiene rutas crudas de disco, lo cual no esta permitido."
  fi

  success "Entrada Arch verificada: ${entry_file}"
}

configure_systemd_boot_loader_and_arch_entry() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  validate_systemd_boot_prerequisites "${target_root}"
  verify_systemd_boot_installed "${target_root}"
  write_loader_conf "${target_root}"
  write_arch_entry "${target_root}"
  verify_loader_conf "${target_root}"
  verify_arch_entry "${target_root}"
}

target_has_sbctl() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  [[ -x "${target_root%/}/usr/bin/sbctl" ]] && return 0
  arch_chroot_capture "${target_root}" command -v sbctl >/dev/null 2>&1
}

detect_efi_variable_state() {
  local variable_name="$1"
  local variable_path
  local byte

  if [[ ! -d /sys/firmware/efi/efivars ]]; then
    printf 'unsupported\n'
    return 0
  fi

  variable_path="$(find /sys/firmware/efi/efivars -maxdepth 1 -name "${variable_name}-*" -print -quit 2>/dev/null || true)"
  if [[ -z "${variable_path}" || ! -r "${variable_path}" ]]; then
    printf 'unknown\n'
    return 0
  fi

  byte="$(od -An -t u1 -j 4 -N 1 "${variable_path}" 2>/dev/null | tr -d '[:space:]' || true)"
  case "${byte}" in
    1) printf 'enabled\n' ;;
    0) printf 'disabled\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

detect_secure_boot_state() {
  detect_efi_variable_state "SecureBoot"
}

detect_setup_mode_state() {
  detect_efi_variable_state "SetupMode"
}

show_secure_boot_status() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local sbctl_state="no"

  if target_has_sbctl "${target_root}"; then
    sbctl_state="yes"
  fi

  log_section "Estado Secure Boot"
  log_kv "Secure Boot" "$(detect_secure_boot_state)"
  log_kv "Setup Mode" "$(detect_setup_mode_state)"
  log_kv "sbctl en target" "${sbctl_state}"
}

validate_sbctl_available() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  target_has_sbctl "${target_root}" || \
    die "sbctl no esta disponible dentro del target. Revisa Stage04/package selection: sbctl debe instalarse cuando ENABLE_SECURE_BOOT=yes o SBCTL_CREATE_KEYS=yes."
  success "sbctl disponible dentro del target."
}

validate_secure_boot_environment() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  log_section "Prerequisitos Secure Boot"
  validate_bootloader_target "${target_root}"
  validate_efi_mount "${target_root}"
  require_arch_chroot_available
  validate_sbctl_available "${target_root}"
  show_secure_boot_status "${target_root}"
  success "Entorno Secure Boot validado sin modificar firmware."
}

secure_boot_keys_directory() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  printf '%s/usr/share/secureboot/keys\n' "${target_root%/}"
}

secure_boot_key_files_exist() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local keys_dir
  local key_name

  keys_dir="$(secure_boot_keys_directory "${target_root}")"
  for key_name in PK KEK db; do
    [[ -d "${keys_dir}/${key_name}" ]] || return 1
    find "${keys_dir}/${key_name}" -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q . || return 1
  done
}

sbctl_status_reports_keys() {
  local sbctl_status="$1"

  printf '%s\n' "${sbctl_status}" | grep -Eq '(^|[[:space:]])(Created|Owner GUID):'
}

verify_secure_boot_keys_exist() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local sbctl_status

  validate_sbctl_available "${target_root}"
  secure_boot_key_files_exist "${target_root}" || \
    die "No se encontraron claves sbctl completas en $(secure_boot_keys_directory "${target_root}")."

  sbctl_status="$(arch_chroot_capture "${target_root}" sbctl status)"
  [[ -n "${sbctl_status}" ]] || die "sbctl status no devolvio informacion sobre las claves."
  sbctl_status_reports_keys "${sbctl_status}" || \
    die "sbctl status no reporto informacion reconocible sobre claves Secure Boot."
  log_info "${sbctl_status}"
  success "Claves sbctl verificadas en el target."
}

prepare_secure_boot_keys() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  validate_secure_boot_environment "${target_root}"

  if secure_boot_key_files_exist "${target_root}"; then
    SECURE_BOOT_KEYS_STATUS="reused"
    export SECURE_BOOT_KEYS_STATUS
    log_step "Claves sbctl existentes; reutilizando."
    verify_secure_boot_keys_exist "${target_root}"
    return 0
  fi

  log_step "Creando claves sbctl dentro del target"
  arch_chroot_run "${target_root}" sbctl create-keys
  SECURE_BOOT_KEYS_STATUS="created"
  export SECURE_BOOT_KEYS_STATUS
  verify_secure_boot_keys_exist "${target_root}"
}

fallback_boot_efi_binary_name() {
  local architecture

  architecture="$(uname -m 2>/dev/null || printf 'x86_64')"
  case "${architecture}" in
    x86_64|amd64) printf 'BOOTX64.EFI\n' ;;
    aarch64|arm64) printf 'BOOTAA64.EFI\n' ;;
    *)
      log_warn "Arquitectura EFI no reconocida (${architecture}); usando BOOTX64.EFI por defecto."
      printf 'BOOTX64.EFI\n'
      ;;
  esac
}

secure_boot_candidate_host_path() {
  local target_root="$1"
  local target_path="$2"

  validate_absolute_path "${target_root}"
  validate_absolute_path "${target_path}"
  printf '%s%s\n' "${target_root%/}" "${target_path}"
}

list_secure_boot_signing_candidates() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local host_path
  local candidates=()

  host_path="$(secure_boot_candidate_host_path "${target_root}" "/boot/EFI/systemd/$(systemd_boot_efi_binary_name)")"
  [[ -f "${host_path}" ]] && candidates+=("${host_path}")

  host_path="$(secure_boot_candidate_host_path "${target_root}" "/boot/EFI/BOOT/$(fallback_boot_efi_binary_name)")"
  [[ -f "${host_path}" ]] && candidates+=("${host_path}")

  host_path="$(secure_boot_candidate_host_path "${target_root}" "/boot/vmlinuz-linux")"
  [[ -f "${host_path}" ]] && candidates+=("${host_path}")

  if ((${#candidates[@]} > 0)); then
    printf '%s\n' "${candidates[@]}"
  fi
  return 0
}

list_secure_boot_signing_candidate_target_paths() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local target_path
  local host_path
  local candidates=()

  target_path="/boot/EFI/systemd/$(systemd_boot_efi_binary_name)"
  host_path="$(secure_boot_candidate_host_path "${target_root}" "${target_path}")"
  [[ -f "${host_path}" ]] && candidates+=("${target_path}")

  target_path="/boot/EFI/BOOT/$(fallback_boot_efi_binary_name)"
  host_path="$(secure_boot_candidate_host_path "${target_root}" "${target_path}")"
  [[ -f "${host_path}" ]] && candidates+=("${target_path}")

  target_path="/boot/vmlinuz-linux"
  host_path="$(secure_boot_candidate_host_path "${target_root}" "${target_path}")"
  [[ -f "${host_path}" ]] && candidates+=("${target_path}")

  if ((${#candidates[@]} > 0)); then
    printf '%s\n' "${candidates[@]}"
  fi
  return 0
}

require_secure_boot_signing_candidates() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local candidates

  candidates="$(list_secure_boot_signing_candidate_target_paths "${target_root}")"
  [[ -n "${candidates}" ]] || die "No se detecto ningun artefacto para firmar con sbctl."
}

validate_secure_boot_candidate_target_path() {
  local target_root="$1"
  local target_path="$2"
  local host_path

  validate_absolute_path "${target_path}"
  case "${target_path}" in
    /boot/EFI/systemd/*|/boot/EFI/BOOT/*|/boot/vmlinuz-linux) ;;
    *) die "Candidato Secure Boot fuera de rutas permitidas: ${target_path}" ;;
  esac

  host_path="$(secure_boot_candidate_host_path "${target_root}" "${target_path}")"
  require_file "${host_path}"
}

sign_secure_boot_candidate() {
  local target_root="$1"
  local target_path="$2"

  validate_secure_boot_candidate_target_path "${target_root}" "${target_path}"
  log_step "Firmando candidato Secure Boot: ${target_path}"
  arch_chroot_run "${target_root}" sbctl sign -s "${target_path}"
}

sign_secure_boot_candidates() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local candidates
  local candidate

  validate_secure_boot_environment "${target_root}"
  verify_secure_boot_keys_exist "${target_root}"
  require_secure_boot_signing_candidates "${target_root}"

  candidates="$(list_secure_boot_signing_candidate_target_paths "${target_root}")"
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    sign_secure_boot_candidate "${target_root}" "${candidate}"
  done <<< "${candidates}"

  SECURE_BOOT_SIGNING_STATUS="signed"
  export SECURE_BOOT_SIGNING_STATUS
  verify_secure_boot_signatures "${target_root}"
}

verify_secure_boot_signatures() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local candidates
  local candidate
  local verify_output

  validate_sbctl_available "${target_root}"
  require_secure_boot_signing_candidates "${target_root}"

  candidates="$(list_secure_boot_signing_candidate_target_paths "${target_root}")"
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    validate_secure_boot_candidate_target_path "${target_root}" "${candidate}"
    log_step "Verificando firma Secure Boot: ${candidate}"
    if ! verify_output="$(arch_chroot_capture "${target_root}" sbctl verify "${candidate}")"; then
      die "La verificacion sbctl fallo para ${candidate}: ${verify_output}"
    fi
    log_info "${verify_output}"
  done <<< "${candidates}"

  SECURE_BOOT_VERIFY_STATUS="passed"
  export SECURE_BOOT_VERIFY_STATUS
  success "Firmas Secure Boot verificadas con sbctl."
}

secure_boot_enrollment_requires_confirmation() {
  return 0
}

confirm_secure_boot_key_enrollment() {
  log_section "Confirmacion enrolado Secure Boot"
  log_warn "ADVERTENCIA: esta accion ejecutara sbctl enroll-keys dentro del sistema instalado."
  log_warn "sbctl enroll-keys puede modificar variables de firmware UEFI relacionadas con Secure Boot."
  log_warn "Se enrolaran claves Secure Boot del proyecto. Un enrolado incorrecto puede afectar el arranque."
  log_warn "Asegurate de tener acceso al firmware/BIOS y de entender las consecuencias antes de continuar."

  if confirm_yes_no "Confirmas ejecutar sbctl enroll-keys y modificar variables de firmware Secure Boot"; then
    return 0
  fi

  SECURE_BOOT_ENROLLMENT_STATUS="denied"
  export SECURE_BOOT_ENROLLMENT_STATUS
  die "Enrolado Secure Boot cancelado por el operador."
}

sbctl_status_reports_enrollment_state() {
  local sbctl_status="$1"
  local setup_mode
  local secure_boot

  printf '%s\n' "${sbctl_status}" | grep -q 'Owner GUID:' || return 1
  printf '%s\n' "${sbctl_status}" | grep -q 'Setup Mode:' || return 1

  setup_mode="$(printf '%s\n' "${sbctl_status}" | awk -F: '
    $1 ~ /^[[:space:]]*Setup Mode$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ')"

  case "${setup_mode}" in
    Disabled)
      ;;
    Enabled)
      log_warn "Setup Mode sigue Enabled despues del enrolado; puede requerir reinicio o accion manual en firmware."
      ;;
    *)
      return 1
      ;;
  esac

  secure_boot="$(printf '%s\n' "${sbctl_status}" | awk -F: '
    $1 ~ /^[[:space:]]*Secure Boot$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ')"
  if [[ -n "${secure_boot}" ]]; then
    case "${secure_boot}" in
      Enabled|Disabled) ;;
      *) return 1 ;;
    esac
  fi
}

verify_secure_boot_enrollment_state() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local sbctl_status

  validate_sbctl_available "${target_root}"
  sbctl_status="$(arch_chroot_capture "${target_root}" sbctl status)"
  [[ -n "${sbctl_status}" ]] || die "sbctl status no devolvio informacion despues del enrolado."
  sbctl_status_reports_enrollment_state "${sbctl_status}" || \
    die "sbctl status no reporto un estado de enrolado Secure Boot reconocible."

  log_info "${sbctl_status}"
  SECURE_BOOT_ENROLLMENT_STATUS="enrolled"
  export SECURE_BOOT_ENROLLMENT_STATUS
  success "Estado de enrolado Secure Boot verificado con sbctl."
}

enroll_secure_boot_keys() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  validate_secure_boot_environment "${target_root}"
  verify_secure_boot_keys_exist "${target_root}"
  verify_secure_boot_signatures "${target_root}"
  show_secure_boot_status "${target_root}"

  if secure_boot_enrollment_requires_confirmation; then
    confirm_secure_boot_key_enrollment
  fi

  log_step "Enrolando claves Secure Boot con sbctl enroll-keys"
  arch_chroot_run "${target_root}" sbctl enroll-keys
  verify_secure_boot_enrollment_state "${target_root}"
}

show_secure_boot_preparation_summary() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"
  local candidates
  local candidate
  local sbctl_state="no"

  if target_has_sbctl "${target_root}"; then
    sbctl_state="yes"
  fi

  candidates="$(list_secure_boot_signing_candidate_target_paths "${target_root}")"

  log_section "Resumen preparacion Secure Boot"
  log_kv "Secure Boot" "$(detect_secure_boot_state)"
  log_kv "Setup Mode" "$(detect_setup_mode_state)"
  log_kv "sbctl disponible" "${sbctl_state}"
  log_kv "Claves sbctl" "${SECURE_BOOT_KEYS_STATUS}"
  log_kv "Firma Secure Boot" "${SECURE_BOOT_SIGNING_STATUS}"
  log_kv "Verificacion firmas" "${SECURE_BOOT_VERIFY_STATUS}"
  log_kv "Enrolado claves" "${SECURE_BOOT_ENROLLMENT_STATUS}"
  if [[ -n "${candidates}" ]]; then
    while IFS= read -r candidate; do
      log_kv "Candidato firmado/verificable" "${candidate}"
    done <<< "${candidates}"
  else
    log_kv "Candidatos firma" "ninguno"
  fi
}

show_bootloader_infrastructure_summary() {
  local target_root="${1:-${TARGET_ROOT:-${BOOTLOADER_DEFAULT_TARGET_ROOT}}}"

  log_section "Resumen infraestructura bootloader"
  log_kv "Target root" "${target_root}"
  log_kv "EFI mount" "$(target_boot_path "${target_root}")"
  log_kv "Loader dir" "$(target_loader_path "${target_root}")"
  log_kv "Entries dir" "$(target_loader_entries_path "${target_root}")"
  log_kv "loader.conf" "$(target_loader_conf_path "${target_root}")"
  log_kv "arch.conf" "$(target_arch_entry_path "${target_root}")"
  log_kv "systemd-boot EFI" "$(target_systemd_boot_efi_path "${target_root}")"
  log_kv "Instalacion" "${BOOTLOADER_INSTALL_STATUS}"
}
