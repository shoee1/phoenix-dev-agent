#!/bin/bash
set -euo pipefail

BASE="${PDA_BASE:-/mnt/user/appdata/phoenix-dev-agent}"

show_help() {
  cat <<'EOF'
Phoenix Dev Agent helper

  phoenix-dev status
  phoenix-dev projects
  phoenix-dev logs <project-id> [lines]
  phoenix-dev sweep <project-id>
  phoenix-dev discover <project-id>
  phoenix-dev adopt <project-id>
  phoenix-dev verify <project-id>
  phoenix-dev checkpoint <project-id> [message]
  phoenix-dev build <project-id>
  phoenix-dev deploy <project-id>
  phoenix-dev rollback <project-id>
  phoenix-dev dev-status <project-id>
  phoenix-dev action <project-id> test|build|deploy|rollback
  phoenix-dev codex-login
  phoenix-dev codex-status
  phoenix-dev credentials

Project workflow:
  discover    Read-only project discovery and metadata refresh.
  adopt       Import the registered production image as a Git baseline.
  verify      Prove the adopted baseline matches the production image source.
  checkpoint  Commit current Phoenix workspace changes to Git.
  build       Build and verify a candidate overlay image from the workspace.
  deploy      Guarded production replacement with automatic rollback on failure.
  rollback    Restore the retained previous production container.
  dev-status  Show adoption/build/deployment state for the project.

Production is not changed by discover, adopt, verify, checkpoint, or build.
Deploy is explicit and retains the previous production container for rollback.
EOF
}

case "${1:-}" in
  discover)
    shift
    exec "$BASE/bin/phoenix-dev-discover" "$@"
    ;;
  adopt)
    shift
    exec "$BASE/bin/phoenix-dev-adopt" "$@"
    ;;
  verify|checkpoint|build|deploy|rollback|dev-status)
    cmd="$1"
    shift
    exec "$BASE/bin/phoenix-dev-workflow" "$cmd" "$@"
    ;;
  ""|-h|--help|help)
    show_help
    ;;
  *)
    exec "$BASE/bin/phoenix-dev-core" "$@"
    ;;
esac
