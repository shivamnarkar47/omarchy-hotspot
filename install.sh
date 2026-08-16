#!/usr/bin/env bash
# Omarchy Hotspot installer.
# Installs the root helper, the passwordless polkit rule, and the
# NetworkManager exemption for the AP virtual interface.
set -euo pipefail

HELPER_SRC="$(dirname "$(readlink -f "$0")")/src/omarchy-hotspot-helper"
RULES_SRC="$(dirname "$(readlink -f "$0")")/config/50-omarchy-hotspot.rules"
NM_CONF_SRC="$(dirname "$(readlink -f "$0")")/config/99-unmanaged-ap0.conf"
USER="${SUDO_USER:-$(whoami)}"

echo "==> Installing packages (hostapd, dnsmasq)"
pacman -S --noconfirm --needed hostapd dnsmasq

echo "==> Installing helper to /usr/local/bin"
install -m 755 "$HELPER_SRC" /usr/local/bin/omarchy-hotspot-helper

echo "==> Installing polkit rule (passwordless pkexec for the helper)"
sed "s/__USER__/$USER/g" "$RULES_SRC" > /etc/polkit-1/rules.d/50-omarchy-hotspot.rules
chmod 644 /etc/polkit-1/rules.d/50-omarchy-hotspot.rules

echo "==> Telling NetworkManager to leave ap0 alone"
install -m 644 "$NM_CONF_SRC" /etc/NetworkManager/conf.d/99-unmanaged-ap0.conf
nmcli general reload || true

echo "==> Installing the bar plugin"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/local.hotspot"
mkdir -p "$PLUGIN_DIR"
cp "$(dirname "$(readlink -f "$0")")/plugin/"* "$PLUGIN_DIR/"
chmod +x "$PLUGIN_DIR/qr.sh"
omarchy plugin enable local.hotspot --section right || true

echo
echo "Done! Click the hotspot icon in the bar."
echo "SSID: OmarchyHotspot (password shown in the popup / QR code)"
