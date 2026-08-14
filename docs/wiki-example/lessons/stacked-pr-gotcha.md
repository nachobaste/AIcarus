# Lesson: a stacked PR can silently vanish from view

**Date:** example entry (invented for this starter kit)
**Context:** two devbrain tasks ran back-to-back on the same repo the same night.
The second branched off the first (since the first's branch was the most current
code at that moment), producing a PR stacked on top of the still-open first PR.

## What happened

The next morning, the first PR was reviewed and merged into the base branch. The
second PR's base branch reference did not automatically repoint to the real base
— from the PR list it looked like it was still waiting on the first PR to merge,
so it sat unreviewed for several days. When it was finally opened, GitHub's diff
view showed it as already containing all of the first PR's changes too (since
those commits were now also in its history relative to a stale merge-base), making
it look far larger and riskier than the one line it actually changed.

## The lesson

A PR whose base branch gets merged or advances before the PR itself does can
become invisible or misleading in exactly the two ways that matter: it may not
show up in "needs review" filters the way you expect, and its diff can balloon
with commits that already landed elsewhere. This isn't a GitHub bug — it's a
structural consequence of stacking branches without a mechanism to keep the stack
in sync.

## The mechanical rule that came out of it

Before treating any open PR as "small" or "not yet ready," diff it against the
CURRENT base branch tip, not against whatever its `base` field says — and check
whether commits it appears to introduce are already merged elsewhere. A repo-wide
periodic check that compares each open PR's actual diff against current `origin/
<base>` catches this before a human has to notice it by eye.
