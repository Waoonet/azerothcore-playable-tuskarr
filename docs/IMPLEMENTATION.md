# Implementation roadmap

This document defines the implementation order and hard test gates for playable Tuskarr.

## Milestone 1 — Foundation

Complete when:

- repository structure exists;
- project design is machine-readable;
- CI validates JSON and rejects original/binary Blizzard client assets;
- AzerothCore source audit tooling exists;
- legal/distribution boundaries are documented.

## Milestone 2 — Playable race proof-of-concept

Goal: prove both faction race IDs can create, enter world, move, fight, log out/in and use basic equipment before investing in quests/racials.

Required work:

1. Audit target AzerothCore checkout for IDs 17/18 and all race bounds/masks.
2. Add explicit player-race definitions for Alliance Tuskarr and Horde Tuskarr.
3. Ensure race-to-team logic maps Alliance Tuskarr to Alliance and Horde Tuskarr to Horde.
4. Update playable/alliance/horde race masks and every hard-coded bound identified by the audit.
5. Add six valid race/class combinations: Warrior, Hunter, Shaman for each faction.
6. Add player creation rows placing all six combinations in Kamagua.
7. Add minimum viable base stats/skills/action bars/start outfit data.
8. Make client race data recognize both race entries.
9. Add minimum character-creation UI support sufficient to create test characters.

Gate A: Alliance Tuskarr Warrior can be created and enter world at level 1 in Kamagua.

Gate B: Horde Tuskarr Warrior can be created and enter world at level 1 in Kamagua.

Gate C: all six race/class combinations create successfully.

Gate D: restart server; all six can log in again.

## Milestone 3 — Model/client correctness

- Resolve exact stock WotLK Tuskarr display/model/texture chain.
- Point male and female race model fields to the same Tuskarr model.
- Disable/neutralize unsupported appearance selectors for v1.
- Correct character-creation camera.
- Systematically test animations and weapon attachment points.
- Test armor slots before choosing a custom armor strategy.

Armor test matrix:

- cloth/leather/mail/plate chest;
- robe;
- legs, gloves, boots, belt, cloak;
- helmet, shoulders;
- 1H, 2H, shield, staff, polearm, bow, gun;
- sheathed and unsheathed states.

No claim of normal player armor compatibility is considered verified until this matrix is tested in-game.

## Milestone 4 — Race/class integration

- Correct race/class skill masks.
- Verify Warrior stances/rage/weapons/shields/plate progression.
- Verify Hunter ranged combat/pets/stables/ammunition/mail progression.
- Verify Shaman spells/totems/shields/mail progression, especially Alliance-specific assumptions.
- Configure Common for Alliance and Orcish for Horde.
- Set The Kalu'ak to Friendly.
- Configure normal starter equipment and action bars.

## Milestone 5 — Racials

Implement and test:

- Thick Blubber;
- Arctic Blood;
- Born of the Sea;
- Master Angler;
- Throw Net.

Throw Net must be tested for range, LOS, cooldown, break-on-damage, PvP behavior, diminishing returns and immune/boss targets.

## Milestone 6 — Kamagua starter experience

Shared level 1 introduction:

1. A Child of the Kalu'ak
2. The First Catch
3. Learning the Net
4. Hunter of the Shore
5. The Ancestors Watch

Alliance branch:

1. Friends From the South
2. A Test of Trust
3. An Alliance Beyond the Sea
4. A New Shore
5. A Tuskarr in Stormwind

Horde branch:

1. Visitors of the Earthmother
2. Spirits in Accord
3. Brothers of the Hunt
4. Across the Great Sea
5. A Tuskarr in Thunder Bluff

The Kamagua starter pocket must use safe custom low-level creatures. Normal Northrend creatures must not make the area unusable for level-1 characters.

Final transport is controlled/scripted; a level-5 character is not required to physically traverse Northrend.

## Milestone 7 — Mounts and polish

- Tuskarr-themed racial mount vendor/quest;
- race icons and polished Glue strings;
- optional original custom armor appearances if stock player armor is inadequate;
- documentation and screenshots;
- upgrade/uninstall support.

## Milestone 8 — Public release

A public release must include:

- tested AzerothCore commit/range;
- source patch/module code;
- SQL migrations;
- client patch builder/definitions, not original Blizzard assets;
- install and uninstall instructions;
- compatibility report;
- known limitations;
- checksums/version metadata.

## Regression matrix

Before declaring a release stable, test both factions for:

- creation/login/logout/restart;
- death/corpse/ghost/resurrection;
- NPC hostility and capital-city guards;
- quests/vendors/trainers/flight masters;
- groups/raids/guilds/mail/friends/channels/LFG;
- battleground/world PvP behavior;
- bank/auction house;
- professions;
- mounts/vehicles/transports/swimming;
- achievements and race/faction-restricted content;
- all three classes through representative progression.
