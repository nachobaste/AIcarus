#!/bin/bash
# lib/schedule.sh — schedule matching for a manifest of periodic jobs.
# Pure function: no network, no files, no `date`. The caller passes the instant.
# This ships as generic, reusable infrastructure — the starter kit doesn't include
# any actual scheduled-job manifest (the reference system used it for a fleet of
# scrapers, which are business-specific and not part of this kit), but the matcher
# itself is a handy building block if you wire up your own periodic jobs.
#
# Formats (all in UTC, DOW 1..7 with 1=Monday same as `date -u +%u`):
#   daily:H[,H...]
#   weekly:DOW:H
#   monthly:DOM:H
#   quarterly:M[,M...]:DOM:H
#   manual                  -> never due; documented in the manifest and run by hand
# bash 3.2: no associative arrays, no `wait -n`.

# _in_csv <needle> <csv> -> 0 if present. Compares field by field, NEVER by
# substring: with `case ",$csv," in *",$x,"*)` a "1" could match "10" if the csv
# isn't delimited carefully, and that bug is silent (a job running at the wrong
# hour, not a visible error).
_in_csv() {
  local needle="$1" csv="$2" item oldifs
  oldifs="$IFS"; IFS=','
  for item in $csv; do
    if [ "$item" = "$needle" ]; then IFS="$oldifs"; return 0; fi
  done
  IFS="$oldifs"; return 1
}

# _is_num <s> -> 0 if it's a non-empty integer
_is_num() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

schedule_is_due() { # <schedule> <dow> <dom> <month> <hour> -> 0 due, 1 not due, 2 invalid
  local sched="${1:-}" dow="${2:-}" dom="${3:-}" month="${4:-}" hour="${5:-}"
  [ -z "$sched" ] && return 2

  # `manual` has no ':' — handled before parsing so it isn't mistaken for an
  # invalid format. Never due.
  [ "$sched" = "manual" ] && return 1

  local kind rest
  kind="${sched%%:*}"
  rest="${sched#*:}"
  [ "$rest" = "$sched" ] && return 2   # no ':' -> invalid format

  case "$kind" in
    daily)
      [ -z "$rest" ] && return 2
      _in_csv "$hour" "$rest" && return 0
      return 1
      ;;
    weekly)
      local w_dow w_hour
      w_dow="${rest%%:*}"; w_hour="${rest#*:}"
      [ "$w_hour" = "$rest" ] && return 2
      _is_num "$w_dow" && _is_num "$w_hour" || return 2
      [ "$w_dow" = "$dow" ] && [ "$w_hour" = "$hour" ] && return 0
      return 1
      ;;
    monthly)
      local m_dom m_hour
      m_dom="${rest%%:*}"; m_hour="${rest#*:}"
      [ "$m_hour" = "$rest" ] && return 2
      _is_num "$m_dom" && _is_num "$m_hour" || return 2
      [ "$m_dom" = "$dom" ] && [ "$m_hour" = "$hour" ] && return 0
      return 1
      ;;
    quarterly)
      local q_months q_rest q_dom q_hour
      q_months="${rest%%:*}"; q_rest="${rest#*:}"
      [ "$q_rest" = "$rest" ] && return 2
      q_dom="${q_rest%%:*}"; q_hour="${q_rest#*:}"
      [ "$q_hour" = "$q_rest" ] && return 2
      [ -z "$q_months" ] && return 2
      _is_num "$q_dom" && _is_num "$q_hour" || return 2
      _in_csv "$month" "$q_months" || return 1
      [ "$q_dom" = "$dom" ] && [ "$q_hour" = "$hour" ] && return 0
      return 1
      ;;
    *) return 2 ;;
  esac
}
