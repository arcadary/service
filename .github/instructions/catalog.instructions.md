---
applyTo: "data/catalog/**,lib/tasks/catalog.rake"
---

# Catalog inputs and commands

- The service database is the ongoing source of truth. Use shared authoring operations for corrections, additions and grouping, with no per-record PR or launcher snapshot change. Keep the launcher snapshot verbatim as a bootstrap/reference input, recording its repository, commit, path and SHA-256; update the snapshot from the launcher.
- DATs remain local and untracked. The fetch command accepts only the approved pinned filenames and verifies their SHA-256 digests. Import reads local metadata only.
- Keep operator commands thin wrappers around services. Preserve per-system atomic bulk writes, non-zero failure exits and unchanged repeat imports. The bounded offline transaction exception, key encoding and metadata rules are documented in [Catalog data](../../README.md#catalog-data).
- Reference imports and ordinary seeds preserve authored fields, grouping titles, original importer-key ownership, current memberships, retained identities and release evidence. Store changed source values separately and report nonfatal divergences; unresolved identity conflicts or invalid configurations fail their system without writes. Never reactivate a retired ID or recreate a release for a known detached checksum. Match current memberships, including secondary media, before applying the multi-disk/shared import refusal.
- Manual JSON imports are one shared authoring operation per transaction. Require exact affected revisions and complete unchanged previews where the operation requires one; never generate a replacement preview during apply. See [Offline manual metadata imports](../../README.md#offline-manual-metadata-imports) for revision reads and retry boundaries.
