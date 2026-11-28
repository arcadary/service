# Arcadary service

The Rails 8.1 application behind [Arcadary](https://github.com/arcadary/arcadary)'s remote service. It serves server-rendered HTML pages and a versioned JSON API under `/v1` for the launcher. This repository is public.

**Product intent lives in the project's Uberblick workspace**, not here: what the service is for, who it serves, the privacy and verification rules and the roadmap. `.uberblick.json` binds this repository to that workspace, and the `uberblick` MCP server (`ub mcp serve`, in `.mcp.json` and `.codex/config.toml`) reads it. Before changing user-facing behaviour, search the workspace, starting with the pages tagged `product-intent` and the decision records. A decision in force wins over anything here; when a change conflicts with one, stop and ask. This file holds the technical and implementation rules.

## Implemented

- `GET /v1/lookup/{sha1}.json`: a known checksum answers `301` to its resource, with `Cache-Control: public` for a day; an unknown one answers `404`. The target is `GET /v1/releases/{sha1}.json` (a release, its game, ordered media and validated startup), or `GET /v1/media/{sha1}.json` when the file is shared by several releases; both are cached for 300 seconds with ETags. See [Ordered media and startup](README.md#ordered-media-and-startup). The `.json` suffix is required. Errors are JSON with `no-store`. `/api-docs` documents the contract.
- An offline importer for eight pinned No-Intro lists (29,336 distinct checksums) and two bundled homebrew seeds that need no DATs. Commands, identity rules and the CC-BY-SA-4.0 catalog licence: [Catalog data](README.md#catalog-data).
- The owner's capture device uploads title/gameplay PNGs per release with a bearer token. The service re-encodes pixels, stores them privately in R2 and serves content-addressed PNG URLs through the Rails API. Screenshots carry their own image licence; the catalog licence excludes images. See [Screenshots](README.md#screenshots).
- Shared database operations create and correct catalog metadata with expected authoring revisions, retry protection and atomic audit history. Aliases and retained source values stay internal. See [Catalog authoring](README.md#catalog-authoring).
- Authenticated admins declare and upload private HLS packages for an exact stable release, retaining capture evidence and durable progress. Staging exposes metadata only, without playback or publication. See [Private playthrough staging](README.md#private-playthrough-staging).

## Rules

- **Game files.** Never serve, link to or describe where to get a game file. Identify files by SHA-1 only; never accept a file name from a player's device. The only code path that receives file bytes is the validation-request flow (milestone *Validation requests*): private storage on the service host, downloads only for authenticated reviewers, no public route, preview, execution or unpacking.
- **Media rights.** Title and gameplay screenshots from the capture device are permitted. The owner-approved narrow video exception permits authenticated private HLS staging and delivery, including the private Donkey Kong trial; commercial footage stays out of public distribution and anonymous responses. No other clips, box art or manuals. Uploads, screenshot licences and the catalog licence grant no video rights. Use the recorded image licence for screenshots and honour takedown requests at `takedown@arcadary.org`.
- **Public reads are anonymous and caller-independent.** No account, cookie, session or personalised response on any public read: the same URL returns the same bytes, so a CDN can cache it. Comments, the logging policy and documents never claim reads are private: a read by checksum shows the service and the CDN which file a household has, with its IP address.
- **Authenticated routes** (reviewer pages, admin tools) send `Cache-Control: no-store` on every response, errors included, and are never covered by a CDN cache rule.
- **Logging and telemetry.** No IP address, stable device ID or file name in application logs or telemetry, and no checksum next to anything that could tie it to a household, unless an issue decides otherwise. Telemetry is internal and anonymised. Log nothing that is not needed. The lookup's protections and the deployment checks still outstanding are in [Privacy and logging](README.md#privacy-and-logging).
- **No secrets in git.** Tools come from mise and secrets from fnox, which hands them to the application as environment variables. Rails encrypted credentials are not used: there is no `config/credentials.yml.enc` and no `config/master.key`, and `.env*` files and Kamal secrets stay out of the repository. `fnox.toml` holds the deploy secrets (`DEPLOY_HOST`, `SECRET_KEY_BASE`, `TUNNEL_TOKEN`), encrypted with age, and is committed; the age key is not. Never decrypt, print or copy a value from it. The host's address is one of them because anyone who knows the origin's address can reach it around the cache.
- **Agents deploy only when the owner confirms, and never provision or spend.** An agent may run `fnox exec -- bin/kamal setup` or `fnox exec -- bin/kamal deploy` after the owner has explicitly confirmed that deploy in the conversation; a confirmation covers one deploy, not the next. No push to an outside registry, no server, domain or account. `config/deploy.yml` deploys to the host the infrastructure repository creates (see [Deployment](README.md#deployment)). Kamal's output names the host's address: filter it out, and never copy it into an issue, pull request or commit.
- **Ask before downloading anything** other than the tools in `mise.toml` and the gems in `Gemfile.lock`.
- **Keep it simple.** A normal Rails application: server-rendered HTML for the homepage and the reviewer pages, a versioned JSON API under `/v1`, no separate JavaScript frontend.
- Commit only when asked. Work comes from GitHub issues, and every change arrives as a pull request.

## Code conventions

- **No code comments.** Code says what it does through its names and structure; when it needs a comment to be understood, change the code instead. A comment is the rare exception, for a reason the code cannot show (a workaround for an outside bug, with its link). Context belongs in the commit message, the pull request or the issue. Specs never test comments.

The short version is below. The full guidelines are in [`.github/instructions/`](.github/instructions/), one file per area; read the ones for the files you change. Each file names the paths it covers in its `applyTo` header.

- [controllers](.github/instructions/controllers.instructions.md), [services](.github/instructions/services.instructions.md), [decorators](.github/instructions/decorators.instructions.md), [models](.github/instructions/models.instructions.md)
- [code style](.github/instructions/code-style.instructions.md), [API design](.github/instructions/api.instructions.md), [specs](.github/instructions/specs.instructions.md), [logging and privacy](.github/instructions/logging.instructions.md)

When a change does not fit them, say why in the pull request rather than working around them quietly. A new area gets a new file.

- **Small controllers.** A controller action calls a service and renders a decorator, nothing else:

  ```ruby
  class ReleasesController < ActionController::API
    def show
      render json: ReleaseDecorator.decorate(@release)
    end
  end
  ```

- **Services** hold the logic, in `app/services/` (for example `ReleaseService.find_by(sha1:)`). They signal failure by raising an exception (`ReleaseNotFound`, `InvalidSha1`), never by returning `nil` or an error value. Controllers map those exceptions to responses with `rescue_from`.
- **Decorators** in `app/decorators/` shape the JSON a controller renders (`ReleaseDecorator.decorate(release)`), as plain Ruby classes.
- **Before actions** do whatever they can: loading the record (`before_action :set_release`, which calls the service and sets `@release`), and conditional requests (a `before_action` that answers `304` from the ETag and returns early).

## Decided, not built yet

These are the owner's technical choices. Do not replace them with something else, and do not build them outside an issue that asks for it.

- **Server:** Falcon with the official `falcon-rails` integration. The generated application still runs Puma behind Thruster; an issue will swap it, with evidence that slow outbound requests do not hold up unrelated ones.
- **Database:** SQLite, with short transactions and bounded writes. Reconsider only after measured contention.
- **Pages:** Tailwind and ViewComponent for the public and reviewer pages.
- **Deployment:** a Docker image deployed with Kamal to one small host (Hetzner preferred), behind Cloudflare's cache. Cache rules cover suitable public reads only, never authenticated or write routes.
- **Protocol:** immutable revision URLs get long caching; manifest and latest lookups get short caching and ETags. Illustrative, not a final contract: `/v1/manifest.json`, `/v1/releases/sha1/{sha1}.json`, `/v1/games/{id}/revisions/{hash}.json`, `/v1/profiles/{hash}.json`, `/v1/reports`.

## Setup

Tools are managed with [mise](https://mise.jdx.dev): `mise.toml` pins Ruby 3.4.13 and installs fnox. `.ruby-version` and the Dockerfile's `RUBY_VERSION` name the same Ruby for GitHub Actions and the image; change all three together.

Screenshot decoding requires the native libvips library on the normal library search path. On macOS, install it with `brew install vips` before setup or checks. GitHub CI and the Docker image already install libvips.

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

It runs `bin/ci`, the steps in `config/ci.rb`: setup, RuboCop (`bin/rubocop`), the gem audit (`bin/bundler-audit`), the importmap audit, Brakeman (`bin/brakeman`), the specs (`bin/rspec`), the OpenAPI check and the seeds. GitHub Actions runs the same tools on every pull request (`.github/workflows/ci.yml`). There are no system tests yet, so the generator's `system-test` CI job is removed; add it back with the first system spec in `spec/system`.

Tests are RSpec specs in `spec/` (models in `spec/models`, endpoints as request specs in `spec/requests`); there is no Minitest. Every JSON API endpoint is specified with [rswag](https://github.com/rswag/rswag) in its request spec, and `mise run openapi` writes the OpenAPI document `swagger/v1/swagger.yaml` from those specs. Commit the regenerated document with the change; `bin/ci` fails when it is out of date. The document and a browsable UI are served at `/api-docs`. They use the SQLite test database and no network, and a spec that needs an outside service uses a fake.

## Agent loop

Work runs through [ub-agents](https://agents.uberblick.ai): `ub-agents.yaml` holds the roles and labels, `.agents/` the instructions, and `.agents/ub_agents.md` the merge rules. An issue labelled `needs-preparation` is prepared, implemented, reviewed and merged; the owner merges what the rules leave to a maintainer. Issues in a milestone merge into the milestone's own branch (`milestone/<slug>`, named in the milestone's description), and an admin merges that branch into `main` to release the milestone. Dependabot pull requests skip preparation and review and go straight to the integrator, which merges minor and patch updates once CI passes and leaves majors and sensitive packages to the owner.

## Where things are

- `app/`, `config/`, `db/`, `spec/`: the Rails application, catalog and screenshot models, seeds and specs.
- `storage/`: SQLite databases, git-ignored.
- `swagger/v1/swagger.yaml`: the OpenAPI document, generated from the request specs; never edited by hand.
- `Dockerfile`: production image with Thruster request logging disabled.
- `config/deploy.yml`, `.kamal/secrets`: the Kamal deploy to production, on `api.arcadary.org`, behind the Cloudflare Tunnel that the `cloudflared` accessory runs.
- `fnox.toml`: the deploy secrets, encrypted with age.
- `.uberblick.json`: the binding to the project's Uberblick workspace, where product intent is written down.
