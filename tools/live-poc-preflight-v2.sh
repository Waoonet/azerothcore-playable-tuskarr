#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_ROOT="${SERVER_ROOT:-/home/azeroth/server}"
BUNDLE="${1:-}"
BASE="$PROJECT_ROOT/tools/live-poc-preflight.sh"
TMP="$(mktemp)"
ONLINE_ACCOUNTS="$(mktemp)"
ONLINE_CHARS="$(mktemp)"
trap 'rm -f "$TMP" "$ONLINE_ACCOUNTS" "$ONLINE_CHARS"' EXIT

set +e
set -o pipefail
bash "$BASE" "$BUNDLE" | tee "$TMP"
base_rc=${PIPESTATUS[0]}
set +o pipefail
set -e

if (( base_rc == 0 )); then
    exit 0
fi

# Only override the original preflight when its single failure is the coarse
# characters.online count. Any other failed gate remains fatal.
if ! grep -q '^Failures: 1$' "$TMP" || \
   ! grep -Eq '^FAIL: [0-9]+ character\(s\) are online; live PoC install must not restart the realm$' "$TMP"; then
    echo
    echo "===== Network-session refinement ====="
    echo "RESULT: BLOCKED"
    echo "The original preflight has a failure other than (or in addition to) the coarse online-character count."
    exit "$base_rc"
fi

echo
echo "===== Network-session refinement ====="

CONF="$SERVER_ROOT/etc/worldserver.conf"
[[ -f "$CONF" ]] || { echo "FAIL: worldserver.conf missing: $CONF"; exit 2; }

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

LOGIN_INFO="$(conf_value LoginDatabaseInfo "$CONF" 2>/dev/null || true)"
CHAR_INFO="$(conf_value CharacterDatabaseInfo "$CONF" 2>/dev/null || true)"

if ! parse_db_info "$LOGIN_INFO"; then
    echo "FAIL: could not parse LoginDatabaseInfo"
    exit 2
fi
echo "LOGIN database: host=$DB_HOST port=$DB_PORT user=$DB_USER database=$DB_NAME"

if ! login_ping="$(mysql_query "$LOGIN_INFO" 'SELECT 1;' 2>/dev/null)" || [[ "$login_ping" != "1" ]]; then
    echo "FAIL: login database connection failed"
    exit 2
fi
echo "PASS: login database connection works"

if ! char_ping="$(mysql_query "$CHAR_INFO" 'SELECT 1;' 2>/dev/null)" || [[ "$char_ping" != "1" ]]; then
    echo "FAIL: characters database connection failed during refined check"
    exit 2
fi

# AzerothCore WorldSession sets auth.account.online=1 only when the session has
# a real WorldSocket. Playerbot sessions created without a socket do not set it.
mysql_query "$LOGIN_INFO" 'SELECT id,username FROM account WHERE online=1 ORDER BY id;' >"$ONLINE_ACCOUNTS"
mysql_query "$CHAR_INFO" 'SELECT account,name FROM characters WHERE online=1 ORDER BY account,name;' >"$ONLINE_CHARS"

CLIENT_SESSIONS="$(wc -l < "$ONLINE_ACCOUNTS")"
CHAR_ROWS="$(wc -l < "$ONLINE_CHARS")"

echo "characters.online rows: $CHAR_ROWS"
echo "real network account sessions (auth.account.online=1): $CLIENT_SESSIONS"

if (( CLIENT_SESSIONS > 0 )); then
    echo "Connected account sessions:"
    while read -r account_id username; do
        [[ -n "${account_id:-}" ]] || continue
        printf '  account=%s username=%s\n' "$account_id" "$username"
        awk -v id="$account_id" '$1 == id { printf "    character=%s\n", $2 }' "$ONLINE_CHARS"
    done < "$ONLINE_ACCOUNTS"
    echo "FAIL: $CLIENT_SESSIONS real network account session(s) are connected; live PoC install must not restart the realm."
    echo "RESULT: BLOCKED"
    exit 2
fi

echo "PASS: no real network client session is connected"
if (( CHAR_ROWS > 0 )); then
    echo "PASS: $CHAR_ROWS characters.online row(s) are therefore bot/internal sessions and do not block controlled downtime"
else
    echo "PASS: no character rows are marked online"
fi

echo
echo "===== Refined preflight result ====="
echo "RESULT: PASS"
echo "The original single failure was the coarse character-online count; the core-native network-session gate resolved it."
echo "No changes were made."
