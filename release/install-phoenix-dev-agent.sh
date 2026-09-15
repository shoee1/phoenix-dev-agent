#!/bin/bash
set -euo pipefail

DEFAULT_RELEASE_BASE_URL="https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/main/release"
BASE="${PDA_BASE:-/mnt/user/appdata/phoenix-dev-agent}"
WORKSPACE="${PDA_WORKSPACE:-/mnt/user/dev/phoenix-projects}"
PORT="${PDA_PORT:-8787}"
NETWORK="phoenix-dev-net"
AGENT_CONTAINER="phoenix-dev-agent"
BROKER_CONTAINER="phoenix-dev-broker"
ENVFILE="$BASE/config/phoenix.env"
CHANNELFILE="$BASE/config/release-channel.env"
BIN="$BASE/bin/phoenix-dev"
RELEASE_BASE_URL="${PDA_RELEASE_BASE_URL:-}"
VERSION=""
PAYLOAD_PARTS=""
PAYLOAD_SHA256=""
PAYLOAD_ENCODING=""
RUNTIME=""
AGENT_IMAGE=""
BROKER_IMAGE=""

log() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

secret() {
  if have openssl; then openssl rand -hex 24
  else tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
  fi
}

require_host() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this installer as root from the Unraid terminal."
  for c in docker curl tar sha256sum awk sed grep jq base64; do have "$c" || die "$c is required."; done
  docker info >/dev/null 2>&1 || die "Docker daemon is not available."
}

resolve_release_base() {
  if [[ -z "$RELEASE_BASE_URL" && -f "$CHANNELFILE" ]]; then
    source "$CHANNELFILE"
    RELEASE_BASE_URL="${PDA_RELEASE_BASE_URL:-}"
  fi
  if [[ -z "$RELEASE_BASE_URL" && "$DEFAULT_RELEASE_BASE_URL" != "https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/main/release" ]]; then
    RELEASE_BASE_URL="$DEFAULT_RELEASE_BASE_URL"
  fi
  [[ -n "$RELEASE_BASE_URL" ]] || die "No Phoenix release channel is configured. Set PDA_RELEASE_BASE_URL to the hosted release directory."
  RELEASE_BASE_URL="${RELEASE_BASE_URL%/}"
  [[ "$RELEASE_BASE_URL" == https://* || "$RELEASE_BASE_URL" == http://* ]] || die "Release URL must be http(s)."
}

load_manifest() {
  local mf
  mf="$(mktemp /tmp/phoenix-dev-manifest.XXXXXX)"
  log "Pulling release manifest"
  curl --fail --show-error --location --connect-timeout 15 --retry 3 \
    "$RELEASE_BASE_URL/latest.env" -o "$mf"

  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      PDA_RELEASE_VERSION) VERSION="$value" ;;
      PDA_PAYLOAD_PARTS) PAYLOAD_PARTS="$value" ;;
      PDA_PAYLOAD_SHA256) PAYLOAD_SHA256="$value" ;;
      PDA_PAYLOAD_ENCODING) PAYLOAD_ENCODING="$value" ;;
    esac
  done < "$mf"
  rm -f "$mf"

  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || die "Invalid release version in manifest."
  [[ -n "$PAYLOAD_PARTS" ]] || die "Missing payload parts in manifest."
  [[ "$PAYLOAD_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || die "Invalid payload SHA-256 in manifest."
  [[ "$PAYLOAD_ENCODING" == "base64" ]] || die "Unsupported payload encoding in manifest."

  RUNTIME="$BASE/runtime/$VERSION"
  AGENT_IMAGE="phoenix-dev-agent:$VERSION"
  BROKER_IMAGE="phoenix-dev-broker:$VERSION"
}

save_channel() {
  mkdir -p "$BASE/config"
  cat > "$CHANNELFILE" <<EOF2
PDA_RELEASE_BASE_URL=$RELEASE_BASE_URL
EOF2
  chmod 600 "$CHANNELFILE"
}

download_payload() {
  local payload_encoded payload_tmp got
  payload_encoded="$(mktemp /tmp/phoenix-dev-payload.XXXXXX.b64)"
  payload_tmp="$(mktemp /tmp/phoenix-dev-payload.XXXXXX.tgz)"
  log "Downloading Phoenix Dev Agent v$VERSION payload"
  : > "$payload_encoded"
  IFS=';' read -r -a parts <<< "$PAYLOAD_PARTS"
  local part
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid payload part name: $part"
    curl --fail --show-error --location --connect-timeout 15 --retry 3 \
      "$RELEASE_BASE_URL/$part" >> "$payload_encoded"
  done
  base64 -d "$payload_encoded" > "$payload_tmp" || die "Unable to decode release payload."
  rm -f "$payload_encoded"
  got="$(sha256sum "$payload_tmp" | awk '{print $1}')"
  [[ "$got" == "$PAYLOAD_SHA256" ]] || die "Payload checksum mismatch. Expected $PAYLOAD_SHA256, got $got."

  rm -rf "$RUNTIME"
  mkdir -p "$RUNTIME"
  tar -xzf "$payload_tmp" -C "$RUNTIME"
  rm -f "$payload_tmp"

  chmod +x "$RUNTIME/phoenix-dev"
  mkdir -p "$BASE/bin"
  cp -f "$RUNTIME/phoenix-dev" "$BIN"
  chmod +x "$BIN"
  ln -sf "$BIN" /usr/local/bin/phoenix-dev 2>/dev/null || true
}

ensure_config() {
  mkdir -p "$BASE/config" "$BASE/projects" "$BASE/incidents" "$BASE/logs" "$BASE/codex" "$BASE/backups" "$BASE/releases" "$WORKSPACE"
  if [[ ! -f "$ENVFILE" ]]; then
    local admin_pass broker_token
    admin_pass="$(secret)"
    broker_token="$(secret)"
    cat > "$ENVFILE" <<EOF2
PDA_ADMIN_USER=admin
PDA_ADMIN_PASSWORD=$admin_pass
BROKER_TOKEN=$broker_token
PDA_PORT=$PORT
DEV_SWEEP_SECONDS=600
FAST_WATCH_SECONDS=60
CODEX_MODEL=
EOF2
    chmod 600 "$ENVFILE"
  fi
  set -a
  source "$ENVFILE"
  set +a
  PORT="${PDA_PORT:-$PORT}"
}

build_images() {
  log "Building Phoenix Dev Agent $VERSION"
  docker build --pull -t "$BROKER_IMAGE" "$RUNTIME/broker"
  docker build --pull -t "$AGENT_IMAGE" "$RUNTIME/agent"
}

remove_stack() {
  docker rm -f "$AGENT_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$BROKER_CONTAINER" >/dev/null 2>&1 || true
}

start_stack() {
  local agent_image="$1" broker_image="$2"
  docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null

  docker run -d \
    --name "$BROKER_CONTAINER" \
    --restart unless-stopped \
    --network "$NETWORK" \
    -e "BROKER_TOKEN=$BROKER_TOKEN" \
    -e "PDA_DATA=/data" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$BASE:/data:rw" \
    -v /mnt/user:/host/user:ro \
    -v /mnt/user/appdata:/host/appdata:ro \
    -v "$WORKSPACE:/host/workspace:rw" \
    "$broker_image" >/dev/null

  docker run -d \
    --name "$AGENT_CONTAINER" \
    --restart unless-stopped \
    --network "$NETWORK" \
    -p "$PORT:8787" \
    -e "BROKER_URL=http://$BROKER_CONTAINER:8790" \
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
    "$agent_image" >/dev/null
}

wait_healthy() {
  local i
  for i in $(seq 1 45); do
    if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

install_or_update() {
  require_host
  resolve_release_base
  mkdir -p "$BASE" "$WORKSPACE"
  load_manifest
  download_payload
  ensure_config
  save_channel

  local old_agent="" old_broker=""
  old_agent="$(docker inspect -f '{{.Config.Image}}' "$AGENT_CONTAINER" 2>/dev/null || true)"
  old_broker="$(docker inspect -f '{{.Config.Image}}' "$BROKER_CONTAINER" 2>/dev/null || true)"

  build_images

  log "Starting Phoenix Dev Agent v$VERSION"
  remove_stack
  if ! start_stack "$AGENT_IMAGE" "$BROKER_IMAGE"; then
    if [[ -n "$old_agent" && -n "$old_broker" ]]; then
      echo "New stack failed to start; restoring previous Phoenix Dev Agent images."
      remove_stack
      start_stack "$old_agent" "$old_broker" || true
    fi
    die "Failed to start new Phoenix Dev Agent stack."
  fi

  if ! wait_healthy; then
    echo "Health check failed."
    docker logs --tail 120 "$AGENT_CONTAINER" || true
    if [[ -n "$old_agent" && -n "$old_broker" ]]; then
      echo "Rolling Phoenix Dev Agent itself back to the previous images."
      remove_stack
      start_stack "$old_agent" "$old_broker" || true
    fi
    die "Phoenix Dev Agent health check failed."
  fi

  log "Validating agent/broker"
  "$BIN" status >/dev/null || die "Agent/broker validation failed."

  log "Cleaning orphaned Docker images after successful deployment"
  docker image prune -f >/dev/null || true

  print_success
}

print_success() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  echo "======================================================================"
  echo " Phoenix Dev Agent v$VERSION is running"
  echo "======================================================================"
  echo " UI:       http://${ip:-UNRAID-IP}:$PORT"
  echo " Username: $PDA_ADMIN_USER"
  echo " Password: $PDA_ADMIN_PASSWORD"
  echo " Channel:  $RELEASE_BASE_URL"
  echo
  echo " Helper:   $BIN"
  echo " Update:   phoenix-dev update"
  echo
  echo " ONE-TIME CODEX SIGN-IN:"
  echo "   phoenix-dev codex-login"
  echo
  echo " Register ONLY the existing app(s) you deliberately want managed."
  echo " Unregistered containers are not enrolled as Phoenix projects."
  echo "======================================================================"
}

status_cmd() {
  require_host
  ensure_config
  echo "Phoenix Dev Agent"
  [[ -f "$CHANNELFILE" ]] && { echo -n "Release channel: "; grep '^PDA_RELEASE_BASE_URL=' "$CHANNELFILE" | cut -d= -f2-; }
  docker ps -a --filter "name=^/${AGENT_CONTAINER}$" --filter "name=^/${BROKER_CONTAINER}$" \
    --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  echo
  curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null || echo "Agent health endpoint unavailable."
  echo
  [[ -x "$BIN" ]] && "$BIN" credentials || true
}

uninstall_cmd() {
  require_host
  remove_stack
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -f /usr/local/bin/phoenix-dev 2>/dev/null || true
  if [[ "${1:-}" == "--purge" ]]; then
    echo "PURGE requested: deleting Phoenix Dev Agent data and managed workspace."
    rm -rf "$BASE" "$WORKSPACE"
  else
    echo "Containers removed. Data preserved at:"
    echo "  $BASE"
    echo "  $WORKSPACE"
    echo "Run uninstall --purge only if you intentionally want those deleted too."
  fi
}

verify_channel_cmd() {
  for c in curl tar sha256sum awk; do have "$c" || die "$c is required."; done
  resolve_release_base
  load_manifest
  local enc tmp got
  enc="$(mktemp /tmp/phoenix-dev-verify.XXXXXX.b64)"
  tmp="$(mktemp /tmp/phoenix-dev-verify.XXXXXX.tgz)"
  trap "rm -f '$enc' '$tmp'" EXIT
  : > "$enc"
  IFS=';' read -r -a parts <<< "$PAYLOAD_PARTS"
  local part
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid payload part name: $part"
    curl --fail --show-error --location --connect-timeout 15 --retry 3 \
      "$RELEASE_BASE_URL/$part" >> "$enc"
  done
  base64 -d "$enc" > "$tmp" || die "Unable to decode release payload."
  got="$(sha256sum "$tmp" | awk '{print $1}')"
  [[ "$got" == "$PAYLOAD_SHA256" ]] || die "Payload checksum mismatch."
  tar -tzf "$tmp" >/dev/null || die "Payload archive is invalid."
  echo "Phoenix Dev Agent release channel verified: v$VERSION"
  echo "Payload SHA-256: $got"
}

case "${1:-install}" in
  install|update|repair) install_or_update ;;
  verify-channel) verify_channel_cmd ;;
  status) status_cmd ;;
  uninstall) uninstall_cmd "${2:-}" ;;
  credentials)
    ensure_config
    "$BIN" credentials
    ;;
  *)
    cat <<EOF2
Phoenix Dev Agent pull installer

Usage:
  bash install-phoenix-dev-agent.sh install
  bash install-phoenix-dev-agent.sh update
  bash install-phoenix-dev-agent.sh repair
  bash install-phoenix-dev-agent.sh status
  bash install-phoenix-dev-agent.sh verify-channel
  bash install-phoenix-dev-agent.sh credentials
  bash install-phoenix-dev-agent.sh uninstall
  bash install-phoenix-dev-agent.sh uninstall --purge

First install requires a hosted channel URL unless one is compiled into this script:
  PDA_RELEASE_BASE_URL=https://host/path/stable bash install-phoenix-dev-agent.sh install

After first install the channel is persisted and future updates are simply:
  phoenix-dev update
EOF2
    exit 2
    ;;
esac
