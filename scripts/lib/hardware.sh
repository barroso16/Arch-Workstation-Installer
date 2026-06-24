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

list_available_disks() {
  local line
  local NAME
  local SIZE
  local MODEL
  local SERIAL
  local TYPE
  local TRAN
  local RM
  local warning

  if command_exists lsblk; then
    while IFS= read -r line; do
      NAME=""
      SIZE=""
      MODEL=""
      SERIAL=""
      TYPE=""
      TRAN=""
      RM=""
      warning=""

      [[ "${line}" == NAME=\"* ]] || continue

      eval "${line}"

      [[ "${TYPE}" == "disk" ]] || continue

      if [[ "${TRAN}" == "usb" || "${RM}" == "1" ]]; then
        warning="  [PELIGRO: USB/REMOVIBLE]"
      fi

      printf '%s %s %s %s %s %s %s%s\n' \
        "${NAME}" "${SIZE}" "${MODEL:-unknown}" "${SERIAL:-unknown}" \
        "${TYPE}" "${TRAN:-unknown}" "${RM:-0}" "${warning}"
    done < <(lsblk -P -dpno NAME,SIZE,MODEL,SERIAL,TYPE,TRAN,RM 2>/dev/null)
  else
    find /dev -maxdepth 1 -type b \( -name 'sd*' -o -name 'nvme*n*' -o -name 'vd*' \) -print 2>/dev/null
  fi
}

is_removable_disk() {
  local disk="$1"
  local removable
  local tran
  local sys_name

  [[ -b "${disk}" ]] || return 1

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
  list_available_disks | awk 'NF { count++ } END { print count + 0 }'
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

  list_available_disks
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
