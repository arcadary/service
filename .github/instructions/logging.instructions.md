---
applyTo: "**"
---

# Logging and privacy

- Never log a client IP address, and never log a checksum together with anything that could tie it to a household. `config/initializers/filter_parameter_logging.rb` filters the checksum parameter; extend it for every new identifying parameter.
- Telemetry is internal and anonymised (see `AGENTS.md`).
