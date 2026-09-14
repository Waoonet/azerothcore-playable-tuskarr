# AzerothCore Playable Tuskarr

A reproducible implementation of playable **Alliance and Horde Tuskarr** for AzerothCore 3.3.5a.

> **Status:** development / proof-of-concept. Do not install on a production realm yet.

## Final design target

| Feature | Alliance | Horde |
|---|---|---|
| Display name | Tuskarr | Tuskarr |
| Planned race ID | 17 | 18 |
| Classes | Warrior, Hunter, Shaman | Warrior, Hunter, Shaman |
| Starting level | 1 | 1 |
| Starting area | Kamagua | Kamagua |
| Intro destination | Stormwind | Thunder Bluff |
| Male model | WotLK Tuskarr | WotLK Tuskarr |
| Female model | same male Tuskarr model | same male Tuskarr model |
| Base language | Common | Orcish |
| Kalu'ak reputation | Friendly | Friendly |

### Planned racials

- **Thick Blubber** — +1% Stamina.
- **Arctic Blood** — 2% reduced chance to be hit by Frost spells.
- **Born of the Sea** — +15% swim speed and +100% underwater breath duration.
- **Master Angler** — +15 Fishing.
- **Throw Net** — 15 yd instant root, 3 seconds, breaks on damage, 2 minute cooldown; bosses/immune creatures remain immune.

The exact spell implementation and balance are not considered final until tested in the 3.3.5a client and current AzerothCore.

## Starter experience

All Tuskarr begin at level 1 in a protected low-level section of Kamagua. The shared opening introduces fishing, hunting, Throw Net, and Kalu'ak ancestral/spiritual culture. It then branches by faction:

- **Alliance:** short Alliance contact storyline, then controlled transport to **Stormwind**.
- **Horde:** Tauren-focused spiritual/hunting storyline, then controlled transport to **Thunder Bluff**.

There is **no level-70 starting option**.

## Repository principles

This repository is intended to contain only original project code, SQL, patch definitions, scripts, documentation, and original assets. It must not redistribute Blizzard's original World of Warcraft client, MPQs, DBC binaries, M2 models, BLP textures, sounds, or other copyrighted game data.

Client tooling will therefore be designed to transform files supplied by the user from their own compatible 3.3.5a client instead of shipping original client assets.

## Planned architecture

```text
core/                AzerothCore source patches / module code
sql/                 World/characters/auth migrations
client/              Patch definitions, GlueXML overrides and build tooling
docs/                Design, installation, compatibility and test documentation
tools/               Auditing, validation and packaging scripts
.github/workflows/   CI validation and release automation
project/             Machine-readable implementation manifest
```

## Development milestones

1. **Foundation and compatibility audit** — repository, CI, manifests, AzerothCore scanner and legal/client-asset guardrails.
2. **Playable race core support** — race IDs, faction/team logic, six Warrior/Hunter/Shaman combinations and Kamagua spawn proof-of-concept.
3. **Client/DBC support** — character creation, race/class data, models, customization restrictions and client patch builder.
4. **Racials and class integration** — five racials, skills, action bars, trainers, reputation and class-specific validation.
5. **Kamagua starter experience** — shared quests plus Alliance→Stormwind and Horde→Thunder Bluff branches.
6. **Model/armor compatibility** — systematic animation, weapon attachment and armor rendering tests; custom visual strategy if required.
7. **Public release** — installer, client builder, versioned release packages, upgrade/uninstall path and documentation.

## Compatibility policy

The project targets **AzerothCore WotLK (3.3.5a)**. Hard-coded patches will be tied to tested AzerothCore commits. Before applying anything, the included audit tooling will identify relevant race assumptions and expected source/database structures.

Race ID 18 is currently treated only as a **planned** Horde Tuskarr slot. Upstream AzerothCore identifies 18 with the unused Forest Troll race. It will not be repurposed by an installer until the compatibility audit confirms that doing so is safe for the target checkout and installed modules.

## Current safety rules

- Never run unfinished SQL against a production realm.
- Back up source, databases and server DBCs before installation.
- Keep server and client data versions synchronized.
- Do not assume NPC Tuskarr armor rendering works like a player model; this must be tested.
- Do not silently alter another module's use of race IDs 17 or 18.

## License

Project code is intended to be released under the MIT License. World of Warcraft and related names/assets are property of their respective owners; they are not included in this repository.
