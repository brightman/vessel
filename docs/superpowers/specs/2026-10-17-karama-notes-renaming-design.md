# Karama.Cloud and Notes naming design

## Decision

Karama.Cloud is the public product brand. The structured document product is Note (plural Notes). Files and Apps retain their names. Vessel remains the repository and CLI executable name.

## Contract

- The website, console, registration email, API title and description, current product documentation, and CLI documentation use Karama.Cloud and Notes.
- All Note HTTP routes use `/v1/notes` and `/v1/spaces/{space_id}/notes`. JSON resource keys and identifiers use `note` and `note_id`; errors use `NOTE_*`.
- The CLI command group is `vessel notes`. No `vessel pages` alias is retained.
- The server environment prefix is `NOTES_`. Existing unprefixed registration and Brevo secrets retain their names because they do not contain Page.
- The database uses `notes`, `note_versions`, `note_assets`, `note_directories`, `note_capabilities`, `note_proposals`, and `note_agent_events`, with `note_id` columns. An Alembic migration renames existing tables and columns in place, preserving rows. Earlier migration files remain immutable history.
- Code modules, classes, functions, and UI components that represent the document product use Note naming. Generic browser pages and pagination keep their literal meaning.

## Scope and verification

No old API paths, CLI aliases, or environment prefixes are retained. The existing local PostgreSQL data is migrated in place. Confirm the migration, build both frontends, check the Note API and CLI command surface, and verify the local pages load. Production DNS and deployment are separate operations.
