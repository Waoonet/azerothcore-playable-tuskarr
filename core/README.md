# Core changes

This directory will contain project-authored AzerothCore source changes required to make race IDs 17/18 valid playable Tuskarr races.

Do not place a copy of AzerothCore here.

Planned contents:

- source patch files tied to tested upstream commits;
- optional module code where functionality can cleanly live outside the core;
- compatibility metadata;
- apply/revert tooling.

Core work must cover race validation, playable race masks, Alliance/Horde team derivation, race-indexed bounds, and any systems discovered by `tools/audit-azerothcore.sh`.
