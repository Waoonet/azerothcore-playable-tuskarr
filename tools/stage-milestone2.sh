#!/usr/bin/env bash
set -euo pipefail

CORE_ROOT="${1:-/home/azeroth/azerothcore}"
SERVER_ROOT="${2:-/home/azeroth/server}"
DBC_SOURCE="${3:-$SERVER_ROOT/bin/dbc}"
OUT_ROOT="${4:-/root/tuskarr-stage-$(date +%Y%m%d-%H%M%S)}"
EXPECTED_CORE="413bea61a85e20d9caef7d66fc601a661fdddd9d"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$OUT_ROOT"
REPORT="$OUT_ROOT/STAGING-REPORT.txt"
exec > >(tee "$REPORT") 2>&1

fail() { echo "ERROR: $*" >&2; exit 1; }
section() { printf '\n===== %s =====\n' "$1"; }

section 'Playable Tuskarr Milestone 2 staging'
echo "Project:    $PROJECT_ROOT"
echo "Core:       $CORE_ROOT"
echo "Server:     $SERVER_ROOT"
echo "DBC source: $DBC_SOURCE"
echo "Output:     $OUT_ROOT"
echo
printf '%s\n' 'THIS SCRIPT DOES NOT APPLY PATCHES, CHANGE DATABASES, REPLACE DBCS, OR RESTART THE SERVER.'

[[ -d "$CORE_ROOT/.git" ]] || fail "AzerothCore source is not a Git checkout: $CORE_ROOT"
[[ -d "$DBC_SOURCE" ]] || fail "DBC source directory does not exist: $DBC_SOURCE"
command -v python3 >/dev/null || fail 'python3 is required'
command -v git >/dev/null || fail 'git is required'
command -v sha256sum >/dev/null || fail 'sha256sum is required'

section 'Core compatibility gate'
CORE_COMMIT="$(git -C "$CORE_ROOT" rev-parse HEAD)"
echo "Expected: $EXPECTED_CORE"
echo "Found:    $CORE_COMMIT"
[[ "$CORE_COMMIT" == "$EXPECTED_CORE" ]] || fail 'Core revision is not the tested Milestone-2 revision.'

CORE_STATUS="$(git -C "$CORE_ROOT" status --short)"
if [[ -n "$CORE_STATUS" ]]; then
  echo "$CORE_STATUS"
  fail 'AzerothCore source is not clean. Staging intentionally refuses ambiguous source state.'
fi
echo 'Core working tree: clean'

section 'Input DBC compatibility gate'
REQUIRED=(ChrRaces.dbc CharBaseInfo.dbc CharStartOutfit.dbc SkillRaceClassInfo.dbc SkillLineAbility.dbc)
for f in "${REQUIRED[@]}"; do
  [[ -f "$DBC_SOURCE/$f" ]] || fail "missing $DBC_SOURCE/$f"
  printf '%-28s %s\n' "$f" "$(sha256sum "$DBC_SOURCE/$f" | awk '{print $1}')"
done

CHR_HASH="$(sha256sum "$DBC_SOURCE/ChrRaces.dbc" | awk '{print $1}')"
if [[ "$CHR_HASH" != '3d3e1443e8e97b1810275a45bc3f0588c83d876d04121401cc5adaa02f507bcd' ]]; then
  fail 'ChrRaces.dbc does not match the DBC set audited for this compatibility profile.'
fi

section 'Tool syntax validation'
python3 -m py_compile \
  "$PROJECT_ROOT/tools/wdbc.py" \
  "$PROJECT_ROOT/tools/build-tuskarr-dbc.py" \
  "$PROJECT_ROOT/tools/build-core-patch.py" \
  "$PROJECT_ROOT/tools/inspect-dbc.py"
echo 'Python tools compile successfully.'

section 'Build modified DBC staging set'
mkdir -p "$OUT_ROOT/dbc"
python3 "$PROJECT_ROOT/tools/build-tuskarr-dbc.py" "$DBC_SOURCE" "$OUT_ROOT/dbc" \
  > "$OUT_ROOT/dbc-build.json"
echo "DBC manifest: $OUT_ROOT/dbc/tuskarr-dbc-manifest.json"

section 'Inspect staged Tuskarr race rows'
python3 "$PROJECT_ROOT/tools/inspect-dbc.py" "$OUT_ROOT/dbc/ChrRaces.dbc" --id 17 --id 18

echo
printf 'CharBaseInfo staged pairs: '
python3 - "$OUT_ROOT/dbc/CharBaseInfo.dbc" <<'PY'
import struct, sys
p=sys.argv[1]
d=open(p,'rb').read()
magic,n,fields,size,strings=struct.unpack_from('<4s4I',d,0)
assert magic == b'WDBC' and fields == 2 and size == 2
rows=[tuple(d[20+i*2:22+i*2]) for i in range(n)]
print(' '.join(f'{r}/{c}' for r,c in rows if r in (17,18)))
PY

section 'Generate and validate playerbots source patch'
mkdir -p "$OUT_ROOT/core"
PATCH="$OUT_ROOT/core/playerbots-exclude-tuskarr-random-generation.patch"
python3 "$PROJECT_ROOT/tools/build-core-patch.py" "$CORE_ROOT" "$PATCH"
git -C "$CORE_ROOT" apply --check "$PATCH"
echo 'git apply --check: PASS'
echo 'The patch has NOT been applied.'

section 'Stage SQL preview'
mkdir -p "$OUT_ROOT/sql"
cp "$PROJECT_ROOT/sql/world/00_playable_tuskarr_poc.sql" "$OUT_ROOT/sql/"
echo "SQL preview: $OUT_ROOT/sql/00_playable_tuskarr_poc.sql"
echo 'The SQL has NOT been executed.'

section 'Output hashes'
find "$OUT_ROOT/dbc" -maxdepth 1 -type f -name '*.dbc' -print0 \
  | sort -z \
  | xargs -0 sha256sum
sha256sum "$PATCH" "$OUT_ROOT/sql/00_playable_tuskarr_poc.sql"

section 'Milestone 2 staging status'
echo 'PASS: exact tested AzerothCore revision'
echo 'PASS: clean source tree'
echo 'PASS: audited ChrRaces.dbc input hash'
echo 'PASS: staged race 17/18 DBC transformation completed'
echo 'PASS: six Warrior/Hunter/Shaman CharBaseInfo combinations generated'
echo 'PASS: staged starter outfits generated from Draenei/Tauren class references'
echo 'PASS: conservative SkillRaceClassInfo/SkillLineAbility masks generated'
echo 'PASS: playerbots random-generation exclusion patch applies cleanly'
echo 'PASS: proof-of-concept SQL staged only'
echo
echo 'NOT YET LIVE-READY:'
echo '- Character-creation GlueXML/UI patch is not built yet.'
echo '- Racials, Kalu\x27ak reputation, Kamagua low-level mobs/quests/trainers and faction exits are not built yet.'
echo '- Armor, animation, weapon attachment, death/ghost and mount behavior are untested.'
echo '- Skill-mask propagation still requires in-game regression testing for Warrior/Hunter/Shaman.'
echo
echo "REPORT=$REPORT"
echo "STAGE=$OUT_ROOT"
