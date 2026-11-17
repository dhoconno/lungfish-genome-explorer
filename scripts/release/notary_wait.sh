#!/bin/bash
# notary_wait.sh [--profile NAME] [--keychain PATH]
#
# The wait for Apple's notary service after `release.py setup` fails on the timestamp server or on a notary HTTP 401
# (E-RUN-69, the publish step of .claude/agents/lge-release.md). Each of 5 rounds runs
# `xcrun notarytool history --keychain-profile NAME [--keychain PATH]` under an alarm of NOTARY_WAIT_PROBE_S seconds
# (default 90). NAME defaults to LungfishNotary, and the release agent passes the notary profile and keychain of its
# release profile when they differ. Rounds start 600 seconds apart, so the wait ends within 5 * 90 + 4 * 600 seconds,
# 47.5 minutes. A round passes only when the probe ran, exited 0 within its alarm and printed no error, so a probe cut
# off by the alarm or one that cannot start never reads as a pass. The probe checks the notary credential only, so
# `release.py setup` runs again after a pass.
#
# Prints "round N HH:MM: exit S, <first line of the probe's output>" for each failed round, then "NOTARY-OK HH:MM" with
# exit 0 at the first pass, or "NOTARY-STILL-DOWN HH:MM" with exit 1 after the last round. Exit 2 is a bad argument.
# Copied on 2026-11-17 from the manager's script of session rnaseq-5-1-e, which read a probe with no output as a pass.
set -u
profile=LungfishNotary keychain="" probe_s=${NOTARY_WAIT_PROBE_S:-90} rounds=5 gap=600
error_words='HTTP status code|[Ee]rror'

usage() {
  echo "usage: notary_wait.sh [--profile NAME] [--keychain PATH]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --profile) profile=$2 ;;
    --keychain) keychain=$2 ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$profile" ] || usage
case $probe_s in '' | *[!0-9]*) usage ;; esac

probe=(xcrun notarytool history --keychain-profile "$profile")
if [ -n "$keychain" ]; then probe+=(--keychain "$keychain"); fi

for ((round = 1; round <= rounds; round++)); do
  # The alarm outlives exec, so a probe still running at the limit dies by SIGALRM (status 142), and a probe that
  # cannot start ends perl with its error and a nonzero status.
  out=$(perl -e 'alarm shift; exec @ARGV or die "cannot run $ARGV[0]: $!\n"' "$probe_s" "${probe[@]}" 2>&1)
  status=$?
  if [ "$status" -eq 0 ] && ! [[ $out =~ $error_words ]]; then
    echo "NOTARY-OK $(date '+%H:%M')"
    exit 0
  fi
  first=${out%%$'\n'*}
  if [ "$status" -gt 128 ] && [ -z "$first" ]; then first="no answer within ${probe_s} s"; fi
  echo "round $round $(date '+%H:%M'): exit $status, ${first:0:80}"
  if [ "$round" -lt "$rounds" ]; then sleep "$gap"; fi
done
echo "NOTARY-STILL-DOWN $(date '+%H:%M')"
exit 1
