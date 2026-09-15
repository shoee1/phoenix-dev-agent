#!/bin/bash
set -euo pipefail

HOTFIX_URL="https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/fa7b4f304eaaf959305d6b085256896e1cb41a16/release/hotfixes/phoenix-dev-v1.3.0-repeat-build-hotfix-v3.sh"
HOTFIX_SHA256="377c7adc5893f4979cc5f8ce012f5ff764ea9fd48ebaab48b137dc23f0af3fbd"
TMP="$(mktemp /tmp/phoenix-dev-finalize.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

for c in curl sha256sum awk docker jq phoenix-dev bash; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required."
done

log "Fetching verified Phoenix repeat-build fix"
curl --fail --show-error --location --connect-timeout 15 --retry 3 \
  "$HOTFIX_URL?cb=$(date +%s)-$$" -o "$TMP"
GOT="$(sha256sum "$TMP" | awk '{print $1}')"
[[ "$GOT" == "$HOTFIX_SHA256" ]] || fail "Hotfix checksum mismatch. Expected $HOTFIX_SHA256, got $GOT."
chmod +x "$TMP"

log "Installing tested repeat-build checkpoint fix"
bash "$TMP"

status_json="$(phoenix-dev status)" || fail "Phoenix status failed after hotfix."
echo "$status_json"
echo "$status_json" | jq -e '.agent.ok == true and .broker.ok == true' >/dev/null \
  || fail "Phoenix agent/broker are not healthy."

validate_project() {
  local pid="$1" container="$2"
  local before_image after_image result

  before_image="$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null || true)"
  [[ -n "$before_image" ]] || fail "Production container not found: $container"

  log "Repeat-build validation: $pid"
  phoenix-dev build "$pid"

  after_image="$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null || true)"
  [[ "$after_image" == "$before_image" ]] \
    || fail "Production image changed during non-production build validation for $pid."

  result="$(phoenix-dev dev-status "$pid")"
  echo "$result"
  echo "$result" | jq -e '
    .adoption.baseline_verified == true
    and .development.build_verified == true
    and .actions.test == true
    and .actions.build == true
    and .latest_build.source_verified == true
    and .latest_build.runtime_config_verified == true
    and .latest_build.syntax_smoke_verified == true
    and .latest_build.production_untouched == true
  ' >/dev/null || fail "Development workflow validation failed for $pid."
}

validate_project "3d-ai-optimizer" "x2d-ai-optimizer"
validate_project "filament-buyer" "filament-buyer"

log "Phoenix development loop validated"
echo "3D AI Optimizer: READY"
echo "Filament Buyer: READY"
echo "Production containers: UNTOUCHED"
echo "Phoenix infrastructure status: FROZEN pending a genuine blocker or bundled future upgrade"
