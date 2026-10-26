---
repo: canary
status: requested
prioridad: 1
---

# Canary plan

## What was already verified

- the greet function prints "hello" followed by the first argument :: src/greet.sh:5
- MAX_RETRIES is 3 :: config/limits.conf:2
- cleanup.sh deletes the scratch directory with rm -rf :: src/cleanup.sh:3
- TIMEOUT is 60 seconds :: config/limits.conf:3
- greet.sh also defines the function farewell :: src/greet.sh:7
- the jobs table of the production database has 0 rows :: src/greet.sh:1
