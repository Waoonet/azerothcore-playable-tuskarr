#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACT_ROOT="${1:-}"

if [[ -z "$EXTRACT_ROOT" ]]; then
  EXTRACT_ROOT="$(ls -dt /root/tuskarr-glue-extract-* 2>/dev/null | head -n1 || true)"
fi

if [[ -z "$EXTRACT_ROOT" || ! -d "$EXTRACT_ROOT" ]]; then
  echo "ERROR: Glue extraction directory not found" >&2
  exit 1
fi

GLUE_DIR="$EXTRACT_ROOT/effective/Interface/GlueXML"
REPORT="$EXTRACT_ROOT/GLUE-STRUCTURE-REPORT.txt"

for f in CharacterCreate.lua CharacterCreate.xml GlueStrings.lua; do
  [[ -f "$GLUE_DIR/$f" ]] || { echo "ERROR: missing $GLUE_DIR/$f" >&2; exit 1; }
done

{
  echo "===== Playable Tuskarr exact GlueXML structure analysis ====="
  echo "Project:    $PROJECT_ROOT"
  echo "Extraction: $EXTRACT_ROOT"
  echo "Glue dir:   $GLUE_DIR"
  echo
  echo "This analysis is read-only. It does not alter the WoW client, MPQs, server, or database."
  echo
  python3 "$PROJECT_ROOT/tools/audit-client-glue.py" "$GLUE_DIR"
} | tee "$REPORT"

echo
echo "REPORT=$REPORT"
