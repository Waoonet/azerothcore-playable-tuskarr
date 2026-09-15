#!/usr/bin/env bash
set -euo pipefail

CORE_ROOT="${CORE_ROOT:-/home/azeroth/azerothcore}"
EXPECTED_CORE="413bea61a85e20d9caef7d66fc601a661fdddd9d"
OUT="${1:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run as root"
[[ -n "$OUT" && -d "$OUT" ]] || fail "usage: $0 /root/tuskarr-fresh-build-YYYYMMDD-HHMMSS"
[[ -d "$CORE_ROOT/.git" ]] || fail "AzerothCore source tree missing: $CORE_ROOT"

BUILD_DIR="$OUT/build"
ARTIFACT_DIR="$OUT/artifact"
LOG_DIR="$OUT/logs"
CACHE="$BUILD_DIR/CMakeCache.txt"
COMPILE_DB="$BUILD_DIR/compile_commands.json"
NEW_BIN="$BUILD_DIR/src/server/apps/worldserver"
REPORT="$OUT/FRESH-BUILD-FINALIZE-REPORT.txt"
OLD_ROOT="/home/azeroth/update-work-20260910-145140/azerothcore"
ACTIVE_DB_PATH="$CORE_ROOT/src/server/database/Database/DatabaseWorkerPool.cpp"

mkdir -p "$ARTIFACT_DIR" "$LOG_DIR"
exec > >(tee "$REPORT") 2>&1

echo "===== Playable Tuskarr fresh-build finalizer ====="
echo "Core source:  $CORE_ROOT"
echo "Build output: $OUT"
echo "Mode:         AUDIT/PROMOTE ONLY - LIVE REALM IS NOT MODIFIED"

HEAD="$(git -C "$CORE_ROOT" rev-parse HEAD)"
[[ "$HEAD" == "$EXPECTED_CORE" ]] || fail "unexpected AzerothCore revision: $HEAD"
[[ -z "$(git -C "$CORE_ROOT" status --porcelain)" ]] || fail "AzerothCore working tree is not clean"
echo "PASS: active source tree is clean at audited revision $HEAD"

[[ -f "$CACHE" ]] || fail "missing CMakeCache.txt: $CACHE"
[[ -f "$COMPILE_DB" ]] || fail "missing compile_commands.json: $COMPILE_DB"
[[ -x "$NEW_BIN" ]] || fail "missing fresh worldserver binary: $NEW_BIN"

HOME_DIR="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$CACHE" | tail -n1)"
[[ "$HOME_DIR" == "$CORE_ROOT" ]] || fail "fresh CMake tree points at wrong source: $HOME_DIR"
if grep -Fq "$OLD_ROOT" "$CACHE" "$COMPILE_DB"; then
    fail "fresh build metadata references obsolete September 10 source tree"
fi
grep -Fq "$ACTIVE_DB_PATH" "$COMPILE_DB" || fail "DatabaseWorkerPool compile command does not reference active source"
echo "PASS: CMake and compile database provenance point only at active source"

DB_OBJ="$(find "$BUILD_DIR" -type f -name 'DatabaseWorkerPool.cpp.o' -print -quit)"
[[ -n "$DB_OBJ" && -f "$DB_OBJ" ]] || fail "DatabaseWorkerPool object not found in fresh build tree"
echo "Database object: $DB_OBJ"
stat -c 'owner=%U:%G mode=%a size=%s mtime=%y' "$DB_OBJ"
if grep -aFq "$OLD_ROOT" "$DB_OBJ"; then
    fail "DatabaseWorkerPool object embeds obsolete September 10 source path"
fi
echo "PASS: fresh database object contains no obsolete source-tree path"

echo
echo "===== Current MySQL compile/runtime verification ====="
command -v mysql_config >/dev/null || fail "mysql_config not found"
command -v g++ >/dev/null || fail "g++ not found"
PROBE_CPP="$OUT/mysql-finalize-probe.cpp"
PROBE_BIN="$OUT/mysql-finalize-probe"
cat > "$PROBE_CPP" <<'CPP'
#include <mysql.h>
#include <iostream>
int main()
{
    std::cout << "MYSQL_VERSION_ID=" << MYSQL_VERSION_ID << "\n";
    std::cout << "mysql_get_client_version=" << mysql_get_client_version() << "\n";
    std::cout << "mysql_get_client_info=" << mysql_get_client_info() << "\n";
    return MYSQL_VERSION_ID == mysql_get_client_version() ? 0 : 2;
}
CPP
# shellcheck disable=SC2046
g++ $(mysql_config --cflags) "$PROBE_CPP" -o "$PROBE_BIN" $(mysql_config --libs)
set +e
"$PROBE_BIN" | tee "$LOG_DIR/mysql-finalize-probe.txt"
PROBE_RC=${PIPESTATUS[0]}
set -e
rm -f "$PROBE_CPP" "$PROBE_BIN"
[[ "$PROBE_RC" -eq 0 ]] || fail "current MySQL headers/runtime do not match"
MYSQL_COMPILE_ID="$(sed -n 's/^MYSQL_VERSION_ID=//p' "$LOG_DIR/mysql-finalize-probe.txt" | tail -n1)"
MYSQL_RUNTIME_ID="$(sed -n 's/^mysql_get_client_version=//p' "$LOG_DIR/mysql-finalize-probe.txt" | tail -n1)"
[[ -n "$MYSQL_COMPILE_ID" && "$MYSQL_COMPILE_ID" == "$MYSQL_RUNTIME_ID" ]] || fail "MySQL version probe mismatch"
echo "PASS: current MySQL compile/runtime environment matches ($MYSQL_COMPILE_ID)"

echo
echo "===== Fresh binary audit ====="
stat -c 'owner=%U:%G mode=%a size=%s mtime=%y' "$NEW_BIN"
BIN_SHA="$(sha256sum "$NEW_BIN" | awk '{print $1}')"
echo "$BIN_SHA  $NEW_BIN"
ldd "$NEW_BIN" | grep -E 'mysql|mariadb' || fail "fresh worldserver is not linked to a MySQL client library"
if grep -aFq "$OLD_ROOT" "$NEW_BIN"; then
    fail "fresh worldserver embeds obsolete September 10 source path"
fi
echo "PASS: fresh worldserver contains no obsolete source-tree path"
echo "PASS: source provenance is established by the fresh CMake tree and compile database"

cp -a "$NEW_BIN" "$ARTIFACT_DIR/worldserver"
printf '%s  %s\n' "$BIN_SHA" "$ARTIFACT_DIR/worldserver" > "$ARTIFACT_DIR/worldserver.sha256"

BUNDLE="$(sed -nE 's/^Milestone 4:[[:space:]]+//p' "$OUT/FRESH-BUILD-REPORT.txt" 2>/dev/null | head -n1 || true)"
{
    printf 'CORE_ROOT=%q\n' "$CORE_ROOT"
    printf 'CORE_HEAD=%q\n' "$HEAD"
    printf 'BUILD_DIR=%q\n' "$BUILD_DIR"
    printf 'BUNDLE=%q\n' "$BUNDLE"
    printf 'MYSQL_VERSION_ID=%q\n' "$MYSQL_COMPILE_ID"
    printf 'WORLD_SERVER=%q\n' "$ARTIFACT_DIR/worldserver"
    printf 'WORLD_SERVER_SHA256=%q\n' "$BIN_SHA"
    printf 'PROVENANCE_GATE=%q\n' 'cmake+compile_commands+no-obsolete-path-v2'
} > "$OUT/BUILD-METADATA.env"

echo
echo "===== Fresh-build finalization result ====="
echo "SOURCE_PATH_MATCH=YES"
echo "MYSQL_BUILD_ENV_MATCH=YES"
echo "FRESH_CMAKE_HOME_MATCH=YES"
echo "OBSOLETE_SOURCE_PATH_IN_BINARY=NO"
echo "SOURCE_TREE_CLEAN=YES"
echo "RESULT: PASS"
echo "Artifact: $ARTIFACT_DIR/worldserver"
echo "Artifact SHA256: $BIN_SHA"
echo "Metadata: $OUT/BUILD-METADATA.env"
echo "Report: $REPORT"
echo "No live server, database, DBC, MPQ, or installed binary was modified."
