# Arcadary service

The remote service for [Arcadary](https://github.com/arcadary/arcadary): a Rails 8.1 application for the project's homepage and launcher JSON API. `GET /v1/lookup/{sha1}.json` identifies a game file and redirects to its release and game, or to all containing releases for a shared file. The offline catalog importer covers eight pinned No-Intro lists (29,336 distinct checksums); two optional homebrew seeds work without those lists. An opt-in validation write flow receives player-confirmed unknown files into private Rails-host storage. Reviewer access/downloads follow in #27; the milestone releases both together. Compatibility, controller-profile and page features are still to be built. The upload flow has not been deployed.

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

Fetch downloads only the eight filenames in [data/catalog/dats.json](data/catalog/dats.json), from the recorded commit, and verifies each SHA-256 before replacing its local copy. It refuses extra file arguments. These downloads contain metadata only. DATs stay out of git; the catalog accepts no game files or player filenames. Import reads local files only and accepts later operator-supplied lists under those filenames; it does not require their digests to match the initial pin.

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

## Validation receipts

The launcher checks its reference lists and unknown lookup, then obtains the player's confirmation before offering a transfer. This anonymous service cannot prove those checks occurred. The only file-byte exception is receipt into private host storage and future authenticated reviewer downloads: no public files or links, preview, execution, unpacking, interpretation or acquisition instructions. Receipt changes no catalog, game or verification status. A game becomes Verified only when a named reviewer who owns that exact file has played it; downloading alone confers no status. Legal review is deferred; retention and takedown rules remain undecided. Quotas, per-system policy and proxy rate limiting are deferred to #23.

`POST /v1/validations.json` accepts `application/json` with exactly `sha1` (40 hex characters), `byte_size` (positive integer, at most 134,217,728) and `system` (one of `Release::SYSTEMS`). JSON is limited to 1,024 bytes. A new or matching incomplete submission answers `201 {"status":"admitted","admission":"<token>","expires_at":"<UTC ISO-8601>"}`. Each signed admission is fresh, lasts ten minutes and binds lowercase checksum, size and system. A matching complete submission answers exactly `200 {"status":"received"}` and requires no transfer. Known checksums in any release, including secondary/shared media in another system, are ineligible.

`PUT /v1/validations/{sha1}/file.json` accepts only raw `application/octet-stream`, an explicit `Content-Length` and the token in `X-Validation-Admission`. Never place an admission in a URL or cookie. Both routes permit absent or `identity` Content-Encoding only. PUT checks availability, media/encoding, Rack length presence/format/global bound, path, signature/expiry/persisted facts, known release and admitted length before reading the application body. A catalog import after admission can reject the PUT. A complete retry passes those same checks and confirms without rereading or rewriting its file. The response is exactly `200 {"status":"received"}`. After a broken connection or transport error, repeat POST to learn whether another transfer is needed.

`ValidationSubmission` is separate from releases and unique by checksum. A process-wide filesystem `flock` on `<sha1>.lock` gives one admission/uploader exclusive ownership per checksum across processes; no database transaction stays open while reading. On the next eligible incomplete PUT, the lock owner removes abandoned `<sha1>.stage` before starting a replacement. An active uploader holds the same lock, so recovery cannot delete its staging. Chunks are at most 64 KiB, counting and hashing actual bytes, with a 120-second application read deadline and rejection at the first byte over the global ceiling. After EOF, count is checked before SHA-1. Only verified bytes are flushed, fsynced and atomically renamed to `<sha1>.data`; the directory is synced before recording `completed_at`. A crash between rename and the database write leaves an incomplete record that must upload again. Future reviewer access must require completion and an available regular private final file; staging and uncommitted files are never downloadable. Final and staging names are server-controlled, outside `public/`, with no Active Storage attachment or public signed link.

All receipt responses are cookie-free JSON with `Cache-Control: no-store`; errors contain exactly `{"error":"<code>"}`. Availability is always first. POST then checks media/encoding, declared/actual JSON length (reads at most 1,025 bytes), structure/fields, file size, known release and conflict. PUT precedence is described above; during reading, timeout or oversize stops immediately. `/api-docs` specifies exact response shapes and headers.

| HTTP | Stable errors |
| --- | --- |
| 400 | `invalid_metadata` (including path or PUT length format) |
| 403 | `invalid_admission` |
| 408 | `upload_timeout` |
| 409 | `known_release`, `submission_conflict` |
| 411 | `length_required` (only when Rack has no length) |
| 413 | `metadata_too_large`, `file_too_large` |
| 415 | `unsupported_media_type` (also encoding) |
| 422 | `size_mismatch`, `checksum_mismatch` |
| 503 | `unavailable` (disabled, invalid configuration, credentials or storage failure) |

## Privacy and logging

Checksum reads are anonymous, but they reveal which file a household has and the caller's IP address to the service and CDN. No player account or session is required; the endpoint sets no cookie. This does not make reads private.

Rails silences lookup requests before request-start logging, covering parameter, controller and SQL logs as well, including paths with repeated slashes. SHA-1 parameters are also filtered defensively. Routing errors (for example, a missing `.json` suffix) can still log the checksum URL at error level, without the client IP. The endpoint adds no telemetry or request-specific log lines. The production image sets `LOG_REQUESTS=false` to disable Thruster's access logs, which otherwise pair checksum URLs with client IPs. Keep that setting disabled, including any `THRUSTER_LOG_REQUESTS` override.

Receipt middleware handles the whole `/v1/validations` path family, including malformed paths and repeated slashes, before Rails request logging and parameter parsing. The bounded Rack handler silences application/SQL logging for successes and errors. Credentials, Authorization, admissions/token fields and raw-body fields are also filtered defensively. Records, storage keys and application telemetry collect no player filename, IP or stable device/install identifier. The service, CDN and intervening proxies still see caller IP, checksums and bytes in transit; private storage does not make transit anonymous.

Earlier deployed-read checks established kamal-proxy's Docker `none` log driver and no per-request lines from `cloudflared` at its default level. They do not establish upload privacy or behavior. kamal-proxy's normal request log pairs `X-Forwarded-For` with checksum paths; preserve `log-driver: none`, `publish: false` and `forward_headers: false`. Cloudflare's visitor-IP transform does not remove ordinary visitors' `X-Forwarded-For`. Cloudflare itself still sees visitor IPs. Before enabling uploads the maintainer must verify error as well as success logs across CDN, tunnel, proxy, Thruster and Puma, with no debug logging or admission/header/body capture.

Shared-cache and Cloudflare rules must exclude both `/v1/validations` and `/review/validations` families, all methods, statuses and path variants. Authenticated or write routes never enter a shared cache. New upload cache exclusions, proxy/CDN log checks and filesystem isolation checks below remain unverified on the live host; specs establish application behavior only.

## Deployment

Production is one Hetzner host behind Cloudflare, created by the infrastructure repository, and the service answers on `api.arcadary.org`. Kamal builds the image locally for amd64 and moves it to the host through its local registry, so no registry account is needed. fnox supplies the host's address (`DEPLOY_HOST`), `SECRET_KEY_BASE` and the tunnel's token (`TUNNEL_TOKEN`). The owner deploys, or an agent once the owner has confirmed that deploy:

```bash
fnox exec -- bin/kamal setup    # the first time: installs Docker, boots cloudflared and kamal-proxy, then deploys
fnox exec -- bin/kamal deploy   # every time after
```

Cloudflare terminates TLS. It reaches the origin only through a Cloudflare Tunnel, which the infrastructure repository creates: `cloudflared` runs on the host as a Kamal accessory, dials out to Cloudflare and hands each request to kamal-proxy in plain HTTP on Docker's `kamal` network. kamal-proxy publishes no ports on the host, the host's firewall has no web ports open, and the origin holds no certificate. The tunnel's token is a sensitive output of the infrastructure repository; pipe it into fnox without printing it (`fnox set TUNNEL_TOKEN` reads stdin). `bin/kamal accessory reboot cloudflared` picks up a new token or image.

### Enabling receipt

Production defaults uploads off. Development/test default on, but both routes still require nonblank `VALIDATION_REVIEWER_USERNAME` and `VALIDATION_REVIEWER_PASSWORD`; there are no default credentials. Only the literal string `true` enables `VALIDATION_UPLOADS_ENABLED`. Disabled/invalid configuration, blank credentials and unusable storage fail closed with `503` before input/body processing or submission changes. Development defaults to `storage/validations`; tests use a process-isolated directory under `tmp/`, with per-example temporary storage in receipt specs.

The existing age-encrypted `SECRET_KEY_BASE` declaration in `fnox.toml` stays unchanged. The reviewer declarations are value-free, environment-supplied entries, as described in the [fnox configuration reference](https://fnox.jdx.dev/reference/configuration#secrets). Before the first deploy enabling uploads, the maintainer supplies reviewer values with `fnox set VALIDATION_REVIEWER_USERNAME` and `fnox set VALIDATION_REVIEWER_PASSWORD`, using private stdin without printing values. This implementation provisions no provider or secret, copies/rotates no signing secret and changes no existing `fnox exec -- bin/kamal deploy` workflow. Kamal passes all three through ENV. Production runtime initialization requires a nonblank environment `SECRET_KEY_BASE`, including `rails server`, `rails runner` and the entrypoint's `rails db:prepare`, even with uploads disabled. Neither credentials files nor `SECRET_KEY_BASE_DUMMY` bypass this. The sole build-task exception is `SECRET_KEY_BASE_DUMMY=1 rails assets:precompile`; combinations with runtime tasks are not exempt.

After the manual checks below, the maintainer can enable this example under `env.clear` in `config/deploy.yml`:

```yaml
VALIDATION_UPLOADS_ENABLED: "true"
VALIDATION_STORAGE_PATH: /rails/storage/validations
```

Production requires an explicit absolute private subdirectory resolving inside the existing `/rails/storage` persistent volume. Relative paths, the shared volume root, outside paths and symlink escapes are rejected. The volume mount `/mnt/storage/arcadary_service:/rails/storage` and all four SQLite paths remain unchanged. Storage is owned by the Rails user, directories mode `0700`, files `0600`; each request probes usability. The example is commented out in the shipped configuration and authorizes no deployment. Release receipt and reviewer access together from `milestone/validation-requests`.

### Upload transport and buffering

The shipped chain is **Cloudflare → cloudflared → kamal-proxy → Thruster → Puma → Rails**. The 134,217,728-byte application ceiling is global, not a per-system quota or a promise that every game image fits. [Cloudflare Free/Pro limits requests to 100 MB](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/4xx-client-error/error-413/), below that ceiling. Before deployment the maintainer must choose and verify a higher-limit plan, an upload hostname bypassing the proxy, or acceptance of transport errors above that limit. This work selects/provisions none and preserves the application ceiling and existing origin protections.

Puma 8.1.2 evaluates `http_content_length_limit 134_217_728`. The Dockerfile supplies Thruster 0.1.28 `MAX_REQUEST_BODY=134217728`, `HTTP_READ_TIMEOUT=120`, `HTTP_WRITE_TIMEOUT=150` and `LOG_REQUESTS=false`. [Thruster-prefixed variables override these defaults](https://github.com/basecamp/thruster/blob/v0.1.28/README.md#custom-configuration); verify `THRUSTER_` overrides too, especially limits and disabled access logging. Its [server](https://github.com/basecamp/thruster/blob/v0.1.28/internal/server.go) applies Go HTTP read/write deadlines, and its [reverse proxy](https://github.com/basecamp/thruster/blob/v0.1.28/internal/proxy_handler.go) streams to Puma without a request disk spool.

Kamal 2.12.0's [bundled proxy configuration](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration/proxy.rb) enables request and response buffering and selects [kamal-proxy v0.9.2](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration/proxy/run.rb) by default. The [Kamal docs](https://kamal-deploy.org/docs/configuration/proxy/#buffering) describe a 30-second response timeout, 1 GB request bound and 1 MB memory buffer. There is a version-specific discrepancy: v0.9.2's [actual defaults](https://github.com/basecamp/kamal-proxy/blob/v0.9.2/internal/server/service.go) set the maximum request body to `0` (unlimited), the target timeout to 30 seconds and memory to 1 MiB. We therefore explicitly set `proxy.buffering.requests/responses: true`, `max_request_body: 134217728`, `memory: 1048576`, retain unlimited response size (`0`), and set `proxy.response_timeout: 300`. Evaluated configuration specs check the resulting Kamal CLI flags; these do not establish the live proxy version.

The proxy [buffers the complete request before forwarding](https://github.com/basecamp/kamal-proxy/blob/v0.9.2/internal/server/request_buffer_middleware.go). Its [target timeout](https://github.com/basecamp/kamal-proxy/blob/v0.9.2/internal/server/target.go) is an upstream response-header timeout, after sending the buffered request, not a client-upload deadline. The 300-second setting leaves room above the application's 120-second read budget and local forwarding/response overhead. Thruster's 120-second network read applies on the local buffered hop from kamal-proxy; its 150-second write budget overlaps that hop and response work, rather than adding 150 seconds afterward. Puma buffers again before Rails runs. A rejected PUT may already have been buffered upstream but never becomes a submitted file. Admission avoids unnecessary transfers for compliant launchers. The injected slow-body `408` test establishes only the application's 120-second deadline, not an end-to-end upload promise. Edge limits, buffering time, waiting for checksum ownership and each hop's deadlines can terminate the connection separately. Proxy/server rejection or a broken connection may lack the JSON envelope or application cache headers; repeat POST to recover.

| Hop | Body storage and isolation to verify |
| --- | --- |
| Rails staging/final | `<configured private directory>/<sha1>.stage` / `.data`, with persistent `.lock` files; Rails UID/GID `1000:1000`, directory `0700`, files `0600`. Staging is removed on failure or next eligible PUT under the same lock; never served by `public/` or Active Storage. |
| Puma 8.1.2 | [Client buffering](https://github.com/puma/puma/blob/v8.1.2/lib/puma/client.rb) uses memory for small bodies, otherwise Ruby `Tempfile.create("puma")` in `Dir.tmpdir` (normally `/tmp` inside the application container; `TMPDIR` can override). Large/chunked uploads spill there, owned by Rails UID `1000`, mode `0600`, immediately unlinked on Linux and closed after use. Check open deleted files as well as directory entries. Chunk decoding supplies Rack Content-Length, so `411` is only for an absent Rack length. |
| Thruster 0.1.28 | Streaming reverse proxy, no request disk spool; in-memory transport buffers run in the Rails container as UID `1000`. Internal state under `storage/thruster` is not an upload buffer. |
| kamal-proxy v0.9.2 | [Spill implementation](https://github.com/basecamp/kamal-proxy/blob/v0.9.2/internal/server/buffer.go) uses `os.CreateTemp("", "proxy-buffer-")` beyond 1 MiB, in Go's temp directory (`TMPDIR` or `/tmp`) in the **separate proxy container**, outside application storage. Files mode `0600`, owned by the image's [kamal-proxy user](https://github.com/basecamp/kamal-proxy/blob/v0.9.2/Dockerfile); spill removal runs on buffer close. Inspect cleanup and leftovers on abort/restart, actual UID and any mounts independently. |
| cloudflared 2026.11.2 | HTTP-origin [proxy code](https://github.com/cloudflare/cloudflared/blob/2026.11.2/proxy/proxy.go) forwards the request body to RoundTrip, with streaming transport buffers and no HTTP-body disk spool in that path. No upload tempfile location/owner applies there; inspect the actual tunnel configuration/image and `/tmp` for changed behavior. |
| Cloudflare | Remote transport/edge buffering is outside application filesystem control. Verify the selected plan's size/time limits, caching and logs; local private permissions cannot establish edge retention or logging. |

Before deployment, the maintainer must check live size/time limits, success/error headers and cookie absence, cache exclusions, logs, and application/Puma/kamal-proxy/cloudflared tempfile isolation and cleanup. Check owners, modes, mounts and reachability from other containers/users, and remaining bytes after interruption; proxy tempfiles live outside the application volume. The existing read-only deployment observations do not satisfy these new upload checks. No deployment is authorized by this issue.

## Licence

Code: MIT, see [LICENSE](LICENSE). Catalog data: CC-BY-SA-4.0, see [LICENSE-DATA](LICENSE-DATA).
