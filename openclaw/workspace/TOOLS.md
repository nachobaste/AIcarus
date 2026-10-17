# TOOLS.md — operational notes for this setup

Your cheat sheet. Fill in the blanks for your own machine and repos.

## Your one action tool: `exec` → the queue

- The `exec` tool is allowlisted: it can ONLY run `devbrain-queue` (add any other
  devbrain-family command you've enabled, e.g. a personal-assistant script — keep the list
  short and explicit). Everything else is DENIED, `devbrain plan` and `devbrain execute`
  included. The allowlist itself lives in `openclaw/exec-approvals.json` as absolute paths —
  it must point at wherever YOU cloned this repo, not a placeholder or someone else's path
  (see setup.sh's final checklist).
- Pass only the `command` parameter. No `host`, `security`, `elevated`, `&&`, `cd`,
  `npm`, etc.
- Code and idea flow: `devbrain-queue add <project|-> --fuente telegram "<verbatim text>"`
  → "Noted as #<n>; the plan reaches you to approve" → the owner decides with
  `approve`/`deny`/`change` (below). See AGENTS.md, "Request flow".

## Projects (devbrain's allowlist)

Keep this table in sync with `config/devbrain-projects.allow` in this repo.
Example format:

| Project | What it is |
|---|---|
| `<YOUR_REPO_NAME>` | one-line description of what it is and any special handling |
| `<YOUR_OTHER_REPO>` | **PRODUCTION.** PRs to `develop`, no migrations, extra review. Flag that it's prod when you route a task there. |

## Available commands

- `devbrain-queue add <project|-> --fuente telegram "<text>"` — notes a code request or an
  idea, with the owner's text as it is (links included). `-` if you don't know the project:
  the planner asks the owner (they answer with `change <n>: repo: <name>`).
  `devbrain-queue list` to see what's queued.
- `devbrain-queue approve <n>` — approves plan `<n>` of the queue (the `#N` the planner
  printed, e.g. 37). It refuses if the plan is not drafted yet: relay the error.
- `devbrain-queue show <n>` — prints plan `<n>` (read-only) to show it to the owner before
  approving.
- `devbrain-queue deny <n> <reason>` — discards plan `<n>`; the reason is required.
- `devbrain-queue change <n>: <note>` — sends `<n>` back to be planned again with the note
  added (the colon after the number is required). It is also how you answer a planner
  question about `<n>`.
- `devbrain-queue requeue <n>` — the way out of a `blocked` plan, once the owner says the
  missing permission is granted; the plan goes back to `requested` and the owner still has
  to approve it.
- `devbrain-queue dale <n>` / `devbrain-queue no <n> "<reason>"` — ONLY for research
  proposals: when the owner replies to the morning digest ("Proposals waiting on your
  decision", numbered 1, 2, 3...). If the number is a plan's `#N` from the planner it is a
  plan of the queue: use `approve`/`deny`, not `dale`/`no`. `<n>` is the number exactly as it appeared in THAT
  message — don't recompute it or assume it from an old conversation. `dale <n>` approves
  and creates the plan in the queue; `no <n> "<reason>"` discards it — **the reason is
  required**; if the owner says "no 2" with no reason, ask why before retrying (the command
  fails with a readable error if you send it without a reason — relay that and ask). If
  `<n>` doesn't exist or the repo isn't enabled, the command fails with a clear message:
  relay it as-is, don't reinterpret it.
- Any other devbrain-family command you've personally added and allowlisted —
  document it here the same way.

## Inputs you handle

- **Text** — normal.
- **Voice** — voice notes are transcribed before you see them; confirm what you
  understood.
- **Images/screenshots** — use them to understand the task and to write a better request
  text. You don't edit images or write code yourself.

## What you CANNOT do (and that's fine)

- Write/edit code yourself, or draft/run plans → the system does that (the planner and a
  coding agent) after the owner approves.
- Run commands outside the allowlist → denied automatically.
- Merge PRs, touch `main`, deploy to production → never. The owner merges from
  their phone or laptop.
- Read personal data (email, calendar) unless you've explicitly wired up and
  enabled that yourself, on-demand only, read-only, never scheduled.
