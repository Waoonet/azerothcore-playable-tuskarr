# Milestone 2 — Base playable-race staging

This milestone converts the audited stock 3.3.5a race data into a **staged proof-of-concept** for two playable Tuskarr races. It deliberately does not install anything on a live realm.

## Tested compatibility profile

- AzerothCore commit: `413bea61a85e20d9caef7d66fc601a661fdddd9d`
- Active server DBC location in the reference Armapade environment: `/home/azeroth/server/bin/dbc`
- Race 17 in the audited `ChrRaces.dbc`: stock Tuskarr
- Race 18 in the audited `ChrRaces.dbc`: stock Forest Troll placeholder, intentionally repurposed by this project

## Staged race definitions

### Race 17 — Alliance Tuskarr

- stock race-17 Tuskarr strings and client prefix
- Alliance TeamID `7`
- Alliance group field `0`
- Alliance faction-template reference `1`
- male and female visual model both use the stock race-17 male model

### Race 18 — Horde Tuskarr

- cloned from the stock race-17 Tuskarr record rather than the Forest Troll visual record
- Horde TeamID `1`
- Horde group field `1`
- Tauren/Horde faction-template reference `6`
- male and female visual model both use the stock race-17 male model

Both use flags `14`, matching the audited Tauren/Draenei playable-style flag combination (`bare feet`, `can mount`, plus the existing `0x08` playable-race flag used by those records). This is a project implementation choice and must still be validated in-game for Tuskarr-specific rendering/mount behavior.

## Class data

`CharBaseInfo.dbc` receives exactly six combinations:

- 17 / Warrior (1)
- 17 / Hunter (3)
- 17 / Shaman (7)
- 18 / Warrior (1)
- 18 / Hunter (3)
- 18 / Shaman (7)

No other class is made available.

## Starting outfits

For the proof-of-concept only:

- Alliance Tuskarr outfits are cloned from Draenei rows for the same class/gender.
- Horde Tuskarr outfits are cloned from Tauren rows for the same class/gender.

This provides legitimate class starter item IDs without copying another race's racial spells. Visual rendering on the NPC-derived Tuskarr model is **untested** and is a later milestone gate.

## Skill-mask strategy

The builder does not blindly copy all Tauren or Draenei race data.

- race-mask `0` rows remain untouched (generic/all-race semantics)
- Common (`SkillLine 98`) gains Alliance Tuskarr only
- Orcish (`SkillLine 109`) gains Horde Tuskarr only
- other restricted rows gain both Tuskarr bits only when the existing mask already contains **both Tauren and Draenei**

That is deliberately conservative: Warrior/Hunter/Shaman are shared by the two reference races, while Tauren-only and Draenei-only racial/language data is not inherited automatically.

This is still **untested** until class spellbooks, trainers, weapon skills, armor proficiency and later-level skill acquisition have been exercised in-game.

## Playerbots safeguard

The audited `mod-playerbots` factory iterates dynamically to `sRaceMgr->GetMaxRaces()`. As soon as races 17/18 become playable and have valid creation data, they could become candidates for random bot generation.

Milestone 2 therefore generates a small source patch that skips IDs 17 and 18 in `RandomPlayerbotFactory::CreateRandomBot`. The patch is generated and validated with `git apply --check`, but the staging script does not apply it.

Tuskarr playerbots can be enabled later as a separate tested feature.

## Proof-of-concept SQL

The SQL preview creates only the six base `playercreateinfo` rows, neutral race-stat modifiers, and racial-free class fundamentals on the action bar.

Start location:

- Map: `571` (Northrend)
- Zone: `495` (Howling Fjord)
- Position: stock AzerothCore Kamagua teleport coordinates

The SQL deliberately does **not** add:

- custom racials
- Kalu'ak reputation
- low-level Kamagua creatures
- quests
- trainers
- Stormwind/Thunder Bluff exits
- racial mounts

Those are later milestones after the base race/client login proof is successful.

## Running the staging gate

```bash
cd /root/azerothcore-playable-tuskarr
git pull --ff-only

bash tools/stage-milestone2.sh \
  /home/azeroth/azerothcore \
  /home/azeroth/server
```

The script writes a timestamped directory under `/root/tuskarr-stage-*` containing modified DBCs, a source patch, SQL preview, manifests and a report.

It does **not** modify AzerothCore, execute SQL, replace server/client DBCs, or restart worldserver.

## Next gate

Before installing Milestone 2, the project still needs the client character-creation GlueXML/UI work. After that package exists, we can apply the staged changes to a controlled test copy and verify character creation/login plus movement, animations, equipment and class functionality.
