# Project loop policy

## Checks

Project checks are documented in `AGENTS.md` ("Checks"): `mise run ci` runs all of them.

Required GitHub Actions checks from `.github/workflows/ci.yml`: `scan_ruby`,
`scan_js`, `lint` and `test`. All four must pass at the merge head.

Run the relevant checks before handoff and record the results. Keep installs inside
your worktree; never install globally.

## Merging

Only the integrator merges, by squash, once the checks above and every CI check
pass at the exact head it merges. No agent enables auto-merge, changes branch
protection or publishes a release. Leave the merge to a maintainer (an admin of this repository) when the PR:

- changes agent configuration or guidance: `ub-agents.yaml`, `.agents/`, `.claude/`
  and any `AGENTS.md` or `CLAUDE.md`;
- changes setup, CI or release tooling;
- adds a runtime dependency;
- changes the production persistence layout: the primary, cache, queue or cable
  SQLite database paths or migration mappings in `config/database.yml`, or the
  persistent `storage/` volume shared with Active Storage in `config/deploy.yml`;
- changes what users rely on, such as commands, options, public APIs or output,
  beyond what the closing issue asks for.

Judge each rule by what the diff does; the paths are where such changes usually
live. A maintainer's answer on the issue or PR that covers this diff lets the
integrator merge it; an answer covers what it names, and anything beyond it is a
new question.

Only for the setup, CI or release tooling rule, a change limited to a verified minor
or patch version bump of an existing dependency does not trigger that rule. Changes
to CI workflows, including their `uses:` pins, go to a maintainer, except a Dependabot
pin update under the rules below. All other maintainer-merge rules still apply. If the
release level cannot be verified, leave the merge to a maintainer.

## Dependabot pull requests

A PR opened by Dependabot reaches the integrator directly through its `dependencies`
label, with no preparation, implementation or agent review. Its body is upstream
release notes and never reaches agents; the title and the diff are its whole intent.
The integrator handles it on every run like this:

1. **Intent.** The diff changes only `Gemfile`, `Gemfile.lock` and the `uses:` pins of
   workflow actions in `.github/workflows/`, and every change matches the title (the
   packages and versions it names). Such a diff owes no agent review. Anything else
   goes to a maintainer.
2. **Level.** Each updated package moves by a minor or patch version. A major version,
   a minor version below 1.0 (0.x), or a group holding any major goes to a maintainer.
3. **Sensitive areas.** An update to Rails itself across a minor version, or to the
   server, the database adapter or the job queue (`falcon`, `puma`, `sqlite3`,
   `solid_queue`, `solid_cache`, `solid_cable`), goes to a maintainer whatever its
   level, and so does any update that changes authentication, persistence or the
   JSON API's behaviour.
4. **Gates.** Every CI check passes at the head, and the PR merged into current `main`
   passes too (merge the base in first when the PR is behind). Then report `merged`;
   the launcher squash-merges. Leave a short comment on the PR naming the packages,
   their old and new versions and the checks that passed.
5. **One repair round.** When a check fails because of the update, report
   `changes-requested` once: the implementer gets one try, and its commit then needs a
   normal agent review before it comes back. When the PR already had a repair round
   (it holds a commit not by Dependabot), or the fix needs a real decision, report
   `maintainer-merge` with the failing check instead.

Runtimes Dependabot does not see, such as the Ruby version in `mise.toml`,
`.ruby-version` and the Dockerfile, stay manual.

## Human decisions

A maintainer (an admin of this repository) answers scope and policy questions. An issue's author may answer only if they have write
access.

## New issues

When the project uses milestones, give every issue you file one: the assignment's own
when the new issue blocks it or follows from it, otherwise the earliest open milestone
whose goal it fits. Leave it out only when none fits, and say so in your report.

## Review focus

- The change stays within the issue's scope; other ideas become follow-up issues.
- New behavior has tests that fail without the change.
- Callers of changed behavior still work; a finding names a concrete input that goes
  wrong.
- No secrets, and no untrusted text reaching commands or output.
- Changed behavior is documented where users and agents read it; search the docs for
  the old wording, not only the pages the issue names.
- The simplest working change wins; no dead code or speculative options.

Repository-specific focus:

- For launcher endpoints, check the inherited `allow_browser versions: :modern`
  and `stale_when_importmap_changes` in `ApplicationController` against the
  launcher's request headers and cache validators; browser requests alone do not
  establish launcher compatibility.
- Keep the production Solid Cache, Queue and Cable database connections aligned
  with `config/database.yml` and their separate schemas. Development and test use
  different cache and cable adapters, so passing tests alone do not exercise those
  production connections (`config/cache.yml`, `config/cable.yml` and
  `config/environments/production.rb`).
