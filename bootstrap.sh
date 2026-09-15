#!/bin/bash
set -euo pipefail

DEFAULT_RELEASE_BASE_URL="https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/main/release"
BASE="${PDA_RELEASE_BASE_URL:-${1:-}}"
ACTION="${2:-install}"
PDA_BASE_DIR="${PDA_BASE:-/mnt/user/appdata/phoenix-dev-agent}"
PDA_ENV_FILE="$PDA_BASE_DIR/config/phoenix.env"

if [[ -z "$BASE" ]]; then
  BASE="$DEFAULT_RELEASE_BASE_URL"
fi
[[ -n "$BASE" ]] || { echo "ERROR: No Phoenix release URL configured." >&2; exit 1; }
BASE="${BASE%/}"
[[ "$BASE" == https://* || "$BASE" == http://* ]] || { echo "ERROR: Release URL must be http(s)." >&2; exit 1; }
for c in curl awk sha256sum mktemp; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required." >&2; exit 1; }; done

port_busy() {
  local p="$1"
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Ports}}' 2>/dev/null | grep -Fq ":${p}->"; then
    return 0
  fi
  if command -v ss >/dev/null 2>&1 && ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${p}$"; then
    return 0
  fi
  return 1
}

select_first_install_port() {
  # If the caller explicitly supplied PDA_PORT, respect it exactly.
  if [[ -n "${PDA_PORT:-}" ]]; then
    return 0
  fi

  local desired="8787"
  if [[ -f "$PDA_ENV_FILE" ]]; then
    desired="$(awk -F= '$1=="PDA_PORT" {print $2; exit}' "$PDA_ENV_FILE" 2>/dev/null || true)"
    desired="${desired:-8787}"
  fi

  # If Phoenix Dev Agent is already running, this is an update/repair and its
  # existing published port is expected to be occupied by itself.
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq 'phoenix-dev-agent'; then
    export PDA_PORT="$desired"
    return 0
  fi

  if ! port_busy "$desired"; then
    export PDA_PORT="$desired"
    return 0
  fi

  local candidate
  for candidate in $(seq 8788 8899); do
    if ! port_busy "$candidate"; then
      echo "Port $desired is already in use; Phoenix Dev Agent will use port $candidate instead."
      export PDA_PORT="$candidate"
      if [[ -f "$PDA_ENV_FILE" ]]; then
        if grep -q '^PDA_PORT=' "$PDA_ENV_FILE"; then
          sed -i "s/^PDA_PORT=.*/PDA_PORT=$candidate/" "$PDA_ENV_FILE"
        else
          printf '\nPDA_PORT=%s\n' "$candidate" >> "$PDA_ENV_FILE"
        fi
      fi
      return 0
    fi
  done

  echo "ERROR: No free Phoenix Dev Agent UI port found in 8787-8899." >&2
  exit 1
}

select_first_install_port

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
exec env PDA_RELEASE_BASE_URL="$BASE" PDA_PORT="${PDA_PORT:-8787}" bash "$inst" "$ACTION"
