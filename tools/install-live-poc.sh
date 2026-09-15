#!/usr/bin/env bash
set -euo pipefail

CORE_ROOT="${CORE_ROOT:-/home/azeroth/azerothcore}"
BUILD_DIR="${BUILD_DIR:-$CORE_ROOT/build}"
SERVER_ROOT="${SERVER_ROOT:-/home/azeroth/server}"
CLIENT_ROOT="${CLIENT_ROOT:-/home/azeroth/wow-client}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${1:-}"
JOBS="${JOBS:-16}"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run as root"
[[ -n "$BUNDLE" && -d "$BUNDLE" ]] || fail "usage: $0 /root/tuskarr-milestone4-YYYYMMDD-HHMMSS"

CONF="$SERVER_ROOT/etc/worldserver.conf"
[[ -f "$CONF" ]] || fail "worldserver.conf missing"

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
      --no-create-info --skip-triggers --single-transaction --skip-lock-tables \
      "$DB_NAME" "$table" --where="$where" > "$outfile"
}

WORLD_INFO="$(conf_value WorldDatabaseInfo "$CONF")"
CHAR_INFO="$(conf_value CharacterDatabaseInfo "$CONF")"
LOGIN_INFO="$(conf_value LoginDatabaseInfo "$CONF")"
parse_db_info "$WORLD_INFO" || fail "could not parse WorldDatabaseInfo"
parse_db_info "$CHAR_INFO" || fail "could not parse CharacterDatabaseInfo"
parse_db_info "$LOGIN_INFO" || fail "could not parse LoginDatabaseInfo"

# Full audited preflight must pass before any source or live-state change.
echo "===== FINAL READ-ONLY PREFLIGHT ====="
bash "$PROJECT_ROOT/tools/live-poc-preflight-v2.sh" "$BUNDLE"

mapfile -t ACTIVE_SERVICES < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'worldserver' | while read -r s; do [[ "$(systemctl is-active "$s" 2>/dev/null || true)" == active ]] && echo "$s"; done)
((${#ACTIVE_SERVICES[@]} == 1)) || fail "expected exactly one active worldserver service"
SERVICE="${ACTIVE_SERVICES[0]}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/tuskarr-live-backup-$STAMP"
mkdir -p "$BACKUP"/{live/dbc,live/client,db,core,logs}
chmod 700 "$BACKUP"
REPORT="$BACKUP/INSTALL-REPORT.txt"
exec > >(tee "$REPORT") 2>&1

echo "===== Playable Tuskarr live PoC install ====="
echo "Bundle:  $BUNDLE"
echo "Backup:  $BACKUP"
echo "Service: $SERVICE"
echo "Jobs:    $JOBS"
echo "Started: $(date -Is)"

(cd "$BUNDLE" && sha256sum -c SHA256SUMS.txt)

LIVE_BIN="$SERVER_ROOT/bin/worldserver"
TARGET_CPP="$CORE_ROOT/modules/mod-playerbots/src/Bot/Factory/RandomPlayerbotFactory.cpp"
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

{
    printf 'SERVICE=%q\n' "$SERVICE"
    printf 'BUNDLE=%q\n' "$BUNDLE"
    printf 'GLOBAL_PATCH_EXISTED=%q\n' "$GLOBAL_PATCH_EXISTED"
    printf 'LOCALE_PATCH_EXISTED=%q\n' "$LOCALE_PATCH_EXISTED"
    printf 'CORE_HEAD=%q\n' "$(git -C "$CORE_ROOT" rev-parse HEAD)"
} > "$BACKUP/metadata.env"

cp "$PROJECT_ROOT/tools/rollback-live-poc.sh" "$BACKUP/rollback.sh"
chmod 700 "$BACKUP/rollback.sh"
echo "PASS: backups created"
echo "Rollback command: bash $BACKUP/rollback.sh $BACKUP"

PATCH="$BUNDLE/server/core/playerbots-exclude-tuskarr-random-generation.patch"
git -C "$CORE_ROOT" apply --check "$PATCH"
git -C "$CORE_ROOT" apply "$PATCH"
echo "PASS: playerbots safeguard applied to source"

# Build while the existing realm remains online. If this fails, restore source and stop.
set +e
cmake --build "$BUILD_DIR" --target worldserver -- -j"$JOBS" 2>&1 | tee "$BACKUP/logs/build-worldserver.log"
BUILD_RC=${PIPESTATUS[0]}
set -e
if (( BUILD_RC != 0 )); then
    cp -a "$BACKUP/core/RandomPlayerbotFactory.cpp" "$TARGET_CPP"
    fail "worldserver build failed; live realm was not changed and source was restored"
fi

NEW_BIN="$(find "$BUILD_DIR" -type f -name worldserver -perm /111 -printf '%T@\t%p\n' | sort -nr | head -n1 | cut -f2-)"
[[ -n "$NEW_BIN" && -x "$NEW_BIN" ]] || { cp -a "$BACKUP/core/RandomPlayerbotFactory.cpp" "$TARGET_CPP"; fail "could not locate rebuilt worldserver"; }
echo "Rebuilt worldserver: $NEW_BIN"
sha256sum "$NEW_BIN"

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
BOT_IDS="$(mktemp)"; ONLINE_ROWS="$(mktemp)"
trap 'rm -f "$BOT_IDS" "$ONLINE_ROWS"' EXIT
mysql_query "$LOGIN_INFO" "SELECT id FROM account WHERE username LIKE '${prefix}%';" > "$BOT_IDS"
mysql_query "$CHAR_INFO" 'SELECT account,name FROM characters WHERE online=1 ORDER BY account,name;' > "$ONLINE_ROWS"
NONBOTS="$(awk 'NR==FNR{b[$1]=1;next} !($1 in b){n++} END{print n+0}' "$BOT_IDS" "$ONLINE_ROWS")"
TOTAL="$(wc -l < "$ONLINE_ROWS")"
if (( NONBOTS != 0 )); then
    echo "Non-bot online rows:"
    awk 'NR==FNR{b[$1]=1;next} !($1 in b){print}' "$BOT_IDS" "$ONLINE_ROWS"
    cp -a "$BACKUP/core/RandomPlayerbotFactory.cpp" "$TARGET_CPP"
    fail "$NONBOTS non-bot character(s) came online during build; install aborted before downtime"
fi
echo "PASS: immediate downtime gate: TOTAL=$TOTAL NONBOTS=0"

systemctl stop "$SERVICE"
for _ in {1..60}; do
    pgrep -x worldserver >/dev/null || break
    sleep 1
done
pgrep -x worldserver >/dev/null && fail "worldserver did not stop cleanly"
echo "PASS: worldserver stopped"

# Install live server payload.
install -o azeroth -g azeroth -m 0755 "$NEW_BIN" "$LIVE_BIN"
for f in ChrRaces.dbc CharBaseInfo.dbc CharStartOutfit.dbc SkillRaceClassInfo.dbc SkillLineAbility.dbc; do
    install -o azeroth -g azeroth -m 0644 "$BUNDLE/server/dbc/$f" "$SERVER_ROOT/bin/dbc/$f"
done
mysql_file "$WORLD_INFO" "$BUNDLE/server/sql/00_playable_tuskarr_poc.sql"

CLIENT_UID="$(stat -c %u "$CLIENT_ROOT")"
CLIENT_GID="$(stat -c %g "$CLIENT_ROOT")"
install -o "$CLIENT_UID" -g "$CLIENT_GID" -m 0644 "$BUNDLE/client/packages/Data/patch-4.MPQ" "$CLIENT_ROOT/Data/patch-4.MPQ"
install -o "$CLIENT_UID" -g "$CLIENT_GID" -m 0644 "$BUNDLE/client/packages/Data/enUS/patch-enUS-4.MPQ" "$CLIENT_ROOT/Data/enUS/patch-enUS-4.MPQ"
echo "PASS: binary, five server DBCs, SQL, and two client MPQs installed"

systemctl start "$SERVICE"
sleep 8
if ! systemctl is-active --quiet "$SERVICE" || ! pgrep -x worldserver >/dev/null; then
    echo "FAIL: worldserver did not survive startup; capturing diagnostics and rolling back"
    systemctl status "$SERVICE" --no-pager > "$BACKUP/logs/failed-status.txt" 2>&1 || true
    journalctl -u "$SERVICE" -n 200 --no-pager > "$BACKUP/logs/failed-journal.txt" 2>&1 || true
    bash "$BACKUP/rollback.sh" "$BACKUP"
    exit 2
fi

sleep 8
if ! systemctl is-active --quiet "$SERVICE" || ! pgrep -x worldserver >/dev/null; then
    echo "FAIL: worldserver exited shortly after startup; rolling back"
    journalctl -u "$SERVICE" -n 200 --no-pager > "$BACKUP/logs/failed-journal.txt" 2>&1 || true
    bash "$BACKUP/rollback.sh" "$BACKUP"
    exit 2
fi

echo "PASS: worldserver active after restart"
ps -C worldserver -o pid,user,lstart,etime,%cpu,%mem,cmd

# Verify installed payload and SQL state.
for f in ChrRaces.dbc CharBaseInfo.dbc CharStartOutfit.dbc SkillRaceClassInfo.dbc SkillLineAbility.dbc; do
    cmp -s "$BUNDLE/server/dbc/$f" "$SERVER_ROOT/bin/dbc/$f" || fail "live DBC mismatch: $f"
done
cmp -s "$BUNDLE/client/packages/Data/patch-4.MPQ" "$CLIENT_ROOT/Data/patch-4.MPQ" || fail "global client MPQ mismatch"
cmp -s "$BUNDLE/client/packages/Data/enUS/patch-enUS-4.MPQ" "$CLIENT_ROOT/Data/enUS/patch-enUS-4.MPQ" || fail "locale client MPQ mismatch"
cmp -s "$NEW_BIN" "$LIVE_BIN" || fail "live worldserver binary mismatch"

PCI="$(mysql_query "$WORLD_INFO" 'SELECT COUNT(*) FROM playercreateinfo WHERE race IN (17,18);')"
PRS="$(mysql_query "$WORLD_INFO" 'SELECT COUNT(*) FROM player_race_stats WHERE Race IN (17,18);')"
PCA="$(mysql_query "$WORLD_INFO" 'SELECT COUNT(*) FROM playercreateinfo_action WHERE race IN (17,18);')"
echo "SQL_COUNTS playercreateinfo=$PCI player_race_stats=$PRS playercreateinfo_action=$PCA"
[[ "$PCI" == 6 && "$PRS" == 2 && "$PCA" == 20 ]] || fail "unexpected PoC SQL row counts"

git -C "$CORE_ROOT" apply -R --check "$PATCH" >/dev/null || fail "playerbots source patch is not present after successful build"

echo "===== LIVE POC INSTALL RESULT ====="
echo "RESULT: PASS"
echo "Backup:   $BACKUP"
echo "Rollback: bash $BACKUP/rollback.sh $BACKUP"
echo "Client MPQs:"
echo "  $CLIENT_ROOT/Data/patch-4.MPQ"
echo "  $CLIENT_ROOT/Data/enUS/patch-enUS-4.MPQ"
echo "Next: copy both MPQs to the test PC client and attempt Race 17 Alliance Tuskarr Warrior creation/login."
echo "Finished: $(date -Is)"
