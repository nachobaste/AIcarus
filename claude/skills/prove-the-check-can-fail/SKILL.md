---
name: prove-the-check-can-fail
description: Use when writing or trusting any check, test, assertion, grep, or verification script - before believing what it reports, plant a case it MUST catch and confirm it catches it; a check that cannot fail is not a check
---

# Prove The Check Can Fail

## Overview

**Core principle:** A passing check proves nothing until you have seen that check fail.

This is not the same as running your verification. You can run a check, read its
output, and report it honestly — and still be completely blind, because the check
never had the ability to report a problem in the first place.

`verification-before-completion` covers *"run the command before you claim."* This
covers the step before it: *"prove the command can say no."*

## The Iron Law

```
BEFORE trusting what a check reports, make it report the OTHER answer.
```

If you have only ever seen the check pass, you have measured nothing.

## The Gate Function

```
BEFORE believing any check, assertion, grep or test:

1. PLANT: introduce a case the check MUST catch
2. RUN: the check, unchanged
3. CONFIRM: it catches the planted case
4. REMOVE: the planted case
5. ONLY THEN: believe what it reports about the real case

Skipped step 1-3 = you have an opinion, not a measurement
```

## Two Rules That Actually Worked

Drawn from a session where a large share of reported "defects fixed" turned out to
be verifications that verified nothing — checks that passed while the code was
broken, or failed while it was fine. Being more careful did not lower the rate.
These two mechanical rules did.

### 1. Plant a canary and require the control to find it

```bash
# WRONG — only ever exercises the case that should pass
grep -rl "$TOKEN" /tmp && echo LEAK || echo "no leak"

# RIGHT — plant something that IS there, and require the scan to see it
printf '%s\n' "$CANARY" > "$TMP/probe"
hits="$(grep -rl "$CANARY" /tmp "$TMPDIR" "$DIR" 2>/dev/null)"
[ -n "$hits" ] || { echo "the scan is BLIND"; exit 1; }
```

Without that control, "no leak" is an assertion, not a measurement.

### 2. The control must exercise the blind spot, not the happy path

A control that only tests the easy case cannot detect its own blind spot. When
`grep -I` was silently skipping binary files, a plain-text canary passed anyway.
The control needed **two** probes — one text, one containing a NUL byte — to
exercise what `-I` was hiding.

**Corollary:** two controls that agree validate nothing if both are poisoned by the
same harness artifact. Controls must differ in the *mechanism under test*, not just
in intent.

## Red Flags — STOP

- The check has only ever returned the answer you wanted
- You are reporting absence ("no leak", "no drift", "0 errors", "nothing found")
- You wrote the check and the code it checks in the same breath
- A "0 results" outcome would look identical to a broken check
- The check is new and has never been seen to fail
- You are about to say "clean" / "0 unresolved" / "all passing"

**Reporting absence is the highest-risk case.** `0` is exactly what a broken check
returns.

## Rationalization Prevention

| Excuse | Reality |
|--------|---------|
| "The logic is obviously right" | Plenty of obviously-right checks measure nothing |
| "I read the code carefully" | Reading did not lower the rate. Planting did |
| "It found things earlier" | Earlier is not now; you changed it since |
| "Testing the failure case is extra work" | It is the only part that proves anything |
| "It returned 0, so we're clean" | A broken check also returns 0 |

## Environment Traps That Produce Silent Blindness

These are real, and each one has cost someone a round of rework:

- **`$?` after a pipe is the last command's exit.** `cmd | tail` then `$?` reads
  `tail`. Save it: `cmd >file; rc=$?`
- **`grep -q 'PATTERN'` matches itself in `ps`.** Use `'PATTER[N]'`
- **`grep -I` never sees files with NUL bytes** — never use it to hunt secrets
- **`pipefail` + `grep -r` over `$TMPDIR`** exits non-zero on a real hit, because
  unreadable dirs raise the status. Capture output; do not trust the exit
- **A markdown link destination containing a space** is not parsed as a link at
  all, so a link checker reports it as neither broken nor present

## When To Apply

**ALWAYS before:**
- Trusting a new test, assertion, linter, grep or verification script
- Reporting that something is absent, clean, empty, or zero
- Declaring a sweep or migration complete
- Believing a check you just modified

## Source

This skill is the operational rule only. If you keep a wiki of decisions/lessons
(see docs/wiki-example/ in this repo for the convention), it's worth writing up the
specific verification failures you hit as their own lessons page — that's the
source-of-truth narrative; this file deliberately stays a checklist.
