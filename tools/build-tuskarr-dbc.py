#!/usr/bin/env python3
"""Build staged playable-Tuskarr DBCs from user-supplied AzerothCore 3.3.5a DBCs.

This tool does not contain or download Blizzard data. It transforms local files
and writes the result to a separate output directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
from pathlib import Path

from wdbc import WDBC

ALLIANCE_TUSKARR = 17
HORDE_TUSKARR = 18
RACE_TAUREN = 6
RACE_DRAENEI = 11
CLASS_WARRIOR = 1
CLASS_HUNTER = 3
CLASS_SHAMAN = 7
TARGET_CLASSES = (CLASS_WARRIOR, CLASS_HUNTER, CLASS_SHAMAN)
TARGET_GENDERS = (0, 1)
RACE_BIT = lambda race: 1 << (race - 1)
SKILL_LANG_COMMON = 98
SKILL_LANG_ORCISH = 109

FILES = (
    "ChrRaces.dbc",
    "CharBaseInfo.dbc",
    "CharStartOutfit.dbc",
    "SkillRaceClassInfo.dbc",
    "SkillLineAbility.dbc",
)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def find_u32_record(dbc: WDBC, field: int, value: int) -> tuple[int, bytearray]:
    for index, record in enumerate(dbc.records):
        if dbc.u32(record, field) == value:
            return index, record
    raise ValueError(f"record with field {field} == {value} not found")


def build_chr_races(src: Path, dst: Path) -> dict:
    dbc = WDBC.load(src)
    if dbc.fields != 69 or dbc.record_size != 276:
        raise ValueError(f"unexpected ChrRaces layout: fields={dbc.fields}, record_size={dbc.record_size}")

    idx17, row17 = find_u32_record(dbc, 0, ALLIANCE_TUSKARR)
    idx18, _row18 = find_u32_record(dbc, 0, HORDE_TUSKARR)
    original_male = dbc.u32(row17, 4)
    if original_male == 0:
        raise ValueError("race 17 has no male Tuskarr model; refusing to guess")

    # Use the stock race-17 Tuskarr record as the canonical visual/string basis.
    ally = bytearray(row17)
    dbc.set_u32(ally, 0, ALLIANCE_TUSKARR)
    dbc.set_u32(ally, 1, 14)          # playable-style flags; Tauren/Draenei reference value
    dbc.set_u32(ally, 2, 1)           # Human/Alliance faction template reference
    dbc.set_u32(ally, 4, original_male)
    dbc.set_u32(ally, 5, original_male)  # same visual model for both genders by project design
    dbc.set_u32(ally, 7, 7)           # AzerothCore: Alliance TeamID
    dbc.set_u32(ally, 13, 0)          # AzerothCore: Alliance race group
    dbc.set_u32(ally, 68, 0)

    horde = bytearray(row17)
    dbc.set_u32(horde, 0, HORDE_TUSKARR)
    dbc.set_u32(horde, 1, 14)
    dbc.set_u32(horde, 2, 6)          # Tauren/Horde faction template reference
    dbc.set_u32(horde, 4, original_male)
    dbc.set_u32(horde, 5, original_male)
    dbc.set_u32(horde, 7, 1)          # AzerothCore: Horde TeamID
    dbc.set_u32(horde, 13, 1)         # AzerothCore: Horde race group
    dbc.set_u32(horde, 68, 0)

    dbc.records[idx17] = ally
    dbc.records[idx18] = horde
    dbc.save(dst)
    return {
        "stock_tuskarr_male_model": original_male,
        "alliance": {"race": 17, "flags": 14, "faction_id": 1, "team_id": 7, "alliance_field": 0},
        "horde": {"race": 18, "flags": 14, "faction_id": 6, "team_id": 1, "alliance_field": 1},
    }


def build_char_base_info(src: Path, dst: Path) -> dict:
    dbc = WDBC.load(src)
    if dbc.fields != 2 or dbc.record_size != 2:
        raise ValueError(f"unexpected CharBaseInfo layout: fields={dbc.fields}, record_size={dbc.record_size}")

    targets = {(race, cls) for race in (17, 18) for cls in TARGET_CLASSES}
    kept: list[bytearray] = []
    removed = 0
    for record in dbc.records:
        pair = (record[0], record[1])
        if pair in targets:
            removed += 1
            continue
        kept.append(record)
    for race, cls in sorted(targets):
        kept.append(bytearray((race, cls)))
    dbc.records = kept
    dbc.save(dst)
    return {"added_pairs": sorted([list(x) for x in targets]), "replaced_existing": removed}


def outfit_key(record: bytearray) -> tuple[int, int, int]:
    # WotLK CharStartOutfit: uint32 ID, then byte Race, Class, Gender, OutfitID.
    if len(record) < 8:
        raise ValueError("CharStartOutfit record is unexpectedly short")
    return record[4], record[5], record[6]


def outfit_id(record: bytearray) -> int:
    return struct.unpack_from("<I", record, 0)[0]


def set_outfit_id(record: bytearray, value: int) -> None:
    struct.pack_into("<I", record, 0, value)


def build_char_start_outfit(src: Path, dst: Path) -> dict:
    dbc = WDBC.load(src)
    if dbc.record_size < 8:
        raise ValueError(f"unexpected CharStartOutfit record_size={dbc.record_size}")

    # Remove stale rows for 17/18, then clone known playable reference outfits.
    dbc.records = [r for r in dbc.records if outfit_key(r)[0] not in (17, 18)]
    max_id = max(outfit_id(r) for r in dbc.records)
    index = {outfit_key(r): r for r in dbc.records}
    added = []

    for target_race, reference_race in ((17, RACE_DRAENEI), (18, RACE_TAUREN)):
        for cls in TARGET_CLASSES:
            for gender in TARGET_GENDERS:
                source_key = (reference_race, cls, gender)
                if source_key not in index:
                    raise ValueError(f"missing reference CharStartOutfit row {source_key}")
                row = bytearray(index[source_key])
                max_id += 1
                set_outfit_id(row, max_id)
                row[4] = target_race
                row[5] = cls
                row[6] = gender
                dbc.records.append(row)
                added.append([target_race, cls, gender, max_id, reference_race])

    dbc.save(dst)
    return {"added": added}


def extend_mask(mask: int, skill_line: int) -> int:
    """Conservative race-mask extension.

    Generic masks (0) stay generic. Common and Orcish are explicitly assigned to
    the appropriate Tuskarr faction. Other restricted rows are extended only if
    they already apply to BOTH Tauren and Draenei, which captures the shared
    Warrior/Hunter/Shaman capability intersection without copying race-specific
    Tauren- or Draenei-only data.
    """
    if mask == 0:
        return mask
    if skill_line == SKILL_LANG_COMMON:
        return mask | RACE_BIT(ALLIANCE_TUSKARR)
    if skill_line == SKILL_LANG_ORCISH:
        return mask | RACE_BIT(HORDE_TUSKARR)
    if (mask & RACE_BIT(RACE_TAUREN)) and (mask & RACE_BIT(RACE_DRAENEI)):
        return mask | RACE_BIT(ALLIANCE_TUSKARR) | RACE_BIT(HORDE_TUSKARR)
    return mask


def build_skill_race_class_info(src: Path, dst: Path) -> dict:
    dbc = WDBC.load(src)
    if dbc.record_size != dbc.fields * 4 or dbc.fields < 7:
        raise ValueError(f"unexpected SkillRaceClassInfo layout: fields={dbc.fields}, record_size={dbc.record_size}")
    changed = 0
    examples = []
    for row in dbc.records:
        skill = dbc.u32(row, 1)
        old = dbc.u32(row, 2)
        new = extend_mask(old, skill)
        if new != old:
            dbc.set_u32(row, 2, new)
            changed += 1
            if len(examples) < 25:
                examples.append({"skill": skill, "old_mask": old, "new_mask": new})
    dbc.save(dst)
    return {"changed_rows": changed, "examples": examples}


def build_skill_line_ability(src: Path, dst: Path) -> dict:
    dbc = WDBC.load(src)
    if dbc.record_size != dbc.fields * 4 or dbc.fields < 5:
        raise ValueError(f"unexpected SkillLineAbility layout: fields={dbc.fields}, record_size={dbc.record_size}")
    changed = 0
    examples = []
    for row in dbc.records:
        skill_line = dbc.u32(row, 1)
        old = dbc.u32(row, 3)
        new = extend_mask(old, skill_line)
        if new != old:
            dbc.set_u32(row, 3, new)
            changed += 1
            if len(examples) < 25:
                examples.append({"skill_line": skill_line, "spell": dbc.u32(row, 2), "old_mask": old, "new_mask": new})
    dbc.save(dst)
    return {"changed_rows": changed, "examples": examples}


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("source_dir", type=Path)
    p.add_argument("output_dir", type=Path)
    args = p.parse_args()

    source = args.source_dir.resolve()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)

    for name in FILES:
        if not (source / name).is_file():
            raise SystemExit(f"ERROR: missing {source / name}")

    input_hashes = {name: sha256(source / name) for name in FILES}
    changes = {
        "ChrRaces.dbc": build_chr_races(source / "ChrRaces.dbc", output / "ChrRaces.dbc"),
        "CharBaseInfo.dbc": build_char_base_info(source / "CharBaseInfo.dbc", output / "CharBaseInfo.dbc"),
        "CharStartOutfit.dbc": build_char_start_outfit(source / "CharStartOutfit.dbc", output / "CharStartOutfit.dbc"),
        "SkillRaceClassInfo.dbc": build_skill_race_class_info(source / "SkillRaceClassInfo.dbc", output / "SkillRaceClassInfo.dbc"),
        "SkillLineAbility.dbc": build_skill_line_ability(source / "SkillLineAbility.dbc", output / "SkillLineAbility.dbc"),
    }
    output_hashes = {name: sha256(output / name) for name in FILES}

    manifest = {
        "format": 1,
        "source_dir": str(source),
        "output_dir": str(output),
        "input_sha256": input_hashes,
        "output_sha256": output_hashes,
        "changes": changes,
        "notes": [
            "No Blizzard data is stored in the repository; these outputs were generated locally from user-supplied DBCs.",
            "Race 18 is intentionally repurposed from the stock Forest Troll placeholder.",
            "Both genders intentionally use the stock Tuskarr male model.",
            "Skill mask propagation is conservative and must still pass in-game class/trainer regression testing.",
        ],
    }
    (output / "tuskarr-dbc-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
