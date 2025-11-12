#!/usr/bin/env bash
# Minimal Desktop systemd Profile (Interactive)
# Debian/Ubuntu: services, boot quieting, Plymouth, Flatpak migration, Waydroid,
# Security (AppArmor+UFW), Privoxy, MS-compat (Samba/NTFS/exFAT/FAT32/Wine/DOSBox/CoreFonts),
# Snap (single prompt), Ubuntu-like Appearance (Fonts+Theme)
# Tested on Debian 13
#
# NOTE: For proprietary or copyrighted applications and fonts (e.g. Steam, MS Core Fonts),
#       please review the repository's LICENSE file and the vendor EULAs before installing.

set -o nounset
set -o pipefail

# ------------------------------ Helpers ------------------------------

sh_run() { "$@"; return $?; }
have() { command -v "$1" >/dev/null 2>&1; }
have_systemctl() { have systemctl; }
is_apt_based() { have apt-get || have apt; }

unit_exists() {
  local unit="$1"
  systemctl status "$unit" >/dev/null 2>&1 || {
    systemctl status "$unit" 2>&1 | grep -qiE 'not-found|could not be found' && return 1
  }
  return 0
}

first_existing() { local u; for u in "$@"; do unit_exists "$u" && { echo "$u"; return 0; }; done; return 1; }
enable_now() { systemctl enable --now "$1" >/dev/null 2>&1 || true; }
disable_now() { systemctl disable --now "$1" >/dev/null 2>&1 || true; }
mask_unit() { systemctl mask "$1" >/dev/null 2>&1 || true; }
unmask_unit() { systemctl unmask "$1" >/dev/null 2>&1 || true; }

print_header() { printf "\n%s\n%s\n%s\n" "========================================================================" "$1" "========================================================================"; }
print_action() { printf "  - %-10s %s\n" "$1" "$2"; }

yn() {
  local prompt="$1" default="$2" ans
  if [[ "$default" == "true" ]]; then
    read -r -p "$prompt [Y/n]: " ans || ans=""
    ans="${ans,,}"; [[ -z "$ans" || "$ans" == y || "$ans" == yes ]]
  else
    read -r -p "$prompt [y/N]: " ans || ans=""
    ans="${ans,,}"; [[ "$ans" == y || "$ans" == yes ]]
  fi
}

yn_strict() {
  local ans
  while true; do
    read -r -p "$1 [y/n]: " ans || ans=""
    ans="${ans,,}"
    [[ "$ans" == y || "$ans" == yes ]] && return 0
    [[ "$ans" == n || "$ans" == no  ]] && return 1
    echo "Please type 'y' or 'n'."
  done
}

# One prompt for Snap: Enable / Remove / Keep
choose_snap_mode() {
  local ans
  while true; do
    echo "Snap: [E]nable (install snapd+plugin), [R]emove (purge snapd), [K]eep (no changes)"
    read -r -p "Choose [E]nable/[R]remove/[K]eep [default: K]: " ans || ans=""
    ans="${ans,,}"
    [[ -z "$ans" || "$ans" == "k" ]] && { echo "keep"; return 0; }
    [[ "$ans" == "e" ]] && { echo "enable"; return 0; }
    [[ "$ans" == "r" ]] && { echo "remove"; return 0; }
    echo "Please type E, R, or K."
  done
}

ensure_packages_list() {
  if ! is_apt_based; then echo "  ! Not an apt-based system; cannot install: $*"; return 1; fi
  echo "  - Installing (if missing): $*"
  DEBIAN_FRONTEND=noninteractive apt-get -y update >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get -y install "$@"
}

have_pkg() { dpkg -s "$1" >/dev/null 2>&1; }
file_read() { [[ -f "$1" ]] && cat -- "$1"; }
file_write() { local path="$1"; mkdir -p "$(dirname "$path")"; cat >"$path"; }

ensure_kv_line() {
  local conf="$1" key="$2" value="$3" comment="${4:-}"
  local tmp; tmp="$(mktemp)"
  local new="${key}=${value}"
  [[ -f "$conf" ]] || { [[ -n "$comment" ]] && echo "# $comment" >"$tmp"; echo "$new" >>"$tmp"; mv "$tmp" "$conf"; return; }
  awk -v k="^\\s*"${key//\//\\/}"\\s*=" -v new="$new" -v cmt="$comment" '
    BEGIN{replaced=0}
    NR==1 && length(cmt)>0 {print "# " cmt}
    { if ($0 ~ k && !replaced) { print new; replaced=1 } else { print $0 } }
    END{ if (!replaced) print new }
  ' "$conf" >"$tmp" && mv "$tmp" "$conf"
}

kernel_versions() { ls -1 /lib/modules 2>/dev/null | sed '/^\s*$/d' || true; }

rebuild_initramfs_after_plymouth() {
  if have update-initramfs; then
    echo "  - Rebuilding initramfs via update-initramfs (all kernels)..."
    update-initramfs -u -k all >/dev/null 2>&1 || true
  elif have dracut; then
    echo "  - Rebuilding initramfs via dracut (hostonly per kernel)..."
    local v; while IFS= read -r v; do [[ -n "$v" ]] && dracut -f --hostonly --kver="$v" >/dev/null 2>&1 || true; done < <(kernel_versions)
  else
    echo "  ! No initramfs tool found (update-initramfs or dracut). Rebuild manually if needed."
  fi
}

append_kernel_params() {
  local changed=0 params=("$@") entries=()
  IFS=$'\n' read -r -d '' -a entries < <(find /boot/efi/loader/entries -type f -name '*.conf' 2>/dev/null && printf '\0') || true
  if (( ${#entries[@]} )); then
    local p data new tokens i opt
    for p in "${entries[@]}"; do
      data="$(cat "$p")"
      if grep -qE '^\s*options\s+' "$p"; then
        opt="$(grep -E '^\s*options\s+' "$p" | head -n1)"
        # shellcheck disable=SC2206
        tokens=($opt); unset tokens[0]
        for i in "${params[@]}"; do
          if ! printf '%s\n' "${tokens[@]}" | grep -qx -- "$i"; then tokens+=("$i"); changed=1; fi
        done
        new="options ${tokens[*]}"
        awk -v repl="$new" 'BEGIN{done=0}{ if (!done && $1=="options"){ print repl; done=1 } else { print $0 } }' "$p" >"$p.tmp" && mv "$p.tmp" "$p"
      else
        echo "options ${params[*]}" >>"$p"; changed=1
      fi
    done
  else
    local grub_def="/etc/default/grub"
    if [[ -f "$grub_def" ]]; then
      local current; current="$(sed -n 's/^\s*GRUB_CMDLINE_LINUX_DEFAULT\s*=\s*"\(.*\)".*/\1/p' "$grub_def")"
      if [[ -z "$current" ]]; then
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${params[*]}\"" >>"$grub_def"; changed=1
      else
        local add=0 p; for p in "${params[@]}"; do
          if ! grep -qw -- "$p" <<<"$current"; then current="$current $p"; add=1; fi
        done
        if (( add )); then
          sed -i "s|^\s*GRUB_CMDLINE_LINUX_DEFAULT\s*=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$current\"|" "$grub_def"; changed=1
        fi
      fi
      if (( changed )); then
        if have update-grub; then echo "  - Running update-grub..."; update-grub >/dev/null 2>&1 || true
        elif have grub-mkconfig; then echo "  - Running grub-mkconfig..."; grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true; fi
      fi
    fi
  fi
  return "$changed"
}

# ------------------------------ OS / repo helpers ------------------------------

OS_ID=""; OS_CODENAME=""
read_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
  fi
}

ensure_base_repo_tools() { ensure_packages_list curl ca-certificates gnupg apt-transport-https >/dev/null 2>&1 || true; }

add_apt_repo() {
  # add_apt_repo name key_url repo_line
  local name="$1" key_url="$2" repo_line="$3"
  local keyring="/etc/apt/keyrings/${name}.gpg" list="/etc/apt/sources.list.d/${name}.list"
  mkdir -p /etc/apt/keyrings
  curl -fsSL "$key_url" | gpg --dearmor | tee "$keyring" >/dev/null
  echo "deb [signed-by=${keyring}] ${repo_line}" > "$list"
  echo "  - Added APT repo: $name"
}

apt_update_quiet() { DEBIAN_FRONTEND=noninteractive apt-get -y update >/dev/null 2>&1 || true; }

enable_i386_multiarch() {
  if ! dpkg --print-foreign-architectures | grep -q '^i386$'; then
    dpkg --add-architecture i386
    echo "  - Enabled i386 multiarch."
    apt_update_quiet
  fi
}

debian_enable_components_if_needed() {
  # Ensure contrib non-free non-free-firmware for Debian (needed for fonts/firmware, etc.)
  [[ "$OS_ID" != "debian" ]] && return 0
  if ! grep -Eq '\scontrib(\s|$)' /etc/apt/sources.list; then
    echo "  ! Debian: enabling 'contrib non-free non-free-firmware' in /etc/apt/sources.list"
    sed -i 's/^\s*deb\s\+\(\S\+\)\s\+(\S\+\s\+)\?main.*/& contrib non-free non-free-firmware/' /etc/apt/sources.list || true
    apt_update_quiet
  fi
}

# ------------------------------ Boot verbosity ------------------------------

reduce_boot_spam() {
  local mask_plymouth_waits="$1"
  print_header "Reducing boot verbosity"
  append_kernel_params "quiet" "loglevel=3" "udev.log_level=3" "systemd.show_status=false" "rd.systemd.show_status=false" && \
    echo "  - Kernel cmdline updated for quieter boot."
  ensure_kv_line "/etc/systemd/journald.conf" "MaxLevelConsole" "notice" "Set by lean-desktop: reduce console noise while keeping important messages"
  systemctl restart systemd-journald.service >/dev/null 2>&1 || true
  ensure_kv_line "/etc/systemd/system.conf" "LogLevel" "notice" "Set by lean-desktop: reduce systemd manager console verbosity"
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ "$mask_plymouth_waits" == "true" ]]; then
    local u; for u in plymouth-quit-wait.service plymouth-quit.service; do unit_exists "$u" && { print_action "mask" "$u"; mask_unit "$u"; }; done
  fi
}

# ------------------------------ Plymouth ------------------------------

configure_plymouth() {
  local theme="${1:-debian-text}"
  print_header "Configuring Plymouth splash"
  if is_apt_based; then ensure_packages_list plymouth plymouth-themes "plymouth-theme-${theme}" >/dev/null 2>&1 || true
  else echo "  ! Non-apt system: ensure plymouth + themes installed."; fi

  if have plymouth-set-default-theme; then
    echo "  - Setting Plymouth theme: $theme"
    plymouth-set-default-theme -R "$theme" >/dev/null 2>&1 || true
  else
    if have update-alternatives; then
      update-alternatives --set default.plymouth "/usr/share/plymouth/themes/${theme}/${theme}.plymouth" >/dev/null 2>&1 || true
    fi
    rebuild_initramfs_after_plymouth
  fi

  append_kernel_params "splash" && { echo "  - Added 'splash' to kernel cmdline."; rebuild_initramfs_after_plymouth; }
}

# ------------------------------ Flatpak ------------------------------

ensure_flatpak_setup() {
  print_header "Setting up Flatpak & Flathub"
  if ! is_apt_based; then echo "  ! Non-apt system; install Flatpak manually."; return; fi
  ensure_packages_list flatpak gnome-software gnome-software-plugin-flatpak xdg-desktop-portal xdg-desktop-portal-gnome >/dev/null 2>&1 || true
  if ! flatpak remotes | grep -q '^flathub'; then
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true
  fi
  echo "  - Flathub is configured."
  systemctl --user start xdg-desktop-portal.service >/dev/null 2>&1 || true
}

install_flatpak_firefox() {
  print_header "Installing Firefox (Flatpak)"
  if ! flatpak info org.mozilla.firefox >/dev/null 2>&1; then
    flatpak install -y flathub org.mozilla.firefox >/dev/null 2>&1 || true
  else
    echo "  - Firefox Flatpak already installed."
  fi
}

apt_purge_group() {
  local -a pkgs=("$@")
  if ! is_apt_based; then echo "  ! Non-apt system; skip purge."; return; fi
  local p
  for p in "${pkgs[@]}"; do
    echo "  - Purging: $p"
    DEBIAN_FRONTEND=noninteractive apt-get -y purge "$p" >/dev/null 2>&1 || true
  done
  echo "  - Autoremoving residual dependencies..."
  DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge >/dev/null 2>&1 || true
}

offer_purge_groups() {
  print_header "Purge preinstalled APT apps (optional)"
  echo "Select groups to purge. You can re-install from Flathub via GNOME Software later."
  yn "  Purge Browsers & Mail (firefox-esr, chromium, thunderbird)?" false && apt_purge_group firefox-esr firefox chromium chromium-common thunderbird
  yn "  Purge Office (libreoffice*, dictionaries)?" false && apt_purge_group 'libreoffice*' 'hunspell-*' 'mythes-*' 'hyphen-*'
  yn "  Purge Media (vlc, totem, rhythmbox, etc.)?" false && apt_purge_group vlc 'vlc-plugin-*' totem rhythmbox shotwell cheese
  yn "  Purge Utilities (transmission-gtk, file-roller, scanners, pdf viewers)?" false && apt_purge_group transmission-gtk file-roller simple-scan evince okular atril xpdf
  yn "  Purge Graphics (gimp, inkscape)?" false && apt_purge_group gimp inkscape
  yn "  Purge GNOME Extras (gnome-logs, maps, weather)?" false && apt_purge_group gnome-logs gnome-maps gnome-weather
  yn "  Purge Snap (snapd)?" false && apt_purge_group snapd
}

# ------------------------------ Waydroid ------------------------------

ensure_waydroid_repo_and_install() {
  print_header "Installing Waydroid (Android apps on Linux)"
  if ! is_apt_based; then echo "  ! Non-apt system; install Waydroid manually."; return 1; fi
  ensure_packages_list curl ca-certificates >/dev/null 2>&1 || true
  bash -lc 'curl -s https://repo.waydro.id | bash' >/dev/null 2>&1 || true
  if ensure_packages_list waydroid lxc python3-gbinder; then echo "  - Waydroid packages installed."; return 0; fi
  return 1
}

waydroid_initialized() { [[ -d /var/lib/waydroid ]]; }
waydroid_init() { local gapps="$1"; waydroid_initialized && { echo "  - Waydroid already initialized; skipping image download."; return; }
  if [[ "$gapps" == "true" ]]; then echo "  - Initializing Waydroid image (GAPPS)..."; bash -lc 'waydroid init -s GAPPS' >/dev/null 2>&1 || true
  else echo "  - Initializing Waydroid image (VANILLA)..."; bash -lc 'waydroid init' >/dev/null 2>&1 || true; fi; }
ensure_waydroid_service() { local u; u="$(first_existing waydroid-container.service)" || u="waydroid-container.service"; print_action "enable" "$u"; enable_now "$u"; }
write_desktop_file() { local path="$1" name="$2" exec_cmd="$3" icon="${4:-waydroid}" comment="${5:-}"; mkdir -p "$(dirname "$path")"; cat >"$path" <<EOF
[Desktop Entry]
Type=Application
Name=${name}
Exec=${exec_cmd}
Icon=${icon}
Terminal=false
StartupNotify=true
Categories=System;Utility;
X-GNOME-UsesNotifications=true
EOF
[[ -n "$comment" ]] && echo "# $comment" >>"$path"; echo "  - Desktop entry: $path"; }
create_waydroid_launchers() { local include_play_store="$1"; print_header "Creating Waydroid desktop launchers"
  write_desktop_file "/usr/share/applications/waydroid-full-ui.desktop" "Waydroid (Full UI)" "waydroid show-full-ui" "waydroid" "Launch full Android UI"
  if [[ "$include_play_store" == "true" ]]; then
    write_desktop_file "/usr/share/applications/waydroid-play-store.desktop" "Google Play Store (Waydroid)" "waydroid app launch com.android.vending" "waydroid" "Requires GAPPS image"
  fi
}
configure_waydroid_props() { local multi_windows="$1"; print_header "Tweaking Waydroid integration"
  if [[ "$multi_windows" == "true" ]]; then bash -lc 'waydroid prop set persist.waydroid.multi_windows true' >/dev/null 2>&1 || true; echo "  - Enabled multi-window integration for Android apps."; fi
}

# ------------------------------ Security (AppArmor + UFW) ------------------------------

configure_security() {
  print_header "Security hardening: AppArmor + UFW"
  ensure_packages_list apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra ufw >/dev/null 2>&1 || true
  append_kernel_params "apparmor=1" "security=apparmor" && echo "  - Ensured kernel args enable AppArmor (apparmor=1 security=apparmor)."
  echo "  - Enabling AppArmor service…"; systemctl enable --now apparmor >/dev/null 2>&1 || true
  echo "  - Enforcing AppArmor profiles…"
  bash -lc "find /etc/apparmor.d -maxdepth 1 -type f ! -name 'README' -print0 | xargs -0 --no-run-if-empty aa-enforce" >/dev/null 2>&1 || true
  systemctl reload apparmor >/dev/null 2>&1 || true
  echo "  - Configuring UFW default policy…"; ufw default deny incoming >/dev/null 2>&1 || true; ufw default allow outgoing >/dev/null 2>&1 || true
  if have_pkg openssh-server; then echo "  - OpenSSH detected; allowing and rate-limiting SSH in UFW."; ufw allow OpenSSH >/dev/null 2>&1 || true; ufw limit OpenSSH >/dev/null 2>&1 || true; else echo "  - OpenSSH not detected; SSH not opened in firewall."; fi
  echo "  - Enabling UFW…"; ufw --force enable >/dev/null 2>&1 || true; systemctl enable --now ufw >/dev/null 2>&1 || true
}

# ------------------------------ Privoxy ------------------------------

configure_privoxy() {
  print_header "Installing & configuring Privoxy"
  ensure_packages_list privoxy >/dev/null 2>&1 || true
  local cfg="/etc/privoxy/config"
  if [[ -f "$cfg" ]]; then
    sed -i 's|^listen-address .*|listen-address  127.0.0.1:8118|' "$cfg" || true
    grep -q '^toggle 1' "$cfg" || echo 'toggle 1' >> "$cfg"
    grep -q '^accept-intercepted-requests 0' "$cfg" || echo 'accept-intercepted-requests 0' >> "$cfg"
    grep -q '^enforce-blocks 1' "$cfg" || echo 'enforce-blocks 1' >> "$cfg"
  fi
  enable_now privoxy.service
  echo "  - Privoxy ready on http://127.0.0.1:8118"
  echo "    • Set system proxy (HTTP/HTTPS) to 127.0.0.1:8118 if you want it globally."
}

# ------------------------------ Snap (single prompt flow) ------------------------------

enable_snap_support() {
  print_header "Enabling Snap + GNOME Software plugin"
  ensure_packages_list snapd gnome-software-plugin-snap >/dev/null 2>&1 || true
  enable_now snapd.socket
  echo "  - Snap support enabled. Re-login may be required for /snap/bin on PATH."
}

remove_snap_support() {
  print_header "Removing Snap (snapd)"
  apt_purge_group snapd
}

apply_snap_choice() {
  case "$1" in
    enable) enable_snap_support ;;
    remove) remove_snap_support ;;
    keep)   echo "  - Snap unchanged." ;;
  esac
}

# ------------------------------ Microsoft-compatible stack ------------------------------

install_ms_compat() {
  print_header "Installing Microsoft-compatible stack"
  debian_enable_components_if_needed
  enable_i386_multiarch
  local fs_pkgs=(samba cifs-utils ntfs-3g exfatprogs dosfstools mtools)
  local wine_pkgs=(wine winetricks)
  local fonts_pkgs=(ttf-mscorefonts-installer cabextract)
  ensure_packages_list "${fs_pkgs[@]}" "${wine_pkgs[@]}" "${fonts_pkgs[@]}" >/dev/null 2>&1 || true
  echo "  - Samba tools, filesystem support, Wine, and MS Core Fonts installed."
  echo "    - Some components (e.g. MS Core Fonts) are proprietary or copyrighted."
  echo "      Please review the relevant EULAs and this project's LICENSE file."
}

# ------------------------------ Ubuntu-like Appearance ------------------------------

configure_ubuntu_look() {
  print_header "Ubuntu-like Fonts & Appearance"
  # Packages — add reliable monospace options too
  ensure_packages_list fonts-ubuntu fonts-cantarell fonts-noto-mono fonts-dejavu-core fonts-hack-ttf \
                       fontconfig-config gnome-tweaks yaru-theme-gtk yaru-theme-icon yaru-theme-sound >/dev/null 2>&1 || true

  # System-wide fontconfig tuning
  local fc="/etc/fonts/local.conf"
  cat >"$fc" <<'FCEOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
  </match>
</fontconfig>
FCEOF
  fc-cache -fv >/dev/null 2>&1 || true
  echo "  - Fontconfig tuned (slight hinting, RGB subpixel)."

  local target_user="${SUDO_USER:-}"
  if [[ -n "$target_user" ]]; then
    su - "$target_user" -c '
      eval "$(dbus-launch --sh-syntax 2>/dev/null || true)"

      # Desktop fonts + theme
      gsettings set org.gnome.desktop.interface font-name "Ubuntu 11" >/dev/null 2>&1 || true
      gsettings set org.gnome.desktop.interface document-font-name "Ubuntu 11" >/dev/null 2>&1 || true
      gsettings set org.gnome.settings-daemon.plugins.xsettings antialiasing "rgba" >/dev/null 2>&1 || true
      gsettings set org.gnome.settings-daemon.plugins.xsettings hinting "slight" >/dev/null 2>&1 || true
      gsettings set org.gnome.settings-daemon.plugins.xsettings rgba-order "rgb" >/dev/null 2>&1 || true
      gsettings set org.gnome.desktop.interface gtk-theme "Yaru" >/dev/null 2>&1 || true
      gsettings set org.gnome.desktop.interface icon-theme "Yaru" >/dev/null 2>&1 || true
      gsettings set org.gnome.desktop.interface cursor-theme "Yaru" >/dev/null 2>&1 || true
      gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" >/dev/null 2>&1 || true

      # Choose a present monospace
      CANDIDATES=("Ubuntu Mono" "Noto Mono" "DejaVu Sans Mono" "Hack" "Liberation Mono" "Nimbus Mono PS" "Monospace")
      pick_font() { for f in "${CANDIDATES[@]}"; do fc-list ":family=$f" | grep -qi . && { echo "$f"; return; }; done; echo "Monospace"; }
      FONT="$(pick_font) 12"

      # System monospace + GNOME Terminal profile
      gsettings set org.gnome.desktop.interface monospace-font-name "$FONT" >/dev/null 2>&1 || true
      if gsettings writable org.gnome.Terminal.ProfilesList default >/dev/null 2>&1; then
        PID=$(gsettings get org.gnome.Terminal.ProfilesList default | tr -d "'\''")
        SCHEMA="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:$PID/"
        gsettings set "$SCHEMA" use-system-font false >/dev/null 2>&1 || true
        gsettings set "$SCHEMA" font "$FONT" >/dev/null 2>&1 || true
      fi

      # Clean up temp session bus
      [[ -n "$DBUS_SESSION_BUS_PID" ]] && kill "$DBUS_SESSION_BUS_PID" >/dev/null 2>&1 || true
    '
    echo "  - Applied Yaru theme + Ubuntu fonts for user: $target_user"
  else
    echo "  ! Could not detect invoking user; installed themes & fonts system-wide."
    echo "    Open GNOME Tweaks → Appearance & Fonts to select Yaru + Ubuntu."
  fi

  ensure_packages_list gnome-shell-extension-manager gnome-shell-extension-appindicator gnome-shell-extension-dash-to-dock >/dev/null 2>&1 || true
  echo "  - You can enable AppIndicator & Dash-to-Dock via ‘Extensions’ or Extension Manager."
}

# ------------------------------ Main ------------------------------

main() {
  if [[ $EUID -ne 0 ]]; then echo "This script must be run as root (sudo). Aborting."; exit 1; fi
  if ! have_systemctl; then echo "systemctl not found. This script targets systemd-based systems."; exit 1; fi

  read_os

  print_header "Minimal Desktop systemd Profile (Interactive)"
  echo "This sets up a lean GNOME desktop: services, quieter boot, Plymouth,"
  echo "optional Flatpak migration, Waydroid, security hardening, plus requested extras."
  echo
  echo "For proprietary or copyrighted apps/fonts (e.g. Steam via Flatpak, MS Core Fonts),"
  echo "please review this project's LICENSE file and the vendor EULAs."
  echo
  echo "Press Enter to accept defaults shown in brackets."
  echo

  # Defaults
  local d_networkmanager=true
  local d_disable_wait_online=true
  local d_timesyncd=true
  local d_bluetooth=false
  local d_printing=false
  local d_avahi=false
  local d_modemmanager=false
  local d_power_profiles=true
  local d_tlp=false
  local d_reduce_boot_spam=true
  local d_plymouth=true
  local d_flatpak_shift=true
  local d_waydroid=false
  local d_waydroid_gapps=true
  local d_waydroid_multi_windows=true
  local d_security=true

  # NEW defaults for extra asks
  local d_privoxy=false
  local d_ms_compat=true
  local d_ubuntu_look=true # Ubuntu-like appearance (fonts + Yaru)

  # Units
  local nm_units=("NetworkManager.service")
  local wait_units=("NetworkManager-wait-online.service" "systemd-networkd-wait-online.service")
  local timesyncd_units=("systemd-timesyncd.service")
  local chrony_units=("chronyd.service" "chrony.service")
  local ntp_units=("ntp.service" "ntpd.service")
  local bt_units=("bluetooth.service")
  local printing_units=("cups.service" "org.cups.cupsd.service")
  local cups_browsed_units=("cups-browsed.service")
  local avahi_units=("avahi-daemon.service")
  local mm_units=("ModemManager.service")
  local ppd_units=("power-profiles-daemon.service")
  local tlp_units=("tlp.service")
  local plymouth_waits=("plymouth-quit-wait.service" "plymouth-quit.service")

  local enable_list=() disable_list=() mask_list=()

  # Networking
  yn "Use NetworkManager for networking?" "$d_networkmanager" && { local u; for u in "${nm_units[@]}"; do unit_exists "$u" && enable_list+=("$u"); done; }
  yn "Disable network 'wait-online' services (faster boots)?" "$d_disable_wait_online" && { local u; for u in "${wait_units[@]}"; do unit_exists "$u" && disable_list+=("$u"); done; }

  # Time sync
  if yn "Use systemd-timesyncd for time sync (recommended)?" "$d_timesyncd"; then
    local u; u="$(first_existing "${timesyncd_units[@]}")" && enable_list+=("$u")
    for u in "${chrony_units[@]}" "${ntp_units[@]}"; do unit_exists "$u" && disable_list+=("$u"); done
  fi

  # Bluetooth
  if yn "Enable Bluetooth support?" "$d_bluetooth"; then local u; u="$(first_existing "${bt_units[@]}")" && enable_list+=("$u")
  else local u; for u in "${bt_units[@]}"; do unit_exists "$u" && disable_list+=("$u"); done; fi

  # Printing
  if yn "Enable printing (CUPS)?" "$d_printing"; then
    local u; u="$(first_existing "${printing_units[@]}")" && enable_list+=("$u")
    yn "  Also enable cups-browsed (printer auto-discovery)?" false && { u="$(first_existing "${cups_browsed_units[@]}")" && enable_list+=("$u"); }
  else
    local u; for u in "${printing_units[@]}" "${cups_browsed_units[@]}"; do unit_exists "$u" && disable_list+=("$u"); done
  fi

  # Avahi
  if yn "Enable Avahi/mDNS (AirPrint, .local names)?" "$d_avahi"; then local u; u="$(first_existing "${avahi_units[@]}")" && enable_list+=("$u")
  else local u; for u in "${avahi_units[@]}"; do unit_exists "$u" && disable_list+=("$u"); done; fi

  # ModemManager
  if yn "Enable ModemManager (WWAN dongles)?" "$d_modemmanager"; then local u; u="$(first_existing "${mm_units[@]}")" && enable_list+=("$u")
  else local u; for u in "${mm_units[@]}"; do unit_exists "$u" && disable_list+=("$u"); done; fi

  # Power management
  local ppd_exists=false tlp_exists=false
  first_existing "${ppd_units[@]}" >/dev/null 2>&1 && ppd_exists=true
  first_existing "${tlp_units[@]}" >/dev/null 2>&1 && tlp_exists=true
  if $ppd_exists && yn "Enable power-profiles-daemon?" "$d_power_profiles"; then
    local u; u="$(first_existing "${ppd_units[@]}")" && enable_list+=("$u")
    $tlp_exists && { local u; for u in "${tlp_units[@]}"; do unit_exists "$u" && disable_list+=("$u"); done; }
  elif $tlp_exists && yn "Enable TLP (great for laptops)?" "$d_tlp"; then
    local u; u="$(first_existing "${tlp_units[@]}")" && enable_list+=("$u")
    $ppd_exists && { local u; for u in "${ppd_units[@]}"; do unit_exists "$u" && disable_list+=("$u"); done; }
  else
    local u; for u in "${ppd_units[@]}" "${tlp_units[@]}"; do unit_exists "$u" && disable_list+=("$u"); done
  fi

  # Optional: reduce boot spam
  local reduce_boot=false; yn "Reduce boot spam (keep important messages)?" "$d_reduce_boot_spam" && reduce_boot=true

  # Optional: mask plymouth waits
  local mask_plymouth=false
  if $reduce_boot || yn "Mask Plymouth 'quit-wait' units (avoids some shutdown hangs)?" true; then mask_plymouth=true; fi

  # Optional: Plymouth
  local use_plymouth=false; yn "Enable Plymouth splash with Debian's default 'debian-text' theme?" "$d_plymouth" && use_plymouth=true

  # Optional: Ubuntu-like appearance
  local do_ubuntu_look=false; yn "Make Debian look like Ubuntu (fonts+Yaru, dark mode)?" "$d_ubuntu_look" && do_ubuntu_look=true

  # Optional: Flatpak migration
  local do_flatpak_shift=false; yn "Purge some APT apps and switch to Flatpaks where possible?" "$d_flatpak_shift" && do_flatpak_shift=true

  # Optional: Waydroid
  local do_waydroid=false want_gapps=false want_multiwin=false
  if yn "Install Waydroid to run Android apps?" "$d_waydroid"; then
    do_waydroid=true
    yn "  Use GAPPS image to get Google Play Store?" "$d_waydroid_gapps" && want_gapps=true
    yn "  Enable windowed Android apps (multi-window integration)?" "$d_waydroid_multi_windows" && want_multiwin=true
  fi

  # Optional: security
  local do_security=false; yn "Apply security hardening (AppArmor enforcing + UFW sane defaults)?" "$d_security" && do_security=true

  # Privoxy
  local do_privoxy=false; yn "Install & enable Privoxy (local HTTP/HTTPS proxy on 127.0.0.1:8118)?" "$d_privoxy" && do_privoxy=true

  # Snap: ask ONCE (Enable / Remove / Keep)
  local snap_choice; snap_choice="$(choose_snap_mode)"

  # MS-compatible stack
  local do_ms_compat=false; yn "Install Samba/NTFS/exFAT/FAT32 tools + Wine + DOSBox + MS Core Fonts?" "$d_ms_compat" && do_ms_compat=true

  # Deduplicate service actions
  declare -A enable_set disable_set mask_set
  local x
  for x in "${enable_list[@]}"; do unit_exists "$x" && enable_set["$x"]=1; done
  for x in "${disable_list[@]}"; do unit_exists "$x" && disable_set["$x"]=1; done
  $mask_plymouth && { for x in "${plymouth_waits[@]}"; do unit_exists "$x" && mask_set["$x"]=1; done; }
  for x in "${!enable_set[@]}"; do unset "disable_set[$x]" "mask_set[$x]"; done

  print_header "Planned changes"
  if ((${#enable_set[@]})); then echo "Enable & start:"; for x in "${!enable_set[@]}"; do print_action "enable" "$x"; done; fi
  if ((${#disable_set[@]})); then echo; echo "Disable & stop:"; for x in "${!disable_set[@]}"; do print_action "disable" "$x"; done; fi
  if ((${#mask_set[@]})); then echo; echo "Mask:"; for x in "${!mask_set[@]}"; do print_action "mask" "$x"; done; fi
  echo; echo "Snap action: $snap_choice"
  [[ $(( ${#enable_set[@]} + ${#disable_set[@]} + ${#mask_set[@]} )) -eq 0 ]] && echo "(No service changes; nothing applicable on this system.)"

  if ! yn_strict $'\nProceed with these changes?'; then echo "Aborted. No changes made."; exit 0; fi

  # Apply service changes
  print_header "Applying changes"
  for x in "${!enable_set[@]}"; do print_action "enable" "$x"; enable_now "$x"; done
  for x in "${!disable_set[@]}"; do print_action "disable" "$x"; unmask_unit "$x"; disable_now "$x"; done
  for x in "${!mask_set[@]}"; do print_action "mask" "$x"; mask_unit "$x"; done

  # Boot spam reduction
  $reduce_boot && reduce_boot_spam "false"

  # Plymouth
  $use_plymouth && configure_plymouth "debian-text"

  # Ubuntu look
  $do_ubuntu_look && configure_ubuntu_look

  # Flatpak setup/migration
  if $do_flatpak_shift; then
    ensure_flatpak_setup
    offer_purge_groups
    install_flatpak_firefox
    print_header "Flatpak migration tips"
    echo "• Open GNOME Software → ‘Add-ons’ to confirm Flatpak is enabled."
    echo "• Browse apps in GNOME Software (they’ll prefer Flathub sources)."
    echo "• CLI example (VLC):       flatpak install flathub org.videolan.VLC"
    echo "• CLI example (Steam):     flatpak install flathub com.valvesoftware.Steam"
    echo "    Steam and similar apps are proprietary; please review their EULAs"
    echo "    as well as this project's LICENSE file before installing."
  fi

  # Extras
  $do_privoxy && configure_privoxy
  apply_snap_choice "$snap_choice"
  $do_ms_compat && install_ms_compat

  # Waydroid
  if $do_waydroid; then
    if ensure_waydroid_repo_and_install; then
      waydroid_init "$want_gapps"
      ensure_waydroid_service
      configure_waydroid_props "$want_multiwin"
      create_waydroid_launchers "$want_gapps"
      print_header "Waydroid notes"
      echo "• Launch 'Waydroid (Full UI)' from your applications grid."
      $want_gapps && echo "• Launch 'Google Play Store (Waydroid)' to sign in."
      echo "• CLI: waydroid app list / waydroid app launch <pkg>."
    else
      echo "  ! Skipped Waydroid configuration due to install error."
    fi
  fi

  # Security last
  $do_security && configure_security

  print_header "Done"
  echo "After reboot, review startup/shutdown with:"
  echo "  systemd-analyze blame"
  echo "  systemd-analyze critical-chain"
  echo "  journalctl -b -1 -xe   # previous boot logs (run after the next reboot)"
}

main "$@"
