# Private catalog MCP

`/mcp` is the single admin's MCP endpoint for catalog reads, staged screenshot publication and private HLS upload intake in the Rails application. It uses the official Ruby `mcp` SDK **1.11.0**, in stateless Streamable HTTP mode with finite JSON responses. Writes publish a screenshot issued by private PNG staging, or begin/renew a release-bound private playthrough stage. It exposes no video publication, general blob publication, catalog metadata writes, compatibility operations, game files, downloads, submissions, shell, SQL or arbitrary URL tools. Catalog coverage is not a playability verdict.

The generated [HTTP endpoint documentation](../swagger/v1/swagger.yaml) is served at `/api-docs`. MCP `tools/list` publishes the input/output JSON schemas and help for each tool; `server/discover` serves SDK discovery for the modern protocol. All discovery is authenticated. These schemas, rather than the launcher's public JSON shapes, describe the private authoring records.

## Authentication and transport

Use HTTP Basic over **TLS** with the shared `VALIDATION_REVIEWER_USERNAME` and `VALIDATION_REVIEWER_PASSWORD` pair. Authentication is the entire access gate: there are no accounts, roles, scopes or per-tool permissions. It deliberately supports Codex's configured-header mode. It does not implement OAuth authorization, OAuth discovery or an interactive login; no OAuth conformance is claimed.

Every request to `/mcp` or its subtree requires the current pair, including unsupported methods, malformed bodies and errors. Missing or blank server configuration returns `503 authentication_unavailable`. Missing, malformed or wrong credentials return `401 unauthorized` and `WWW-Authenticate: Basic realm="Arcadary", charset="UTF-8"`. Credentials are checked against the workers' environment on every request; replace both variables and restart/replace **all** workers together to rotate. The old pair then fails on subsequent requests, including reconnects. There is no session token that bypasses rotation. This follows the [shared authentication contract](../README.md#private-service-authentication).

All responses carry `Cache-Control: no-store`, and the endpoint creates no cookie or persistent session. GET/DELETE and unsupported HTTP methods receive the SDK's `405`; unknown subpaths return `404` after authentication. Successful requests use POST with `Content-Type: application/json`. Legacy clients may send `Accept: application/json`; modern clients must accept both `application/json, text/event-stream`, as the SDK requires. No SSE subscription or resumable stream is enabled.

The SDK retains protocol negotiation. The legacy `initialize` handshake supports `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`; an unsupported proposal is counter-offered `2025-11-25`. A modern `2026-07-28` client uses `server/discover` and that protocol's per-request metadata (`io.modelcontextprotocol/protocolVersion` and `io.modelcontextprotocol/clientCapabilities`, with optional `io.modelcontextprotocol/clientInfo`) instead of the legacy handshake. Include the matching `Mcp-Method` header and, for named calls, `Mcp-Name`. Send the negotiated `MCP-Protocol-Version` header on subsequent requests. The SDK rejects unsupported request versions and malformed envelopes. The adapter supplies JSON text content alongside structured results for older clients.

Complete HTTP POST bodies are capped at **2 MiB (2,097,152 bytes)**, read with the SDK's bounded reader even with missing or dishonest Content-Length; one byte over returns HTTP `413` before tool execution. JSON nesting is capped at **64**. Tool results are capped at **1 MiB (1,048,576 bytes)** of structured JSON before the SDK adds its text-content representation. Oversized catalog read results return `invalid_input`; reduce the page limit. Playthrough begin arguments have a separate **1 MiB** UTF-8 compact-JSON ceiling before normalization, excluding the JSON-RPC envelope. An over-limit declaration returns tool error `stage_too_large` without creating a stage or authorization. Its compact result fits every valid declaration and returns all object metadata without pagination or truncation. No unlimited request option is used. Tools do not issue server-to-client requests or create background streams.

The explicit Host allow-list is `api.arcadary.org`, plus `localhost`, `127.0.0.1` and `[::1]` for local tests (ports allowed). The only accepted Origin value is `https://api.arcadary.org`. A missing Origin is permitted for the intended non-browser client; hostile origins, including `null`, are rejected even with valid Basic credentials. The application checks this stricter list before the SDK's additional DNS-rebinding checks. Forward the original Host through the trusted proxy.

## Tools and pagination

| Tool | Initial arguments | Data |
| --- | --- | --- |
| `search_games` | Optional `query` (case-insensitive title/alias substring, at most 200 characters), optional `system` | Page of `{id, title, authoring_revision}` summaries, ordered by stable game ID. System filters games with a release on that system. |
| `get_game` | `id` from search | `{type, id, authoring_revision, canonical, authored_fields, source, releases}`. Canonical title and aliases; existing release variant summaries. |
| `get_release` | Exactly one of `id` or `sha1` | `{type, id, authoring_revision, canonical, authored_fields, source}`. Stable release ID selects one edition; a SHA-1 can identify several candidates. |
| `get_catalog_history` | No required initial argument | Page of `{id, operation, admin_name, created_at, reason, record_changes}` audit entries, newest ID first. Each change retains its before/after authoring snapshots. |

Each initial read call accepts `limit`: default **20**, range **1–50**. Systems are `nes`, `snes`, `gb`, `gbc`, `megadrive`, `pcengine`, `atari2600`, `c64`. SHA-1 is 40 hexadecimal characters, case-insensitive. Player filenames are never accepted. These four tools retain read-only, non-destructive, idempotent annotations and their existing read semantics.

Every collection uses `{ "items": [...], "next_cursor": "opaque-token-or-null" }`, including aliases, authored-field names, variants, media, controller-profile layout/prompts and each fact's evidence citations, ambiguous candidates, audit changes and collections inside before/after snapshots. No array is silently cut off. Alias ordering is lexical, releases/candidates use stable release ID, and media retain exact position order. Profile and audit snapshot arrays retain the recorded order.

Release `canonical.controller_profile` is null or the full internal [version 1 profile](../README.md#original-controller-layout-and-prompts): `version`, edition `binding` (`system`, `region`, `revision`), paginated `layout` facts (`position`, `label`, paginated `evidence`) and paginated `prompts` facts (`letter`, `position`, paginated `evidence`). Evidence retains bounded text citations and provenance for each fact. Unlike public JSON, these private reads include binding and evidence. `get_release` and every retained before/after snapshot in `get_catalog_history` expose the complete authored value. Consume all layout, prompt and evidence continuation pages before interpreting the facts; references can point to a layout position on another page. The same tool with only `cursor` continues each nested collection without losing facts. Profiles add no MCP write tools.

To continue **any** collection, call the **same tool** with **only** `cursor` set to its `next_cursor`. The returned `data` is that collection's next page, rather than a repeated enclosing record. The cursor retains the original page size and search/selection context. Follow nested cursors separately. A null cursor means complete. Cursors are signed, expire after one hour, and cannot cross tools; they are not credentials and still require Basic authentication. A changed nested record invalidates its cursor (`invalid_input`); restart the enclosing read. Root searches and relation pages use keyset continuation, not a frozen database snapshot: concurrent edits can change which records match. Audit entries are retained history.

Release `canonical` includes `game_id`, `system`, `region`, `revision`, effective `startup` (`schema`, `boot`, `drives`, startup `revision`), and paginated `media`. Each medium includes `key`, `position`, `role`, `label`, `sha1`, `size`, `format`, `crc32` and `md5`; unavailable metadata is null. Startup refers to medium keys across all pages, so consume every media page before interpreting it. `source` exposes the retained `source_title`, `source_system`, `source_region`, `source_revision` separately from effective canonical values. `authored_fields` identifies the fields deliberately authored; the values of those fields are in `canonical`. Available provenance is what the catalog retained, without invented source claims. Game source contains `source_title`.

Successful tool results have `isError: false` and `structuredContent: {"data": ...}`. Domain failures have `isError: true` and `structuredContent: {"error": {"code": ...}}`. Codes are `invalid_input` (argument schema, selection, checksum, cursor or result bound), `not_found`, and `ambiguous_release`. The last includes `error.candidates`, a page of `{id, game_id, system, region, revision, authoring_revision}`. Continuing that page keeps `ambiguous_release` and returns the next candidates; call `get_release` with one candidate's `id` to inspect it. Malformed JSON/JSON-RPC remains SDK protocol errors (for example `-32700`, `-32600`, `-32602`), distinct from these domain failures. The adapter validates tool arguments against their published schemas so domain failures consistently carry machine-readable codes. Each result also contains its JSON as text for older clients. Unexpected application exceptions disclose no exception details.

## Screenshot publication

Bulk bytes use `POST /v1/screenshot-stages/{release_id}/{source_sha1}/{kind}.json` with `Content-Type: image/png` and the same Basic credentials as MCP. No capture token is required. [Screenshots](../README.md#private-staging-and-mcp-publication) and the generated HTTP documentation specify ingest, limits and status codes. Only title/gameplay screenshots are accepted; upload grants no new image rights.

The fifth tool, `publish_screenshot`, requires exactly four string arguments, with no additional properties:

| Argument | Meaning |
| --- | --- |
| `staging_id` | Opaque ID returned by screenshot ingest, not a PNG hash, Active Storage ID or other record ID; nonblank, at most 200 characters. |
| `release_id` | The exact bound stable release public ID; nonblank, at most 200 characters. |
| `source_sha1` | The bound source-medium SHA-1: exactly 40 case-insensitive hexadecimal characters. |
| `kind` | The bound `title` or `gameplay` kind. |

Both ingest and publication verify checksum membership in the specified release. Secondary media are valid; shared checksums never select a release implicitly. Publication rechecks the binding and membership atomically with the screenshot update. Success returns `isError: false` and `structuredContent: {"data":{"release_id":"stable-id","screenshot":{"kind":"gameplay","url":"https://PUBLIC_ORIGIN/v1/screenshots/HASH.png","width":2,"height":2,"licence":""}}}`. The published screenshot uses the game's current image licence, replaces only that release/kind and follows existing game-picture selection, removal and validator rules. The tool is annotated `readOnlyHint: false`, `destructiveHint: true`, `idempotentHint: false`, `openWorldHint: false`. It has no pagination/cursor arguments. Discovery publishes its complete input/output schemas.

A stage expires exactly 24 hours after successful ingest, without renewal on reads/failures. The first success atomically consumes the ID and transfers the canonical blob to the screenshot without retaining a second staging copy. Concurrent/repeated successful-target calls return `staged_image_consumed` until the original expiry, including after later replacement/removal. At expiry the ID returns `staged_image_unavailable`, whether or not cleanup has run. Failed attempts preserve the previous screenshot/bytes and leave the unexpired stage retryable. If a response is lost, retry the same ID/binding: `staged_image_consumed` means it was already published; inspect public release JSON to see the current screenshot, which may have been replaced since. IDs are never reused. There is no discard tool.

Publication errors use `isError: true` and `structuredContent: {"error":{"code":"..."}}`:

| Code | Meaning / next step |
| --- | --- |
| `invalid_input` | Missing/malformed arguments or unexpected properties; correct the call. |
| `not_found` | Unknown stable release public ID. |
| `target_mismatch` | Wrong bound release/checksum/kind, or the checksum no longer belongs to the release. Use the exact binding; ingest a new stage if the intended target changed. |
| `staged_image_unavailable` | Unknown/other record ID, expired stage, missing blob or invalid staged bytes. Ingest again. |
| `staged_image_consumed` | This bound stage already published successfully; it cannot publish again. |
| `uploads_disabled` | Missing/malformed public screenshot origin or incomplete production R2 configuration; the operator must restore configuration before retrying. |
| `storage_unavailable` | Storage failed; retry the same stage before expiry after storage recovers. |

The production recurring scheduler runs cleanup at least hourly, with at most 100 records per pass and queued continuation for excess work. It removes expired consumed receipts and unconsumed blobs; storage deletion failures retain a durable expired record for the next hourly retry without blocking later records. Cleanup never removes a blob transferred to a screenshot. A storage upload failure returns `storage_unavailable` and cleans up its private blob. If deletion also fails, cleanup retains the blob record and queues hourly retries until deletion succeeds. Solid Queue workers and its recurring scheduler must run. Private stage bytes/metadata have no anonymous route or storage redirect and never appear in public JSON. A known PNG hash alone grants no public access; existing published copies of identical pixels keep normal delivery. This is not a trial-media flow or a general blob-publication operation.

## Private playthrough intake

`begin_playthrough_staging` is the sole entry point for beginning and renewing private HLS uploads. It takes the declaration directly as its arguments, with no extra properties:

| Argument | Meaning |
| --- | --- |
| `release_id` | Stable release `public_id`, nonblank, at most 200 characters. Select one exact release even for shared/secondary media; titles and checksum-only selection are rejected. |
| `source_sha1` | Exact lowercase 40-hex capture-source checksum. It must belong to the release unless explicit successful verification binds a different payload checksum that does. |
| `capture` | Nonblank `tool` and `version` (at most 200 characters each), and timezone-qualified ISO 8601 `captured_at` (at most 64 characters). |
| `retry_key` | Nonblank key, at most 200 characters. Identical normalized declarations replay the original stage/package/progress and issue a fresh capability. Changed declarations conflict. |
| `manifest` | 1–4,096 unique package-relative objects, each `{path, byte_size, sha256, content_type}`. Path at most 1,024 characters; positive size at most 8,388,608 bytes; lowercase 64-hex SHA-256; exact MIME type without parameters, at most 200 characters. Total declared bytes at most 4,294,967,296. All ceilings apply together. |
| `verification` | Required only for a nonmember source: one explicit offline mismatch-verification attestation, as described below. |

Paths exclude absolute paths, URLs, empty/dot/traversal components, whitespace, backslashes, colon, percent, query/fragment and controls. Package identity is SHA-256 of UTF-8 compact JSON of `[path, byte_size, sha256, content_type]` arrays sorted bytewise by path. Normalization also sorts JSON object keys and converts timestamps to UTC microseconds. The declaration size is measured **before** those transformations, as UTF-8 compact argument JSON; request whitespace and the JSON-RPC envelope count only toward the separate 2 MiB HTTP ceiling. A 4,096-object, 4 GiB declaration with short paths fits all limits.

Verification contains `source_sha1`, distinct `payload_sha1`, `relationship` (`trailing_padding` or `verified_equivalence`), `method`, `result: "success"`, `verifier` equal to the authenticated Basic username, timezone-qualified `verified_at`, and text `evidence` naming exactly those two checksums with no additional checksum proposals. Method, verifier and evidence are nonblank and at most 8,000 characters each; the timestamp is at most 64 characters. The payload must belong to the selected release. `trailing_padding` requires positive integer `removed_bytes`; preserve 127 bytes for the trial when verified. `verified_equivalence` omits that field. The service retains the source, payload and evidence separately, without receiving game bytes or inferring title matches. [The staging contract](../README.md#private-playthrough-staging) includes a synthetic declaration example.

Success returns `isError: false` with `structuredContent: {"data": ...}` containing only `staging_id`, `release_id`, `package_sha256`, `state`, every object's `{object_id, path, received}`, `capability` and ISO 8601 `expires_at`. No declaration, bulk bytes, admin credentials or signed upload URLs are echoed. `incomplete` means objects remain missing; `received` means stored, never HLS-validated or published. The tool is non-read-only, non-destructive and non-idempotent because each call issues a fresh authorization; the stage declaration itself is retry-safe.

Transfer raw bytes to `PUT /v1/playthrough-stages/{staging_id}/objects/{object_id}.json` using **both** current shared Basic credentials in `Authorization` and the issued token in **`X-Arcadary-Upload-Capability`**. Never put the token in a URL. Each capability binds the exact release, stage, immutable package manifest and declared objects. It expires exactly **900 seconds (15 minutes)** after issuance, invalid at or after `expires_at`. Replaying the identical begin declaration renews authorization even after expiry, without extending an older capability or changing the package/stage/progress. After Basic authentication, missing, expired or mismatched tokens return `403 upload_not_authorized` before application transfer-body reads or object storage access, including accepted-object retries. Basic credentials and IDs alone cannot upload or mint capabilities. Credential rotation still applies to every PUT.

`GET /v1/playthrough-stages/{staging_id}.json` remains Basic-authenticated metadata, including normalized declaration and durable progress; it never mints or renews authorization. Standalone HTTP `POST /v1/playthrough-stages.json` is removed. Transfers retain exact size/digest/content-type verification, bounded actual reads despite Content-Length, immutable accepted-object receipts and retryable incomplete objects on interruption/storage failure. All private responses and errors are `no-store`, with no cookie, playback/download route, public metadata or logged capabilities, credentials, identifying paths, checksums, provenance or bodies.

Begin errors are `isError: true` with `structuredContent: {"error":{"code":"..."}}`: `invalid_declaration`, `not_found`, `target_mismatch`, `stage_conflict`, or `stage_too_large`. Missing required arguments are SDK tool errors. Correct the declaration for validation/targeting failures; preserve the original declaration when renewing or recovering from a lost response. IDs and capabilities provide no video rights. Synthetic specs cover intake and transfer; technical HLS validation and abandoned-stage retention remain #56, R2 promotion/release discovery #57, and MCP publication/end-to-end verification #46. This intake performs no footage upload/publication, provisioning or deployment.

## Codex configured-header connection

Placeholder-only configuration, following [Codex MCP configuration](https://developers.openai.com/codex/mcp/):

```toml
[mcp_servers.arcadary_catalog]
url = "https://SERVICE_HOST_PLACEHOLDER/mcp"
env_http_headers = { Authorization = "ARCADARY_CATALOG_AUTHORIZATION" }
```

Provision `ARCADARY_CATALOG_AUTHORIZATION` in the **intended Codex process's environment** through a secure secret manager or launcher. Its complete value must be the Basic scheme plus the base64 encoding of the configured username, a colon and password. Base64 is reversible. Do not print the value, put it in shell history, commit it, store it in a URL, or paste it into this TOML. Restart the intended client with its refreshed environment after rotation. Configuring a terminal environment alone does not configure a separately launched app. Do not use `codex mcp login`: there is no OAuth login here.

## Enabling hosted access

The Rails guard runs before request logging and host validation, silencing the whole private request, including malformed bodies, checksum requests, admin notes, Authorization and exception details. Parameter filters remain defense in depth for the public API. Application suppression does not control the HTTP server, proxy, CDN or client logs.

Before enabling access, the maintainer must verify TLS and all delivery layers. On Cloudflare and any reverse proxy, match **exactly `/mcp` and every path beginning `/mcp/`**, and **`/v1/screenshot-stages` and `/v1/playthrough-stages` with their complete subtrees and suffix/error variants**, for **every HTTP method**. Cover normalized repeated-slash/encoded equivalents too: bypass cache, disable access/request-body/header logging and tracing, exclude analytics that retain IPs, queries, Authorization, X-Arcadary-Upload-Capability or responses, and never include these paths in public read cache rules. Keep Thruster request logging disabled as documented in the [deployment/privacy instructions](../README.md#privacy-and-logging). Verify rejected/authentication/error responses as well as successful POSTs/PUTs, and confirm no cache hit, stored private response, request body, Basic header or capability at any layer. Public `/v1/lookup`, release and media caching remains anonymous and caller-independent.

Owner: configure the intended Codex app environment and verify its connection. Maintainer: verify hosted TLS, proxy/CDN cache and log exclusions before enabling access. A deployed smoke test requires a separately owner-authorized deployment; this change performs no deployment or live catalog edits.

## Local real-client evidence

The earlier read-tool implementation passed on 2026-11-28 using the installed **Codex CLI 0.172.0 app-server** on macOS arm64, with an isolated Codex home, a temporary SQLite catalog containing only synthetic metadata, and disposable Basic credentials supplied through `env_http_headers.Authorization`. No model turn, account credential copy or real catalog access was involved. The client initialized the MCP connection, sent the initialized notification, listed the then-existing four tools, searched the synthetic title, inspected its game and release, and read one synthetic audit entry through `mcpServer/tool/call`. All four calls returned `isError: false`, with matching structured and JSON-text results. Subsequent HTTP requests used **2025-06-18** and all observed MCP responses carried `no-store`; the initialized notification received 202 and reads received 200. The local server and client were stopped after the test. Screenshot staging/publication is covered by in-process HTTP/MCP request specs and local storage lifecycle/concurrency specs; it has not been exercised through a real external MCP client.

This exercised a real configured-header Codex MCP client over loopback HTTP, separately from the in-process specs. Hosted TLS, proxy/CDN caches/logs, a deployed smoke test, and the owner's intended Codex app environment remain **unperformed** until the manual checks above are completed.
