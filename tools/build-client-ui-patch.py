#!/usr/bin/env python3
"""Build an exact-source playable-Tuskarr client patch tree.

This transforms only copies extracted from the user's own 3.3.5a client. It
never writes to the installed client. The current compatibility profile is
intentionally pinned to the exact GlueXML hashes audited on Armapade.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path

EXPECTED = {
    "CharacterCreate.lua": "f041474fa333e063bc8b30919c9a85ddc663e86e799f59505be2d911b90cff73",
    "CharacterCreate.xml": "5492a4dccfc414fe1a7e8bb3f3b994d2382e65e182759a082c6d5c212cb13a1d",
    "GlueStrings.lua": "cb23e488305fe2f3573283b2931ecdbb5fefd08b3b8e30b86d5b646c2cd05532",
    "GlueParent.lua": "503d2363655a4b3145332a4024ee24240a0ab04b87724b6a6b0ec97fd75d8d31",
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def fail(msg: str) -> None:
    raise SystemExit(f"ERROR: {msg}")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    n = text.count(old)
    if n != 1:
        fail(f"{label}: expected exactly one match, found {n}")
    return text.replace(old, new, 1)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="strict")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="\n")


def patch_character_create_lua(path: Path) -> None:
    text = read(path)
    text = replace_once(text, "MAX_RACES = 10;", "MAX_RACES = 12;", "MAX_RACES")

    marker = "\t[\"DRAENEI_FEMALE\"]\t= {0.5, 0.625, 0.5, 0.75}, \n};\nCLASS_ICON_TCOORDS = {"
    replacement = (
        "\t[\"DRAENEI_FEMALE\"]\t= {0.5, 0.625, 0.5, 0.75}, \n\n"
        "\t-- Playable Tuskarr proof-of-concept. The stock 3.3.5a race atlas has\n"
        "\t-- no Tuskarr portrait cell, so both internal genders deliberately reuse\n"
        "\t-- the same Tauren-male atlas cell until an original Tuskarr icon is added.\n"
        "\t[\"TUSKARR_MALE\"]\t= {0, 0.125, 0.25, 0.5},\n"
        "\t[\"TUSKARR_FEMALE\"]\t= {0, 0.125, 0.25, 0.5},\n"
        "};\nCLASS_ICON_TCOORDS = {"
    )
    text = replace_once(text, marker, replacement, "Tuskarr race icon coordinates")

    start = text.find("function CharacterCreateEnumerateRaces(...)")
    end = text.find("function CharacterCreateEnumerateClasses(...)", start)
    if start < 0 or end < 0:
        fail("could not isolate CharacterCreateEnumerateRaces")
    block = text[start:end]

    block = replace_once(
        block,
        "\tlocal selectedSex = GetSelectedSex();\n",
        "\tlocal selectedSex = GetSelectedSex();\n"
        "\tlocal allianceRaceRow = 0;\n"
        "\tlocal hordeRaceRow = 0;\n",
        "race layout counters",
    )

    layout = (
        "\t\t-- Position by the faction of the UI enumeration index rather than by\n"
        "\t\t-- ChrRaces ID. This remains correct even when GetAvailableRaces()\n"
        "\t\t-- reorders the custom Alliance/Horde entries. Six rows fit before the\n"
        "\t\t-- stock gender controls by using 48px vertical spacing.\n"
        "\t\tlocal _, raceFaction = GetFactionForRace(index);\n"
        "\t\tbutton:ClearAllPoints();\n"
        "\t\tif ( raceFaction == \"Alliance\" ) then\n"
        "\t\t\tallianceRaceRow = allianceRaceRow + 1;\n"
        "\t\t\tbutton:SetPoint(\"TOP\", CharacterCreateConfigurationFrame, \"TOP\", -50, -61 - ((allianceRaceRow - 1) * 48));\n"
        "\t\telseif ( raceFaction == \"Horde\" ) then\n"
        "\t\t\thordeRaceRow = hordeRaceRow + 1;\n"
        "\t\t\tbutton:SetPoint(\"TOP\", CharacterCreateConfigurationFrame, \"TOP\", 50, -61 - ((hordeRaceRow - 1) * 48));\n"
        "\t\telse\n"
        "\t\t\tbutton:SetPoint(\"TOP\", CharacterCreateConfigurationFrame, \"TOP\", 0, -61 - ((index - 1) * 48));\n"
        "\t\tend\n"
    )
    block = replace_once(block, "\t\tbutton:Show();\n", "\t\tbutton:Show();\n" + layout, "dynamic race layout")
    text = text[:start] + block + text[end:]

    write(path, text)


def patch_character_create_xml(path: Path) -> None:
    text = read(path)
    marker = '\t\t\t\t\t\t\t<CheckButton name="CharacterCreateGenderButtonMale" inherits="CharacterCreateGenderButtonTemplate">'
    addition = (
        '\t\t\t\t\t\t\t<CheckButton name="CharacterCreateRaceButton11" inherits="CharacterCreateRaceButtonTemplate" id="11"/>\n'
        '\t\t\t\t\t\t\t<CheckButton name="CharacterCreateRaceButton12" inherits="CharacterCreateRaceButtonTemplate" id="12"/>\n'
        + marker
    )
    text = replace_once(text, marker, addition, "race buttons 11/12")
    write(path, text)
    try:
        ET.parse(path)
    except ET.ParseError as exc:
        fail(f"patched CharacterCreate.xml is not well-formed XML: {exc}")


def patch_glue_strings(path: Path) -> None:
    text = read(path)
    ability_marker = 'ACCEPT = "Accept";'
    abilities = (
        'TUSKARR_DISABLED = "Tuskarr are currently unavailable.";\n'
        'ABILITY_INFO_TUSKARR1 = "- Thick Blubber: Stamina increased by 1%.";\n'
        'ABILITY_INFO_TUSKARR2 = "- Arctic Blood: Reduced chance to be hit by Frost spells.";\n'
        'ABILITY_INFO_TUSKARR3 = "- Born of the Sea: Swim speed and underwater breath duration increased.";\n'
        'ABILITY_INFO_TUSKARR4 = "- Master Angler: Fishing skill increased by 15.";\n'
        'ABILITY_INFO_TUSKARR5 = "- Throw Net: Briefly roots a nearby target; breaks on damage.";\n'
        + ability_marker
    )
    text = replace_once(text, ability_marker, abilities, "Tuskarr ability strings")

    race_marker = 'RACIAL_ABILITIES = "Racial Abilities";'
    lore = (
        'RACE_INFO_TUSKARR = "The tuskarr of the Kalu\\\'ak have endured Northrend\\\'s frozen coasts through patience, kinship, fishing, and the wisdom of their ancestors. As war spreads across Azeroth, some young tuskarr have chosen to travel beyond their traditional villages, carrying the customs of Kamagua into a wider world.";\n'
        'RACE_INFO_TUSKARR_FEMALE = RACE_INFO_TUSKARR;\n'
        + race_marker
    )
    text = replace_once(text, race_marker, lore, "Tuskarr race lore")
    write(path, text)


def patch_glue_parent(path: Path) -> None:
    text = read(path)
    needle = "function SetBackgroundModel(model, name)\n    local nameupper = strupper(name);"
    if needle not in text:
        # The extracted file uses tabs in some distributions; accept the audited form.
        needle = "function SetBackgroundModel(model, name)\n\tlocal nameupper = strupper(name);"
    if needle not in text:
        fail("could not find SetBackgroundModel header")

    injection = needle + (
        "\n\t-- Tuskarr have no stock Glue background model in 3.3.5a. Reuse an\n"
        "\t-- existing faction-appropriate background while keeping the character\n"
        "\t-- model itself Tuskarr. Character select falls back to Tauren.\n"
        "\tif ( nameupper == \"TUSKARR\" ) then\n"
        "\t\tif ( model == CharacterCreate ) then\n"
        "\t\t\tlocal _, tuskarrFaction = GetFactionForRace(GetSelectedRace());\n"
        "\t\t\tif ( tuskarrFaction == \"Alliance\" ) then\n"
        "\t\t\t\tname = \"Human\";\n"
        "\t\t\telse\n"
        "\t\t\t\tname = \"Tauren\";\n"
        "\t\t\tend\n"
        "\t\telse\n"
        "\t\t\tname = \"Tauren\";\n"
        "\t\tend\n"
        "\t\tnameupper = strupper(name);\n"
        "\tend"
    )
    text = replace_once(text, needle, injection, "Tuskarr background fallback")
    write(path, text)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("extraction", type=Path, help="/root/tuskarr-glue-extract-* directory")
    ap.add_argument("output", type=Path, help="Milestone 4 output directory")
    args = ap.parse_args()

    extraction = args.extraction.resolve()
    output = args.output.resolve()
    glue = extraction / "effective" / "Interface" / "GlueXML"
    source_tree = extraction / "patch-tree"

    if not glue.is_dir() or not source_tree.is_dir():
        fail("extraction directory is missing effective GlueXML or patch-tree")

    for name, expected in EXPECTED.items():
        p = glue / name
        if not p.is_file():
            fail(f"missing exact GlueXML input: {p}")
        actual = sha256(p)
        if actual != expected:
            fail(f"{name} hash mismatch: expected {expected}, found {actual}")

    patch_tree = output / "client" / "patch-tree"
    if patch_tree.exists():
        shutil.rmtree(patch_tree)
    patch_tree.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source_tree, patch_tree)

    out_glue = patch_tree / "Interface" / "GlueXML"
    patch_character_create_lua(out_glue / "CharacterCreate.lua")
    patch_character_create_xml(out_glue / "CharacterCreate.xml")
    patch_glue_strings(out_glue / "GlueStrings.lua")
    patch_glue_parent(out_glue / "GlueParent.lua")

    lua = read(out_glue / "CharacterCreate.lua")
    xml = read(out_glue / "CharacterCreate.xml")
    strings = read(out_glue / "GlueStrings.lua")
    parent = read(out_glue / "GlueParent.lua")

    checks = {
        "MAX_RACES_12": "MAX_RACES = 12;" in lua,
        "TUSKARR_MALE_ICON": '["TUSKARR_MALE"]' in lua,
        "TUSKARR_FEMALE_ICON": '["TUSKARR_FEMALE"]' in lua,
        "DYNAMIC_FACTION_LAYOUT": "GetFactionForRace(index)" in lua,
        "RACE_BUTTON_11": 'CharacterCreateRaceButton11' in xml,
        "RACE_BUTTON_12": 'CharacterCreateRaceButton12' in xml,
        "TUSKARR_RACE_INFO": "RACE_INFO_TUSKARR" in strings,
        "TUSKARR_ABILITY_5": "ABILITY_INFO_TUSKARR5" in strings,
        "TUSKARR_BACKGROUND_FALLBACK": 'nameupper == "TUSKARR"' in parent,
    }
    if not all(checks.values()):
        fail("one or more generated UI validation checks failed")

    manifest = {
        "source_extraction": str(extraction),
        "source_hashes": EXPECTED,
        "design": {
            "max_races": 12,
            "layout": "dynamic two-column faction layout, six rows per faction",
            "race_icon": "temporary Tauren-male atlas cell for both Tuskarr genders",
            "alliance_background": "Human",
            "horde_background": "Tauren",
            "classes": [1, 3, 7],
        },
        "checks": checks,
        "outputs": {},
    }
    for p in sorted(patch_tree.rglob("*")):
        if p.is_file():
            manifest["outputs"][str(p.relative_to(patch_tree))] = sha256(p)

    (output / "client" / "tuskarr-client-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"PASS: generated exact-source client patch tree: {patch_tree}")
    print(f"Manifest: {output / 'client' / 'tuskarr-client-manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
