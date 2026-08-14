# TOOLS.md — operational notes for this setup

Your cheat sheet. Fill in the blanks for your own machine and repos.

## Your one action tool: `exec` → `devbrain`

- The `exec` tool is allowlisted: it can ONLY run `devbrain` and `devbrain-queue`
  (add any other devbrain-family command you've enabled, e.g. a personal-assistant
  script — keep the list short and explicit). Everything else is DENIED.
- Pass only the `command` parameter. No `host`, `security`, `elevated`, `&&`, `cd`,
  `npm`, etc.
- Code flow: `devbrain plan <project> "<task>"` → show the full plan + "Run it?
  say go" → if yes: `devbrain execute <project>` → hand back the PR link.
- `devbrain projects` lists the projects currently cloned locally.
- Idea flow (not code yet): `devbrain-queue add <project> "<idea>"` to note it
  down, then offer a `devbrain plan` afterward — see AGENTS.md, "Ideas to
  evaluate/research".

## Projects (devbrain's allowlist)

Keep this table in sync with `devbrain-projects.allow` at the root of this repo.
Example format:

| Project | What it is |
|---|---|
| `<YOUR_REPO_NAME>` | one-line description of what it is and any special handling |
| `<YOUR_OTHER_REPO>` | **PRODUCTION.** PRs to `develop`, no migrations, extra review. Flag that it's prod when you route a task there. |

## Available commands

- `devbrain plan|execute|projects` — the code loop (above).
- `devbrain-queue add <project> "<idea>"` — note an idea/task in the queue without
  spending a model call or touching code. `devbrain-queue list` to see what's queued.
- `devbrain-queue dale <n>` / `devbrain-queue no <n> "<reason>"` — for when the
  owner replies to the morning digest ("Proposals waiting on your decision",
  numbered). `<n>` is the number exactly as it appeared in THAT message — don't
  recompute it or assume it from an old conversation. `dale <n>` approves and
  creates the plan in the queue; `no <n> "<reason>"` discards it — **the reason is
  required**; if the owner says "no 2" with no reason, ask why before retrying
  (the command fails with a readable error if you send it without a reason — relay
  that and ask). If `<n>` doesn't exist or the repo isn't enabled, the command
  fails with a clear message: relay it as-is, don't reinterpret it.
- Any other devbrain-family command you've personally added and allowlisted —
  document it here the same way.

## Inputs you handle

- **Text** — normal.
- **Voice** — voice notes are transcribed before you see them; confirm what you
  understood.
- **Images/screenshots** — use them to understand the task and write a better
  `devbrain plan`. You don't edit images or write code yourself.

## What you CANNOT do (and that's fine)

- Write/edit code yourself → `devbrain` does that (a coding agent runs underneath it).
- Run commands outside the allowlist → denied automatically.
- Merge PRs, touch `main`, deploy to production → never. The owner merges from
  their phone or laptop.
- Read personal data (email, calendar) unless you've explicitly wired up and
  enabled that yourself, on-demand only, read-only, never scheduled.
