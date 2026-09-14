#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_ROOT="${1:-/home/azeroth/wow-client}"
M2_STAGE="${2:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/root/tuskarr-client-preflight-$STAMP"
REPORT="$OUT/CLIENT-PREFLIGHT-REPORT.txt"

if [[ -z "$M2_STAGE" ]]; then
  M2_STAGE="$(ls -dt /root/tuskarr-stage-* 2>/dev/null | head -n1 || true)"
fi

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "$CLIENT_ROOT" ]] || fail "client root not found: $CLIENT_ROOT"
[[ -n "$M2_STAGE" && -d "$M2_STAGE" ]] || fail "Milestone 2 stage not found; pass it as argument 2"
[[ -d "$M2_STAGE/dbc" ]] || fail "Milestone 2 DBC directory missing: $M2_STAGE/dbc"

mkdir -p "$OUT/patch-tree/DBFilesClient" "$OUT/discovery" "$OUT/inputs/Interface/GlueXML"
exec > >(tee "$REPORT") 2>&1

echo "===== Playable Tuskarr Milestone 3 client preflight ====="
echo "Project:          $PROJECT_ROOT"
echo "Client root:      $CLIENT_ROOT"
echo "Milestone 2:      $M2_STAGE"
echo "Output:           $OUT"
echo
echo "THIS SCRIPT IS READ-ONLY WITH RESPECT TO THE WOW CLIENT."
echo "It does not modify MPQs, install client files, modify the live server, or restart anything."

required_dbc=(ChrRaces.dbc CharBaseInfo.dbc CharStartOutfit.dbc SkillRaceClassInfo.dbc SkillLineAbility.dbc)

echo
echo "===== Stage already-validated custom DBCs into MPQ tree ====="
for dbc in "${required_dbc[@]}"; do
  [[ -f "$M2_STAGE/dbc/$dbc" ]] || fail "missing staged DBC: $M2_STAGE/dbc/$dbc"
  cp -a "$M2_STAGE/dbc/$dbc" "$OUT/patch-tree/DBFilesClient/$dbc"
  printf '%-30s %s\n' "$dbc" "$(sha256sum "$OUT/patch-tree/DBFilesClient/$dbc" | awk '{print $1}')"
done

echo
echo "===== Client root inventory ====="
printf 'Top-level entries:\n'
find "$CLIENT_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | tee "$OUT/discovery/top-level.txt" || true

printf '\nPossible WoW executables:\n'
find "$CLIENT_ROOT" -maxdepth 4 -type f \( -iname 'Wow.exe' -o -iname 'Wow-64.exe' -o -iname 'Wow.app' \) -print 2>/dev/null | sort | tee "$OUT/discovery/executables.txt" || true

printf '\nMPQ archives:\n'
find "$CLIENT_ROOT" -maxdepth 6 -type f -iname '*.mpq' -printf '%p\t%s bytes\n' 2>/dev/null | sort | tee "$OUT/discovery/mpqs.txt" || true

printf '\nLocale directories:\n'
find "$CLIENT_ROOT" -maxdepth 4 -type d \( -iname 'enUS' -o -iname 'enGB' -o -iname 'deDE' -o -iname 'frFR' -o -iname 'esES' -o -iname 'ruRU' \) -print 2>/dev/null | sort | tee "$OUT/discovery/locales.txt" || true

printf '\nExisting patch archives:\n'
find "$CLIENT_ROOT" -maxdepth 6 -type f \( -iname 'patch*.mpq' -o -iname 'patch-*.mpq' \) -printf '%p\t%s bytes\n' 2>/dev/null | sort | tee "$OUT/discovery/patches.txt" || true


echo
echo "===== Search for extracted character-creation UI assets ====="
ui_names=(CharacterCreate.lua CharacterCreate.xml GlueStrings.lua GlueParent.lua UI-CHARACTERCREATE-RACES.blp UI-CharacterCreate-Races.blp)
for name in "${ui_names[@]}"; do
  echo "--- $name ---"
  find "$CLIENT_ROOT" -maxdepth 12 -type f -iname "$name" -print 2>/dev/null | sort || true
done | tee "$OUT/discovery/ui-assets.txt"

# Prefer one directory containing all three mandatory text inputs.
GLUE_DIR=""
while IFS= read -r candidate; do
  dir="$(dirname "$candidate")"
  if [[ -f "$dir/CharacterCreate.xml" && -f "$dir/GlueStrings.lua" ]]; then
    GLUE_DIR="$dir"
    break
  fi
done < <(find "$CLIENT_ROOT" -maxdepth 12 -type f -name 'CharacterCreate.lua' -print 2>/dev/null | sort)

if [[ -n "$GLUE_DIR" ]]; then
  echo
echo "===== Exact GlueXML input set found ====="
  echo "Glue directory: $GLUE_DIR"
  for name in CharacterCreate.lua CharacterCreate.xml GlueStrings.lua GlueParent.lua; do
    if [[ -f "$GLUE_DIR/$name" ]]; then
      cp -a "$GLUE_DIR/$name" "$OUT/inputs/Interface/GlueXML/$name"
      printf '%-22s %s\n' "$name" "$(sha256sum "$GLUE_DIR/$name" | awk '{print $1}')"
    else
      printf '%-22s MISSING\n' "$name"
    fi
  done

  echo
  python3 "$PROJECT_ROOT/tools/audit-client-glue.py" "$GLUE_DIR" || true
else
  echo
echo "===== Exact GlueXML input set ====="
  echo "NOT FOUND as extracted files under $CLIENT_ROOT"
  echo "This does not mean the files are absent from the client; they may exist only inside MPQ archives."
fi


echo
echo "===== MPQ / client tooling discovery ====="
tools=(wine wine64 7z 7zz mpqextract mpqtool wowmpq MPQEditor MPQEditor.exe cmake make gcc g++ python3)
for tool in "${tools[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%-18s %s\n' "$tool" "$(command -v "$tool")"
  else
    printf '%-18s %s\n' "$tool" "not found"
  fi
done | tee "$OUT/discovery/tools.txt"


echo
echo "===== DBC source consistency check ====="
CLIENT_DBC_DIR=""
for candidate in "$CLIENT_ROOT/dbc" "$CLIENT_ROOT/DBFilesClient" "$CLIENT_ROOT/Data/dbc"; do
  if [[ -f "$candidate/ChrRaces.dbc" ]]; then
    CLIENT_DBC_DIR="$candidate"
    break
  fi
done

if [[ -n "$CLIENT_DBC_DIR" ]]; then
  echo "Client DBC directory: $CLIENT_DBC_DIR"
  for dbc in "${required_dbc[@]}"; do
    if [[ -f "$CLIENT_DBC_DIR/$dbc" ]]; then
      printf '%-30s %s\n' "$dbc" "$(sha256sum "$CLIENT_DBC_DIR/$dbc" | awk '{print $1}')"
    else
      printf '%-30s MISSING\n' "$dbc"
    fi
  done
else
  echo "No extracted DBC directory found under the expected client-root locations."
fi


echo
echo "===== Preflight result ====="
echo "PASS: Milestone 2 custom DBCs staged under patch-tree/DBFilesClient"
if [[ -n "$GLUE_DIR" ]]; then
  echo "PASS: exact extracted CharacterCreate.lua/xml + GlueStrings.lua source set found"
  if [[ -f "$GLUE_DIR/GlueParent.lua" ]]; then
    echo "PASS: GlueParent.lua found"
  else
    echo "WARN: GlueParent.lua not found beside the other GlueXML inputs"
  fi
  echo "NEXT: generate an exact-source GlueXML patch from these files"
else
  echo "BLOCKED: exact extracted GlueXML sources not found"
  echo "NEXT: use the discovered MPQ/tooling inventory to extract CharacterCreate.lua, CharacterCreate.xml, GlueStrings.lua and GlueParent.lua from this exact client"
fi

echo
echo "Patch tree prepared at: $OUT/patch-tree"
echo "Report:                 $REPORT"
echo "OUT=$OUT"
