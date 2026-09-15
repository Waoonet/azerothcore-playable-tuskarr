#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_ROOT="${SERVER_ROOT:-/home/azeroth/server}"
BUNDLE="${1:-}"
BASE="$PROJECT_ROOT/tools/live-poc-preflight.sh"
TMP="$(mktemp)"
BOT_IDS="$(mktemp)"
ONLINE_ROWS="$(mktemp)"
trap 'rm -f "$TMP" "$BOT_IDS" "$ONLINE_ROWS"' EXIT

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
    echo "===== Bot-aware online-session refinement ====="
    echo "RESULT: BLOCKED"
    echo "The original preflight has a failure other than (or in addition to) the coarse online-character count."
    exit "$base_rc"
fi

echo
echo "===== Bot-aware online-session refinement ====="

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

mapfile -t PB_CONFS < <(find "$SERVER_ROOT/etc" -type f \( -name 'playerbots.conf' -o -name '*playerbots*.conf' \) ! -name '*.dist' -print 2>/dev/null | sort -u)
if ((${#PB_CONFS[@]} == 0)); then
    echo "FAIL: installed playerbots.conf was not found under $SERVER_ROOT/etc"
    exit 2
fi

echo "Playerbots config candidates:"
printf '  %s\n' "${PB_CONFS[@]}"

prefix=""
prefix_source=""
for cfg in "${PB_CONFS[@]}"; do
    candidate="$(sed -nE 's/^[[:space:]]*AiPlayerbot\.RandomBotAccountPrefix[[:space:]]*=[[:space:]]*"?([^"#[:space:]]+)"?.*$/\1/p' "$cfg" | tail -n1)"
    if [[ -n "$candidate" ]]; then
        if [[ -n "$prefix" && "$candidate" != "$prefix" ]]; then
            echo "FAIL: conflicting AiPlayerbot.RandomBotAccountPrefix values: '$prefix' and '$candidate'"
            exit 2
        fi
        prefix="$candidate"
        prefix_source="$cfg"
    fi
done

if [[ -z "$prefix" ]]; then
    echo "FAIL: AiPlayerbot.RandomBotAccountPrefix is not explicitly present in installed playerbots config"
    exit 2
fi
if [[ ! "$prefix" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "FAIL: bot account prefix contains characters this safety gate will not interpolate into SQL: $prefix"
    exit 2
fi

echo "Random bot account prefix: $prefix"
echo "Prefix source: $prefix_source"

mysql_query "$LOGIN_INFO" "SELECT id FROM account WHERE username LIKE '${prefix}%';" >"$BOT_IDS"
bot_accounts="$(wc -l <"$BOT_IDS")"
if (( bot_accounts == 0 )); then
    echo "FAIL: no login accounts match bot prefix '${prefix}%'; refusing to treat online characters as bots"
    exit 2
fi
echo "Random-bot login accounts matched: $bot_accounts"

if ! char_ping="$(mysql_query "$CHAR_INFO" 'SELECT 1;' 2>/dev/null)" || [[ "$char_ping" != "1" ]]; then
    echo "FAIL: characters database connection failed during refined check"
    exit 2
fi
mysql_query "$CHAR_INFO" 'SELECT account,name FROM characters WHERE online=1 ORDER BY account,name;' >"$ONLINE_ROWS"

summary="$(awk '
NR==FNR { bot[$1]=1; next }
{
    total++
    if ($1 in bot) bots++
    else { humans++; human_rows = human_rows sprintf("  account=%s character=%s\n", $1, $2) }
}
END {
    printf "TOTAL=%d\nBOTS=%d\nNONBOTS=%d\n", total+0, bots+0, humans+0
    if (humans) printf "%s", human_rows
}
' "$BOT_IDS" "$ONLINE_ROWS")"

printf '%s\n' "$summary"
total="$(sed -n 's/^TOTAL=//p' <<<"$summary")"
bots="$(sed -n 's/^BOTS=//p' <<<"$summary")"
nonbots="$(sed -n 's/^NONBOTS=//p' <<<"$summary")"

if [[ ! "$total" =~ ^[0-9]+$ || ! "$bots" =~ ^[0-9]+$ || ! "$nonbots" =~ ^[0-9]+$ ]]; then
    echo "FAIL: could not classify online character rows"
    exit 2
fi

if (( nonbots > 0 )); then
    echo "FAIL: $nonbots online character(s) belong to accounts outside the configured random-bot account prefix."
    echo "RESULT: BLOCKED"
    exit 2
fi

if (( total == 0 )); then
    echo "PASS: no characters are online"
else
    echo "PASS: all $total online character(s) belong to configured random-bot accounts (${prefix}*)"
fi

echo "PASS: no non-bot/human account has an online character"
echo
echo "===== Refined preflight result ====="
echo "RESULT: PASS"
echo "The original single failure was the coarse online count; the bot-aware classification resolved it."
echo "No changes were made."
