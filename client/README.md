# Client patch tooling

This directory contains only project-authored client transformation definitions, GlueXML/Lua overrides, original project assets, and scripts for building a Tuskarr patch from a user-supplied compatible WoW 3.3.5a client.

Do not commit original Blizzard MPQ/DBC/M2/BLP/audio/map files.

Planned responsibilities:

- verify expected 3.3.5a client inputs;
- extract required data locally;
- apply race/class/skill/spell data transformations;
- install character-creation Glue changes;
- add project-authored icons/textures if created;
- build the final patch archive locally;
- validate output and print checksums.

The repository CI intentionally rejects common original/binary Blizzard client asset extensions.
