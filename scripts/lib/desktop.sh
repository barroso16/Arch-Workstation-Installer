#!/usr/bin/env bash
# Desktop environment helpers for the Arch workstation installer.
#
# This library configures optional graphical environments inside the installed
# target. It never installs packages and never touches storage, bootloader, or
# Secure Boot state.

set -euo pipefail

DESKTOP_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F die >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "${DESKTOP_LIB_DIR}/common.sh"
fi

if ! declare -F log_section >/dev/null 2>&1; then
  # shellcheck source=logging.sh
  source "${DESKTOP_LIB_DIR}/logging.sh"
fi

if ! declare -F validate_install_config >/dev/null 2>&1; then
  # shellcheck source=config.sh
  source "${DESKTOP_LIB_DIR}/config.sh"
fi

if ! declare -F arch_chroot_run >/dev/null 2>&1; then
  # shellcheck source=chroot.sh
  source "${DESKTOP_LIB_DIR}/chroot.sh"
fi

if ! declare -F detect_nvidia_gpu >/dev/null 2>&1; then
  # shellcheck source=hardware.sh
  source "${DESKTOP_LIB_DIR}/hardware.sh"
fi

DESKTOP_WALLPAPER_PATH="/usr/share/backgrounds/arch-workstation/default-wallpaper.png"
HYPRLAND_START_WRAPPER="/usr/local/bin/arch-workstation-start-hyprland"
HYPRLAND_SESSION_FILE="/usr/share/wayland-sessions/arch-workstation-hyprland.desktop"
HYPRLAND_SDDM_CONFIG="/etc/sddm.conf.d/10-arch-workstation.conf"

desktop_env_is_hyprland() {
  [[ "${INSTALL_DESKTOP_ENV:-none}" == "hyprland" ]]
}

target_user_home_dir() {
  local target_root="$1"
  local username="$2"
  local home_dir

  validate_username_value "${username}"
  home_dir="$(arch_chroot_capture "${target_root}" getent passwd "${username}" | awk -F: '{ print $6; exit }')"
  [[ -n "${home_dir}" ]] || die "No se pudo detectar el home de ${username}."
  validate_absolute_path "${home_dir}"
  printf '%s\n' "${home_dir}"
}

write_user_config_file() {
  local target_root="$1"
  local username="$2"
  local destination="$3"

  validate_username_value "${username}"
  validate_absolute_path "${destination}"
  write_target_file "${target_root}" "${destination}"
  arch_chroot_run "${target_root}" chown "${username}:${username}" "${destination}"
  arch_chroot_run "${target_root}" chmod 0644 "${destination}"
}

create_hyprland_user_directories() {
  local target_root="$1"
  local username="$2"
  local home_dir="$3"

  arch_chroot_run "${target_root}" install -d -m 0755 -o "${username}" -g "${username}" \
    "${home_dir}/.config/hypr" \
    "${home_dir}/.config/waybar" \
    "${home_dir}/.config/mako"
}

create_hyprland_system_directories() {
  local target_root="$1"

  arch_chroot_run "${target_root}" install -d -m 0755 \
    /usr/local/bin \
    /usr/share/backgrounds/arch-workstation \
    /usr/share/wayland-sessions \
    /etc/sddm.conf.d
}

write_default_hyprland_wallpaper() {
  local target_root="$1"
  local encoded_path="${DESKTOP_WALLPAPER_PATH}.b64"

  write_target_file "${target_root}" "${encoded_path}" <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAB+0lEQVR42g3PAbKjMAgAUK/gZDLZ/DSliIiISNP+3fsfbX03eNOc/qRUc/opqdX0aKn39IQEmF6UkNMiiTStltjTFkmmOdeUf3JuJT9q7i0/ewbIL8xIeeFMklfNbHnzLJH3aS4/qbRcHqX0Wp6tQC8vKIhloUJcVimsZbMiXvYoOs21pfrItZf6rBVaffWKUBesRHXlylI3rWJ196pRj2luj9R6bs/SoLZXa9jbAo2wrdSY2yZNtO3W1NsRzab5TvZn7lD6q3ZsfemdoK/YmfrGXaTv2tX64d2in9MMz3Qn4VUAKywNqMMKwAgbgTDsAqpwGJjDGeDTjJDwle8kLhWp4dqRATdEIdwZVfBQNMPT0QOvaaZXIsy0lDtJayPutAEJ0k6kTIeQKZ1G7nQFxTQzJl4yU+G13kneOgvwjqzEB7MJn8pufDlH8HuaZUlCWdYiXGVrd1J2EEU5SIzlFHGVyyRc3iFjmpWSrlm56FZVmu79TuqBaqQnq4teqmH6dh2hn2m2NRln24pJtb2ZdjvgTtpJ5myXWKi9zYbbJ+w7zc7Jt+xSfK+uzY/uBn7infSLPcTf6sP84/4N/53m2FJIjr2E1jhaWI8TwjEuupPxlhgaH4uvx2/E32keksaeh5Zx1GFtnH04jAtH0HjzGDI+Or42fn38jfHvP9mtaQEpEs83AAAAAElFTkSuQmCC
EOF

  arch_chroot_run "${target_root}" /usr/bin/env bash -euo pipefail -c '
encoded_path="$1"
wallpaper_path="$2"
tmp="${wallpaper_path}.tmp.$$"
trap '\''rm -f -- "${tmp}"'\'' EXIT
base64 -d -- "${encoded_path}" > "${tmp}"
chmod 0644 "${tmp}"
mv -f -- "${tmp}" "${wallpaper_path}"
trap - EXIT
rm -f -- "${encoded_path}"
' _ "${encoded_path}" "${DESKTOP_WALLPAPER_PATH}"
}

write_hyprland_config() {
  local target_root="$1"
  local username="$2"
  local home_dir="$3"

  write_user_config_file "${target_root}" "${username}" "${home_dir}/.config/hypr/hyprland.conf" <<'EOF'
# Arch Workstation Installer - Hyprland keyboard-first defaults.

$mod = SUPER
$terminal = kitty
$launcher = wofi --show drun

monitor = ,preferred,auto,1

env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = GDK_BACKEND,wayland,x11
env = QT_QPA_PLATFORM,wayland;xcb
env = SDL_VIDEODRIVER,wayland
env = CLUTTER_BACKEND,wayland
env = MOZ_ENABLE_WAYLAND,1
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE
exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE
exec-once = hyprpaper
exec-once = waybar
exec-once = mako
exec-once = nm-applet --indicator
exec-once = /usr/lib/polkit-kde-authentication-agent-1

input {
  kb_layout = us
  follow_mouse = 1
  touchpad {
    natural_scroll = true
  }
}

general {
  gaps_in = 4
  gaps_out = 8
  border_size = 2
  layout = dwindle
}

decoration {
  rounding = 4
}

misc {
  disable_hyprland_logo = true
  disable_splash_rendering = true
}

bind = $mod, Return, exec, $terminal
bind = $mod, D, exec, $launcher
bind = $mod, SPACE, exec, $launcher
bind = $mod, Q, killactive
bind = $mod, H, movefocus, l
bind = $mod, J, movefocus, d
bind = $mod, K, movefocus, u
bind = $mod, L, movefocus, r
bind = $mod SHIFT, H, movewindow, l
bind = $mod SHIFT, J, movewindow, d
bind = $mod SHIFT, K, movewindow, u
bind = $mod SHIFT, L, movewindow, r
bind = $mod, V, togglefloating
bind = $mod, F, fullscreen
bind = $mod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy
bind = $mod CTRL, L, exec, hyprlock
bind = $mod SHIFT, F, exec, nautilus
bind = $mod SHIFT, B, exec, firefox
bind = $mod SHIFT, E, exit

bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5
bind = $mod, 6, workspace, 6
bind = $mod, 7, workspace, 7
bind = $mod, 8, workspace, 8
bind = $mod, 9, workspace, 9

bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bind = $mod SHIFT, 4, movetoworkspace, 4
bind = $mod SHIFT, 5, movetoworkspace, 5
bind = $mod SHIFT, 6, movetoworkspace, 6
bind = $mod SHIFT, 7, movetoworkspace, 7
bind = $mod SHIFT, 8, movetoworkspace, 8
bind = $mod SHIFT, 9, movetoworkspace, 9
EOF

  if is_yes "${INSTALL_NVIDIA_IF_DETECTED:-yes}" && detect_nvidia_gpu; then
    write_target_file "${target_root}" "${home_dir}/.config/hypr/arch-workstation-nvidia.conf" <<'EOF'
# NVIDIA/Hyprland compatibility layer generated only when NVIDIA hardware is detected.
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = ELECTRON_OZONE_PLATFORM_HINT,auto
env = NVD_BACKEND,direct
EOF
    arch_chroot_run "${target_root}" chown "${username}:${username}" "${home_dir}/.config/hypr/arch-workstation-nvidia.conf"
    arch_chroot_run "${target_root}" chmod 0644 "${home_dir}/.config/hypr/arch-workstation-nvidia.conf"
    printf '%s\n' "source = ${home_dir}/.config/hypr/arch-workstation-nvidia.conf" >> "$(target_path "${target_root}" "${home_dir}/.config/hypr/hyprland.conf")"
  fi
}

write_hyprpaper_config() {
  local target_root="$1"
  local username="$2"
  local home_dir="$3"

  write_user_config_file "${target_root}" "${username}" "${home_dir}/.config/hypr/hyprpaper.conf" <<EOF
preload = ${DESKTOP_WALLPAPER_PATH}
wallpaper = ,${DESKTOP_WALLPAPER_PATH}
splash = false
EOF
}

write_waybar_config() {
  local target_root="$1"
  local username="$2"
  local home_dir="$3"

  write_user_config_file "${target_root}" "${username}" "${home_dir}/.config/waybar/config" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "height": 28,
  "modules-left": ["hyprland/workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["network", "pulseaudio", "battery", "tray"],
  "hyprland/workspaces": {
    "disable-scroll": true,
    "all-outputs": true
  },
  "clock": {
    "format": "{:%Y-%m-%d %H:%M}"
  },
  "network": {
    "format-wifi": "{essid} {signalStrength}%",
    "format-ethernet": "wired",
    "format-disconnected": "offline"
  },
  "pulseaudio": {
    "format": "vol {volume}%"
  },
  "battery": {
    "format": "bat {capacity}%"
  }
}
EOF
}

write_waybar_style() {
  local target_root="$1"
  local username="$2"
  local home_dir="$3"

  write_user_config_file "${target_root}" "${username}" "${home_dir}/.config/waybar/style.css" <<'EOF'
* {
  border: none;
  font-family: "DejaVu Sans", "Noto Sans", sans-serif;
  font-size: 12px;
  min-height: 0;
}

window#waybar {
  background: #111318;
  color: #e6e6e6;
}

#workspaces button {
  color: #c8d0e0;
  padding: 0 8px;
}

#workspaces button.active {
  background: #2f6f9f;
  color: #ffffff;
}

#clock,
#network,
#pulseaudio,
#battery,
#tray {
  padding: 0 10px;
}
EOF
}

write_mako_config() {
  local target_root="$1"
  local username="$2"
  local home_dir="$3"

  write_user_config_file "${target_root}" "${username}" "${home_dir}/.config/mako/config" <<'EOF'
font=DejaVu Sans 10
background-color=#111318
text-color=#e6e6e6
border-color=#2f6f9f
border-size=2
border-radius=4
default-timeout=6000
EOF
}

write_hyprland_start_wrapper() {
  local target_root="$1"

  write_target_file "${target_root}" "${HYPRLAND_START_WRAPPER}" <<'EOF'
#!/usr/bin/env bash
# Start Hyprland as the graphical engine, with a VM-only software fallback.

set -euo pipefail

is_virtualized_guest() {
  local value

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    value="$(systemd-detect-virt --vm 2>/dev/null || true)"
    [[ -n "${value}" && "${value}" != "none" ]] && return 0
  fi

  if [[ -r /sys/class/dmi/id/product_name ]]; then
    value="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    [[ "${value}" == *VMware* ]] && return 0
  fi

  if [[ -r /sys/class/dmi/id/sys_vendor ]]; then
    value="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
    [[ "${value}" == *VMware* ]] && return 0
  fi

  if command -v dmidecode >/dev/null 2>&1; then
    value="$(dmidecode -s system-product-name 2>/dev/null || true)"
    [[ "${value}" == *VMware* ]] && return 0
    value="$(dmidecode -s system-manufacturer 2>/dev/null || true)"
    [[ "${value}" == *VMware* ]] && return 0
  fi

  return 1
}

if is_virtualized_guest; then
  export WLR_RENDERER_ALLOW_SOFTWARE=1
  export LIBGL_ALWAYS_SOFTWARE=1
fi

export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-Hyprland}"
export XDG_SESSION_DESKTOP="${XDG_SESSION_DESKTOP:-Hyprland}"
export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-wayland}"
export GDK_BACKEND="${GDK_BACKEND:-wayland,x11}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland}"
export CLUTTER_BACKEND="${CLUTTER_BACKEND:-wayland}"
export MOZ_ENABLE_WAYLAND="${MOZ_ENABLE_WAYLAND:-1}"
export ELECTRON_OZONE_PLATFORM_HINT="${ELECTRON_OZONE_PLATFORM_HINT:-auto}"

if command -v nvidia-smi >/dev/null 2>&1 || [[ -d /proc/driver/nvidia/gpus ]]; then
  export LIBVA_DRIVER_NAME="${LIBVA_DRIVER_NAME:-nvidia}"
  export __GLX_VENDOR_LIBRARY_NAME="${__GLX_VENDOR_LIBRARY_NAME:-nvidia}"
  export NVD_BACKEND="${NVD_BACKEND:-direct}"
fi

if command -v start-hyprland >/dev/null 2>&1; then
  exec start-hyprland
fi

if command -v Hyprland >/dev/null 2>&1; then
  exec Hyprland
fi

if command -v hyprland >/dev/null 2>&1; then
  exec hyprland
fi

printf '%s\n' "No se encontro start-hyprland, Hyprland ni hyprland en PATH." >&2
exit 127
EOF
  arch_chroot_run "${target_root}" chmod 0755 "${HYPRLAND_START_WRAPPER}"
}

write_hyprland_session_file() {
  local target_root="$1"

  write_target_file "${target_root}" "${HYPRLAND_SESSION_FILE}" <<EOF
[Desktop Entry]
Name=Arch Workstation Hyprland
Comment=Keyboard-first Hyprland session with VM fallback
Exec=${HYPRLAND_START_WRAPPER}
Type=Application
DesktopNames=Hyprland
EOF
  arch_chroot_run "${target_root}" chmod 0644 "${HYPRLAND_SESSION_FILE}"
}

write_hyprland_sddm_config() {
  local target_root="$1"
  local username="$2"

  validate_username_value "${username}"
  write_target_file "${target_root}" "${HYPRLAND_SDDM_CONFIG}" <<EOF
[Autologin]
User=${username}
Session=arch-workstation-hyprland.desktop
EOF
  arch_chroot_run "${target_root}" chmod 0644 "${HYPRLAND_SDDM_CONFIG}"
}

configure_hyprland_desktop() {
  local target_root="$1"
  local username="$2"
  local home_dir

  validate_arch_target_root "${target_root}"
  validate_username_value "${username}"
  arch_chroot_run "${target_root}" id -u "${username}" >/dev/null

  home_dir="$(target_user_home_dir "${target_root}" "${username}")"

  log_section "Hyprland"
  log_kv "Usuario" "${username}"
  log_kv "Home" "${home_dir}"

  create_hyprland_system_directories "${target_root}"
  write_default_hyprland_wallpaper "${target_root}"
  create_hyprland_user_directories "${target_root}" "${username}" "${home_dir}"
  write_hyprland_config "${target_root}" "${username}" "${home_dir}"
  write_hyprpaper_config "${target_root}" "${username}" "${home_dir}"
  write_waybar_config "${target_root}" "${username}" "${home_dir}"
  write_waybar_style "${target_root}" "${username}" "${home_dir}"
  write_mako_config "${target_root}" "${username}" "${home_dir}"
  write_hyprland_start_wrapper "${target_root}"
  write_hyprland_session_file "${target_root}"
  write_hyprland_sddm_config "${target_root}" "${username}"

  success "Configuracion inicial de Hyprland creada para ${username}."
}

configure_desktop_environment() {
  local target_root="$1"
  local username="$2"

  ensure_install_config_loaded

  case "${INSTALL_DESKTOP_ENV:-none}" in
    none)
      log_info "INSTALL_DESKTOP_ENV=none; se omite configuracion grafica."
      ;;
    hyprland)
      configure_hyprland_desktop "${target_root}" "${username}"
      ;;
    *)
      die "INSTALL_DESKTOP_ENV no soportado: ${INSTALL_DESKTOP_ENV}"
      ;;
  esac
}
