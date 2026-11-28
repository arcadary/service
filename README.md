# Arcadary service

The remote service for [Arcadary](https://github.com/arcadary/arcadary): a Rails 8.1 application for the project's homepage and launcher JSON API. `GET /v1/lookup/{sha1}.json` identifies a game file and redirects to its release and game, or to all containing releases for a shared file. The offline catalog importer covers eight pinned No-Intro lists (29,336 distinct checksums); two optional homebrew seeds work without those lists. Original controller facts support exact SNES releases; compatibility and page features are still to be built. Nothing is deployed.

## Setup

Screenshot decoding requires native libvips on the normal library search path. On macOS, install it with `brew install vips` before running setup or checks. GitHub CI and the Docker image already install libvips.

```bash
mise install
mise run setup
mise run dev
mise run ci
```

What it is for and its product rules are in the project's Uberblick workspace (bound in `.uberblick.json`); the technical rules and setup are in [AGENTS.md](AGENTS.md).

## Catalog data

The catalog originates from [No-Intro](https://no-intro.org/), sourced through [libretro-database at f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029](https://github.com/libretro/libretro-database/tree/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/metadat/no-intro). We import checksum metadata, group releases into games, normalize titles/regions/revisions and apply the launcher's explicit identity mappings. The service database is the ongoing source of truth: the single admin makes additions, corrections, aliases, grouping and startup changes through [shared authoring operations](#catalog-authoring), including the offline JSON adapter below, without a per-record PR or launcher snapshot change. Git mappings are bootstrap/reference inputs. The entire service catalog, including project corrections, additions and later metadata fields, is licensed under [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/); see [LICENSE-DATA](LICENSE-DATA). Screenshot images and all video are excluded: each medium's own rights apply. Catalog and screenshot licences grant no video rights. The source's [licence at the pin](https://github.com/libretro/libretro-database/blob/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/LICENSE) is CC-BY-SA-4.0. Code remains MIT.

### Fetch and import

```bash
mise exec -- bin/rails 'catalog:fetch[storage/catalog-dats]'
mise exec -- bin/rails 'catalog:import[storage/catalog-dats]'
```

Fetch downloads only the eight filenames in [data/catalog/dats.json](data/catalog/dats.json), from the recorded commit, and verifies each SHA-256 before replacing its local copy. It refuses extra file arguments. These downloads contain metadata only. DATs stay out of git; no game files or player filenames are received, stored or served. Import reads local files only and accepts later operator-supplied lists under those filenames; it does not require their digests to match the initial pin.

Run import as an offline operator task with exclusive access to the catalog. Parsing and validation precede writes. Each system gets one atomic transaction with bulk writes in batches of up to 500 rows, the issue-approved exception to the normal short-transaction/Solid Queue guidance. No downloads or parsing occur in the transaction. Systems commit independently. The command prints one JSON line per system with game/release created, updated, unchanged and skipped counts, skip/failure reasons and transaction duration in seconds. Missing, malformed or conflicting systems fail without writes to that system; other systems still run. Any whole-system failure or skip exits non-zero. Fetch refusal, digest mismatch and network failures also exit non-zero. Invalid/missing SHA-1 rows are skipped with reasons. Identical reimports preserve every row and timestamp. Later lists never delete absent releases.

Coverage is NES, SNES, Game Boy, Game Boy Color, Mega Drive, PC Engine, Atari 2600 and C64. All valid SHA-1 entries are imported regardless of extension, including all 3,512 C64 entries and tape metadata. Catalog coverage does not imply launcher playback support. The pinned NES list includes both headered `.nes` and unheadered `.unh` variants as distinct releases. A launcher hashing NES payload bytes without the iNES header sends the matching **unheadered** checksum.

`db:seed` optionally adds just µCity (`ucity`, GBC) and Tobu Tobu Girl (`tobu-tobu-girl`, GB), preserving existing releases and imported metadata. Their fixed IDs also apply when importing into an empty database. After import they are `uCity` / `World` / `v1.3` and `Tobu Tobu Girl` / `World` / no revision. `db:seed:replant` discards the catalog and restores only the two offline seeds, titled `µCity` and `Tobu Tobu Girl`, with their original checksums/systems and no region/revision. No DATs are needed for seeds or replant.

### Identity and metadata rules

[data/catalog/games.txt](data/catalog/games.txt) is the verbatim launcher source snapshot; [source.json](data/catalog/source.json) records its repository, commit, path and SHA-256. Update it from the launcher rather than curating a second map here. An unindented `<id> <title>` starts a game, indented SHA-1 lines belong to it, and blank lines and `#` comments are ignored. IDs use lowercase ASCII letters/digits joined by single hyphens. Duplicate IDs/checksums, invalid lines and empty games fail before writes. Preference order has no API meaning. Explicit mappings preserve titles such as `Tetris (Tengen)` and share a game across systems only where explicitly mapped, such as the listed NES/GB Pac-Man releases.

Existing checksum associations and public IDs take precedence. Authored release assignments win over source grouping; retained identities resolve to the active canonical target without reclaiming or reactivating the original ID. Compatible imports after merges/restores succeed. An unresolved curated reassignment, importer-key ownership conflict or public-ID collision fails its system with affected IDs, keys and source values. Unmapped releases initially group only with fallback/seed identities in the same system; titles never implicitly join curated identities. A fallback key is the DAT game name with recognized region/revision parentheses removed, normalized to Unicode NFC, whitespace collapsed to one ASCII space and ends trimmed. Case, punctuation and all other annotations remain significant. The exact stored key encoding is compact UTF-8 JSON `[system, normalized_name]`, with no extra whitespace (`JSON.generate`). Its unique `GameIdentity` entry stays owned by its original identity and resolves through that identity. DAT name changes can add importer keys without forgetting earlier keys. These keys are separate from the searchable `title_aliases` edited by authoring.

A new fallback ID is `<system>-<slug>-<sha256>`: slug is the display title lowercased, each run outside ASCII `a-z0-9` replaced with `-`, leading/trailing `-` removed, or `game` when empty; suffix is the full lowercase SHA-256 of the exact encoded key. Distinct keys therefore stay distinct even if display titles or slugs coincide. There is no fuzzy matching or inferred cross-system grouping.

Display titles remove all parenthesized metadata annotations, then apply NFC and whitespace normalization. Each fallback/seed identity's source title is the smallest display title across all releases originally imported for it, in lexicographic UTF-8 byte order, including releases absent from later lists. Each release retains its DAT source title and internal `source_game_id`; provenance stays with the original identity across grouping. Mapping titles supply curated source titles. For unauthored identities these become effective titles. Explicit title corrections and participation in reassignment, merge or restore protect effective titles thereafter, including retired titles. Merging fallback Adventure into fallback Zelda keeps Zelda's title. A mapping naming a retired ID updates only that identity's source provenance; it never supplies the canonical target's title or transfers provenance between identities.

Reference imports retain authored effective values while updating separate source fields. They preserve aliases, grouping, startup and ordered media corrections, stable IDs, audits, screenshots and recorded image licences. Matching uses current `ReleaseMedium` memberships, never the legacy first-checksum column. A known checksum with no memberships stays unattached, including after an authored removal; the import reports a membership divergence. A checksum in a secondary position is recognized before the existing multi-disk/shared-input refusal, so it cannot create a duplicate release. Invalid effective configurations fail validation before any writes.

Each successful system result includes `divergences`, empty when source and effective choices agree. Entries have `{type, id, field, source_value, effective_value}`; `type` is `game`, `release` or `media`, with a stable public ID or SHA-1. Grouping uses public game IDs; membership differences contain ordered membership arrays, or `source_value: "single release"` and `effective_value: []` for detached checksums. For example, a reviewed title yields `{"type":"game","id":"example","field":"title","source_value":"Source title","effective_value":"Reviewed title"}`. Divergences preserve database choices and do not fail a system or the command. Ordinary seeds print one JSON line per seed with `seed` and the same divergence entry shape, preserving existing metadata, memberships and grouping. Seeds do not update an original seed identity's licence after grouping or replace an existing nonempty licence. Destructive `db:seed:replant` retains its reset semantics.

Source changes advance affected authoring revisions without marking fields authored or creating correction audits; identical imports leave revisions and timestamps unchanged. Changes to public output refresh affected resource ETags and Last-Modified, including sibling releases when a game's title changes. Cache limits still apply: resources may remain cached for **300 seconds**, lookup redirects for **one day**, with no promised early CDN eviction.

Recognized regions are: Asia, Australia, Brazil, Canada, China, Denmark, Europe, Finland, France, Germany, Greece, Hong Kong, India, Italy, Japan, Korea, Mexico, Netherlands, New Zealand, Norway, Portugal, Russia, Scandinavia, Spain, Sweden, Taiwan, United Kingdom, USA and World. A comma-space list of these is recognized intact (`Japan, USA`); `USA`, `Europe` and `World` likewise retain their spelling. Revisions match `Rev ` followed by an ASCII alphanumeric token with optional dot-separated alphanumeric components (for example `Rev 1`), or lowercase `v` followed by numeric dot-separated components and an optional lowercase suffix (for example `v1.3`). Multiple recognized annotations are joined with comma-space. Unknown annotations populate neither region nor revision but remain identity discriminators.

### Ordered media and startup

A release has a stable UUID `public_id` and ordered `ReleaseMedium` rows. Each medium has a stable key within that release, a consecutive position from 1, an optional label (up to 80 characters), a `game` or `save` role, and a `MediaFile`. Files store only exact SHA-1 checksums and optional size, lower-case source extension, CRC32 and MD5 metadata. A file can belong to several releases. The legacy `releases.sha1` column holds the first medium's checksum and is no longer unique. Existing releases migrate to one `main` game medium; size and format stay null when unknown. Seeds and offline imports create the same structure. Imports still create one release per DAT `rom`; they refuse files already in curated multi-disk or shared releases. Importing actual sets remains a follow-up. C64 files remain offline in the launcher.

`GET /v1/releases/{sha1}.json` preserves the existing release/game fields and adds `release.id`, an ordered top-level `media` array (`key`, `position`, `label`, `role`, `sha1`, `size`, `format`) and effective `startup`. The response's `release.sha1` is always the asked file, including secondary disks. The service never infers a set from one checksum or from file names. A shared file's lookup redirects to `/v1/media/{sha1}.json`, whose `releases` array lists each containing release in the same response shape, ordered by release public ID. The direct release endpoint returns `409 {"error":"ambiguous_release"}` with `no-store` for shared files. Both resource endpoints cache successes publicly for 300 seconds with ETags. Lookup redirects cache for one day. `/api-docs` describes every response.

The nullable `releases.startup` JSON uses schema 1: `{"schema":1,"boot":"disk-1","drives":{"8":"disk-1","9":"disk-2"}}`. Every reference is a key in that release. Only C64 has drive slots (`8`, `9`); other systems accept absent or empty drives. A medium occupies at most one slot; boot must be a game medium and, for C64, occupy a slot. Unknown keys, settings, schemas and wrong types are rejected. Null startup boots the first game medium in position order, mounted in C64 slot `8` where applicable. Make coordinated media/startup edits through the previewed `correct_release` authoring operation below. Supply the complete resulting ordered media array and, when needed, startup in the same call. Surviving memberships keep their row IDs and keys during position swaps; do not replace surviving rows to reorder them. Model validation also rejects individual medium edits or removals that invalidate the release.

`startup.revision` is lower-case SHA-256 of compact UTF-8 JSON with no whitespace: `{"startup":{"schema":1,"boot":"<effective key>","drives":{...}},"media":["<first sha1>","<second sha1>"]}`. Object keys appear in the order shown, drive slots sort lexicographically and media checksums follow position order. Explicit defaults produce the same revision as null startup. Labels, size and format do not affect it; effective startup and ordered checksums do. The launcher can bind resume states to this revision. Media/startup changes also invalidate response ETags.

### Original controller layout and prompts

An optional `releases.controller_profile` belongs to the stable release ID. Version 1 supports **`snes` only**. A complete authored example using synthetic evidence:

```json
{
  "version": 1,
  "binding": { "system": "snes", "region": "USA", "revision": null },
  "layout": [
    { "position": "top", "label": "X", "evidence": ["Synthetic edition: original controller observation"] },
    { "position": "right", "label": "A", "evidence": ["Synthetic edition: original controller observation"] },
    { "position": "bottom", "label": "B", "evidence": ["Synthetic edition: original controller observation"] },
    { "position": "left", "label": "Y", "evidence": ["Synthetic edition: original controller observation"] }
  ],
  "prompts": [
    { "letter": "A", "position": "right", "evidence": ["Synthetic edition: observed gameplay prompt and its action"] }
  ]
}
```

Every shown key is required; no extra keys or other versions are accepted at any level. `version` is the integer `1`. `binding` must exactly equal the release's `system`, `region` and `revision`, including nulls. Each non-null binding string is at most **128 characters**. This checks edition metadata; the stable release ID identifies the owner. No facts are inferred from a title, another edition or a system default.

`layout` has exactly **four** facts, declaring each position (`top`, `right`, `bottom`, `left`) and each original SNES label (`X`, `A`, `B`, `Y`) once. Positions are viewed facing the controller's buttons. The supplied mapping is retained, never filled from defaults. `prompts` has **0–16** facts; each `letter` is one case-sensitive ASCII letter (`A–Z` or `a–z`), unique in that profile, and its `position` must resolve to a declared layout position. An empty prompt list asserts no prompt facts. Literal gameplay prompt letters can differ from original labels and between editions.

Every layout and prompt fact has its own `evidence`: **1–8 nonblank text citations**, each at most **500 characters**, retaining provenance for that exact edition. Citations must contain text only: no images, clips, manual scans, file bytes, file names or game-file download locations. No evidence assets or game files are accepted. All profile collections and strings have finite bounds; wrong types, unsupported fields/versions, invalid references and incompatible bindings fail validation.

Public `release.controller_profile` contains only `version`, `layout` (`position`, `label`) and `prompts` (`letter`, `position`). It is omitted when absent. Binding and evidence stay internal. Each shared-media candidate carries its own optional facts; profiles never select a candidate, combine facts or change redirects and `409 ambiguous_release`. No controller choice, controller identifier or device identity is received. Controller classification, physical label/symbol mapping and local preferences belong to the launcher.

**The Legend of Zelda: A Link to the Past SNES trial remains unconfirmed.** No real Zelda profile is populated. Before trial use, the owner must confirm the exact stable release ID, checksum, edition metadata and textual evidence for that edition's layout and on-screen gameplay prompt letters. Its title is insufficient. This gates trial use only, not PR merge or issue closure. Catalog publication and deployment are outside scope.

## Catalog authoring

`CatalogAuthoringService.call(operation:, attributes:, expected_revisions:, reason:, idempotency_key:, preview: nil)` is the shared database write contract used by the offline manual-import adapter and available to future reviewer adapters. It has no authoring HTTP endpoint or UI. Each call requires a nonblank reason and retry key. Configure `CATALOG_ADMIN_NAME` with the single admin's display name as a non-credential environment setting; a missing or blank name fails closed before any write or replay. Never derive it from an HTTP Basic username, token or other credential. Reasons and metadata must contain no credentials or household/device identifiers.

Operations accept only these creation/correction fields (string or symbol keys); all other fields are rejected:

| Operation | `attributes` |
| --- | --- |
| `create_game` | Required `id` (stable public game ID), `title`; optional `title_aliases` (array of distinct nonblank searchable titles). |
| `create_media` | Required lower-case 40-character `sha1`; optional `size` (nonnegative integer), `format` (lower-case alphanumeric), `crc32` (8 lower-case hex characters), `md5` (32 lower-case hex characters). Only checksum metadata is accepted, never file bytes or names. |
| `create_release` | Required existing `game_id`, `system` and nonempty ordered `media` array; optional `region`, `revision`, `startup` and `controller_profile`. The release's stable public ID is generated. Each medium requires `key`, consecutive `position` from 1, `role` (`game` or `save`) and a **new** `sha1`; optional `label` and the initial metadata fields from `create_media` are accepted. No existing checksum may be attached, including one created separately through `create_media`. |
| `correct_game` | Required `id`; one or more of `title`, `title_aliases`. Resolves retired IDs before correction. The alias array replaces the previous aliases. |
| `correct_release` | Required stable release `id`; one or more of `system`, `region`, `revision`, `startup`, `controller_profile`, `media`. `region` and release `revision` may be null. `startup` replaces the whole configuration or may be null for system defaults. `controller_profile` replaces the whole profile, including evidence, or null clears it. A `media` replacement requires preview; see below. |
| `correct_media` | Required existing `sha1`; one or more of `size`, `format`, `crc32`, `md5`, each nullable. Requires preview and covers all containing releases. The checksum itself never changes. |
| `reassign_release` | Required release `id` and target `game_id`. Resolves the target to its active game and moves just that release. Requires preview. |
| `merge_games` | Required source `id` and target `into_game_id`. Resolves both IDs first, moves every source release and retires the source into the chosen target. Requires preview. |
| `restore_game` | Required retired `id`, expected active `canonical_game_id` and explicit distinct `release_ids` array, possibly empty. Optional `title`, `title_aliases` correct the restored identity; optional `canonical_title_aliases` replaces the canonical game's aliases. Requires preview. |

All startup writes use the existing [schema, medium keys and defaults](#ordered-media-and-startup). `correct_release.media` is the complete nonempty resulting array, with required `key`, consecutive `position` from 1, `role` and an **existing** `sha1` in each entry. Optional `label` and checksum metadata (`size`, `format`, `crc32`, `md5`) are accepted. Omitted memberships are removed; new keys attach files already known to the database (create standalone metadata with `create_media` first). A surviving key must retain its checksum and row ID. Optional metadata updates the shared `MediaFile`, not a release-local copy; inconsistent metadata for the same checksum in one request conflicts. Omitted labels on surviving memberships are retained. Startup, system, membership order, roles and labels are validated as one final configuration. A media-only removal leaving a startup reference invalid fails without writes; a coupled startup correction can make the same removal valid. Position swaps preserve surviving keys. Public game/release IDs, media checksums, source fields and importer `GameIdentity` keys cannot be corrected through these operations.

Profile authoring uses the [version 1 schema and bounds](#original-controller-layout-and-prompts) above. Omission preserves the current profile; null clears it, while `authored_fields` retains that deliberate choice. System/edition corrections validate the existing profile against the resulting binding and require a compatible whole replacement or explicit clearing when incompatible. A profile and `correct_release.media` may change in one complete preview; all final profile, startup and media values validate together. Reassignment, grouping and restoration revalidate profiles and preserve each stable release's own facts and evidence; game identity is not part of the edition binding. They never borrow another release's profile. Invalid/stale writes and persistence failures roll back relationships, profiles, revisions and audits together. Profile changes refresh release and containing-media ETags and Last-Modified; old ETag or Last-Modified validators receive updated `200` content and current validators receive `304`, including with `User-Agent: Arcadary/1.0`. Cache lifetimes remain unchanged. Profile changes do not affect `startup.revision`.

`CatalogAuthoringReadService` returns internal records shaped as `{type, id, authoring_revision, canonical, authored_fields, source}`. `canonical` holds effective values: games include `title` and `title_aliases`; releases include `game_id`, `system`, `region`, release `revision`, ordered media metadata, effective startup with `startup.revision`, and complete `controller_profile` (including binding and evidence), or null; media include checksums and metadata. Every game record additionally contains `identity: {state, retired_into_game_id, canonical_game_id, screenshot_licence, catalog_curated, importer_keys}`. State is `active` or `retired`; `retired_into_game_id` is the immediate target, null for active games; `canonical_game_id` is the final active ID. Importer keys belong to that actual identity and are sorted by exact key.

| Read | Result |
| --- | --- |
| `.game(id:)` | Resolves any active or retired ID and returns the active game's actual record and revision, plus `requested_id` echoing the input. |
| `.scope(game_id:)` | Returns raw records for the active game, every retained identity resolving to it, and all its releases, each once. Active and retired inputs produce the same array. |
| `.record(record)` | Serializes the supplied model instance, not an ID. A retired Game produces its own actual ID/revision, retained `canonical.title`/`title_aliases`, source and identity fields, without substitution. |
| `.release(id:)`, `.media(sha1:)` | Return the actual release or checksum metadata record. |

`authored_fields` names fields explicitly set by authoring, including creation fields; the game marker `grouping` protects titles after reassignment, merge or restore. Changing an affected record's revision alone marks no new fields authored. `source` exposes retained `source_title` for games and releases, plus `source_system`, `source_region`, `source_revision` for releases and `source_size`, `source_format`, `source_crc32`, `source_md5` for media, separately from corrected values. Absent source values are null. Authoring never overwrites source provenance. New authored records have no invented provenance. The import-precedence migration reconstructs prior grouping protection and original release ownership from retained audit history; pre-existing corrected media fields whose original values were never stored remain unknown until a reference import supplies them.

`.search(query:, limit: 25)` matches active and retained titles/aliases case-insensitively and returns each resolved active game once (maximum 100 results, ordered by active public ID). Aliases are internal, independent of importer keys, and never appear in public JSON. Provenance, audits, identity state and authoring revisions are also internal.

Merges retain the retired game's original ID, title, aliases, source title, screenshot licence, curation flag and importer keys. The target keeps its own metadata and gains the source title/aliases as searchable aliases, deduplicated by **exact string equality**, excluding its own title. No source values move between games. A into B followed by B into C makes both A and B resolve to C, while A's immediate target remains B. Old IDs resolve before `correct_game`, `create_release.game_id`, reassignment and merge scope selection. Importer keys remain reserved to their original identity and resolve through that identity. Curated/fallback grouping is permitted without changing either flag. Self-merge after resolution, reassignment to the current resolved game, differing screenshot licences on either grouping operation, and identity/public-ID collisions raise `Conflict` without writes.

Restore requires the original identity still to be retired **directly into** the specified active game. An intervening chained merge conflicts. Selected releases must currently belong to that active game. Only those releases move back, and the original ID becomes active again. Restored title/aliases default to retained values; source, licence, curation flag and key ownership remain intact. Canonical aliases gained through the merge are never removed implicitly: use `canonical_title_aliases` for an explicit replacement. Restore does not infer an inverse from audits or overwrite subsequent changes.

For reassignment, merge, restore, `correct_media` and `correct_release` with `media`, first call `CatalogAuthoringService.preview(operation:, attributes:)`. This read-only method needs no reason, retry key or `CATALOG_ADMIN_NAME` and writes no records or audits. Pass its **complete unchanged result** as `preview:` at apply, with the same operation and attributes. Preview contains:

- `operation`, normalized `attributes` and `requested_ids`.
- `resolutions.before` and `.after`, mapping each affected actual game ID to its canonical ID.
- Complete `before` and proposed `after` raw records, including separate retained identities, media metadata, ordered memberships, aliases, importer ownership/resolution and revisions.
- `affected_items`, the distinct union of before/after item identities, and `expected_revisions`, separately keyed to actual records.

Preview/apply permit at most **100 distinct affected items** across the union: each game, release, media file, membership, alias and importer-key entry counts once. A membership's identity is `[release ID, stable key]`, an alias's is `[owning game ID, exact title]`, and an importer entry's is its globally unique key. Grouping/restoration includes both games, all their releases and media, and all retained identities resolving to those games. Media edits include the changed release's complete game scope, old/new files, every release containing those files and those releases' complete game scopes. Shared metadata corrections cover every containing release. No truncated preview is applicable. Above the bound, preview and apply raise `InvalidInput` without writes.

Supply `expected_revisions` as a hash from `game:<actual public ID>`, `release:<public ID>` and, for previewed operations, `media:<sha1>` to each current integer revision. Memberships are protected through release revisions; aliases, importer-key ownership and resolution through owning game revisions and preview state. `game:<old>` never substitutes for `game:<canonical>`; when both identities are affected, require both keys. Apply recomputes the plan under the mutation transaction and requires the same complete preview, set, state and revisions. Missing/stale revisions, missing/changed previews or changed state raise `Conflict`; unrelated revision keys and unsupported fields raise `InvalidInput`. Lookup, validation and persistence errors also propagate without partial changes.

Non-previewed game/release metadata corrections and creation under an existing game cover the active game, its retained identities and all its releases; `.scope` supplies their revisions. Creating a release advances that existing scope and returns the new release and media too. Standalone game/media creation requires an empty revision hash. Existing imported records start at revision 0; new authored records at 1. Every affected record advances once per mutation. These counters differ from release `revision` text and `startup.revision`.

The result contains `{audit_id, records}` with committed states and revisions for every affected record, including raw retained identities. Previewed operations additionally return the matched `preview`. Retry with the same key, operation, attributes, expected revisions, reason **and supplied preview** to receive the exact saved committed result, even after revisions advance or grouping changes. Hash key order is immaterial; array order matters. A changed request with the same key conflicts. Concurrent retries serialize on the unique key, producing one mutation and one audit. Validation, revision, preview or persistence failure rolls back relationships, retry record and audit together; a failed key can be retried after fixing the request. A missing admin name raises `MissingAdminName` before any write or replay.

Each committed `CatalogMutation` stores the admin display name, UTC timestamp, operation, reason, before/after raw state of every affected record and the saved result (including matched preview where required). New records have a null before-state. `.history(limit: 25, before_id: nil)` returns newest entries with `id`, `operation`, `admin_name`, `created_at`, `reason`, `record_changes` (`before`/`after`). The maximum is **100 entries per read**; use the oldest returned ID as `before_id` for the next page. Original entries and saved results remain retained. Compensation is a new correction/reassignment or explicit `restore_game` for a merge, using desired values, a new reason/key, **current** affected revisions and a fresh preview where required. It is validated and audited normally and preserves original audits, provenance, stable IDs and release-scoped evidence. No account, permission or extra approval framework is introduced.

Grouping/restoration preserves screenshots, stored images and recorded image licences on stable release IDs and recomputes selected game screenshots on both sides. Public corrections refresh release ETags and Last-Modified values on both sides and for releases containing edited shared media, including shared-media representations. Lookup redirects, unknown checksums and direct-release ambiguity follow current membership. Title, label and checksum-metadata corrections leave `startup.revision` unchanged; effective startup and ordered checksums determine it. With `User-Agent: Arcadary/1.0`, an old ETag receives updated `200` content and the new ETag receives `304` for resources still resolvable. Already cached responses can remain until their TTL expires: **300 seconds for resources and one day for lookup redirects**. No early CDN eviction is promised. Reads remain anonymous and caller-independent.

A supported reimport preserves the authored controller profile, evidence, authored-state tracking and stable release identity; an import making its edition binding incompatible fails before writes.

### Offline manual metadata imports

Run these local-file operations with exclusive operator access, against the intended Rails database. Configure `CATALOG_ADMIN_NAME` before applying. Inputs are UTF-8 JSON metadata, with one operation envelope per file; no SQL, game-file bytes, filenames from a player's device or batch transaction language is accepted. The operation/attribute allow-lists and startup schema above apply unchanged.

```bash
mise exec -- bin/rails 'catalog:preview[storage/proposal.json]' > storage/preview.json
mise exec -- bin/rails 'catalog:apply[storage/operation.json]'
```

For previewed operations, `proposal.json` contains only `operation` and `attributes`, for example `{"operation":"merge_games","attributes":{"id":"example-old","into_game_id":"example-current"}}`. Preview supports reassignment, merge, restore, `correct_media` and `correct_release` with `media`. It returns the complete bounded preview described above, writes nothing and needs no admin-name setting. Construct the apply envelope from that saved result with an offline Rails read:

```bash
mise exec -- bin/rails runner 'p = JSON.parse(File.read("storage/preview.json", encoding: "UTF-8")); e = p.slice("operation", "attributes", "expected_revisions").merge("preview" => p, "reason" => "Reviewed duplicate identity", "idempotency_key" => "merge-example-1"); File.write("storage/operation.json", JSON.pretty_generate(e))'
```

Review the complete preview before apply. Apply requires its exact unchanged content and revisions; it never substitutes a fresh preview. If state changes, obtain and review a new preview, then build a new envelope. The top-level apply fields are `operation`, `attributes`, `expected_revisions`, `reason`, `idempotency_key`, plus complete `preview` where required. Standalone `create_game` and `create_media` require `expected_revisions: {}` and no preview. For example:

```json
{"operation":"create_game","attributes":{"id":"example","title":"Example","title_aliases":["Alternate title"]},"expected_revisions":{},"reason":"Reviewed catalog addition","idempotency_key":"create-example-1"}
```

For non-previewed `correct_game`, `create_release` and `correct_release` without media, read the complete existing game scope and turn every returned record into an exact revision key. This works with an old ID after chained merges: scope includes the active game, every retained identity resolving to it, and all its releases. These commands need no MCP connection:

```bash
mise exec -- bin/rails runner 's = CatalogAuthoringReadService.scope(game_id: "example"); puts JSON.pretty_generate(s)' > storage/scope.json
mise exec -- bin/rails runner 's = JSON.parse(File.read("storage/scope.json", encoding: "UTF-8")); r = s.to_h { |v| ["#{v.fetch("type")}:#{v.fetch("id")}", v.fetch("authoring_revision")] }; e = {operation: "correct_game", attributes: {id: "example", title: "Reviewed title"}, expected_revisions: r, reason: "Reviewed title correction", idempotency_key: "title-example-1"}; File.write("storage/operation.json", JSON.pretty_generate(e))'
mise exec -- bin/rails 'catalog:apply[storage/operation.json]'
```

Use the same scope-to-revisions conversion for `create_release`, with attributes such as `{"game_id":"example","system":"gb","media":[{"key":"main","position":1,"role":"game","sha1":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}`. The checksum must be new. For a `correct_release` without media, first read its current game ID rather than assuming an old assignment:

```bash
mise exec -- bin/rails runner 'r = CatalogAuthoringReadService.release(id: "example-release-id"); s = CatalogAuthoringReadService.scope(game_id: r.fetch("canonical").fetch("game_id")); puts JSON.pretty_generate(s)' > storage/scope.json
```

Convert that scope using the same `to_h` expression, and set `operation: "correct_release"`, `attributes: {id: "example-release-id", region: "Europe"}` with a new reason/key. Every actual game/release key is required, including retained identities; there is no need to guess keys or replace old IDs manually. Refresh the scope after any intervening mutation or reference-source change.

Successful apply prints the same committed `{audit_id, records}` result as direct authoring, with `preview` for previewed operations. Failures print JSON containing `failed` and `error` to stderr and exit nonzero. Invalid envelopes, stale revisions/previews, domain validation and persistence failures leave no partial writes or success audit. Each envelope is one atomic mutation; a sequence of files has no enclosing transaction. Retrying an exactly committed envelope returns its saved result even after revisions advance; changing any request content while reusing its key conflicts. Reference imports instead commit one whole system at a time and retry by re-running source inputs, without authoring retry keys or correction audits. Both retain their independent failure boundaries.

## Uploads

Screenshots and playthrough videos reach the service in six steps, whatever their type. The Uploads technical reference in the corpus, the project's Uberblick workspace, has the flow diagram, the states and the error codes; this section covers what the code does.

1. The admin agent picks the files and their release.
2. MCP `request_upload(type:)`, with `type` `screenshot` or `video`, creates an upload and answers `upload_id`, `upload_url`, `expires_at` (24 hours later) and the type's limits. Only MCP creates uploads, and only once storage is configured (otherwise `uploads_disabled`).
3. `PUT /v1/uploads/{upload_id}/files/{name}` sends one file as the raw body, with its `Content-Type` and its SHA-256 in `Content-Digest` (`sha-256=:BASE64:`). `name` is the file's package-relative path, such as `low/segment-0001.ts`. `GET /v1/uploads/{upload_id}.json` lists what has arrived, so an interrupted upload resumes by sending the rest. Sending a stored name again with the same digest changes nothing; a different digest is a conflict.
4. Each file is checked on arrival: its digest and size, and that it looks like its type (a PNG signature; `#EXTM3U`, transport-stream sync bytes or `WEBVTT` for a video). A file that fails is not stored.
5. MCP `confirm_upload(upload_id:)` closes the upload and answers `checking`; `UploadCheckJob` then checks it as a whole in the background: exactly one PNG, or an HLS package whose playlists, segments and chapters agree (`PlaythroughHlsService`), which it then copies to the private bucket. Calling `confirm_upload` again reports `confirmed`, or `rejected` with `rejection_reason` (`too_many_files`, `invalid_hls`), whose files are deleted. If the check cannot finish, for example because storage fails, the upload goes back to `receiving` and can be confirmed again.
6. MCP `upload_screenshot(upload_id:, release_id:, kind:)` or `upload_video(upload_id:, release_id:, source_sha1:, capture:, verification:)` turns a confirmed upload into its record and uses the upload up. `upload_screenshot` decodes the PNG against the release system's limits (`upload_rejected` when it doesn't fit) and stores it in the public media bucket. A failure leaves the upload confirmed, to try again before it expires.

| Type | Per file | Per upload |
| --- | --- | --- |
| `screenshot` | one PNG, at most 1 MiB | one file |
| `video` | at most 8 MiB, `application/vnd.apple.mpegurl`, `video/mp2t` or `text/vtt` | at most 2 GiB in 4,096 files |

All stored uploads together stay within 10 GB; past that, a file is refused with `507 uploads_full` until uploads expire or are used.

Uploads wait on the service host's own disk (`config.x.uploads_root`; in production the `arcadary_service_uploads` Docker volume at `/rails/uploads`), never on the volume that holds the databases. A rejected upload's files are deleted at once, a used upload's once its record exists, and `UploadCleanupJob` deletes every expired upload hourly, with any folder a crash left behind and the private copy of a video nobody used.

A playthrough is private: its package is in the private bucket under `playthroughs/{id}/`, where `id` is the upload's, and `upload_video` records the release, the capture provenance (`tool`, `version`, `captured_at`), the files and the validated media (duration, codecs, chapters). Nothing publishes it. `source_sha1` must be one of the release's media, unless `verification` attests that the captured file differs from a release medium: `trailing_padding` with `removed_bytes`, or `verified_equivalence`, verified by the admin, with evidence naming exactly both checksums. The [owner decision](https://github.com/arcadary/service/issues/45#issuecomment-7230746970) permits these authenticated private uploads, including the private Donkey Kong trial; commercial footage stays out of public distribution, and the catalog and screenshot licences grant no video rights.

## Screenshots

Screenshots arrive through the [upload flow](#uploads): a `screenshot` upload of one PNG of at most 1 MiB, then `upload_screenshot(upload_id:, release_id:, kind:)` with the release's stable id and `title` or `gameplay`.

Dimensions must be positive and within these fixed capture ceilings, regardless of crop, overscan, borders or interlace. Byte and dimension checks happen before decoded pixels are allocated, then the image is fully decoded and re-encoded as a pixel-only PNG. Stored dimensions and SHA-256 are measured from that image.

| System | Maximum width | Maximum height |
| --- | ---: | ---: |
| nes | 1024 | 960 |
| snes | 2048 | 1912 |
| gb | 640 | 576 |
| gbc | 640 | 576 |
| megadrive | 1280 | 1920 |
| pcengine | 2048 | 960 |
| atari2600 | 640 | 768 |
| c64 | 1536 | 1088 |

Each release has at most one screenshot per kind. Successful uploads replace it; rejected or failed uploads retain the previous record, stored bytes and API references. Release JSON, including each release inside a media response, has `release.screenshots` ordered title then gameplay, empty when absent. Its embedded `game.screenshot` chooses the lexicographically smallest stable release `public_id` (the API's `release.id`) among that game's releases with screenshots, preferring that release's gameplay then title image, or `null`. This is a stable total order even when first checksums are equal or media are reordered; it does not recommend a release for playback. Changes invalidate affected release/media ETags, including sibling responses when the selected game picture changes.

Every screenshot is exactly `{kind, url, width, height, licence}`. `url` is the media host (`config.x.media_base_url`) plus `/screenshots/{sha256}.png`, without signed or expiring parameters. That key is the object's key in the public media bucket, which Cloudflare serves at `media.arcadary.org` under its own cache rule; each object carries `Cache-Control: public, max-age=31536000, immutable`. Identical pixels share one object, which is deleted once no screenshot uses it. Rails serves no image bytes, and Active Storage's own routes are disabled.

### Storage configuration

Infrastructure supplies both R2 buckets and one access key for them through fnox; this application never provisions them. Supply `R2_BUCKET` (private, for playthroughs), `R2_PUBLIC_BUCKET` (public, for screenshots), `R2_ENDPOINT` (the S3-compatible endpoint), `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`; the R2 region is `auto`. 

Configured nonempty R2 names pass through Kamal `env.secret` and `.kamal/secrets`; no values are committed, and absent or empty names are left out. Production boots, answers `/up` and serves lookups without them, but `request_upload` answers `uploads_disabled` until all five are set, with no local-storage fallback. Production config names the two services (`:r2` for Active Storage, `config.x.media_service = :r2_media`) and `config.x.media_base_url`, `https://media.arcadary.org`; development and test use local disk services for both. Specs use local test storage, never R2. Local decoder checks require libvips; CI and Docker install it.

Before public launch the deployment owner must verify Cloudflare CDN purging, access-log suppression at every delivery layer for both image reads and uploads, and that `takedown@arcadary.org` accepts mail and forwards to a monitored inbox. These are launch prerequisites, not claims that provisioning or verification has happened.

## Private service authentication

`PrivateServiceAuthentication` is the shared single-admin HTTP Basic guard. The private catalog MCP endpoint at `/mcp`, the upload routes under `/v1/uploads`, and their entire subtrees use it. It does not create accounts. The read tools, the upload tools, protocol versions, the Codex configured-header example and required hosted checks are documented in [Private catalog MCP](docs/mcp.md).

The guard reads `VALIDATION_REVIEWER_USERNAME` and `VALIDATION_REVIEWER_PASSWORD` from the Rails process environment on every protected request. Supply both through fnox, with no defaults: `fnox set VALIDATION_REVIEWER_USERNAME` and `fnox set VALIDATION_REVIEWER_PASSWORD` prompt with hidden input, and Kamal forwards both to the web container (`.kamal/secrets`, `config/deploy.yml`). Placeholder configuration is `VALIDATION_REVIEWER_USERNAME=<admin-username>` and `VALIDATION_REVIEWER_PASSWORD=<long-random-password>`; use a username without a colon. Either missing or blank returns `503 {"error":"authentication_unavailable"}` before controller work. Missing, malformed or invalid Basic credentials return `401 {"error":"unauthorized"}` with a Basic challenge. Both credentials are compared as fixed-length SHA-256 digests in constant time. There is no remembered successful authentication or session.

To adopt the guard, add the consumer's complete private path subtree to `config.x.private_service_paths` in `config/application.rb`, for example `config.x.private_service_paths = [ %r{\A/private-admin(?:/|\z)} ]` (illustrative only; no such route exists). Matchers see decoded paths with repeated slashes collapsed. The guard wraps every HTTP method on matching paths before Rails host checks and `Rails::Rack::Logger`, authenticates before controller callbacks or request-body parsing, suppresses application logs including exceptions, disables detailed exception responses, and sets `Cache-Control: no-store` on successes and errors. HTML controllers can inherit `ApplicationController` and JSON controllers `ApiController`; add request coverage for every consumer's paths, errors and headers. Keep anonymous reads outside these matchers.

For rotation, the owner replaces both values through fnox and makes the replacement environment available to every Rails worker through the normal release/restart process. Changing fnox alone does not modify an already-running process's environment. Once replaced, the next request rejects the old pair and accepts the new one; clients must supply credentials on every request. Never put real values in documentation, commands saved in history, logs or git. The isolated request harness uses disposable credentials only.

Hosted Basic authentication **requires TLS**. Production retains `assume_ssl` and `force_ssl`; trust forwarded scheme headers only from the TLS-terminating proxy. Before enabling any hosted consumer, the maintainer must verify TLS, exclude its entire private subtree from proxy/CDN shared caches (including errors), and disable Authorization-header, credential and request-body logging at every proxy/CDN/application layer. The application tests cannot verify hosted infrastructure. This issue makes no live fnox, deployment or proxy configuration change; consumers must arrange environment delivery to their Rails workers when enabled.

## Privacy and logging

Checksum reads are anonymous, but they reveal which file a household has and the caller's IP address to the service and CDN. Screenshot URLs likewise identify releases, and the service/CDN see image callers' IPs. No player account or session is required; the endpoints set no cookie. This does not make reads private. Authentication and upload responses are never shared-cacheable.

Rails silences lookup and release/media requests before request-start logging, covering parameter, controller and SQL logs, including paths with repeated slashes and handled failures. SHA-1, SHA-256 and authorization parameters are filtered defensively. Captured application-log specs cover client IPs and release SHA-1s. Routing errors (for example, a missing suffix) can still log the identifying URL at error level, without the client IP. These routes add no telemetry or request-specific log lines. The production image sets `LOG_REQUESTS=false` to disable Thruster's access logs, which otherwise pair identifying URLs with client IPs. Keep that setting disabled, including any `THRUSTER_LOG_REQUESTS` override.

The Basic guard separately silences the complete `/mcp` and `/v1/uploads` subtrees, including routing/authentication/application errors, before Rails request logging. Captured-log specs cover upload ids, tool arguments and credentials. Upload and release ids are also filtered defensively. Hosted cache/log exclusions must cover these entire protected paths. Private playthroughs are never cacheable or included in public JSON; anonymous reads remain caller-independent.

The specs check Rails logs only; the rest was checked on the deployed host. kamal-proxy runs with Docker's `none` log driver and keeps no request log, because that log records `X-Forwarded-For`, which Cloudflare always fills with the visitor's IP, next to each path and so each checksum. Cloudflare's "Remove visitor IP headers" transform does not change that header for ordinary visitors. `cloudflared` logs no per-request lines at its default level. Check these again whenever the proxy, the tunnel or the image changes. Cloudflare itself still sees every visitor's IP.

## Deployment

Production is one Hetzner host behind Cloudflare, created by the infrastructure repository, and the service answers on `api.arcadary.org`. Kamal builds the image locally for amd64 and moves it to the host through its local registry, so no registry account is needed. fnox supplies the host's address (`DEPLOY_HOST`), `SECRET_KEY_BASE`, the tunnel's token (`TUNNEL_TOKEN`) and the shared admin login (see [Private service authentication](#private-service-authentication)). Every push to `main` deploys itself (see [Automatic deploys](#automatic-deploys)). By hand, the owner deploys, or an agent once the owner has confirmed that deploy:

```bash
fnox exec -- bin/kamal setup    # the first time: installs Docker, boots cloudflared and kamal-proxy, then deploys
fnox exec -- bin/kamal deploy   # every time after
```

Cloudflare terminates TLS. It reaches the origin only through a Cloudflare Tunnel, which the infrastructure repository creates: `cloudflared` runs on the host as a Kamal accessory, dials out to Cloudflare and hands each request to kamal-proxy in plain HTTP on Docker's `kamal` network. kamal-proxy publishes no ports on the host, the host's firewall has no web ports open, and the origin holds no certificate. The tunnel's token is a sensitive output of the infrastructure repository; pipe it into fnox without printing it (`fnox set TUNNEL_TOKEN` reads stdin). `bin/kamal accessory reboot cloudflared` picks up a new token or image.

### Automatic deploys

`bin/auto-deploy` runs on the owner's Mac every five minutes as a launchd agent. It fetches `main` into its own clone (`~/.local/state/arcadary-auto-deploy/service`), so the shared checkout's branch never matters. Once the `scan_ruby`, `scan_js`, `lint` and `test` checks, and every other check, have passed at that commit, it runs `fnox exec -- bin/kamal deploy --lock-wait` from the clone. That waits for a deploy already running and stops when someone has locked deploys by hand (`bin/kamal lock acquire`). A commit whose CI or deploy fails is skipped until `main` moves again or `bin/auto-deploy retry` runs. Each deploy or failure posts a macOS notification. The output, with the host's address and the secrets replaced by their names, goes to `~/Library/Logs/arcadary-auto-deploy.log`.

```bash
bin/auto-deploy install     # once, and again after bin/auto-deploy changes: starts the launchd agent
bin/auto-deploy retry       # deploys main again after a failure
bin/auto-deploy uninstall   # stops automatic deploys and removes the clone
```

It deploys only while the Mac is awake and Docker is running. Anything merged in the meantime goes out at the next check. It runs whatever `main` holds, with the owner's SSH and age keys, including `bin/kamal`, the `.kamal/` hooks and the gems in `Gemfile.lock`, and nobody looks first: a merge into `main` is a release.

## Licence

Code: MIT, see [LICENSE](LICENSE). Catalog metadata: CC-BY-SA-4.0, see [LICENSE-DATA](LICENSE-DATA). Screenshot images and all video are excluded from that licence; each medium's own rights apply. Catalog and screenshot licences grant no video rights. Image credits and upstream notices are in [Screenshots](#screenshots).
