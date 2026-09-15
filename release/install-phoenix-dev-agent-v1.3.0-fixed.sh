#!/bin/bash
set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/main/release"
BROKEN_INSTALLER_SHA256="e4866e3ec4cc7f9592ebd4414e6d9354879295e38f5fc1340b67ce99d06e6ccd"
OLD_WORKFLOW_SHA256="e3a7f844fc363981674678394fcd8d8e101ce223e360914661f1801e534b8d74"
NEW_WORKFLOW_SHA256="4507a62c9ea348a77fd729cf1beee0b4bfa8d2fea1c5d9e522e51868d9db1e91"
REPEAT_FIX_URL="https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/fa7b4f304eaaf959305d6b085256896e1cb41a16/release/hotfixes/phoenix-dev-v1.3.0-repeat-build-hotfix-v3.sh"
REPEAT_FIX_SHA256="377c7adc5893f4979cc5f8ce012f5ff764ea9fd48ebaab48b137dc23f0af3fbd"

TMP="$(mktemp /tmp/phoenix-dev-v130-fixed.XXXXXX.sh)"
INJECTED="$(mktemp /tmp/phoenix-dev-v130-injected.XXXXXX.sh)"
trap 'rm -f "$TMP" "$INJECTED"' EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

for c in curl sha256sum awk sed bash grep; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required."
done

echo
echo "==> Fetching verified Phoenix Dev Agent v1.3.0 installer"
curl --fail --show-error --location --connect-timeout 15 --retry 3 \
  "$BASE_URL/install-phoenix-dev-agent.sh?cb=$(date +%s%N 2>/dev/null || date +%s)-$$" \
  -o "$TMP"

got="$(sha256sum "$TMP" | awk '{print $1}')"
[[ "$got" == "$BROKEN_INSTALLER_SHA256" ]] \
  || die "Base v1.3.0 installer checksum mismatch. Expected $BROKEN_INSTALLER_SHA256, got $got."

grep -Fq "$OLD_WORKFLOW_SHA256" "$TMP" \
  || die "Expected v1.3.0 workflow checksum field was not found."

sed -i "s/$OLD_WORKFLOW_SHA256/$NEW_WORKFLOW_SHA256/" "$TMP"

grep -Fq "WORKFLOW_SHA256=\"$NEW_WORKFLOW_SHA256\"" "$TMP" \
  || die "Workflow checksum hotfix did not apply."

awk -v fix_url="$REPEAT_FIX_URL" -v fix_sha="$REPEAT_FIX_SHA256" '
  /^log "Refreshing registered projects and preparing adopted projects for development"$/ && !done {
    print "log \"Applying tested repeat-build checkpoint fix\""
    print "REPEAT_FIX_TMP=\"$(mktemp /tmp/phoenix-dev-repeat-fix.XXXXXX.sh)\""
    print "curl --fail --show-error --location --connect-timeout 15 --retry 3 \\\\"
    print "  \"" fix_url "?cb=$(date +%s)-$$\" -o \"$REPEAT_FIX_TMP\""
    print "REPEAT_FIX_GOT=\"$(sha256sum \"$REPEAT_FIX_TMP\" | awk '\''{print $1}'\'')\""
    print "[[ \"$REPEAT_FIX_GOT\" == \"" fix_sha "\" ]] || die \"Repeat-build hotfix checksum mismatch.\""
    print "chmod +x \"$REPEAT_FIX_TMP\""
    print "bash \"$REPEAT_FIX_TMP\""
    print "rm -f \"$REPEAT_FIX_TMP\""
    print ""
    done=1
  }
  { print }
  END {
    if (!done) exit 42
  }
' "$TMP" > "$INJECTED" || die "Could not inject repeat-build fix into v1.3.0 installer."

mv "$INJECTED" "$TMP"

bash -n "$TMP" || die "Patched v1.3.0 installer failed shell syntax validation."

echo "==> v1.3.0 installer fixes verified"
exec bash "$TMP" "$@"
