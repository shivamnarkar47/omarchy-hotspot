#!/usr/bin/env bash
# Omarchy Hotspot installer — system bits.
# (The bar widget itself installs via: omarchy plugin add <repo-url>)
# Installs the root helper, the passwordless polkit rule, and the
# NetworkManager exemption for the AP virtual interface.
set -euo pipefail

REPO_DIR="$(dirname "$(readlink -f "$0")")"
HELPER_SRC="$REPO_DIR/src/omarchy-hotspot-helper"
RULES_SRC="$REPO_DIR/config/50-omarchy-hotspot.rules"
NM_CONF_SRC="$REPO_DIR/config/99-unmanaged-ap0.conf"
if (( EUID != 0 )); then
  exec pkexec "$0" "$@"
fi

# pkexec clears the environment and runs as root, so $USER/$(whoami) would be
# "root" here and the polkit rule would match the wrong subject. pkexec exports
# PKEXEC_UID for the real caller; fall back to SUDO_USER / logname / id.
if [ -n "${PKEXEC_UID:-}" ]; then
  USER="$(id -nu "$PKEXEC_UID")"
elif [ -n "${SUDO_USER:-}" ]; then
  USER="$SUDO_USER"
elif logname >/dev/null 2>&1; then
  USER="$(logname)"
else
  USER="$(id -un)"
fi

echo "==> Installing packages (hostapd, dnsmasq)"
pacman -S --noconfirm --needed hostapd dnsmasq

echo "==> Installing helper to /usr/local/bin"
install -m 755 "$HELPER_SRC" /usr/local/bin/omarchy-hotspot-helper

echo "==> Installing polkit rule (passwordless pkexec for the helper)"
# Use awk (not sed) so the username is treated as a fixed string, never as a
# regex or replacement pattern.
awk -v u="$USER" '{ gsub(/__USER__/, u) } 1' "$RULES_SRC" > /etc/polkit-1/rules.d/50-omarchy-hotspot.rules
chmod 644 /etc/polkit-1/rules.d/50-omarchy-hotspot.rules

echo "==> Telling NetworkManager to leave ap0 alone"
install -m 644 "$NM_CONF_SRC" /etc/NetworkManager/conf.d/99-unmanaged-ap0.conf
nmcli general reload || true

echo
echo "Done! Now install the widget with:"
echo "  omarchy plugin add https://github.com/shivamnarkar47/omarchy-hotspot"
echo "  omarchy plugin enable io.github.shivamnarkar47.omarchy-hotspot --section right"
