#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$PROJECT_ROOT/tools/install-live-poc.sh"
EXPECTED_BLOB="76817c2506ece6c315892dc8fd5b780abd7031bd"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run as root"
[[ -f "$BASE" ]] || fail "base installer missing: $BASE"

ACTUAL_BLOB="$(git -C "$PROJECT_ROOT" hash-object tools/install-live-poc.sh)"
[[ "$ACTUAL_BLOB" == "$EXPECTED_BLOB" ]] || fail "unexpected base installer revision: $ACTUAL_BLOB"

TMP="$PROJECT_ROOT/tools/.install-live-poc-v4.$$.sh"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

python3 - "$BASE" "$TMP" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])

replacements = {
    'strings "$ARTIFACT" | grep -Fq "$EXPECTED_CONF_DIR" || fail "artifact does not embed expected live config directory"':
        'grep -aFq "$EXPECTED_CONF_DIR" "$ARTIFACT" || fail "artifact does not embed expected live config directory"',
    'if strings "$ARTIFACT" | grep -Fq "$FRESH_OUT/stage/etc"; then':
        'if grep -aFq "$FRESH_OUT/stage/etc" "$ARTIFACT"; then',
}

for old, new in replacements.items():
    count = src.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one base-installer match, found {count}: {old}")
    src = src.replace(old, new)

out.write_text(src)
out.chmod(0o700)
PY

echo "PASS: prepared v4 installer with pipefail-safe binary config-path gates"
set +e
bash "$TMP" "$@"
RC=$?
set -e
cleanup
trap - EXIT
exit "$RC"
