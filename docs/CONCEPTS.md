# Concepts — the ideas behind the five moving parts

The README describes the five moving parts and the propose-only workflow. This
document goes one level deeper: the recurring patterns that show up across
`bin/` and `lib/`, and the reasoning behind them — useful before your first PR,
or if you're trying to understand why something is built the way it is instead
of some simpler-looking way.

## Tools this repo actually uses

Nothing here is a framework. It's shell scripts and standalone Python (stdlib
only — no `requirements.txt`, no pip dependencies anywhere in `bin/` or `lib/`;
every script that talks to an HTTP API does it with `urllib.request` or shells
out to `gh`/`git`) gluing together a small number of external things:

| Tool | Role | Swappable? |
|---|---|---|
| [Claude Code](https://claude.com/claude-code) | The coding agent — the thing that reads a repo, writes code, runs tests, opens a PR (`bin/devbrain`) | Yes — any non-interactively-invokable coding agent works, as long as it can be constrained to a branch |
| [OpenClaw](https://github.com/openclaw/openclaw) | The reference Telegram bridge (`openclaw/`) | Yes — the most swappable piece; anything that turns a chat message into a shell command and back works |
| Moonshot Kimi K2 (API) / [Ollama](https://ollama.com) (local) | The cheap LLM router that talks to you day-to-day | Yes — a config value (`DEVBRAIN_LLM_ROUTER` in `devbrain.local.env`), not hardcoded |
| `gh` (GitHub CLI) | Opens PRs, reads PR/issue state for the audit scripts | Not really — several scripts shell out to it directly; a different forge would mean rewriting those |
| `git` | Branching, the propose-only workflow's actual mechanism | No |
| Notion API (`bin/notion-*`) | Optional mirror of the queue/wiki into a Notion workspace | Entirely optional — ignore it if you don't use Notion |
| bash 3.2 + python3 | The scripting substrate | Not swappable, but see "Portability" below for what that constrains |

## The propose-only workflow, mechanically

`devbrain plan <project> "<task>"` runs the coding agent read-only-ish (it can
read the repo and think, but the plan it hands back is what gets shown to you —
nothing is written yet). `devbrain execute <project>` is the one that writes: it
creates a branch named `devbrain/<slug>-<timestamp>`, does the work, runs a
**second** agent pass that adversarially reviews the diff (looks for exactly the
kind of "technically works but is wrong" issues a self-review misses), and opens
a PR with both the plain-language summary and that adversarial review in the
body. Two independent facts make this enforceable rather than aspirational:

1. It is never given permission to push to the base branch or merge. Not "asked
   not to" — the branch/PR/merge sequence is the only path that exists.
2. `bin/devbrain-night`'s "clean working tree" precondition check means a stray
   direct commit to the base branch (bypassing all of this) surfaces as a
   confusing failure on the *next* task, not silently — see
   [`docs/wiki-example/lessons/propose-only-is-not-negotiable.md`](wiki-example/lessons/propose-only-is-not-negotiable.md)
   for the incident that is based on.

## The file-based queue

Every proposed task is one file: `~/dev/queue/<NN>-<repo>--<slug>.plan.md`. `NN`
is a zero-padded priority number (see `queue_next_nn` in `lib/queue.sh` — new
items get `max existing + 10`, leaving room to insert between two without
renumbering everything). Frontmatter, YAML between two `---` lines:

```markdown
---
repo: my-website
status: approved
prioridad: 130
creado: 2026-03-01
aprobado: 2026-03-04
epic: 2
---

## Qué hacer / What to do
...

## Cómo verificar / How to verify
...
```

- `status` moves through `requested` (not yet planned) →
  `approved` → (after a run) either gone/merged, `failed`, or `paused`/`blocked`
  with a reason.
- **`aprobado` is the one field with a hard rule attached: only
  `bin/devbrain-interview` — a weekly, interactive, human-present session — is
  allowed to write it.** `bin/devbrain-night` refuses to touch any plan that
  doesn't have both `status: approved` and a non-empty `aprobado:` date. This is
  the actual mechanism behind "nothing runs unattended unless a human explicitly
  approved it" — not a convention, a field the nightly runner checks.
- No database: `git log -- ~/dev/queue/` on that directory is a complete,
  ordered audit trail of every task ever proposed, approved, or rejected, and
  why (see `bin/devbrain-queue`'s `no <n> "<reason>"` path — rejections require
  a reason, not just a discard).

## The "deliberate act" config-file convention

Six plain-text files at the repo root — `devbrain-projects.allow`,
`devbrain-projects.excluded`, `devbrain-base-branch.override`,
`devbrain-verify.commands`, `devbrain-migration-block.list`, and (optionally)
`devbrain-classify.tiers` — all ship empty except comments, and all follow the
same rule: **adding a line is a deliberate act you take, not a default the
system assumes for you.** The reasoning is spelled out inline in each file
(read them, they're short), but the pattern itself is worth naming: every one of
these is an *opt-in* safeguard, and a repo missing from the relevant file
doesn't silently get the permissive behavior — `devbrain-repo-audit` flags
anything unclassified so you make the decision instead of the absence of a line
making it for you. If you're adding a new capability that needs its own
allowlist, extend one of these (or add a new file following the identical
"empty by default, one line per deliberate decision, format documented in the
file's own header comment" shape) rather than inventing a different mechanism.

## The four-tier data classification (`lib/classify.sh`)

`personal | business-confidential | interno-devbrain | publico` (public). Every
path gets classified by `classify_tier()`, and **unknown paths fail CLOSED to
`business-confidential`** — a brand-new directory nobody has classified yet
must not leak by default just because nobody got around to labeling it.
`assert_egress_ok <tier> <destination>` is the single gate every script that
sends content somewhere (GitHub, Notion, Telegram) is expected to call before
sending it; `personal` is refused for every destination on purpose (it's not
even listed as an allowed case — bash's `case` falls through to the refusal
after `esac`, so there's no branch to accidentally return 0 from).

## The wiki convention (`docs/wiki-example/`)

Not code — a separate git repo/directory (`~/dev/wiki/` by convention) with
three kinds of page: **status** (what's true about a project right now),
**decisions** (why something was chosen, so it doesn't get silently
re-litigated), and **lessons** (a specific incident, what happened, and the
mechanical rule that came out of it — not "be more careful," an actual rule a
script or a review step can enforce). The coding agent reads it at the start of
a task and writes to it at the end. `docs/wiki-example/` in this repo isn't a
live wiki — it's three invented-but-realistic example lessons showing the
convention's shape.

## Why so many separate audit scripts instead of one linter

`devbrain-drift`, `devbrain-repo-audit`, `devbrain-wiki-status-audit`, and
`devbrain-stacked-pr-check` look like they could be "one health-check script,"
but each one exists because it catches a **structurally different** failure
mode that the others provably don't (each script's own docstring names the
specific incident that motivated it):

- **`devbrain-drift`** — do the separate knowledge stores (wiki, Claude memory,
  the messaging bridge's persona snapshot) still agree with each other?
- **`devbrain-repo-audit`** — does a repo that exists on GitHub but was never
  cloned locally, or was cloned but never classified, go unnoticed?
- **`devbrain-wiki-status-audit`** — does a specific sentence in the wiki
  ("PR #41 is not yet merged") still match live GitHub state?
- **`devbrain-stacked-pr-check`** — did a PR GitHub reports as `MERGED` actually
  reach the base branch, or did it get stacked on another PR whose base moved
  out from under it?

None of these subsume another — a PR can be correctly merged (nothing for
stacked-pr-check to catch) while the wiki still says it's pending (exactly what
wiki-status-audit catches), and vice versa. If you're adding a new check, ask
which specific, narrow question it answers that an existing one provably
doesn't — and see `claude/skills/prove-the-check-can-fail/` before trusting
what it reports: plant a case it must catch, confirm it does, before believing
a clean run means anything.

## The night/day split (`devbrain-research`, `devbrain-day`)

A nightly run with an empty approved queue used to report "0 done, 0 failed" for
eight nights in a row — not broken, just idle, because nothing generates
candidate work between weekly interviews. `devbrain-research` is the fix: a
read-only research shift (no `Write`, no `Edit`, no MCP tools available to that
session — it *cannot* touch code even if it wanted to) that spends a rotating
attention budget (internal gaps / cross-project links / external exploration)
investigating and writing up findings, which `devbrain-day` then turns into
queue proposals for you to decide on the next day-shift — never approved for
unattended execution by this path; only `devbrain-interview` can do that.

## If you clone this somewhere else

Most of this repo genuinely doesn't care where you put it — `setup.sh` and
`bin/devbrain-night` compute their own root from `$0`'s location, and
`~/dev/queue`, `~/dev/wiki`, `~/dev/projects`, and `~/dev/scratch` are their own
independent, generic conventions unrelated to where *this* repo lives.

A small number of config-file defaults are the exception: they point at files
that live **inside this repo's own checkout**, read by a script running from a
*different* working directory, where deriving "wherever this repo is" from
`${BASH_SOURCE[0]}` is unreliable (it resolves emptily under zsh when a file is
sourced rather than executed — see the comment on `DAY_ENGINE` in `lib/day.sh`).
Rather than that fragility, these default to the recommended clone path,
`~/dev/devbrain`, and are overridable by environment variable if you use a
different one:

| Script | Env var(s) | Defaults to |
|---|---|---|
| `lib/day.sh` | `DAY_ENGINE` | `~/dev/devbrain/lib/day_engine.py` |
| `lib/classify.sh` | `CLASSIFY_TIERS_FILE` | `~/dev/devbrain/devbrain-classify.tiers` |
| `lib/classify.sh` | `NOTION_REDACT_BIN` | `~/dev/devbrain/bin/notion-redact.py` |
| `bin/devbrain-repo-audit` | `REPO_AUDIT_ALLOWFILE`, `REPO_AUDIT_EXCLUDEFILE` | `~/dev/devbrain/devbrain-projects.{allow,excluded}` |
| `bin/devbrain-wiki-status-audit` | `WIKI_STATUS_AUDIT_ALLOWFILE`, `WIKI_STATUS_AUDIT_SCRAPERS_TSV` | `~/dev/devbrain/devbrain-projects.allow`, `~/dev/devbrain/scrapers.tsv` |
| `bin/devbrain-stacked-pr-check` | `STACKED_PR_ALLOWFILE`, `STACKED_PR_BASE_OVERRIDE` | `~/dev/devbrain/devbrain-projects.allow`, `~/dev/devbrain/devbrain-base-branch.override` |
| `bin/devbrain-drift` | `DRIFT_SNAPSHOT`, `DRIFT_SKILLS` | `~/dev/devbrain/openclaw/workspace`, `~/dev/devbrain/claude/skills` |
| `openclaw/exec-approvals.json` | (not env-driven — edit the file) | placeholder paths, must be edited to your actual clone path regardless of what you name it |

If you clone under a different name or path, set the relevant variables (in
`devbrain.local.env`, sourced before these scripts run) rather than editing the
defaults in place — that keeps your fork diffable against upstream.

## Portability: bash 3.2

macOS ships bash 3.2 as `/bin/bash`, and a script's `#!/bin/bash` shebang execs
that directly regardless of what's on `$PATH` — a contributor with a newer bash
installed via Homebrew won't be protected from this if they write a script that
only works on bash 4+. Concretely, this repo avoids: `declare -A` (associative
arrays — see the case-statement-based tier tally as the alternative pattern),
`wait -n`, `${var,,}` case-folding, and `mapfile`. `lib/queue.sh`'s
`with_timeout` and `lib/schedule.sh`'s manifest parsing both carry comments
explaining the specific bash-3.2-safe workaround in place — read those before
reaching for a bash 4+ feature that looks like it'd simplify something.
