# Contributing to AIcarus

Thanks for considering it. This file is about contributing to *this repo* — the
starter kit itself. If you're looking for how to use it on your own projects,
that's the README, not this file.

## Before you write code

Open an issue or a draft PR describing the gap you found. Useful categories:

- **A genericization leak.** Something that still assumes one specific setup —
  a hardcoded path, a username, a company name, an assumption that only holds for
  the original author's machine. These are the highest-value contributions: a
  starter kit that quietly only works for its own creator isn't a starter kit.
  **Known open gap, largest one left:** the interactive/LLM-facing scripts —
  `bin/devbrain-interview`, `bin/devbrain-day`, `bin/devbrain-queue`,
  `bin/devbrain-digest`, `bin/devbrain-wiki-status-audit`,
  `bin/devbrain-repo-audit`, `bin/devbrain-research`, `lib/day.sh`,
  `lib/day_engine.py`, `lib/research_promote.py` — still carry the original
  author's Spanish-language, informal-`vos` system prompts and user-facing
  strings verbatim. They work (nothing here is broken), but they're the most
  visible remaining sign this was extracted from one specific, non-English
  setup rather than written as a template. A PR translating one script at a
  time to a neutral, second-person-`you` English prompt — re-running that
  script's own `tests/test-*.sh` afterward, since these are executable prompts
  and not just comments — is exactly the kind of contribution this section
  describes.
- **A swappable piece that isn't actually swappable.** The README claims the
  messaging bridge, the LLM router, and the coding agent are all replaceable. If
  you tried to swap one and hit a place that assumed OpenClaw, or Kimi, or Claude
  Code specifically, that's a bug in the abstraction, not a missing feature
  request.
- **A new safeguard, following the existing pattern.** Every guardrail in this
  repo (the propose-only workflow, `devbrain-verify.commands`, the migration
  block list, `devbrain-check-blocked-actions`, `classify.sh`'s tiers) exists
  because something went wrong once and got turned into a mechanical rule instead
  of a remembered judgment call. See `docs/wiki-example/lessons/` for the shape a
  writeup like that takes. If you're proposing a new one, a short "here's the
  failure mode this closes" is more valuable than the code itself.
- **A new swappable piece** (a different messaging bridge, a different LLM
  router, a different coding agent). These are welcome as long as they're
  genuinely optional — nothing in `bin/` or `lib/` should import a specific
  provider's SDK or hardcode its API shape. Route it through a config value, the
  same way `DEVBRAIN_LLM_ROUTER` and `devbrain-base-branch.override` do.

## Ground rules

- **No real paths, usernames, company names, or credentials.** This sounds
  obvious, but it's the exact class of bug that survived the original
  genericization pass twice (see `git log --oneline` — "Fix leaked real username
  in CLASSIFY_MEMORY default"). Before opening a PR, `grep -rIn` your diff for
  anything that looks like it came from your own `~/dev/`.
- **Bash portability: target bash 3.2, not just whatever you're running.**
  macOS ships bash 3.2 as `/bin/bash` (the shebang execs it directly, ignoring
  `$PATH`, so a newer bash on your `$PATH` won't save a contributor who doesn't
  have one). That means: no `declare -A` (associative arrays), no `wait -n`, no
  `${var,,}` lowercasing, no `mapfile`. See the comments at the top of
  `lib/schedule.sh` and `lib/queue.sh` for the specific workarounds already in
  place (a polling loop instead of a backgrounded watchdog, because a subshell
  can't `wait` on a PID it didn't fork).
- **Every script that reads or writes outside its own repo names the safeguard
  it's honoring.** `devbrain-verify.commands`, `devbrain-migration-block.list`,
  `devbrain-base-branch.override`, `devbrain-projects.allow` /
  `.excluded` all ship empty by design — a new capability should extend one of
  these opt-in files, not bypass them with its own separate check.
- **Nothing here fetches from the network unattended, except the messaging
  bridge and the coding agent's own tool use.** `devbrain-verify.commands`
  explicitly forbids `npm install`/`pip install`-shaped commands
  (`tests/test-devbrain-guardrails.sh` enforces this) — a nightly run should
  never need new dependencies to pass its own verification.
- **Tone: read `docs/wiki-example/lessons/` before writing new docs.** That's the
  register this repo writes in — concrete failure, what actually happened, the
  mechanical rule that came out of it. Not marketing copy, not hedge-everything
  disclaimers.

## Running the tests

```bash
for f in tests/*.sh; do bash "$f" || echo "FAILED: $f"; done
```

Each `tests/test-*.sh` targets one `bin/*` or `lib/*.sh` file 1:1 — if you touch
`lib/queue.sh`, run (and probably extend) `tests/test-queue.sh`. There's no test
runner framework here on purpose: each file is a standalone bash script that
exits non-zero on failure, so `bash tests/test-whatever.sh` is always the whole
story of how to run it.

If you're adding a check, assertion, or verification script of any kind: prove it
can fail before you trust what it reports. Plant a case it must catch, confirm it
catches it, then remove the case. `claude/skills/prove-the-check-can-fail/` is
this rule in checklist form — several of the guardrails in this repo exist
*because* an earlier check turned out to pass silently on broken input.

## Opening the PR

- Small, focused diffs. One genericization fix, or one new safeguard, per PR —
  not a sweep of unrelated cleanups.
- Say what you tested and how, in the PR description. "Ran `tests/test-queue.sh`,
  added a case for the empty-frontmatter path" beats "should work."
- If your change touches a documented convention (the queue frontmatter schema,
  the wiki convention, `devbrain-verify.commands`' pattern syntax), update
  `docs/CONCEPTS.md` and the README section that references it in the same PR —
  not as a follow-up.

## What this repo will not accept

Per the README's own "What's intentionally NOT in this starter kit" section:
scrapers, anything Sentry-specific, personal-data digests (email/calendar/task
briefings), or anything else that's inherently one operator's bespoke setup
rather than generic machinery. If you built something like that for yourself,
the right contribution is a short pattern writeup (the way `lib/schedule.sh`'s
manifest format is described as "copy this if you build your own"), not the code
itself.
