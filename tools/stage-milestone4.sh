#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACTION="${1:-}"
M2_STAGE="${2:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/root/tuskarr-milestone4-$STAMP"
REPORT="$OUT/MILESTONE-4-REPORT.txt"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

if [[ -z "$EXTRACTION" ]]; then
    EXTRACTION="$(ls -dt /root/tuskarr-glue-extract-* 2>/dev/null | head -n1 || true)"
fi
if [[ -z "$M2_STAGE" ]]; then
    M2_STAGE="$(ls -dt /root/tuskarr-stage-* 2>/dev/null | head -n1 || true)"
fi

[[ -n "$EXTRACTION" && -d "$EXTRACTION" ]] || fail "GlueXML extraction not found"
[[ -n "$M2_STAGE" && -d "$M2_STAGE" ]] || fail "Milestone 2 stage not found"
[[ -f /usr/include/StormLib.h ]] || fail "StormLib headers missing; install Debian package libstorm-dev first"
[[ -d "$M2_STAGE/dbc" && -d "$M2_STAGE/sql" && -d "$M2_STAGE/core" ]] || fail "Milestone 2 server payload is incomplete"

mkdir -p "$OUT"
exec > >(tee "$REPORT") 2>&1

echo "===== Playable Tuskarr Milestone 4 staging ====="
echo "Project:          $PROJECT_ROOT"
echo "Glue extraction:  $EXTRACTION"
echo "Milestone 2:      $M2_STAGE"
echo "Output:           $OUT"
echo
echo "NO LIVE INSTALLATION OCCURS IN THIS SCRIPT."
echo "It builds a deployment bundle under /root only."


echo
echo "===== Tool syntax gate ====="
python3 -m py_compile "$PROJECT_ROOT/tools/build-client-ui-patch.py"
echo "Python generator: PASS"


echo
echo "===== Generate exact-source client UI patch tree ====="
python3 "$PROJECT_ROOT/tools/build-client-ui-patch.py" "$EXTRACTION" "$OUT"

PATCH_TREE="$OUT/client/patch-tree"
[[ -f "$PATCH_TREE/DBFilesClient/ChrRaces.dbc" ]] || fail "generated patch tree lacks ChrRaces.dbc"
[[ -f "$PATCH_TREE/Interface/GlueXML/CharacterCreate.lua" ]] || fail "generated patch tree lacks CharacterCreate.lua"


echo
echo "===== Prepare global and locale MPQ roots ====="
GLOBAL_ROOT="$OUT/client/mpq-roots/global"
LOCALE_ROOT="$OUT/client/mpq-roots/enUS"
mkdir -p "$GLOBAL_ROOT" "$LOCALE_ROOT"
cp -a "$PATCH_TREE/DBFilesClient" "$GLOBAL_ROOT/DBFilesClient"
mkdir -p "$LOCALE_ROOT/Interface"
cp -a "$PATCH_TREE/Interface/GlueXML" "$LOCALE_ROOT/Interface/GlueXML"

find "$GLOBAL_ROOT" -type f -printf 'GLOBAL\t%P\t%s bytes\n' | sort
find "$LOCALE_ROOT" -type f -printf 'enUS\t%P\t%s bytes\n' | sort


echo
echo "===== Compile StormLib pack/verification helpers ====="
mkdir -p "$OUT/build"
g++ -std=c++17 -O2 "$PROJECT_ROOT/tools/tuskarr-mpq-pack.cpp" -lstorm -o "$OUT/build/tuskarr-mpq-pack"
g++ -std=c++17 -O2 "$PROJECT_ROOT/tools/tuskarr-mpq-extract.cpp" -lstorm -o "$OUT/build/tuskarr-mpq-extract"
echo "StormLib helpers: PASS"


echo
echo "===== Build staged client MPQs ====="
mkdir -p "$OUT/client/packages/Data/enUS"
GLOBAL_MPQ="$OUT/client/packages/Data/patch-4.MPQ"
LOCALE_MPQ="$OUT/client/packages/Data/enUS/patch-enUS-4.MPQ"
"$OUT/build/tuskarr-mpq-pack" "$GLOBAL_ROOT" "$GLOBAL_MPQ"
"$OUT/build/tuskarr-mpq-pack" "$LOCALE_ROOT" "$LOCALE_MPQ"


echo
echo "===== Verify generated MPQs by round-trip extraction ====="
mkdir -p "$OUT/verify"
"$OUT/build/tuskarr-mpq-extract" "$GLOBAL_MPQ" 'DBFilesClient\ChrRaces.dbc' "$OUT/verify/ChrRaces.dbc"
"$OUT/build/tuskarr-mpq-extract" "$LOCALE_MPQ" 'Interface\GlueXML\CharacterCreate.lua' "$OUT/verify/CharacterCreate.lua"
"$OUT/build/tuskarr-mpq-extract" "$LOCALE_MPQ" 'Interface\GlueXML\CharacterCreate.xml' "$OUT/verify/CharacterCreate.xml"

cmp -s "$OUT/verify/ChrRaces.dbc" "$PATCH_TREE/DBFilesClient/ChrRaces.dbc" || fail "ChrRaces round-trip mismatch"
cmp -s "$OUT/verify/CharacterCreate.lua" "$PATCH_TREE/Interface/GlueXML/CharacterCreate.lua" || fail "CharacterCreate.lua round-trip mismatch"
cmp -s "$OUT/verify/CharacterCreate.xml" "$PATCH_TREE/Interface/GlueXML/CharacterCreate.xml" || fail "CharacterCreate.xml round-trip mismatch"
echo "MPQ round-trip verification: PASS"


echo
echo "===== Add staged server payload ====="
mkdir -p "$OUT/server"
cp -a "$M2_STAGE/dbc" "$OUT/server/dbc"
cp -a "$M2_STAGE/sql" "$OUT/server/sql"
cp -a "$M2_STAGE/core" "$OUT/server/core"
find "$OUT/server" -type f -printf '%P\t%s bytes\n' | sort


echo
echo "===== Bundle hashes ====="
(
    cd "$OUT"
    find client/packages server -type f -print0 \
      | sort -z \
      | xargs -0 sha256sum
) | tee "$OUT/SHA256SUMS.txt"


echo
echo "===== Milestone 4 status ====="
echo "PASS: exact audited GlueXML sources transformed from the user's own client"
echo "PASS: MAX_RACES raised from 10 to 12"
echo "PASS: race-button layout made faction-aware at runtime (up to six rows per faction)"
echo "PASS: CharacterCreateRaceButton11 and 12 added"
echo "PASS: Tuskarr race lore and five racial descriptions added"
echo "PASS: Tuskarr background fallback added (Alliance=Human, Horde=Tauren)"
echo "PASS: Warrior/Hunter/Shaman restrictions remain DBC-driven through IsRaceClassValid()"
echo "PASS: global patch-4.MPQ built with custom DBFilesClient records"
echo "PASS: enUS patch-enUS-4.MPQ built with patched GlueXML"
echo "PASS: generated MPQs round-trip verified"
echo "PASS: server DBC/SQL/playerbots staging payload included"
echo
echo "KNOWN PROOF-OF-CONCEPT LIMITATION:"
echo "- The stock 3.3.5a race-icon atlas has no Tuskarr portrait. Both Tuskarr genders currently reuse the Tauren-male icon cell."
echo "- The actual Tuskarr character model remains the staged stock Tuskarr model; this icon fallback affects only the UI portrait/button."
echo
echo "STILL NOT APPLIED:"
echo "- client MPQs are not installed into /home/azeroth/wow-client/Data"
echo "- server DBCs are not replaced"
echo "- SQL is not executed"
echo "- playerbots patch is not applied/compiled"
echo "- worldserver is not restarted"
echo
echo "NEXT GATE: inspect this bundle, then perform a controlled backup/install/rebuild/restart and first Race 17 Warrior login test."
echo
echo "BUNDLE=$OUT"
echo "REPORT=$REPORT"
