# SQL migrations

All database changes must be reproducible migrations. Do not document production-only manual edits as the source of truth.

Planned layout:

- `sql/world/` — player creation data, racials, quests, NPCs, starter creatures, trainers, reputation, mounts and other world content.
- `sql/characters/` — only if character-schema changes become necessary.
- `sql/auth/` — only if auth-schema changes become necessary.

Migrations must be idempotent where practical, use reserved project ID ranges documented before insertion, and include an uninstall/revert strategy for custom rows.
