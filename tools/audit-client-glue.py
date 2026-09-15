#!/usr/bin/env python3
"""Read-only inspector for WoW 3.3.5a character-creation GlueXML inputs.

The script never modifies client files. It summarizes the exact extracted source
files and prints narrowly-scoped, line-numbered structural excerpts needed to
build a minimal custom-race patch against the user's own client revision.
"""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def scalar(text: str, name: str) -> str:
    match = re.search(rf"(?m)^\s*{re.escape(name)}\s*=\s*([0-9]+)\s*;?", text)
    return match.group(1) if match else "NOT FOUND"


def count_regex(text: str, pattern: str) -> int:
    return len(re.findall(pattern, text, flags=re.IGNORECASE | re.MULTILINE))


def print_context(title: str, path: Path, text: str, patterns: list[str], context: int = 3, max_hits: int = 40) -> None:
    """Print de-duplicated line ranges around structural regex hits."""
    lines = text.splitlines()
    hit_lines: set[int] = set()
    compiled = [re.compile(p, re.IGNORECASE) for p in patterns]

    for idx, line in enumerate(lines):
        if any(rx.search(line) for rx in compiled):
            hit_lines.add(idx)

    print()
    print(f"===== {title} =====")
    print(f"Source: {path}")
    print(f"Matches: {len(hit_lines)}")

    if not hit_lines:
        print("(none)")
        return

    # Merge nearby windows so the report stays readable.
    windows: list[tuple[int, int]] = []
    for idx in sorted(hit_lines)[:max_hits]:
        start = max(0, idx - context)
        end = min(len(lines) - 1, idx + context)
        if windows and start <= windows[-1][1] + 1:
            windows[-1] = (windows[-1][0], max(windows[-1][1], end))
        else:
            windows.append((start, end))

    for start, end in windows:
        print(f"--- lines {start + 1}-{end + 1} ---")
        for idx in range(start, end + 1):
            print(f"{idx + 1:5d}: {lines[idx]}")

    if len(hit_lines) > max_hits:
        print(f"... {len(hit_lines) - max_hits} additional matching lines omitted ...")


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
        if path.is_file():
            print(f"{path.name:<22} FOUND  size={path.stat().st_size} sha256={sha256(path)}")
        else:
            print(f"{path.name:<22} MISSING")

    if any(not path.is_file() for path in required):
        print("RESULT: INCOMPLETE - required GlueXML source files are missing")
        return 2

    lua_text = read_text(lua)
    xml_text = read_text(xml)
    strings_text = read_text(strings)
    parent_text = read_text(parent) if parent.is_file() else ""

    race_info_count = count_regex(strings_text, r"RACE_INFO_[A-Z0-9_]+\s*=")
    ability_info_count = count_regex(strings_text, r"ABILITY_INFO_[A-Z0-9_]+\s*=")

    print()
    print("===== CharacterCreate.lua summary =====")
    print(f"MAX_RACES:            {scalar(lua_text, 'MAX_RACES')}")
    print(f"MAX_CLASSES_PER_RACE: {scalar(lua_text, 'MAX_CLASSES_PER_RACE')}")
    print(f"TUSKARR references:   {count_regex(lua_text, r'TUSKARR')}")
    print(f"RACE_ICON_TCOORDS:    {'FOUND' if 'RACE_ICON_TCOORDS' in lua_text else 'NOT FOUND'}")
    print(f"GetAvailableRaces:    {'FOUND' if 'GetAvailableRaces' in lua_text else 'NOT FOUND'}")
    print(f"SetSelectedRace:      {'FOUND' if 'SetSelectedRace' in lua_text else 'NOT FOUND'}")
    print(f"GetFactionForRace:    {'FOUND' if 'GetFactionForRace' in lua_text else 'NOT FOUND'}")
    print(f"GetAvailableClasses:  {'FOUND' if 'GetAvailableClasses' in lua_text else 'NOT FOUND'}")
    print(f"SetSelectedClass:     {'FOUND' if 'SetSelectedClass' in lua_text else 'NOT FOUND'}")

    print()
    print("===== CharacterCreate.xml summary =====")
    print(f"CharCreateRaceButton refs: {count_regex(xml_text, r'CharCreateRaceButton')}")
    print(f"Race button refs:           {count_regex(xml_text, r'RaceButton')}")
    print(f"CharacterCreateRace refs:   {count_regex(xml_text, r'CharacterCreateRace')}")

    print()
    print("===== GlueStrings.lua summary =====")
    print(f"TUSKARR references:         {count_regex(strings_text, r'TUSKARR')}")
    print(f"RACE_INFO_* definitions:    {race_info_count}")
    print(f"ABILITY_INFO_* definitions: {ability_info_count}")

    if parent.is_file():
        print()
        print("===== GlueParent.lua summary =====")
        print(f"TUSKARR references:         {count_regex(parent_text, r'TUSKARR')}")
        print(f"CharacterCreate refs:       {count_regex(parent_text, r'CharacterCreate')}")

    # Structural excerpts: deliberately focused on race/class enumeration and UI layout.
    print_context(
        "CharacterCreate.lua race/class structure",
        lua,
        lua_text,
        [
            r"MAX_RACES",
            r"MAX_CLASSES_PER_RACE",
            r"RACE_ICON_TCOORDS",
            r"CLASS_ICON_TCOORDS",
            r"GetAvailableRaces",
            r"SetSelectedRace",
            r"GetFactionForRace",
            r"GetAvailableClasses",
            r"SetSelectedClass",
            r"CharCreateRaceButton",
            r"CharacterCreateRaceButton",
            r"race.*button",
            r"class.*button",
        ],
        context=4,
        max_hits=80,
    )

    print_context(
        "CharacterCreate.xml race/class button structure",
        xml,
        xml_text,
        [
            r"CharCreateRaceButton",
            r"CharacterCreateRaceButton",
            r"RaceButton",
            r"CharCreateClassButton",
            r"ClassButton",
            r"CharacterCreate",
        ],
        context=3,
        max_hits=80,
    )

    print_context(
        "GlueStrings.lua race definitions",
        strings,
        strings_text,
        [
            r"RACE_INFO_(HUMAN|ORC|DWARF|NIGHTELF|UNDEAD|TAUREN|GNOME|TROLL|BLOODELF|DRAENEI)",
            r"ABILITY_INFO_(HUMAN|ORC|DWARF|NIGHTELF|UNDEAD|TAUREN|GNOME|TROLL|BLOODELF|DRAENEI)",
        ],
        context=1,
        max_hits=60,
    )

    if parent.is_file():
        print_context(
            "GlueParent.lua character-create integration",
            parent,
            parent_text,
            [r"CharacterCreate", r"RACE", r"FACTION"],
            context=2,
            max_hits=40,
        )

    print()
    print("===== Project requirements =====")
    print("Race 17: Alliance Tuskarr")
    print("Race 18: Horde Tuskarr")
    print("Playable classes: Warrior=1, Hunter=3, Shaman=7")
    print("Both race rows use ClientFileString 'Tuskarr' and the same initial visual model.")
    print("The UI needs two selectable race entries but can reuse one Tuskarr icon/text family.")
    print("Race-button index must follow this client's GetAvailableRaces enumeration; do not assume index == race ID.")
    print()
    print("RESULT: PASS - exact GlueXML inputs captured for patch generation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
