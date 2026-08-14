# USER.md - About Your Human

- **Name:** <YOUR_NAME>
- **What to call them:** <YOUR_PREFERRED_NAME>
- **Timezone:** <YOUR_TIMEZONE> (e.g. America/Guatemala)
- **Telegram ID:** <YOUR_TELEGRAM_CHAT_ID> — the ONLY authorized user of this system
  (get this from @userinfobot or similar; see setup.sh)
- **Notes:** <anything about how you like to be talked to — language, tone,
  technical depth. Example: "guided beginner developer: talk to me plainly, explain
  jargon before using it.">

## Context

- **Their goal:** <what this automation is FOR, in one line — e.g. "free up time
  from repetitive dev work" or "let me ship small fixes without opening a laptop">.
- Projects enabled for `devbrain` (allowlist): keep this in sync with
  `devbrain-projects.allow` at the root of this repo.
- Any project you've marked production-sensitive: note it here explicitly, e.g.
  "**`<repo>` is PRODUCTION** with real users. PRs go to the `develop` branch
  (never `main`), devbrain doesn't touch migrations there, and there's automatic
  review. When showing a plan for it, remind them it's production."
- Any project deliberately on hold: note it here too, e.g. "**`<repo>` is PAUSED**
  — don't route tasks there until they explicitly say to."
- This system is documented in the README of this repo; project memory lives in
  `~/dev/wiki/` (maintained by the coding agent, not by you).
