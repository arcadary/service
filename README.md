# Arcadary service

The remote service for [Arcadary](https://github.com/arcadary/arcadary): a Rails 8.1 application for the project's homepage and launcher JSON API. `GET /v1/lookup/{sha1}.json` identifies a game file and redirects to its release and game, or to all containing releases for a shared file. The offline catalog importer covers eight pinned No-Intro lists (29,336 distinct checksums); two optional homebrew seeds work without those lists. Compatibility, controller-profile and page features are still to be built. Nothing is deployed.

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

The catalog originates from [No-Intro](https://no-intro.org/), sourced through [libretro-database at f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029](https://github.com/libretro/libretro-database/tree/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/metadat/no-intro). We import checksum metadata, group releases into games, normalize titles/regions/revisions and apply the launcher's explicit identity mappings. The entire service catalog, including project corrections, additions and later metadata fields, is licensed under [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/); see [LICENSE-DATA](LICENSE-DATA). Screenshot images are excluded: their own licence applies. The source's [licence at the pin](https://github.com/libretro/libretro-database/blob/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/LICENSE) is CC-BY-SA-4.0. Code remains MIT.

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

The nullable `releases.startup` JSON uses schema 1: `{"schema":1,"boot":"disk-1","drives":{"8":"disk-1","9":"disk-2"}}`. Every reference is a key in that release. Only C64 has drive slots (`8`, `9`); other systems accept absent or empty drives. A medium occupies at most one slot; boot must be a game medium and, for C64, occupy a slot. Unknown keys, settings, schemas and wrong types are rejected. Null startup boots the first game medium in position order, mounted in C64 slot `8` where applicable. Make coordinated media/startup edits through the release's nested `release_media_attributes`; replace old rows with marked-for-destruction rows and new ordered rows to swap positions without violating the unique indexes. Model validation also rejects individual medium edits or removals that invalidate the release.

`startup.revision` is lower-case SHA-256 of compact UTF-8 JSON with no whitespace: `{"startup":{"schema":1,"boot":"<effective key>","drives":{...}},"media":["<first sha1>","<second sha1>"]}`. Object keys appear in the order shown, drive slots sort lexicographically and media checksums follow position order. Explicit defaults produce the same revision as null startup. Labels, size and format do not affect it; effective startup and ordered checksums do. The launcher can bind resume states to this revision. Media/startup changes also invalidate response ETags.

## Catalog authoring

`CatalogAuthoringService.call(operation:, attributes:, expected_revisions:, reason:, idempotency_key:)` is the shared database write contract for future MCP, reviewer and manual-import adapters. It has no HTTP endpoint or UI. Each call requires a nonblank reason and retry key. Configure `CATALOG_ADMIN_NAME` with the single admin's display name as a non-credential environment setting; a missing or blank name fails closed before any write or replay. Never derive it from an HTTP Basic username, token or other credential. Reasons and metadata must contain no credentials or household/device identifiers.

Operations accept only these creation/correction fields (string or symbol keys); all other fields are rejected:

| Operation | `attributes` |
| --- | --- |
| `create_game` | Required `id` (stable public game ID), `title`; optional `title_aliases` (array of distinct nonblank searchable titles). |
| `create_media` | Required lower-case 40-character `sha1`; optional `size` (nonnegative integer), `format` (lower-case alphanumeric), `crc32` (8 lower-case hex characters), `md5` (32 lower-case hex characters). Only checksum metadata is accepted, never file bytes or names. |
| `create_release` | Required existing `game_id`, `system` and nonempty ordered `media` array; optional `region`, `revision` and `startup`. The release's stable public ID is generated. Each medium requires `key`, consecutive `position` from 1, `role` (`game` or `save`) and a **new** `sha1`; optional `label` and the initial metadata fields from `create_media` are accepted. No existing checksum may be attached, including one created separately through `create_media`. |
| `correct_game` | Required `id`; one or more of `title`, `title_aliases`. The alias array replaces the previous aliases. |
| `correct_release` | Required stable release `id`; one or more of `system`, `region`, `revision`, `startup`. `region` and release `revision` may be null. `startup` replaces the whole configuration or may be null for system defaults. |

All startup writes use the existing [schema, medium keys and defaults](#ordered-media-and-startup). A system and startup correction is validated together against the resulting system's drive slots and existing media keys. Existing media sets, labels and media metadata cannot be corrected here. Public game/release IDs, media checksums, source fields and importer `GameIdentity` keys cannot be corrected through these operations.

`CatalogAuthoringReadService.game(id:)`, `.release(id:)` and `.media(sha1:)` return internal records shaped as `{type, id, authoring_revision, canonical, authored_fields, source}`. `canonical` holds effective values: games include `title` and `title_aliases`; releases include `game_id`, `system`, `region`, release `revision`, ordered media metadata and effective startup with `startup.revision`; media include checksums and metadata. `authored_fields` names fields explicitly set by authoring, including creation fields; changing an affected record's revision alone marks no new fields authored. `source` exposes retained `source_title` for games and releases, plus `source_system`, `source_region`, `source_revision` for releases, separately from corrected canonical values. Absent source values are null. Migration retains the existing canonical game title and release metadata as their original source values; reference imports also record these source fields. Authoring never overwrites them. New authored records have no invented source provenance.

`.search(query:, limit: 25)` finds canonical game titles and title aliases case-insensitively (maximum 100 results, ordered by public ID). Aliases are searchable only through this internal contract, are independent of importer `GameIdentity` keys and never appear in public JSON. Provenance, audits and authoring revisions are also internal.

For any operation on an existing game or one of its releases, the affected authoring scope is **the game and all its current releases**: their associated public representations are touched together. Read `.scope(game_id:)` to obtain those records and their current revisions. Supply `expected_revisions` as a hash from `game:<public ID>` and `release:<public ID>` to each integer revision. Every affected existing record is required; missing, stale or unrelated revision targets reject the entire operation. Creating a release under an existing game uses this same scope, advances the parent and existing releases, and returns the new release and media as well. Standalone game/media creation requires an empty revision hash. Existing imported records start at authoring revision 0; new authored records start at 1. Every successful mutation advances each affected record once. These counters are distinct from release `revision` text and the content hash `startup.revision`.

The result is `{audit_id, records}`, containing committed canonical states, provenance and revisions for every affected record. Retry with the same key, operation, attributes, expected revisions and reason to receive the exact saved committed result, even though those expected revisions are now stale. Hash key order is immaterial; array order is significant. A changed operation or payload with the same key conflicts. Concurrent retries serialize on the database's unique retry key, producing one mutation and one audit entry. A validation, revision conflict or persistence failure rolls back the mutation, retry record and audit together; a failed key can be retried after fixing the request. Failures raise exceptions: `CatalogAuthoringService::InvalidInput`, `::Conflict`, `::MissingAdminName`, or the underlying record lookup/validation/persistence error.

Each committed `CatalogMutation` stores the admin display name, UTC timestamp, operation, reason and before/after internal state of every affected record, including its identity and revision. New records have a null before-state. `.history(limit: 25, before_id: nil)` returns newest entries first with `id`, `operation`, `admin_name`, `created_at`, `reason` and `record_changes` (each with `before` and `after`). The finite maximum is **100 entries per read**; use the oldest returned ID as `before_id` for the next page. This bounds retrieval only: original entries and saved results are retained. Compensation is a new `correct_game` or `correct_release` call with desired earlier field values, a new key, a reason and the **current** scope revisions. It is validated and audited normally; original entries, stable identities and evidence remain intact. No account, permission or extra human-approval framework is introduced.

Public corrections refresh all containing release ETags and Last-Modified values, including shared-media representations. Title-only edits leave `startup.revision` unchanged. With launcher headers (`User-Agent: Arcadary/1.0`), an old ETag receives updated `200` content and the new ETag receives `304`. Already cached responses may remain until their existing TTL expires: **300 seconds for resource responses and one day for lookup redirects**. Reads remain anonymous and caller-independent.

Relationship changes and edits to existing ordered-media sets (including existing-checksum attachment and media-metadata corrections) belong to #40. Reference-import precedence and the manual-import adapter belong to #41; current reference imports are still bootstrap operations and must not be used to overwrite authored records pending that slice. Those adapters must reuse the expected-revision, retry, result and audit guarantees above. No adapter or new startup format is included here.

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

Configured nonempty R2 names and the capture token pass through Kamal `env.secret` and `.kamal/secrets`; the public origin passes through `env.clear`. No values are committed. Absent/empty secret names are omitted from resolved container declarations and values; an absent public base URL is empty. Production boots, answers `/up` and serves existing lookups without these six variables. Incomplete production configuration disables uploads with `503`, with no local-storage fallback. Specs use local test storage, never R2. Local decoder checks require libvips; CI and Docker install it.

Before public launch the deployment owner must verify Cloudflare CDN purging, access-log suppression at every delivery layer for both image reads and uploads, and that `takedown@arcadary.org` accepts mail and forwards to a monitored inbox. These are launch prerequisites, not claims that provisioning or verification has happened.

## Private service authentication

`PrivateServiceAuthentication` is the shared single-admin HTTP Basic guard for future reviewer, admin and private API controllers. No production route currently opts in; review/download adoption belongs to #27 and MCP adoption to #34. It does not create accounts or replace the capture device's bearer token.

The guard reads `VALIDATION_REVIEWER_USERNAME` and `VALIDATION_REVIEWER_PASSWORD` from the Rails process environment on every protected request. Supply both through fnox, with no defaults. Placeholder configuration is `VALIDATION_REVIEWER_USERNAME=<admin-username>` and `VALIDATION_REVIEWER_PASSWORD=<long-random-password>`; use a username without a colon. Either missing or blank returns `503 {"error":"authentication_unavailable"}` before controller work. Missing, malformed or invalid Basic credentials return `401 {"error":"unauthorized"}` with a Basic challenge. Both credentials are compared as fixed-length SHA-256 digests in constant time. There is no remembered successful authentication or session.

To adopt the guard, add the consumer's complete private path subtree to `config.x.private_service_paths` in `config/application.rb`, for example `config.x.private_service_paths = [ %r{\A/private-admin(?:/|\z)} ]` (illustrative only; no such route exists). Matchers see paths with repeated slashes collapsed. The guard wraps every HTTP method on matching paths before `Rails::Rack::Logger`, authenticates before controller callbacks or request-body parsing, suppresses application logs including exceptions, disables detailed exception responses, and sets `Cache-Control: no-store` on successes and errors. HTML controllers can inherit `ApplicationController` and JSON controllers `ApiController`; add request coverage for every consumer's paths, errors and headers. Keep anonymous reads outside these matchers.

For rotation, the owner replaces both values through fnox and makes the replacement environment available to every Rails worker through the normal release/restart process. Changing fnox alone does not modify an already-running process's environment. Once replaced, the next request rejects the old pair and accepts the new one; clients must supply credentials on every request. Never put real values in documentation, commands saved in history, logs or git. The isolated request harness uses disposable credentials only.

Hosted Basic authentication **requires TLS**. Production retains `assume_ssl` and `force_ssl`; trust forwarded scheme headers only from the TLS-terminating proxy. Before enabling any hosted consumer, the maintainer must verify TLS, exclude its entire private subtree from proxy/CDN shared caches (including errors), and disable Authorization-header, credential and request-body logging at every proxy/CDN/application layer. The application tests cannot verify hosted infrastructure. This issue makes no live fnox, deployment or proxy configuration change; consumers must arrange environment delivery to their Rails workers when enabled.

## Privacy and logging

Checksum reads are anonymous, but they reveal which file a household has and the caller's IP address to the service and CDN. Screenshot URLs likewise identify releases, and the service/CDN see image callers' IPs. No player account or session is required; the endpoints set no cookie. This does not make reads private. Authentication and upload responses are never shared-cacheable.

Rails silences lookup, release/media, screenshot-read and capture-upload requests before request-start logging, covering parameter, controller and SQL logs, including paths with repeated slashes and handled failures. SHA-1, SHA-256 and authorization parameters are filtered defensively. Captured application-log specs cover token, client IP, release SHA-1, PNG SHA-256 and body bytes. Routing errors (for example, a missing suffix) can still log the identifying URL at error level, without the client IP. These routes add no telemetry or request-specific log lines. The production image sets `LOG_REQUESTS=false` to disable Thruster's access logs, which otherwise pair identifying URLs with client IPs. Keep that setting disabled, including any `THRUSTER_LOG_REQUESTS` override.

The specs check Rails logs only; the rest was checked on the deployed host. kamal-proxy runs with Docker's `none` log driver and keeps no request log, because that log records `X-Forwarded-For`, which Cloudflare always fills with the visitor's IP, next to each path and so each checksum. Cloudflare's "Remove visitor IP headers" transform does not change that header for ordinary visitors. `cloudflared` logs no per-request lines at its default level. Check these again whenever the proxy, the tunnel or the image changes. Cloudflare itself still sees every visitor's IP.

## Deployment

Production is one Hetzner host behind Cloudflare, created by the infrastructure repository, and the service answers on `api.arcadary.org`. Kamal builds the image locally for amd64 and moves it to the host through its local registry, so no registry account is needed. fnox supplies the host's address (`DEPLOY_HOST`), `SECRET_KEY_BASE` and the tunnel's token (`TUNNEL_TOKEN`). The owner deploys, or an agent once the owner has confirmed that deploy:

```bash
fnox exec -- bin/kamal setup    # the first time: installs Docker, boots cloudflared and kamal-proxy, then deploys
fnox exec -- bin/kamal deploy   # every time after
```

Cloudflare terminates TLS. It reaches the origin only through a Cloudflare Tunnel, which the infrastructure repository creates: `cloudflared` runs on the host as a Kamal accessory, dials out to Cloudflare and hands each request to kamal-proxy in plain HTTP on Docker's `kamal` network. kamal-proxy publishes no ports on the host, the host's firewall has no web ports open, and the origin holds no certificate. The tunnel's token is a sensitive output of the infrastructure repository; pipe it into fnox without printing it (`fnox set TUNNEL_TOKEN` reads stdin). `bin/kamal accessory reboot cloudflared` picks up a new token or image.

## Licence

Code: MIT, see [LICENSE](LICENSE). Catalog metadata: CC-BY-SA-4.0, see [LICENSE-DATA](LICENSE-DATA). Screenshot images are excluded from that licence; their own licence applies. Image credits and upstream notices are in [Screenshots](#screenshots).
