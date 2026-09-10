#!/usr/bin/env bash
# Omarchy Hotspot installer — system bits.
# (The bar widget itself installs via: omarchy plugin add <repo-url>)
# Installs the root helper, the passwordless polkit rule, and the
# NetworkManager exemption for the AP virtual interface.
set -euo pipefail

REPO_DIR="$(dirname "$(readlink -f "$0")")"
HELPER_SRC="$REPO_DIR/src/omarchy-hotspot-helper"
RULES_SRC="$REPO_DIR/config/50-omarchy-hotspot.rules"
NM_CONF_DIR="/etc/NetworkManager/conf.d"
# zz- prefix sorts last in conf.d so this file wins over other plugins that
# set unmanaged-devices (e.g. lerd-dns-link.conf). NM does NOT merge that key
# across files — the last file wins — so we must merge here (see below).
NM_CONF_NEW="$NM_CONF_DIR/zz-omarchy-hotspot-unmanaged.conf"
NM_CONF_OLD="$NM_CONF_DIR/99-unmanaged-ap0.conf"
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

echo "==> Telling NetworkManager to leave ap0 alone (merging unmanaged-devices)"
# NetworkManager does not merge `unmanaged-devices` across conf.d files: the
# lexicographically last file wins. Blindly installing our own file (e.g.
# 99-unmanaged-ap0.conf) means another plugin's file (e.g. lerd-dns-link.conf
# with only lerd0) silently re-manages ap0, leaving a stale managed-type ap0
# behind. Then `ip link set ap0 up` fails with:
#   RTNETLINK answers: Device or resource busy
# and hostapd can never start. Collect existing entries, preserve them, ensure
# ap0 is present, and write to a zz- file that sorts last.
merge_unmanaged_devices() {
  local existing="" entry norm f key value
  shopt -s nullglob
  for f in "$NM_CONF_DIR"/*.conf /etc/NetworkManager/NetworkManager.conf; do
    [ -r "$f" ] || continue
    while IFS='=' read -r key value; do
      # trim whitespace from key
      key="$(printf '%s' "$key" | tr -d '[:space:]')"
      [ "$key" = "unmanaged-devices" ] || continue
      existing+="${value};"
    done < <(grep -hE '^[[:space:]]*unmanaged-devices[[:space:]]*=' "$f" 2>/dev/null || true)
  done
  shopt -u nullglob

  local merged="interface-name:ap0"
  # Split on comma, semicolon, and whitespace.
  while IFS= read -r entry; do
    norm="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$norm" ] || continue
    case ";${merged};" in
      *";${norm};"*) continue ;;
    esac
    merged="${merged};${norm}"
  done < <(printf '%s' "$existing" | tr ',;' '\n')

  printf '[keyfile]\n# Managed by omarchy-hotspot install.sh — merged to survive\n# other plugins that also set unmanaged-devices (last file in conf.d wins).\nunmanaged-devices=%s\n' "$merged" >"$NM_CONF_NEW"
  chmod 644 "$NM_CONF_NEW"
  # Drop the legacy file superseded by the zz- file.
  if [ "$NM_CONF_OLD" != "$NM_CONF_NEW" ] && [ -e "$NM_CONF_OLD" ]; then
    rm -f "$NM_CONF_OLD"
  fi
  echo "    unmanaged-devices=${merged}"
}
merge_unmanaged_devices
nmcli general reload || true
if NetworkManager --print-config 2>/dev/null | grep -q 'interface-name:ap0'; then
  echo "    NetworkManager exempts ap0 OK"
else
  echo "    WARNING: NetworkManager config does not list ap0 yet — check 'NetworkManager --print-config | grep unmanaged'" >&2
fi
# A previous failed start may have left ap0 behind as type managed (NM-owned).
# The helper recreates it as type __ap on next start only if it is gone.
iw dev ap0 del 2>/dev/null || true

echo
echo "Done! Now install the widget with:"
echo "  omarchy plugin add https://github.com/shivamnarkar47/omarchy-hotspot"
echo "  omarchy plugin enable io.github.shivamnarkar47.omarchy-hotspot --section right"
