#!/bin/bash
set -euo pipefail
DEFAULT_RELEASE_BASE_URL="https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/main/release"
BASE="${PDA_RELEASE_BASE_URL:-${1:-}}"
ACTION="${2:-install}"
if [[ -z "$BASE" && "$DEFAULT_RELEASE_BASE_URL" != "https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/main/release" ]]; then
  BASE="$DEFAULT_RELEASE_BASE_URL"
fi
[[ -n "$BASE" ]] || { echo "ERROR: No Phoenix release URL configured." >&2; exit 1; }
BASE="${BASE%/}"
[[ "$BASE" == https://* || "$BASE" == http://* ]] || { echo "ERROR: Release URL must be http(s)." >&2; exit 1; }
for c in curl awk sha256sum mktemp; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required." >&2; exit 1; }; done
mf="$(mktemp /tmp/phoenix-dev-manifest.XXXXXX)"
inst="$(mktemp /tmp/phoenix-dev-installer.XXXXXX.sh)"
trap 'rm -f "$mf" "$inst"' EXIT
curl --fail --show-error --location --connect-timeout 15 --retry 3 "$BASE/latest.env" -o "$mf"
sha="$(awk -F= '$1=="PDA_INSTALLER_SHA256" {print $2}' "$mf")"
[[ "$sha" =~ ^[a-fA-F0-9]{64}$ ]] || { echo "ERROR: Invalid installer checksum in release manifest." >&2; exit 1; }
curl --fail --show-error --location --connect-timeout 15 --retry 3 "$BASE/install-phoenix-dev-agent.sh" -o "$inst"
got="$(sha256sum "$inst" | awk '{print $1}')"
[[ "$got" == "$sha" ]] || { echo "ERROR: Installer checksum mismatch." >&2; exit 1; }
chmod +x "$inst"
exec env PDA_RELEASE_BASE_URL="$BASE" bash "$inst" "$ACTION"
