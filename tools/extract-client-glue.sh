#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_ROOT="${1:-/home/azeroth/wow-client}"
PREFLIGHT="${2:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/root/tuskarr-glue-extract-$STAMP"
REPORT="$OUT/GLUE-EXTRACTION-REPORT.txt"
CACHE="/root/.cache/azerothcore-playable-tuskarr"
HELPER="$CACHE/tuskarr-mpq-extract"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "$CLIENT_ROOT/Data" ]] || fail "WoW client Data directory not found: $CLIENT_ROOT/Data"

if [[ -z "$PREFLIGHT" ]]; then
  PREFLIGHT="$(ls -dt /root/tuskarr-client-preflight-* 2>/dev/null | head -n1 || true)"
fi
[[ -n "$PREFLIGHT" && -d "$PREFLIGHT/patch-tree/DBFilesClient" ]] || \
  fail "Milestone 3 preflight directory not found; pass it as argument 2"

command -v g++ >/dev/null 2>&1 || fail "g++ is required"
[[ -f /usr/include/StormLib.h ]] || \
  fail "StormLib development headers are missing. Install Debian package libstorm-dev first."
ldconfig -p 2>/dev/null | grep -q 'libstorm\.so' || \
  fail "StormLib runtime library is missing. Install Debian package libstorm-dev first."

mkdir -p "$CACHE" "$OUT/candidates" "$OUT/effective/Interface/GlueXML" \
  "$OUT/patch-tree/DBFilesClient" "$OUT/patch-tree/Interface/GlueXML" "$OUT/discovery"

echo "Compiling read-only MPQ extraction helper..."
g++ -std=c++17 -O2 -Wall -Wextra \
  "$PROJECT_ROOT/tools/tuskarr-mpq-extract.cpp" \
  -lstorm -o "$HELPER"

cp -a "$PREFLIGHT/patch-tree/DBFilesClient/." "$OUT/patch-tree/DBFilesClient/"

exec > >(tee "$REPORT") 2>&1

echo "===== Playable Tuskarr Milestone 3B GlueXML extraction ====="
echo "Project:     $PROJECT_ROOT"
echo "Client root: $CLIENT_ROOT"
echo "Preflight:   $PREFLIGHT"
echo "Output:      $OUT"
echo
echo "READ-ONLY CLIENT OPERATION:"
echo "The script opens existing MPQs for reading and writes extracted copies only under $OUT."
echo "It does not alter the client MPQs or install the staged patch."

LOCALE=""
for candidate in enUS enGB deDE frFR esES ruRU; do
  if [[ -d "$CLIENT_ROOT/Data/$candidate" ]]; then
    LOCALE="$candidate"
    break
  fi
done
[[ -n "$LOCALE" ]] || fail "No supported locale directory found under $CLIENT_ROOT/Data"

echo
echo "Locale detected: $LOCALE"

declare -a ARCHIVES=()
add_archive() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  local existing
  for existing in "${ARCHIVES[@]:-}"; do
    [[ "$existing" == "$path" ]] && return 0
  done
  ARCHIVES+=("$path")
}

# Highest patch layers are checked first. Every hit is still retained and
# reported so we can verify the effective source before generating UI edits.
add_archive "$CLIENT_ROOT/Data/$LOCALE/patch-$LOCALE-3.MPQ"
add_archive "$CLIENT_ROOT/Data/$LOCALE/patch-$LOCALE-2.MPQ"
add_archive "$CLIENT_ROOT/Data/$LOCALE/patch-$LOCALE.MPQ"
add_archive "$CLIENT_ROOT/Data/patch-3.MPQ"
add_archive "$CLIENT_ROOT/Data/patch-2.MPQ"
add_archive "$CLIENT_ROOT/Data/patch.MPQ"
add_archive "$CLIENT_ROOT/Data/$LOCALE/lichking-locale-$LOCALE.MPQ"
add_archive "$CLIENT_ROOT/Data/$LOCALE/expansion-locale-$LOCALE.MPQ"
add_archive "$CLIENT_ROOT/Data/$LOCALE/locale-$LOCALE.MPQ"
add_archive "$CLIENT_ROOT/Data/$LOCALE/base-$LOCALE.MPQ"
add_archive "$CLIENT_ROOT/Data/lichking.MPQ"
add_archive "$CLIENT_ROOT/Data/expansion.MPQ"
add_archive "$CLIENT_ROOT/Data/common-2.MPQ"
add_archive "$CLIENT_ROOT/Data/common.MPQ"
add_archive "$CLIENT_ROOT/Data/$LOCALE/backup-$LOCALE.MPQ"

while IFS= read -r archive; do
  add_archive "$archive"
done < <(find "$CLIENT_ROOT/Data" -maxdepth 3 -type f -iname '*.mpq' -print 2>/dev/null | sort)

echo
echo "===== MPQ search order ====="
printf '%s\n' "${ARCHIVES[@]}" | tee "$OUT/discovery/archive-order.txt"

targets=(
  'Interface\GlueXML\CharacterCreate.lua'
  'Interface\GlueXML\CharacterCreate.xml'
  'Interface\GlueXML\GlueStrings.lua'
  'Interface\GlueXML\GlueParent.lua'
)

: > "$OUT/discovery/hits.tsv"
missing=0

for internal in "${targets[@]}"; do
  filename="${internal##*\\}"
  echo
  echo "===== $internal ====="
  winner=""
  winner_archive=""
  hit_count=0

  for archive in "${ARCHIVES[@]}"; do
    rel="${archive#"$CLIENT_ROOT"/}"
    tag="$(printf '%s' "$rel" | sed 's#[/\\ ]#_#g')"
    candidate="$OUT/candidates/$tag/$filename"
    mkdir -p "$(dirname "$candidate")"

    set +e
    "$HELPER" "$archive" "$internal" "$candidate"
    rc=$?
    set -e

    if (( rc == 0 )); then
      hit_count=$((hit_count + 1))
      hash="$(sha256sum "$candidate" | awk '{print $1}')"
      printf 'HIT\t%s\t%s\t%s\n' "$internal" "$archive" "$hash" | tee -a "$OUT/discovery/hits.tsv"
      if [[ -z "$winner" ]]; then
        winner="$candidate"
        winner_archive="$archive"
      fi
    elif (( rc != 4 )); then
      echo "WARN: extraction error rc=$rc from $archive"
    fi
  done

  if [[ -n "$winner" ]]; then
    cp -a "$winner" "$OUT/effective/Interface/GlueXML/$filename"
    cp -a "$winner" "$OUT/patch-tree/Interface/GlueXML/$filename"
    echo "Selected highest-priority readable copy: $winner_archive"
    echo "Hits found: $hit_count"
    echo "SHA256: $(sha256sum "$winner" | awk '{print $1}')"
  else
    echo "MISSING from all readable MPQs"
    if [[ "$filename" != "GlueParent.lua" ]]; then
      missing=$((missing + 1))
    fi
  fi
done

echo
echo "===== Extracted GlueXML audit ====="
if (( missing == 0 )); then
  python3 "$PROJECT_ROOT/tools/audit-client-glue.py" "$OUT/effective/Interface/GlueXML"
else
  echo "Required GlueXML extraction is incomplete."
fi

echo
echo "===== Patch-tree inventory ====="
find "$OUT/patch-tree" -type f -printf '%P\t%s bytes\n' | sort

echo
echo "===== Result ====="
if (( missing == 0 )); then
  echo "PASS: CharacterCreate.lua, CharacterCreate.xml and GlueStrings.lua extracted."
  if [[ -f "$OUT/effective/Interface/GlueXML/GlueParent.lua" ]]; then
    echo "PASS: GlueParent.lua extracted."
  else
    echo "WARN: GlueParent.lua was not found; exact need will be decided from the extracted source."
  fi
  echo "PASS: staged DBCs and exact-source GlueXML copies are combined in one patch tree."
  echo "NEXT: generate the two-Tuskarr character-creation changes against these exact sources."
else
  echo "BLOCKED: one or more mandatory GlueXML files could not be extracted."
  echo "Review $OUT/discovery/hits.tsv and extraction warnings before proceeding."
fi

echo
echo "REPORT=$REPORT"
echo "OUT=$OUT"
