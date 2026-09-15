#!/bin/bash
set -euo pipefail

BASE="${PDA_BASE:-/mnt/user/appdata/phoenix-dev-agent}"
TARGET="$BASE/bin/phoenix-dev-workflow"
BACKUP_DIR="$BASE/releases/v1.3.0-repeat-build-hotfix-v2"
BACKUP="$BACKUP_DIR/phoenix-dev-workflow.before"
TMP="$(mktemp /tmp/phoenix-dev-workflow-hotfix-v2.XXXXXX)"
trap 'rm -f "$TMP" "$TMP.part1" "$TMP.part2"' EXIT

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

[[ -f "$TARGET" ]] || fail "Phoenix workflow helper not found: $TARGET"
for c in bash awk grep git cp mv chmod mkdir mktemp; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required."
done

mkdir -p "$BACKUP_DIR"
if [[ ! -f "$BACKUP" ]]; then
  cp -p "$TARGET" "$BACKUP"
fi

# Keep everything before checkpoint_source().
awk '
  /^checkpoint_source\(\) \{/ { exit }
  { print }
' "$TARGET" > "$TMP.part1"

# Keep safe_repo_tag() onward, while replacing the brittle short-SHA derivation.
awk '
  BEGIN { keep=0 }
  /^safe_repo_tag\(\) \{/ { keep=1 }
  keep {
    if ($0 == "  short=\"$(git -C \"$PROJECT_DIR\" rev-parse --short=12 \"$commit\")\"") {
      print "  [[ \"$commit\" =~ ^[0-9a-f]{40}$ ]] || fail \"Checkpoint returned an invalid Git commit: $commit\""
      print "  short=\"${commit:0:12}\""
    } else {
      print
    }
  }
' "$TARGET" > "$TMP.part2"

cat "$TMP.part1" > "$TMP"
cat >> "$TMP" <<'PATCHED_FUNCTION'
checkpoint_source() {
  local message="${*:-}"
  local head
  [[ -d "$PROJECT_DIR/.git" ]] || fail "Project Git repository is missing."
  [[ -n "$message" ]] || message="Phoenix checkpoint $(date +%Y-%m-%d_%H-%M-%S)"

  # Always stage the managed project files first. This includes new/deleted
  # source files and makes repeated builds deterministic.
  git -C "$PROJECT_DIR" add source deployment PROJECT_STATE.md DEPLOYMENT.yaml CHANGELOG.md CHAT_CONTEXT.md AGENTS.md .gitignore 2>/dev/null || true

  if git -C "$PROJECT_DIR" diff --cached --quiet -- .; then
    stage "Workspace already clean"
  else
    stage "Creating Git checkpoint"
    git -C "$PROJECT_DIR" commit -q -m "$message" || fail "Git checkpoint commit failed."
  fi

  head="$(git -C "$PROJECT_DIR" rev-parse --verify HEAD 2>/dev/null || true)"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || fail "Unable to resolve one valid Git HEAD commit."
  printf '%s\n' "$head"
}

PATCHED_FUNCTION
cat "$TMP.part2" >> "$TMP"

bash -n "$TMP" || fail "Patched workflow helper failed shell syntax validation."
"$TMP" --self-test | grep -Fq 'self-test OK' || fail "Patched workflow helper self-test failed."
grep -Fq 'Unable to resolve one valid Git HEAD commit.' "$TMP" || fail "HEAD validation patch missing."
grep -Fq 'short="${commit:0:12}"' "$TMP" || fail "Candidate tag patch missing."

chmod --reference="$TARGET" "$TMP" 2>/dev/null || chmod +x "$TMP"
mv "$TMP" "$TARGET"
trap - EXIT
rm -f "$TMP.part1" "$TMP.part2"

log "Phoenix repeat-build hotfix v2 installed"
echo "Backup: $BACKUP"
echo "Next: phoenix-dev build filament-buyer"
