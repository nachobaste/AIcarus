# Lesson: a permission that exists is not a permission that works

**Date:** example entry (invented for this starter kit)
**Context:** five of seven approved plans ended `blocked` in a single night, with the
scheduled preflight green and every command they needed present in
`devbrain-verify.commands`.

## What happened

Verification commands declared as `npm run test:run@frontend` were granted to the
session as the literal string `Bash(cd frontend && npm run test:run)`. A literal is an
exact match, and the session's shell **keeps its working directory between calls**. The
first `cd frontend && npm run build` worked and left the shell inside `frontend/`. The
second call, `cd frontend && npm run test:run`, failed with `no such file or directory:
frontend`. The session then retried the bare command, `npm run test:run`, which was not
granted, was told it "requires approval", and stopped. The plan was marked blocked.

Two more plans blocked on `npm install`. The session was right to want it: the
frontend's `node_modules` was stale, with five declared dependencies never installed, so
its tests could not run. Unattended installs are never granted, and nothing had checked.

The same trap had already blocked plans twice before. Each time the fix was a longer
instruction in the prompt ("run it as ONE call, exactly this string"), and each time the
shell set the same trap again, because the failure did not come from the model.

## The lesson

**Checking that a permission exists says nothing about whether it can be used.** The
preflight looked at configuration, not at use. Asking a model to be more careful about
a mechanical trap only moves the failure to the next session.

## The mechanical rules that came out of it

1. `bin/devbrain-verify-run <repo> <command>` does the `cd` itself, runs only the exact
   command declared with `@subdir`, and uses no shell, so a `;` or `&&` is just an
   argument that matches nothing. The session gets one grant for it, and it works from
   any directory, any number of times in a row.
2. `devbrain-verify-run --check <repo>` proves each declared command *can* execute
   (subdir exists, declared dependencies installed, script present) without running it.
   The preflight calls it, so "granted but unusable" is red before the night.
3. `bin/devbrain-preflight --plan <file>` runs the same checks on one plan, and
   `day_apply` runs it before writing `aprobado:`. A plan that cannot run is refused
   while you are at the keyboard to fix it, not at the hour the night is already lost.
   The gate fails closed: if the check is missing, nothing is approved.
4. The check that says a plan cannot run must itself be proven able to say so. Both
   scripts ship with planted cases (a missing dependency, an undeclared command, a
   smuggled separator) and a mutation that removes the check and must turn a test red.
