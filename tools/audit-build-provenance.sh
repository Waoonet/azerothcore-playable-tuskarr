#!/usr/bin/env bash
set -euo pipefail

CORE_ROOT="${CORE_ROOT:-/home/azeroth/azerothcore}"
BUILD_DIR="${BUILD_DIR:-$CORE_ROOT/build}"
SERVER_ROOT="${SERVER_ROOT:-/home/azeroth/server}"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run as root"
[[ -f "$BUILD_DIR/CMakeCache.txt" ]] || fail "CMakeCache.txt missing: $BUILD_DIR"

section() { printf '\n===== %s =====\n' "$*"; }
cache_value() {
    local key="$1"
    sed -nE 's/^'"$key"':[A-Z_]+=(.*)$/\1/p' "$BUILD_DIR/CMakeCache.txt" | tail -n1
}

section "Tuskarr build provenance audit"
echo "Core root:   $CORE_ROOT"
echo "Build dir:   $BUILD_DIR"
echo "Server root: $SERVER_ROOT"
echo "Mode:        READ-ONLY (temporary compiler probe only)"

section "CMake provenance"
for key in CMAKE_HOME_DIRECTORY CMAKE_INSTALL_PREFIX CMAKE_BUILD_TYPE CMAKE_GENERATOR; do
    printf '%-24s %s\n' "$key:" "$(cache_value "$key")"
done

echo
echo "MySQL-related CMake cache entries:"
grep -Ei '^(MYSQL|MySQL|MariaDB|MARIADB)[A-Za-z0-9_]*:' "$BUILD_DIR/CMakeCache.txt" || true

section "Git source identity"
echo "Active source:"
git -C "$CORE_ROOT" rev-parse --show-toplevel 2>/dev/null || true
git -C "$CORE_ROOT" rev-parse HEAD 2>/dev/null || true
git -C "$CORE_ROOT" status --short 2>/dev/null || true

CMAKE_HOME="$(cache_value CMAKE_HOME_DIRECTORY)"
if [[ -n "$CMAKE_HOME" && -d "$CMAKE_HOME" ]]; then
    echo
    echo "CMake source:"
    git -C "$CMAKE_HOME" rev-parse --show-toplevel 2>/dev/null || true
    git -C "$CMAKE_HOME" rev-parse HEAD 2>/dev/null || true
    git -C "$CMAKE_HOME" status --short 2>/dev/null || true
else
    echo "CMake source directory does not exist: ${CMAKE_HOME:-<empty>}"
fi

section "Build references to source trees"
for needle in "$CORE_ROOT" /home/azeroth/update-work-20260910-145140/azerothcore; do
    echo "--- $needle ---"
    grep -RIl --exclude='*.o' --exclude='*.a' --exclude='worldserver' -- "$needle" "$BUILD_DIR/CMakeFiles" 2>/dev/null | head -40 || true
done

section "MySQL command-line / development versions"
command -v mysql || true
mysql --version 2>/dev/null || true
command -v mysql_config || true
if command -v mysql_config >/dev/null 2>&1; then
    echo "mysql_config --version: $(mysql_config --version 2>/dev/null || true)"
    echo "mysql_config --cflags:  $(mysql_config --cflags 2>/dev/null || true)"
    echo "mysql_config --libs:    $(mysql_config --libs 2>/dev/null || true)"
fi
if command -v pkg-config >/dev/null 2>&1; then
    echo "pkg-config mysqlclient: $(pkg-config --modversion mysqlclient 2>/dev/null || echo unavailable)"
fi

section "Compile-time vs runtime MySQL probe"
TMP="$(mktemp -d /tmp/tuskarr-mysql-probe.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/probe.cpp" <<'CPP'
#include <mysql.h>
#include <cstdio>
int main()
{
    std::printf("MYSQL_VERSION_ID=%lu\n", static_cast<unsigned long>(MYSQL_VERSION_ID));
    std::printf("mysql_get_client_version=%lu\n", static_cast<unsigned long>(mysql_get_client_version()));
    std::printf("mysql_get_client_info=%s\n", mysql_get_client_info());
    return MYSQL_VERSION_ID == mysql_get_client_version() ? 0 : 3;
}
CPP

if command -v mysql_config >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    g++ -O0 -g $(mysql_config --cflags) "$TMP/probe.cpp" $(mysql_config --libs) -o "$TMP/probe"
    set +e
    "$TMP/probe"
    PROBE_RC=$?
    set -e
    echo "probe_exit_code=$PROBE_RC"
else
    echo "SKIP: mysql_config is unavailable; compiler probe not run"
    PROBE_RC=99
fi

section "Worldserver binary provenance"
LIVE="$SERVER_ROOT/bin/worldserver"
BUILD_BIN="$(find "$BUILD_DIR" -type f -name worldserver -perm /111 -printf '%T@\t%p\n' 2>/dev/null | sort -nr | head -n1 | cut -f2-)"
for bin in "$LIVE" "$BUILD_BIN"; do
    [[ -n "$bin" && -x "$bin" ]] || continue
    echo "--- $bin ---"
    stat -c 'owner=%U:%G mode=%a size=%s mtime=%y' "$bin"
    sha256sum "$bin"
    ldd "$bin" 2>/dev/null | grep -Ei 'mysql|maria' || true
    strings "$bin" 2>/dev/null | grep -E -m5 '/(azerothcore|update-work-[^/]+)/.*DatabaseWorkerPool\.cpp' || true
done

section "Known failed PoC core"
CORE_FILE="$(find "$SERVER_ROOT/logs/cores" -maxdepth 1 -type f -name 'core.worldserver.*' -newermt '2026-09-15 09:23:50' ! -newermt '2026-09-15 09:24:30' -print 2>/dev/null | head -n1)"
if [[ -n "$CORE_FILE" ]]; then
    ls -lh "$CORE_FILE"
    file "$CORE_FILE" || true
    if command -v gdb >/dev/null 2>&1 && [[ -n "$BUILD_BIN" ]]; then
        echo
        echo "GDB backtrace using retained rebuilt binary:"
        gdb -q -batch -ex 'set pagination off' -ex 'thread apply all bt 20' "$BUILD_BIN" "$CORE_FILE" 2>&1 | tail -n 300 || true
    else
        echo "gdb or retained build binary unavailable; backtrace skipped"
    fi
else
    echo "No core found in failed PoC time window"
fi

section "Audit conclusion inputs"
echo "CMAKE_HOME_DIRECTORY=$CMAKE_HOME"
echo "ACTIVE_CORE_ROOT=$CORE_ROOT"
echo "MYSQL_PROBE_RC=$PROBE_RC"
if [[ "$CMAKE_HOME" == "$CORE_ROOT" ]]; then
    echo "SOURCE_PATH_MATCH=YES"
else
    echo "SOURCE_PATH_MATCH=NO"
fi
if (( PROBE_RC == 0 )); then
    echo "MYSQL_BUILD_ENV_MATCH=YES"
else
    echo "MYSQL_BUILD_ENV_MATCH=NO_OR_UNKNOWN"
fi

echo
echo "No live server, database, DBC, MPQ, or source files were modified."
