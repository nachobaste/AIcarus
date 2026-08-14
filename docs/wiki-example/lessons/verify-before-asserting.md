# Lesson: verify before asserting

**Date:** example entry (invented for this starter kit)
**Context:** an agent session reported "the database migration is already live"
based on grep'ing the migrations folder in the repo. It never queried the actual
database.

## What happened

The migration file existed in git and looked merged. The agent treated "the code
that would apply this migration exists" as equivalent to "this migration is
applied to the real database." It wasn't — a previous deploy had failed silently,
and the table the new code expected didn't exist yet. The frontend built fine
(nothing type-checks against a live database schema) and the bug only surfaced at
runtime, for real users, hours later.

## The lesson

**Existing in code is not existing.** Before stating that a resource is live — a
migration, a deployed environment, a feature flag, an external service — touch it.
Query the database. Curl the endpoint. Check the actual dashboard. A reference in
source control proves that someone intended for it to exist, not that it does.

This generalizes past databases: "the API key is configured" (check the actual
environment, don't infer from a `.env.example`), "the cron job runs" (check its
last successful run, don't infer from the crontab entry existing), "the test
suite covers this" (run it and watch it exercise the code path, don't infer from
a file named `test_thing.py` existing).

## The mechanical rule that came out of it

Before any status claim ("X is live", "X is configured", "X works"), name the
specific command or query that would prove it, and run it. If you can't name one,
that's the tell that you're about to assert instead of verify.
