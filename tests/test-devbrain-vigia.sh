#!/bin/bash
# tests/test-devbrain-vigia.sh — bin/devbrain-vigia: scheduled jobs that are not loaded,
# failing or stalled. Everything runs on fake files through environment variables: it never
# reads the real ~/Library/LaunchAgents, never runs the real launchctl, never writes the real
# state. Canaries: with the stall threshold made huge the stall test must go red, and with a
# prefix that matches nothing every test must go red (and only the ones that look for a finding).
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
export DEVBRAIN_NO_TG=1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-vigia"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
die() { echo "FAIL (line ${BASH_LINENO[0]})"; exit 1; }
mkdir -p "$TMP/la"

for l in loaded unloaded failing; do
cat > "$TMP/la/com.devbrain.$l.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.devbrain.$l</string>
<key>StartInterval</key><integer>3600</integer></dict></plist>
P
done
# a plist of somebody else's job: must never be judged
cat > "$TMP/la/com.example.other.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.example.other</string>
<key>StartInterval</key><integer>3600</integer></dict></plist>
P
# fake launchctl: list = loaded jobs; print = runs / last exit code per label.
cat > "$TMP/launchctl" <<'P'
#!/bin/bash
case "$1" in
  list) printf -- '-\t0\tcom.devbrain.loaded\n-\t1\tcom.devbrain.failing\n' ;;
  print) case "$2" in
    *failing) printf '\truns = 9\n\tlast exit code = 78\n' ;;
    *) printf '\truns = %s\n\tlast exit code = 0\n' "${FAKE_RUNS:-5}" ;;
  esac ;;
esac
P
chmod +x "$TMP/launchctl"

BOOT="$(date -u -j -f %FT%T 2026-10-08T01:00:00 +%s 2>/dev/null || date -u -d 2026-10-08T01:00:00 +%s)"
vigia() { # prints the section; extra environment goes before the call
  VIGIA_LAUNCHD_DIR="$TMP/la" VIGIA_LAUNCHCTL="${VIGIA_LAUNCHCTL:-$TMP/launchctl}" VIGIA_STATE="$TMP/state.json" VIGIA_LOG="$TMP/vigia.log" \
  VIGIA_NOW="${VIGIA_NOW:-2026-10-08T12:00:00Z}" VIGIA_BOOT_EPOCH="$BOOT" \
  python3 "$BIN" 2>&1
}

# Each test returns 0 if it passes and prints its name if it fails.
t_not_loaded()   { vigia | grep -q 'NOT loaded.*com.devbrain.unloaded' || { echo "t_not_loaded"; return 1; }; }
t_failing()      { vigia | grep -q 'com.devbrain.failing: last exit code 78' || { echo "t_failing"; return 1; }; }

out="$(vigia)"; echo "$out"
t_not_loaded && echo "OK: a plist that is not loaded" || die
t_failing && echo "OK: last exit code != 0" || die
echo "$out" | grep -q 'no graphical' && echo "OK: it warns about a reboot with nobody signed in" || die
echo "$out" | grep -q 'com.example.other' && die || echo "OK: a plist outside the prefix is never judged"
echo "$out" | grep -q 'com.devbrain.loaded:' && die || echo "OK: a loaded, healthy job gives nothing"
[ "$(echo "$out" | grep -c 'What to do')" -ge 2 ] && echo "OK: every finding says what to do" || die
[ -s "$TMP/vigia.log" ] && [ -s "$TMP/state.json" ] && echo "OK: it writes only its own state and log" || die

# Stalled: the `runs` counter does not move for more than 3x the interval (1 h) between watches.
FAKE_RUNS=5 vigia >/dev/null                       # baseline: runs=5 seen now
o2="$(VIGIA_NOW=2026-10-08T16:00:00Z FAKE_RUNS=5 vigia)"
echo "$o2" | grep -q 'com.devbrain.loaded: loaded but not executed' && echo "OK: loaded but stalled 4 h with a 1 h interval" || die
o3="$(VIGIA_NOW=2026-10-08T16:00:00Z FAKE_RUNS=6 vigia)"
echo "$o3" | grep -q 'com.devbrain.loaded: loaded but' && die || echo "OK: if the counter advanced it does not warn"

# No findings: everything loaded and healthy is one line.
rm -f "$TMP/la/com.devbrain.unloaded.plist" "$TMP/la/com.devbrain.failing.plist"
rm -f "$TMP/state.json"
o4="$(FAKE_RUNS=5 vigia)"
[ "$o4" = "  no findings" ] && echo "OK: nothing to report is one line" || { echo "got: $o4"; die; }

# No launchd on the machine: prints nothing (the digest then has no section).
o5="$(VIGIA_LAUNCHCTL=/nonexistent/launchctl vigia)"
[ -z "$o5" ] && echo "OK: no launchctl means no output" || { echo "got: $o5"; die; }

# A broken reader is said, not hidden.
printf 'not a plist' > "$TMP/la/com.devbrain.broken.plist"
o6="$(vigia)"
echo "$o6" | grep -q '\[jobs\] could not read' && echo "OK: an unreadable plist is reported, the digest is not taken down" || die
rm -f "$TMP/la/com.devbrain.broken.plist"

# Canaries: each planted defect makes ITS test go red and no other.
for l in unloaded failing; do
cat > "$TMP/la/com.devbrain.$l.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.devbrain.$l</string>
<key>StartInterval</key><integer>3600</integer></dict></plist>
P
done
r="$(VIGIA_LABEL_PREFIX=com.nothing. t_not_loaded)"; rc=$?
[ $rc -ne 0 ] && [ "$r" = "t_not_loaded" ] && echo "OK: canary, a prefix that matches nothing -> $r goes red" || die
r="$(VIGIA_LABEL_PREFIX=com.nothing. t_failing)"; rc=$?
[ $rc -ne 0 ] && [ "$r" = "t_failing" ] && echo "OK: the same canary -> $r goes red" || die
rm -f "$TMP/state.json"; FAKE_RUNS=5 vigia >/dev/null
o7="$(VIGIA_UMBRAL=1000000 VIGIA_NOW=2026-10-08T16:00:00Z FAKE_RUNS=5 vigia)"
echo "$o7" | grep -q 'com.devbrain.loaded: loaded but not executed' && die || echo "OK: canary, a huge threshold -> the stall finding goes away"
echo "PASS: devbrain-vigia"
