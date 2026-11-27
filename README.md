# Arcadary service

The remote service for [Arcadary](https://github.com/arcadary/arcadary): a Rails 8.1 application for the project's homepage and launcher JSON API. `GET /v1/lookup/{sha1}.json` identifies a game file and redirects to its release and game, or to all containing releases for a shared file. The offline catalog importer covers eight pinned No-Intro lists (29,336 distinct checksums); two optional homebrew seeds work without those lists. Compatibility, controller-profile and page features are still to be built. Nothing is deployed.

```bash
mise install
mise run setup
mise run dev
mise run ci
```

What it is for and its product rules are in the project's Uberblick workspace (bound in `.uberblick.json`); the technical rules and setup are in [AGENTS.md](AGENTS.md).

## Catalog data

The catalog originates from [No-Intro](https://no-intro.org/), sourced through [libretro-database at f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029](https://github.com/libretro/libretro-database/tree/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/metadat/no-intro). We import checksum metadata, group releases into games, normalize titles/regions/revisions and apply the launcher's explicit identity mappings. The entire service catalog, including project corrections, additions and later fields, is licensed under [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/); see [LICENSE-DATA](LICENSE-DATA). The source's [licence at the pin](https://github.com/libretro/libretro-database/blob/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/LICENSE) is CC-BY-SA-4.0. Code remains MIT.

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

## Privacy and logging

Checksum reads are anonymous, but they reveal which file a household has and the caller's IP address to the service and CDN. No player account or session is required; the endpoint sets no cookie. This does not make reads private.

Rails silences lookup requests before request-start logging, covering parameter, controller and SQL logs as well, including paths with repeated slashes. SHA-1 parameters are also filtered defensively. Routing errors (for example, a missing `.json` suffix) can still log the checksum URL at error level, without the client IP. The endpoint adds no telemetry or request-specific log lines. The production image sets `LOG_REQUESTS=false` to disable Thruster's access logs, which otherwise pair checksum URLs with client IPs. Keep that setting disabled, including any `THRUSTER_LOG_REQUESTS` override.

The specs check Rails logs only; the rest was checked on the deployed host. kamal-proxy runs with Docker's `none` log driver and keeps no request log, because that log records `X-Forwarded-For`, which Cloudflare always fills with the visitor's IP, next to each path and so each checksum. Cloudflare's "Remove visitor IP headers" transform does not change that header for ordinary visitors. `cloudflared` logs no per-request lines at its default level. Check these again whenever the proxy, the tunnel or the image changes. Cloudflare itself still sees every visitor's IP.

## Deployment

Production is one Hetzner host behind Cloudflare, created by the infrastructure repository, and the service answers on `api.arcadary.org`. Kamal builds the image locally for amd64 and moves it to the host through its local registry, so no registry account is needed. fnox supplies the host's address (`DEPLOY_HOST`), `SECRET_KEY_BASE` and the tunnel's token (`TUNNEL_TOKEN`). The owner deploys, or an agent once the owner has confirmed that deploy:

```bash
fnox exec -- bin/kamal setup    # the first time: installs Docker, boots cloudflared and kamal-proxy, then deploys
fnox exec -- bin/kamal deploy   # every time after
```

Cloudflare terminates TLS. It reaches the origin only through a Cloudflare Tunnel, which the infrastructure repository creates: `cloudflared` runs on the host as a Kamal accessory, dials out to Cloudflare and hands each request to kamal-proxy in plain HTTP on Docker's `kamal` network. kamal-proxy publishes no ports on the host, the host's firewall has no web ports open, and the origin holds no certificate. The tunnel's token is a sensitive output of the infrastructure repository; pipe it into fnox without printing it (`fnox set TUNNEL_TOKEN` reads stdin). `bin/kamal accessory reboot cloudflared` picks up a new token or image.

## Licence

Code: MIT, see [LICENSE](LICENSE). Catalog data: CC-BY-SA-4.0, see [LICENSE-DATA](LICENSE-DATA).
