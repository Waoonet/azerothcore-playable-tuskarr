#!/usr/bin/env python3
"""Small WDBC reader/writer used by the Tuskarr build tools.

The project never ships Blizzard DBC files. These helpers operate only on DBCs
supplied locally by the user and preserve the original string block verbatim.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path


@dataclass
class WDBC:
    fields: int
    record_size: int
    string_block: bytes
    records: list[bytearray]

    @classmethod
    def load(cls, path: Path) -> "WDBC":
        data = path.read_bytes()
        if len(data) < 20:
            raise ValueError(f"{path}: too small to be a WDBC file")
        magic, count, fields, record_size, string_size = struct.unpack_from("<4s4I", data, 0)
        if magic != b"WDBC":
            raise ValueError(f"{path}: expected WDBC magic, got {magic!r}")
        records_start = 20
        strings_start = records_start + count * record_size
        strings_end = strings_start + string_size
        if strings_end > len(data):
            raise ValueError(f"{path}: truncated WDBC data")
        records = [
            bytearray(data[records_start + i * record_size : records_start + (i + 1) * record_size])
            for i in range(count)
        ]
        return cls(fields=fields, record_size=record_size, string_block=data[strings_start:strings_end], records=records)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        header = struct.pack(
            "<4s4I", b"WDBC", len(self.records), self.fields, self.record_size, len(self.string_block)
        )
        path.write_bytes(header + b"".join(bytes(r) for r in self.records) + self.string_block)

    def u32(self, record: bytearray, field: int) -> int:
        offset = field * 4
        if offset + 4 > len(record):
            raise IndexError(f"field {field} does not fit record_size={self.record_size}")
        return struct.unpack_from("<I", record, offset)[0]

    def set_u32(self, record: bytearray, field: int, value: int) -> None:
        offset = field * 4
        if offset + 4 > len(record):
            raise IndexError(f"field {field} does not fit record_size={self.record_size}")
        struct.pack_into("<I", record, offset, value & 0xFFFFFFFF)

    @staticmethod
    def u8(record: bytearray, offset: int) -> int:
        return record[offset]

    @staticmethod
    def set_u8(record: bytearray, offset: int, value: int) -> None:
        record[offset] = value & 0xFF

    def string_at(self, offset: int) -> str | None:
        if offset <= 0 or offset >= len(self.string_block):
            return None
        end = self.string_block.find(b"\0", offset)
        if end < 0:
            return None
        try:
            return self.string_block[offset:end].decode("utf-8")
        except UnicodeDecodeError:
            return None
