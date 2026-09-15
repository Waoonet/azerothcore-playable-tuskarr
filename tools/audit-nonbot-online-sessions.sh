#!/usr/bin/env bash
set -euo pipefail

SERVER_ROOT="${SERVER_ROOT:-/home/azeroth/server}"
CONF="$SERVER_ROOT/etc/worldserver.conf"
CONSOLE_LOG="$SERVER_ROOT/logs/worldserver-console.log"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run as root"
[[ -f "$CONF" ]] || fail "worldserver.conf missing: $CONF"
command -v mysql >/dev/null || fail "mysql client not found"

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

CHAR_INFO="$(conf_value CharacterDatabaseInfo "$CONF")"
LOGIN_INFO="$(conf_value LoginDatabaseInfo "$CONF")"
parse_db_info "$CHAR_INFO" || fail "could not parse CharacterDatabaseInfo"
parse_db_info "$LOGIN_INFO" || fail "could not parse LoginDatabaseInfo"

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
NONBOT_ROWS="$(mktemp)"
trap 'rm -f "$BOT_IDS" "$ONLINE_ROWS" "$NONBOT_ROWS"' EXIT

mysql_query "$LOGIN_INFO" "SELECT id FROM account WHERE username LIKE '${prefix}%';" > "$BOT_IDS"
mysql_query "$CHAR_INFO" 'SELECT account,name FROM characters WHERE online=1 ORDER BY account,name;' > "$ONLINE_ROWS"
awk 'NR==FNR{b[$1]=1;next} !($1 in b){print}' "$BOT_IDS" "$ONLINE_ROWS" > "$NONBOT_ROWS"

TOTAL="$(wc -l < "$ONLINE_ROWS")"
BOTS="$(awk 'NR==FNR{b[$1]=1;next} ($1 in b){n++} END{print n+0}' "$BOT_IDS" "$ONLINE_ROWS")"
NONBOTS="$(wc -l < "$NONBOT_ROWS")"

echo "===== Non-bot online-session audit ====="
echo "Mode: READ-ONLY / NO DATABASE OR SERVER CHANGES"
echo "Random-bot account prefix: $prefix"
echo "TOTAL=$TOTAL"
echo "BOTS=$BOTS"
echo "NONBOTS=$NONBOTS"

if (( NONBOTS == 0 )); then
    echo "PASS: no non-bot characters are marked online"
    exit 0
fi

echo
echo "===== Non-bot rows grouped by account ====="
cut -f1 "$NONBOT_ROWS" | sort -n | uniq -c | awk '{printf "account=%s marked_online_rows=%s\n", $2, $1}'

echo
echo "===== Account metadata (no password/session secrets) ====="
while read -r account _name; do
    [[ -n "$account" ]] || continue
    username="$(mysql_query "$LOGIN_INFO" "SELECT username FROM account WHERE id=${account} LIMIT 1;")"
    last_login="$(mysql_query "$LOGIN_INFO" "SELECT COALESCE(DATE_FORMAT(last_login,'%Y-%m-%d %H:%i:%s'),'NULL') FROM account WHERE id=${account} LIMIT 1;" 2>/dev/null || true)"
    expansion="$(mysql_query "$LOGIN_INFO" "SELECT expansion FROM account WHERE id=${account} LIMIT 1;" 2>/dev/null || true)"
    gmlevel="$(mysql_query "$LOGIN_INFO" "SELECT COALESCE(MAX(gmlevel),0) FROM account_access WHERE id=${account};" 2>/dev/null || true)"
    echo "account=$account username=$username last_login=${last_login:-unknown} expansion=${expansion:-unknown} gmlevel=${gmlevel:-unknown}"
done < <(awk '!seen[$1]++{print $1,$2}' "$NONBOT_ROWS")

echo
echo "===== Character rows marked online ====="
while read -r account name; do
    mysql_query "$CHAR_INFO" "SELECT CONCAT('account=',account,' guid=',guid,' name=',name,' race=',race,' class=',class,' level=',level,' online=',online,' logout_time=',logout_time) FROM characters WHERE account=${account} AND name='${name//\'/\'\'}' LIMIT 1;"
done < "$NONBOT_ROWS"

echo
echo "===== Same-account consistency check ====="
while read -r account _name; do
    [[ -n "$account" ]] || continue
    marked="$(mysql_query "$CHAR_INFO" "SELECT COUNT(*) FROM characters WHERE account=${account} AND online=1;")"
    echo "account=$account characters_marked_online=$marked"
    if (( marked > 1 )); then
        echo "WARNING: multiple characters on the same account are marked online; they cannot all be simultaneous normal client sessions on one realm."
    fi
done < <(awk '!seen[$1]++{print $1,$2}' "$NONBOT_ROWS")

PORT="$(sed -nE 's/^[[:space:]]*WorldServerPort[[:space:]]*=[[:space:]]*([0-9]+).*$/\1/p' "$CONF" | tail -n1)"
[[ -n "$PORT" ]] || PORT=8085

echo
echo "===== Established client TCP connections to world port ====="
echo "WorldServerPort=$PORT"
if command -v ss >/dev/null; then
    CONNECTIONS="$(ss -Htn state established 2>/dev/null | awk -v p=":${PORT}" '$4 ~ p"$" {n++} END{print n+0}')"
    echo "ESTABLISHED_WORLD_CONNECTIONS=$CONNECTIONS"
else
    echo "ESTABLISHED_WORLD_CONNECTIONS=unknown (ss unavailable)"
fi

echo
echo "===== Recent console evidence for affected character names ====="
if [[ -f "$CONSOLE_LOG" ]]; then
    regex="$(awk '{print $2}' "$NONBOT_ROWS" | paste -sd'|' -)"
    if [[ -n "$regex" ]]; then
        tail -n 50000 "$CONSOLE_LOG" | grep -Ei -C 2 "($regex).*(log|connect|disconnect|enter|leave)|((log|connect|disconnect|enter|leave).*)($regex)" | tail -n 200 || true
    fi
else
    echo "console log not found"
fi

echo
echo "===== Interpretation gate ====="
echo "Do not clear online flags or restart the realm from this audit alone."
echo "If ESTABLISHED_WORLD_CONNECTIONS is non-zero, treat at least one real client session as active until identified/logged out."
echo "If it is zero and multiple characters on one non-bot account remain online=1, those rows are candidates for stale flags and require a separate controlled cleanup step."
