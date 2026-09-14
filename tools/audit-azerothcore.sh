#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
INSTALL_ROOT="${2:-$(cd "$(dirname "$ROOT")" 2>/dev/null && pwd)/server}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "$ROOT/src" ]]; then
  echo "ERROR: '$ROOT' does not look like an AzerothCore source checkout (missing src/)." >&2
  exit 2
fi

ROOT="$(cd "$ROOT" && pwd)"

section() {
  printf '\n===== %s =====\n' "$1"
}

show_git_state() {
  local dir="$1"
  local label="$2"
  [[ -e "$dir" ]] || return 0
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' "$label"
    printf '  path:   %s\n' "$dir"
    printf '  commit: %s\n' "$(git -C "$dir" rev-parse HEAD)"
    printf '  branch: %s\n' "$(git -C "$dir" branch --show-current 2>/dev/null || true)"
    local status
    status="$(git -C "$dir" status --short 2>/dev/null || true)"
    if [[ -n "$status" ]]; then
      printf '  status:\n%s\n' "$status"
    else
      printf '  status: clean\n'
    fi
  fi
}

show_context() {
  local file="$1"
  local pattern="$2"
  local before="${3:-8}"
  local after="${4:-20}"
  [[ -f "$file" ]] || return 0

  local line
  line="$(grep -nEm1 "$pattern" "$file" 2>/dev/null | cut -d: -f1 || true)"
  if [[ -n "$line" ]]; then
    local start=$(( line > before ? line - before : 1 ))
    local end=$(( line + after ))
    printf '\n--- %s : /%s/ (lines %d-%d) ---\n' "${file#$ROOT/}" "$pattern" "$start" "$end"
    nl -ba "$file" | sed -n "${start},${end}p"
  fi
}

printf 'Playable Tuskarr compatibility audit v2\n'
printf 'Source root:  %s\n' "$ROOT"
printf 'Install root: %s\n' "$INSTALL_ROOT"

section 'Core revision'
show_git_state "$ROOT" 'AzerothCore'

section 'Installed module revisions'
if [[ -d "$ROOT/modules" ]]; then
  found_module=0
  for module in "$ROOT"/modules/*; do
    [[ -d "$module" ]] || continue
    if git -C "$module" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      show_git_state "$module" "$(basename "$module")"
      found_module=1
    fi
  done
  if [[ "$found_module" -eq 0 ]]; then
    echo 'No independently versioned module Git repositories detected.'
  fi
fi

section 'Race enum and masks'
show_context "$ROOT/src/server/shared/SharedDefines.h" '^enum Races' 2 45
show_context "$ROOT/src/server/shared/SharedDefines.h" 'RACEMASK_ALL_PLAYABLE|RACEMASK_ALLIANCE|RACEMASK_HORDE' 8 30

section 'Race manager'
show_context "$ROOT/src/server/game/Entities/Player/RaceMgr.h" 'class RaceMgr' 4 55
show_context "$ROOT/src/server/game/Entities/Player/RaceMgr.cpp" 'RaceMgr::_maxRaces|LoadRaces' 8 110

section 'Team/faction derivation'
show_context "$ROOT/src/server/game/Entities/Player/Player.cpp" 'TeamId Player::TeamIdForRace' 8 45

section 'Character creation validation'
show_context "$ROOT/src/server/game/Handlers/CharacterHandler.cpp" 'GetPlayableRaceMask|createInfo->Race|CreateCharacter' 20 100

section 'Player creation data loading'
show_context "$ROOT/src/server/game/Globals/ObjectMgr.cpp" 'playercreateinfo' 12 100
show_context "$ROOT/src/server/game/Globals/ObjectMgr.cpp" 'player_race_stats' 12 80
show_context "$ROOT/src/server/game/Globals/ObjectMgr.cpp" 'playercreateinfo_skills' 12 80

section 'DBC structures relevant to playable races'
show_context "$ROOT/src/server/shared/DataStores/DBCStructure.h" 'struct ChrRacesEntry' 6 75
show_context "$ROOT/src/server/shared/DataStores/DBCfmt.h" 'ChrRacesEntryfmt' 5 15
show_context "$ROOT/src/server/game/DataStores/DBCStores.cpp" 'sChrRacesStore' 5 15

section 'Playerbots race handling'
if [[ -d "$ROOT/modules/mod-playerbots" ]]; then
  show_context "$ROOT/modules/mod-playerbots/src/Mgr/Item/RandomItemMgr.cpp" 'RACEMASK_ALL_PLAYABLE' 12 35
  show_context "$ROOT/modules/mod-playerbots/src/Bot/RandomPlayerbotMgr.cpp" 'GetMaxRaces' 12 35
  show_context "$ROOT/modules/mod-playerbots/src/Bot/Factory/RandomPlayerbotFactory.cpp" 'GetMaxRaces' 12 35
  show_context "$ROOT/modules/mod-playerbots/src/Mgr/Travel/TravelMgr.cpp" 'MAX_RACES|GetMaxRaces' 12 35
fi

section 'Broad race references requiring later regression testing'
grep -RInE --exclude-dir=.git \
  'RACE_TUSKARR|RACE_FOREST_TROLL|RACE_TAUNKA|MAX_RACES|MAX_PLAYABLE_RACES|RACEMASK_ALL_PLAYABLE|RACEMASK_ALLIANCE|RACEMASK_HORDE' \
  "$ROOT/src" "$ROOT/modules" 2>/dev/null | head -n 800 || true

section 'SQL/data references to numeric IDs 17 and 18'
if [[ -d "$ROOT/data/sql" ]]; then
  grep -RInE --exclude-dir=.git '(^|[^0-9])(17|18)([^0-9]|$)' "$ROOT/data/sql" 2>/dev/null | head -n 500 || true
fi
if [[ -d "$ROOT/modules" ]]; then
  grep -RInE --include='*.sql' '(^|[^0-9])(17|18)([^0-9]|$)' "$ROOT/modules" 2>/dev/null | head -n 500 || true
fi

section 'Expected player creation tables'
for name in playercreateinfo player_race_stats playercreateinfo_skills playercreateinfo_action playercreateinfo_item; do
  if grep -RIl --include='*.sql' "CREATE TABLE.*${name}\|INSERT INTO.*${name}\|\`${name}\`" "$ROOT/data/sql" "$ROOT/modules" 2>/dev/null | head -n1 | grep -q .; then
    echo "FOUND: $name"
  else
    echo "CHECK MANUALLY: $name"
  fi
done

section 'Installed server DBC inventory'
DBC_DIR=''
for candidate in \
  "$INSTALL_ROOT/data/dbc" \
  "$INSTALL_ROOT/data/dbc/enUS" \
  "$INSTALL_ROOT/data/dbc/enGB" \
  "$INSTALL_ROOT/dbc"; do
  if [[ -f "$candidate/ChrRaces.dbc" ]]; then
    DBC_DIR="$candidate"
    break
  fi
done

if [[ -n "$DBC_DIR" ]]; then
  printf 'DBC directory: %s\n' "$DBC_DIR"
  for dbc in ChrRaces.dbc CharBaseInfo.dbc CharStartOutfit.dbc SkillRaceClassInfo.dbc SkillLineAbility.dbc Spell.dbc CreatureDisplayInfo.dbc CreatureDisplayInfoExtra.dbc CreatureModelData.dbc; do
    if [[ -f "$DBC_DIR/$dbc" ]]; then
      printf '%-34s size=%-10s sha256=%s\n' \
        "$dbc" \
        "$(stat -c '%s' "$DBC_DIR/$dbc")" \
        "$(sha256sum "$DBC_DIR/$dbc" | awk '{print $1}')"
    else
      printf '%-34s MISSING\n' "$dbc"
    fi
  done

  section 'ChrRaces.dbc comparison rows'
  if command -v python3 >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/inspect-dbc.py" ]]; then
    python3 "$SCRIPT_DIR/inspect-dbc.py" "$DBC_DIR/ChrRaces.dbc" \
      --id 1 --id 2 --id 6 --id 11 --id 17 --id 18 || true

    section 'Existing CharBaseInfo rows for race IDs 17 and 18'
    if [[ -f "$DBC_DIR/CharBaseInfo.dbc" ]]; then
      python3 "$SCRIPT_DIR/inspect-dbc.py" "$DBC_DIR/CharBaseInfo.dbc" \
        --id 17 --id 18 || true
    fi
  else
    echo 'python3 or tools/inspect-dbc.py unavailable; skipping row inspection.'
  fi
else
  echo 'ChrRaces.dbc not found in the common install locations checked.'
fi

section 'Result'
echo 'Audit complete. This script is read-only. It does not modify source, databases, DBCs, or the running realm.'
