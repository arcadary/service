# Arcadary service

The remote service for [Arcadary](https://github.com/arcadary/arcadary), a retro game launcher for Steam Machine and Steam Deck. The launcher works without it. When a device is online, the service gives it what cannot ship inside the app: catalog updates, compatibility records per device class and controller profiles.

This repository is private and nothing is deployed yet. It holds an empty Rails application; every feature below is still to be built.

## What the service is

One Rails application serves two things: the project's **homepage** (server-rendered HTML for people) and the **JSON API** the launcher talks to.

- **Public API reads** are anonymous: no player account, no cookie, no personalised response. The same URL returns the same bytes, so a CDN can cache them.
- **One opt-in write path** takes run reports from devices. A report is triage and supporting evidence; it never changes a game's status by itself.
- **Reviewer and admin pages** are authenticated and never served from a shared cache. A game becomes Verified only when a named reviewer who owns that exact file has played it.
- **Later:** artwork delivery (after a rights review) and a pairing redirect.

The background is the launcher repository's spike report, [docs/spike-174-remote-service.md](https://github.com/arcadary/arcadary/blob/6a8db20ace59afce558a8daa06dfdd84dca48471/docs/spike-174-remote-service.md), and the owner's decisions on [arcadary/arcadary#174](https://github.com/arcadary/arcadary/issues/174).

## Rules

- **No game files, ever.** The service never receives, stores, serves or links to a ROM, and never describes where to get one. A file is identified by its checksum only. No file names from a player's device either.
- **No player accounts.** A read by checksum still shows the service and the CDN which file a household has, together with its IP address. Say so honestly in code comments, the logging policy and documents; never claim reads are private.
- **Telemetry is for internal use only, and anonymised.** It exists to run and improve the service, is never shared or sold, and holds nothing that identifies a person, a household or a device: no IP address, no stable device ID, no file names.
- **Nothing is logged that is not needed.** No IP addresses in application logs or telemetry, and no checksum next to anything that could tie it to a household, unless an issue decides otherwise.
- **No secrets in git.** Tools come from mise and secrets from fnox, which hands them to the application as environment variables. Rails encrypted credentials are not used: there is no `config/credentials.yml.enc` and no `config/master.key`, and `.env*` files and Kamal secrets stay out of the repository. There is no `fnox.toml` yet; it comes with the first secret.
- **Agents never deploy, provision or spend.** No `kamal deploy`, no registry push, no server, domain or account. `config/deploy.yml` holds the generator's placeholder values.
- **Ask before downloading anything** other than the tools in `mise.toml` and the gems in `Gemfile.lock`.
- **Keep it simple.** A normal Rails application: server-rendered HTML for the homepage and the reviewer pages, a versioned JSON API under `/v1`, no separate JavaScript frontend.
- Commit only when asked. Work comes from GitHub issues, and every change arrives as a pull request.

## Decided, not built yet

These are the owner's choices. Do not replace them with something else, and do not build them outside an issue that asks for it.

- **Server:** Falcon with the official `falcon-rails` integration. The generated application still runs Puma behind Thruster; an issue will swap it, with evidence that slow outbound requests do not hold up unrelated ones.
- **Database:** SQLite, with short transactions and bounded writes. Reconsider only after measured contention.
- **Pages:** Tailwind and ViewComponent for the public and reviewer pages.
- **Deployment:** a Docker image deployed with Kamal to one small host (Hetzner preferred), behind Cloudflare's cache. Cache rules cover suitable public reads only, never authenticated or write routes.
- **Protocol:** immutable revision URLs get long caching; manifest and latest lookups get short caching and ETags. Illustrative, not a final contract: `/v1/manifest.json`, `/v1/releases/sha1/{sha1}.json`, `/v1/games/{id}/revisions/{hash}.json`, `/v1/profiles/{hash}.json`, `/v1/reports`.

## Setup

Tools are managed with [mise](https://mise.jdx.dev): `mise.toml` pins Ruby 3.4.13 and installs fnox. `.ruby-version` and the Dockerfile's `RUBY_VERSION` name the same Ruby for GitHub Actions and the image; change all three together. Rails is 8.1.

```bash
mise install       # Ruby and fnox, once
mise run setup     # installs gems and prepares the SQLite databases in storage/
mise run dev       # serves http://localhost:3000
```

A shell with `mise activate` prints these and the other common commands when it enters the folder (the `enter` hook in `mise.toml`). Each task is a thin name for a `bin/` script, and `mise tasks` lists them all. Keep the hook's list in step when a task is added.

`/up` answers 200 when the application has booted.

## Checks

Run all of them before handing work over:

```bash
mise run ci
```

It runs `bin/ci`, the steps in `config/ci.rb`: setup, RuboCop (`bin/rubocop`), the gem audit (`bin/bundler-audit`), the importmap audit, Brakeman (`bin/brakeman`), the tests (`bin/rails test`) and the seeds. GitHub Actions runs the same tools on every pull request (`.github/workflows/ci.yml`). There are no system tests yet, so the generator's `system-test` CI job is removed; add it back with the first test in `test/system`.

Tests use the SQLite test database and no network. A test that needs an outside service uses a fake.

## Agent loop

Work runs through [ub-agents](https://agents.uberblick.ai): `ub-agents.yaml` holds the roles and labels, `.agents/` the instructions, and `.agents/ub_agents.md` the merge rules. An issue labelled `needs-preparation` is prepared, implemented, reviewed (by Codex) and merged; the owner merges what the rules leave to a maintainer. Dependabot pull requests skip preparation and review and go straight to the integrator, which merges minor and patch updates once CI passes and leaves majors and sensitive packages to the owner.

## Where things are

- `app/`, `config/`, `db/`, `test/`: the Rails application as generated.
- `storage/`: SQLite databases, git-ignored.
- `Dockerfile`, `config/deploy.yml`, `.kamal/`: the generator's container and Kamal files, not adapted yet.
