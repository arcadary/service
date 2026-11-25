# Arcadary service

The remote service for [Arcadary](https://github.com/arcadary/arcadary): a Rails 8.1 application for the project's homepage and launcher JSON API. The first slice identifies a game and release through `GET /v1/releases/sha1/{sha1}.json`, seeded with µCity and Tobu Tobu Girl. The remaining catalog, compatibility, controller-profile and page features are still to be built. Nothing is deployed.

```bash
mise install
mise run setup
mise run dev
mise run ci
```

What it is for, the rules and the setup are in [AGENTS.md](AGENTS.md).

## Privacy and logging

Checksum reads are anonymous, but they reveal which file a household has and the caller's IP address to the service and CDN. No player account or session is required; the endpoint sets no cookie. This does not make reads private.

Rails silences lookup requests before request-start logging, covering parameter, controller and SQL logs as well, including paths with repeated slashes. SHA-1 parameters are also filtered defensively. Routing errors (for example, a missing `.json` suffix) can still log the checksum URL at error level, without the client IP. The endpoint adds no telemetry or request-specific log lines. The production image sets `LOG_REQUESTS=false` to disable Thruster's access logs, which otherwise pair checksum URLs with client IPs. Keep that setting disabled, including any `THRUSTER_LOG_REQUESTS` override.

Local checks capture Rails logs and Thruster stdout. External CDN and deployment-proxy logging (including kamal-proxy) remains unverified until deployment and is not covered by these checks. Deployment must verify those logging policies separately.

## Licence

MIT, see [LICENSE](LICENSE).
