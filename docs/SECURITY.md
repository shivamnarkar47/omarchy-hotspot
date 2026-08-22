# Security

This document describes the security hardening applied to the Mobile Hotspot
plugin in response to the marketplace security review. It is meant both as a
transparency record for reviewers and as an operational reference.

## Threat model

- The plugin runs a small **root helper** (`/usr/local/bin/omarchy-hotspot-helper`)
  so the bar can manage the `ap0` virtual interface, `hostapd`, and `dnsmasq`
  without the user typing a password each time. A scoped, passwordless polkit
  rule authorizes *only* that helper for *only* the installing user.
- The WPA passphrase is a secret: it must be usable by the owner (shown in the
  UI, rendered into the join QR, and copied to the clipboard) but must **not**
  be readable by other local users, leaked through the process command line, or
  injectable into configuration files.

## Fixes applied

| # | Issue | Fix |
|---|-------|-----|
| 1 | The `install.sh` → `pkexec` path recomputed `USER` as `root`, installing a non-functional polkit rule for `subject.user == "root"`. | `install.sh` resolves the real caller via `PKEXEC_UID` (with `SUDO_USER` → `logname` → `id` fallbacks) *after* the `pkexec` re-exec, so the rule targets the actual desktop user. The rule is scoped to `program == /usr/local/bin/omarchy-hotspot-helper` **and** `subject.user == <installer>`. |
| 2 | The helper accepted unbounded / control-character passphrases, interpolated them into `hostapd.conf`, and stored the credential world-readable (`644`). | Passphrases are validated as **8–63 bytes of printable ASCII**. Validation compares *total* vs *printable* byte counts, so an **embedded newline** (which `grep`/command-substitution treat as a line break) is still caught — this prevents `hostapd.conf` injection. The password file is written `600` and **owned by the calling user** (`protect_passfile`), so it is no longer world-readable yet remains usable by the bar for the join QR. |
| 3 | Helper-derived text in the panel was rendered with default (rich-text) formatting, allowing injection if the helper output were malicious. | All helper-derived `Text` elements use `textFormat: Text.PlainText` (SSID, status line, password, password error, and the shared `DetailValue` component). |
| 4 | The passphrase was embedded in a `bash -c` command and passed as `set-password` **argv**, exposing it via process command-line inspection. | `set-password` reads the passphrase from **stdin** (a single line). The panel feeds it over the `Process` stdin channel instead of argv. `copyPassword` reads the passphrase from the secret file (`cat … \| wl-copy`) rather than embedding it. |
| 5 | `status` echoed the passphrase back to the bar over the `pkexec` stdout channel. | `status` no longer prints the passphrase. The bar reads it directly from the user-owned secret file via a dedicated `passReadProc`. |
| 6 | The passwordless `pkexec` path exposed diagnostic subcommands (`debug`/`sniff`/`test`) that can read `hostapd.conf` or capture traffic. | The helper restricts the passwordless path to `status` / `toggle` / `set-password`. `debug`/`sniff`/`test` are rejected over `pkexec` ("Subcommand '…' is not permitted via pkexec") but remain available to a direct root invocation (e.g. `sudo omarchy-hotspot-helper debug`). |
| 7 | `install.sh` interpolated the username into a `sed` replacement (regex/`&` interpretation risk). | The polkit rule is generated with `awk -v`, treating the username as a fixed string. |
| 8 | WIFI QR payload escaping omitted the double quote. | `qr.sh` now also escapes `"` per the WIFI QR standard. |

## Runtime file permissions

- `/var/lib/omarchy-hotspot/password` — `600`, owned by the installing user.
  Contains the WPA passphrase.
- `/run/omarchy-hotspot/` — `700` (root). `hostapd.conf` inside is `600` and
  contains the same passphrase; it is only read by root-owned `hostapd`.
- `/usr/local/bin/omarchy-hotspot-helper` — `755`, root-owned and not writable
  by unprivileged users, so it cannot be replaced (TOCTOU-safe).

## Notes for reviewers

- No network fetches, `eval`, `rm -rf`, or world-writable temp files are used.
- The polkit rule grants passwordless root **only** to the helper binary for
  the installing user; other local users are not authorized.
