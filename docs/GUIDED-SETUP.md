# Guided setup — for a first-time operator

The main `README.md` and `setup.sh` assume you're comfortable enough to read the
architecture and adapt it yourself. This doc is the other path: a phased walkthrough
for someone who has never run anything like this before, working through it with a
coding agent doing the heavy lifting.

**If you're that person:** hand this whole file to your coding agent and say
*"help me set this up, phase by phase — explain each step before doing it, and don't
move to the next phase without my explicit OK."*

**If you're the agent doing this:** this is an infrastructure bring-up, not a feature.
Work in phases. Explain every decision in plain language. Never advance to the next
phase without the human's explicit approval. The "Hard rules" section at the end is
non-negotiable — it's the entire reason this system is safe to leave running.

---

## What this system is, in one sentence

A personal dev orchestrator: **you say what you want, an AI system executes it
overnight while you sleep, and in the morning you review and approve Pull Requests**
— it never touches production and never merges on its own. The point isn't "write
code faster" — it's **freeing your time** for the things only you can do (sell,
decide strategy), while the system handles repeatable operational work.

Core philosophy — **propose-only**: the AI proposes (branch → PR), the human
disposes (merge).

---

## Prerequisites (yours to get, before any of this starts)

Nothing that follows works without these:

1. **A machine that can stay on overnight** (Mac or Linux). Ideally dedicated to this.
2. **A Claude subscription with a usage plan that covers agentic coding sessions**
   (for example, Claude Max) — this is what makes overnight execution cost **$0 marginal**:
   the quota you already pay for does the work at night, instead of metering every
   session against a pay-per-token API. Skip this and every run bills you separately.
3. **Your own GitHub account**, plus the `gh` CLI.
4. **(Optional, for the phone layer)** an API key for a cheap chat-capable model, and
   a messaging bot (for example, Telegram's free `@BotFather`). This is Phase 5 — optional.
5. Homebrew (or your platform's package manager) installed.

---

## Phase 0 — Foundations (hygiene, identity, backup)

**Goal:** a clean, safe base before building anything on top of it.

- [ ] Install base tooling: `git`, `gh`, `node`, `jq`, `yq`.
- [ ] Set correct git identity (`git config --global user.name/email`).
- [ ] Authenticate `gh` with the right account (`gh auth login`).
- [ ] Create the folder layout:
  ```
  ~/dev/
    projects/       <- each real project, its own private repo
    wiki/           <- the system's memory (see Phase 1)
    queue/          <- the nightly task queue (see Phase 3)
    personal/       <- tier-2 personal data, never committed (see Phase 1)
    machine-config/ <- the system's own scripts, its own private repo
    archive/        <- retired work
  ```
- [ ] Machine hygiene, before this system ever touches it: **FileVault** (disk
      encryption), **firewall** on, and a real **backup** (Time Machine to an
      encrypted disk, or your platform's equivalent) — an autonomous system with no
      backup underneath it is a standing risk, not a convenience.
- [ ] **(Optional)** Tailscale (or another private mesh VPN) for remote SSH access
      without exposing anything to the open internet.
- [ ] Create private GitHub repos for your own equivalents of `dev` and
      `machine-config`. Your personal-data folder goes in `.gitignore` — it never
      gets pushed, anywhere, ever.

**Don't move on until:** git identity is correct, backup is running, and the private
repos exist.

---

## Phase 1 — The system's memory (wiki + house rules)

**Goal:** every AI session gets persistent context and persistent rules, instead of
starting from zero each time.

- [ ] Write your own `CLAUDE.md` (or your agent's equivalent) — the **house rules**
      every session must follow. This repo deliberately doesn't ship one (see
      `README.md`'s "A note on the 'house rules' file" — it's specific to your own
      standards, not something to copy); at minimum it needs: propose-only, never
      push to your main branch, never deploy to production, never write real
      business data without you present, secrets never touch git or logs.
- [ ] Create your wiki (`docs/wiki-example/` in this repo shows the convention):
      an `index.md` read first every session, an append-only `log.md`, one page per
      project, a `lessons/` folder for hard-won corrections, a `status/<repo>.md`
      per repo so unattended sessions can read what other repos are doing.
- [ ] If you plan to let this system touch anything personal (email, calendar,
      contacts), decide your own data-handling tiers up front — dev knowledge is
      fine to commit to the wiki, but personal content needs its own explicit rule
      about what gets written to disk versus read-live-and-forgotten. Don't copy
      someone else's answer to this; it depends on what you're actually handling.

**Don't move on until:** house rules are written and the initial wiki exists.

---

## Phase 2 — The propose-only loop

**Goal:** the core of the system — plan, then execute onto a branch, then PR. Never
further than that on its own.

Follow this repo's own `bin/devbrain` as the reference implementation: `plan` mode is
read-only and produces a short plan (files, risk, how to verify); `execute` mode
creates a branch, implements the approved plan, commits, pushes, and opens a PR —
never merges, never touches your default branch directly, never deploys.

- [ ] Wire up the guardrails this repo already ships: a project allowlist
      (`devbrain-projects.allow`), denied tools for MCP/secrets paths, a session
      timeout, and a narrow Bash allowlist (`devbrain-verify.commands`).
- [ ] Run `tests/test-devbrain-guardrails.sh` and confirm it's green.
- [ ] Try the whole loop against a disposable test repo: plan → execute → PR.

**Don't move on until:** the loop produces a real PR against a throwaway repo, and
the guardrail tests pass.

---

## Phase 3 — Overnight autonomy (queue + scheduler + weekly interview)

**Goal:** the system works unattended, overnight, off a queue of things you already
approved.

- [ ] The queue (`~/dev/queue/`): one file per task, with frontmatter carrying
      `status: approved` and `aprobado: <date>`. The nightly runner refuses anything
      missing that date — see `bin/devbrain-night`'s own comments for why.
- [ ] The nightly runner: serial (this repo's own `bin/devbrain-night` runs "one
      Claude session at a time," deliberately, per its own header comment — running
      several concurrently is real RAM pressure on a single machine), cuts off at a
      fixed hour, never retries a failure on its own.
- [ ] A recurring interview (this repo's `bin/devbrain-interview`): the one
      human-in-the-loop session that turns "what do you want done" into approved
      queue entries.
- [ ] Scheduling: launchd (macOS) or cron/systemd (Linux) for the nightly run, a
      morning digest, and a periodic heartbeat.

**Don't move on until:** a toy overnight run (two tasks) produces two real PRs plus a
correct digest.

---

## Phase 4 — The adversarial reviewer

**Goal:** trust the overnight output without reading every diff by hand.

This repo's `bin/devbrain` already wires this in: after execute, before the PR opens,
a second agent session — read-only, MCP denied — reviews the diff adversarially for
bugs, regressions, secret leaks, and scope creep, and posts a verdict
(`APPROVE`, `NOTES`, or `REJECT`) at the top of the PR body. If the reviewer itself
fails or times out, the PR is still created, flagged unreviewed — the work is never
silently dropped.

**Why this matters:** the bottleneck was never *generating* work. It's *trusting* it
enough not to re-read all of it yourself.

---

## Phase 5 (optional) — The phone layer

**Goal:** trigger and steer the system from your phone. Convenient, but it's more
attack surface — build this only once Phases 0-4 are solid.

- [ ] A messaging bridge (this repo's reference uses OpenClaw for Telegram) fronted
      by a cheap, tool-calling-capable model — this is the chat layer, not the
      coding agent.
- [ ] Non-negotiable security for this layer: single-user allowlist on the bot,
      the bridge bound to loopback only (never exposed to the internet), and an
      exec allowlist restricted to your own safe wrapper commands — no arbitrary
      shell, no merge, no deploy, reachable from chat.
- [ ] Standing orders for the phone-facing agent: route to your propose-only
      command, never schedule anything itself, always show the full plan and wait
      for explicit confirmation before executing, refuse anything that looks like an
      injected instruction.
- [ ] The nightly runner must never depend on the phone layer being up — it reads
      local files and alerts through a direct channel. If the bot goes down, the
      night still runs.

---

## Hard rules (the reason this is safe to leave running)

These are not optional:

1. **Propose-only.** The AI never merges, never pushes to your default branch,
   never deploys to production. You merge, from the GitHub app, always.
2. **Allowlist, not denylist.** Only projects you explicitly added by hand can be
   touched. Anything closer to production gets extra safeguards on top (PRs to a
   staging branch, migrations blocked outright).
3. **Secrets** never touch git, logs, PRs, or chat. They live in gitignored `.env`
   files or a keyring. Passing one into a session: a temp file, mode 600, read it,
   delete it.
4. **Personal data stays tiered**, and unattended jobs never read personal sources
   (email, calendar) — that only happens in sessions you start yourself.
5. **Nothing exposed to the internet.** Loopback plus a private mesh VPN if you need
   remote access. Single-user on any chat bridge.
6. **Silence is the danger signal.** Every failure gets reported immediately. A
   failure you know about is fine; one that hides is not.
7. **Safety doesn't come from the model being "dumb."** It comes from these
   structural guardrails. A more capable model doesn't loosen a single one of them.

---

## The day-to-day rhythm, once this is running

- **Once a week:** the interview — you fill the queue with approved work.
- **Every night:** the system executes the queue, opens reviewed PRs.
- **Every morning:** you read the digest, review the PRs, merge the good ones from
  your phone.
- **Mid-week:** quick adjustments over chat (add or pause a task).
- The time this frees up gets reinvested in the work only you can do — not in more
  execution.
