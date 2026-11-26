# Arcadary service

The remote service for [Arcadary](https://github.com/arcadary/arcadary): a Rails 8.1 application for the project's homepage and launcher JSON API. The first slice identifies a game file through `GET /v1/lookup/{sha1}.json`, which redirects to its release and game, seeded with µCity and Tobu Tobu Girl. The remaining catalog, compatibility, controller-profile and page features are still to be built. Nothing is deployed.

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

The specs check Rails logs only; the rest was checked on the deployed host. kamal-proxy runs with Docker's `none` log driver and keeps no request log, because that log records `X-Forwarded-For`, which Cloudflare always fills with the visitor's IP, next to each path and so each checksum. Cloudflare's "Remove visitor IP headers" transform does not change that header for ordinary visitors. `cloudflared` logs no per-request lines at its default level. Check these again whenever the proxy, the tunnel or the image changes. Cloudflare itself still sees every visitor's IP.

## Deployment

Production is one Hetzner host behind Cloudflare, created by the infrastructure repository, and the service answers on `api.arcadary.org`. Kamal builds the image locally for amd64 and moves it to the host through its local registry, so no registry account is needed. fnox supplies the host's address (`DEPLOY_HOST`), `SECRET_KEY_BASE` and the tunnel's token (`TUNNEL_TOKEN`). The owner deploys, or an agent once the owner has confirmed that deploy:

```bash
fnox exec -- bin/kamal setup    # the first time: installs Docker, boots cloudflared and kamal-proxy, then deploys
fnox exec -- bin/kamal deploy   # every time after
```

Cloudflare terminates TLS. It reaches the origin only through a Cloudflare Tunnel, which the infrastructure repository creates: `cloudflared` runs on the host as a Kamal accessory, dials out to Cloudflare and hands each request to kamal-proxy in plain HTTP on Docker's `kamal` network. kamal-proxy publishes no ports on the host, the host's firewall has no web ports open, and the origin holds no certificate. The tunnel's token is a sensitive output of the infrastructure repository; pipe it into fnox without printing it (`fnox set TUNNEL_TOKEN` reads stdin). `bin/kamal accessory reboot cloudflared` picks up a new token or image.

## Licence

MIT, see [LICENSE](LICENSE).
