#!/usr/bin/env bash
# Hardware detection helpers for the Arch workstation installer.
#
# This library only inspects the running machine. It does not modify disks,
# firmware, packages, Secure Boot state, bootloader configuration, or chroot.

set -euo pipefail

HARDWARE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F die >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${HARDWARE_LIB_DIR}/common.sh"
fi

if ! declare -F log_section >/dev/null 2>&1; then
  # shellcheck source=logging.sh
  source "${HARDWARE_LIB_DIR}/logging.sh"
fi

if ! declare -F validate_install_config >/dev/null 2>&1; then
  # shellcheck source=config.sh
  source "${HARDWARE_LIB_DIR}/config.sh"
fi

HARDWARE_DISK_INVENTORY_LOADED="no"
HARDWARE_DISKS=()

declare -Ag HARDWARE_DISK_SIZE=()
declare -Ag HARDWARE_DISK_MODEL=()
declare -Ag HARDWARE_DISK_SERIAL=()
declare -Ag HARDWARE_DISK_TYPE=()
declare -Ag HARDWARE_DISK_TRAN=()
declare -Ag HARDWARE_DISK_RM=()

is_uefi_booted() {
  [[ -d /sys/firmware/efi/efivars ]]
}

detect_uefi() {
  if is_uefi_booted; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

detect_secure_boot() {
  local secure_boot_var
  local byte

  if ! is_uefi_booted; then
    printf 'unsupported\n'
    return 0
  fi

  secure_boot_var="$(find /sys/firmware/efi/efivars -maxdepth 1 -name 'SecureBoot-*' -print -quit 2>/dev/null || true)"
  if [[ -z "${secure_boot_var}" || ! -r "${secure_boot_var}" ]]; then
    printf 'unknown\n'
    return 0
  fi

  byte="$(od -An -t u1 -j 4 -N 1 "${secure_boot_var}" 2>/dev/null | tr -d '[:space:]' || true)"
  case "${byte}" in
    1) printf 'enabled\n' ;;
    0) printf 'disabled\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

detect_cpu_vendor() {
  local vendor

  vendor="$(awk -F: '/vendor_id/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  case "${vendor}" in
    GenuineIntel) printf 'intel\n' ;;
    AuthenticAMD) printf 'amd\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

detect_cpu_model() {
  awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || printf 'unknown\n'
}

detect_microcode_package() {
  case "$(detect_cpu_vendor)" in
    intel) printf 'intel-ucode\n' ;;
    amd) printf 'amd-ucode\n' ;;
    *) printf '\n' ;;
  esac
}

detect_cpu_virtualization() {
  local vendor

  vendor="$(detect_cpu_vendor)"
  case "${vendor}" in
    intel)
      if grep -Eq '(^|[[:space:]])vmx([[:space:]]|$)' /proc/cpuinfo; then
        printf 'Intel VT-x\n'
      else
        printf 'none\n'
      fi
      ;;
    amd)
      if grep -Eq '(^|[[:space:]])svm([[:space:]]|$)' /proc/cpuinfo; then
        printf 'AMD-V\n'
      else
        printf 'none\n'
      fi
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

cpu_virtualization_available() {
  case "$(detect_cpu_virtualization)" in
    "Intel VT-x"|"AMD-V") return 0 ;;
    *) return 1 ;;
  esac
}

detect_nvidia_gpu() {
  command_exists lspci || return 1
  lspci -nn 2>/dev/null | grep -Eiq 'NVIDIA.*(VGA|3D|Display|Graphics)|((VGA|3D|Display|Graphics).*)NVIDIA'
}

detect_amd_gpu() {
  command_exists lspci || return 1
  lspci -nn 2>/dev/null | grep -Eiq '(AMD|ATI).*(VGA|3D|Display|Graphics)|((VGA|3D|Display|Graphics).*)(AMD|ATI)'
}

detect_amd_gpu_model() {
  if ! command_exists lspci; then
    printf 'unknown\n'
    return 0
  fi

  lspci -nn 2>/dev/null | awk '
    BEGIN { found = 0 }
    /(AMD|ATI)/ && /(VGA|3D|Display|Graphics)/ {
      sub(/^[^ ]+ /, "")
      print
      found = 1
    }
    END {
      if (found == 0) {
        print "none"
      }
    }
  '
}

detect_nvidia_gpu_model() {
  if ! command_exists lspci; then
    printf 'unknown\n'
    return 0
  fi

  lspci -nn 2>/dev/null | awk '
    BEGIN { found = 0 }
    /NVIDIA/ && /(VGA|3D|Display|Graphics)/ {
      sub(/^[^ ]+ /, "")
      print
      found = 1
    }
    END {
      if (found == 0) {
        print "none"
      }
    }
  '
}

nvidia_gpu_model_upper() {
  detect_nvidia_gpu_model | tr '[:lower:]' '[:upper:]'
}

nvidia_open_kernel_modules_preferred() {
  local model_text

  model_text="$(nvidia_gpu_model_upper)"
  [[ "${model_text}" != "NONE" ]] || return 1

  # Turing/GTX16/RTX and newer use Arch's current official open modules.
  grep -Eq 'RTX|GTX 16|T[0-9]{3,}|A[0-9]{3,}|L[0-9]{1,2}|QUADRO RTX' <<<"${model_text}"
}

nvidia_legacy_gpu_detected() {
  local model_text

  model_text="$(nvidia_gpu_model_upper)"
  grep -Eq 'GTX (10|9|8|7|6|5|4)[0-9]{2}|GT [0-9]{3}|QUADRO [KMP][0-9]|TESLA [KMP][0-9]' <<<"${model_text}"
}

detect_intel_display_gpu() {
  command_exists lspci || return 1
  lspci -nn 2>/dev/null | grep -Eiq 'Intel.*(VGA|3D|Display|Graphics)|((VGA|3D|Display|Graphics).*)Intel'
}

detect_hybrid_intel_nvidia_graphics() {
  detect_nvidia_gpu && detect_intel_display_gpu
}

detect_tpm2() {
  if [[ -r /sys/class/tpm/tpm0/tpm_version_major ]]; then
    [[ "$(cat /sys/class/tpm/tpm0/tpm_version_major)" == "2" ]]
    return
  fi

  [[ -e /dev/tpmrm0 || -e /dev/tpm0 ]] || return 1

  if command_exists systemd-creds; then
    systemd-creds has-tpm2 >/dev/null 2>&1
    return
  fi

  return 0
}

detect_tpm2_status() {
  if detect_tpm2; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

hardware_lsblk_pair_value() {
  local line
  local key="$2"
  local rest
  local pair_key
  local pair_value

  line="$1"
  rest="${line}"
  while [[ "${rest}" =~ ^[[:space:]]*([A-Z_]+)=\"(([^\"\\]|\\.)*)\"(.*)$ ]]; do
    pair_key="${BASH_REMATCH[1]}"
    pair_value="${BASH_REMATCH[2]}"
    rest="${BASH_REMATCH[4]}"

    if [[ "${pair_key}" == "${key}" ]]; then
      pair_value="${pair_value//\\\"/\"}"
      pair_value="${pair_value//\\\\/\\}"
      printf '%s\n' "${pair_value}"
      return 0
    fi
  done

  return 1
}

hardware_reset_disk_inventory() {
  HARDWARE_DISK_INVENTORY_LOADED="no"
  HARDWARE_DISKS=()
  HARDWARE_DISK_SIZE=()
  HARDWARE_DISK_MODEL=()
  HARDWARE_DISK_SERIAL=()
  HARDWARE_DISK_TYPE=()
  HARDWARE_DISK_TRAN=()
  HARDWARE_DISK_RM=()
}

hardware_forbidden_disk_basename() {
  local disk="$1"
  local base

  base="$(basename -- "${disk}")"
  case "${base}" in
    loop*|sr*|md*|dm-*) return 0 ;;
    *) return 1 ;;
  esac
}

hardware_cache_disk_from_lsblk_line() {
  local line="$1"
  local name
  local size
  local model
  local serial
  local type
  local tran
  local rm

  [[ "${line}" == NAME=\"* ]] || return 0

  name="$(hardware_lsblk_pair_value "${line}" NAME || true)"
  size="$(hardware_lsblk_pair_value "${line}" SIZE || true)"
  model="$(hardware_lsblk_pair_value "${line}" MODEL || true)"
  serial="$(hardware_lsblk_pair_value "${line}" SERIAL || true)"
  type="$(hardware_lsblk_pair_value "${line}" TYPE || true)"
  tran="$(hardware_lsblk_pair_value "${line}" TRAN || true)"
  rm="$(hardware_lsblk_pair_value "${line}" RM || true)"

  [[ -n "${name}" ]] || return 0
  [[ "${type}" == "disk" ]] || return 0
  hardware_forbidden_disk_basename "${name}" && return 0

  HARDWARE_DISKS+=("${name}")
  HARDWARE_DISK_SIZE["${name}"]="${size:-unknown}"
  HARDWARE_DISK_MODEL["${name}"]="${model:-unknown}"
  HARDWARE_DISK_SERIAL["${name}"]="${serial:-unknown}"
  HARDWARE_DISK_TYPE["${name}"]="${type}"
  HARDWARE_DISK_TRAN["${name}"]="${tran:-unknown}"
  HARDWARE_DISK_RM["${name}"]="${rm:-0}"
}

hardware_load_disk_inventory() {
  local line

  [[ "${HARDWARE_DISK_INVENTORY_LOADED}" == "yes" ]] && return 0
  hardware_reset_disk_inventory

  if command_exists lsblk; then
    while IFS= read -r line; do
      hardware_cache_disk_from_lsblk_line "${line}"
    done < <(lsblk -P -dpno NAME,SIZE,MODEL,SERIAL,TYPE,TRAN,RM 2>/dev/null)
  fi

  HARDWARE_DISK_INVENTORY_LOADED="yes"
}

hardware_refresh_disk_inventory() {
  hardware_reset_disk_inventory
  hardware_load_disk_inventory
}

hardware_disk_in_loaded_inventory() {
  local disk="$1"
  local candidate

  for candidate in "${HARDWARE_DISKS[@]}"; do
    [[ "${candidate}" == "${disk}" ]] && return 0
  done

  return 1
}

hardware_disk_in_inventory() {
  local disk="$1"

  hardware_load_disk_inventory
  hardware_disk_in_loaded_inventory "${disk}"
}

hardware_disk_count() {
  hardware_load_disk_inventory
  printf '%s\n' "${#HARDWARE_DISKS[@]}"
}

hardware_disk_value() {
  local disk="$1"
  local field="$2"

  hardware_load_disk_inventory
  hardware_disk_in_loaded_inventory "${disk}" || return 1

  case "${field}" in
    size) printf '%s\n' "${HARDWARE_DISK_SIZE[$disk]}" ;;
    model) printf '%s\n' "${HARDWARE_DISK_MODEL[$disk]}" ;;
    serial) printf '%s\n' "${HARDWARE_DISK_SERIAL[$disk]}" ;;
    type) printf '%s\n' "${HARDWARE_DISK_TYPE[$disk]}" ;;
    tran) printf '%s\n' "${HARDWARE_DISK_TRAN[$disk]}" ;;
    rm) printf '%s\n' "${HARDWARE_DISK_RM[$disk]}" ;;
    *) die "Campo de disco no soportado: ${field}" ;;
  esac
}

hardware_validate_installable_disk() {
  local disk="$1"

  [[ -n "${disk}" ]] || die "No se selecciono ningun disco."
  validate_absolute_path "${disk}"
  [[ "${disk}" == /dev/* ]] || die "El disco debe estar bajo /dev: ${disk}"
  hardware_forbidden_disk_basename "${disk}" && die "Dispositivo no permitido para instalacion: ${disk}"
  [[ -b "${disk}" ]] || die "El dispositivo no existe o no es bloque: ${disk}"
  hardware_load_disk_inventory
  hardware_disk_in_loaded_inventory "${disk}" || die "El dispositivo no es un disco instalable TYPE=disk: ${disk}"
}

hardware_show_disk_inventory_table() {
  local disk
  local removable

  hardware_load_disk_inventory
  log_section "Discos instalables"
  printf '%-16s %-8s %-24s %-8s %-9s\n' "DEVICE" "SIZE" "MODEL" "TRAN" "REMOVABLE"
  printf '%s\n' "---------------------------------------------------------------------"

  for disk in "${HARDWARE_DISKS[@]}"; do
    removable="no"
    [[ "${HARDWARE_DISK_RM[$disk]}" == "1" ]] && removable="yes"
    printf '%-16s %-8s %-24.24s %-8s %-9s\n' \
      "${disk}" \
      "${HARDWARE_DISK_SIZE[$disk]}" \
      "${HARDWARE_DISK_MODEL[$disk]}" \
      "${HARDWARE_DISK_TRAN[$disk]}" \
      "${removable}"
  done
}

hardware_show_disk_details() {
  local disk="$1"
  local removable="no"

  hardware_validate_installable_disk "${disk}"
  [[ "${HARDWARE_DISK_RM[$disk]}" == "1" ]] && removable="yes"

  log_header "Detalle del disco"
  log_kv "Device" "${disk}"
  log_kv "Size" "${HARDWARE_DISK_SIZE[$disk]}"
  log_kv "Model" "${HARDWARE_DISK_MODEL[$disk]}"
  log_kv "Serial" "${HARDWARE_DISK_SERIAL[$disk]}"
  log_kv "Transport" "${HARDWARE_DISK_TRAN[$disk]}"
  log_kv "Removable" "${removable}"
}

hardware_warn_if_removable_disk() {
  local disk="$1"
  local tran
  local rm

  hardware_validate_installable_disk "${disk}"
  tran="${HARDWARE_DISK_TRAN[$disk]}"
  rm="${HARDWARE_DISK_RM[$disk]}"

  if [[ "${tran}" == "usb" || "${rm}" == "1" ]]; then
    log_warn "ADVERTENCIA MUY FUERTE: ${disk} parece ser USB/removible."
    log_warn "Podria ser el medio Live USB. Verifica fisicamente el dispositivo antes de continuar."
  fi
}

hardware_detect_live_iso_disk() {
  local target
  local source
  local parent
  local source_type

  for target in /run/archiso/bootmnt /run/archiso/cowspace; do
    [[ -e "${target}" ]] || continue
    source="$(findmnt -rn -o SOURCE --target "${target}" 2>/dev/null || true)"
    [[ "${source}" == /dev/* ]] || continue

    source_type="$(lsblk -dnpo TYPE "${source}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    if [[ "${source_type}" == "disk" ]]; then
      printf '%s\n' "${source}"
      return 0
    fi

    parent="$(lsblk -no PKNAME "${source}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    [[ -n "${parent}" ]] || continue
    printf '/dev/%s\n' "${parent}"
    return 0
  done

  return 1
}

hardware_warn_if_live_iso_disk() {
  local disk="$1"
  local live_disk

  live_disk="$(hardware_detect_live_iso_disk || true)"
  [[ -n "${live_disk}" ]] || return 0

  if [[ "$(realpath -m -- "${disk}")" == "$(realpath -m -- "${live_disk}")" ]]; then
    log_warn "ADVERTENCIA CRITICA: ${disk} parece contener el Arch Live ISO actualmente en uso."
    log_warn "Seleccionar este disco podria destruir el medio desde el que arrancaste."
  fi
}

hardware_warn_if_disk_has_mounts() {
  local disk="$1"
  local entry
  local mounted_entries=()

  while IFS= read -r entry; do
    [[ -n "${entry}" ]] && mounted_entries+=("${entry}")
  done < <(
    while IFS= read -r entry; do
      [[ -n "${entry}" ]] || continue
      findmnt -rn --source "${entry}" -o SOURCE,TARGET,FSTYPE 2>/dev/null || true
    done < <(lsblk -nrpo NAME "${disk}" 2>/dev/null)
  )

  ((${#mounted_entries[@]} == 0)) && return 0

  log_warn "ADVERTENCIA: el disco seleccionado contiene particiones montadas:"
  for entry in "${mounted_entries[@]}"; do
    log_warn "  ${entry}"
  done
}

list_available_disks() {
  local disk
  local warning

  hardware_load_disk_inventory
  for disk in "${HARDWARE_DISKS[@]}"; do
    warning=""
    if [[ "${HARDWARE_DISK_TRAN[$disk]}" == "usb" || "${HARDWARE_DISK_RM[$disk]}" == "1" ]]; then
      warning="  [PELIGRO: USB/REMOVIBLE]"
    fi

    printf '%s %s %s %s %s %s %s%s\n' \
      "${disk}" "${HARDWARE_DISK_SIZE[$disk]}" "${HARDWARE_DISK_MODEL[$disk]}" \
      "${HARDWARE_DISK_SERIAL[$disk]}" "${HARDWARE_DISK_TYPE[$disk]}" \
      "${HARDWARE_DISK_TRAN[$disk]}" "${HARDWARE_DISK_RM[$disk]}" "${warning}"
  done
}

is_removable_disk() {
  local disk="$1"
  local removable
  local tran
  local sys_name

  [[ -b "${disk}" ]] || return 1

  if hardware_disk_in_inventory "${disk}"; then
    [[ "${HARDWARE_DISK_RM[$disk]}" == "1" || "${HARDWARE_DISK_TRAN[$disk]}" == "usb" ]] && return 0
  fi

  if command_exists lsblk; then
    removable="$(lsblk -dpno RM "${disk}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    tran="$(lsblk -dpno TRAN "${disk}" 2>/dev/null | awk 'NR == 1 { print $1 }')"

    [[ "${removable}" == "1" || "${tran}" == "usb" ]] && return 0
  fi

  sys_name="$(basename -- "${disk}")"
  if [[ -r "/sys/block/${sys_name}/removable" ]]; then
    [[ "$(cat "/sys/block/${sys_name}/removable")" == "1" ]] && return 0
  fi

  return 1
}

warn_if_removable_disk() {
  local disk="$1"

  if is_removable_disk "${disk}"; then
    log_warn "ADVERTENCIA FUERTE: ${disk} parece ser USB/removible."
    log_warn "No se aborta automaticamente, pero los scripts destructivos deben exigir confirmacion exacta."
  fi
}

count_available_disks() {
  hardware_disk_count
}

detect_network_available() {
  local has_route

  has_route="no"
  if command_exists ip; then
    if ip route get 1.1.1.1 >/dev/null 2>&1; then
      has_route="yes"
    fi
  fi

  [[ "${has_route}" == "yes" ]] || return 1

  if command_exists getent; then
    getent hosts archlinux.org >/dev/null 2>&1 && return 0
  fi

  if command_exists ping; then
    ping -c 1 -W 3 archlinux.org >/dev/null 2>&1 && return 0
  fi

  log_warn "Hay ruta de red, pero no se pudo resolver o contactar archlinux.org. Puede haber DNS o ICMP bloqueado."
  return 1
}

detect_network_status() {
  if detect_network_available; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

detect_memory_kib() {
  awk '/MemTotal/ { print $2; exit }' /proc/meminfo 2>/dev/null || printf '0\n'
}

detect_memory_mib() {
  local kib

  kib="$(detect_memory_kib)"
  printf '%s\n' "$((kib / 1024))"
}

detect_memory_human() {
  local mib

  mib="$(detect_memory_mib)"
  if [[ "${mib}" -ge 1024 ]]; then
    awk -v mib="${mib}" 'BEGIN { printf "%.1f GiB\n", mib / 1024 }'
  else
    printf '%s MiB\n' "${mib}"
  fi
}

show_disk_summary() {
  log_header "Discos disponibles"
  if [[ "$(count_available_disks)" -eq 0 ]]; then
    log_warn "No se detectaron discos instalables."
    return 0
  fi

  hardware_show_disk_inventory_table
}

show_hardware_summary() {
  log_section "Resumen de hardware"
  log_kv "UEFI" "$(detect_uefi)"
  log_kv "Secure Boot" "$(detect_secure_boot)"
  log_kv "CPU vendor" "$(detect_cpu_vendor)"
  log_kv "CPU model" "$(detect_cpu_model)"
  log_kv "Microcode" "$(detect_microcode_package)"
  log_kv "Virtualizacion CPU" "$(detect_cpu_virtualization)"
  log_kv "GPU NVIDIA" "$(detect_nvidia_gpu && printf 'yes' || printf 'no')"
  log_kv "Modelo NVIDIA" "$(detect_nvidia_gpu_model | paste -sd ';' -)"
  log_kv "GPU AMD" "$(detect_amd_gpu && printf 'yes' || printf 'no')"
  log_kv "Modelo AMD" "$(detect_amd_gpu_model | paste -sd ';' -)"
  log_kv "TPM 2.0" "$(detect_tpm2_status)"
  log_kv "Red disponible" "$(detect_network_status)"
  log_kv "RAM" "$(detect_memory_human)"
  show_disk_summary
}

validate_minimum_memory() {
  local minimum_mib="${1:-4096}"
  local current_mib

  current_mib="$(detect_memory_mib)"
  [[ "${current_mib}" -ge "${minimum_mib}" ]] || \
    die "RAM insuficiente: ${current_mib} MiB detectados, minimo requerido ${minimum_mib} MiB."
}

validate_install_hardware() {
  local disk_count

  is_uefi_booted || die "El equipo debe arrancar el ISO en modo UEFI."

  disk_count="$(count_available_disks)"
  [[ "${disk_count}" -gt 0 ]] || die "No se detectaron discos disponibles."

  if [[ -n "${TARGET_DISK:-}" ]]; then
    [[ -b "${TARGET_DISK}" ]] || die "TARGET_DISK no existe o no es un dispositivo de bloque: ${TARGET_DISK}"
    warn_if_removable_disk "${TARGET_DISK}"
  fi

  validate_minimum_memory 4096

  if ! cpu_virtualization_available; then
    log_warn "No se detecto Intel VT-x ni AMD-V. La virtualizacion KVM puede no funcionar."
  fi

  if ! detect_network_available; then
    log_warn "No se detecto red activa. La instalacion necesitara red para pacstrap y paquetes."
  fi

  success "Validacion de hardware completada."
}
