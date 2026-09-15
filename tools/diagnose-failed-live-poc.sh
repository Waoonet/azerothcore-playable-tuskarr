#!/usr/bin/env bash
set -euo pipefail

SERVER_ROOT="${SERVER_ROOT:-/home/azeroth/server}"
BACKUP="${1:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run as root"
[[ -n "$BACKUP" && -d "$BACKUP" ]] || fail "usage: $0 /root/tuskarr-live-backup-YYYYMMDD-HHMMSS"

REPORT="$BACKUP/FAILURE-DIAGNOSTIC.txt"
exec > >(tee "$REPORT") 2>&1

section() { printf '\n===== %s =====\n' "$*"; }

section "Playable Tuskarr failed live PoC diagnostic"
echo "Backup:  $BACKUP"
echo "Server:  $SERVER_ROOT"
echo "Time:    $(date -Is)"

section "Rollback state"
if [[ -f "$BACKUP/ROLLBACK-REPORT.txt" ]]; then
    cat "$BACKUP/ROLLBACK-REPORT.txt"
else
    echo "No ROLLBACK-REPORT.txt found"
fi

echo
systemctl is-active azeroth-worldserver.service 2>/dev/null || true
pgrep -a worldserver || true

section "Captured failed systemd status"
if [[ -s "$BACKUP/logs/failed-status.txt" ]]; then
    cat "$BACKUP/logs/failed-status.txt"
else
    echo "No failed-status.txt captured"
fi

section "Captured failed journal"
if [[ -s "$BACKUP/logs/failed-journal.txt" ]]; then
    cat "$BACKUP/logs/failed-journal.txt"
else
    echo "No failed-journal.txt captured"
fi

section "High-signal lines from captured failure"
{
    [[ -s "$BACKUP/logs/failed-status.txt" ]] && cat "$BACKUP/logs/failed-status.txt"
    [[ -s "$BACKUP/logs/failed-journal.txt" ]] && cat "$BACKUP/logs/failed-journal.txt"
} | grep -Ein -C 4 'fatal|error|assert|exception|dbc|race|char(base|start)|skillrace|skillline|segfault|signal|abort|crash|failed|invalid|duplicate|missing|cannot|could not|unsupported' || true

section "Worldserver log inventory"
if [[ -d "$SERVER_ROOT/logs" ]]; then
    find "$SERVER_ROOT/logs" -maxdepth 1 -type f -printf '%T@\t%TY-%Tm-%Td %TH:%TM:%TS\t%p\t%s bytes\n' 2>/dev/null | sort -nr | head -40
else
    echo "Server log directory not found: $SERVER_ROOT/logs"
fi

section "Recent worldserver log tails"
if [[ -d "$SERVER_ROOT/logs" ]]; then
    mapfile -t RECENT_LOGS < <(find "$SERVER_ROOT/logs" -maxdepth 1 -type f -mmin -180 -printf '%T@\t%p\n' 2>/dev/null | sort -nr | head -12 | cut -f2-)
    if ((${#RECENT_LOGS[@]})); then
        for log in "${RECENT_LOGS[@]}"; do
            echo
            echo "--- $log ---"
            tail -n 160 "$log" 2>/dev/null || true
        done
    else
        echo "No logs modified in the last 180 minutes."
    fi
fi

section "High-signal lines from recent server logs"
if [[ -d "$SERVER_ROOT/logs" ]]; then
    while IFS= read -r log; do
        echo
        echo "--- $log ---"
        grep -Ein -C 5 'fatal|error|assert|exception|dbc|race|char(base|start)|skillrace|skillline|segfault|signal|abort|crash|failed|invalid|duplicate|missing|cannot|could not|unsupported' "$log" 2>/dev/null | tail -n 240 || true
    done < <(find "$SERVER_ROOT/logs" -maxdepth 1 -type f -mmin -180 -print 2>/dev/null | sort)
fi

section "Current service health after rollback"
systemctl status azeroth-worldserver.service --no-pager || true
ps -C worldserver -o pid,user,lstart,etime,%cpu,%mem,cmd || true

section "Diagnostic result"
echo "Diagnostic capture complete."
echo "Report: $REPORT"
echo "Do not retry the Tuskarr live installer until the startup failure above is identified and corrected."
