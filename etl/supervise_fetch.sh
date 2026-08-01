#!/bin/bash
# Keep a long region fetch alive across crashes, network drops and logouts.
#
# The CONUS pull runs for well over a day. fetch_inat.py resumes from the last
# observation id, so restarting it costs nothing but the current page - the only
# real failure mode is nobody noticing it stopped.
#
#   nohup etl/supervise_fetch.sh conus > data/supervise_conus.log 2>&1 &
#
# Exits on its own once the fetch reports completion.

set -u
REGION="${1:?usage: supervise_fetch.sh <region>}"
cd "$(dirname "$0")/.." || exit 1

LOG="data/fetch_${REGION}.log"
STATE="data/obs_${REGION}.state.json"
CHECK_EVERY=60
STALL_AFTER=1800     # state file untouched this long means wedged, not working

restarts=0
while true; do
  if grep -q "^done:" "$LOG" 2>/dev/null; then
    echo "$(date '+%F %T') fetch complete after $restarts restart(s)"
    exit 0
  fi

  if ! pgrep -f "fetch_inat.py $REGION" > /dev/null; then
    restarts=$((restarts + 1))
    echo "$(date '+%F %T') not running - starting (restart #$restarts)"
    nohup python3 etl/fetch_inat.py "$REGION" >> "$LOG" 2>&1 &
    sleep 30
    continue
  fi

  # Running but making no progress: kill it and let the next pass restart it,
  # since a wedged socket read can outlast any single request timeout.
  if [ -f "$STATE" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$STATE") ))
    if [ "$age" -gt "$STALL_AFTER" ]; then
      echo "$(date '+%F %T') stalled ${age}s with no progress - restarting"
      pkill -f "fetch_inat.py $REGION"
      sleep 5
      continue
    fi
  fi

  sleep "$CHECK_EVERY"
done
