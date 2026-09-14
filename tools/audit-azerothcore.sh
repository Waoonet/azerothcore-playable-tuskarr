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
if [[ -d "$INSTALL_ROOT" ]]; then
  INSTALL_ROOT="$(cd "$INSTALL_ROOT" && pwd)"
fi

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

add_dbc_candidate() {
  local dir="$1"
  [[ -n "$dir" ]] || return 0
  [[ -f "$dir/ChrRaces.dbc" ]] || return 0
  case "\n${DBC_CANDIDATES[*]:-}\n" in
    *"\n$dir\n"*) ;;
    *) DBC_CANDIDATES+=("$dir") ;;
  esac
}

resolve_datadir_candidate() {
  local value="$1"
  local base="$2"
  [[ -n "$value" ]] || return 0

  if [[ "$value" = /* ]]; then
    for suffix in "" dbc dbc/enUS dbc/enGB DBC DBC/enUS DBC/enGB; do
      [[ -n "$suffix" ]] && add_dbc_candidate "$value/$suffix" || add_dbc_candidate "$value"
    done
  else
    for prefix in "$base" "$INSTALL_ROOT" "$INSTALL_ROOT/bin"; do
      for suffix in "" dbc dbc/enUS dbc/enGB DBC DBC/enUS DBC/enGB; do
        if [[ -n "$suffix" ]]; then
          add_dbc_candidate "$prefix/$value/$suffix"
        else
          add_dbc_candidate "$prefix/$value"
        fi
      done
    done
  fi
}

printf 'Playable Tuskarr compatibility audit v3\n'
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

section 'Worldserver runtime / DataDir discovery'
DBC_CANDIDATES=()
CONF_CANDIDATES=(
  "$INSTALL_ROOT/etc/worldserver.conf"
  "$INSTALL_ROOT/etc/worldserver.conf.dist"
  "$ROOT/env/dist/etc/worldserver.conf.dist"
)

WORLD_PID="$(pgrep -u azeroth -x worldserver 2>/dev/null | head -n1 || pgrep -x worldserver 2>/dev/null | head -n1 || true)"
WORLD_CWD=''
if [[ -n "$WORLD_PID" && -e "/proc/$WORLD_PID/cwd" ]]; then
  WORLD_CWD="$(readlink -f "/proc/$WORLD_PID/cwd" 2>/dev/null || true)"
  printf 'Running worldserver PID: %s\n' "$WORLD_PID"
  printf 'worldserver cwd:        %s\n' "$WORLD_CWD"
  printf 'worldserver command:    %s\n' "$(tr '\0' ' ' < "/proc/$WORLD_PID/cmdline" 2>/dev/null || true)"
fi

for conf in "${CONF_CANDIDATES[@]}"; do
  [[ -f "$conf" ]] || continue
  printf '\nConfig candidate: %s\n' "$conf"
  DATA_DIR="$(sed -nE 's/^[[:space:]]*DataDir[[:space:]]*=[[:space:]]*"?([^"#;]+)"?.*/\1/p' "$conf" | head -n1 | sed -E 's/[[:space:]]+$//' || true)"
  if [[ -n "$DATA_DIR" ]]; then
    printf 'Configured DataDir: %s\n' "$DATA_DIR"
    resolve_datadir_candidate "$DATA_DIR" "$(dirname "$conf")"
    [[ -n "$WORLD_CWD" ]] && resolve_datadir_candidate "$DATA_DIR" "$WORLD_CWD"
  else
    echo 'Configured DataDir: not found in this file'
  fi
done

# Common locations and locations relative to the running process.
for candidate in \
  "$INSTALL_ROOT/data/dbc" \
  "$INSTALL_ROOT/data/dbc/enUS" \
  "$INSTALL_ROOT/data/dbc/enGB" \
  "$INSTALL_ROOT/dbc" \
  "$ROOT/data/dbc" \
  "$ROOT/data/dbc/enUS" \
  "$ROOT/data/dbc/enGB"; do
  add_dbc_candidate "$candidate"
done

if [[ -n "$WORLD_CWD" ]]; then
  for candidate in \
    "$WORLD_CWD/dbc" \
    "$WORLD_CWD/data/dbc" \
    "$WORLD_CWD/../data/dbc" \
    "$WORLD_CWD/../data/dbc/enUS" \
    "$WORLD_CWD/../data/dbc/enGB"; do
    add_dbc_candidate "$(readlink -m "$candidate")"
  done
fi

section 'Filesystem search for ChrRaces.dbc'
SEARCH_ROOT="$(dirname "$ROOT")"
printf 'Search root: %s\n' "$SEARCH_ROOT"
while IFS= read -r chr; do
  [[ -n "$chr" ]] || continue
  printf '%s\n' "$chr"
  add_dbc_candidate "$(dirname "$chr")"
done < <(find "$SEARCH_ROOT" -maxdepth 10 -type f -name 'ChrRaces.dbc' -print 2>/dev/null | sort)

section 'Installed server DBC inventory'
if (( ${#DBC_CANDIDATES[@]} == 0 )); then
  echo 'No ChrRaces.dbc was found under the configured/runtime/common locations or the Azeroth install tree.'
else
  BEST_DBC_DIR=''
  BEST_SCORE=-1
  REQUIRED_DBC=(ChrRaces.dbc CharBaseInfo.dbc CharStartOutfit.dbc SkillRaceClassInfo.dbc SkillLineAbility.dbc Spell.dbc CreatureDisplayInfo.dbc CreatureDisplayInfoExtra.dbc CreatureModelData.dbc)

  idx=0
  for dir in "${DBC_CANDIDATES[@]}"; do
    idx=$((idx + 1))
    score=0
    for dbc in "${REQUIRED_DBC[@]}"; do
      [[ -f "$dir/$dbc" ]] && score=$((score + 1))
    done
    printf '\nCandidate %d: %s (%d/%d required files)\n' "$idx" "$dir" "$score" "${#REQUIRED_DBC[@]}"
    for dbc in "${REQUIRED_DBC[@]}"; do
      if [[ -f "$dir/$dbc" ]]; then
        printf '%-34s size=%-10s sha256=%s\n' \
          "$dbc" \
          "$(stat -c '%s' "$dir/$dbc")" \
          "$(sha256sum "$dir/$dbc" | awk '{print $1}')"
      else
        printf '%-34s MISSING\n' "$dbc"
      fi
    done

    if (( score > BEST_SCORE )); then
      BEST_SCORE=$score
      BEST_DBC_DIR="$dir"
    fi
  done

  printf '\nSelected best candidate for inspection: %s (%d/%d files)\n' \
    "$BEST_DBC_DIR" "$BEST_SCORE" "${#REQUIRED_DBC[@]}"

  section 'ChrRaces.dbc comparison rows'
  if command -v python3 >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/inspect-dbc.py" ]]; then
    python3 "$SCRIPT_DIR/inspect-dbc.py" "$BEST_DBC_DIR/ChrRaces.dbc" \
      --id 1 --id 2 --id 6 --id 11 --id 17 --id 18 || true

    section 'Existing CharBaseInfo rows for race IDs 17 and 18'
    if [[ -f "$BEST_DBC_DIR/CharBaseInfo.dbc" ]]; then
      python3 "$SCRIPT_DIR/inspect-dbc.py" "$BEST_DBC_DIR/CharBaseInfo.dbc" \
        --id 17 --id 18 || true
    fi
  else
    echo 'python3 or tools/inspect-dbc.py unavailable; skipping row inspection.'
  fi
fi

section 'Result'
echo 'Audit complete. This script is read-only. It does not modify source, databases, DBCs, or the running realm.'
