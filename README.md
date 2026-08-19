# AIcarus — a Telegram-driven, propose-only dev automation starter kit

AIcarus (internally, the tooling still goes by its original name, "devbrain" — you'll
see `devbrain-*` throughout the scripts and docs below) lets you chat with your own
projects over Telegram, have a cheap LLM turn
that chat into queued work items, and have a more capable coding agent pick up
*approved* items overnight — always on a feature branch, always as a pull request,
never merged without you. It's the "starter kit" version of a system one person
built for their own multi-repo, one-operator dev setup. Everything identifying to
that original setup has been stripped out; what's left is the generic machinery,
for you to point at your own repos, your own bot, your own model of choice.

This is not a polished product. It's a working reference implementation you're
expected to read, understand, and adapt — the same way you'd fork a dotfiles repo,
not install a SaaS.

## The architecture, in one loop

```
      you, on Telegram
            │
            ▼
  ┌───────────────────┐        proposes work items
  │  messaging bridge   │ ─────────────────────────────┐
  │  + cheap LLM router │                              ▼
  └───────────────────┘                     ┌─────────────────────┐
            ▲                               │  file-based queue    │
            │ weekly interview               │  (~/dev/queue/*.md)   │
            │ (interactive, you approve)     └─────────────────────┘
            │                                          │
  ┌───────────────────┐                                │ nightly runner
  │  you, deciding      │ ◄─────── PR opened ───────────┘   picks up
  │  what to merge      │          (propose-only)            approved items
  └───────────────────┘                                          │
            ▲                                                    ▼
            │                                        ┌───────────────────────┐
            └──────── coding agent branch/PR ────────│  coding agent (Claude   │
                                                       │  Code) executes on a    │
                                                       │  feature branch         │
                                                       └───────────────────────┘

  a wiki (docs/wiki-example/ shows the convention) records decisions and lessons
  learned along the way, read by both the interview and the nightly runner.
```

Five moving parts:

1. **A messaging bridge.** Something that turns Telegram (or Slack, or whatever
   chat surface you use) messages into a program you can shell out to, and lets a
   program send messages back. The reference implementation uses
   [OpenClaw](https://github.com/openclaw/openclaw), an open-source Telegram
   bridge — but this is the most swappable piece in the whole system. Anything
   that can receive a message and run a local command in response works.

2. **A cheap LLM router.** The thing that actually talks to you day-to-day: turns
   "add a dark mode toggle to the settings page" into a queued work item, answers
   quick questions, nags you about a stale proposal. It should be cheap — it's
   running constantly and doing very little real reasoning. The reference setup
   uses Moonshot's Kimi K2 via API, with a local [Ollama](https://ollama.com)
   model as a self-hosted fallback. Both are documented as validated options in
   `setup.sh`; anything else is on you to wire up (it's a config value, not a
   hardcoded assumption).

3. **A file-based queue.** Markdown files with frontmatter, one per proposed task,
   living in `~/dev/queue/`. No database, no server — `git log` on that directory
   *is* the audit trail. See `lib/queue.sh` for the frontmatter conventions and
   `bin/devbrain-queue` for the CLI that manages it.

4. **A stronger coding agent.** Picks up *approved* queue items (never anything
   else) and does the actual work: reads the repo, writes code, runs your tests,
   opens a PR. The reference setup uses [Claude Code](https://claude.com/claude-code)
   for this, in two passes — one model to draft a plan (`devbrain plan`), a second
   to implement it and a third pass to adversarially review the diff before the PR
   goes out (`devbrain execute`, see `bin/devbrain`). This is also swappable: any
   agent you can invoke non-interactively, constrained to a branch, works.

5. **A wiki.** Not this repo — a *separate* git repo (or directory) at `~/dev/wiki/`
   that accumulates project status pages, decisions, and lessons learned, written
   by the coding agent at the end of each task and read by it at the start of the
   next one, plus read in full during the weekly interview. `docs/wiki-example/`
   in this repo shows the convention with a few generic example lessons — it's not
   itself the wiki, just a sample of the shape one should take.

## The propose-only workflow (the part that isn't optional)

This is the one piece of the design that isn't a suggestion:

1. **Plan first.** The agent describes what it intends to change and why. Nothing
   is touched yet.
2. **A feature branch, never `main`.** All work happens on a branch named
   `devbrain/<slug>-<timestamp>`.
3. **A PR, not a merge.** The agent opens a pull request with a plain-language
   summary (what changed, why, risks, how to verify) and a second agent's
   adversarial review at the top of the PR body. It never merges it.
4. **You merge, or you don't.** From the GitHub app, from the CLI, whenever you
   get to it. If something's wrong, you close the PR and tell the queue why.

Three paths can write the `aprobado:` (approved) key into a queue plan —
`bin/devbrain-interview` (weekly planning), `bin/devbrain-day` (the daily
shift ritual), and `bin/devbrain-queue dale <n>` (a reply to the morning
digest, e.g. from a chat bot). All three require a human to make the call
on that specific plan in the moment; none of them run unattended. The
actual gate against unattended self-approval lives in `bin/devbrain-night`:
its `next_plan()` refuses any plan that lacks both `status: approved` and
a non-empty `aprobado:` — so nothing reaches the nightly runner without
both markers set by a human.

## What's in this repo

```
bin/            the actual commands (devbrain, devbrain-queue, devbrain-night, ...)
lib/            shared shell/python helpers sourced by bin/*
claude/         Claude Code skills and status line used by the coding-agent side
openclaw/       persona/config templates for the OpenClaw messaging bridge, plus
                exec-approvals.json — the actual allowlist config that makes "the
                agent can only run devbrain" a real enforced boundary, not just
                a line in a prompt
tests/          bash test suite (tests/*.sh — run any of them directly)
docs/wiki-example/  a small, generic sample of the wiki convention (not a live wiki)
devbrain-projects.allow        the repo allowlist (starts empty — see setup.sh)
devbrain-projects.excluded     repos deliberately out of scope, with reasons
devbrain-base-branch.override  per-repo "PRs target develop, not main" overrides
devbrain-verify.commands       per-repo commands devbrain may run unattended
devbrain-migration-block.list  per-repo "never write migrations here" list
TELEGRAM-PLANTILLAS.md         example message templates for the Telegram bot
setup.sh                       interactive first-run wizard
```

## Getting started

**Never run anything like this before, or want a coding agent to walk you through it
step by step with explicit go/no-go checkpoints?** Use
[`docs/GUIDED-SETUP.md`](docs/GUIDED-SETUP.md) instead — a phased bring-up (machine
hygiene, then memory, then the propose-only loop, then autonomy) written for that.
The steps below assume you're comfortable enough to adapt them yourself.

1. Clone this repo to `~/dev/devbrain` (recommended — a handful of scripts
   default to this exact path for config files they read from a *different*
   process than the one invoking them, where auto-detecting "wherever you put
   it" isn't reliable; see `docs/CONCEPTS.md#if-you-clone-this-somewhere-else`
   if you'd rather use a different name or location).
2. Run `./setup.sh`. It asks a handful of questions (your GitHub username, which
   repos to manage, which LLM router to use, your Telegram bot token and chat id),
   checks your prerequisites, and writes `devbrain-projects.allow` plus a local,
   gitignored config file with your secrets.
3. Read the checklist `setup.sh` prints at the end — installing the messaging
   bridge itself, wiring up launchd/cron for `devbrain-night`/`devbrain-digest`/
   `devbrain-heartbeat`, and running `gh auth login` are manual steps by design;
   this repo doesn't script your OS's service manager for you.
4. Run `tests/*.sh` to sanity-check the pieces you'll actually rely on
   (`tests/test-lib.sh`, `tests/test-queue.sh`, `tests/test-devbrain-guardrails.sh`
   are a good place to start).

## What's intentionally NOT in this starter kit

A few things from the reference system were dropped rather than genericized,
because they were either too bespoke to be useful as a template or squarely
personal-data territory:

- **Scrapers.** The reference system ran a fleet of scheduled data-collection
  jobs for one specific business. `lib/schedule.sh`'s manifest-scheduling format
  is a reasonable pattern to copy if you build your own, but no scraper code
  ships here.
- **Sentry triage.** Bespoke to one org/project's Sentry setup. If you want
  something similar, `sentry-cli` (see the `sentry-cli` Claude Code skill, if
  you have it installed) plus a small wrapper script is the way to go.
- **Personal read-only digests** (email/calendar/tasks briefings). These touch
  real personal data and are exactly the kind of thing you should NOT copy
  from someone else's config — build your own, and keep it read-only, "read
  live, answer, forget," never persisted to disk or the wiki.
- **Notion sync.** Included (`bin/notion-sync*`), but it's OPTIONAL — a
  nice-to-have mirror of the queue/wiki into a Notion workspace, not something
  devbrain needs to function. Ignore it if you don't use Notion.

## A note on the "house rules" file

Several scripts reference `~/dev/CLAUDE.md` (or your coding agent's equivalent) as
a shared "house rules" file — things like "always work on a branch," "never
deploy to production," "explain diffs in plain language." That file isn't part of
this repo (it's specific to your own standards and tone), but every script that
reads it will work fine with an empty one; it just won't have anything useful to
say. Write your own.

## License

MIT — see [`LICENSE`](LICENSE). Fork it, adapt it, point it at your own repos.
No attribution required beyond what MIT already asks for.

## Contributing

Found a bug, a genericization gap (something that still assumes one specific
setup), or want to add a swappable piece (another messaging bridge, another LLM
router)? See [`CONTRIBUTING.md`](CONTRIBUTING.md). For the deeper "why does this
work this way" behind the five moving parts above, see
[`docs/CONCEPTS.md`](docs/CONCEPTS.md).
