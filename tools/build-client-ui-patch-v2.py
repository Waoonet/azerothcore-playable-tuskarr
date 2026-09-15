#!/usr/bin/env python3
"""Milestone 4 client UI generator hotfix.

This wrapper loads the exact-source generator and replaces only the GlueStrings
patch routine. The original generator used the generic ACCEPT string as an
anchor, but the audited enUS GlueStrings.lua contains that string three times.
This version anchors on the unique ABILITY_INFO_TROLL5 -> ACCEPT boundary in
the racial ability section.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path


BASE_PATH = Path(__file__).with_name("build-client-ui-patch.py")
spec = importlib.util.spec_from_file_location("tuskarr_build_client_ui_patch_base", BASE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit(f"ERROR: could not load base generator: {BASE_PATH}")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


def patch_glue_strings(path: Path) -> None:
    text = base.read(path)

    ability_marker = (
        'ABILITY_INFO_TROLL5 = "- Reduced duration of movement reducing effects.";\n'
        'ACCEPT = "Accept";'
    )
    abilities = (
        'ABILITY_INFO_TROLL5 = "- Reduced duration of movement reducing effects.";\n'
        'TUSKARR_DISABLED = "Tuskarr are currently unavailable.";\n'
        'ABILITY_INFO_TUSKARR1 = "- Thick Blubber: Stamina increased by 1%.";\n'
        'ABILITY_INFO_TUSKARR2 = "- Arctic Blood: Reduced chance to be hit by Frost spells.";\n'
        'ABILITY_INFO_TUSKARR3 = "- Born of the Sea: Swim speed and underwater breath duration increased.";\n'
        'ABILITY_INFO_TUSKARR4 = "- Master Angler: Fishing skill increased by 15.";\n'
        'ABILITY_INFO_TUSKARR5 = "- Throw Net: Briefly roots a nearby target; breaks on damage.";\n'
        'ACCEPT = "Accept";'
    )
    text = base.replace_once(text, ability_marker, abilities, "Tuskarr ability strings")

    race_marker = 'RACIAL_ABILITIES = "Racial Abilities";'
    lore = (
        'RACE_INFO_TUSKARR = "The tuskarr of the Kalu\\\'ak have endured Northrend\\\'s frozen coasts through patience, kinship, fishing, and the wisdom of their ancestors. As war spreads across Azeroth, some young tuskarr have chosen to travel beyond their traditional villages, carrying the customs of Kamagua into a wider world.";\n'
        'RACE_INFO_TUSKARR_FEMALE = RACE_INFO_TUSKARR;\n'
        + race_marker
    )
    text = base.replace_once(text, race_marker, lore, "Tuskarr race lore")
    base.write(path, text)


base.patch_glue_strings = patch_glue_strings

if __name__ == "__main__":
    raise SystemExit(base.main())
