#!/bin/bash
set -euo pipefail

BASE="${PDA_BASE:-/mnt/user/appdata/phoenix-dev-agent}"
WORKSPACE="${PDA_WORKSPACE:-/mnt/user/dev/phoenix-projects}"
VERSION="1.0.7"
GENERIC_URL="https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/9966cc18c34743addd2bc3f32f7a9c97ce770dd2/release/install-phoenix-dev-agent.sh"
GENERIC_SHA256="11973de5a064a47bdd41b526f65f6aa349e433563805f77147de57f5ffa23ebc"
ACTION="${1:-install}"
TMP="$(mktemp /tmp/phoenix-dev-v107-base.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

log() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for c in docker curl sha256sum awk python3; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required."
done

log "Fetching verified Phoenix Dev Agent base installer"
curl --fail --show-error --location --connect-timeout 15 --retry 3 \
  "$GENERIC_URL?cb=$(date +%s%N 2>/dev/null || date +%s)" -o "$TMP"
got="$(sha256sum "$TMP" | awk '{print $1}')"
[[ "$got" == "$GENERIC_SHA256" ]] || die "Base installer checksum mismatch. Expected $GENERIC_SHA256, got $got."
chmod +x "$TMP"

# The verified v1.0.6 installer is release-manifest driven. With latest.env at
# v1.0.7 it safely stages/builds the v1.0.7 runtime first, including rollback.
env PDA_RELEASE_BASE_URL="${PDA_RELEASE_BASE_URL:-https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/main/release}" \
    PDA_PORT="${PDA_PORT:-8787}" \
    bash "$TMP" "$ACTION"

# Non-install commands are fully handled by the base installer.
case "$ACTION" in
  install|update|repair) ;;
  *) exit 0 ;;
esac

RUNTIME="$BASE/runtime/$VERSION"
MAIN="$RUNTIME/agent/main.py"
ENVFILE="$BASE/config/phoenix.env"
[[ -f "$MAIN" ]] || die "v$VERSION agent source not found at $MAIN"
[[ -f "$ENVFILE" ]] || die "Phoenix environment file not found at $ENVFILE"

log "Applying verified Codex compatibility hotfix for codex-cli 0.154.x"
PDA_RELEASE_VERSION="$VERSION" python3 - "$MAIN" <<'PY'
from pathlib import Path
import os, re, sys

p = Path(sys.argv[1])
s = p.read_text()
version = os.environ["PDA_RELEASE_VERSION"]

old_cmd = '    cmd=["codex","exec","--json","-C",str(ws)]'
new_cmd = '    cmd=["codex","exec","--json","--skip-git-repo-check","-C",str(ws)]'
old_auto = '    if full_auto: cmd.append("--full-auto")'
new_auto = '    if full_auto: cmd.extend(["--sandbox","read-only"])'

if old_cmd in s:
    s = s.replace(old_cmd, new_cmd, 1)
elif new_cmd not in s:
    raise SystemExit("Expected Codex command construction was not found")

if old_auto in s:
    s = s.replace(old_auto, new_auto, 1)
elif new_auto not in s:
    raise SystemExit("Expected Codex automation flag construction was not found")

# v1.0.6 reports 1.0.0 from its health endpoint. Correct dictionary-style
# version fields while leaving unrelated text untouched.
s, count = re.subn(
    r'([\"\']version[\"\']\s*:\s*[\"\'])1\.0\.0([\"\'])',
    lambda m: m.group(1) + version + m.group(2),
    s,
)
if count == 0 and version not in s:
    raise SystemExit("Expected stale agent version field was not found")

p.write_text(s)
print(f"Patched {p}")
PY

python3 -m py_compile "$MAIN" || die "Patched agent source failed Python compilation."

echo "===== PATCH VERIFICATION ====="
grep -n -E 'codex.*exec|full_auto|version.*1\.0\.7' "$MAIN" | head -20 || true

# Rebuild the agent image from the patched runtime. Keep the broker created by
# the base installer; only the agent needs replacing.
log "Rebuilding patched Phoenix Dev Agent v$VERSION image"
old_image_id="$(docker inspect -f '{{.Image}}' phoenix-dev-agent 2>/dev/null || true)"
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

log "Restarting agent with the patched v$VERSION image"
docker rm -f phoenix-dev-agent >/dev/null 2>&1 || true
if ! run_agent "phoenix-dev-agent:$VERSION"; then
  if [[ -n "$old_image_id" ]]; then
    echo "Patched agent failed to start; restoring prior agent image."
    docker rm -f phoenix-dev-agent >/dev/null 2>&1 || true
    run_agent "$old_image_id" || true
  fi
  die "Unable to start patched Phoenix Dev Agent."
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
  echo "Patched agent health check failed. Recent logs:"
  docker logs --tail 150 phoenix-dev-agent 2>&1 || true
  if [[ -n "$old_image_id" ]]; then
    echo "Restoring prior agent image."
    docker rm -f phoenix-dev-agent >/dev/null 2>&1 || true
    run_agent "$old_image_id" || true
  fi
  die "Patched agent health check failed."
fi

if ! "$BASE/bin/phoenix-dev" status >/dev/null; then
  echo "Patched agent/broker validation failed. Recent agent logs:"
  docker logs --tail 150 phoenix-dev-agent 2>&1 || true
  if [[ -n "$old_image_id" ]]; then
    echo "Restoring prior agent image."
    docker rm -f phoenix-dev-agent >/dev/null 2>&1 || true
    run_agent "$old_image_id" || true
  fi
  die "Patched agent/broker validation failed."
fi

log "Phoenix Dev Agent v$VERSION Codex compatibility hotfix verified"
docker image prune -f >/dev/null || true
"$BASE/bin/phoenix-dev" status
