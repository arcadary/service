# Arcadary service

The remote service for [Arcadary](https://github.com/bk-one/arcadary), a retro game launcher for Steam Machine and Steam Deck. The launcher works without it. When a device is online, the service gives it what cannot ship inside the app: catalog updates, compatibility records per device class and controller profiles.

This repository is private and nothing is deployed yet. It holds an empty Rails application; every feature below is still to be built.

## What the service is

- **Public reads** are anonymous: no player account, no cookie, no personalised response. The same URL returns the same bytes, so a CDN can cache them.
- **One opt-in write path** takes run reports from devices. A report is triage and supporting evidence; it never changes a game's status by itself.
- **Reviewer and admin pages** are authenticated and never served from a shared cache. A game becomes Verified only when a named reviewer who owns that exact file has played it.
- **Later:** artwork delivery (after a rights review) and a pairing redirect.

The background is the launcher repository's spike report, [docs/spike-174-remote-service.md](https://github.com/bk-one/arcadary/blob/6a8db20ace59afce558a8daa06dfdd84dca48471/docs/spike-174-remote-service.md), and the owner's decisions on [bk-one/arcadary#174](https://github.com/bk-one/arcadary/issues/174).

## Rules

- **No game files, ever.** The service never receives, stores, serves or links to a ROM, and never describes where to get one. A file is identified by its checksum only. No file names from a player's device either.
- **No player accounts and no telemetry by default.** A read by checksum still shows the service and the CDN which file a household has, together with its IP address. Say so honestly in code comments, logs policy and documents; never claim reads are private.
- **Nothing is logged that is not needed.** No checksums or IP addresses in application logs unless an issue decides otherwise.
- **No secrets in git.** `config/master.key`, `.env*` and Kamal secrets stay out of the repository. There is no `config/credentials.yml.enc` yet; create it with `bin/rails credentials:edit` when the first secret is needed, and give the key to the owner.
- **Agents never deploy, provision or spend.** No `kamal deploy`, no registry push, no server, domain or account. `config/deploy.yml` holds the generator's placeholder values.
- **Ask before downloading anything** other than the gems in `Gemfile.lock`.
- **Keep it simple.** A normal Rails application: server-rendered HTML, a versioned JSON API under `/v1`, no separate JavaScript frontend.
- Commit only when asked. Work comes from GitHub issues, and every change arrives as a pull request.

## Decided, not built yet

These are the owner's choices. Do not replace them with something else, and do not build them outside an issue that asks for it.

- **Server:** Falcon with the official `falcon-rails` integration. The generated application still runs Puma behind Thruster; an issue will swap it, with evidence that slow outbound requests do not hold up unrelated ones.
- **Database:** SQLite, with short transactions and bounded writes. Reconsider only after measured contention.
- **Pages:** Tailwind and ViewComponent for the public and reviewer pages.
- **Deployment:** a Docker image deployed with Kamal to one small host (Hetzner preferred), behind Cloudflare's cache. Cache rules cover suitable public reads only, never authenticated or write routes.
- **Protocol:** immutable revision URLs get long caching; manifest and latest lookups get short caching and ETags. Illustrative, not a final contract: `/v1/manifest.json`, `/v1/releases/sha1/{sha1}.json`, `/v1/games/{id}/revisions/{hash}.json`, `/v1/profiles/{hash}.json`, `/v1/reports`.

## Setup

Ruby is pinned in `.ruby-version` (3.4.13) and Rails is 8.1. Install that Ruby with your version manager (for example `mise install ruby@3.4.13`), then:

```bash
bin/setup --skip-server   # installs gems and prepares the SQLite databases in storage/
bin/dev                   # serves http://localhost:3000
```

`/up` answers 200 when the application has booted.

## Checks

Run all of them before handing work over:

```bash
bin/ci
```

It runs the steps in `config/ci.rb`: setup, RuboCop (`bin/rubocop`), the gem audit (`bin/bundler-audit`), the importmap audit, Brakeman (`bin/brakeman`), the tests (`bin/rails test`) and the seeds. GitHub Actions runs the same tools on every pull request (`.github/workflows/ci.yml`).

Tests use the SQLite test database and no network. A test that needs an outside service uses a fake.

## Where things are

- `app/`, `config/`, `db/`, `test/`: the Rails application as generated.
- `storage/`: SQLite databases, git-ignored.
- `Dockerfile`, `config/deploy.yml`, `.kamal/`: the generator's container and Kamal files, not adapted yet.
