#!/usr/bin/env bash
set -euo pipefail

CORE_ROOT="${CORE_ROOT:-/home/azeroth/azerothcore}"
SERVER_ROOT="${SERVER_ROOT:-/home/azeroth/server}"
CLIENT_ROOT="${CLIENT_ROOT:-/home/azeroth/wow-client}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${1:-}"
FRESH_OUT="${2:-}"
EXPECTED_CORE="413bea61a85e20d9caef7d66fc601a661fdddd9d"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run as root"
[[ -n "$BUNDLE" && -d "$BUNDLE" ]] || fail "usage: $0 /root/tuskarr-milestone4-YYYYMMDD-HHMMSS /root/tuskarr-fresh-build-YYYYMMDD-HHMMSS"
[[ -n "$FRESH_OUT" && -d "$FRESH_OUT" ]] || fail "fresh-build directory missing: $FRESH_OUT"

CONF="$SERVER_ROOT/etc/worldserver.conf"
CONSOLE_LOG="$SERVER_ROOT/logs/worldserver-console.log"
META="$FRESH_OUT/BUILD-METADATA.env"
FINAL_REPORT="$FRESH_OUT/FRESH-BUILD-FINALIZE-REPORT.txt"
ARTIFACT="$FRESH_OUT/artifact/worldserver"
[[ -f "$CONF" ]] || fail "worldserver.conf missing"
[[ -f "$META" ]] || fail "fresh-build metadata missing: $META"
[[ -f "$FINAL_REPORT" ]] || fail "fresh-build finalization report missing: $FINAL_REPORT"
[[ -x "$ARTIFACT" ]] || fail "verified fresh worldserver artifact missing: $ARTIFACT"
grep -Fxq 'RESULT: PASS' "$FINAL_REPORT" || fail "fresh-build finalizer did not record RESULT: PASS"

meta_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "$META" | tail -n1
}

META_CORE_ROOT="$(meta_value CORE_ROOT)"
META_CORE_HEAD="$(meta_value CORE_HEAD)"
META_BUNDLE="$(meta_value BUNDLE)"
META_MYSQL_ID="$(meta_value MYSQL_VERSION_ID)"
META_WORLD_SERVER="$(meta_value WORLD_SERVER)"
META_WORLD_SHA="$(meta_value WORLD_SERVER_SHA256)"
META_PROVENANCE="$(meta_value PROVENANCE_GATE)"

[[ "$META_CORE_ROOT" == "$CORE_ROOT" ]] || fail "fresh artifact core root mismatch: $META_CORE_ROOT"
[[ "$META_CORE_HEAD" == "$EXPECTED_CORE" ]] || fail "fresh artifact core revision mismatch: $META_CORE_HEAD"
[[ "$META_BUNDLE" == "$BUNDLE" ]] || fail "fresh artifact was built for a different Milestone 4 bundle: $META_BUNDLE"
[[ "$META_WORLD_SERVER" == "$ARTIFACT" ]] || fail "fresh artifact metadata path mismatch: $META_WORLD_SERVER"
[[ "$META_PROVENANCE" == "cmake+compile_commands+no-obsolete-path-v2" ]] || fail "unexpected provenance gate: $META_PROVENANCE"
ACTUAL_WORLD_SHA="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
[[ -n "$META_WORLD_SHA" && "$ACTUAL_WORLD_SHA" == "$META_WORLD_SHA" ]] || fail "fresh artifact SHA256 mismatch"

conf_value() {
    local key="$1" file="$2"
    sed -nE 's/^[[:space:]]*'"$key"'[[:space:]]*=[[:space:]]*"([^"]*)".*$/\1/p' "$file" | tail -n1
}
parse_db_info() {
    local raw="$1"
    IFS=';' read -r DB_HOST DB_PORT DB_USER DB_PASS DB_NAME DB_EXTRA <<<"$raw"
    [[ -n "${DB_HOST:-}" && -n "${DB_PORT:-}" && -n "${DB_USER:-}" && -n "${DB_NAME:-}" ]]
}
mysql_query() {
    local raw="$1" sql="$2"
    parse_db_info "$raw" || return 90
    MYSQL_PWD="$DB_PASS" mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" -Nse "$sql"
}
mysql_file() {
    local raw="$1" file="$2"
    parse_db_info "$raw" || return 90
    MYSQL_PWD="$DB_PASS" mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" < "$file"
}
mysqldump_rows() {
    local raw="$1" table="$2" where="$3" outfile="$4"
    parse_db_info "$raw" || return 90
    MYSQL_PWD="$DB_PASS" mysqldump --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" \
      --no-tablespaces --no-create-info --skip-triggers --single-transaction --skip-lock-tables \
      "$DB_NAME" "$table" --where="$where" > "$outfile"
}

WORLD_INFO="$(conf_value WorldDatabaseInfo "$CONF")"
CHAR_INFO="$(conf_value CharacterDatabaseInfo "$CONF")"
LOGIN_INFO="$(conf_value LoginDatabaseInfo "$CONF")"
parse_db_info "$WORLD_INFO" || fail "could not parse WorldDatabaseInfo"
parse_db_info "$CHAR_INFO" || fail "could not parse CharacterDatabaseInfo"
parse_db_info "$LOGIN_INFO" || fail "could not parse LoginDatabaseInfo"

# The complete bot-aware read-only preflight must still pass immediately before staging.
echo "===== FINAL READ-ONLY PREFLIGHT ====="
bash "$PROJECT_ROOT/tools/live-poc-preflight-v2.sh" "$BUNDLE"

CURRENT_HEAD="$(git -C "$CORE_ROOT" rev-parse HEAD)"
[[ "$CURRENT_HEAD" == "$EXPECTED_CORE" ]] || fail "active source revision changed: $CURRENT_HEAD"
[[ -z "$(git -C "$CORE_ROOT" status --porcelain)" ]] || fail "active AzerothCore source tree is not clean"

mapfile -t ACTIVE_SERVICES < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'worldserver' | while read -r s; do [[ "$(systemctl is-active "$s" 2>/dev/null || true)" == active ]] && echo "$s"; done)
((${#ACTIVE_SERVICES[@]} == 1)) || fail "expected exactly one active worldserver service"
SERVICE="${ACTIVE_SERVICES[0]}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/tuskarr-live-backup-$STAMP"
mkdir -p "$BACKUP"/{live/dbc,live/client,db,core,logs}
chmod 700 "$BACKUP"
REPORT="$BACKUP/INSTALL-REPORT.txt"
exec > >(tee "$REPORT") 2>&1

ROLLBACK_ARMED=0
BOT_IDS=""
ONLINE_ROWS=""
MYSQL_PROBE=""
STAGED_BIN="$SERVER_ROOT/bin/.worldserver.tuskarr-stage-$STAMP"
cleanup_tmp() {
    [[ -n "$BOT_IDS" ]] && rm -f "$BOT_IDS" || true
    [[ -n "$ONLINE_ROWS" ]] && rm -f "$ONLINE_ROWS" || true
    [[ -n "$MYSQL_PROBE" ]] && rm -f "$MYSQL_PROBE" "$MYSQL_PROBE.cpp" || true
    [[ -e "$STAGED_BIN" ]] && rm -f "$STAGED_BIN" || true
}
capture_failure() {
    systemctl status "$SERVICE" --no-pager > "$BACKUP/logs/failed-status.txt" 2>&1 || true
    journalctl -u "$SERVICE" -n 250 --no-pager > "$BACKUP/logs/failed-journal.txt" 2>&1 || true
    if [[ -f "$CONSOLE_LOG" && -n "${LOG_START:-}" ]]; then
        tail -n +"$((LOG_START + 1))" "$CONSOLE_LOG" > "$BACKUP/logs/failed-console-slice.txt" 2>/dev/null || true
    fi
}
on_exit() {
    local rc=$?
    if (( rc != 0 && ROLLBACK_ARMED == 1 )); then
        capture_failure
    fi
    cleanup_tmp
    if (( rc != 0 && ROLLBACK_ARMED == 1 )); then
        trap - EXIT
        echo "AUTO-ROLLBACK: an error occurred after live downtime began. Restoring original realm state."
        if bash "$BACKUP/rollback.sh" "$BACKUP"; then
            echo "AUTO-ROLLBACK: completed successfully."
        else
            echo "AUTO-ROLLBACK: rollback script reported an error; inspect $BACKUP/ROLLBACK-REPORT.txt" >&2
        fi
    fi
    exit "$rc"
}
trap on_exit EXIT

echo "===== Playable Tuskarr live PoC install v2 ====="
echo "Bundle:         $BUNDLE"
echo "Fresh build:    $FRESH_OUT"
echo "Artifact:       $ARTIFACT"
echo "Artifact SHA:   $ACTUAL_WORLD_SHA"
echo "Artifact MySQL: $META_MYSQL_ID"
echo "Backup:         $BACKUP"
echo "Service:        $SERVICE"
echo "Started:        $(date -Is)"

(cd "$BUNDLE" && sha256sum -c SHA256SUMS.txt)

echo
echo "===== Current MySQL runtime compatibility gate ====="
command -v mysql_config >/dev/null || fail "mysql_config not found"
command -v g++ >/dev/null || fail "g++ not found"
MYSQL_PROBE="$(mktemp /tmp/tuskarr-install-mysql-probe.XXXXXX)"
rm -f "$MYSQL_PROBE"
cat > "$MYSQL_PROBE.cpp" <<'CPP'
#include <mysql.h>
#include <iostream>
int main()
{
    std::cout << MYSQL_VERSION_ID << " " << mysql_get_client_version() << " " << mysql_get_client_info() << "\n";
    return MYSQL_VERSION_ID == mysql_get_client_version() ? 0 : 2;
}
CPP
# shellcheck disable=SC2046
g++ $(mysql_config --cflags) "$MYSQL_PROBE.cpp" -o "$MYSQL_PROBE" $(mysql_config --libs)
PROBE_LINE="$("$MYSQL_PROBE")" || fail "current MySQL headers/runtime mismatch"
read -r CURRENT_MYSQL_COMPILE CURRENT_MYSQL_RUNTIME CURRENT_MYSQL_INFO <<<"$PROBE_LINE"
echo "compile=$CURRENT_MYSQL_COMPILE runtime=$CURRENT_MYSQL_RUNTIME info=$CURRENT_MYSQL_INFO"
[[ "$CURRENT_MYSQL_COMPILE" == "$META_MYSQL_ID" && "$CURRENT_MYSQL_RUNTIME" == "$META_MYSQL_ID" ]] || fail "verified worldserver was built for MySQL $META_MYSQL_ID but current runtime is $CURRENT_MYSQL_RUNTIME"
echo "PASS: verified artifact and current MySQL environment agree ($META_MYSQL_ID)"

LIVE_BIN="$SERVER_ROOT/bin/worldserver"
TARGET_CPP="$CORE_ROOT/modules/mod-playerbots/src/Bot/Factory/RandomPlayerbotFactory.cpp"

# This PoC SQL deliberately owns race IDs 17/18. Refuse to overwrite unexpected existing data.
PCI_BEFORE="$(mysql_query "$WORLD_INFO" 'SELECT COUNT(*) FROM playercreateinfo WHERE race IN (17,18);')"
PRS_BEFORE="$(mysql_query "$WORLD_INFO" 'SELECT COUNT(*) FROM player_race_stats WHERE Race IN (17,18);')"
PCA_BEFORE="$(mysql_query "$WORLD_INFO" 'SELECT COUNT(*) FROM playercreateinfo_action WHERE race IN (17,18);')"
echo "PREINSTALL_SQL_COUNTS playercreateinfo=$PCI_BEFORE player_race_stats=$PRS_BEFORE playercreateinfo_action=$PCA_BEFORE"
[[ "$PCI_BEFORE" == 0 && "$PRS_BEFORE" == 0 && "$PCA_BEFORE" == 0 ]] || fail "race 17/18 world rows already exist; refusing destructive PoC replacement"

ARTIFACT_SIZE="$(stat -c %s "$ARTIFACT")"
AVAIL_BYTES="$(df -Pk "$SERVER_ROOT/bin" | awk 'NR==2 {print $4 * 1024}')"
NEEDED_BYTES=$((ARTIFACT_SIZE + 1073741824))
(( AVAIL_BYTES > NEEDED_BYTES )) || fail "insufficient free space to stage verified worldserver beside live binary"

cp -a "$LIVE_BIN" "$BACKUP/live/worldserver"
cp -a "$TARGET_CPP" "$BACKUP/core/RandomPlayerbotFactory.cpp"
cp -a "$CONF" "$BACKUP/live/worldserver.conf"
systemctl cat "$SERVICE" > "$BACKUP/live/systemd-unit.txt" || true
for f in ChrRaces.dbc CharBaseInfo.dbc CharStartOutfit.dbc SkillRaceClassInfo.dbc SkillLineAbility.dbc; do
    cp -a "$SERVER_ROOT/bin/dbc/$f" "$BACKUP/live/dbc/$f"
done

GLOBAL_PATCH_EXISTED=0
LOCALE_PATCH_EXISTED=0
if [[ -e "$CLIENT_ROOT/Data/patch-4.MPQ" ]]; then
    GLOBAL_PATCH_EXISTED=1
    cp -a "$CLIENT_ROOT/Data/patch-4.MPQ" "$BACKUP/live/client/patch-4.MPQ"
fi
if [[ -e "$CLIENT_ROOT/Data/enUS/patch-enUS-4.MPQ" ]]; then
    LOCALE_PATCH_EXISTED=1
    cp -a "$CLIENT_ROOT/Data/enUS/patch-enUS-4.MPQ" "$BACKUP/live/client/patch-enUS-4.MPQ"
fi

mysqldump_rows "$WORLD_INFO" playercreateinfo 'race IN (17,18)' "$BACKUP/db/playercreateinfo.sql"
mysqldump_rows "$WORLD_INFO" player_race_stats 'Race IN (17,18)' "$BACKUP/db/player_race_stats.sql"
mysqldump_rows "$WORLD_INFO" playercreateinfo_action 'race IN (17,18)' "$BACKUP/db/playercreateinfo_action.sql"

grep -qi 'mysqldump' "$BACKUP/db/playercreateinfo.sql" || true
{
    printf 'SERVICE=%q\n' "$SERVICE"
    printf 'BUNDLE=%q\n' "$BUNDLE"
    printf 'FRESH_OUT=%q\n' "$FRESH_OUT"
    printf 'FRESH_WORLD_SHA256=%q\n' "$ACTUAL_WORLD_SHA"
    printf 'GLOBAL_PATCH_EXISTED=%q\n' "$GLOBAL_PATCH_EXISTED"
    printf 'LOCALE_PATCH_EXISTED=%q\n' "$LOCALE_PATCH_EXISTED"
    printf 'CORE_HEAD=%q\n' "$CURRENT_HEAD"
} > "$BACKUP/metadata.env"

cp "$PROJECT_ROOT/tools/rollback-live-poc.sh" "$BACKUP/rollback.sh"
chmod 700 "$BACKUP/rollback.sh"
echo "PASS: rollback backups created with --no-tablespaces database dumps"
echo "Rollback command: bash $BACKUP/rollback.sh $BACKUP"

# Copy the large verified binary while the realm is still online, then use an atomic rename during downtime.
install -o azeroth -g azeroth -m 0755 "$ARTIFACT" "$STAGED_BIN"
STAGED_SHA="$(sha256sum "$STAGED_BIN" | awk '{print $1}')"
[[ "$STAGED_SHA" == "$ACTUAL_WORLD_SHA" ]] || fail "pre-staged worldserver checksum mismatch"
echo "PASS: verified worldserver pre-staged beside live binary"

# Re-check online accounts immediately before downtime. Only configured random-bot accounts may be online.
mapfile -t PB_CONFS < <(find "$SERVER_ROOT/etc" -type f \( -name 'playerbots.conf' -o -name '*playerbots*.conf' \) ! -name '*.dist' -print | sort -u)
prefix=""
for cfg in "${PB_CONFS[@]}"; do
    candidate="$(sed -nE 's/^[[:space:]]*AiPlayerbot\.RandomBotAccountPrefix[[:space:]]*=[[:space:]]*"?([^"#[:space:]]+)"?.*$/\1/p' "$cfg" | tail -n1)"
    [[ -z "$candidate" ]] && continue
    [[ -z "$prefix" || "$prefix" == "$candidate" ]] || fail "conflicting random-bot prefixes"
    prefix="$candidate"
done
[[ -n "$prefix" && "$prefix" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "could not safely determine random-bot account prefix"
BOT_IDS="$(mktemp)"
ONLINE_ROWS="$(mktemp)"
mysql_query "$LOGIN_INFO" "SELECT id FROM account WHERE username LIKE '${prefix}%';" > "$BOT_IDS"
mysql_query "$CHAR_INFO" 'SELECT account,name FROM characters WHERE online=1 ORDER BY account,name;' > "$ONLINE_ROWS"
NONBOTS="$(awk 'NR==FNR{b[$1]=1;next} !($1 in b){n++} END{print n+0}' "$BOT_IDS" "$ONLINE_ROWS")"
TOTAL="$(wc -l < "$ONLINE_ROWS")"
if (( NONBOTS != 0 )); then
    echo "Non-bot online rows:"
    awk 'NR==FNR{b[$1]=1;next} !($1 in b){print}' "$BOT_IDS" "$ONLINE_ROWS"
    fail "$NONBOTS non-bot character(s) are online; install aborted before downtime"
fi
echo "PASS: immediate downtime gate: TOTAL=$TOTAL NONBOTS=0"

# From this point onward, any non-zero exit automatically restores the original realm.
ROLLBACK_ARMED=1
systemctl stop "$SERVICE"
for _ in {1..60}; do
    pgrep -x worldserver >/dev/null || break
    sleep 1
done
pgrep -x worldserver >/dev/null && fail "worldserver did not stop cleanly"
echo "PASS: worldserver stopped"

mv -f "$STAGED_BIN" "$LIVE_BIN"
for f in ChrRaces.dbc CharBaseInfo.dbc CharStartOutfit.dbc SkillRaceClassInfo.dbc SkillLineAbility.dbc; do
    install -o azeroth -g azeroth -m 0644 "$BUNDLE/server/dbc/$f" "$SERVER_ROOT/bin/dbc/$f"
done
mysql_file "$WORLD_INFO" "$BUNDLE/server/sql/00_playable_tuskarr_poc.sql"

CLIENT_UID="$(stat -c %u "$CLIENT_ROOT")"
CLIENT_GID="$(stat -c %g "$CLIENT_ROOT")"
install -o "$CLIENT_UID" -g "$CLIENT_GID" -m 0644 "$BUNDLE/client/packages/Data/patch-4.MPQ" "$CLIENT_ROOT/Data/patch-4.MPQ"
install -o "$CLIENT_UID" -g "$CLIENT_GID" -m 0644 "$BUNDLE/client/packages/Data/enUS/patch-enUS-4.MPQ" "$CLIENT_ROOT/Data/enUS/patch-enUS-4.MPQ"
echo "PASS: verified binary, five server DBCs, SQL, and two client MPQs installed"

[[ -f "$CONSOLE_LOG" ]] || touch "$CONSOLE_LOG"
LOG_START="$(wc -l < "$CONSOLE_LOG")"
systemctl start "$SERVICE"

READY=0
for _ in {1..120}; do
    if ! systemctl is-active --quiet "$SERVICE" || ! pgrep -x worldserver >/dev/null; then
        fail "worldserver exited during startup"
    fi
    NEW_LOG="$(tail -n +"$((LOG_START + 1))" "$CONSOLE_LOG" 2>/dev/null || true)"
    if grep -Eq '>> FATAL ERROR|ACE00046|Used MySQL library version .* does not match' <<<"$NEW_LOG"; then
        fail "new worldserver startup logged a fatal error"
    fi
    if grep -Fq '(worldserver-daemon) ready...' <<<"$NEW_LOG"; then
        READY=1
        break
    fi
    sleep 1
done
[[ "$READY" == 1 ]] || fail "worldserver stayed alive but did not reach the AzerothCore ready marker within the startup gate"
echo "PASS: new worldserver reached AzerothCore ready marker"

sleep 10
systemctl is-active --quiet "$SERVICE" || fail "worldserver service left active state after ready marker"
pgrep -x worldserver >/dev/null || fail "worldserver process exited after ready marker"
echo "PASS: worldserver remained active after readiness verification"
ps -C worldserver -o pid,user,lstart,etime,%cpu,%mem,cmd

# Verify installed payload and SQL state.
for f in ChrRaces.dbc CharBaseInfo.dbc CharStartOutfit.dbc SkillRaceClassInfo.dbc SkillLineAbility.dbc; do
    cmp -s "$BUNDLE/server/dbc/$f" "$SERVER_ROOT/bin/dbc/$f" || fail "live DBC mismatch: $f"
done
cmp -s "$BUNDLE/client/packages/Data/patch-4.MPQ" "$CLIENT_ROOT/Data/patch-4.MPQ" || fail "global client MPQ mismatch"
cmp -s "$BUNDLE/client/packages/Data/enUS/patch-enUS-4.MPQ" "$CLIENT_ROOT/Data/enUS/patch-enUS-4.MPQ" || fail "locale client MPQ mismatch"
LIVE_SHA="$(sha256sum "$LIVE_BIN" | awk '{print $1}')"
[[ "$LIVE_SHA" == "$ACTUAL_WORLD_SHA" ]] || fail "live worldserver SHA256 mismatch"

PCI="$(mysql_query "$WORLD_INFO" 'SELECT COUNT(*) FROM playercreateinfo WHERE race IN (17,18);')"
PRS="$(mysql_query "$WORLD_INFO" 'SELECT COUNT(*) FROM player_race_stats WHERE Race IN (17,18);')"
PCA="$(mysql_query "$WORLD_INFO" 'SELECT COUNT(*) FROM playercreateinfo_action WHERE race IN (17,18);')"
echo "SQL_COUNTS playercreateinfo=$PCI player_race_stats=$PRS playercreateinfo_action=$PCA"
[[ "$PCI" == 6 && "$PRS" == 2 && "$PCA" == 20 ]] || fail "unexpected PoC SQL row counts"

[[ -z "$(git -C "$CORE_ROOT" status --porcelain)" ]] || fail "active source tree unexpectedly changed during install"

ROLLBACK_ARMED=0
trap - EXIT
cleanup_tmp

echo "===== LIVE POC INSTALL RESULT ====="
echo "RESULT: PASS"
echo "Worldserver SHA256: $LIVE_SHA"
echo "Backup:   $BACKUP"
echo "Rollback: bash $BACKUP/rollback.sh $BACKUP"
echo "Client MPQs:"
echo "  $CLIENT_ROOT/Data/patch-4.MPQ"
echo "  $CLIENT_ROOT/Data/enUS/patch-enUS-4.MPQ"
echo "Next: copy both MPQs to the test PC client and attempt Race 17 Alliance Tuskarr Warrior creation/login."
echo "Finished: $(date -Is)"
