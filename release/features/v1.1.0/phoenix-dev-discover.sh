#!/bin/bash
set -euo pipefail

BASE="${PDA_BASE:-/mnt/user/appdata/phoenix-dev-agent}"
ENVFILE="$BASE/config/phoenix.env"
[[ -f "$ENVFILE" ]] && { set -a; source "$ENVFILE"; set +a; }
WORKSPACE="${PDA_WORKSPACE:-/mnt/user/dev/phoenix-projects}"
PID="${1:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ -n "$PID" ]] || fail "Usage: phoenix-dev discover <project-id>"
[[ "$PID" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Invalid project id."
command -v docker >/dev/null 2>&1 || fail "docker is required."
command -v jq >/dev/null 2>&1 || fail "jq is required."

PROJECT_JSON="$BASE/projects/$PID/project.json"
[[ -f "$PROJECT_JSON" ]] || fail "Project is not registered: $PID"
CONTAINER="$(jq -r '.container // empty' "$PROJECT_JSON")"
[[ -n "$CONTAINER" ]] || fail "Registered project has no container."
docker inspect "$CONTAINER" >/dev/null 2>&1 || fail "Registered container not found: $CONTAINER"

PROJECT_DIR="$WORKSPACE/$PID"
PHOENIX_DIR="$PROJECT_DIR/.phoenix"
mkdir -p "$PROJECT_DIR" "$PHOENIX_DIR"
TMP="$(mktemp -d /tmp/phoenix-discover.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
NOW="$(date -Iseconds)"

# Only the explicitly registered container is inspected. Environment values are
# never persisted; only variable names are retained.
docker inspect "$CONTAINER" | jq '.[0] | {
  name: (.Name | ltrimstr("/")),
  image: .Config.Image,
  image_id: .Image,
  created: .Created,
  state: {
    status: .State.Status,
    running: .State.Running,
    started_at: .State.StartedAt,
    restart_count: .RestartCount,
    health: (.State.Health.Status // null)
  },
  restart_policy: .HostConfig.RestartPolicy,
  network_mode: .HostConfig.NetworkMode,
  ports: .NetworkSettings.Ports,
  mounts: [.Mounts[]? | {
    type: .Type,
    source: .Source,
    destination: .Destination,
    mode: .Mode,
    rw: .RW
  }],
  env_names: ([.Config.Env[]? | split("=")[0]] | sort | unique),
  entrypoint: .Config.Entrypoint,
  cmd: .Config.Cmd,
  working_dir: .Config.WorkingDir,
  user: .Config.User,
  device_requests: .HostConfig.DeviceRequests,
  labels: .Config.Labels
}' > "$TMP/container.json"

IMAGE_ID="$(jq -r '.image_id' "$TMP/container.json")"
docker image inspect "$IMAGE_ID" | jq '.[0] | {
  id: .Id,
  created: .Created,
  repo_tags: .RepoTags,
  size: .Size,
  architecture: .Architecture,
  os: .Os
}' > "$TMP/image.json"

# Build the allowed host search roots only from the registered project's known
# paths and mounts. Nothing outside these roots is recursively searched.
{
  jq -r '.mounts[].source // empty' "$TMP/container.json"
  jq -r '.appdata_host_path // empty, .source_host_path // empty, .installer_host_path // empty' "$PROJECT_JSON"
} | awk 'NF && /^\/mnt\/user\//' | sort -u > "$TMP/roots.raw"

# For appdata submounts, also include their app-level parent (for example
# /mnt/user/appdata/app/postgres -> /mnt/user/appdata/app).
while IFS= read -r root; do
  echo "$root"
  case "$root" in
    /mnt/user/appdata/*/*)
      rest="${root#/mnt/user/appdata/}"
      app="${rest%%/*}"
      echo "/mnt/user/appdata/$app"
      ;;
  esac
done < "$TMP/roots.raw" | sort -u | while IFS= read -r root; do
  [[ -e "$root" ]] && echo "$root"
done > "$TMP/roots.txt"

jq -R -s 'split("\n") | map(select(length > 0))' "$TMP/roots.txt" > "$TMP/roots.json"

# Discover log files only under a mount that is clearly a log mount.
: > "$TMP/logs.txt"
jq -r '.mounts[]? | select((.destination == "/logs") or (.source | test("/logs($|/)"))) | .source' "$TMP/container.json" \
  | while IFS= read -r root; do
      [[ -d "$root" ]] || continue
      find "$root" -maxdepth 2 -type f \( -name '*.log' -o -name '*.txt' \) -print 2>/dev/null | head -100
    done | sort -u > "$TMP/logs.txt"
jq -R -s 'split("\n") | map(select(length > 0))' "$TMP/logs.txt" > "$TMP/logs.json"

# Candidate deployment/source files are searched only inside allowed roots.
: > "$TMP/source_candidates.txt"
: > "$TMP/installer_candidates.txt"
: > "$TMP/rollback_candidates.txt"
while IFS= read -r root; do
  [[ -d "$root" ]] || continue
  find "$root" -maxdepth 5 -type f \
    \( -name 'Dockerfile' -o -name 'docker-compose.yml' -o -name 'compose.yml' \
       -o -name 'pyproject.toml' -o -name 'requirements*.txt' -o -name 'package.json' \) \
    -print 2>/dev/null | head -200 >> "$TMP/source_candidates.txt" || true
  find "$root" -maxdepth 5 -type f \
    \( -iname '*install*.sh' -o -iname '*update*.sh' -o -iname '*deploy*.sh' \) \
    ! -iname '*rollback*' -print 2>/dev/null | head -100 >> "$TMP/installer_candidates.txt" || true
  find "$root" -maxdepth 6 -type f -iname '*rollback*.sh' -print 2>/dev/null | head -100 >> "$TMP/rollback_candidates.txt" || true
done < "$TMP/roots.txt"
for f in source_candidates installer_candidates rollback_candidates; do
  sort -u "$TMP/$f.txt" -o "$TMP/$f.txt"
  jq -R -s 'split("\n") | map(select(length > 0))' "$TMP/$f.txt" > "$TMP/$f.json"
done

# Find source-like files inside the registered image/container. This runs only
# read-only listing commands and does not alter application files.
if docker exec "$CONTAINER" sh -lc 'true' >/dev/null 2>&1; then
  docker exec "$CONTAINER" sh -lc '
    for d in /app /opt /srv; do
      [ -d "$d" ] || continue
      find "$d" -maxdepth 3 -type f \
        \( -name "*.py" -o -name "Dockerfile" -o -name "requirements*.txt" \
           -o -name "pyproject.toml" -o -name "package.json" -o -name "*.sh" \) \
        -print 2>/dev/null
    done | head -200
  ' > "$TMP/image_source_files.txt" 2>/dev/null || true
else
  : > "$TMP/image_source_files.txt"
fi
jq -R -s 'split("\n") | map(select(length > 0))' "$TMP/image_source_files.txt" > "$TMP/image_source_files.json"

# Locate the Unraid template by the registered container name, but never copy
# template contents because they can contain credential values.
TEMPLATE=""
if [[ -d /boot/config/plugins/dockerMan/templates-user ]]; then
  while IFS= read -r f; do
    if grep -Fq "$CONTAINER" "$f" 2>/dev/null; then
      TEMPLATE="$f"
      break
    fi
  done < <(find /boot/config/plugins/dockerMan/templates-user -maxdepth 1 -type f -name '*.xml' -print | sort)
fi
TEMPLATE_SHA=""
[[ -n "$TEMPLATE" && -f "$TEMPLATE" ]] && TEMPLATE_SHA="$(sha256sum "$TEMPLATE" | awk '{print $1}')"

# Conservative deterministic selection: only auto-fill a source path when a
# single Dockerfile is present under allowed roots. Installer path is only
# auto-filled when there is exactly one install/update/deploy script candidate.
SOURCE_PATH=""
mapfile -t dockerfiles < <(grep -E '/Dockerfile$' "$TMP/source_candidates.txt" || true)
if [[ "${#dockerfiles[@]}" -eq 1 ]]; then
  SOURCE_PATH="$(dirname "${dockerfiles[0]}")"
fi
INSTALLER_PATH=""
mapfile -t installers < "$TMP/installer_candidates.txt"
if [[ "${#installers[@]}" -eq 1 ]]; then
  INSTALLER_PATH="${installers[0]}"
fi

jq -n \
  --arg project_id "$PID" \
  --arg discovered_at "$NOW" \
  --arg template "$TEMPLATE" \
  --arg template_sha256 "$TEMPLATE_SHA" \
  --arg source_path "$SOURCE_PATH" \
  --arg installer_path "$INSTALLER_PATH" \
  --slurpfile container "$TMP/container.json" \
  --slurpfile image "$TMP/image.json" \
  --slurpfile roots "$TMP/roots.json" \
  --slurpfile logs "$TMP/logs.json" \
  --slurpfile source_candidates "$TMP/source_candidates.json" \
  --slurpfile installer_candidates "$TMP/installer_candidates.json" \
  --slurpfile rollback_candidates "$TMP/rollback_candidates.json" \
  --slurpfile image_source_files "$TMP/image_source_files.json" \
  '{
    project_id: $project_id,
    discovered_at: $discovered_at,
    production_untouched: true,
    secrets_redacted: true,
    container: $container[0],
    image: $image[0],
    associated_host_paths: $roots[0],
    log_files: $logs[0],
    unraid_template: (if $template == "" then null else {path:$template, sha256:$template_sha256} end),
    source_host_path: (if $source_path == "" then null else $source_path end),
    installer_host_path: (if $installer_path == "" then null else $installer_path end),
    source_candidates: $source_candidates[0],
    installer_candidates: $installer_candidates[0],
    rollback_candidates: $rollback_candidates[0],
    image_source_files: $image_source_files[0],
    deployment_verified: false,
    authority: {test:false, build:false, deploy:false, rollback:false}
  }' > "$PHOENIX_DIR/discovery.json"

# Refresh project metadata without ever enabling deployment authority.
PROJECT_TMP="$TMP/project.json"
jq \
  --arg ts "$NOW" \
  --arg template "$TEMPLATE" \
  --arg source "$SOURCE_PATH" \
  --arg installer "$INSTALLER_PATH" \
  --slurpfile roots "$TMP/roots.json" \
  --slurpfile logs "$TMP/logs.json" \
  '.last_discovery = $ts
   | .associated_host_paths = $roots[0]
   | .log_files = $logs[0]
   | .unraid_template_path = (if $template == "" then (.unraid_template_path // null) else $template end)
   | .source_host_path = (if $source == "" then (.source_host_path // null) else $source end)
   | .installer_host_path = (if $installer == "" then (.installer_host_path // null) else $installer end)
   | .discovery = {status:"complete", deployment_verified:false, secrets_redacted:true}
  ' "$PROJECT_JSON" > "$PROJECT_TMP"
mv "$PROJECT_TMP" "$PROJECT_JSON"

NAME="$(jq -r '.name' "$TMP/container.json")"
IMAGE="$(jq -r '.image' "$TMP/container.json")"
STATUS="$(jq -r '.state.status' "$TMP/container.json")"
NETWORK="$(jq -r '.network_mode' "$TMP/container.json")"
GPU="$(jq -r '([.device_requests[]?.Capabilities[]?[]?] | index("gpu")) != null' "$TMP/container.json")"

{
  echo "# PROJECT_STATE"
  echo
  echo "- Project ID: \`$PID\`"
  echo "- Container: \`$NAME\`"
  echo "- Image: \`$IMAGE\`"
  echo "- Runtime status: \`$STATUS\`"
  echo "- Network: \`$NETWORK\`"
  echo "- GPU requested: \`$GPU\`"
  echo "- Last discovery: \`$NOW\`"
  echo "- Production modified by discovery: **No**"
  echo "- Secret values captured: **No**"
  echo
  echo "## Associated host paths"
  if [[ -s "$TMP/roots.txt" ]]; then sed 's#^#- `#; s#$#`#' "$TMP/roots.txt"; else echo "- None detected"; fi
  echo
  echo "## Deployment discovery"
  echo "- Source host path: ${SOURCE_PATH:-Not verified}"
  echo "- Installer/deployer: ${INSTALLER_PATH:-Not verified}"
  echo "- Unraid template: ${TEMPLATE:-Not detected}"
  echo "- Deployment verified: **No**"
  echo
  echo "## Authority"
  echo "Build, deploy and rollback remain disabled until the discovered deployment path is explicitly verified."
} > "$PROJECT_DIR/PROJECT_STATE.md"

yamlq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
{
  echo "version: 1"
  printf 'project: '; yamlq "$PID"; echo
  printf 'discovered_at: '; yamlq "$NOW"; echo
  echo "verified: false"
  echo "production_untouched: true"
  echo "secrets_redacted: true"
  echo "container:"
  printf '  name: '; yamlq "$NAME"; echo
  printf '  image: '; yamlq "$IMAGE"; echo
  printf '  image_id: '; yamlq "$(jq -r '.image_id' "$TMP/container.json")"; echo
  printf '  network_mode: '; yamlq "$NETWORK"; echo
  echo "  gpu_requested: $GPU"
  echo "mounts:"
  jq -r '.mounts[]? | @base64' "$TMP/container.json" | while IFS= read -r row; do
    j="$(printf '%s' "$row" | base64 -d)"
    src="$(printf '%s' "$j" | jq -r '.source')"
    dst="$(printf '%s' "$j" | jq -r '.destination')"
    rw="$(printf '%s' "$j" | jq -r '.rw')"
    printf '  - source: '; yamlq "$src"; echo
    printf '    destination: '; yamlq "$dst"; echo
    echo "    rw: $rw"
  done
  printf 'unraid_template: '; if [[ -n "$TEMPLATE" ]]; then yamlq "$TEMPLATE"; else printf 'null'; fi; echo
  printf 'source_host_path: '; if [[ -n "$SOURCE_PATH" ]]; then yamlq "$SOURCE_PATH"; else printf 'null'; fi; echo
  printf 'installer_host_path: '; if [[ -n "$INSTALLER_PATH" ]]; then yamlq "$INSTALLER_PATH"; else printf 'null'; fi; echo
  echo "rollback_candidates:"
  if [[ -s "$TMP/rollback_candidates.txt" ]]; then
    while IFS= read -r f; do printf '  - '; yamlq "$f"; echo; done < "$TMP/rollback_candidates.txt"
  else
    echo "  []"
  fi
  echo "actions:"
  echo "  test: false"
  echo "  build: false"
  echo "  deploy: false"
  echo "  rollback: false"
} > "$PROJECT_DIR/DEPLOYMENT.yaml"

[[ -f "$PROJECT_DIR/AGENTS.md" ]] || cat > "$PROJECT_DIR/AGENTS.md" <<'DOC'
# AGENTS

Phoenix Dev Agent project workspace. Production access is project-scoped. Do not change production unless the project's explicit policy and action allow it.
DOC
[[ -f "$PROJECT_DIR/CHAT_CONTEXT.md" ]] || printf '# CHAT_CONTEXT\n\nNo chat checkpoint recorded yet.\n' > "$PROJECT_DIR/CHAT_CONTEXT.md"
[[ -f "$PROJECT_DIR/CHANGELOG.md" ]] || printf '# CHANGELOG\n\n' > "$PROJECT_DIR/CHANGELOG.md"

jq '{project_id, discovered_at, container: {name:.container.name,image:.container.image,status:.container.state.status}, associated_host_paths, log_files, unraid_template, source_host_path, installer_host_path, rollback_candidates, deployment_verified, authority}' "$PHOENIX_DIR/discovery.json"
