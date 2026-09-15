#!/bin/bash
set -euo pipefail
BASE="${PDA_BASE:-/mnt/user/appdata/phoenix-dev-agent}"
case "${1:-}" in
  discover)
    shift
    exec "$BASE/bin/phoenix-dev-discover" "$@"
    ;;
  *)
    exec "$BASE/bin/phoenix-dev-core" "$@"
    ;;
esac
