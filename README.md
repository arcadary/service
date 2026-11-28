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

The catalog originates from [No-Intro](https://no-intro.org/), sourced through [libretro-database at f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029](https://github.com/libretro/libretro-database/tree/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/metadat/no-intro). We import checksum metadata, group releases into games, normalize titles/regions/revisions and apply the launcher's explicit identity mappings. The entire service catalog, including project corrections, additions and later metadata fields, is licensed under [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/); see [LICENSE-DATA](LICENSE-DATA). Screenshot images and all video are excluded: each medium's own rights apply. Catalog and screenshot licences grant no video rights. The source's [licence at the pin](https://github.com/libretro/libretro-database/blob/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/LICENSE) is CC-BY-SA-4.0. Code remains MIT.

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

Existing checksum associations and public IDs take precedence: a conflicting curated mapping fails its system rather than moving a release or merging games. Unmapped releases group only with fallback/seed identities in the same system. They never join curated identities by title. A fallback key is the DAT game name with recognized region/revision parentheses removed, normalized to Unicode NFC, whitespace collapsed to one ASCII space and ends trimmed. Case, punctuation and all other annotations remain significant. The exact stored key encoding is compact UTF-8 JSON `[system, normalized_name]`, with no extra whitespace (`JSON.generate`). Its unique alias is persisted; title corrections add aliases without changing assigned IDs or forgetting earlier aliases. Aliases pointing at different games and public-ID collisions fail the system.

A new fallback ID is `<system>-<slug>-<sha256>`: slug is the display title lowercased, each run outside ASCII `a-z0-9` replaced with `-`, leading/trailing `-` removed, or `game` when empty; suffix is the full lowercase SHA-256 of the exact encoded key. Distinct keys therefore stay distinct even if display titles or slugs coincide. There is no fuzzy matching or inferred cross-system grouping.

Display titles remove all parenthesized metadata annotations, then apply NFC and whitespace normalization. Each fallback/seed game's title is the smallest display title across **all** its persisted releases in lexicographic UTF-8 byte order, including releases absent from later lists. Each release retains its DAT source title; importing a seed replaces its initial title contribution. Partial corrections recompute from the complete associated set. Curated titles take precedence.

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

`CatalogAuthoringService.call(operation:, attributes:, expected_revisions:, reason:, idempotency_key:, preview: nil)` is the shared database write contract for future MCP, reviewer and manual-import adapters. It has no HTTP endpoint or UI. Each call requires a nonblank reason and retry key. Configure `CATALOG_ADMIN_NAME` with the single admin's display name as a non-credential environment setting; a missing or blank name fails closed before any write or replay. Never derive it from an HTTP Basic username, token or other credential. Reasons and metadata must contain no credentials or household/device identifiers.

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

`authored_fields` names fields explicitly set by authoring, including creation fields; changing an affected record's revision alone marks no new fields authored. `source` exposes retained `source_title` for games and releases, plus `source_system`, `source_region`, `source_revision` for releases, separately from corrected values. Absent source values are null. Authoring never overwrites source provenance. New authored records have no invented provenance.

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

Reference-import precedence and the manual-import adapter remain #41's work. A supported reimport preserves the authored controller profile, evidence, authored-state tracking and stable release identity; an import making its edition binding incompatible fails before writes. This does not expand supported inputs or solve broader precedence. **Bootstrap reference imports must not run after any merge**, even if a later restore has reactivated an identity: the current importer can retitle or attach releases to a retired identity. Reference imports must also not overwrite other authored fields pending #41. Its importer must retain original key ownership, resolve canonical targets and never reclaim retired identities. Future adapters reuse this contract; no adapter, new reference source or game-file handling is included here.

## Private playthrough staging

The [owner decision](https://github.com/arcadary/service/issues/45#issuecomment-7230746970) permits authenticated private HLS staging and delivery, including the private Donkey Kong trial. Commercial footage must stay out of public distribution and anonymous responses. Catalog and screenshot licences grant no video rights; all video is excluded from the catalog licence. Staging accepts synthetic or rights-cleared rendered package objects, never game files. It exposes no staged bytes, playback, storage redirects or direct-upload capabilities.

All three endpoints use the [shared admin HTTP Basic guard](#private-service-authentication) on every request, before parsing or body reads, and return `Cache-Control: no-store` without cookies. The complete `/v1/playthrough-stages` subtree, including authentication, parsing, integrity, storage and routing failures, is excluded from application logs. Hosted TLS, cache exclusions and access/body/header/tracing exclusions remain deployment-owner checks in #57; this implementation makes no deployment change.

`POST /v1/playthrough-stages.json` takes a strict JSON declaration. `release_id` is the release's stable `public_id`, never its title or mutable first-medium checksum. An exact `source_sha1` must be a medium of that release, including a secondary or shared medium with this explicit release target. Capture provenance requires nonblank tool and version and a timezone-qualified ISO 8601 capture time. SHA-1s are lowercase. This synthetic example declares one object:

```json
{
  "retry_key": "synthetic-capture-1",
  "release_id": "stable-release-public-id",
  "source_sha1": "0000000000000000000000000000000000000001",
  "capture": {"tool": "synthetic-capture", "version": "1", "captured_at": "2026-11-28T08:00:00Z"},
  "manifest": [{"path": "video/segment.ts", "byte_size": 1, "sha256": "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881", "content_type": "video/mp2t"}]
}
```

When the source is not a release medium, a single `verification` object is required. It contains `source_sha1` matching the declaration, distinct `payload_sha1` belonging to that release, `relationship` (`trailing_padding` or `verified_equivalence`), nonblank `method`, `result: "success"`, `verifier` equal to the authenticated admin username, timezone-qualified `verified_at`, and nonblank textual `evidence` naming exactly those two checksums with no other checksum proposals. `trailing_padding` additionally requires a positive integer `removed_bytes`; preserve the trial's 127 bytes when verified. Other relationships omit that field. The verifier performs byte-level verification offline; the service checks the attestation and catalog membership without receiving game bytes. Source and payload remain distinct retained facts. Missing/blank evidence, contradictory pairs, unknown/duplicate fields, multiple targets or mappings, and nonmember payloads are refused. The service does not infer title matches or a launcher checksum. The real Donkey Kong checksums, offline mapping and launcher confirmation remain attachment/trial gates in #57, not implementation or closure prerequisites.

Each manifest entry requires a unique package-relative `path`, positive integer `byte_size`, lowercase SHA-256 `sha256` and exact MIME `content_type` without parameters. Absolute paths, URLs, traversal, empty/dot path components, whitespace, backslashes, colon, percent, query/fragment and control characters are rejected. Package identity is SHA-256 of UTF-8 compact JSON containing `[path, byte_size, sha256, content_type]` arrays sorted bytewise by path, without insignificant whitespace. The durable declaration normalizes manifest ordering, JSON object keys and timestamp offsets to UTC microseconds. An identical normalized declaration with the same `retry_key` returns the original stage and current progress (`201`); changing its release, capture evidence or manifest returns `409 stage_conflict`. Retry keys have at most 200 characters. Replays do not add object rows or package accounting.

The declaration result contains `staging_id`, `package_sha256`, the normalized `declaration`, `state` and `objects`, each with an opaque `object_id`, declared `path` and `received` boolean. `GET /v1/playthrough-stages/{staging_id}.json` returns that same authenticated metadata. Transfer raw bytes with `PUT /v1/playthrough-stages/{staging_id}/objects/{object_id}.json` and the exact declared `Content-Type`. The stage and declared object must both match; actual size and SHA-256 are checked before storage, even for successful retries. Success returns an immutable `{object_id, received_at}` receipt; identical retries return the same receipt even after other objects finish. Changed bytes, size or content type return `409 stage_conflict`. The object becomes complete only after storage success. In metadata, `incomplete` means one or more objects are missing; `received` means all objects are stored, **not HLS-validated or published**.

Ceilings are **1 MiB (1,048,576 bytes)** per declaration, **4,096 objects**, **8 MiB (8,388,608 bytes)** per object and **4 GiB (4,294,967,296 bytes)** summed declared package size. Actual reads are bounded, including missing or dishonest `Content-Length`. The per-object limit is below Cloudflare's [documented 100 MB minimum plan upload limit](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/#upload-limits); the actual zone Maximum Upload Size can be lower and must be checked by the deployment owner in #57, along with transfer timeouts.

Storage reuses private R2/Active Storage configuration; production fails closed on incomplete R2 configuration, independently of screenshot bearer-token/public-image-base settings. Tests use local private storage. Each attempt gets a fresh private key under its stage/object IDs; no accepted object or other stage can be overwritten. Interrupted reads or storage failures leave declaration and completed objects durable, the affected object incomplete and retryable after restart. Database writes are bounded and storage runs outside transactions. Failed attempts try to remove only their own blob; a crash or failed deletion can retain an unreferenced blob with its stage/object key for future cleanup. No expiry or automatic playthrough cleanup is introduced here. HLS validation, rendition interpretation, publication and safe cleanup belong to #56; private delivery and hosted/launcher trial verification belong to #57. Existing screenshots, public lookup/release/media JSON and validators are unchanged.

Errors use the standard JSON envelope: `400 invalid_declaration` or `interrupted_transfer`, `401 unauthorized`, `404 not_found`, `409 target_mismatch` or `stage_conflict`, `413 stage_too_large`, and `503 authentication_unavailable` or `storage_unavailable`. `/api-docs` documents each endpoint and its schemas. No game-file names or bytes are part of declarations or verification.

## Screenshots

The owner's capture device sends a raw `image/png` body to `PUT /v1/releases/{sha1}/screenshots/{kind}.json` with `Authorization: Bearer <token>`, where kind is `title` or `gameplay`. A secondary-medium checksum targets its containing release. A shared checksum returns `409 ambiguous_release` without changing an image. Authentication runs before decoding or storage. Unset/empty token or incomplete production configuration returns `503`; missing/wrong credentials when enabled return `401`. Unknown releases return `404`, malformed SHA-1 `400`, input over 8 MiB (8,388,608 bytes) `413`, and invalid kinds, malformed/non-PNG/animated input or excessive dimensions `422`. All upload responses are `no-store`. `/api-docs` specifies the route and schemas.

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

Every screenshot is exactly `{kind, url, width, height, licence}`. `url` is absolute HTTPS, built from `SCREENSHOT_PUBLIC_BASE_URL` plus `/v1/screenshots/{sha256}.png`, independent of request headers, without expiring/signed parameters. The anonymous Rails-origin route serves stored PNG bytes with `Content-Type: image/png` and `Cache-Control: public, max-age=31536000`. Missing or unreferenced images return `404` with `no-store`. Images are in private R2 storage through Active Storage's S3 adapter; JSON never exposes bucket URLs or Active Storage signed URLs, and Active Storage's built-in delivery/upload routes are disabled.

### Private staging and MCP publication

The admin can stage raw PNG bytes with `POST /v1/screenshot-stages/{release_id}/{source_sha1}/{kind}.json`, `Content-Type: image/png` and the [shared HTTP Basic credentials](#private-service-authentication). `release_id` is the stable release public ID, not its first checksum; `source_sha1` must identify an exact medium currently belonging to that release. Secondary media are valid, and shared checksums require the explicit matching release. Kind is `title` or `gameplay`. Authentication, configuration and target checks precede PNG processing. Staging uses the capture byte/dimension limits, full validation and pixel re-encoding above, without requiring `SCREENSHOT_CAPTURE_TOKEN`.

Success returns `201 {"staging_id":"opaque-id","expires_at":"UTC timestamp"}`. Expiry is exactly 24 hours after successful ingest. The private record and canonical blob survive requests/restarts; staging changes no screenshot, anonymous JSON, validator or public PNG availability. There is no anonymous stage metadata, read or storage-redirect route. Knowing its PNG hash cannot make an unpublished stage publicly readable; an already published copy of identical pixels remains normally available. Ingest errors are `400 invalid_input`, `401 unauthorized`, `404 not_found`, `409 target_mismatch`, `413 screenshot_too_large`, `422 invalid_screenshot`, or `503 authentication_unavailable`, `uploads_disabled` or `storage_unavailable`. Failed ingest purges its upload.

Call the authenticated MCP tool `publish_screenshot` with `staging_id`, `release_id`, `source_sha1` and `kind`. It accepts only IDs issued by this ingest, verifies the exact binding and current checksum membership again, and returns `{data: {release_id, screenshot}}` with the published screenshot object above. It uses the game's image licence **at publication**, the existing replacement/game-picture rules, validator invalidation and content-addressed delivery. Validation or storage failure leaves the previous image intact. See [Private catalog MCP](docs/mcp.md#screenshot-publication) for schemas and error codes.

The first success atomically consumes the ID and transfers its canonical blob to the screenshot without a second staging copy. Until the original expiry, repeated successful-target calls return `staged_image_consumed`, even after that screenshot is replaced or removed. At expiry the ID is `staged_image_unavailable`, independently of cleanup timing. IDs are never reused. Failed publication is retryable with the same binding before expiry; neither reads nor failed attempts extend expiry. There is no discard API.

Solid Queue's recurring scheduler runs `ScreenshotStageCleanupJob` every hour in production. Each pass handles at most 100 expired stages/consumed receipts and queues continuation when more remain. Unconsumed bytes are deleted outside database transactions; failed deletions retain their expired records for the next hourly retry while cleanup continues through later records. Consumed receipts hold no blob and cleanup never deletes transferred screenshot bytes. A storage upload failure returns `storage_unavailable` and cleans up its private blob. If deletion also fails, cleanup retains the blob record and queues hourly retries until deletion succeeds. Run the Solid Queue workers **and recurring scheduler** for automatic cleanup.

Every staging and publication response, including errors, is `no-store`. The complete `/v1/screenshot-stages` subtree and `/mcp` subtree authenticate before request processing and are silenced before the Rails logger. Before hosted access, exclude both complete subtrees, all methods and errors from proxy/CDN caches, access/body/header logs, tracing and identifying analytics, including normalized repeated-slash/encoded equivalents. These are operator checks, not a claim of deployed verification.

Remove a screenshot by stable release public ID and kind, never by a possibly shared checksum:

```bash
mise exec -- bin/rails 'screenshots:remove[RELEASE_PUBLIC_ID,gameplay]'
```

Removal and replacement stop origin delivery at the old URL as soon as the last screenshot with those bytes is unreferenced. Active Storage purge jobs then delete the old blobs; Solid Queue must run to complete storage cleanup. Identical bytes referenced by another screenshot remain available. For takedown requests contact **takedown@arcadary.org**. Origin deletion cannot erase CDN or client cached copies; the deployment owner must purge the affected content-addressed URL at Cloudflare.

`Game.screenshot_licence` defaults to `""` for imported/commercial games and survives catalog reimports. Seeds set the following image licences, including on existing games/releases. Uploads copy the game value and cannot supply a licence. An upload grants no new rights; an empty string grants no image licence. Launchers can attribute using `game.id` and the image's public `licence`, together with these image credits:

| Game ID | Image credit | Image licence and source |
| --- | --- | --- |
| `ucity` | µCity graphics by AntonioND/SkyLyrac (Antonio Niño Díaz) | [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/), [upstream v1.3 notice](https://github.com/AntonioND/ucity/blob/v1.3/readme.rst#license) |
| `tobu-tobu-girl` | Tobu Tobu Girl assets by Tangram Games | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/), [upstream notice](https://github.com/SimonLarsen/tobutobugirl/blob/048a22c2d7ebbe25811322e8692803fa86bb643a/README.md#license) |

Arcadary re-encodes captures of both games as pixel-only PNGs and removes metadata. Tobu Tobu Girl's asset licence applies to its screenshots; its source code's MIT licence does not license the images.

### Screenshot configuration

Infrastructure supplies the private R2 bucket and credentials through fnox; this application never provisions them. Supply `R2_BUCKET`, `R2_ENDPOINT` (the S3-compatible endpoint), `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `SCREENSHOT_CAPTURE_TOKEN` and `SCREENSHOT_PUBLIC_BASE_URL` (an HTTPS origin without a path, query, fragment or credentials). The R2 region is `auto`.

Configured nonempty R2 names and the capture token pass through Kamal `env.secret` and `.kamal/secrets`; the public origin passes through `env.clear`. No values are committed. Absent/empty secret names are omitted from resolved container declarations and values; an absent public base URL is empty. Production boots, answers `/up` and serves existing lookups without these six variables. Missing/malformed public-base configuration or incomplete production R2 configuration disables capture, staging and MCP publication with `503 uploads_disabled`, with no local-storage fallback. A missing capture token disables only capture. Staging/publication use the shared Basic credentials instead. Specs use local test storage, never R2. Local decoder checks require libvips; CI and Docker install it.

Before public launch the deployment owner must verify Cloudflare CDN purging, access-log suppression at every delivery layer for both image reads and uploads, and that `takedown@arcadary.org` accepts mail and forwards to a monitored inbox. These are launch prerequisites, not claims that provisioning or verification has happened.

## Private service authentication

`PrivateServiceAuthentication` is the shared single-admin HTTP Basic guard. The private catalog MCP endpoint at `/mcp`, screenshot ingest at `/v1/screenshot-stages`, and their entire subtrees use it; review/download adoption belongs to #27. It does not create accounts or replace the capture device's bearer token. The four bounded read tools, screenshot publication tool, protocol versions, Codex configured-header example and required hosted checks are documented in [Private catalog MCP](docs/mcp.md).

The guard reads `VALIDATION_REVIEWER_USERNAME` and `VALIDATION_REVIEWER_PASSWORD` from the Rails process environment on every protected request. Supply both through fnox, with no defaults. Placeholder configuration is `VALIDATION_REVIEWER_USERNAME=<admin-username>` and `VALIDATION_REVIEWER_PASSWORD=<long-random-password>`; use a username without a colon. Either missing or blank returns `503 {"error":"authentication_unavailable"}` before controller work. Missing, malformed or invalid Basic credentials return `401 {"error":"unauthorized"}` with a Basic challenge. Both credentials are compared as fixed-length SHA-256 digests in constant time. There is no remembered successful authentication or session.

To adopt the guard, add the consumer's complete private path subtree to `config.x.private_service_paths` in `config/application.rb`, for example `config.x.private_service_paths = [ %r{\A/private-admin(?:/|\z)} ]` (illustrative only; no such route exists). Matchers see decoded paths with repeated slashes collapsed. The guard wraps every HTTP method on matching paths before Rails host checks and `Rails::Rack::Logger`, authenticates before controller callbacks or request-body parsing, suppresses application logs including exceptions, disables detailed exception responses, and sets `Cache-Control: no-store` on successes and errors. HTML controllers can inherit `ApplicationController` and JSON controllers `ApiController`; add request coverage for every consumer's paths, errors and headers. Keep anonymous reads outside these matchers.

For rotation, the owner replaces both values through fnox and makes the replacement environment available to every Rails worker through the normal release/restart process. Changing fnox alone does not modify an already-running process's environment. Once replaced, the next request rejects the old pair and accepts the new one; clients must supply credentials on every request. Never put real values in documentation, commands saved in history, logs or git. The isolated request harness uses disposable credentials only.

Hosted Basic authentication **requires TLS**. Production retains `assume_ssl` and `force_ssl`; trust forwarded scheme headers only from the TLS-terminating proxy. Before enabling any hosted consumer, the maintainer must verify TLS, exclude its entire private subtree from proxy/CDN shared caches (including errors), and disable Authorization-header, credential and request-body logging at every proxy/CDN/application layer. The application tests cannot verify hosted infrastructure. This issue makes no live fnox, deployment or proxy configuration change; consumers must arrange environment delivery to their Rails workers when enabled.

## Privacy and logging

Checksum reads are anonymous, but they reveal which file a household has and the caller's IP address to the service and CDN. Screenshot URLs likewise identify releases, and the service/CDN see image callers' IPs. No player account or session is required; the endpoints set no cookie. This does not make reads private. Authentication and upload responses are never shared-cacheable.

Rails silences lookup, release/media, screenshot-read and capture-upload requests before request-start logging, covering parameter, controller and SQL logs, including paths with repeated slashes and handled failures. SHA-1, SHA-256 and authorization parameters are filtered defensively. Captured application-log specs cover token, client IP, release SHA-1, PNG SHA-256 and body bytes. Routing errors (for example, a missing suffix) can still log the identifying URL at error level, without the client IP. These routes add no telemetry or request-specific log lines. The production image sets `LOG_REQUESTS=false` to disable Thruster's access logs, which otherwise pair identifying URLs with client IPs. Keep that setting disabled, including any `THRUSTER_LOG_REQUESTS` override.

The Basic guard separately silences the complete `/mcp`, `/v1/screenshot-stages` and `/v1/playthrough-stages` subtrees, including routing/authentication/application errors, before Rails request logging. Captured-log specs cover staging bytes, exact source checksums, provenance, publication arguments and credentials. Staging IDs and release IDs are also filtered defensively. Hosted cache/log exclusions must cover these entire protected paths, not only successful POSTs. Private playthrough metadata is authenticated and never cacheable or included in public JSON; anonymous reads remain caller-independent.

The specs check Rails logs only; the rest was checked on the deployed host. kamal-proxy runs with Docker's `none` log driver and keeps no request log, because that log records `X-Forwarded-For`, which Cloudflare always fills with the visitor's IP, next to each path and so each checksum. Cloudflare's "Remove visitor IP headers" transform does not change that header for ordinary visitors. `cloudflared` logs no per-request lines at its default level. Check these again whenever the proxy, the tunnel or the image changes. Cloudflare itself still sees every visitor's IP.

## Deployment

Production is one Hetzner host behind Cloudflare, created by the infrastructure repository, and the service answers on `api.arcadary.org`. Kamal builds the image locally for amd64 and moves it to the host through its local registry, so no registry account is needed. fnox supplies the host's address (`DEPLOY_HOST`), `SECRET_KEY_BASE` and the tunnel's token (`TUNNEL_TOKEN`). The owner deploys, or an agent once the owner has confirmed that deploy:

```bash
fnox exec -- bin/kamal setup    # the first time: installs Docker, boots cloudflared and kamal-proxy, then deploys
fnox exec -- bin/kamal deploy   # every time after
```

Cloudflare terminates TLS. It reaches the origin only through a Cloudflare Tunnel, which the infrastructure repository creates: `cloudflared` runs on the host as a Kamal accessory, dials out to Cloudflare and hands each request to kamal-proxy in plain HTTP on Docker's `kamal` network. kamal-proxy publishes no ports on the host, the host's firewall has no web ports open, and the origin holds no certificate. The tunnel's token is a sensitive output of the infrastructure repository; pipe it into fnox without printing it (`fnox set TUNNEL_TOKEN` reads stdin). `bin/kamal accessory reboot cloudflared` picks up a new token or image.

## Licence

Code: MIT, see [LICENSE](LICENSE). Catalog metadata: CC-BY-SA-4.0, see [LICENSE-DATA](LICENSE-DATA). Screenshot images and all video are excluded from that licence; each medium's own rights apply. Catalog and screenshot licences grant no video rights. Image credits and upstream notices are in [Screenshots](#screenshots).
