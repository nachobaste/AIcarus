# Telegram message templates for devbrain

These are examples to save as **Saved Messages** in Telegram (or wherever you keep
snippets) so you don't have to retype them. Replace anything in `<ANGLE_BRACKETS>`.
Send them to your own bot — set that up first with @BotFather, see `setup.sh`.

If your messaging bridge routes free-form chat through an LLM router (the default
setup — see README.md), you may not need most of these at all: you can usually
just say "add a CSV export button to the dashboard" in plain language and let the
router turn it into the right `devbrain-queue` call. These templates are for the direct,
no-router path — useful while you're setting things up, debugging, or if you'd
rather skip the router step entirely for a given message.

## 1. Queue a request
```
/bash devbrain-queue add <PROJECT> --fuente telegram "<what you want to happen>"
```
Use `-` instead of `<PROJECT>` if you are not sure which repo it is for; the planner
asks you. Example:
```
/bash devbrain-queue add my-website --fuente telegram "make the nav menu look right on mobile"
```
`devbrain-planner` reads the code in a temporary worktree and sends you a message
when the plan is ready (or one question if it cannot plan it).

## 2. Decide on the plan
```
/bash devbrain-queue show <N>
/bash devbrain-queue approve <N>
/bash devbrain-queue change <N>: <what to change, or your answer to its question>
/bash devbrain-queue deny <N> <reason>
```
`<N>` is the `#N` in the planner's message. `approve` runs the preflight and
refuses a plan that cannot run; the night runner picks up what you approved.

## 3. Retry a blocked plan
After you granted the permission the night runner said was missing:
```
/bash devbrain-queue requeue <N>
/bash devbrain-queue approve <N>
```

## 4. Look at the queue
```
/bash devbrain-queue list
```

## How to approve a run
If your bridge requires an explicit approval step for shell commands, after each
`/bash` it will reply something like **"Approval required id XXXX"**. To authorize:
```
/approve XXXX allow-once
```
(replace XXXX with the id it shows you)

## Full task flow
1. `/bash devbrain-queue add <project> --fuente telegram "<task>"` → approve if prompted.
2. The planner's message arrives: read the plan (`show <N>` for the whole thing).
3. If it looks right: `/bash devbrain-queue approve <N>`. Otherwise `change <N>: ...` or
   `deny <N> <reason>`.
4. The night runner opens a PR → review it and **Merge** from the GitHub app yourself.

## Valid projects
Whatever is listed in `config/devbrain-projects.allow`. Any repo you've
marked as production-sensitive (see `devbrain-base-branch.override` and
`devbrain-migration-block.list`) still goes through devbrain like any other, just
with its extra safeguards (PRs to a staging branch, migrations blocked, etc.) — say
so explicitly when you route a task there, the same way you'd flag it to a human
collaborator.

## Rules the system enforces on its own
- Only runs `devbrain-queue`. Any other command, `devbrain plan` and `devbrain execute`
  included: blocked.
- Never touches production directly, never merges, never deploys. It only opens
  PRs for you to review.

## Talking to the LLM router directly (natural language, no template needed)
Once the router is set up (see `openclaw/workspace/`), most day-to-day use looks
like plain conversation, not slash commands:

- "Add a request for `<project>`: <idea>" → queues it; the planner drafts the plan
  and you approve it.
- "approve 37" / "change 37: also do X" / "deny 37, <reason>" → decides on plan
  #37 (the number the planner's message showed you).
- "dale 2" / "no 2, <reason>" → approves or discards proposal #2 from the most
  recent digest message (the number must match what THAT message showed you).
- "What's the status of `<project>`?" → the router reads the wiki/status page and
  answers directly, no code session needed.
