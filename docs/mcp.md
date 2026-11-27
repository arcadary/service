# Private catalog MCP

`/mcp` is the single admin's read-only MCP endpoint in the Rails application. It uses the official Ruby `mcp` SDK **1.11.0**, in stateless Streamable HTTP mode with finite JSON responses. It exposes no catalog writes, compatibility operations, files, downloads, submissions, shell, SQL or arbitrary URL tools. Catalog coverage is not a playability verdict.

The generated [HTTP endpoint documentation](../swagger/v1/swagger.yaml) is served at `/api-docs`. MCP `tools/list` publishes the input/output JSON schemas and help for each tool; `server/discover` serves SDK discovery for the modern protocol. All discovery is authenticated. These schemas, rather than the launcher's public JSON shapes, describe the private authoring records.

## Authentication and transport

Use HTTP Basic over **TLS** with the shared `VALIDATION_REVIEWER_USERNAME` and `VALIDATION_REVIEWER_PASSWORD` pair. Authentication is the entire access gate: there are no accounts, roles, scopes or per-tool permissions. It deliberately supports Codex's configured-header mode. It does not implement OAuth authorization, OAuth discovery or an interactive login; no OAuth conformance is claimed.

Every request to `/mcp` or its subtree requires the current pair, including unsupported methods, malformed bodies and errors. Missing or blank server configuration returns `503 authentication_unavailable`. Missing, malformed or wrong credentials return `401 unauthorized` and `WWW-Authenticate: Basic realm="Arcadary", charset="UTF-8"`. Credentials are checked against the workers' environment on every request; replace both variables and restart/replace **all** workers together to rotate. The old pair then fails on subsequent requests, including reconnects. There is no session token that bypasses rotation. This follows the [shared authentication contract](../README.md#private-service-authentication).

All responses carry `Cache-Control: no-store`, and the endpoint creates no cookie or persistent session. GET/DELETE and unsupported HTTP methods receive the SDK's `405`; unknown subpaths return `404` after authentication. Successful requests use POST with `Content-Type: application/json` and `Accept: application/json` (accepting both `application/json, text/event-stream` also works). No SSE subscription or resumable stream is enabled.

The SDK retains protocol negotiation. The legacy `initialize` handshake supports `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`; an unsupported proposal is counter-offered `2025-11-25`. A modern `2026-07-28` client uses `server/discover` and that protocol's per-request metadata instead of the legacy handshake. Send the negotiated `MCP-Protocol-Version` header on subsequent requests. The SDK rejects unsupported request versions and malformed envelopes. Older versions may omit structured results on the wire; the SDK also supplies JSON text content.

POST bodies are capped at **65,536 bytes**, read with the SDK's bounded reader even without Content-Length. JSON nesting is capped at **64**. Tool results are capped at **1 MiB** of structured JSON before the SDK adds its text-content representation; a larger result returns `invalid_input` rather than a partial collection. Reduce the page limit. The SDK's finite defaults remain enabled; no unlimited request option is used. Tools do not issue server-to-client requests or create background streams.

The explicit Host allow-list is `api.arcadary.org`, plus `localhost`, `127.0.0.1` and `[::1]` for local tests (ports allowed). The only accepted Origin value is `https://api.arcadary.org`. A missing Origin is permitted for the intended non-browser client; hostile origins, including `null`, are rejected even with valid Basic credentials. The application checks this stricter list before the SDK's additional DNS-rebinding checks. Forward the original Host through the trusted proxy.

## Tools and pagination

| Tool | Initial arguments | Data |
| --- | --- | --- |
| `search_games` | Optional `query` (case-insensitive title/alias substring, at most 200 characters), optional `system` | Page of `{id, title, authoring_revision}` summaries, ordered by stable game ID. System filters games with a release on that system. |
| `get_game` | `id` from search | `{type, id, authoring_revision, canonical, authored_fields, source, releases}`. Canonical title and aliases; existing release variant summaries. |
| `get_release` | Exactly one of `id` or `sha1` | `{type, id, authoring_revision, canonical, authored_fields, source}`. Stable release ID selects one edition; a SHA-1 can identify several candidates. |
| `get_catalog_history` | No required initial argument | Page of `{id, operation, admin_name, created_at, reason, record_changes}` audit entries, newest ID first. Each change retains its before/after authoring snapshots. |

Each initial call accepts `limit`: default **20**, range **1–50**. Systems are `nes`, `snes`, `gb`, `gbc`, `megadrive`, `pcengine`, `atari2600`, `c64`. SHA-1 is 40 hexadecimal characters, case-insensitive. Player filenames are never accepted.

Every collection uses `{ "items": [...], "next_cursor": "opaque-token-or-null" }`, including aliases, authored-field names, variants, media, ambiguous candidates, audit changes and collections inside before/after snapshots. No array is silently cut off. Alias ordering is lexical, releases/candidates use stable release ID, and media retain exact position order. Audit snapshot arrays retain the recorded order.

To continue **any** collection, call the **same tool** with **only** `cursor` set to its `next_cursor`. The returned `data` is that collection's next page, rather than a repeated enclosing record. The cursor retains the original page size and search/selection context. Follow nested cursors separately. A null cursor means complete. Cursors are signed, expire after one hour, and cannot cross tools; they are not credentials and still require Basic authentication. A changed nested record invalidates its cursor (`invalid_input`); restart the enclosing read. Root searches and relation pages use keyset continuation, not a frozen database snapshot: concurrent edits can change which records match. Audit entries are retained history.

Release `canonical` includes `game_id`, `system`, `region`, `revision`, effective `startup` (`schema`, `boot`, `drives`, startup `revision`), and paginated `media`. Each medium includes `key`, `position`, `role`, `label`, `sha1`, `size`, `format`, `crc32` and `md5`; unavailable metadata is null. Startup refers to medium keys across all pages, so consume every media page before interpreting it. `source` exposes the retained `source_title`, `source_system`, `source_region`, `source_revision` separately from effective canonical values. `authored_fields` identifies the fields deliberately authored; the values of those fields are in `canonical`. Available provenance is what the catalog retained, without invented source claims. Game source contains `source_title`.

Successful tool results have `isError: false` and `structuredContent: {"data": ...}`. Domain failures have `isError: true` and `structuredContent: {"error": {"code": ...}}`. Codes are `invalid_input` (selection, checksum, cursor or result bound), `not_found`, and `ambiguous_release`. The last includes `error.candidates`, a page of `{id, game_id, system, region, revision, authoring_revision}`. Continuing that page keeps `ambiguous_release` and returns the next candidates; call `get_release` with one candidate's `id` to inspect it. Malformed JSON/JSON-RPC and schema-invalid tool arguments remain SDK protocol errors (for example `-32700`, `-32600`, `-32602`), distinct from these domain failures. Unexpected application exceptions disclose no exception details.

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

Before enabling access, the maintainer must verify TLS and all delivery layers. On Cloudflare and any reverse proxy, match **exactly `/mcp` and every path beginning `/mcp/`**, for **every HTTP method**: bypass cache, disable access/request-body/header logging and tracing, exclude analytics that retain IPs, queries, Authorization or responses, and never include these paths in public read cache rules. Keep Thruster request logging disabled as documented in the [deployment/privacy instructions](../README.md#privacy-and-logging). Verify rejected/authentication/error responses as well as successful POSTs, and confirm no cache hit, stored private response, request body or Basic header at any layer. Public `/v1/lookup`, release and media caching remains anonymous and caller-independent.

Owner: configure the intended Codex app environment and verify its connection. Maintainer: verify hosted TLS, proxy/CDN cache and log exclusions before enabling access. A deployed smoke test requires a separately owner-authorized deployment; this change performs no deployment or live catalog edits.

## Local real-client evidence

Pending local Codex smoke-test results; in-process request specs alone do not establish real-client compatibility. Hosted tests and the intended owner app's configuration remain unperformed until the manual checks above are completed.
