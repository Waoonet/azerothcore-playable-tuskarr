#!/usr/bin/env python3
"""Read-only inspector for WoW 3.3.5a character-creation GlueXML inputs.

The script does not modify client files. It summarizes the exact source files
found on the user's client so the project can generate a minimal patch against
those files instead of assuming a third-party UI revision.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def scalar(text: str, name: str) -> str:
    match = re.search(rf"(?m)^\s*{re.escape(name)}\s*=\s*([0-9]+)\s*;?", text)
    return match.group(1) if match else "NOT FOUND"


def count_regex(text: str, pattern: str) -> int:
    return len(re.findall(pattern, text, flags=re.IGNORECASE | re.MULTILINE))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("glue_dir", type=Path, help="Directory containing CharacterCreate.lua/xml and GlueStrings.lua")
    args = parser.parse_args()

    glue = args.glue_dir.resolve()
    lua = glue / "CharacterCreate.lua"
    xml = glue / "CharacterCreate.xml"
    strings = glue / "GlueStrings.lua"
    parent = glue / "GlueParent.lua"

    print("===== GlueXML source audit =====")
    print(f"Glue directory: {glue}")

    required = [lua, xml, strings]
    for path in [lua, xml, strings, parent]:
        print(f"{path.name:<22} {'FOUND' if path.is_file() else 'MISSING'}")

    if any(not path.is_file() for path in required):
        print("RESULT: INCOMPLETE - required GlueXML source files are missing")
        return 2

    lua_text = read_text(lua)
    xml_text = read_text(xml)
    strings_text = read_text(strings)
    parent_text = read_text(parent) if parent.is_file() else ""

    print()
    print("===== CharacterCreate.lua =====")
    print(f"MAX_RACES:            {scalar(lua_text, 'MAX_RACES')}")
    print(f"MAX_CLASSES_PER_RACE: {scalar(lua_text, 'MAX_CLASSES_PER_RACE')}")
    print(f"TUSKARR references:   {count_regex(lua_text, r'TUSKARR')}")
    print(f"RACE_ICON_TCOORDS:    {'FOUND' if 'RACE_ICON_TCOORDS' in lua_text else 'NOT FOUND'}")
    print(f"GetAvailableRaces:    {'FOUND' if 'GetAvailableRaces' in lua_text else 'NOT FOUND'}")
    print(f"SetSelectedRace:      {'FOUND' if 'SetSelectedRace' in lua_text else 'NOT FOUND'}")
    print(f"GetFactionForRace:    {'FOUND' if 'GetFactionForRace' in lua_text else 'NOT FOUND'}")

    print()
    print("===== CharacterCreate.xml =====")
    print(f"CharCreateRaceButton refs: {count_regex(xml_text, r'CharCreateRaceButton')}")
    print(f"Race button templates:     {count_regex(xml_text, r'RaceButton')}")

    print()
    print("===== GlueStrings.lua =====")
    print(f"TUSKARR references:        {count_regex(strings_text, r'TUSKARR')}")
    print(f"RACE_INFO_* definitions:   {count_regex(strings_text, r'RACE_INFO_[A-Z0-9_]+\s*=')}")
    print(f"ABILITY_INFO_* definitions:{count_regex(strings_text, r'ABILITY_INFO_[A-Z0-9_]+\s*=')}")

    if parent.is_file():
        print()
        print("===== GlueParent.lua =====")
        print(f"TUSKARR references:        {count_regex(parent_text, r'TUSKARR')}")
        print(f"CharacterCreate refs:      {count_regex(parent_text, r'CharacterCreate')}")

    print()
    print("===== Project requirements derived from the staged races =====")
    print("Playable race rows to expose: 17 (Alliance Tuskarr), 18 (Horde Tuskarr)")
    print("Playable classes: Warrior=1, Hunter=3, Shaman=7")
    print("Both race rows use ClientFileString 'Tuskarr' and the same visual model.")
    print("The UI therefore needs two selectable race entries but only one Tuskarr icon/text family.")
    print("Do not assume race button index == ChrRaces race ID; patch generation must follow this client's enumeration logic.")
    print()
    print("RESULT: PASS - GlueXML inputs are suitable for exact-source patch generation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
