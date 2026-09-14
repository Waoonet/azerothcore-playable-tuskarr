#!/usr/bin/env python3
"""Generate the Milestone-2 AzerothCore/playerbots patch without modifying source."""

from __future__ import annotations

import argparse
import difflib
from pathlib import Path

EXPECTED_CORE = "413bea61a85e20d9caef7d66fc601a661fdddd9d"
TARGET = Path("modules/mod-playerbots/src/Bot/Factory/RandomPlayerbotFactory.cpp")

OLD = """        // skip disabled with config races\n        if ((1 << (race - 1)) & sWorld->getIntConfig(CONFIG_CHARACTER_CREATING_DISABLED_RACEMASK))\n            continue;\n"""

NEW = """        // Playable Tuskarr races 17/18 remain player-only until playerbot behavior is validated.\n        if (race == 17 || race == 18)\n            continue;\n\n        // skip disabled with config races\n        if ((1 << (race - 1)) & sWorld->getIntConfig(CONFIG_CHARACTER_CREATING_DISABLED_RACEMASK))\n            continue;\n"""


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("core_root", type=Path)
    p.add_argument("output_patch", type=Path)
    args = p.parse_args()

    root = args.core_root.resolve()
    path = root / TARGET
    if not path.is_file():
        raise SystemExit(f"ERROR: missing {path}")

    original = path.read_text(encoding="utf-8")
    if NEW in original:
        raise SystemExit("ERROR: playerbots Tuskarr exclusion already appears to be applied")
    if original.count(OLD) != 1:
        raise SystemExit(f"ERROR: expected playerbots source block exactly once; found {original.count(OLD)}")

    modified = original.replace(OLD, NEW, 1)
    diff = "".join(
        difflib.unified_diff(
            original.splitlines(keepends=True),
            modified.splitlines(keepends=True),
            fromfile=f"a/{TARGET.as_posix()}",
            tofile=f"b/{TARGET.as_posix()}",
        )
    )
    args.output_patch.parent.mkdir(parents=True, exist_ok=True)
    args.output_patch.write_text(diff, encoding="utf-8")
    print(f"Generated: {args.output_patch}")
    print(f"Target:    {TARGET}")
    print("Purpose:   prevent random playerbot creation for custom races 17 and 18 during initial validation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
