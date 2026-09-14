#!/usr/bin/env python3
"""Minimal read-only inspector for Wrath-era WDBC files.

This tool intentionally does not ship or modify Blizzard data. It reads a DBC
provided by the user and prints selected records as raw 32-bit fields, with a
few field labels for known tables used by the Tuskarr project.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

LABELS = {
    "ChrRaces.dbc": {
        0: "RaceID",
        1: "Flags",
        2: "FactionID",
        4: "model_m",
        5: "model_f",
        7: "TeamID",
        12: "CinematicSequence",
        13: "alliance",
        68: "expansion",
    },
    "CharBaseInfo.dbc": {
        0: "RaceID",
        1: "ClassID",
    },
}


def read_c_string(block: bytes, offset: int) -> str | None:
    if offset <= 0 or offset >= len(block):
        return None
    end = block.find(b"\0", offset)
    if end < 0:
        return None
    raw = block[offset:end]
    if not raw or len(raw) > 160:
        return None
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if not all(ch.isprintable() or ch in "\t\r\n" for ch in text):
        return None
    return text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("dbc", type=Path)
    parser.add_argument(
        "--id",
        dest="ids",
        type=int,
        action="append",
        default=[],
        help="Only show records whose first field matches this value; repeatable.",
    )
    parser.add_argument(
        "--field-equals",
        nargs=2,
        metavar=("FIELD", "VALUE"),
        action="append",
        default=[],
        help="Additional raw field equality filter; repeatable.",
    )
    args = parser.parse_args()

    data = args.dbc.read_bytes()
    if len(data) < 20:
        raise SystemExit("ERROR: file is too small to be a DBC")

    magic, records, fields, record_size, string_size = struct.unpack_from("<4s4I", data, 0)
    if magic != b"WDBC":
        raise SystemExit(f"ERROR: expected WDBC magic, found {magic!r}")
    if record_size != fields * 4:
        raise SystemExit(
            f"ERROR: unsupported record layout: fields={fields}, record_size={record_size}"
        )

    records_start = 20
    strings_start = records_start + records * record_size
    strings_end = strings_start + string_size
    if strings_end > len(data):
        raise SystemExit("ERROR: truncated DBC")
    strings = data[strings_start:strings_end]

    print(f"file={args.dbc}")
    print(
        f"magic=WDBC records={records} fields={fields} "
        f"record_size={record_size} string_block_size={string_size}"
    )

    filters = [(int(field), int(value)) for field, value in args.field_equals]
    labels = LABELS.get(args.dbc.name, {})
    shown = 0

    for index in range(records):
        pos = records_start + index * record_size
        values = struct.unpack_from(f"<{fields}I", data, pos)
        if args.ids and values[0] not in args.ids:
            continue
        if any(field >= fields or values[field] != value for field, value in filters):
            continue

        shown += 1
        print(f"\nrecord_index={index}")
        for field, value in enumerate(values):
            label = labels.get(field, "")
            decoded = read_c_string(strings, value)
            suffix = ""
            if decoded is not None:
                suffix = f" string={decoded!r}"
            if label:
                print(f"  [{field:02d}] {label:<20} = {value:<10} 0x{value:08X}{suffix}")
            else:
                print(f"  [{field:02d}] {'':20} = {value:<10} 0x{value:08X}{suffix}")

    if shown == 0:
        print("\nNo matching records.")
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FileNotFoundError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
