#!/usr/bin/env bash
set -euo pipefail

CORE_ROOT="${CORE_ROOT:-/home/azeroth/azerothcore}"
SERVER_ROOT="${SERVER_ROOT:-/home/azeroth/server}"
CLIENT_ROOT="${CLIENT_ROOT:-/home/azeroth/wow-client}"
BACKUP="${1:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run as root"
[[ -n "$BACKUP" && -d "$BACKUP" ]] || fail "usage: $0 /root/tuskarr-live-backup-YYYYMMDD-HHMMSS"

REPORT="$BACKUP/FAILURE-DIAGNOSTIC.txt"
exec > >(tee "$REPORT") 2>&1
section() { printf '\n===== %s =====\n' "$*"; }

FRESH_OUT=""
FRESH_WORLD_SHA256=""
GLOBAL_PATCH_EXISTED=0
LOCALE_PATCH_EXISTED=0
if [[ -f "$BACKUP/metadata.env" ]]; then
    # shellcheck disable=SC1090
    source "$BACKUP/metadata.env"
fi

section "Playable Tuskarr failed live PoC diagnostic"
echo "Backup:      $BACKUP"
echo "Core:        $CORE_ROOT"
echo "Server:      $SERVER_ROOT"
echo "Client:      $CLIENT_ROOT"
echo "Fresh build: ${FRESH_OUT:-not recorded}"
echo "Time:        $(date -Is)"

section "Rollback report"
[[ -f "$BACKUP/ROLLBACK-REPORT.txt" ]] && cat "$BACKUP/ROLLBACK-REPORT.txt" || echo "No ROLLBACK-REPORT.txt found"

section "Rollback integrity"
if [[ -f "$BACKUP/live/worldserver" ]] && cmp -s "$BACKUP/live/worldserver" "$SERVER_ROOT/bin/worldserver"; then
    echo "PASS: live worldserver matches pre-install backup"
else
    echo "FAIL: live worldserver does not match pre-install backup"
fi
for f in ChrRaces.dbc CharBaseInfo.dbc CharStartOutfit.dbc SkillRaceClassInfo.dbc SkillLineAbility.dbc; do
    if [[ -f "$BACKUP/live/dbc/$f" ]] && cmp -s "$BACKUP/live/dbc/$f" "$SERVER_ROOT/bin/dbc/$f"; then
        echo "PASS: $f restored byte-for-byte"
    else
        echo "FAIL: $f differs from pre-install backup"
    fi
done
if [[ -d "$CORE_ROOT/.git" ]]; then
    echo "Core HEAD: $(git -C "$CORE_ROOT" rev-parse HEAD 2>/dev/null || true)"
    if [[ -z "$(git -C "$CORE_ROOT" status --porcelain 2>/dev/null || true)" ]]; then
        echo "PASS: AzerothCore working tree is clean after rollback"
    else
        echo "WARN: AzerothCore working tree has changes after rollback"
        git -C "$CORE_ROOT" status --short || true
    fi
fi
if [[ "${GLOBAL_PATCH_EXISTED:-0}" == "0" ]]; then
    [[ ! -e "$CLIENT_ROOT/Data/patch-4.MPQ" ]] && echo "PASS: patch-4.MPQ removed by rollback" || echo "FAIL: patch-4.MPQ still exists"
fi
if [[ "${LOCALE_PATCH_EXISTED:-0}" == "0" ]]; then
    [[ ! -e "$CLIENT_ROOT/Data/enUS/patch-enUS-4.MPQ" ]] && echo "PASS: patch-enUS-4.MPQ removed by rollback" || echo "FAIL: patch-enUS-4.MPQ still exists"
fi
systemctl is-active azeroth-worldserver.service 2>/dev/null || true
pgrep -a worldserver || true

section "Captured failed console slice"
if [[ -s "$BACKUP/logs/failed-console-slice.txt" ]]; then
    cat "$BACKUP/logs/failed-console-slice.txt"
else
    echo "No failed-console-slice.txt captured"
fi

section "Captured failed systemd status"
[[ -s "$BACKUP/logs/failed-status.txt" ]] && cat "$BACKUP/logs/failed-status.txt" || echo "No failed-status.txt captured"

section "Captured failed journal"
[[ -s "$BACKUP/logs/failed-journal.txt" ]] && cat "$BACKUP/logs/failed-journal.txt" || echo "No failed-journal.txt captured"

section "High-signal lines from exact failed attempt"
{
    [[ -s "$BACKUP/logs/failed-console-slice.txt" ]] && cat "$BACKUP/logs/failed-console-slice.txt"
    [[ -s "$BACKUP/logs/failed-status.txt" ]] && cat "$BACKUP/logs/failed-status.txt"
    [[ -s "$BACKUP/logs/failed-journal.txt" ]] && cat "$BACKUP/logs/failed-journal.txt"
} | grep -Ein -C 10 'fatal|error|assert|exception|dbc|race|tuskarr|char(base|start)|skillrace|skillline|playercreate|segfault|signal|abort|crash|failed|invalid|duplicate|missing|cannot|could not|unsupported|ACE[0-9]+' || true

section "Recent worldserver core files"
CORE_DIR="$SERVER_ROOT/logs/cores"
NEWEST_CORE=""
if [[ -d "$CORE_DIR" ]]; then
    find "$CORE_DIR" -maxdepth 1 -type f -name 'core.worldserver.*' -mmin -180 \
        -printf '%T@\t%TY-%Tm-%Td %TH:%TM:%TS\t%s bytes\t%p\n' 2>/dev/null | sort -nr | head -10
    NEWEST_CORE="$(find "$CORE_DIR" -maxdepth 1 -type f -name 'core.worldserver.*' -mmin -180 -printf '%T@\t%p\n' 2>/dev/null | sort -nr | head -1 | cut -f2-)"
else
    echo "No core directory: $CORE_DIR"
fi

section "Fresh artifact identity"
FRESH_BIN=""
if [[ -n "${FRESH_OUT:-}" && -x "$FRESH_OUT/artifact/worldserver" ]]; then
    FRESH_BIN="$FRESH_OUT/artifact/worldserver"
    stat -c 'owner=%U:%G mode=%a size=%s mtime=%y' "$FRESH_BIN"
    sha256sum "$FRESH_BIN"
    if [[ -n "${FRESH_WORLD_SHA256:-}" ]]; then
        ACTUAL_SHA="$(sha256sum "$FRESH_BIN" | awk '{print $1}')"
        [[ "$ACTUAL_SHA" == "$FRESH_WORLD_SHA256" ]] && echo "PASS: fresh artifact hash matches install metadata" || echo "FAIL: fresh artifact hash differs from install metadata"
    fi
else
    echo "Verified fresh artifact not available from backup metadata"
fi

section "Newest core backtrace against verified fresh artifact"
if [[ -n "$NEWEST_CORE" && -n "$FRESH_BIN" && -x "$(command -v gdb || true)" ]]; then
    echo "Core:   $NEWEST_CORE"
    echo "Binary: $FRESH_BIN"
    file "$NEWEST_CORE" || true
    gdb -batch \
        -ex 'set pagination off' \
        -ex 'info threads' \
        -ex 'thread apply all bt 40' \
        "$FRESH_BIN" "$NEWEST_CORE" 2>&1 || true
else
    echo "No recent core, no verified fresh artifact, or gdb unavailable."
fi

section "Kernel crash evidence from last 180 minutes"
journalctl -k --since '-180 minutes' --no-pager 2>&1 | \
    grep -Ei -C 8 'worldserver|segfault|general protection|trap|oom|out of memory|killed process|signal|core dump' | tail -n 300 || true

section "Current service health after rollback"
systemctl status azeroth-worldserver.service --no-pager || true
ps -C worldserver -o pid,user,lstart,etime,%cpu,%mem,cmd || true

section "Diagnostic result"
echo "Diagnostic capture complete."
echo "Report: $REPORT"
echo "Do not retry the live installer until the exact startup failure above is identified and corrected."
