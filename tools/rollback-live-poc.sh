#!/usr/bin/env bash
set -euo pipefail

CORE_ROOT="${CORE_ROOT:-/home/azeroth/azerothcore}"
SERVER_ROOT="${SERVER_ROOT:-/home/azeroth/server}"
CLIENT_ROOT="${CLIENT_ROOT:-/home/azeroth/wow-client}"
BACKUP="${1:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run as root"
[[ -n "$BACKUP" && -d "$BACKUP" ]] || fail "usage: $0 /root/tuskarr-live-backup-YYYYMMDD-HHMMSS"
[[ -f "$BACKUP/metadata.env" ]] || fail "backup metadata missing: $BACKUP/metadata.env"
# shellcheck disable=SC1090
source "$BACKUP/metadata.env"

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
mysql_exec() {
    local raw="$1" sql="$2"
    parse_db_info "$raw" || return 90
    MYSQL_PWD="$DB_PASS" mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" -e "$sql"
}
mysql_file() {
    local raw="$1" file="$2"
    parse_db_info "$raw" || return 90
    MYSQL_PWD="$DB_PASS" mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" < "$file"
}

WORLD_INFO="$(conf_value WorldDatabaseInfo "$CONF")"
parse_db_info "$WORLD_INFO" || fail "could not parse WorldDatabaseInfo"

REPORT="$BACKUP/ROLLBACK-REPORT.txt"
exec > >(tee -a "$REPORT") 2>&1

echo "===== Playable Tuskarr PoC rollback ====="
echo "Backup:  $BACKUP"
echo "Service: $SERVICE"
echo "Started: $(date -Is)"

systemctl stop "$SERVICE" || true
for _ in {1..30}; do
    pgrep -x worldserver >/dev/null || break
    sleep 1
done
if pgrep -x worldserver >/dev/null; then
    fail "worldserver is still running after service stop"
fi

install -o azeroth -g azeroth -m 0755 "$BACKUP/live/worldserver" "$SERVER_ROOT/bin/worldserver"
for f in ChrRaces.dbc CharBaseInfo.dbc CharStartOutfit.dbc SkillRaceClassInfo.dbc SkillLineAbility.dbc; do
    install -o azeroth -g azeroth -m 0644 "$BACKUP/live/dbc/$f" "$SERVER_ROOT/bin/dbc/$f"
done

if [[ "${GLOBAL_PATCH_EXISTED:-0}" == "1" ]]; then
    cp -a "$BACKUP/live/client/patch-4.MPQ" "$CLIENT_ROOT/Data/patch-4.MPQ"
else
    rm -f "$CLIENT_ROOT/Data/patch-4.MPQ"
fi
if [[ "${LOCALE_PATCH_EXISTED:-0}" == "1" ]]; then
    cp -a "$BACKUP/live/client/patch-enUS-4.MPQ" "$CLIENT_ROOT/Data/enUS/patch-enUS-4.MPQ"
else
    rm -f "$CLIENT_ROOT/Data/enUS/patch-enUS-4.MPQ"
fi

mysql_exec "$WORLD_INFO" "DELETE FROM playercreateinfo_action WHERE race IN (17,18); DELETE FROM player_race_stats WHERE Race IN (17,18); DELETE FROM playercreateinfo WHERE race IN (17,18);"
for f in "$BACKUP/db/playercreateinfo.sql" "$BACKUP/db/player_race_stats.sql" "$BACKUP/db/playercreateinfo_action.sql"; do
    [[ -s "$f" ]] && mysql_file "$WORLD_INFO" "$f"
done

TARGET="$CORE_ROOT/modules/mod-playerbots/src/Bot/Factory/RandomPlayerbotFactory.cpp"
if [[ -f "$BACKUP/core/RandomPlayerbotFactory.cpp" ]]; then
    cp -a "$BACKUP/core/RandomPlayerbotFactory.cpp" "$TARGET"
fi

systemctl start "$SERVICE"
sleep 5
if systemctl is-active --quiet "$SERVICE" && pgrep -x worldserver >/dev/null; then
    echo "PASS: rollback complete and worldserver is running"
else
    echo "FAIL: rollback files restored but worldserver did not return active"
    systemctl status "$SERVICE" --no-pager || true
    journalctl -u "$SERVICE" -n 100 --no-pager || true
    exit 2
fi

echo "Finished: $(date -Is)"
