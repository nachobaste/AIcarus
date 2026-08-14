# Telegram message templates for devbrain

These are examples to save as **Saved Messages** in Telegram (or wherever you keep
snippets) so you don't have to retype them. Replace anything in `<ANGLE_BRACKETS>`.
Send them to your own bot — set that up first with @BotFather, see `setup.sh`.

If your messaging bridge routes free-form chat through an LLM router (the default
setup — see README.md), you may not need most of these at all: you can usually
just say "add a CSV export button to the dashboard" in plain language and let the
router turn it into the right `devbrain` call. These templates are for the direct,
no-router path — useful while you're setting things up, debugging, or if you'd
rather skip the router step entirely for a given message.

## 1. List available projects
```
/bash devbrain projects
```

## 2. Ask for a PLAN (changes nothing, only proposes)
```
/bash devbrain plan <PROJECT> "<what you want to happen>"
```
Example:
```
/bash devbrain plan my-website "make the nav menu look right on mobile"
```

## 3. EXECUTE the approved plan (creates the branch and the PR)
```
/bash devbrain execute <PROJECT>
```
Example:
```
/bash devbrain execute my-website
```

## How to approve a run
If your bridge requires an explicit approval step for shell commands, after each
`/bash` it will reply something like **"Approval required id XXXX"**. To authorize:
```
/approve XXXX allow-once
```
(replace XXXX with the id it shows you)

## Full task flow
1. `/bash devbrain plan <project> "<task>"` → approve if prompted.
2. Read the plan that comes back.
3. If it looks right: `/bash devbrain execute <project>` → approve if prompted.
4. The PR link arrives → review it and **Merge** from the GitHub app yourself.

## Valid projects
Whatever is listed in `devbrain-projects.allow` at the root of this repo — run
`/bash devbrain projects` to see what's actually cloned locally. Any repo you've
marked as production-sensitive (see `devbrain-base-branch.override` and
`devbrain-migration-block.list`) still goes through devbrain like any other, just
with its extra safeguards (PRs to a staging branch, migrations blocked, etc.) — say
so explicitly when you route a task there, the same way you'd flag it to a human
collaborator.

## Rules the system enforces on its own
- Only runs `devbrain`. Any other command: blocked.
- Never touches production directly, never merges, never deploys. It only opens
  PRs for you to review.

## Talking to the LLM router directly (natural language, no template needed)
Once the router is set up (see `openclaw/workspace/`), most day-to-day use looks
like plain conversation, not slash commands:

- "Add a proposal to the queue for `<project>`: <idea>" → queues it without
  spending a coding-agent session.
- "dale 2" / "no 2, <reason>" → approves or discards proposal #2 from the most
  recent digest message (the number must match what THAT message showed you).
- "What's the status of `<project>`?" → the router reads the wiki/status page and
  answers directly, no code session needed.
