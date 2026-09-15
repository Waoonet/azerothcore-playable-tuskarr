#!/usr/bin/env bash
set -euo pipefail

CORE_ROOT="${CORE_ROOT:-/home/azeroth/azerothcore}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${1:-}"
JOBS="${JOBS:-16}"
EXPECTED_CORE="413bea61a85e20d9caef7d66fc601a661fdddd9d"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run as root"
[[ -n "$BUNDLE" && -d "$BUNDLE" ]] || fail "usage: $0 /root/tuskarr-milestone4-YYYYMMDD-HHMMSS"
[[ -d "$CORE_ROOT/.git" ]] || fail "AzerothCore source tree missing: $CORE_ROOT"

PATCH="$BUNDLE/server/core/playerbots-exclude-tuskarr-random-generation.patch"
[[ -f "$PATCH" ]] || fail "playerbots safeguard patch missing from bundle"

HEAD="$(git -C "$CORE_ROOT" rev-parse HEAD)"
[[ "$HEAD" == "$EXPECTED_CORE" ]] || fail "unexpected AzerothCore revision: $HEAD"
[[ -z "$(git -C "$CORE_ROOT" status --porcelain)" ]] || fail "AzerothCore working tree is not clean"
git -C "$CORE_ROOT" apply --check "$PATCH"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/root/tuskarr-fresh-build-$STAMP"
BUILD_DIR="$OUT/build"
STAGE_DIR="$OUT/stage"
ARTIFACT_DIR="$OUT/artifact"
LOG_DIR="$OUT/logs"
mkdir -p "$BUILD_DIR" "$STAGE_DIR" "$ARTIFACT_DIR" "$LOG_DIR"
chmod 700 "$OUT"
REPORT="$OUT/FRESH-BUILD-REPORT.txt"
exec > >(tee "$REPORT") 2>&1

TARGET_CPP="$CORE_ROOT/modules/mod-playerbots/src/Bot/Factory/RandomPlayerbotFactory.cpp"
ORIGINAL_CPP="$OUT/RandomPlayerbotFactory.cpp.original"
cp -a "$TARGET_CPP" "$ORIGINAL_CPP"
PATCH_APPLIED=0

restore_source() {
    if (( PATCH_APPLIED == 1 )); then
        cp -a "$ORIGINAL_CPP" "$TARGET_CPP"
        PATCH_APPLIED=0
    fi
}
on_exit() {
    local rc=$?
    restore_source
    if [[ -d "$CORE_ROOT/.git" ]]; then
        local dirty
        dirty="$(git -C "$CORE_ROOT" status --porcelain || true)"
        if [[ -n "$dirty" ]]; then
            echo "WARNING: source tree is not clean after staging:" >&2
            echo "$dirty" >&2
        fi
    fi
    exit "$rc"
}
trap on_exit EXIT

echo "===== Playable Tuskarr fresh worldserver staging ====="
echo "Core source:    $CORE_ROOT"
echo "Core HEAD:      $HEAD"
echo "Milestone 4:    $BUNDLE"
echo "Output:         $OUT"
echo "Fresh build:    $BUILD_DIR"
echo "Install stage:  $STAGE_DIR"
echo "Parallel jobs:  $JOBS"
echo "Mode:           BUILD/STAGE ONLY - LIVE REALM IS NOT MODIFIED"

echo
echo "===== Active source configuration ====="
if [[ -f "$CORE_ROOT/conf/config.cmake" ]]; then
    echo "Custom conf/config.cmake present:"
    sha256sum "$CORE_ROOT/conf/config.cmake"
    sed -n '1,240p' "$CORE_ROOT/conf/config.cmake"
else
    echo "No custom conf/config.cmake; AzerothCore defaults apply."
fi

echo
echo "===== Current MySQL compile/runtime gate ====="
command -v mysql_config >/dev/null || fail "mysql_config not found"
command -v g++ >/dev/null || fail "g++ not found"
PROBE_CPP="$OUT/mysql-version-probe.cpp"
PROBE_BIN="$OUT/mysql-version-probe"
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
"$PROBE_BIN" | tee "$LOG_DIR/mysql-probe.txt"
PROBE_RC=${PIPESTATUS[0]}
set -e
[[ "$PROBE_RC" -eq 0 ]] || fail "current MySQL headers/runtime do not match"
MYSQL_COMPILE_ID="$(sed -n 's/^MYSQL_VERSION_ID=//p' "$LOG_DIR/mysql-probe.txt" | tail -n1)"
MYSQL_RUNTIME_ID="$(sed -n 's/^mysql_get_client_version=//p' "$LOG_DIR/mysql-probe.txt" | tail -n1)"
[[ -n "$MYSQL_COMPILE_ID" && "$MYSQL_COMPILE_ID" == "$MYSQL_RUNTIME_ID" ]] || fail "MySQL version probe mismatch"
echo "PASS: current MySQL build environment is internally consistent ($MYSQL_COMPILE_ID)"

echo
echo "===== Apply staged playerbots safeguard to active source ====="
git -C "$CORE_ROOT" apply "$PATCH"
PATCH_APPLIED=1
git -C "$CORE_ROOT" apply -R --check "$PATCH"
echo "PASS: playerbots safeguard applied temporarily"

echo
echo "===== Fresh CMake configure ====="
cmake -S "$CORE_ROOT" -B "$BUILD_DIR" \
    -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX="$STAGE_DIR" \
    2>&1 | tee "$LOG_DIR/cmake-configure.log"

CACHE="$BUILD_DIR/CMakeCache.txt"
[[ -f "$CACHE" ]] || fail "fresh CMakeCache.txt missing"
HOME_DIR="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$CACHE" | tail -n1)"
PREFIX="$(sed -n 's/^CMAKE_INSTALL_PREFIX:PATH=//p' "$CACHE" | tail -n1)"
[[ "$HOME_DIR" == "$CORE_ROOT" ]] || fail "fresh build points at wrong source: $HOME_DIR"
[[ "$PREFIX" == "$STAGE_DIR" ]] || fail "fresh build points at wrong install prefix: $PREFIX"
echo "PASS: CMAKE_HOME_DIRECTORY=$HOME_DIR"
echo "PASS: CMAKE_INSTALL_PREFIX=$PREFIX"

echo "MySQL cache entries:"
grep -E '^MYSQL_(CONFIG|EXECUTABLE|INCLUDE_DIR|LIBRARY|ADD_INCLUDE_PATH|CONFIG_PREFER_PATH|EXTRA_LIBRARIES)' "$CACHE" || true

COMPILE_DB="$BUILD_DIR/compile_commands.json"
[[ -f "$COMPILE_DB" ]] || fail "compile_commands.json missing"
if grep -Fq "/home/azeroth/update-work-20260910-145140/azerothcore" "$CACHE" "$COMPILE_DB"; then
    fail "fresh configure still references obsolete September 10 source tree"
fi
grep -Fq "$CORE_ROOT/src/server/database/Database/DatabaseWorkerPool.cpp" "$COMPILE_DB" || fail "DatabaseWorkerPool compile command does not reference active source"
echo "PASS: compile database references active source only"

echo
echo "===== Fresh worldserver build ====="
set +e
cmake --build "$BUILD_DIR" --target worldserver -- -j"$JOBS" 2>&1 | tee "$LOG_DIR/build-worldserver.log"
BUILD_RC=${PIPESTATUS[0]}
set -e
[[ "$BUILD_RC" -eq 0 ]] || fail "fresh worldserver build failed"

NEW_BIN="$BUILD_DIR/src/server/apps/worldserver"
[[ -x "$NEW_BIN" ]] || fail "fresh worldserver binary not found at expected path: $NEW_BIN"

echo
echo "===== Restore active source before binary audit ====="
restore_source
[[ -z "$(git -C "$CORE_ROOT" status --porcelain)" ]] || fail "source tree did not return clean after temporary patch"
echo "PASS: AzerothCore source tree restored clean"

echo
echo "===== Fresh binary provenance gate ====="
stat -c 'owner=%U:%G mode=%a size=%s mtime=%y' "$NEW_BIN"
sha256sum "$NEW_BIN"
ldd "$NEW_BIN" | grep -E 'mysql|mariadb' || fail "fresh worldserver is not linked to a MySQL client library"

ACTIVE_DB_PATH="$CORE_ROOT/src/server/database/Database/DatabaseWorkerPool.cpp"
OLD_ROOT="/home/azeroth/update-work-20260910-145140/azerothcore"
strings "$NEW_BIN" | grep -Fq "$ACTIVE_DB_PATH" || fail "fresh binary does not embed active DatabaseWorkerPool source path"
if strings "$NEW_BIN" | grep -Fq "$OLD_ROOT"; then
    fail "fresh binary still embeds obsolete September 10 source path"
fi
echo "PASS: fresh binary embeds active source path and no obsolete source path"

cp -a "$NEW_BIN" "$ARTIFACT_DIR/worldserver"
sha256sum "$ARTIFACT_DIR/worldserver" > "$ARTIFACT_DIR/worldserver.sha256"

{
    printf 'CORE_ROOT=%q\n' "$CORE_ROOT"
    printf 'CORE_HEAD=%q\n' "$HEAD"
    printf 'BUILD_DIR=%q\n' "$BUILD_DIR"
    printf 'STAGE_DIR=%q\n' "$STAGE_DIR"
    printf 'BUNDLE=%q\n' "$BUNDLE"
    printf 'MYSQL_VERSION_ID=%q\n' "$MYSQL_COMPILE_ID"
    printf 'WORLD_SERVER=%q\n' "$ARTIFACT_DIR/worldserver"
    printf 'WORLD_SERVER_SHA256=%q\n' "$(sha256sum "$ARTIFACT_DIR/worldserver" | awk '{print $1}')"
} > "$OUT/BUILD-METADATA.env"

echo
echo "===== Fresh-build staging result ====="
echo "SOURCE_PATH_MATCH=YES"
echo "MYSQL_BUILD_ENV_MATCH=YES"
echo "FRESH_CMAKE_HOME_MATCH=YES"
echo "OBSOLETE_SOURCE_PATH_IN_BINARY=NO"
echo "SOURCE_TREE_CLEAN=YES"
echo "RESULT: PASS"
echo "Artifact: $ARTIFACT_DIR/worldserver"
echo "Metadata: $OUT/BUILD-METADATA.env"
echo "Report:   $REPORT"
echo "No live server, database, DBC, MPQ, or installed binary was modified."

trap - EXIT
