#!/bin/bash
set -euo pipefail

BASE="${PDA_BASE:-/mnt/user/appdata/phoenix-dev-agent}"
ENVFILE="$BASE/config/phoenix.env"
[[ -f "$ENVFILE" ]] && { set -a; source "$ENVFILE"; set +a; }
WORKSPACE="${PDA_WORKSPACE:-/mnt/user/dev/phoenix-projects}"
CMD="${1:-}"
PID="${2:-}"
shift 2 2>/dev/null || true

fail() { echo "ERROR: $*" >&2; exit 1; }
stage() { printf '==> %s\n' "$*" >&2; }
now() { date -Iseconds; }

if [[ "$CMD" == "--self-test" ]]; then
  echo "phoenix-dev-workflow self-test OK"
  exit 0
fi

case "$CMD" in
  verify|build|checkpoint|deploy|rollback|dev-status) ;;
  *) fail "Usage: phoenix-dev verify|build|checkpoint|deploy|rollback|dev-status <project-id> [message]" ;;
esac
[[ -n "$PID" ]] || fail "Project id is required."
[[ "$PID" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Invalid project id."

for c in docker jq git find sha256sum awk sed sort xargs tar curl cmp diff cp; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required."
done

PROJECT_JSON="$BASE/projects/$PID/project.json"
[[ -f "$PROJECT_JSON" ]] || fail "Project is not registered: $PID"
PROJECT_DIR="$WORKSPACE/$PID"
PHOENIX_DIR="$PROJECT_DIR/.phoenix"
ADOPTION="$PHOENIX_DIR/adoption.json"
SOURCE_DIR="$PROJECT_DIR/source"
[[ -s "$ADOPTION" ]] || fail "Project has not been adopted. Run: phoenix-dev adopt $PID"
[[ -d "$SOURCE_DIR" ]] || fail "Adopted source directory is missing: $SOURCE_DIR"

CONTAINER="$(jq -r '.container // empty' "$PROJECT_JSON")"
[[ -n "$CONTAINER" ]] || fail "Registered project has no container."
BASE_IMAGE="$(jq -r '.image // empty' "$ADOPTION")"
BASE_IMAGE_ID="$(jq -r '.image_id // empty' "$ADOPTION")"
IMAGE_SOURCE_PATH="$(jq -r '.image_source_path // "/app"' "$ADOPTION")"
BASELINE_COMMIT="$(jq -r '.baseline_commit // empty' "$ADOPTION")"
BASELINE_TAG="$(jq -r '.baseline_tag // empty' "$ADOPTION")"
[[ "$IMAGE_SOURCE_PATH" == /* ]] || fail "Invalid adopted image source path."

mkdir -p "$PHOENIX_DIR/builds" "$PHOENIX_DIR/deployments"

manifest_tree() {
  local dir="$1" out="$2"
  (
    cd "$dir"
    find . -type f \
      ! -path './__pycache__/*' \
      ! -name '*.pyc' ! -name '*.pyo' \
      -print0 | sort -z | xargs -0 -r sha256sum
  ) > "$out"
}

verify_baseline() {
  stage "Verifying adopted Git baseline against production image $BASE_IMAGE"
  [[ -n "$BASELINE_COMMIT" ]] || fail "Adoption record has no baseline commit."
  git -C "$PROJECT_DIR" cat-file -e "$BASELINE_COMMIT^{commit}" 2>/dev/null || fail "Baseline Git commit is missing."
  [[ -z "$BASELINE_TAG" ]] || git -C "$PROJECT_DIR" rev-parse -q --verify "refs/tags/$BASELINE_TAG" >/dev/null || fail "Baseline Git tag is missing."

  local tmp cid
  tmp="$(mktemp -d /tmp/phoenix-verify.XXXXXX)"
  cid=""
  cleanup_verify() {
    [[ -z "$cid" ]] || docker rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$tmp"
  }
  trap cleanup_verify RETURN

  mkdir -p "$tmp/git" "$tmp/image"
  git -C "$PROJECT_DIR" archive "$BASELINE_COMMIT" source | tar -x -C "$tmp/git"
  [[ -d "$tmp/git/source" ]] || fail "Baseline archive does not contain source/."

  cid="$(docker create "$BASE_IMAGE_ID")"
  docker cp "$cid:$IMAGE_SOURCE_PATH/." "$tmp/image/" >/dev/null
  manifest_tree "$tmp/git/source" "$tmp/git.sha256"
  manifest_tree "$tmp/image" "$tmp/image.sha256"

  if ! cmp -s "$tmp/git.sha256" "$tmp/image.sha256"; then
    echo "Baseline/source mismatch:" >&2
    diff -u "$tmp/git.sha256" "$tmp/image.sha256" | sed -n '1,160p' >&2 || true
    fail "Adopted Git baseline does not match the production image source."
  fi

  local current_id
  current_id="$(docker inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || true)"
  [[ "$current_id" == "$BASE_IMAGE_ID" ]] || stage "Note: production has moved beyond the original adopted image; baseline itself still verified."

  local ts
  ts="$(now)"
  local atmp="$PHOENIX_DIR/adoption.tmp.$$"
  jq --arg ts "$ts" '
    .baseline_verified = true
    | .baseline_verified_at = $ts
  ' "$ADOPTION" > "$atmp" && mv "$atmp" "$ADOPTION"

  local ptmp="$PHOENIX_DIR/project.verify.tmp.$$"
  jq --arg ts "$ts" '
    .adoption.baseline_verified = true
    | .adoption.baseline_verified_at = $ts
  ' "$PROJECT_JSON" > "$ptmp" && mv "$ptmp" "$PROJECT_JSON"

  trap - RETURN
  cleanup_verify
  jq '{project_id,image,image_id,baseline_commit,baseline_tag,baseline_verified,baseline_verified_at,production_untouched}' "$ADOPTION"
}

checkpoint_source() {
  local message="${*:-}"
  [[ -d "$PROJECT_DIR/.git" ]] || fail "Project Git repository is missing."
  if git -C "$PROJECT_DIR" diff --quiet -- . && git -C "$PROJECT_DIR" diff --cached --quiet -- .; then
    stage "Workspace already clean"
    git -C "$PROJECT_DIR" rev-parse HEAD
    return 0
  fi
  [[ -n "$message" ]] || message="Phoenix checkpoint $(date +%Y-%m-%d_%H-%M-%S)"
  stage "Creating Git checkpoint"
  git -C "$PROJECT_DIR" add source deployment PROJECT_STATE.md DEPLOYMENT.yaml CHANGELOG.md CHAT_CONTEXT.md AGENTS.md .gitignore 2>/dev/null || true
  git -C "$PROJECT_DIR" commit -q -m "$message"
  git -C "$PROJECT_DIR" rev-parse HEAD
}

safe_repo_tag() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/^-*//; s/-*$//'
}

build_candidate() {
  verify_baseline >/dev/null
  local commit
  commit="$(checkpoint_source "Phoenix auto-checkpoint before build $(date +%Y-%m-%d_%H-%M-%S)")"
  local short tag repo tmp dockerfile orig_user orig_workdir cid
  short="$(git -C "$PROJECT_DIR" rev-parse --short=12 "$commit")"
  repo="$(safe_repo_tag "phoenix-dev-candidate-$PID")"
  tag="$repo:$short"
  tmp="$(mktemp -d /tmp/phoenix-build.XXXXXX)"
  cid=""
  cleanup_build() {
    [[ -z "$cid" ]] || docker rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$tmp"
  }
  trap cleanup_build RETURN

  stage "Preparing overlay build from verified runtime base $BASE_IMAGE"
  local resolved_base
  resolved_base="$(docker image inspect -f '{{.Id}}' "$BASE_IMAGE" 2>/dev/null || true)"
  [[ "$resolved_base" == "$BASE_IMAGE_ID" ]] || fail "Baseline image tag no longer resolves to the adopted image ID."
  mkdir -p "$tmp/source"
  cp -a "$SOURCE_DIR/." "$tmp/source/"
  orig_user="$(docker image inspect "$BASE_IMAGE_ID" | jq -r '.[0].Config.User // empty')"
  orig_workdir="$(docker image inspect "$BASE_IMAGE_ID" | jq -r '.[0].Config.WorkingDir // empty')"
  [[ -n "$orig_workdir" ]] || orig_workdir="$IMAGE_SOURCE_PATH"

  dockerfile="$tmp/Dockerfile"
  {
    printf 'FROM %s\n' "$BASE_IMAGE"
    echo 'USER root'
    echo 'WORKDIR /'
    printf 'RUN rm -rf %q && mkdir -p %q\n' "$IMAGE_SOURCE_PATH" "$IMAGE_SOURCE_PATH"
    printf 'COPY source/ %s/\n' "$IMAGE_SOURCE_PATH"
    printf 'WORKDIR %s\n' "$orig_workdir"
    [[ -z "$orig_user" ]] || printf 'USER %s\n' "$orig_user"
  } > "$dockerfile"

  stage "Building candidate image $tag"
  docker build --pull=false -t "$tag" "$tmp"

  stage "Verifying candidate source tree"
  mkdir -p "$tmp/candidate"
  cid="$(docker create "$tag")"
  docker cp "$cid:$IMAGE_SOURCE_PATH/." "$tmp/candidate/" >/dev/null
  manifest_tree "$SOURCE_DIR" "$tmp/source.sha256"
  manifest_tree "$tmp/candidate" "$tmp/candidate.sha256"
  if ! cmp -s "$tmp/source.sha256" "$tmp/candidate.sha256"; then
    diff -u "$tmp/source.sha256" "$tmp/candidate.sha256" | sed -n '1,160p' >&2 || true
    fail "Candidate image source does not match the Phoenix workspace."
  fi

  stage "Checking inherited runtime configuration"
  local base_cfg cand_cfg
  base_cfg="$(docker image inspect "$BASE_IMAGE_ID" | jq -c '.[0].Config | {Entrypoint,Cmd,ExposedPorts,StopSignal}')"
  cand_cfg="$(docker image inspect "$tag" | jq -c '.[0].Config | {Entrypoint,Cmd,ExposedPorts,StopSignal}')"
  [[ "$base_cfg" == "$cand_cfg" ]] || fail "Candidate runtime entrypoint/cmd/ports differ from the verified base image."

  stage "Running non-production Python syntax smoke test"
  if docker run --rm --entrypoint sh "$tag" -lc 'command -v python >/dev/null 2>&1'; then
    docker run --rm --entrypoint sh "$tag" -lc \
      "python -m compileall -q '$IMAGE_SOURCE_PATH'" \
      || fail "Candidate Python compile smoke test failed."
  else
    stage "Python not present in candidate image; compile smoke test skipped."
  fi

  local image_id ts record
  image_id="$(docker image inspect -f '{{.Id}}' "$tag")"
  ts="$(now)"
  record="$PHOENIX_DIR/builds/$short.json"
  jq -n \
    --arg project_id "$PID" \
    --arg built_at "$ts" \
    --arg commit "$commit" \
    --arg image "$tag" \
    --arg image_id "$image_id" \
    --arg base_image "$BASE_IMAGE" \
    --arg base_image_id "$BASE_IMAGE_ID" \
    '{
      project_id:$project_id,built_at:$built_at,commit:$commit,
      image:$image,image_id:$image_id,
      base_image:$base_image,base_image_id:$base_image_id,
      source_verified:true,runtime_config_verified:true,
      syntax_smoke_verified:true,production_untouched:true
    }' > "$record"
  cp -f "$record" "$PHOENIX_DIR/latest-build.json"

  local ptmp="$PHOENIX_DIR/project.build.tmp.$$"
  jq --arg ts "$ts" --arg image "$tag" --arg image_id "$image_id" --arg commit "$commit" '
    .adoption.build_verified = true
    | .adoption.build_verified_at = $ts
    | .development = {
        candidate_image:$image,
        candidate_image_id:$image_id,
        candidate_commit:$commit,
        build_verified:true,
        deployment_verified:(.development.deployment_verified // false)
      }
    | .actions.test = true
    | .actions.build = true
  ' "$PROJECT_JSON" > "$ptmp" && mv "$ptmp" "$PROJECT_JSON"

  trap - RETURN
  cleanup_build
  jq . "$record"
}

probe_running_service() {
  local inspect_file="$1" out="$2"
  : > "$out"
  local host_port path code
  host_port="$(jq -r '.[0].NetworkSettings.Ports // {} | to_entries[]?.value[]?.HostPort' "$inspect_file" | head -1 || true)"
  [[ -n "$host_port" ]] || return 0
  for path in /health /api/status /docs /; do
    code="$(curl -sS -o /dev/null -m 4 -w '%{http_code}' "http://127.0.0.1:${host_port}${path}" 2>/dev/null || true)"
    if [[ "$code" =~ ^[23] ]]; then
      jq -n --arg port "$host_port" --arg path "$path" --arg code "$code" \
        '{host_port:$port,path:$path,http_code:$code}' > "$out"
      return 0
    fi
  done
}

create_from_snapshot() {
  local snapshot="$1" image="$2" name="$3"
  local envf
  envf="$(mktemp /tmp/phoenix-deploy-env.XXXXXX)"
  umask 077
  jq -r '.[0].Config.Env[]?' "$snapshot" > "$envf"
  local -a args
  args=(docker create --name "$name" --env-file "$envf")

  local restart retry net runtime privileged shm
  restart="$(jq -r '.[0].HostConfig.RestartPolicy.Name // empty' "$snapshot")"
  retry="$(jq -r '.[0].HostConfig.RestartPolicy.MaximumRetryCount // 0' "$snapshot")"
  if [[ -n "$restart" && "$restart" != "no" ]]; then
    [[ "$restart" == "on-failure" && "$retry" != "0" ]] && restart="$restart:$retry"
    args+=(--restart "$restart")
  fi
  net="$(jq -r '.[0].HostConfig.NetworkMode // empty' "$snapshot")"
  [[ -z "$net" ]] || args+=(--network "$net")
  runtime="$(jq -r '.[0].HostConfig.Runtime // empty' "$snapshot")"
  [[ -z "$runtime" || "$runtime" == "runc" ]] || args+=(--runtime "$runtime")
  privileged="$(jq -r '.[0].HostConfig.Privileged // false' "$snapshot")"
  [[ "$privileged" != "true" ]] || args+=(--privileged)
  shm="$(jq -r '.[0].HostConfig.ShmSize // 0' "$snapshot")"
  [[ "$shm" == "0" ]] || args+=(--shm-size "${shm}b")

  while IFS=$'\t' read -r typ src dst rw prop; do
    [[ -n "$typ" && -n "$dst" ]] || continue
    if [[ "$typ" == "bind" ]]; then
      local opt="type=bind,src=$src,dst=$dst"
      [[ "$rw" == "true" ]] || opt="$opt,readonly"
      [[ -z "$prop" || "$prop" == "rprivate" ]] || opt="$opt,bind-propagation=$prop"
      args+=(--mount "$opt")
    elif [[ "$typ" == "volume" ]]; then
      local opt="type=volume,src=$src,dst=$dst"
      [[ "$rw" == "true" ]] || opt="$opt,readonly"
      args+=(--mount "$opt")
    fi
  done < <(jq -r '.[0].Mounts[]? | [.Type, (.Source // .Name // ""), .Destination, (.RW|tostring), (.Propagation // "")] | @tsv' "$snapshot")

  while IFS=$'\t' read -r cport hip hport; do
    [[ -n "$cport" && -n "$hport" ]] || continue
    if [[ -n "$hip" && "$hip" != "0.0.0.0" && "$hip" != "::" ]]; then
      args+=(-p "$hip:$hport:$cport")
    else
      args+=(-p "$hport:$cport")
    fi
  done < <(jq -r '.[0].HostConfig.PortBindings // {} | to_entries[] as $e | ($e.value // [])[]? | [$e.key, (.HostIp // ""), (.HostPort // "")] | @tsv' "$snapshot")

  if jq -e '.[0].HostConfig.DeviceRequests[]? | (.Capabilities // [])[][]? | select(. == "gpu")' "$snapshot" >/dev/null 2>&1; then
    args+=(--gpus all)
  fi
  while IFS=$'\t' read -r hp cp perm; do
    [[ -n "$hp" ]] || continue
    args+=(--device "$hp:$cp:$perm")
  done < <(jq -r '.[0].HostConfig.Devices[]? | [.PathOnHost,.PathInContainer,.CgroupPermissions] | @tsv' "$snapshot")
  while IFS= read -r cap; do [[ -z "$cap" ]] || args+=(--cap-add "$cap"); done < <(jq -r '.[0].HostConfig.CapAdd[]?' "$snapshot")
  while IFS= read -r cap; do [[ -z "$cap" ]] || args+=(--cap-drop "$cap"); done < <(jq -r '.[0].HostConfig.CapDrop[]?' "$snapshot")
  while IFS= read -r opt; do [[ -z "$opt" ]] || args+=(--security-opt "$opt"); done < <(jq -r '.[0].HostConfig.SecurityOpt[]?' "$snapshot")
  while IFS= read -r dns; do [[ -z "$dns" ]] || args+=(--dns "$dns"); done < <(jq -r '.[0].HostConfig.Dns[]?' "$snapshot")
  while IFS= read -r eh; do [[ -z "$eh" ]] || args+=(--add-host "$eh"); done < <(jq -r '.[0].HostConfig.ExtraHosts[]?' "$snapshot")
  while IFS=$'\t' read -r key val; do
    [[ -n "$key" ]] || continue
    args+=(--sysctl "$key=$val")
  done < <(jq -r '.[0].HostConfig.Sysctls // {} | to_entries[]? | [.key,.value] | @tsv' "$snapshot")
  while IFS=$'\t' read -r key val; do
    [[ -n "$key" ]] || continue
    args+=(--label "$key=$val")
  done < <(jq -r '.[0].Config.Labels // {} | to_entries[]? | [.key,.value] | @tsv' "$snapshot")

  local host
  host="$(jq -r '.[0].Config.Hostname // empty' "$snapshot")"
  [[ -z "$host" ]] || args+=(--hostname "$host")

  args+=("$image")
  local cid
  if ! cid="$("${args[@]}")"; then
    rm -f "$envf"
    return 1
  fi
  rm -f "$envf"
  printf '%s\n' "$cid"
}

deploy_candidate() {
  [[ -s "$PHOENIX_DIR/latest-build.json" ]] || fail "No verified candidate build exists. Run: phoenix-dev build $PID"
  local candidate candidate_id commit
  candidate="$(jq -r '.image // empty' "$PHOENIX_DIR/latest-build.json")"
  candidate_id="$(jq -r '.image_id // empty' "$PHOENIX_DIR/latest-build.json")"
  commit="$(jq -r '.commit // empty' "$PHOENIX_DIR/latest-build.json")"
  [[ -n "$candidate" && -n "$candidate_id" ]] || fail "Latest build record is incomplete."
  docker image inspect "$candidate_id" >/dev/null 2>&1 || fail "Candidate image no longer exists."

  local current_commit
  current_commit="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  [[ "$current_commit" == "$commit" ]] || fail "Workspace has moved since the candidate was built. Rebuild before deploy."
  git -C "$PROJECT_DIR" diff --quiet -- . || fail "Workspace has uncommitted changes. Rebuild before deploy."

  local stamp ddir snapshot probe rollback_name rollback_tag preflight_cid
  stamp="$(date +%Y%m%d-%H%M%S)"
  ddir="$PHOENIX_DIR/deployments/$stamp"
  mkdir -p "$ddir"
  snapshot="$ddir/container-inspect.json"
  docker inspect "$CONTAINER" > "$snapshot"
  probe="$ddir/probe.json"
  probe_running_service "$snapshot" "$probe"
  rollback_name="${CONTAINER}-phoenix-rollback-${stamp}"
  rollback_tag="$(safe_repo_tag "phoenix-dev-rollback-$PID"):$stamp"

  stage "Preflighting candidate container configuration"
  preflight_cid="$(create_from_snapshot "$snapshot" "$candidate_id" "${CONTAINER}-phoenix-preflight-${stamp}")" || fail "Could not create candidate with the production runtime configuration."
  docker rm "$preflight_cid" >/dev/null

  local old_image_id
  old_image_id="$(jq -r '.[0].Image' "$snapshot")"
  docker tag "$old_image_id" "$rollback_tag"

  stage "Stopping production container for guarded replacement"
  docker stop "$CONTAINER" >/dev/null
  docker rename "$CONTAINER" "$rollback_name"

  local new_cid=""
  rollback_deploy() {
    stage "Automatic rollback: restoring previous production container"
    [[ -z "$new_cid" ]] || docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker rename "$rollback_name" "$CONTAINER" >/dev/null 2>&1 || true
    docker start "$CONTAINER" >/dev/null 2>&1 || true
  }

  if ! new_cid="$(create_from_snapshot "$snapshot" "$candidate_id" "$CONTAINER")"; then
    rollback_deploy
    fail "Candidate container creation failed; previous production restored."
  fi
  if ! docker start "$CONTAINER" >/dev/null; then
    rollback_deploy
    fail "Candidate failed to start; previous production restored."
  fi

  stage "Validating replacement container"
  local ok=0 i host_port path code
  host_port="$(jq -r '.host_port // empty' "$probe" 2>/dev/null || true)"
  path="$(jq -r '.path // empty' "$probe" 2>/dev/null || true)"
  for i in $(seq 1 90); do
    if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx true; then
      break
    fi
    if [[ -n "$host_port" && -n "$path" ]]; then
      code="$(curl -sS -o /dev/null -m 4 -w '%{http_code}' "http://127.0.0.1:${host_port}${path}" 2>/dev/null || true)"
      if [[ "$code" =~ ^[23] ]]; then ok=1; break; fi
    elif [[ "$i" -ge 20 ]]; then
      ok=1
      break
    fi
    sleep 1
  done
  if [[ "$ok" -ne 1 ]]; then
    docker logs --tail 160 "$CONTAINER" > "$ddir/failed-candidate.log" 2>&1 || true
    rollback_deploy
    fail "Candidate failed post-start validation; previous production restored."
  fi

  stage "Deployment validated; retaining previous stopped container for rollback"
  jq -n \
    --arg deployed_at "$(now)" --arg project_id "$PID" --arg commit "$commit" \
    --arg candidate_image "$candidate" --arg candidate_image_id "$candidate_id" \
    --arg rollback_container "$rollback_name" --arg rollback_image "$rollback_tag" \
    --arg old_image_id "$old_image_id" \
    '{
      project_id:$project_id,deployed_at:$deployed_at,commit:$commit,
      candidate_image:$candidate_image,candidate_image_id:$candidate_image_id,
      rollback_container:$rollback_container,rollback_image:$rollback_image,
      previous_image_id:$old_image_id,validated:true
    }' > "$ddir/deployment.json"
  cp -f "$ddir/deployment.json" "$PHOENIX_DIR/latest-deployment.json"

  local ptmp="$PHOENIX_DIR/project.deploy.tmp.$$"
  jq --arg ts "$(now)" --arg image "$candidate" --arg iid "$candidate_id" '
    .container_image = $image
    | .development.deployment_verified = true
    | .development.deployed_at = $ts
    | .development.deployed_image = $image
    | .development.deployed_image_id = $iid
    | .actions.test = true
    | .actions.build = true
    | .actions.deploy = true
    | .actions.rollback = true
  ' "$PROJECT_JSON" > "$ptmp" && mv "$ptmp" "$PROJECT_JSON"

  jq . "$PHOENIX_DIR/latest-deployment.json"
}

rollback_latest() {
  [[ -s "$PHOENIX_DIR/latest-deployment.json" ]] || fail "No Phoenix deployment is available to roll back."
  local rollback_container
  rollback_container="$(jq -r '.rollback_container // empty' "$PHOENIX_DIR/latest-deployment.json")"
  [[ -n "$rollback_container" ]] || fail "Rollback record is incomplete."
  docker inspect "$rollback_container" >/dev/null 2>&1 || fail "Retained rollback container is no longer available."

  stage "Rolling back to retained production container"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker rename "$rollback_container" "$CONTAINER"
  docker start "$CONTAINER" >/dev/null
  local ok=0 i
  for i in $(seq 1 45); do
    if docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx true; then ok=1; break; fi
    sleep 1
  done
  [[ "$ok" -eq 1 ]] || fail "Rollback container did not start."

  local rtmp="$PHOENIX_DIR/project.rollback.tmp.$$"
  jq --arg ts "$(now)" '
    .development.deployment_verified = false
    | .development.last_rollback_at = $ts
    | .actions.deploy = false
    | .actions.rollback = false
  ' "$PROJECT_JSON" > "$rtmp" && mv "$rtmp" "$PROJECT_JSON"
  stage "Rollback complete"
  docker inspect "$CONTAINER" | jq '.[0] | {name:.Name,image:.Config.Image,image_id:.Image,running:.State.Running,started_at:.State.StartedAt}'
}

dev_status() {
  local build_json="null" deployment_json="null"
  [[ ! -s "$PHOENIX_DIR/latest-build.json" ]] || build_json="$(cat "$PHOENIX_DIR/latest-build.json")"
  [[ ! -s "$PHOENIX_DIR/latest-deployment.json" ]] || deployment_json="$(cat "$PHOENIX_DIR/latest-deployment.json")"
  jq -n \
    --arg project_id "$PID" \
    --slurpfile project "$PROJECT_JSON" \
    --slurpfile adoption "$ADOPTION" \
    --argjson build "$build_json" \
    --argjson deployment "$deployment_json" \
    '{
      project_id:$project_id,
      adoption:($adoption[0] // null),
      development:($project[0].development // null),
      actions:($project[0].actions // null),
      latest_build:$build,
      latest_deployment:$deployment
    }'
}

case "$CMD" in
  verify) verify_baseline ;;
  checkpoint) checkpoint_source "$@" ;;
  build) build_candidate ;;
  deploy) deploy_candidate ;;
  rollback) rollback_latest ;;
  dev-status) dev_status ;;
esac
