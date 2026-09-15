#!/usr/bin/env bash
set -euo pipefail

CORE_ROOT="${CORE_ROOT:-/home/azeroth/azerothcore}"
BUILD_DIR="${BUILD_DIR:-$CORE_ROOT/build}"
SERVER_ROOT="${SERVER_ROOT:-/home/azeroth/server}"
CLIENT_ROOT="${CLIENT_ROOT:-/home/azeroth/wow-client}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${1:-}"

if [[ -z "$BUNDLE" ]]; then
    while IFS= read -r candidate; do
        if [[ -f "$candidate/MILESTONE-4-REPORT.txt" ]] && grep -q '^PASS: generated MPQs round-trip verified$' "$candidate/MILESTONE-4-REPORT.txt"; then
            BUNDLE="$candidate"
            break
        fi
    done < <(ls -dt /root/tuskarr-milestone4-* 2>/dev/null || true)
fi

failures=0
warns=0
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; warns=$((warns+1)); }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures+1)); }
section() { printf '\n===== %s =====\n' "$*"; }

conf_value() {
    local key="$1" file="$2"
    sed -nE 's/^[[:space:]]*'"$key"'[[:space:]]*=[[:space:]]*"([^"]*)".*$/\1/p' "$file" | tail -n1
}

parse_db_info() {
    local raw="$1"
    IFS=';' read -r DB_HOST DB_PORT DB_USER DB_PASS DB_NAME DB_EXTRA <<<"$raw"
    [[ -n "${DB_HOST:-}" && -n "${DB_PORT:-}" && -n "${DB_USER:-}" && -n "${DB_NAME:-}" ]]
}

mysql_scalar() {
    local raw="$1" sql="$2"
    parse_db_info "$raw" || return 90
    MYSQL_PWD="$DB_PASS" mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" -Nse "$sql"
}

section "Playable Tuskarr live PoC preflight"
echo "Project:     $PROJECT_ROOT"
echo "Bundle:      ${BUNDLE:-<not found>}"
echo "Core:        $CORE_ROOT"
echo "Build:       $BUILD_DIR"
echo "Server:      $SERVER_ROOT"
echo "Client copy: $CLIENT_ROOT"
echo "Mode:        READ-ONLY / NO RESTART / NO DATABASE CHANGES"

section "Bundle gate"
if [[ -n "$BUNDLE" && -d "$BUNDLE" ]]; then
    pass "Milestone 4 bundle directory exists"
else
    fail "no successful Milestone 4 bundle found"
fi

required_bundle=(
    client/packages/Data/patch-4.MPQ
    client/packages/Data/enUS/patch-enUS-4.MPQ
    server/core/playerbots-exclude-tuskarr-random-generation.patch
    server/dbc/ChrRaces.dbc
    server/dbc/CharBaseInfo.dbc
    server/dbc/CharStartOutfit.dbc
    server/dbc/SkillRaceClassInfo.dbc
    server/dbc/SkillLineAbility.dbc
    server/sql/00_playable_tuskarr_poc.sql
    SHA256SUMS.txt
)
if [[ -n "$BUNDLE" && -d "$BUNDLE" ]]; then
    for rel in "${required_bundle[@]}"; do
        [[ -f "$BUNDLE/$rel" ]] || fail "bundle missing $rel"
    done
    if [[ -f "$BUNDLE/SHA256SUMS.txt" ]]; then
        if (cd "$BUNDLE" && sha256sum -c SHA256SUMS.txt >/tmp/tuskarr-preflight-sha.txt 2>&1); then
            pass "all Milestone 4 bundle hashes verify"
        else
            fail "Milestone 4 bundle hash verification failed"
            cat /tmp/tuskarr-preflight-sha.txt
        fi
    fi
fi

section "AzerothCore source gate"
if [[ -d "$CORE_ROOT/.git" ]]; then
    core_head="$(git -C "$CORE_ROOT" rev-parse HEAD 2>/dev/null || true)"
    echo "Core HEAD: $core_head"
    if [[ "$core_head" == "413bea61a85e20d9caef7d66fc601a661fdddd9d" ]]; then
        pass "exact audited AzerothCore revision"
    else
        fail "AzerothCore revision differs from the audited compatibility profile"
    fi
    if [[ -z "$(git -C "$CORE_ROOT" status --porcelain)" ]]; then
        pass "AzerothCore working tree is clean"
    else
        fail "AzerothCore working tree has local changes"
        git -C "$CORE_ROOT" status --short
    fi
else
    fail "$CORE_ROOT is not a Git checkout"
fi

if [[ -n "$BUNDLE" && -f "$BUNDLE/server/core/playerbots-exclude-tuskarr-random-generation.patch" ]]; then
    if git -C "$CORE_ROOT" apply --check "$BUNDLE/server/core/playerbots-exclude-tuskarr-random-generation.patch" 2>/dev/null; then
        pass "playerbots safeguard patch applies cleanly"
    elif git -C "$CORE_ROOT" apply -R --check "$BUNDLE/server/core/playerbots-exclude-tuskarr-random-generation.patch" 2>/dev/null; then
        fail "playerbots safeguard already appears applied; expected pristine audited source"
    else
        fail "playerbots safeguard patch does not apply cleanly"
    fi
fi

section "Build tree discovery"
if [[ -d "$BUILD_DIR" ]]; then
    pass "build directory exists"
else
    fail "build directory does not exist: $BUILD_DIR"
fi
if [[ -f "$BUILD_DIR/CMakeCache.txt" ]]; then
    pass "CMakeCache.txt found"
    grep -E '^(CMAKE_BUILD_TYPE|CMAKE_INSTALL_PREFIX|CMAKE_GENERATOR):' "$BUILD_DIR/CMakeCache.txt" || true
else
    fail "CMakeCache.txt missing from build directory"
fi

echo "Existing executable worldserver candidates inside build tree:"
if [[ -d "$BUILD_DIR" ]]; then
    mapfile -t build_bins < <(find "$BUILD_DIR" -type f -name worldserver -perm /111 -printf '%T@\t%p\t%s bytes\n' 2>/dev/null | sort -nr)
    if ((${#build_bins[@]})); then
        printf '%s\n' "${build_bins[@]}"
        pass "at least one build-tree worldserver binary exists"
    else
        warn "no existing executable worldserver found in build tree; a rebuild may create one"
    fi
fi

if command -v cmake >/dev/null; then pass "cmake available: $(command -v cmake)"; else fail "cmake not installed"; fi
if command -v g++ >/dev/null; then pass "g++ available: $(command -v g++)"; else fail "g++ not installed"; fi

section "Installed worldserver / controller discovery"
LIVE_BIN="$SERVER_ROOT/bin/worldserver"
if [[ -x "$LIVE_BIN" ]]; then
    pass "installed worldserver exists: $LIVE_BIN"
    stat -c 'owner=%U:%G mode=%a size=%s mtime=%y' "$LIVE_BIN"
else
    fail "installed worldserver binary missing or not executable: $LIVE_BIN"
fi

pid="$(pgrep -u azeroth -x worldserver | head -n1 || pgrep -x worldserver | head -n1 || true)"
if [[ -n "$pid" ]]; then
    pass "worldserver process is running (PID $pid)"
    ps -p "$pid" -o pid,user,lstart,etime,%cpu,%mem,cmd
    echo -n "cwd="; readlink -f "/proc/$pid/cwd" || true
    echo -n "exe="; readlink -f "/proc/$pid/exe" || true
else
    warn "worldserver process is not currently running"
fi

mapfile -t service_candidates < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'worldserver' | sort -u || true)
if ((${#service_candidates[@]})); then
    echo "worldserver-related systemd units:"
    printf '  %s\n' "${service_candidates[@]}"
    active_count=0
    for svc in "${service_candidates[@]}"; do
        state="$(systemctl is-active "$svc" 2>/dev/null || true)"
        printf '  %-40s %s\n' "$svc" "$state"
        [[ "$state" == "active" ]] && active_count=$((active_count+1))
    done
    if ((active_count == 1)); then
        pass "exactly one worldserver-related systemd unit is active"
    elif ((active_count == 0)); then
        fail "no worldserver-related systemd unit is active; automatic controlled restart cannot be selected safely"
    else
        fail "multiple worldserver-related systemd units are active; controller is ambiguous"
    fi
else
    fail "no worldserver-related systemd service found"
fi

section "Worldserver configuration / database connectivity"
CONF="$SERVER_ROOT/etc/worldserver.conf"
if [[ -f "$CONF" ]]; then
    pass "worldserver.conf found: $CONF"
else
    fail "worldserver.conf not found: $CONF"
fi

WORLD_INFO="$(conf_value WorldDatabaseInfo "$CONF" 2>/dev/null || true)"
CHAR_INFO="$(conf_value CharacterDatabaseInfo "$CONF" 2>/dev/null || true)"
for kind in WORLD CHAR; do
    var="${kind}_INFO"
    raw="${!var:-}"
    if parse_db_info "$raw"; then
        echo "$kind database: host=$DB_HOST port=$DB_PORT user=$DB_USER database=$DB_NAME"
        pass "$kind database connection string parsed (password intentionally hidden)"
    else
        fail "could not parse ${kind}DatabaseInfo"
    fi
done

if command -v mysql >/dev/null; then pass "mysql client available"; else fail "mysql client missing"; fi
if command -v mysqldump >/dev/null; then pass "mysqldump available"; else fail "mysqldump missing"; fi

if [[ -n "$WORLD_INFO" ]]; then
    if world_ping="$(mysql_scalar "$WORLD_INFO" 'SELECT 1;' 2>/dev/null)" && [[ "$world_ping" == "1" ]]; then
        pass "world database login works"
        for table in playercreateinfo player_race_stats playercreateinfo_action; do
            count="$(mysql_scalar "$WORLD_INFO" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='$table';" 2>/dev/null || true)"
            [[ "$count" == "1" ]] && pass "world table exists: $table" || fail "world table missing: $table"
        done
        echo "Existing race 17/18 rows before PoC:"
        mysql_scalar "$WORLD_INFO" "SELECT CONCAT('playercreateinfo=',COUNT(*)) FROM playercreateinfo WHERE race IN (17,18);" 2>/dev/null || true
        mysql_scalar "$WORLD_INFO" "SELECT CONCAT('player_race_stats=',COUNT(*)) FROM player_race_stats WHERE Race IN (17,18);" 2>/dev/null || true
        mysql_scalar "$WORLD_INFO" "SELECT CONCAT('playercreateinfo_action=',COUNT(*)) FROM playercreateinfo_action WHERE race IN (17,18);" 2>/dev/null || true
    else
        fail "world database login failed"
    fi
fi

if [[ -n "$CHAR_INFO" ]]; then
    if char_ping="$(mysql_scalar "$CHAR_INFO" 'SELECT 1;' 2>/dev/null)" && [[ "$char_ping" == "1" ]]; then
        pass "characters database login works"
        online="$(mysql_scalar "$CHAR_INFO" 'SELECT COUNT(*) FROM characters WHERE online=1;' 2>/dev/null || true)"
        if [[ "$online" =~ ^[0-9]+$ ]]; then
            echo "Online characters: $online"
            if [[ "$online" == "0" ]]; then
                pass "no human/player characters are marked online"
            else
                fail "$online character(s) are online; live PoC install must not restart the realm"
            fi
        else
            fail "could not determine online character count"
        fi
    else
        fail "characters database login failed"
    fi
fi

section "Server DBC gate"
LIVE_DBC="$SERVER_ROOT/bin/dbc"
if [[ -d "$LIVE_DBC" ]]; then
    pass "active DBC directory exists: $LIVE_DBC"
else
    fail "active DBC directory missing: $LIVE_DBC"
fi
for f in ChrRaces.dbc CharBaseInfo.dbc CharStartOutfit.dbc SkillRaceClassInfo.dbc SkillLineAbility.dbc; do
    if [[ -f "$LIVE_DBC/$f" ]]; then
        printf '%-28s %s\n' "$f" "$(sha256sum "$LIVE_DBC/$f" | awk '{print $1}')"
    else
        fail "active DBC missing: $f"
    fi
done

section "Client copy / patch-number conflict gate"
GLOBAL_TARGET="$CLIENT_ROOT/Data/patch-4.MPQ"
LOCALE_TARGET="$CLIENT_ROOT/Data/enUS/patch-enUS-4.MPQ"
if [[ -d "$CLIENT_ROOT/Data/enUS" ]]; then
    pass "client Data/enUS directory exists"
else
    fail "client Data/enUS directory missing"
fi

for target in "$GLOBAL_TARGET" "$LOCALE_TARGET"; do
    if [[ -e "$target" ]]; then
        if [[ -n "$BUNDLE" ]]; then
            if [[ "$target" == "$GLOBAL_TARGET" ]]; then src="$BUNDLE/client/packages/Data/patch-4.MPQ"; else src="$BUNDLE/client/packages/Data/enUS/patch-enUS-4.MPQ"; fi
            if cmp -s "$src" "$target"; then
                warn "target already exists but is byte-identical to staged package: $target"
            else
                fail "patch-number conflict: nonmatching file already exists: $target"
            fi
        else
            fail "patch-number conflict: $target exists"
        fi
    else
        pass "patch slot free: $target"
    fi
done

echo "Existing patch archives at or above patch-4 naming:"
find "$CLIENT_ROOT/Data" -maxdepth 2 -type f \( -iname 'patch-[4-9]*.mpq' -o -iname 'patch-enUS-[4-9]*.mpq' \) -printf '%p\t%s bytes\n' 2>/dev/null | sort || true

section "Capacity / backup prerequisites"
df -h "$CORE_ROOT" "$SERVER_ROOT" "$CLIENT_ROOT" /root | awk 'NR==1 || !seen[$1]++'
root_avail_kb="$(df -Pk /root | awk 'NR==2 {print $4}')"
if [[ "$root_avail_kb" =~ ^[0-9]+$ ]] && (( root_avail_kb >= 1048576 )); then
    pass "/root has at least 1 GiB free for backups/build metadata"
else
    warn "/root has less than 1 GiB free; inspect capacity before applying"
fi

section "Preflight result"
if ((failures == 0)); then
    echo "RESULT: PASS"
    echo "The machine-specific prerequisites for a controlled PoC install are verified."
    echo "Warnings: $warns"
    echo "No changes were made."
    exit 0
else
    echo "RESULT: BLOCKED"
    echo "Failures: $failures"
    echo "Warnings: $warns"
    echo "No changes were made."
    exit 2
fi
