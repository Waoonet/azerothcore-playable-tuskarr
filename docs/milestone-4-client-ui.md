# Milestone 4 - generated client UI and deployment bundle

Milestone 4 consumes the exact GlueXML files extracted from the user's own 3.3.5a client and the already-validated Milestone 2 DBC/server staging payload.

It remains a staging-only operation. Nothing is copied into the live client or server.

## Client transformation

`tools/build-client-ui-patch.py` is pinned to the audited Armapade GlueXML hashes. It refuses to patch an unexpected source revision.

The generator:

- changes `MAX_RACES` from 10 to 12;
- adds race buttons 11 and 12;
- positions every race button dynamically from `GetFactionForRace(index)` instead of assuming enumeration order;
- supports six Alliance and six Horde rows with compact spacing;
- adds Tuskarr race lore and the five planned racial descriptions;
- maps `TUSKARR_MALE` and `TUSKARR_FEMALE` to one temporary stock atlas cell because 3.3.5a has no Tuskarr race portrait in `UI-CharacterCreate-Races`;
- makes the character-create background fall back to Human for Alliance Tuskarr and Tauren for Horde Tuskarr;
- leaves class restrictions DBC-driven through the existing `IsRaceClassValid()` path.

The icon mapping is explicitly temporary. It does not alter the character model.

## MPQ packaging

`tools/tuskarr-mpq-pack.cpp` uses StormLib to build two staged archives:

- `Data/patch-4.MPQ` - custom `DBFilesClient` files;
- `Data/enUS/patch-enUS-4.MPQ` - patched `Interface/GlueXML` files.

The staging script round-trips representative files through StormLib and compares them byte-for-byte with the generated patch tree.

## Server payload

The same bundle also includes the Milestone 2 server staging data:

- modified server DBC set;
- proof-of-concept creation SQL;
- `mod-playerbots` random-generation exclusion patch.

## Run

```bash
cd /root/azerothcore-playable-tuskarr
git pull --ff-only
bash tools/stage-milestone4.sh \
  /root/tuskarr-glue-extract-20260915-084412 \
  /root/tuskarr-stage-20260914-203217
```

Do not manually install the resulting archives or server payload until the generated `MILESTONE-4-REPORT.txt` has passed all gates.
