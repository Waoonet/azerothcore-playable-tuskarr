# Milestone 3 - client preflight

Milestone 2 proved that the exact Armapade AzerothCore revision and active DBC set can be transformed into two playable Tuskarr race definitions without touching the live realm.

Milestone 3 moves to the WoW 3.3.5a client side, but remains read-only against the user's client.

## Why this gate exists

Playable custom races require character-creation UI changes in addition to DBC data. On Wrath-era clients those changes are normally carried by GlueXML/Lua files such as:

- `Interface/GlueXML/CharacterCreate.lua`
- `Interface/GlueXML/CharacterCreate.xml`
- `Interface/GlueXML/GlueStrings.lua`
- `Interface/GlueXML/GlueParent.lua` (when required by the exact client/UI revision)

The project must patch the user's exact client sources rather than silently replacing them with a third-party UI dump. This matters because existing private-server clients often already contain custom GlueXML changes.

## What `stage-client-preflight.sh` does

The script:

1. locates the most recent Milestone 2 staging directory (or accepts one explicitly);
2. copies the five custom DBCs into a new `patch-tree/DBFilesClient` directory;
3. inventories the supplied client root without changing it;
4. records WoW executables, locale directories, MPQ archives and existing patch archives;
5. searches for extracted character-creation GlueXML/Lua assets;
6. if an exact extracted set is found, copies it into the staging directory and runs `audit-client-glue.py`;
7. inventories candidate MPQ/client tooling available on the host;
8. verifies any extracted client DBC directory it can identify;
9. writes a complete `CLIENT-PREFLIGHT-REPORT.txt`.

It does **not** edit the client, rebuild an MPQ, install a patch, alter the server database, or restart either AzerothCore service.

## Current target design

The staged data represents:

- race 17: Alliance Tuskarr;
- race 18: Horde Tuskarr;
- Warrior, Hunter and Shaman only;
- both genders using the same stock Tuskarr visual model for the initial proof of concept;
- both race records exposing the same `Tuskarr` client file-string family.

The UI therefore needs two selectable Tuskarr race entries, while a single Tuskarr icon/text family can be reused for both faction versions.

## Important implementation rule

Do not assume that a character-creation race-button index is numerically equal to the `ChrRaces.dbc` race ID. Milestone 3 records the exact client enumeration logic before generating the GlueXML patch.

## Run

```bash
cd /root/azerothcore-playable-tuskarr
git pull --ff-only
bash tools/stage-client-preflight.sh /home/azeroth/wow-client
```

After it completes, preserve the final `OUT=...` value and the complete `CLIENT-PREFLIGHT-REPORT.txt` output for the next implementation step.
