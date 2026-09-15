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
  phoenix-dev action <project-id> test|build|deploy|rollback
  phoenix-dev codex-login
  phoenix-dev codex-status
  phoenix-dev credentials

Project onboarding:
  discover  Read-only project discovery and metadata refresh.
  adopt     Import the registered production image into the Phoenix workspace
            as a Git baseline without modifying production.

Build/deploy/rollback remain disabled until separately verified and enabled.
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
  ""|-h|--help|help)
    show_help
    ;;
  *)
    exec "$BASE/bin/phoenix-dev-core" "$@"
    ;;
esac
