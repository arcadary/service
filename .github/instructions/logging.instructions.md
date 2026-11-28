---
applyTo: "**"
---

# Logging and privacy

- Never log a client IP address, and never log a checksum together with anything that could tie it to a household. `config/initializers/filter_parameter_logging.rb` filters the checksum parameter; extend it for every new identifying parameter.
- Telemetry is internal and anonymised (see `AGENTS.md`).
- Receipt middleware short-circuits the entire validation path family, including malformed paths and repeated slashes, before Rails request logging or parsing. Silence application and SQL logs across success and error paths; never log a raw body, admission, credential, Authorization header, player filename or stable device/install identifier. Parameter filtering is defense in depth, not permission to parse a rejected body.
- Preserve `LOG_REQUESTS=false` and any `THRUSTER_LOG_REQUESTS` override, kamal-proxy's `none` log driver, unpublished proxy ports and disabled forwarded headers. Do not claim reads/uploads are private in transit: service/proxies/CDN see IP, checksum and bytes. Prior deployed-read observations do not establish upload logging/cache/tempfile protections; maintainer checks remain in README.
