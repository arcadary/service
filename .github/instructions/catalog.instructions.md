---
applyTo: "data/catalog/**,lib/tasks/catalog.rake"
---

# Catalog inputs and commands

- Keep the launcher identity snapshot verbatim and record its repository, commit, path and SHA-256 alongside it. Update it from the launcher, without independently curating a service mapping.
- DATs remain local and untracked. The fetch command accepts only the approved pinned filenames and verifies their SHA-256 digests. Import reads local metadata only.
- Keep operator commands thin wrappers around services. Preserve per-system atomic bulk writes, non-zero failure exits and unchanged repeat imports. The bounded offline transaction exception, key encoding and metadata rules are documented in [Catalog data](../../README.md#catalog-data).
