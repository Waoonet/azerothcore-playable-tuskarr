#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"

if [[ ! -d "$ROOT/src" ]]; then
  echo "ERROR: '$ROOT' does not look like an AzerothCore source checkout (missing src/)." >&2
  exit 2
fi

printf 'Playable Tuskarr compatibility audit\n'
printf 'Source root: %s\n\n' "$(cd "$ROOT" && pwd)"

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'Git commit: %s\n\n' "$(git -C "$ROOT" rev-parse HEAD)"
fi

echo '== Race definitions / identifiers =='
grep -RInE --exclude-dir=.git \
  'RACE_TUSKARR|RACE_FOREST_TROLL|RACE_TAUNKA|MAX_RACES|MAX_PLAYABLE_RACES|RACEMASK_ALL_PLAYABLE|RACEMASK_ALLIANCE|RACEMASK_HORDE' \
  "$ROOT/src" "$ROOT/modules" 2>/dev/null || true

echo
echo '== Team/faction derivation =='
grep -RInE --exclude-dir=.git \
  'TeamIdForRace|Player::TeamForRace|GetTeamId\(|getRaceMask\(|GetRace\(' \
  "$ROOT/src/server" "$ROOT/modules" 2>/dev/null | head -n 500 || true

echo
echo '== Race-indexed arrays / bounds checks =='
grep -RInE --exclude-dir=.git \
  'race[[:space:]]*[<>]=?|GetRace\(\)[[:space:]]*[<>]=?|MAX_RACES|RACE_NONE' \
  "$ROOT/src/server" "$ROOT/modules" 2>/dev/null | head -n 500 || true

echo
echo '== SQL/data references to race IDs 17 and 18 =='
if [[ -d "$ROOT/data/sql" ]]; then
  grep -RInE --exclude-dir=.git '(^|[^0-9])(17|18)([^0-9]|$)' "$ROOT/data/sql" 2>/dev/null | head -n 500 || true
fi
if [[ -d "$ROOT/modules" ]]; then
  grep -RInE --include='*.sql' '(^|[^0-9])(17|18)([^0-9]|$)' "$ROOT/modules" 2>/dev/null | head -n 500 || true
fi

echo
echo '== Expected player creation tables =='
for name in playercreateinfo player_race_stats playercreateinfo_skills playercreateinfo_action playercreateinfo_item; do
  if grep -RIl --include='*.sql' "CREATE TABLE.*${name}\|INSERT INTO.*${name}\|\`${name}\`" "$ROOT/data/sql" "$ROOT/modules" 2>/dev/null | head -n1 | grep -q .; then
    echo "FOUND: $name"
  else
    echo "CHECK MANUALLY: $name"
  fi
done

echo
echo 'Audit complete. This script reports candidates; it does not prove compatibility or modify anything.'
