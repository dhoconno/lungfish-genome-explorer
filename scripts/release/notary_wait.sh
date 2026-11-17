#!/bin/bash
# Probe the notary profile until it authenticates (Apple outage 2026-11-17). Prints NOTARY-OK or NOTARY-STILL-DOWN.
for round in 1 2 3 4 5; do
  out=$(perl -e 'alarm shift; exec @ARGV' 90 xcrun notarytool history --keychain-profile LungfishNotary 2>&1 | head -3)
  if ! printf '%s' "$out" | grep -q -E 'HTTP status code|Error|error'; then
    echo "NOTARY-OK $(date '+%H:%M')"; exit 0
  fi
  echo "round $round $(date '+%H:%M'): $(printf '%s' "$out" | head -1 | cut -c1-80)"
  [ "$round" -lt 5 ] && sleep 600
done
echo "NOTARY-STILL-DOWN $(date '+%H:%M')"
