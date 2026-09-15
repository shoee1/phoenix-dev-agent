#!/bin/bash
set -euo pipefail

BASE="${PDA_BASE:-/mnt/user/appdata/phoenix-dev-agent}"
ENVFILE="$BASE/config/phoenix.env"
[[ -f "$ENVFILE" ]] && { set -a; source "$ENVFILE"; set +a; }
WORKSPACE="${PDA_WORKSPACE:-/mnt/user/dev/phoenix-projects}"
PID="${1:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }
stage() { printf '==> %s\n' "$*" >&2; }

if [[ "$PID" == "--self-test" ]]; then
  echo "phoenix-dev-adopt self-test OK"
  exit 0
fi

[[ -n "$PID" ]] || fail "Usage: phoenix-dev adopt <project-id>"
[[ "$PID" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Invalid project id."
for c in docker jq git find sha256sum awk sed sort xargs; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required."
done

PROJECT_JSON="$BASE/projects/$PID/project.json"
[[ -f "$PROJECT_JSON" ]] || fail "Project is not registered: $PID"
DISCOVER="$BASE/bin/phoenix-dev-discover"
[[ -x "$DISCOVER" ]] || fail "Discovery helper is not installed."

PROJECT_DIR="$WORKSPACE/$PID"
PHOENIX_DIR="$PROJECT_DIR/.phoenix"
DISCOVERY="$PHOENIX_DIR/discovery.json"
ADOPTION="$PHOENIX_DIR/adoption.json"
SOURCE_DIR="$PROJECT_DIR/source"
DEPLOY_DIR="$PROJECT_DIR/deployment"
mkdir -p "$PROJECT_DIR" "$PHOENIX_DIR"

stage "Refreshing read-only discovery for $PID"
"$DISCOVER" "$PID" >/dev/null
[[ -s "$DISCOVERY" ]] || fail "Discovery state was not created."

CONTAINER="$(jq -r '.container.name // empty' "$DISCOVERY")"
IMAGE="$(jq -r '.container.image // empty' "$DISCOVERY")"
IMAGE_ID="$(jq -r '.container.image_id // empty' "$DISCOVERY")"
WORKDIR="$(jq -r '.container.working_dir // empty' "$DISCOVERY")"
[[ -n "$CONTAINER" && -n "$IMAGE" && -n "$IMAGE_ID" ]] || fail "Discovery is missing container/image information."

CURRENT_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || true)"
[[ "$CURRENT_IMAGE_ID" == "$IMAGE_ID" ]] || fail "Production container image changed during adoption. Run discovery again."

if [[ -s "$ADOPTION" ]]; then
  PREV_IMAGE_ID="$(jq -r '.image_id // empty' "$ADOPTION")"
  if [[ "$PREV_IMAGE_ID" == "$IMAGE_ID" && -d "$SOURCE_DIR" && -n "$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    stage "Existing adopted baseline already matches the production image"
    jq '{project_id, adopted_at, image, image_id, source_host_path, baseline_commit, baseline_tag, production_untouched, build_verified, deployment_verified, authority}' "$ADOPTION"
    exit 0
  fi
  fail "A different adopted baseline already exists. Refusing to overwrite project source."
fi

if [[ -d "$SOURCE_DIR" && -n "$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  fail "Project source directory already contains files. Refusing to overwrite: $SOURCE_DIR"
fi
if [[ -d "$DEPLOY_DIR" && -n "$(find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  fail "Project deployment directory already contains files. Refusing to overwrite: $DEPLOY_DIR"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
NOW="$(date -Iseconds)"
STAGE_DIR="$PHOENIX_DIR/adopt-staging-$STAMP"
TEMP_CID=""
cleanup() {
  [[ -z "$TEMP_CID" ]] || docker rm -f "$TEMP_CID" >/dev/null 2>&1 || true
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT
mkdir -p "$STAGE_DIR/source" "$STAGE_DIR/deployment/entrypoints"

stage "Creating temporary baseline container from $IMAGE"
TEMP_CID="$(docker create "$IMAGE_ID")"
[[ -n "$TEMP_CID" ]] || fail "Could not create temporary baseline container."

COPY_ROOT="$WORKDIR"
[[ "$COPY_ROOT" == /* ]] || COPY_ROOT="/app"

stage "Extracting application baseline from image path $COPY_ROOT"
if ! docker cp "$TEMP_CID:$COPY_ROOT/." "$STAGE_DIR/source/"; then
  if [[ "$COPY_ROOT" != "/app" ]]; then
    stage "Primary workdir extraction failed; trying /app"
    docker cp "$TEMP_CID:/app/." "$STAGE_DIR/source/" || fail "Could not extract application source from the production image."
    COPY_ROOT="/app"
  else
    fail "Could not extract application source from the production image."
  fi
fi

[[ -n "$(find "$STAGE_DIR/source" -mindepth 1 -print -quit 2>/dev/null)" ]] || fail "Adopted source tree is empty."

stage "Capturing entrypoint and deployment metadata without secret values"
: > "$STAGE_DIR/deployment/entrypoints/manifest.tsv"
while IFS= read -r ep; do
  [[ -n "$ep" && "$ep" == /* ]] || continue
  name="$(basename "$ep")"
  if docker cp "$TEMP_CID:$ep" "$STAGE_DIR/deployment/entrypoints/$name" >/dev/null 2>&1; then
    printf '%s\t%s\n' "$ep" "$name" >> "$STAGE_DIR/deployment/entrypoints/manifest.tsv"
  fi
done < <(jq -r '.container.entrypoint[]? // empty' "$DISCOVERY")

jq '{
  adopted_from: {
    container: .container.name,
    image: .container.image,
    image_id: .container.image_id,
    image_created: .image.created,
    workdir: .container.working_dir,
    entrypoint: .container.entrypoint,
    cmd: .container.cmd
  },
  runtime: {
    restart_policy: .container.restart_policy,
    network_mode: .container.network_mode,
    ports: .container.ports,
    mounts: .container.mounts,
    env_names: .container.env_names,
    device_requests: .container.device_requests,
    labels: .container.labels
  },
  unraid_template: .unraid_template,
  secrets_redacted: true
}' "$DISCOVERY" > "$STAGE_DIR/deployment/runtime-baseline.json"

: > "$STAGE_DIR/deployment/rollback-manifest.tsv"
jq -r '.rollback_candidates[]? // empty' "$DISCOVERY" | while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  printf '%s\t%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')" >> "$STAGE_DIR/deployment/rollback-manifest.tsv"
done
jq -R -s '
  split("\n")
  | map(select(length > 0) | split("\t") | {path:.[0], sha256:.[1]})
' "$STAGE_DIR/deployment/rollback-manifest.tsv" > "$STAGE_DIR/deployment/rollback-manifest.json"
rm -f "$STAGE_DIR/deployment/rollback-manifest.tsv"

jq '{
  id: .id,
  display_name: .display_name,
  container: .container,
  container_image: .container_image,
  policy: .policy,
  actions: .actions
}' "$PROJECT_JSON" > "$STAGE_DIR/deployment/phoenix-project-baseline.json"

cat > "$STAGE_DIR/deployment/README.md" <<EOF
# Adopted deployment baseline

This baseline was extracted from the registered production image.

- Image: \`$IMAGE\`
- Image ID: \`$IMAGE_ID\`
- Image source path: \`$COPY_ROOT\`
- Adopted: \`$NOW\`
- Production modified: **No**
- Secret values captured: **No**
- Build reproduction verified: **No**
- Deployment verified: **No**

The Unraid template is referenced by path and SHA-256 only. Secret-bearing environment values are intentionally not copied into this workspace.
EOF

cat > "$PROJECT_DIR/.gitignore" <<'EOF'
.phoenix/
logs/
incidents/
__pycache__/
*.pyc
*.pyo
.DS_Store
EOF

stage "Installing adopted baseline into the Phoenix workspace"
rm -rf "$SOURCE_DIR" "$DEPLOY_DIR"
mv "$STAGE_DIR/source" "$SOURCE_DIR"
mv "$STAGE_DIR/deployment" "$DEPLOY_DIR"

stage "Creating source checksum manifest"
(
  cd "$SOURCE_DIR"
  find . -type f -print0 | sort -z | xargs -0 -r sha256sum
) > "$PHOENIX_DIR/adopted-source.sha256"

PROJECT_TMP="$PHOENIX_DIR/project-adopt.tmp.json"
jq \
  --arg ts "$NOW" \
  --arg src "$SOURCE_DIR" \
  --arg image "$IMAGE" \
  --arg image_id "$IMAGE_ID" \
  '.source_host_path = $src
   | .adoption = {
       status:"baseline",
       adopted_at:$ts,
       image:$image,
       image_id:$image_id,
       production_untouched:true,
       build_verified:false,
       deployment_verified:false
     }
   | .actions.test = false
   | .actions.build = false
   | .actions.deploy = false
   | .actions.rollback = false
   | .policy.auto_build = false
   | .policy.auto_deploy = false
  ' "$PROJECT_JSON" > "$PROJECT_TMP"
mv "$PROJECT_TMP" "$PROJECT_JSON"

if [[ -f "$PROJECT_DIR/DEPLOYMENT.yaml" ]]; then
  src_escaped="$(printf '%s' "$SOURCE_DIR" | sed "s/'/''/g")"
  sed -i "s#^source_host_path:.*#source_host_path: '$src_escaped'#" "$PROJECT_DIR/DEPLOYMENT.yaml"
  cat >> "$PROJECT_DIR/DEPLOYMENT.yaml" <<EOF

adoption:
  baseline_image: '$IMAGE'
  baseline_image_id: '$IMAGE_ID'
  adopted_at: '$NOW'
  production_untouched: true
  build_verified: false
  deployment_verified: false
EOF
fi

cat >> "$PROJECT_DIR/PROJECT_STATE.md" <<EOF

## Adopted baseline

- Adopted: \`$NOW\`
- Production image: \`$IMAGE\`
- Image ID: \`$IMAGE_ID\`
- Source workspace: \`$SOURCE_DIR\`
- Production modified: **No**
- Build reproduction verified: **No**
- Deployment verified: **No**
EOF

stage "Creating Git baseline"
if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  git -C "$PROJECT_DIR" init -q
fi
git -C "$PROJECT_DIR" config user.name >/dev/null 2>&1 || git -C "$PROJECT_DIR" config user.name "Phoenix Dev Agent"
git -C "$PROJECT_DIR" config user.email >/dev/null 2>&1 || git -C "$PROJECT_DIR" config user.email "phoenix-dev-agent@localhost"

git -C "$PROJECT_DIR" add \
  .gitignore \
  AGENTS.md \
  PROJECT_STATE.md \
  CHAT_CONTEXT.md \
  CHANGELOG.md \
  DEPLOYMENT.yaml \
  source \
  deployment

git -C "$PROJECT_DIR" diff --cached --quiet && fail "Nothing was staged for the adoption baseline."

git -C "$PROJECT_DIR" commit -q -m "Baseline adopt $IMAGE"
BASELINE_COMMIT="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
TAG_SUFFIX="$(printf '%s' "$IMAGE" | sed 's/[^A-Za-z0-9._-]/-/g')"
BASELINE_TAG="baseline-$TAG_SUFFIX"
git -C "$PROJECT_DIR" tag -f "$BASELINE_TAG" "$BASELINE_COMMIT" >/dev/null

jq -n \
  --arg project_id "$PID" \
  --arg adopted_at "$NOW" \
  --arg container "$CONTAINER" \
  --arg image "$IMAGE" \
  --arg image_id "$IMAGE_ID" \
  --arg source_host_path "$SOURCE_DIR" \
  --arg image_source_path "$COPY_ROOT" \
  --arg baseline_commit "$BASELINE_COMMIT" \
  --arg baseline_tag "$BASELINE_TAG" \
  '{
    project_id:$project_id,
    adopted_at:$adopted_at,
    container:$container,
    image:$image,
    image_id:$image_id,
    source_host_path:$source_host_path,
    image_source_path:$image_source_path,
    baseline_commit:$baseline_commit,
    baseline_tag:$baseline_tag,
    production_untouched:true,
    secrets_redacted:true,
    build_verified:false,
    deployment_verified:false,
    authority:{test:false,build:false,deploy:false,rollback:false}
  }' > "$ADOPTION"

stage "Adoption complete"
jq . "$ADOPTION"
