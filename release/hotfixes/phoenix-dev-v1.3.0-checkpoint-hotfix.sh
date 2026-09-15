#!/bin/bash
set -euo pipefail

BASE="${PDA_BASE:-/mnt/user/appdata/phoenix-dev-agent}"
TARGET="$BASE/bin/phoenix-dev-workflow"
BACKUP_DIR="$BASE/releases/v1.3.0-checkpoint-hotfix"
BACKUP="$BACKUP_DIR/phoenix-dev-workflow.before"
TMP="$(mktemp /tmp/phoenix-dev-workflow-hotfix.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

[[ -f "$TARGET" ]] || fail "Phoenix workflow helper not found: $TARGET"
command -v python3 >/dev/null 2>&1 || fail "python3 is required."
command -v bash >/dev/null 2>&1 || fail "bash is required."

mkdir -p "$BACKUP_DIR"
if [[ ! -f "$BACKUP" ]]; then
  cp -p "$TARGET" "$BACKUP"
fi
cp -p "$TARGET" "$TMP"

log "Applying repeat-build checkpoint hotfix"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old = r'''checkpoint_source() {
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
'''

new = r'''checkpoint_source() {
  local message="${*:-}"
  local head
  [[ -d "$PROJECT_DIR/.git" ]] || fail "Project Git repository is missing."
  [[ -n "$message" ]] || message="Phoenix checkpoint $(date +%Y-%m-%d_%H-%M-%S)"

  # Stage the managed project files first. This makes repeated builds
  # idempotent and also includes new/deleted source files.
  git -C "$PROJECT_DIR" add source deployment PROJECT_STATE.md DEPLOYMENT.yaml CHANGELOG.md CHAT_CONTEXT.md AGENTS.md .gitignore 2>/dev/null || true

  if git -C "$PROJECT_DIR" diff --cached --quiet -- .; then
    stage "Workspace already clean"
  else
    stage "Creating Git checkpoint"
    git -C "$PROJECT_DIR" commit -q -m "$message"
  fi

  head="$(git -C "$PROJECT_DIR" rev-parse --verify HEAD 2>/dev/null || true)"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || fail "Unable to resolve one valid Git HEAD commit."
  printf '%s\n' "$head"
}
'''

old_short = '  short="$(git -C "$PROJECT_DIR" rev-parse --short=12 "$commit")"'
new_short = '''  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "Checkpoint returned an invalid Git commit: $commit"\n  short="${commit:0:12}"'''

if old in s:
    s = s.replace(old, new, 1)
elif new not in s:
    raise SystemExit("Expected checkpoint_source block was not found")

if old_short in s:
    s = s.replace(old_short, new_short, 1)
elif new_short not in s:
    raise SystemExit("Expected build commit-shortening line was not found")

p.write_text(s)
PY

bash -n "$TMP" || fail "Patched workflow helper failed shell syntax validation."
"$TMP" --self-test | grep -Fq 'self-test OK' || fail "Patched workflow helper self-test failed."

grep -Fq 'Unable to resolve one valid Git HEAD commit.' "$TMP" || fail "Checkpoint validation patch missing."
grep -Fq 'short="${commit:0:12}"' "$TMP" || fail "Candidate tag patch missing."

chmod --reference="$TARGET" "$TMP" 2>/dev/null || chmod +x "$TMP"
mv "$TMP" "$TARGET"
trap - EXIT

log "Phoenix repeat-build checkpoint hotfix installed"
echo "Backup: $BACKUP"
echo "Next: phoenix-dev build <project-id>"
