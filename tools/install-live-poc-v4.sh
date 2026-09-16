#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$PROJECT_ROOT/tools/install-live-poc.sh"
EXPECTED_BLOB="76817c2506ece6c315892dc8fd5b780abd7031bd"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run as root"
[[ -f "$BASE" ]] || fail "base installer missing: $BASE"

ACTUAL_BLOB="$(git -C "$PROJECT_ROOT" hash-object tools/install-live-poc.sh)"
[[ "$ACTUAL_BLOB" == "$EXPECTED_BLOB" ]] || fail "unexpected base installer revision: $ACTUAL_BLOB"

TMP="$PROJECT_ROOT/tools/.install-live-poc-v4.$$.sh"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

python3 - "$BASE" "$TMP" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])

simple_replacements = {
    'strings "$ARTIFACT" | grep -Fq "$EXPECTED_CONF_DIR" || fail "artifact does not embed expected live config directory"':
        'grep -aFq "$EXPECTED_CONF_DIR" "$ARTIFACT" || fail "artifact does not embed expected live config directory"',
    'if strings "$ARTIFACT" | grep -Fq "$FRESH_OUT/stage/etc"; then':
        'if grep -aFq "$FRESH_OUT/stage/etc" "$ARTIFACT"; then',
}

for old, new in simple_replacements.items():
    count = src.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one base-installer match, found {count}: {old}")
    src = src.replace(old, new)

old_downtime = '''# Re-check online accounts immediately before downtime. Only configured random-bot accounts may be online.
mapfile -t PB_CONFS < <(find "$SERVER_ROOT/etc" -type f \\( -name 'playerbots.conf' -o -name '*playerbots*.conf' \\) ! -name '*.dist' -print | sort -u)
prefix=""
for cfg in "${PB_CONFS[@]}"; do
    candidate="$(sed -nE 's/^[[:space:]]*AiPlayerbot\\.RandomBotAccountPrefix[[:space:]]*=[[:space:]]*"?([^"#[:space:]]+)"?.*$/\\1/p' "$cfg" | tail -n1)"
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
'''

new_downtime = '''# Re-check actual network client sessions immediately before downtime.
# At this audited AzerothCore revision WorldSession sets auth.account.online=1
# only when a real WorldSocket exists. Playerbot sessions created without a
# socket do not set this flag, including altbots on normal player accounts.
ONLINE_CLIENTS="$(mysql_query "$LOGIN_INFO" 'SELECT id,username FROM account WHERE online=1 ORDER BY id;')"
if [[ -n "$ONLINE_CLIENTS" ]]; then
    CLIENT_COUNT="$(wc -l <<<"$ONLINE_CLIENTS")"
    echo "Connected real network account sessions:"
    printf '%s\\n' "$ONLINE_CLIENTS"
    fail "$CLIENT_COUNT real network account session(s) are connected; install aborted before downtime"
fi
echo "PASS: immediate downtime gate: REAL_NETWORK_SESSIONS=0"
'''

count = src.count(old_downtime)
if count != 1:
    raise SystemExit(f"expected exactly one old downtime-gate block, found {count}")
src = src.replace(old_downtime, new_downtime)

old_startup = '''READY=0
for _ in {1..120}; do
    if ! systemctl is-active --quiet "$SERVICE" || ! pgrep -x worldserver >/dev/null; then
        fail "worldserver exited during startup"
    fi
    NEW_LOG="$(tail -n +"$((LOG_START + 1))" "$CONSOLE_LOG" 2>/dev/null || true)"
    if grep -Eq '>> FATAL ERROR|ACE00046|Used MySQL library version .* does not match|Config::LoadFile: Failed open file' <<<"$NEW_LOG"; then
        fail "new worldserver startup logged a fatal/configuration error"
    fi
    if grep -Fq '(worldserver-daemon) ready...' <<<"$NEW_LOG"; then
        READY=1
        break
    fi
    sleep 1
done
[[ "$READY" == 1 ]] || fail "worldserver stayed alive but did not reach the AzerothCore ready marker within the startup gate"
echo "PASS: new worldserver reached AzerothCore ready marker"
'''

new_startup = '''# The systemd unit wraps worldserver in tmux. systemctl can become active a few
# milliseconds before tmux has spawned the child, so do not treat an immediate
# pgrep miss as a crash. First allow a bounded child-spawn grace period.
CHILD_SEEN=0
for _ in {1..30}; do
    NEW_LOG="$(tail -n +"$((LOG_START + 1))" "$CONSOLE_LOG" 2>/dev/null || true)"
    if grep -Eq '>> FATAL ERROR|ACE00046|Used MySQL library version .* does not match|Config::LoadFile: Failed open file' <<<"$NEW_LOG"; then
        fail "new worldserver startup logged a fatal/configuration error during child-spawn grace period"
    fi
    if pgrep -x worldserver >/dev/null; then
        CHILD_SEEN=1
        break
    fi
    if systemctl is-failed --quiet "$SERVICE"; then
        fail "worldserver service entered failed state before child process appeared"
    fi
    sleep 1
done
[[ "$CHILD_SEEN" == 1 ]] || fail "worldserver child did not appear within 30-second startup grace period"
echo "PASS: worldserver child process appeared after service start"

# Once the child exists, require it and the service to remain alive while the
# normal AzerothCore startup sequence reaches its ready marker.
READY=0
for _ in {1..300}; do
    if ! systemctl is-active --quiet "$SERVICE"; then
        fail "worldserver service left active state during startup"
    fi
    if ! pgrep -x worldserver >/dev/null; then
        fail "worldserver child exited during startup"
    fi
    NEW_LOG="$(tail -n +"$((LOG_START + 1))" "$CONSOLE_LOG" 2>/dev/null || true)"
    if grep -Eq '>> FATAL ERROR|ACE00046|Used MySQL library version .* does not match|Config::LoadFile: Failed open file' <<<"$NEW_LOG"; then
        fail "new worldserver startup logged a fatal/configuration error"
    fi
    if grep -Fq '(worldserver-daemon) ready...' <<<"$NEW_LOG"; then
        READY=1
        break
    fi
    sleep 1
done
[[ "$READY" == 1 ]] || fail "worldserver stayed alive but did not reach the AzerothCore ready marker within 300 seconds"
echo "PASS: new worldserver reached AzerothCore ready marker"
'''

count = src.count(old_startup)
if count != 1:
    raise SystemExit(f"expected exactly one startup-gate block, found {count}")
src = src.replace(old_startup, new_startup)

out.write_text(src)
out.chmod(0o700)
PY

echo "PASS: prepared v4 installer with core-native network-session gate, pipefail-safe config gates, and tmux child-spawn grace period"
set +e
bash "$TMP" "$@"
RC=$?
set -e
cleanup
trap - EXIT
exit "$RC"
