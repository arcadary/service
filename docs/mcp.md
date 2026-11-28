# Private catalog MCP

`/mcp` is the single admin's MCP endpoint for catalog reads, uploads, device compatibility results and release registration in the Rails application. It uses the official Ruby `mcp` SDK **1.11.0**, in stateless Streamable HTTP mode with finite JSON responses. Writes start and confirm uploads and turn a confirmed upload into a release's screenshot or a private playthrough, or append a reviewer's compatibility result for one release and device class. It exposes no video publication, catalog metadata writes, game files, downloads, submissions, shell, SQL or arbitrary URL tools. Catalog coverage is not a playability verdict; only a recorded compatibility result is.

The generated [HTTP endpoint documentation](../swagger/v1/swagger.yaml) is served at `/api-docs`. MCP `tools/list` publishes the input/output JSON schemas and help for each tool; `server/discover` serves SDK discovery for the modern protocol. All discovery is authenticated. These schemas, rather than the launcher's public JSON shapes, describe the private authoring records.

## Authentication and transport

Use HTTP Basic over **TLS** with the shared `VALIDATION_REVIEWER_USERNAME` and `VALIDATION_REVIEWER_PASSWORD` pair. Authentication is the entire access gate: there are no accounts, roles, scopes or per-tool permissions. It deliberately supports Codex's configured-header mode. It does not implement OAuth authorization, OAuth discovery or an interactive login; no OAuth conformance is claimed.

Every request to `/mcp` or its subtree requires the current pair, including unsupported methods, malformed bodies and errors. Missing or blank server configuration returns `503 authentication_unavailable`. Missing, malformed or wrong credentials return `401 unauthorized` and `WWW-Authenticate: Basic realm="Arcadary", charset="UTF-8"`. Credentials are checked against the workers' environment on every request; replace both variables and restart/replace **all** workers together to rotate. The old pair then fails on subsequent requests, including reconnects. There is no session token that bypasses rotation. This follows the [shared authentication contract](../README.md#private-service-authentication).

All responses carry `Cache-Control: no-store`, and the endpoint creates no cookie or persistent session. GET/DELETE and unsupported HTTP methods receive the SDK's `405`; unknown subpaths return `404` after authentication. Successful requests use POST with `Content-Type: application/json`. Legacy clients may send `Accept: application/json`; modern clients must accept both `application/json, text/event-stream`, as the SDK requires. No SSE subscription or resumable stream is enabled.

The SDK retains protocol negotiation. The legacy `initialize` handshake supports `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`; an unsupported proposal is counter-offered `2025-11-25`. A modern `2026-07-28` client uses `server/discover` and that protocol's per-request metadata (`io.modelcontextprotocol/protocolVersion` and `io.modelcontextprotocol/clientCapabilities`, with optional `io.modelcontextprotocol/clientInfo`) instead of the legacy handshake. Include the matching `Mcp-Method` header and, for named calls, `Mcp-Name`. Send the negotiated `MCP-Protocol-Version` header on subsequent requests. The SDK rejects unsupported request versions and malformed envelopes. The adapter supplies JSON text content alongside structured results for older clients.

Complete HTTP POST bodies are capped at **2 MiB (2,097,152 bytes)**, read with the SDK's bounded reader even with missing or dishonest Content-Length; one byte over returns HTTP `413` before tool execution. JSON nesting is capped at **64**. Tool results are capped at **1 MiB (1,048,576 bytes)** of structured JSON before the SDK adds its text-content representation. Oversized catalog read results return `invalid_input`; reduce the page limit. No unlimited request option is used. Tools do not issue server-to-client requests or create background streams.

The explicit Host allow-list is `api.arcadary.org`, plus `localhost`, `127.0.0.1` and `[::1]` for local tests (ports allowed). The only accepted Origin value is `https://api.arcadary.org`. A missing Origin is permitted for the intended non-browser client; hostile origins, including `null`, are rejected even with valid Basic credentials. The application checks this stricter list before the SDK's additional DNS-rebinding checks. Forward the original Host through the trusted proxy.

## Tools and pagination

| Tool | Initial arguments | Data |
| --- | --- | --- |
| `search_games` | Optional `query` (case-insensitive title/alias substring, at most 200 characters), optional `system` | Page of `{id, title, authoring_revision}` summaries, ordered by stable game ID. System filters games with a release on that system. |
| `get_game` | `id` from search | `{type, id, authoring_revision, canonical, authored_fields, source, releases}`. Canonical title and aliases; existing release variant summaries. |
| `get_release` | Exactly one of `id` or `sha1` | `{type, id, authoring_revision, canonical, authored_fields, source}`. Stable release ID selects one edition; a SHA-1 can identify several candidates. |
| `get_compatibility` | `release_id` | `{release_id, startup_revision, current, history}`. Current matches public `release.compatibility`; history includes all results newest first. |
| `get_catalog_history` | No required initial argument | Page of `{id, operation, admin_name, created_at, reason, record_changes}` audit entries, newest ID first. Each change retains its before/after authoring snapshots. |

Each initial read call accepts `limit`: default **20**, range **1–50**. Systems are `nes`, `snes`, `gb`, `gbc`, `megadrive`, `pcengine`, `atari2600`, `c64`. SHA-1 is 40 hexadecimal characters, case-insensitive. Player filenames are never accepted. These five tools retain read-only, non-destructive, idempotent annotations and their existing read semantics.

Every collection uses `{ "items": [...], "next_cursor": "opaque-token-or-null" }`, including aliases, authored-field names, variants, media, controller-profile layout/prompts and each fact's evidence citations, ambiguous candidates, audit changes and collections inside before/after snapshots. No array is silently cut off. Alias ordering is lexical, releases/candidates use stable release ID, and media retain exact position order. Profile and audit snapshot arrays retain the recorded order.

Release `canonical.controller_profile` is null or the full internal [version 1 profile](../README.md#original-controller-layout-and-prompts): `version`, edition `binding` (`system`, `region`, `revision`), paginated `layout` facts (`position`, `label`, paginated `evidence`) and paginated `prompts` facts (`letter`, `position`, paginated `evidence`). Evidence retains bounded text citations and provenance for each fact. Unlike public JSON, these private reads include binding and evidence. `get_release` and every retained before/after snapshot in `get_catalog_history` expose the complete authored value. Consume all layout, prompt and evidence continuation pages before interpreting the facts; references can point to a layout position on another page. The same tool with only `cursor` continues each nested collection without losing facts. Profiles add no MCP write tools.

To continue **any** collection, call the **same tool** with **only** `cursor` set to its `next_cursor`. The returned `data` is that collection's next page, rather than a repeated enclosing record. The cursor retains the original page size and search/selection context. Follow nested cursors separately. A null cursor means complete. Cursors are signed, expire after one hour, and cannot cross tools; they are not credentials and still require Basic authentication. A changed nested record invalidates its cursor (`invalid_input`); restart the enclosing read. Root searches and relation pages use keyset continuation, not a frozen database snapshot: concurrent edits can change which records match. Audit entries are retained history.

Release `canonical` includes `game_id`, `system`, `region`, `revision`, effective `startup` (`schema`, `boot`, `drives`, startup `revision`), and paginated `media`. Each medium includes `key`, `position`, `role`, `label`, `sha1`, `size`, `format`, `crc32` and `md5`; unavailable metadata is null. Startup refers to medium keys across all pages, so consume every media page before interpreting it. `source` exposes the retained `source_title`, `source_system`, `source_region`, `source_revision` separately from effective canonical values. `authored_fields` identifies the fields deliberately authored; the values of those fields are in `canonical`. Available provenance is what the catalog retained, without invented source claims. Game source contains `source_title`.

Successful tool results have `isError: false` and `structuredContent: {"data": ...}`. Domain failures have `isError: true` and `structuredContent: {"error": {"code": ...}}`. Codes are `invalid_input` (argument schema, selection, checksum, cursor or result bound), `not_found`, and `ambiguous_release`. The last includes `error.candidates`, a page of `{id, game_id, system, region, revision, authoring_revision}`. Continuing that page keeps `ambiguous_release` and returns the next candidates; call `get_release` with one candidate's `id` to inspect it. Malformed JSON/JSON-RPC remains SDK protocol errors (for example `-32700`, `-32600`, `-32602`), distinct from these domain failures. The adapter validates tool arguments against their published schemas so domain failures consistently carry machine-readable codes. Each result also contains its JSON as text for older clients. Unexpected application exceptions disclose no exception details.

## Uploads

Four tools carry an upload; file bytes go over HTTP, never through MCP. The [upload flow](../README.md#uploads) has the limits and storage, and the Uploads technical reference in the corpus the states and error codes.

| Tool | Arguments | Result |
| --- | --- | --- |
| `request_upload` | `type`: `screenshot` or `video` | `upload_id`, `upload_url`, `expires_at` (24 hours later) and the type's `limits` |
| `confirm_upload` | `upload_id` | The upload: `state` `checking` while it is checked in the background, then `confirmed`, or `rejected` with `rejection_reason`, and its `files` |
| `upload_screenshot` | `upload_id`, `release_id`, `kind` (`title` or `gameplay`) | `release_id` and the `screenshot` as release JSON shows it |
| `upload_video` | `upload_id`, `release_id`, `source_sha1`, `capture` (`tool`, `version`, `captured_at`), optional `verification` | The private `playthrough`: id, release, source, file count, duration, codecs and chapters |

After `request_upload`, PUT each file to `upload_url` followed by its package-relative name, with the same Basic credentials, the file's `Content-Type` and `Content-Digest: sha-256=:BASE64:`. `GET /v1/uploads/{upload_id}.json` lists what has arrived. `release_id` is the release's stable id, never its title or a checksum. `upload_url` is built from the MCP request's own origin. `confirm_upload` answers at once; call it again until the state is `confirmed` or `rejected`. `upload_video`'s verification must name the authenticated admin as `verifier`.

Tool errors use `isError: true` and `structuredContent: {"error":{"code":"..."}}`: `invalid_input`, `not_found` (upload or release), `upload_expired`, `upload_conflict` (the upload is in the wrong state or of the other type, or was already used), `upload_rejected` (the PNG exceeds the release system's limits), `target_mismatch` (`source_sha1` is not the release's and no verification explains it), `uploads_disabled` (`request_upload` before storage is configured) and `storage_unavailable`. A failed `upload_screenshot` or `upload_video` leaves the upload confirmed, so retry with the same `upload_id` before it expires.

## Device compatibility

`record_compatibility_result` appends what a named reviewer saw after playing one exact file of one stable release on one device class. Every argument except `reason` and `requires_input` is required, and no others are accepted:

| Argument | Meaning |
| --- | --- |
| `release_id` | Stable release public ID, at most 200 characters. A shared checksum never selects a release. |
| `sha1` | The exact file played, 40 hexadecimal characters, case-insensitive. It must be a medium of the release (a secondary disk is fine). |
| `device` | `steam_machine` or `steam_deck`, the device class it was played on. |
| `status` | `works`, `attention` (a recorded problem, such as performance, explained in one sentence), `does_not_work`, or `unknown` to withdraw an earlier result for that device without claiming the opposite. |
| `reason` | One short public sentence on why, at most 200 characters, no control characters. Required for `attention`, optional for `does_not_work`, refused for `works` and `unknown`. |
| `core`, `core_version` | The libretro core (`^[a-z0-9][a-z0-9_.-]{0,63}$`, for example `mesen`) and its version or build as the launcher reports it, at most 100 characters. |
| `startup_revision` | The release's current `startup.revision` (from `get_release`, `get_compatibility` or the public release JSON): the launch configuration tested. |
| `tested_at` | When it was played: ISO 8601 with `Z` or an offset, not in the future. |
| `observed`, `limits` | What the reviewer saw and what the test did not cover: nonblank, at most 500 characters each, no control characters (one paragraph). Both are public. |
| `reviewer` | The reviewer's display name, at most 100 characters. Internal: it never appears in public JSON. |
| `owns_file` | Must be `true`: the reviewer owns that exact file. |
| `requires_input` | Optional, default `[]`: input devices besides the controller that the release needs to be playable on this device class, from the closed list `keyboard`, `mouse`, each at most once (stored sorted). Separate from `status`: a game can work and still need a keyboard; the launcher shows Attention while a listed device is not connected, unless the status is `does_not_work`, which outranks it. Public. |
| `playthrough_ids` | Optional, default none: up to 20 ids of this release's private playthroughs (from `upload_video`) that show the result. Another release's playthrough returns `target_mismatch`. Internal: they appear in `get_compatibility`'s history, never in public JSON. |
| `retry_key` | Nonblank, at most 200 characters. An identical retry returns the original result; changed arguments with a used key return `retry_conflict`. |

Success returns `{"data":{"release_id","result","current"}}`: the stored history entry and the release's new `current`. Errors are `invalid_input` (schema, attestation, time, text, or a reason missing for `attention` or given for `works`/`unknown`), `not_found` (unknown release), `target_mismatch` (the file is not in the release, or `startup_revision` is not current) and `retry_conflict`. The tool is non-read-only, non-destructive and idempotent per retry key.

`requires_input` is the one plain array in these results (a closed set of at most two values, never paginated); the `history` page continues with `cursor` like every other collection. Results are append-only: a retest or correction is a new result, and earlier ones stay in `get_compatibility`'s history with their reviewer and `recorded_at`. Public `release.compatibility` has exactly two keys, `steam_machine` and `steam_deck`. Each is the newest result for that device whose `startup_revision` equals the release's current one, as `{status, reason, core, core_version, startup_revision, tested_at, observed, limits, requires_input}`, or `{"status":"unknown"}` when there is none, when the newest is a withdrawal, or after a media or startup correction changes the revision. One device class never stands in for the other. Recording touches the release, so its release and media ETags and Last-Modified change at once; CDN copies may stay up to their 300 seconds. Unknown never stops a launch.

## Registering releases

`register_release` takes a `reason`, an `idempotency_key`, `game_id` or `new_game` `{id, title}`, the `system`, optional `region` and `revision`, and `media` (`sha1` with optional `size`, `crc32`, `md5`, `format`, `label`, `key`, `role`). It returns the new release as `get_release` does. Errors are `invalid_input`, `conflict` (an existing checksum or game id, or a reused retry key with different arguments) and `admin_unavailable` (`CATALOG_ADMIN_NAME` is not configured). [Registering releases over MCP](../README.md#registering-releases-over-mcp) has how retries and revisions work.

## Codex configured-header connection

`.codex/config.toml` carries the server for Codex, following [Codex MCP configuration](https://developers.openai.com/codex/mcp/):

```toml
[mcp_servers.arcadary_catalog]
url = "https://api.arcadary.org/mcp"
env_http_headers = { Authorization = "ARCADARY_CATALOG_AUTHORIZATION" }
```

`.mcp.json` carries the same server for Claude Code, with `headers.Authorization` set to `${ARCADARY_CATALOG_AUTHORIZATION:-}`. Without the variable, both clients reach only the `401` challenge.

`fnox.toml` holds the header as `ARCADARY_CATALOG_AUTHORIZATION`, encrypted with age. fnox's shell hook exports it with the other secrets in this checkout, so Claude Code or Codex started from a shell there connects. Anything else started from such a shell inherits it as well, including the agent loop, just as it already inherits the shared login. After rotating the login, store the new header too:

```bash
fnox exec -- sh -c 'printf "Basic %s" "$(printf "%s:%s" "$VALIDATION_REVIEWER_USERNAME" "$VALIDATION_REVIEWER_PASSWORD" | base64 | tr -d "\n")"' \
  | fnox set ARCADARY_CATALOG_AUTHORIZATION
```

Provision `ARCADARY_CATALOG_AUTHORIZATION` in the **intended Codex process's environment** through a secure secret manager or launcher. Its complete value must be the Basic scheme plus the base64 encoding of the configured username, a colon and password. Base64 is reversible. Do not print the value, put it in shell history, commit it, store it in a URL, or paste it into this TOML. Restart the intended client with its refreshed environment after rotation. Configuring a terminal environment alone does not configure a separately launched app. Do not use `codex mcp login`: there is no OAuth login here.

## Enabling hosted access

The Rails guard runs before request logging and host validation, silencing the whole private request, including malformed bodies, checksum requests, admin notes, Authorization and exception details. Parameter filters remain defense in depth for the public API. Application suppression does not control the HTTP server, proxy, CDN or client logs.

Before enabling access, the maintainer must verify TLS and all delivery layers. On Cloudflare and any reverse proxy, match **exactly `/mcp` and every path beginning `/mcp/`**, and **`/v1/uploads` with its complete subtree and suffix/error variants**, for **every HTTP method**. Cover normalized repeated-slash/encoded equivalents too: bypass cache, disable access/request-body/header logging and tracing, exclude analytics that retain IPs, queries, Authorization or responses, and never include these paths in public read cache rules. Keep Thruster request logging disabled as documented in the [deployment/privacy instructions](../README.md#privacy-and-logging). Verify rejected/authentication/error responses as well as successful POSTs/PUTs, and confirm no cache hit, stored private response, request body or Basic header at any layer. Public `/v1/lookup`, release and media caching remains anonymous and caller-independent.

Owner: configure the intended Codex app environment and verify its connection. Maintainer: verify hosted TLS, proxy/CDN cache and log exclusions before enabling access. A deployed smoke test requires a separately owner-authorized deployment; this change performs no deployment or live catalog edits.

## Local real-client evidence

The earlier read-tool implementation passed on 2026-11-28 using the installed **Codex CLI 0.172.0 app-server** on macOS arm64, with an isolated Codex home, a temporary SQLite catalog containing only synthetic metadata, and disposable Basic credentials supplied through `env_http_headers.Authorization`. No model turn, account credential copy or real catalog access was involved. The client initialized the MCP connection, sent the initialized notification, listed the then-existing four tools, searched the synthetic title, inspected its game and release, and read one synthetic audit entry through `mcpServer/tool/call`. All four calls returned `isError: false`, with matching structured and JSON-text results. Subsequent HTTP requests used **2025-06-18** and all observed MCP responses carried `no-store`; the initialized notification received 202 and reads received 200. The local server and client were stopped after the test. The upload tools, `record_compatibility_result` and `get_compatibility` are covered by in-process HTTP/MCP request specs; they have not been exercised through a real external MCP client.

This exercised a real configured-header Codex MCP client over loopback HTTP, separately from the in-process specs. Hosted TLS, proxy/CDN caches/logs, a deployed smoke test, and the owner's intended Codex app environment remain **unperformed** until the manual checks above are completed.
