#!/bin/bash
set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/shoee1/phoenix-dev-agent/main/release"
BROKEN_INSTALLER_SHA256="e4866e3ec4cc7f9592ebd4414e6d9354879295e38f5fc1340b67ce99d06e6ccd"
OLD_WORKFLOW_SHA256="e3a7f844fc363981674678394fcd8d8e101ce223e360914661f1801e534b8d74"
NEW_WORKFLOW_SHA256="4507a62c9ea348a77fd729cf1beee0b4bfa8d2fea1c5d9e522e51868d9db1e91"

TMP="$(mktemp /tmp/phoenix-dev-v130-fixed.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

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

bash -n "$TMP" || die "Patched v1.3.0 installer failed shell syntax validation."

echo "==> v1.3.0 workflow checksum hotfix verified"
exec bash "$TMP" "$@"
