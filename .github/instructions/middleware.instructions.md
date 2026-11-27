---
applyTo: "lib/middleware/**,config/application.rb"
---

# Rack middleware

- Receipt is an explicit exception to controller routing: `ValidationReceipts` owns its JSON transport envelope before ActionController instrumentation can parse parameters. Require it explicitly at boot and exclude `lib/middleware` from autoloading. Other endpoints continue through Rails normally.
- Match the entire validation path family, including malformed paths and repeated slashes, before request logging. Return cookie-free `no-store` JSON for every handled response. Use the executor for connection cleanup and silence application/SQL logging for the full operation. Read neither query tokens nor cookies.
- Availability precedes media/encoding and every body read/change. POST media and the 1,024-byte bound run before JSON parsing, reading at most 1,025 bytes. Reject non-object/extra fields. PUT rejects JSON without parsing; use Rack Content-Length, including Puma's decoded length. Validate length/path/admission/persisted facts, eligibility and admitted length before the body. Completed retries retain those gates but never reread/rewrite files.
- HTTP status/error mapping belongs here; metadata, admissions, locking, persistence and integrity belong in services. Services raise typed exceptions, never HTTP responses. Keep SQLite transactions short and never open one across a body read. Recovery and upload require the same cross-process checksum lock.
- Exercise the full Rails Rack stack with unread/parse-detecting bodies, overlapping failures and captured logs. Request specs cannot establish upstream buffering, transport errors or deployed filesystem isolation; document the manual checks separately.
