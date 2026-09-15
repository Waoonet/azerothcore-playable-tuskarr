#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
cd "$ROOT"

required=(
  README.md
  LICENSE
  project/tuskarr.json
  tools/audit-azerothcore.sh
  tools/stage-milestone2.sh
  tools/stage-client-preflight.sh
  tools/extract-client-glue.sh
  tools/tuskarr-mpq-extract.cpp
  tools/audit-client-glue.py
  tools/analyze-extracted-glue.sh
  tools/validate-repo.sh
)

for path in "${required[@]}"; do
  [[ -f "$path" ]] || { echo "ERROR: missing required file: $path" >&2; exit 1; }
done

python3 -m json.tool project/tuskarr.json >/dev/null

# Syntax-check every project-authored shell/Python tool. This deliberately does
# not execute client/server mutation paths in CI.
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find tools -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)

while IFS= read -r -d '' script; do
  python3 -m py_compile "$script"
done < <(find tools -maxdepth 1 -type f -name '*.py' -print0 | sort -z)

# Do not allow original game binary/data archives or common extracted Blizzard assets
# to be committed. Project-authored source/patch definitions are fine.
forbidden_regex='\.(mpq|dbc|db2|m2|skin|blp|adt|wdt|wdl|wmo|wav|mp3|ogg)$'
if git ls-files | grep -Ei "$forbidden_regex" >/tmp/tuskarr-forbidden-assets.txt; then
  echo "ERROR: repository contains forbidden original/binary client asset types:" >&2
  cat /tmp/tuskarr-forbidden-assets.txt >&2
  exit 1
fi

# Large binary guardrail.
while IFS= read -r -d '' f; do
  size=$(wc -c <"$f")
  if (( size > 5242880 )); then
    echo "ERROR: tracked file exceeds 5 MiB guardrail: $f ($size bytes)" >&2
    exit 1
  fi
done < <(git ls-files -z)

echo "Repository validation passed."
