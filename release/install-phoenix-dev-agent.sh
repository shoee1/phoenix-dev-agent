#!/bin/bash
set -euo pipefail

BASE="${PDA_BASE:-/mnt/user/appdata/phoenix-dev-agent}"
WORKSPACE="${PDA_WORKSPACE:-/mnt/user/dev/phoenix-projects}"
VERSION="1.1.0"
ACTION="${1:-install}"
GENERIC_URL="https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/9966cc18c34743addd2bc3f32f7a9c97ce770dd2/release/install-phoenix-dev-agent.sh"
GENERIC_SHA256="11973de5a064a47bdd41b526f65f6aa349e433563805f77147de57f5ffa23ebc"
DISCOVER_URL="https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/9356d863390c5277053bb87a39cf9e173e0ec16e/release/features/v1.1.0/phoenix-dev-discover.sh"
DISCOVER_SHA256="c98793c5d0afa34cce5b3f550c7e2a2af2a7fb3f5927ccd4cd486615a6de4e47"
WRAPPER_URL="https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/4a92b28447b0fe6ea61480b2fb45d7cf02fd6f62/release/features/v1.1.0/phoenix-dev-wrapper.sh"
WRAPPER_SHA256="5551cee35b02cdef474396604316c87a1c291416da620ce8f7cf6e3032e39e9a"
TMPBASE="$(mktemp /tmp/phoenix-dev-v110-base.XXXXXX.sh)"
TMPDISC="$(mktemp /tmp/phoenix-dev-discover.XXXXXX.sh)"
TMPWRAP="$(mktemp /tmp/phoenix-dev-wrapper.XXXXXX.sh)"
trap 'rm -f "$TMPBASE" "$TMPDISC" "$TMPWRAP"' EXIT

log() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
for c in docker curl sha256sum awk grep sed jq; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required."
done

fetch_verified() {
  local url="$1" sha="$2" out="$3" label="$4" got
  curl --fail --show-error --location --connect-timeout 15 --retry 3 \
    "$url?cb=$(date +%s%N 2>/dev/null || date +%s)-$$" -o "$out"
  got="$(sha256sum "$out" | awk '{print $1}')"
  [[ "$got" == "$sha" ]] || die "$label checksum mismatch. Expected $sha, got $got."
  chmod +x "$out"
}

PREVIOUS_AGENT_IMAGE_ID="$(docker inspect -f '{{.Image}}' phoenix-dev-agent 2>/dev/null || true)"

log "Fetching verified Phoenix base installer"
fetch_verified "$GENERIC_URL" "$GENERIC_SHA256" "$TMPBASE" "Base installer"
log "Fetching verified v$VERSION discovery feature"
fetch_verified "$DISCOVER_URL" "$DISCOVER_SHA256" "$TMPDISC" "Discovery helper"
fetch_verified "$WRAPPER_URL" "$WRAPPER_SHA256" "$TMPWRAP" "Command wrapper"
bash -n "$TMPDISC" || die "Discovery helper shell validation failed."
bash -n "$TMPWRAP" || die "Command wrapper shell validation failed."

# Stage/build/start through the verified base installer. The stable manifest
# supplies VERSION=1.1.0 while reusing the verified base payload.
env PDA_RELEASE_BASE_URL="${PDA_RELEASE_BASE_URL:-https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/main/release}" \
    PDA_PORT="${PDA_PORT:-8787}" \
    bash "$TMPBASE" "$ACTION"

case "$ACTION" in
  install|update|repair) ;;
  *) exit 0 ;;
esac

RUNTIME="$BASE/runtime/$VERSION"
MAIN="$RUNTIME/agent/main.py"
HELPER_RUNTIME="$RUNTIME/phoenix-dev"
ENVFILE="$BASE/config/phoenix.env"
CORE="$BASE/bin/phoenix-dev-core"
DISCOVER="$BASE/bin/phoenix-dev-discover"
ACTIVE="$BASE/bin/phoenix-dev"
[[ -f "$MAIN" ]] || die "v$VERSION agent source not found at $MAIN"
[[ -f "$HELPER_RUNTIME" ]] || die "v$VERSION helper source not found at $HELPER_RUNTIME"
[[ -f "$ENVFILE" ]] || die "Phoenix environment file not found at $ENVFILE"

log "Applying verified v$VERSION agent source fixes"
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

# Accept either the verified base source or an already-patched source.
if 'APP_VERSION = "1.0.0"' in s:
    s = s.replace('APP_VERSION = "1.0.0"', f'APP_VERSION = "{version}"', 1)
elif f'APP_VERSION = "{version}"' not in s:
    raise SystemExit("Expected APP_VERSION source was not found")

old_cmd = '    cmd=["codex","exec","--json","-C",str(ws)]'
new_cmd = '    cmd=["codex","exec","--json","--skip-git-repo-check","-C",str(ws)]'
if old_cmd in s:
    s = s.replace(old_cmd, new_cmd, 1)
elif new_cmd not in s:
    raise SystemExit("Expected Codex command source was not found")

old_auto = '    if full_auto: cmd.append("--full-auto")'
new_auto = '    if full_auto: cmd.extend(["--sandbox","read-only"])'
if old_auto in s:
    s = s.replace(old_auto, new_auto, 1)
elif new_auto not in s:
    raise SystemExit("Expected Codex automation source was not found")

p.write_text(s)
print(f"Patched {p}")
PY

# Parse Python source without generating __pycache__ on the read-only mount.
docker run --rm \
  -v "$RUNTIME/agent:/src:ro" \
  --entrypoint python \
  "phoenix-dev-agent:$VERSION" \
  -c 'import ast,pathlib; ast.parse(pathlib.Path("/src/main.py").read_text()); print("main.py syntax OK")' \
  || die "Patched agent source failed Python syntax validation."

grep -Fq "APP_VERSION = \"$VERSION\"" "$MAIN" || die "APP_VERSION verification failed."
grep -Fq 'cmd=["codex","exec","--json","--skip-git-repo-check","-C",str(ws)]' "$MAIN" || die "Codex command verification failed."
grep -Fq 'if full_auto: cmd.extend(["--sandbox","read-only"])' "$MAIN" || die "Codex read-only verification failed."

# Keep headless Codex login usable from the core helper.
if grep -Fq 'codex-login) exec docker exec -it phoenix-dev-agent codex login ;;' "$HELPER_RUNTIME"; then
  sed -i 's#codex-login) exec docker exec -it phoenix-dev-agent codex login ;;#codex-login) exec docker exec -it phoenix-dev-agent codex login --device-auth ;;#' "$HELPER_RUNTIME"
fi

log "Rebuilding corrected Phoenix Dev Agent v$VERSION image"
docker build --pull --no-cache -t "phoenix-dev-agent:$VERSION" "$RUNTIME/agent"

RUNTIME_HASH="$(sha256sum "$MAIN" | awk '{print $1}')"
IMAGE_HASH="$(docker run --rm --entrypoint sh "phoenix-dev-agent:$VERSION" -lc 'sha256sum /app/main.py' | awk '{print $1}')"
[[ "$RUNTIME_HASH" == "$IMAGE_HASH" ]] || die "Built agent image does not contain the patched runtime source."

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

restore_previous_agent() {
  [[ -n "$PREVIOUS_AGENT_IMAGE_ID" ]] || return 0
  echo "Restoring previous known agent image."
  docker rm -f phoenix-dev-agent >/dev/null 2>&1 || true
  run_agent "$PREVIOUS_AGENT_IMAGE_ID" || true
}

log "Restarting agent with corrected v$VERSION image"
docker rm -f phoenix-dev-agent >/dev/null 2>&1 || true
if ! run_agent "phoenix-dev-agent:$VERSION"; then
  restore_previous_agent
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
  docker logs --tail 150 phoenix-dev-agent 2>&1 || true
  restore_previous_agent
  die "Corrected agent health check failed."
fi

# Preserve the original helper as the core implementation, then layer the
# project-scoped discovery command in front of it.
cp -f "$HELPER_RUNTIME" "$CORE"
cp -f "$TMPDISC" "$DISCOVER"
cp -f "$TMPWRAP" "$ACTIVE"
chmod +x "$CORE" "$DISCOVER" "$ACTIVE"
ln -sf "$ACTIVE" /usr/local/bin/phoenix-dev 2>/dev/null || true

status_json="$("$CORE" status)" || {
  docker logs --tail 150 phoenix-dev-agent 2>&1 || true
  restore_previous_agent
  die "Corrected agent/broker validation failed."
}
echo "$status_json" | grep -Fq "\"version\": \"$VERSION\"" || {
  echo "$status_json"
  restore_previous_agent
  die "Running agent did not report v$VERSION."
}

cleanup_old_phoenix() {
  log "Cleaning old Phoenix Dev Agent containers and images"

  docker ps -a --format '{{.ID}}|{{.Image}}|{{.State}}' | while IFS='|' read -r cid image state; do
    case "$image" in
      phoenix-dev-agent:*|phoenix-dev-broker:*)
        [[ "$state" == "running" ]] || docker rm "$cid" >/dev/null 2>&1 || true
        ;;
    esac
  done

  local repo tag prev
  for repo in phoenix-dev-agent phoenix-dev-broker; do
    prev="$(docker images "$repo" --format '{{.Tag}}' | awk -v cur="$VERSION" '$0 != "<none>" && $0 != cur {print; exit}')"
    while IFS= read -r tag; do
      [[ -n "$tag" && "$tag" != "<none>" ]] || continue
      [[ "$tag" == "$VERSION" || "$tag" == "$prev" ]] && continue
      docker image rm "$repo:$tag" >/dev/null 2>&1 || true
    done < <(docker images "$repo" --format '{{.Tag}}')
    [[ -z "$prev" ]] || echo "Kept previous $repo:$prev for rollback."
  done
  docker image prune -f >/dev/null || true
}

# Run read-only discovery for projects the user has already explicitly
# registered. No unregistered Docker containers are enumerated or enrolled.
log "Refreshing registered project discovery"
shopt -s nullglob
for pj in "$BASE/projects"/*/project.json; do
  pid="$(jq -r '.id // empty' "$pj")"
  [[ -n "$pid" ]] || continue
  echo "--- discover $pid ---"
  "$DISCOVER" "$pid" || echo "WARNING: discovery failed for $pid; core Phoenix remains healthy."
done
shopt -u nullglob

cleanup_old_phoenix

log "Phoenix Dev Agent v$VERSION verified"
echo "$status_json"
echo
echo "Discovery: phoenix-dev discover <project-id>"
