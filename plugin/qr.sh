#!/usr/bin/env bash
# Emits the hotspot QR: a metadata line then a 0/1 module matrix, in the
# same format as omarchy-network-qr so the panel can render it natively.
# Payload follows the WIFI: scheme used by Android/iOS scanners.
set -euo pipefail

SSID="OmarchyHotspot"
PASS_FILE="/var/lib/omarchy-hotspot/password"

pass="$(cat "$PASS_FILE" 2>/dev/null || true)"
[ -n "$pass" ] || { echo "No hotspot password yet — start the hotspot first" >&2; exit 1; }

escape() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  v="${v//;/\\;}"
  v="${v//,/\\,}"
  v="${v//:/\\:}"
  printf '%s' "$v"
}

payload="WIFI:T:WPA;S:$(escape "$SSID");P:$(escape "$pass");;"

printf 'meta\tap0\tWPA\t%s\n' "$SSID"

ascii="$(printf '%s' "$payload" | qrencode --type ASCII --margin 4 --output -)"
while IFS= read -r line; do
  row=""
  for ((col = 0; col < ${#line}; col += 2)); do
    [[ ${line:col:2} == *#* ]] && row+="1" || row+="0"
  done
  printf '%s\n' "$row"
done <<<"$ascii"
