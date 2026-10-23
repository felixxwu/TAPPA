#!/usr/bin/env bash
# butler push with a retry for itch.io's "latest build is still processing".
#
# Pushes to main land minutes apart, and itch keeps processing a channel's
# build for a while after butler returns. When the next run reaches the same
# channel first, itch answers 400 "channel X's latest build is still
# processing, try again later" and the job fails although nothing is wrong
# (runs #743, #744, #747, #749 on 2026-10-23, all on the Windows .exe). Wait
# and try again on that one error only; anything else fails straight away.
#
# Usage: butler_push.sh <path> <user/game:channel>
set -uo pipefail

attempts=10
delay=30
for ((i = 1; i <= attempts; i++)); do
  out=$(butler push "$@" 2>&1)
  status=$?
  echo "$out"
  if [[ $status -eq 0 ]]; then
    exit 0
  fi
  if ! grep -q "still processing" <<<"$out"; then
    exit "$status"
  fi
  if ((i < attempts)); then
    echo "itch is still processing the previous build; retrying in ${delay}s (attempt ${i}/${attempts})"
    sleep "$delay"
  fi
done
echo "::error::itch was still processing the previous build after ${attempts} attempts."
exit 1
