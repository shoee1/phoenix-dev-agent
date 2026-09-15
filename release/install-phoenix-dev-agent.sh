#!/bin/bash
set -euo pipefail

BASE="${PDA_BASE:-/mnt/user/appdata/phoenix-dev-agent}"
WORKSPACE="${PDA_WORKSPACE:-/mnt/user/dev/phoenix-projects}"
VERSION="1.0.8"
GENERIC_URL="https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/9966cc18c34743addd2bc3f32f7a9c97ce770dd2/release/install-phoenix-dev-agent.sh"
GENERIC_SHA256="11973de5a064a47bdd41b526f65f6aa349e433563805f77147de57f5ffa23ebc"
ACTION="${1:-install}"
TMP="$(mktemp /tmp/phoenix-dev-v108-base.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

log() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for c in docker curl sha256sum awk grep sed; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required."
done

log "Fetching verified Phoenix Dev Agent base installer"
curl --fail --show-error --location --connect-timeout 15 --retry 3 \
  "$GENERIC_URL?cb=$(date +%s%N 2>/dev/null || date +%s)" -o "$TMP"
got="$(sha256sum "$TMP" | awk '{print $1}')"
[[ "$got" == "$GENERIC_SHA256" ]] || die "Base installer checksum mismatch. Expected $GENERIC_SHA256, got $got."
chmod +x "$TMP"

# Stage/build/start the release through the already-verified v1.0.6 installer.
# The manifest version is v1.0.8, so its runtime is isolated at runtime/1.0.8.
env PDA_RELEASE_BASE_URL="${PDA_RELEASE_BASE_URL:-https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/main/release}" \
    PDA_PORT="${PDA_PORT:-8787}" \
    bash "$TMP" "$ACTION"

case "$ACTION" in
  install|update|repair) ;;
  *) exit 0 ;;
esac

RUNTIME="$BASE/runtime/$VERSION"
MAIN="$RUNTIME/agent/main.py"
HELPER_RUNTIME="$RUNTIME/phoenix-dev"
HELPER_ACTIVE="$BASE/bin/phoenix-dev"
ENVFILE="$BASE/config/phoenix.env"

[[ -f "$MAIN" ]] || die "v$VERSION agent source not found at $MAIN"
[[ -f "$ENVFILE" ]] || die "Phoenix environment file not found at $ENVFILE"

log "Applying verified Phoenix v$VERSION source fixes"
docker run --rm -i \
  -e "PDA_RELEASE_VERSION=$VERSION" \
  -v "$RUNTIME/agent:/src:rw" \
  --entrypoint python \
  "phoenix-dev-agent:$VERSION" - /src/main.py <<'PY'
from pathlib import Path
import os, sys

p = Path(sys.argv[1])
s = p.read_text()
version = os.environ["PDA_RELEASE_VERSION"]

replacements = [
    (
        'APP_VERSION = "1.0.0"',
        f'APP_VERSION = "{version}"',
        "APP_VERSION",
    ),
    (
        '    cmd=["codex","exec","--json","-C",str(ws)]',
        '    cmd=["codex","exec","--json","--skip-git-repo-check","-C",str(ws)]',
        "Codex trusted-directory compatibility",
    ),
    (
        '    if full_auto: cmd.append("--full-auto")',
        '    if full_auto: cmd.extend(["--sandbox","read-only"])',
        "Codex read-only automation",
    ),
]

for old, new, label in replacements:
    if old in s:
        s = s.replace(old, new, 1)
    elif new not in s:
        raise SystemExit(f"Expected source for {label} was not found")

p.write_text(s)
print(f"Patched {p}")
PY

docker run --rm \
  -v "$RUNTIME/agent:/src:ro" \
  --entrypoint python \
  "phoenix-dev-agent:$VERSION" -m py_compile /src/main.py \
  || die "Patched agent source failed Python compilation."

# Make future headless sign-ins use device auth. This is convenience-only and
# does not affect an already-authenticated Codex session.
for helper in "$HELPER_RUNTIME" "$HELPER_ACTIVE"; do
  if [[ -f "$helper" ]]; then
    if grep -Fq 'codex-login) exec docker exec -it phoenix-dev-agent codex login ;;' "$helper"; then
      sed -i 's#codex-login) exec docker exec -it phoenix-dev-agent codex login ;;#codex-login) exec docker exec -it phoenix-dev-agent codex login --device-auth ;;#' "$helper"
    fi
    chmod +x "$helper" || true
  fi
done

echo "===== PATCH VERIFICATION ====="
grep -n -E 'APP_VERSION|codex.*exec|full_auto' "$MAIN" | head -20

grep -Fq 'APP_VERSION = "1.0.8"' "$MAIN" \
  || die "APP_VERSION verification failed."
grep -Fq 'cmd=["codex","exec","--json","--skip-git-repo-check","-C",str(ws)]' "$MAIN" \
  || die "Codex command verification failed."
grep -Fq 'if full_auto: cmd.extend(["--sandbox","read-only"])' "$MAIN" \
  || die "Codex read-only verification failed."

log "Rebuilding corrected Phoenix Dev Agent v$VERSION image"
rollback_image_id="$(docker inspect -f '{{.Image}}' phoenix-dev-agent 2>/dev/null || true)"
docker build --pull --no-cache -t "phoenix-dev-agent:$VERSION" "$RUNTIME/agent"

set -a
# shellcheck source=/dev/null
source "$ENVFILE"
set +a
PORT="${PDA_PORT:-8787}"

run_agent() {
  local image="$1"
  docker run -d \
    --name phoenix-dev-agent \
    --restart unless-stopped \
    --network phoenix-dev-net \
    -p "$PORT:8787" \
    -e "BROKER_URL=http://phoenix-dev-broker:8790" \
    -e "BROKER_TOKEN=$BROKER_TOKEN" \
    -e "PDA_ADMIN_USER=$PDA_ADMIN_USER" \
    -e "PDA_ADMIN_PASSWORD=$PDA_ADMIN_PASSWORD" \
    -e "PDA_DATA=/data" \
    -e "PDA_WORKSPACE=/workspace" \
    -e "DEV_SWEEP_SECONDS=${DEV_SWEEP_SECONDS:-600}" \
    -e "FAST_WATCH_SECONDS=${FAST_WATCH_SECONDS:-60}" \
    -e "CODEX_MODEL=${CODEX_MODEL:-}" \
    -v "$BASE:/data:rw" \
    -v "$WORKSPACE:/workspace:rw" \
    -v "$BASE/codex:/root/.codex:rw" \
    "$image" >/dev/null
}

restore_base_agent() {
  if [[ -n "$rollback_image_id" ]]; then
    echo "Restoring last healthy staged agent image."
    docker rm -f phoenix-dev-agent >/dev/null 2>&1 || true
    run_agent "$rollback_image_id" || true
  fi
}

log "Restarting agent with corrected v$VERSION image"
docker rm -f phoenix-dev-agent >/dev/null 2>&1 || true
if ! run_agent "phoenix-dev-agent:$VERSION"; then
  restore_base_agent
  die "Unable to start corrected Phoenix Dev Agent."
fi

healthy=0
for _ in $(seq 1 45); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 1
done

if [[ "$healthy" -ne 1 ]]; then
  echo "Corrected agent health check failed. Recent logs:"
  docker logs --tail 150 phoenix-dev-agent 2>&1 || true
  restore_base_agent
  die "Corrected agent health check failed."
fi

status_json="$("$BASE/bin/phoenix-dev" status)" || {
  echo "Corrected agent/broker validation failed."
  docker logs --tail 150 phoenix-dev-agent 2>&1 || true
  restore_base_agent
  die "Corrected agent/broker validation failed."
}

echo "$status_json" | grep -Fq '"version": "1.0.8"' \
  || {
    echo "$status_json"
    restore_base_agent
    die "Running agent did not report v1.0.8."
  }

log "Phoenix Dev Agent v$VERSION verified"
docker image prune -f >/dev/null || true
echo "$status_json"
