#!/usr/bin/env bash
# Redteam-safe Omarchy-inspired customization for Arch Workstation.
#
# This script recreates the local look-and-feel ideas from Omarchy from scratch:
# palettes, Hyprland, Waybar, Mako, Kitty, Starship, btop, Fastfetch, Hyprlock,
# Walker/Wofi styling, and a small local menu.
#
# It intentionally does not install Omarchy, does not clone Omarchy, does not
# add Omarchy repositories, does not run AUR helpers, and does not download
# anything. It writes local configuration only.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=lib/config.sh
source "${LIB_DIR}/config.sh"
# shellcheck source=lib/chroot.sh
source "${LIB_DIR}/chroot.sh"

TARGET_ROOT="${TARGET_ROOT:-/mnt}"
CUSTOM_USER=""
THEME_NAME=""
ASSUME_YES="no"
LIST_ONLY="no"
PREVIEW_ONLY="no"

THEMES=(
  catppuccin
  catppuccin-latte
  ethereal
  everforest
  flexoki-light
  gruvbox
  hackerman
  kanagawa
  last-horizon
  lumon
  matte-black
  miasma
  nord
  osaka-jade
  retro-82
  ristretto
  rose-pine
  solitude
  tokyo-night
  vantablack
  white
)
AVAILABLE_THEMES=()

usage() {
  cat <<'EOF'
Uso:
  bash scripts/omarchy-redteam-customize.sh
  bash scripts/omarchy-redteam-customize.sh --theme tokyo-night --yes

Opciones:
  --target-root PATH   Sistema Arch objetivo. Default: /mnt
  --user USER          Usuario a personalizar. Default: USERNAME de install.conf
  --theme NAME         Tema a aplicar. Si se omite, se muestra un selector.
  --list              Lista temas disponibles y sale
  --preview           Genera imagenes SVG de los temas y sale
  --yes               No pide confirmacion
  -h, --help          Muestra esta ayuda

Garantias de alcance:
  - No instala paquetes.
  - No modifica pacman.conf, mirrorlist, AUR, repositorios ni servicios.
  - No descarga, clona ni ejecuta codigo externo.
  - No crea webapps ni accesos a servicios de terceros.
  - No habilita clipboard history, weather remoto, update checks ni telemetry.
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --target-root)
        shift
        TARGET_ROOT="${1:-}"
        ;;
      --user)
        shift
        CUSTOM_USER="${1:-}"
        ;;
      --theme)
        shift
        THEME_NAME="${1:-}"
        ;;
      --list)
        LIST_ONLY="yes"
        ;;
      --preview)
        PREVIEW_ONLY="yes"
        ;;
      --yes)
        ASSUME_YES="yes"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Opcion no soportada: $1"
        ;;
    esac
    shift
  done
}

contains_value() {
  local needle="$1"
  shift
  local value

  for value in "$@"; do
    [[ "${value}" == "${needle}" ]] && return 0
  done

  return 1
}

target_is_current_system() {
  [[ "$(realpath -m -- "${TARGET_ROOT}")" == "/" ]]
}

target_run() {
  if target_is_current_system; then
    "$@"
  else
    arch_chroot_run "${TARGET_ROOT}" "$@"
  fi
}

target_capture() {
  if target_is_current_system; then
    "$@" 2>&1
  else
    arch_chroot_capture "${TARGET_ROOT}" "$@"
  fi
}

target_to_host_path() {
  local target_path_abs="$1"

  validate_absolute_path "${target_path_abs}"
  if target_is_current_system; then
    printf '%s\n' "${target_path_abs}"
  else
    printf '%s%s\n' "${TARGET_ROOT%/}" "${target_path_abs}"
  fi
}

target_user_home() {
  local username="$1"
  local home_dir

  validate_username_value "${username}"
  home_dir="$(target_capture getent passwd "${username}" | awk -F: '{ print $6; exit }')"
  [[ -n "${home_dir}" ]] || die "No se pudo detectar el home de ${username}."
  validate_absolute_path "${home_dir}"
  printf '%s\n' "${home_dir}"
}

ensure_target_dir() {
  local target_path_abs="$1"
  local owner="${2:-}"
  local host_path_abs

  validate_absolute_path "${target_path_abs}"
  host_path_abs="$(target_to_host_path "${target_path_abs}")"
  install -d -m 0755 "${host_path_abs}"

  if [[ -n "${owner}" ]]; then
    target_run chown "${owner}:${owner}" "${target_path_abs}"
  fi
}

write_target_config() {
  local target_path_abs="$1"
  local owner="$2"
  local mode="${3:-0644}"
  local host_path_abs

  validate_absolute_path "${target_path_abs}"
  host_path_abs="$(target_to_host_path "${target_path_abs}")"
  install -d -m 0755 "$(dirname -- "${host_path_abs}")"
  write_file_atomic "${host_path_abs}"
  target_run chmod "${mode}" "${target_path_abs}"

  if [[ -n "${owner}" ]]; then
    target_run chown "${owner}:${owner}" "${target_path_abs}"
  fi
}

append_line_once() {
  local target_path_abs="$1"
  local owner="$2"
  local line="$3"
  local host_path_abs

  validate_absolute_path "${target_path_abs}"
  host_path_abs="$(target_to_host_path "${target_path_abs}")"
  install -d -m 0755 "$(dirname -- "${host_path_abs}")"
  append_line_if_missing "${host_path_abs}" "${line}"
  target_run chmod 0644 "${target_path_abs}"

  if [[ -n "${owner}" ]]; then
    target_run chown "${owner}:${owner}" "${target_path_abs}"
  fi
}

theme_values() {
  case "$1" in
    catppuccin)
      PALETTE_ACCENT="89b4fa"; PALETTE_FG="cdd6f4"; PALETTE_BG="1e1e2e"; PALETTE_SELECTION="f5e0dc"
      PALETTE_RED="f38ba8"; PALETTE_GREEN="a6e3a1"; PALETTE_YELLOW="f9e2af"; PALETTE_BLUE="89b4fa"; PALETTE_MAGENTA="f5c2e7"; PALETTE_CYAN="94e2d5"
      LIGHT_MODE="no"
      ;;
    catppuccin-latte)
      PALETTE_ACCENT="1e66f5"; PALETTE_FG="4c4f69"; PALETTE_BG="eff1f5"; PALETTE_SELECTION="dc8a78"
      PALETTE_RED="d20f39"; PALETTE_GREEN="40a02b"; PALETTE_YELLOW="df8e1d"; PALETTE_BLUE="1e66f5"; PALETTE_MAGENTA="ea76cb"; PALETTE_CYAN="179299"
      LIGHT_MODE="yes"
      ;;
    ethereal)
      PALETTE_ACCENT="7d82d9"; PALETTE_FG="ffcead"; PALETTE_BG="060B1E"; PALETTE_SELECTION="ffcead"
      PALETTE_RED="ED5B5A"; PALETTE_GREEN="92a593"; PALETTE_YELLOW="E9BB4F"; PALETTE_BLUE="7d82d9"; PALETTE_MAGENTA="c89dc1"; PALETTE_CYAN="a3bfd1"
      LIGHT_MODE="no"
      ;;
    everforest)
      PALETTE_ACCENT="7fbbb3"; PALETTE_FG="d3c6aa"; PALETTE_BG="2d353b"; PALETTE_SELECTION="d3c6aa"
      PALETTE_RED="e67e80"; PALETTE_GREEN="a7c080"; PALETTE_YELLOW="dbbc7f"; PALETTE_BLUE="7fbbb3"; PALETTE_MAGENTA="d699b6"; PALETTE_CYAN="83c092"
      LIGHT_MODE="no"
      ;;
    flexoki-light)
      PALETTE_ACCENT="205EA6"; PALETTE_FG="100F0F"; PALETTE_BG="FFFCF0"; PALETTE_SELECTION="CECDC3"
      PALETTE_RED="D14D41"; PALETTE_GREEN="879A39"; PALETTE_YELLOW="D0A215"; PALETTE_BLUE="205EA6"; PALETTE_MAGENTA="CE5D97"; PALETTE_CYAN="3AA99F"
      LIGHT_MODE="yes"
      ;;
    gruvbox)
      PALETTE_ACCENT="7daea3"; PALETTE_FG="d4be98"; PALETTE_BG="282828"; PALETTE_SELECTION="d65d0e"
      PALETTE_RED="ea6962"; PALETTE_GREEN="a9b665"; PALETTE_YELLOW="d8a657"; PALETTE_BLUE="7daea3"; PALETTE_MAGENTA="d3869b"; PALETTE_CYAN="89b482"
      LIGHT_MODE="no"
      ;;
    hackerman)
      PALETTE_ACCENT="82FB9C"; PALETTE_FG="ddf7ff"; PALETTE_BG="0B0C16"; PALETTE_SELECTION="ddf7ff"
      PALETTE_RED="50f872"; PALETTE_GREEN="4fe88f"; PALETTE_YELLOW="50f7d4"; PALETTE_BLUE="829dd4"; PALETTE_MAGENTA="86a7df"; PALETTE_CYAN="7cf8f7"
      LIGHT_MODE="no"
      ;;
    kanagawa)
      PALETTE_ACCENT="7e9cd8"; PALETTE_FG="dcd7ba"; PALETTE_BG="1f1f28"; PALETTE_SELECTION="2d4f67"
      PALETTE_RED="c34043"; PALETTE_GREEN="76946a"; PALETTE_YELLOW="c0a36e"; PALETTE_BLUE="7e9cd8"; PALETTE_MAGENTA="957fb8"; PALETTE_CYAN="6a9589"
      LIGHT_MODE="no"
      ;;
    last-horizon)
      PALETTE_ACCENT="b59790"; PALETTE_FG="FAFCFB"; PALETTE_BG="0c0b0c"; PALETTE_SELECTION="FAFCFB"
      PALETTE_RED="c38b7b"; PALETTE_GREEN="87a9b0"; PALETTE_YELLOW="6B5E73"; PALETTE_BLUE="b59790"; PALETTE_MAGENTA="c4d8e2"; PALETTE_CYAN="a5a0b6"
      LIGHT_MODE="no"
      ;;
    lumon)
      PALETTE_ACCENT="8bc9eb"; PALETTE_FG="d6e2ee"; PALETTE_BG="16242d"; PALETTE_SELECTION="4d9ed3"
      PALETTE_RED="4d86b0"; PALETTE_GREEN="5e95bc"; PALETTE_YELLOW="6fa4c9"; PALETTE_BLUE="6fb8e3"; PALETTE_MAGENTA="8bc9eb"; PALETTE_CYAN="b4e4f6"
      LIGHT_MODE="no"
      ;;
    matte-black)
      PALETTE_ACCENT="e68e0d"; PALETTE_FG="bebebe"; PALETTE_BG="121212"; PALETTE_SELECTION="515151"
      PALETTE_RED="D35F5F"; PALETTE_GREEN="FFC107"; PALETTE_YELLOW="b91c1c"; PALETTE_BLUE="e68e0d"; PALETTE_MAGENTA="D35F5F"; PALETTE_CYAN="bebebe"
      LIGHT_MODE="no"
      ;;
    miasma)
      PALETTE_ACCENT="78824b"; PALETTE_FG="c2c2b0"; PALETTE_BG="222222"; PALETTE_SELECTION="78824b"
      PALETTE_RED="685742"; PALETTE_GREEN="5f875f"; PALETTE_YELLOW="b36d43"; PALETTE_BLUE="78824b"; PALETTE_MAGENTA="bb7744"; PALETTE_CYAN="c9a554"
      LIGHT_MODE="no"
      ;;
    nord)
      PALETTE_ACCENT="81a1c1"; PALETTE_FG="d8dee9"; PALETTE_BG="2e3440"; PALETTE_SELECTION="4c566a"
      PALETTE_RED="bf616a"; PALETTE_GREEN="a3be8c"; PALETTE_YELLOW="ebcb8b"; PALETTE_BLUE="81a1c1"; PALETTE_MAGENTA="b48ead"; PALETTE_CYAN="88c0d0"
      LIGHT_MODE="no"
      ;;
    osaka-jade)
      PALETTE_ACCENT="509475"; PALETTE_FG="C1C497"; PALETTE_BG="111c18"; PALETTE_SELECTION="C1C497"
      PALETTE_RED="FF5345"; PALETTE_GREEN="549e6a"; PALETTE_YELLOW="459451"; PALETTE_BLUE="509475"; PALETTE_MAGENTA="D2689C"; PALETTE_CYAN="2DD5B7"
      LIGHT_MODE="no"
      ;;
    retro-82)
      PALETTE_ACCENT="faa968"; PALETTE_FG="f6dcac"; PALETTE_BG="05182e"; PALETTE_SELECTION="faa968"
      PALETTE_RED="f85525"; PALETTE_GREEN="028391"; PALETTE_YELLOW="e97b3c"; PALETTE_BLUE="faa968"; PALETTE_MAGENTA="3f8f8a"; PALETTE_CYAN="8cbfb8"
      LIGHT_MODE="no"
      ;;
    ristretto)
      PALETTE_ACCENT="f38d70"; PALETTE_FG="e6d9db"; PALETTE_BG="2c2525"; PALETTE_SELECTION="403e41"
      PALETTE_RED="fd6883"; PALETTE_GREEN="adda78"; PALETTE_YELLOW="f9cc6c"; PALETTE_BLUE="f38d70"; PALETTE_MAGENTA="a8a9eb"; PALETTE_CYAN="85dacc"
      LIGHT_MODE="no"
      ;;
    rose-pine)
      PALETTE_ACCENT="56949f"; PALETTE_FG="575279"; PALETTE_BG="faf4ed"; PALETTE_SELECTION="dfdad9"
      PALETTE_RED="b4637a"; PALETTE_GREEN="286983"; PALETTE_YELLOW="ea9d34"; PALETTE_BLUE="56949f"; PALETTE_MAGENTA="907aa9"; PALETTE_CYAN="d7827e"
      LIGHT_MODE="yes"
      ;;
    solitude)
      PALETTE_ACCENT="798186"; PALETTE_FG="cacccc"; PALETTE_BG="101315"; PALETTE_SELECTION="798186"
      PALETTE_RED="565d60"; PALETTE_GREEN="9fa5a9"; PALETTE_YELLOW="d9dbdc"; PALETTE_BLUE="798186"; PALETTE_MAGENTA="aeaeae"; PALETTE_CYAN="707070"
      LIGHT_MODE="no"
      ;;
    tokyo-night)
      PALETTE_ACCENT="7aa2f7"; PALETTE_FG="a9b1d6"; PALETTE_BG="1a1b26"; PALETTE_SELECTION="7aa2f7"
      PALETTE_RED="f7768e"; PALETTE_GREEN="9ece6a"; PALETTE_YELLOW="e0af68"; PALETTE_BLUE="7aa2f7"; PALETTE_MAGENTA="ad8ee6"; PALETTE_CYAN="449dab"
      LIGHT_MODE="no"
      ;;
    vantablack)
      PALETTE_ACCENT="8d8d8d"; PALETTE_FG="ffffff"; PALETTE_BG="000000"; PALETTE_SELECTION="ffffff"
      PALETTE_RED="a4a4a4"; PALETTE_GREEN="b6b6b6"; PALETTE_YELLOW="cecece"; PALETTE_BLUE="8d8d8d"; PALETTE_MAGENTA="9b9b9b"; PALETTE_CYAN="b0b0b0"
      LIGHT_MODE="no"
      ;;
    white)
      PALETTE_ACCENT="6e6e6e"; PALETTE_FG="000000"; PALETTE_BG="ffffff"; PALETTE_SELECTION="1a1a1a"
      PALETTE_RED="2a2a2a"; PALETTE_GREEN="3a3a3a"; PALETTE_YELLOW="4a4a4a"; PALETTE_BLUE="1a1a1a"; PALETTE_MAGENTA="2e2e2e"; PALETTE_CYAN="3e3e3e"
      LIGHT_MODE="yes"
      ;;
    *)
      die "Tema no soportado: $1"
      ;;
  esac

  PALETTE_PANEL="$(mix_panel_color "${PALETTE_BG}" "${LIGHT_MODE}")"
}

mix_panel_color() {
  local bg="$1"
  local light="$2"

  case "${light}" in
    yes) printf '%s\n' "e7e7e7" ;;
    *) printf '%s\n' "222433" ;;
  esac
}

list_themes() {
  local theme
  local themes_to_show=("${THEMES[@]}")

  log_header "Temas incluidos"
  if ((${#AVAILABLE_THEMES[@]} > 0)); then
    themes_to_show=("${AVAILABLE_THEMES[@]}")
  fi

  for theme in "${themes_to_show[@]}"; do
    theme_values "${theme}"
    log_kv "${theme}" "bg=#${PALETTE_BG} fg=#${PALETTE_FG} accent=#${PALETTE_ACCENT}"
  done
}

theme_preview_dir() {
  local home_dir="$1"
  printf '%s\n' "${home_dir}/.local/share/arch-redteam-style/previews"
}

write_theme_preview_svg() {
  local theme="$1"
  local preview_dir="$2"
  local preview_file="${preview_dir}/${theme}.svg"

  theme_values "${theme}"
  write_target_config "${preview_file}" "${USERNAME}" 0644 <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="960" height="540" viewBox="0 0 960 540">
  <rect width="960" height="540" fill="#${PALETTE_BG}"/>
  <rect x="0" y="0" width="960" height="34" fill="#${PALETTE_BG}" stroke="#${PALETTE_ACCENT}" stroke-opacity="0.55"/>
  <text x="18" y="23" font-family="monospace" font-size="15" font-weight="700" fill="#${PALETTE_ACCENT}">AW</text>
  <rect x="86" y="7" width="24" height="20" fill="#${PALETTE_ACCENT}"/>
  <text x="94" y="22" font-family="monospace" font-size="13" fill="#${PALETTE_BG}">1</text>
  <text x="124" y="22" font-family="monospace" font-size="13" fill="#${PALETTE_FG}" opacity="0.7">2</text>
  <text x="154" y="22" font-family="monospace" font-size="13" fill="#${PALETTE_FG}" opacity="0.7">3</text>
  <text x="184" y="22" font-family="monospace" font-size="13" fill="#${PALETTE_FG}" opacity="0.7">4</text>
  <text x="426" y="22" font-family="monospace" font-size="14" fill="#${PALETTE_ACCENT}">${theme}</text>
  <text x="760" y="22" font-family="monospace" font-size="13" fill="#${PALETTE_FG}">cpu 12%  ram 41%</text>
  <rect x="48" y="72" width="560" height="320" fill="#${PALETTE_BG}" stroke="#${PALETTE_ACCENT}" stroke-opacity="0.7" stroke-width="2"/>
  <rect x="48" y="72" width="560" height="34" fill="#${PALETTE_PANEL}" opacity="0.72"/>
  <rect x="64" y="85" width="10" height="10" fill="#${PALETTE_ACCENT}"/>
  <text x="86" y="95" font-family="monospace" font-size="13" fill="#${PALETTE_ACCENT}">kitty</text>
  <text x="74" y="150" font-family="monospace" font-size="17" fill="#${PALETTE_ACCENT}">~/ops &gt;</text>
  <text x="152" y="150" font-family="monospace" font-size="17" fill="#${PALETTE_FG}">fastfetch</text>
  <text x="74" y="188" font-family="monospace" font-size="16" fill="#${PALETTE_GREEN}">+ theme</text>
  <text x="170" y="188" font-family="monospace" font-size="16" fill="#${PALETTE_FG}">${theme}</text>
  <text x="74" y="220" font-family="monospace" font-size="16" fill="#${PALETTE_BLUE}">+ profile</text>
  <text x="170" y="220" font-family="monospace" font-size="16" fill="#${PALETTE_FG}">redteam-local</text>
  <text x="74" y="252" font-family="monospace" font-size="16" fill="#${PALETTE_YELLOW}">+ status</text>
  <text x="170" y="252" font-family="monospace" font-size="16" fill="#${PALETTE_FG}">quiet</text>
  <text x="74" y="304" font-family="monospace" font-size="17" fill="#${PALETTE_ACCENT}">$</text>
  <rect x="650" y="72" width="260" height="102" fill="#${PALETTE_BG}" stroke="#${PALETTE_ACCENT}" stroke-width="2"/>
  <rect x="650" y="72" width="8" height="102" fill="#${PALETTE_ACCENT}"/>
  <text x="674" y="112" font-family="monospace" font-size="16" fill="#${PALETTE_ACCENT}">Mako</text>
  <text x="674" y="142" font-family="monospace" font-size="13" fill="#${PALETTE_FG}">local, sin weather remoto</text>
  <rect x="650" y="204" width="260" height="188" fill="#${PALETTE_BG}" stroke="#${PALETTE_ACCENT}" stroke-width="2"/>
  <rect x="696" y="276" width="168" height="44" fill="#${PALETTE_BG}" stroke="#${PALETTE_ACCENT}" stroke-width="3"/>
  <text x="744" y="304" font-family="monospace" font-size="15" fill="#${PALETTE_FG}">Password</text>
  <rect x="48" y="430" width="108" height="26" fill="#${PALETTE_RED}"/>
  <rect x="156" y="430" width="108" height="26" fill="#${PALETTE_GREEN}"/>
  <rect x="264" y="430" width="108" height="26" fill="#${PALETTE_YELLOW}"/>
  <rect x="372" y="430" width="108" height="26" fill="#${PALETTE_BLUE}"/>
  <rect x="480" y="430" width="108" height="26" fill="#${PALETTE_MAGENTA}"/>
  <rect x="588" y="430" width="108" height="26" fill="#${PALETTE_CYAN}"/>
  <rect x="696" y="430" width="108" height="26" fill="#${PALETTE_FG}"/>
  <rect x="804" y="430" width="108" height="26" fill="#${PALETTE_ACCENT}"/>
  <text x="48" y="494" font-family="monospace" font-size="16" fill="#${PALETTE_FG}">bash scripts/omarchy-redteam-customize.sh --theme ${theme}</text>
</svg>
EOF
}

generate_theme_previews() {
  local home_dir
  local preview_dir
  local theme
  local preview_host_file

  home_dir="$(target_user_home "${USERNAME}")"
  preview_dir="$(theme_preview_dir "${home_dir}")"
  ensure_target_dir "${preview_dir}" "${USERNAME}"
  AVAILABLE_THEMES=()

  for theme in "${THEMES[@]}"; do
    write_theme_preview_svg "${theme}" "${preview_dir}"
    preview_host_file="$(target_to_host_path "${preview_dir}/${theme}.svg")"
    if [[ -s "${preview_host_file}" ]]; then
      AVAILABLE_THEMES+=("${theme}")
    else
      warn "Tema omitido porque no genero preview valida: ${theme}"
    fi
  done

  ((${#AVAILABLE_THEMES[@]} > 0)) || die "Ningun tema genero preview valida. No se aplicara nada."

  log_header "Previews generadas"
  log_kv "Directorio" "${preview_dir}"
  log_kv "Formato" "SVG local, sin recursos externos"
  log_kv "Temas validos" "${#AVAILABLE_THEMES[@]}"
}

ensure_selected_theme_has_preview() {
  local selected="$1"

  generate_theme_previews
  contains_value "${selected}" "${AVAILABLE_THEMES[@]}" || \
    die "Tema eliminado de la seleccion porque no genero preview valida: ${selected}"
}

open_preview_required() {
  local preview_file="$1"
  local opener=""
  local target_uid=""
  local runtime_dir=""
  local wayland_display="${WAYLAND_DISPLAY:-}"

  target_uid="$(target_capture id -u "${USERNAME}" | tail -n 1)"
  runtime_dir="${XDG_RUNTIME_DIR:-/run/user/${target_uid}}"

  if [[ -z "${wayland_display}" && -d "${runtime_dir}" ]]; then
    wayland_display="$(find "${runtime_dir}" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' 2>/dev/null | head -n 1)"
  fi

  if [[ -z "${DISPLAY:-}" && -z "${wayland_display}" ]]; then
    die "No hay sesion grafica disponible para abrir la preview. Ejecuta este selector dentro del Arch instalado con Hyprland iniciado."
  fi

  if command_exists xdg-open; then
    opener="xdg-open"
  elif command_exists imv; then
    opener="imv"
  elif command_exists swayimg; then
    opener="swayimg"
  elif command_exists firefox; then
    opener="firefox"
  elif command_exists chromium; then
    opener="chromium"
  fi

  [[ -n "${opener}" ]] || die "No hay visor para abrir SVG. Instala o usa xdg-open, imv, swayimg, firefox o chromium antes de aplicar temas."

  log_info "Abriendo preview con ${opener}: ${preview_file}"
  env \
    XDG_RUNTIME_DIR="${runtime_dir}" \
    WAYLAND_DISPLAY="${wayland_display}" \
    DISPLAY="${DISPLAY:-}" \
    XAUTHORITY="${XAUTHORITY:-}" \
    "${opener}" "${preview_file}" >/dev/null 2>&1 || die "No se pudo abrir la preview con ${opener}. No se aplicara ningun tema."
}

select_theme_if_needed() {
  local index=1
  local theme
  local choice
  local confirm
  local seen
  local home_dir
  local preview_dir
  local preview_file

  if [[ -n "${THEME_NAME}" ]]; then
    return 0
  fi

  [[ -t 0 ]] || die "No se indico --theme y no hay terminal interactiva para elegir uno."

  generate_theme_previews
  home_dir="$(target_user_home "${USERNAME}")"
  preview_dir="$(theme_preview_dir "${home_dir}")"

  while true; do
    index=1
    log_header "Selector de tema"
    for theme in "${AVAILABLE_THEMES[@]}"; do
      theme_values "${theme}"
      printf '  %2d) %-18s bg=#%s fg=#%s accent=#%s\n' "${index}" "${theme}" "${PALETTE_BG}" "${PALETTE_FG}" "${PALETTE_ACCENT}"
      index=$((index + 1))
    done

    printf '\nEscribe el numero del tema: '
    read -r choice
    choice="$(trim "${choice}")"

    [[ "${choice}" =~ ^[0-9]+$ ]] || {
      warn "Seleccion invalida. Escribe solo el numero del tema."
      continue
    }

    ((choice >= 1 && choice <= ${#AVAILABLE_THEMES[@]})) || die "Seleccion de tema fuera de rango: ${choice}"
    THEME_NAME="${AVAILABLE_THEMES[$((choice - 1))]}"
    preview_file="${preview_dir}/${THEME_NAME}.svg"

    log_header "Preview del tema"
    log_kv "Tema" "${THEME_NAME}"
    log_kv "Imagen" "${preview_file}"

    open_preview_required "$(target_to_host_path "${preview_file}")"

    printf '\nPudiste ver la preview en pantalla? [yes/no]: '
    read -r seen
    seen="$(trim "${seen}")"
    if ! is_yes "${seen}"; then
      THEME_NAME=""
      log_info "No se aplicara nada. Elige otro tema o revisa el visor de imagenes."
      continue
    fi

    printf '\nAplicar este tema? [yes/no]: '
    read -r confirm
    confirm="$(trim "${confirm}")"
    if is_yes "${confirm}"; then
      return 0
    fi

    THEME_NAME=""
    log_info "Elige otro tema."
  done
}

load_project_config() {
  if [[ -r "${CONFIG_FILE}" ]]; then
    load_install_config
  else
    USERNAME="${USERNAME:-user}"
  fi

  if [[ -n "${CUSTOM_USER}" ]]; then
    USERNAME="${CUSTOM_USER}"
  fi

  validate_username_value "${USERNAME}"
}

validate_environment() {
  require_root
  validate_absolute_path "${TARGET_ROOT}"
  validate_arch_target_root "${TARGET_ROOT}"
  target_capture id -u "${USERNAME}" >/dev/null || die "Usuario no encontrado en target: ${USERNAME}"
  if [[ -n "${THEME_NAME}" ]]; then
    contains_value "${THEME_NAME}" "${THEMES[@]}" || die "Tema no soportado: ${THEME_NAME}"
  fi
}

confirm_scope() {
  if is_yes "${ASSUME_YES}"; then
    return 0
  fi

  log_header "Confirmacion"
  log_kv "Target" "${TARGET_ROOT}"
  log_kv "Usuario" "${USERNAME}"
  log_kv "Tema" "${THEME_NAME}"
  log_kv "Red" "no se usara"
  log_kv "Instalacion paquetes" "no se hara"
  confirm_yes_no "Aplicar personalizacion local inspirada en Omarchy?"
}

write_palette_files() {
  local home_dir="$1"
  local style_dir="${home_dir}/.config/arch-redteam-style"

  ensure_target_dir "${style_dir}" "${USERNAME}"
  write_target_config "${style_dir}/palette.env" "${USERNAME}" 0644 <<EOF
THEME_NAME=${THEME_NAME}
ACCENT=#${PALETTE_ACCENT}
FOREGROUND=#${PALETTE_FG}
BACKGROUND=#${PALETTE_BG}
PANEL=#${PALETTE_PANEL}
SELECTION=#${PALETTE_SELECTION}
RED=#${PALETTE_RED}
GREEN=#${PALETTE_GREEN}
YELLOW=#${PALETTE_YELLOW}
BLUE=#${PALETTE_BLUE}
MAGENTA=#${PALETTE_MAGENTA}
CYAN=#${PALETTE_CYAN}
LIGHT_MODE=${LIGHT_MODE}
EOF

  write_target_config "${style_dir}/README" "${USERNAME}" 0644 <<EOF
Arch Redteam Omarchy-inspired style

This directory was generated locally by scripts/omarchy-redteam-customize.sh.
It does not contain Omarchy code, update channels, package repositories,
webapps, weather checks, AUR helpers, clipboard history, or telemetry.

Selected theme: ${THEME_NAME}
EOF
}

write_hyprland_config() {
  local home_dir="$1"
  local hypr_dir="${home_dir}/.config/hypr"
  local include_file="${hypr_dir}/arch-redteam-omarchy.conf"
  local main_conf="${hypr_dir}/hyprland.conf"
  local wallpaper="/usr/share/backgrounds/arch-workstation/default-wallpaper.png"

  ensure_target_dir "${hypr_dir}" "${USERNAME}"

  write_target_config "${include_file}" "${USERNAME}" 0644 <<EOF
# Local Omarchy-inspired Hyprland layer for redteam workstations.
# No Omarchy binaries, webapps, update checks, or remote helpers are used.

\$mod = SUPER
\$terminal = kitty
\$launcher = arch-redteam-menu

exec-once = hyprpaper
exec-once = waybar
exec-once = mako

env = XCURSOR_SIZE,24
env = QT_QPA_PLATFORM,wayland;xcb
env = GDK_BACKEND,wayland,x11
env = SDL_VIDEODRIVER,wayland
env = CLUTTER_BACKEND,wayland

input {
  kb_layout = us
  kb_options = compose:caps
  repeat_rate = 40
  repeat_delay = 250
  numlock_by_default = true
  follow_mouse = 1
  touchpad {
    clickfinger_behavior = true
    scroll_factor = 0.4
  }
}

general {
  gaps_in = 0
  gaps_out = 0
  border_size = 2
  col.active_border = rgba(${PALETTE_ACCENT}ff)
  col.inactive_border = rgba(${PALETTE_PANEL}cc)
  layout = dwindle
}

decoration {
  rounding = 0
  active_opacity = 1.0
  inactive_opacity = 0.96
  dim_inactive = true
  dim_strength = 0.10
  shadow {
    enabled = false
  }
  blur {
    enabled = false
  }
}

animations {
  enabled = false
}

misc {
  disable_hyprland_logo = true
  disable_splash_rendering = true
  force_default_wallpaper = 0
}

bind = \$mod, RETURN, exec, \$terminal
bind = \$mod, SPACE, exec, \$launcher
bind = \$mod SHIFT, F, exec, nautilus
bind = \$mod SHIFT, B, exec, chromium
bind = \$mod SHIFT, N, exec, nvim
bind = \$mod, Q, killactive
bind = \$mod, F, fullscreen
bind = \$mod, V, togglefloating
bind = \$mod SHIFT, R, exec, hyprctl reload
bind = \$mod CTRL, L, exec, hyprlock
bind = \$mod SHIFT, S, exec, grim -g "\$(slurp)" "\$HOME/Pictures/Screenshots/\$(date +%Y%m%d-%H%M%S).png"
bind = \$mod, H, movefocus, l
bind = \$mod, J, movefocus, d
bind = \$mod, K, movefocus, u
bind = \$mod, L, movefocus, r
bind = \$mod SHIFT, H, movewindow, l
bind = \$mod SHIFT, J, movewindow, d
bind = \$mod SHIFT, K, movewindow, u
bind = \$mod SHIFT, L, movewindow, r

bind = \$mod, 1, workspace, 1
bind = \$mod, 2, workspace, 2
bind = \$mod, 3, workspace, 3
bind = \$mod, 4, workspace, 4
bind = \$mod, 5, workspace, 5
bind = \$mod, 6, workspace, 6
bind = \$mod, 7, workspace, 7
bind = \$mod, 8, workspace, 8
bind = \$mod, 9, workspace, 9
bind = \$mod SHIFT, 1, movetoworkspace, 1
bind = \$mod SHIFT, 2, movetoworkspace, 2
bind = \$mod SHIFT, 3, movetoworkspace, 3
bind = \$mod SHIFT, 4, movetoworkspace, 4
bind = \$mod SHIFT, 5, movetoworkspace, 5
bind = \$mod SHIFT, 6, movetoworkspace, 6
bind = \$mod SHIFT, 7, movetoworkspace, 7
bind = \$mod SHIFT, 8, movetoworkspace, 8
bind = \$mod SHIFT, 9, movetoworkspace, 9

windowrulev2 = opacity 0.98 0.94,class:^(kitty|Alacritty|foot)$
windowrulev2 = float,class:^(pavucontrol|blueman-manager|nm-connection-editor)$
windowrulev2 = center,class:^(pavucontrol|blueman-manager|nm-connection-editor)$
EOF

  if [[ ! -f "$(target_to_host_path "${main_conf}")" ]]; then
    write_target_config "${main_conf}" "${USERNAME}" 0644 <<EOF
# Main Hyprland config generated by Arch Workstation.
source = ${include_file}
EOF
  else
    append_line_once "${main_conf}" "${USERNAME}" "source = ${include_file}"
  fi

  write_target_config "${hypr_dir}/hyprpaper.conf" "${USERNAME}" 0644 <<EOF
preload = ${wallpaper}
wallpaper = ,${wallpaper}
splash = false
EOF

  write_target_config "${hypr_dir}/hyprlock.conf" "${USERNAME}" 0644 <<EOF
general {
  ignore_empty_input = true
}

background {
  monitor =
  color = rgb(${PALETTE_BG})
  blur_passes = 0
}

animations {
  enabled = false
}

input-field {
  monitor =
  size = 620, 82
  position = 0, 0
  halign = center
  valign = center
  inner_color = rgba(${PALETTE_BG}ff)
  outer_color = rgba(${PALETTE_ACCENT}ff)
  outline_thickness = 2
  font_family = JetBrainsMono Nerd Font
  font_color = rgba(${PALETTE_FG}ff)
  placeholder_text = Password
  check_color = rgba(${PALETTE_GREEN}ff)
  fail_color = rgba(${PALETTE_RED}ff)
  rounding = 0
  shadow_passes = 0
  fade_on_empty = false
}

auth {
  fingerprint:enabled = false
}
EOF

  ensure_target_dir "${home_dir}/Pictures/Screenshots" "${USERNAME}"
}

write_waybar_config() {
  local home_dir="$1"
  local waybar_dir="${home_dir}/.config/waybar"

  ensure_target_dir "${waybar_dir}" "${USERNAME}"

  write_target_config "${waybar_dir}/config.jsonc" "${USERNAME}" 0644 <<'EOF'
{
  "reload_style_on_change": true,
  "layer": "top",
  "position": "top",
  "height": 26,
  "spacing": 0,
  "modules-left": ["custom/menu", "hyprland/workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["tray", "network", "pulseaudio", "cpu", "memory", "battery"],
  "custom/menu": {
    "format": "AW",
    "on-click": "arch-redteam-menu",
    "tooltip-format": "Arch Workstation Menu\\nSuper + Space"
  },
  "hyprland/workspaces": {
    "on-click": "activate",
    "format": "{name}",
    "persistent-workspaces": {
      "1": [],
      "2": [],
      "3": [],
      "4": [],
      "5": []
    }
  },
  "clock": {
    "format": "{:%A %H:%M}",
    "format-alt": "{:%Y-%m-%d W%V}",
    "tooltip": false
  },
  "network": {
    "format-wifi": "wifi {signalStrength}%",
    "format-ethernet": "wired",
    "format-disconnected": "offline",
    "tooltip-format-wifi": "{essid}",
    "tooltip-format-disconnected": "Disconnected",
    "interval": 3
  },
  "pulseaudio": {
    "format": "vol {volume}%",
    "format-muted": "muted",
    "scroll-step": 5,
    "on-click-right": "pamixer -t"
  },
  "cpu": {
    "interval": 5,
    "format": "cpu {usage}%"
  },
  "memory": {
    "interval": 5,
    "format": "ram {}%"
  },
  "battery": {
    "format": "bat {capacity}%",
    "format-charging": "chg {capacity}%",
    "format-plugged": "ac",
    "states": {
      "warning": 20,
      "critical": 10
    }
  },
  "tray": {
    "icon-size": 12,
    "spacing": 12
  }
}
EOF

  write_target_config "${waybar_dir}/style.css" "${USERNAME}" 0644 <<EOF
* {
  background: #${PALETTE_BG};
  color: #${PALETTE_FG};
  border: none;
  border-radius: 0;
  min-height: 0;
  font-family: "JetBrainsMono Nerd Font", "Noto Sans", sans-serif;
  font-size: 12px;
}

.modules-left {
  margin-left: 8px;
}

.modules-right {
  margin-right: 8px;
}

#custom-menu,
#cpu,
#memory,
#battery,
#pulseaudio,
#network,
#tray {
  min-width: 12px;
  margin: 0 7px;
}

#custom-menu {
  color: #${PALETTE_ACCENT};
  font-weight: bold;
}

#workspaces button {
  all: initial;
  color: #${PALETTE_FG};
  padding: 0 7px;
  margin: 0 1px;
}

#workspaces button.empty {
  opacity: 0.45;
}

#workspaces button.active {
  color: #${PALETTE_ACCENT};
}

#clock {
  color: #${PALETTE_ACCENT};
}

#battery.warning {
  color: #${PALETTE_YELLOW};
}

#battery.critical {
  color: #${PALETTE_RED};
}

tooltip {
  background: #${PALETTE_BG};
  color: #${PALETTE_FG};
  border: 1px solid #${PALETTE_ACCENT};
}
EOF
}

write_mako_config() {
  local home_dir="$1"
  local mako_dir="${home_dir}/.config/mako"

  ensure_target_dir "${mako_dir}" "${USERNAME}"
  write_target_config "${mako_dir}/config" "${USERNAME}" 0644 <<EOF
font=JetBrainsMono Nerd Font 10
background-color=#${PALETTE_BG}
text-color=#${PALETTE_FG}
border-color=#${PALETTE_ACCENT}
progress-color=over #${PALETTE_ACCENT}
border-size=2
border-radius=0
padding=10
margin=10
default-timeout=6000
max-visible=4
ignore-timeout=0
icons=1
history=0
EOF
}

write_terminal_configs() {
  local home_dir="$1"
  local kitty_dir="${home_dir}/.config/kitty"

  ensure_target_dir "${kitty_dir}" "${USERNAME}"
  write_target_config "${kitty_dir}/theme.conf" "${USERNAME}" 0644 <<EOF
foreground #${PALETTE_FG}
background #${PALETTE_BG}
selection_foreground #${PALETTE_BG}
selection_background #${PALETTE_SELECTION}
cursor #${PALETTE_ACCENT}
color0 #${PALETTE_BG}
color1 #${PALETTE_RED}
color2 #${PALETTE_GREEN}
color3 #${PALETTE_YELLOW}
color4 #${PALETTE_BLUE}
color5 #${PALETTE_MAGENTA}
color6 #${PALETTE_CYAN}
color7 #${PALETTE_FG}
color8 #${PALETTE_PANEL}
color9 #${PALETTE_RED}
color10 #${PALETTE_GREEN}
color11 #${PALETTE_YELLOW}
color12 #${PALETTE_BLUE}
color13 #${PALETTE_MAGENTA}
color14 #${PALETTE_CYAN}
color15 #${PALETTE_FG}
active_tab_background #${PALETTE_ACCENT}
active_tab_foreground #${PALETTE_BG}
inactive_tab_background #${PALETTE_PANEL}
inactive_tab_foreground #${PALETTE_FG}
EOF

  write_target_config "${kitty_dir}/kitty.conf" "${USERNAME}" 0644 <<'EOF'
include theme.conf

font_family JetBrainsMono Nerd Font
bold_italic_font auto
font_size 9.0
window_padding_width 14
hide_window_decorations yes
confirm_os_window_close 0
map ctrl+insert copy_to_clipboard
map shift+insert paste_from_clipboard
allow_remote_control no
cursor_shape block
cursor_blink_interval 0
shell_integration no-cursor
enable_audio_bell no
tab_bar_edge bottom
tab_bar_style powerline
tab_powerline_style slanted
EOF
}

write_shell_tool_configs() {
  local home_dir="$1"
  local btop_dir="${home_dir}/.config/btop/themes"
  local fastfetch_dir="${home_dir}/.config/fastfetch"

  write_target_config "${home_dir}/.config/starship.toml" "${USERNAME}" 0644 <<EOF
add_newline = true
command_timeout = 200
format = "[\\\$directory\\\$git_branch\\\$git_status](\\\$style)\\\$character"

[character]
success_symbol = "[>](bold #${PALETTE_ACCENT})"
error_symbol = "[x](bold #${PALETTE_RED})"

[directory]
truncation_length = 2
truncation_symbol = "../"
repo_root_style = "bold #${PALETTE_ACCENT}"
repo_root_format = "[\\\$repo_root](\\\$repo_root_style)[\\\$path](\\\$style)[\\\$read_only](\\\$read_only_style) "

[git_branch]
format = "[\\\$branch](\\\$style) "
style = "italic #${PALETTE_ACCENT}"

[git_status]
format = "[\\\$all_status](\\\$style)"
style = "#${PALETTE_ACCENT}"
untracked = "? "
modified = "! "
deleted = "x "
ahead = "+\\\${count} "
behind = "-\\\${count} "
diverged = "+\\\${ahead_count}-\\\${behind_count} "
EOF

  ensure_target_dir "${btop_dir}" "${USERNAME}"
  write_target_config "${btop_dir}/arch-redteam.theme" "${USERNAME}" 0644 <<EOF
theme[main_bg]="#${PALETTE_BG}"
theme[main_fg]="#${PALETTE_FG}"
theme[title]="#${PALETTE_ACCENT}"
theme[hi_fg]="#${PALETTE_ACCENT}"
theme[selected_bg]="#${PALETTE_PANEL}"
theme[selected_fg]="#${PALETTE_FG}"
theme[inactive_fg]="#${PALETTE_PANEL}"
theme[graph_text]="#${PALETTE_FG}"
theme[meter_bg]="#${PALETTE_PANEL}"
theme[proc_misc]="#${PALETTE_CYAN}"
theme[cpu_box]="#${PALETTE_ACCENT}"
theme[mem_box]="#${PALETTE_GREEN}"
theme[net_box]="#${PALETTE_BLUE}"
theme[proc_box]="#${PALETTE_MAGENTA}"
theme[temp_start]="#${PALETTE_GREEN}"
theme[temp_mid]="#${PALETTE_YELLOW}"
theme[temp_end]="#${PALETTE_RED}"
theme[cpu_start]="#${PALETTE_GREEN}"
theme[cpu_mid]="#${PALETTE_YELLOW}"
theme[cpu_end]="#${PALETTE_RED}"
theme[free_start]="#${PALETTE_RED}"
theme[free_mid]="#${PALETTE_YELLOW}"
theme[free_end]="#${PALETTE_GREEN}"
EOF

  ensure_target_dir "${fastfetch_dir}" "${USERNAME}"
  write_target_config "${fastfetch_dir}/config.jsonc" "${USERNAME}" 0644 <<EOF
{
  "logo": {
    "type": "small"
  },
  "display": {
    "separator": "  ",
    "color": {
      "keys": "blue",
      "title": "cyan"
    }
  },
  "modules": [
    "title",
    "separator",
    "os",
    "kernel",
    "wm",
    "terminal",
    "shell",
    "cpu",
    "gpu",
    "memory",
    "disk",
    {
      "type": "custom",
      "key": "Theme",
      "format": "${THEME_NAME}"
    },
    {
      "type": "custom",
      "key": "Profile",
      "format": "redteam-local"
    }
  ]
}
EOF
}

write_launcher_configs() {
  local home_dir="$1"
  local walker_dir="${home_dir}/.config/walker"
  local wofi_dir="${home_dir}/.config/wofi"

  ensure_target_dir "${walker_dir}" "${USERNAME}"
  write_target_config "${walker_dir}/config.toml" "${USERNAME}" 0644 <<'EOF'
force_keyboard_focus = true
selection_wrap = true
hide_action_hints = true

[providers]
max_results = 128
default = [
  "desktopapplications",
]

[[providers.prefixes]]
prefix = "/"
provider = "providerlist"

[[providers.prefixes]]
prefix = "."
provider = "files"

[[providers.prefixes]]
prefix = "="
provider = "calc"
EOF

  ensure_target_dir "${wofi_dir}" "${USERNAME}"
  write_target_config "${wofi_dir}/style.css" "${USERNAME}" 0644 <<EOF
window {
  background-color: #${PALETTE_BG};
  color: #${PALETTE_FG};
  border: 2px solid #${PALETTE_ACCENT};
}

#input {
  background-color: #${PALETTE_BG};
  color: #${PALETTE_FG};
  border: 1px solid #${PALETTE_ACCENT};
}

#entry {
  color: #${PALETTE_FG};
  padding: 6px;
}

#entry:selected {
  background-color: #${PALETTE_ACCENT};
  color: #${PALETTE_BG};
}
EOF
}

write_local_menu() {
  local bin_path="/usr/local/bin/arch-redteam-menu"

  write_target_config "${bin_path}" "root" 0755 <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

choose() {
  if command -v walker >/dev/null 2>&1; then
    printf '%s\n' "$@" | walker --dmenu
  elif command -v wofi >/dev/null 2>&1; then
    printf '%s\n' "$@" | wofi --dmenu --prompt "Arch"
  elif command -v fuzzel >/dev/null 2>&1; then
    printf '%s\n' "$@" | fuzzel --dmenu --prompt "Arch> "
  else
    printf '%s\n' "$@" | sed -n '1p'
  fi
}

choice="$(choose \
  "Terminal" \
  "Browser" \
  "Files" \
  "Reload Hyprland" \
  "Restart Waybar" \
  "Lock" \
  "Power Menu")"

case "${choice}" in
  Terminal) exec kitty ;;
  Browser) exec chromium ;;
  Files) exec nautilus ;;
  "Reload Hyprland") exec hyprctl reload ;;
  "Restart Waybar") pkill waybar 2>/dev/null || true; exec waybar ;;
  Lock) exec hyprlock ;;
  "Power Menu")
    subchoice="$(choose "Suspend" "Reboot" "Shutdown" "Cancel")"
    case "${subchoice}" in
      Suspend) exec systemctl suspend ;;
      Reboot) exec systemctl reboot ;;
      Shutdown) exec systemctl poweroff ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOF
}

write_environment_configs() {
  local home_dir="$1"
  local env_dir="${home_dir}/.config/environment.d"
  local gtk3="${home_dir}/.config/gtk-3.0"
  local gtk4="${home_dir}/.config/gtk-4.0"
  local dark_value="1"
  local gtk_theme="Adwaita-dark"

  if is_yes "${LIGHT_MODE}"; then
    dark_value="0"
    gtk_theme="Adwaita"
  fi

  ensure_target_dir "${env_dir}" "${USERNAME}"
  write_target_config "${env_dir}/arch-redteam.conf" "${USERNAME}" 0644 <<'EOF'
TERMINAL=kitty
EDITOR=nvim
BROWSER=chromium
MOZ_ENABLE_WAYLAND=1
QT_QPA_PLATFORM=wayland;xcb
GDK_BACKEND=wayland,x11
EOF

  ensure_target_dir "${gtk3}" "${USERNAME}"
  ensure_target_dir "${gtk4}" "${USERNAME}"
  write_target_config "${gtk3}/settings.ini" "${USERNAME}" 0644 <<EOF
[Settings]
gtk-theme-name=${gtk_theme}
gtk-icon-theme-name=Adwaita
gtk-application-prefer-dark-theme=${dark_value}
EOF
  write_target_config "${gtk4}/settings.ini" "${USERNAME}" 0644 <<EOF
[Settings]
gtk-theme-name=${gtk_theme}
gtk-icon-theme-name=Adwaita
gtk-application-prefer-dark-theme=${dark_value}
EOF
}

write_security_notes() {
  local home_dir="$1"
  local notes_dir="${home_dir}/.config/arch-redteam-style"

  write_target_config "${notes_dir}/omarchy-audit-notes.txt" "${USERNAME}" 0644 <<'EOF'
Omarchy inspection notes for this redteam-safe recreation:

Included locally:
- Theme palettes inspired by Omarchy theme names.
- Local Hyprland, Waybar, Mako, Kitty, Starship, btop, Fastfetch, Hyprlock, Walker/Wofi configs.
- Local launcher script with no package management and no webapp shortcuts.

Deliberately excluded:
- Omarchy boot/install scripts.
- Omarchy pacman repositories and mirrors.
- Omarchy update channels, migrations, package installers, and AUR helpers.
- Weather modules or remote status checks.
- Webapp launchers for third-party services.
- Windows VM helpers.
- Clipboard history provider.
- Log upload/debug upload helpers.
- Fingerprint/Fido automation.
- Portal config that broadly allows screencopy tokens by default.
EOF
}

apply_customization() {
  local home_dir

  theme_values "${THEME_NAME}"
  home_dir="$(target_user_home "${USERNAME}")"

  log_section "Omarchy-inspired redteam customization"
  log_kv "Target" "${TARGET_ROOT}"
  log_kv "Usuario" "${USERNAME}"
  log_kv "Home" "${home_dir}"
  log_kv "Tema" "${THEME_NAME}"

  write_palette_files "${home_dir}"
  write_hyprland_config "${home_dir}"
  write_waybar_config "${home_dir}"
  write_mako_config "${home_dir}"
  write_terminal_configs "${home_dir}"
  write_shell_tool_configs "${home_dir}"
  write_launcher_configs "${home_dir}"
  write_local_menu
  write_environment_configs "${home_dir}"
  write_security_notes "${home_dir}"

  success "Personalizacion aplicada. Reinicia la sesion grafica o ejecuta hyprctl reload."
}

main() {
  parse_args "$@"

  load_project_config
  validate_environment

  if is_yes "${LIST_ONLY}"; then
    generate_theme_previews
    list_themes
    exit 0
  fi

  if is_yes "${PREVIEW_ONLY}"; then
    generate_theme_previews
    exit 0
  fi

  select_theme_if_needed
  ensure_selected_theme_has_preview "${THEME_NAME}"
  contains_value "${THEME_NAME}" "${THEMES[@]}" || die "Tema no soportado: ${THEME_NAME}"
  confirm_scope || die "Operacion cancelada."
  apply_customization
}

main "$@"
