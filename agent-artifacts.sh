#!/usr/bin/env bash
#
# Print the agent-system artifacts tied to a branch, if any:
#
#   tracker: ~/tmp/abema-androidtv-agents/scratch/<feature>   local-markdown issue tracker
#   ship-run: ~/tmp/ship/<slug>                               ship skill run directory
#
# The feature/slug is matched against the branch's path segments, last first
# (suraj/fixed-focus/tab-frame checks tab-frame, then fixed-focus, then suraj).
# Prints nothing when nothing matches; always exits 0 so callers can tack it
# onto their output unconditionally.
#
# Usage:  ./agent-artifacts.sh <branch>

set -euo pipefail

TRACKER_SCRATCH="$HOME/tmp/abema-androidtv-agents/scratch"
SHIP_RUNS="$HOME/tmp/ship"

branch="${1:-}"
[[ -n "$branch" ]] || exit 0

IFS='/' read -r -a segs <<< "$branch"

ticket=""
shiprun=""
for (( i=${#segs[@]}-1; i>=0; i-- )); do
  seg="${segs[$i]}"
  [[ -n "$seg" ]] || continue
  if [[ -z "$ticket" && -d "$TRACKER_SCRATCH/$seg" ]]; then
    ticket="$TRACKER_SCRATCH/$seg"
  fi
  if [[ -z "$shiprun" && -d "$SHIP_RUNS/$seg" ]]; then
    shiprun="$SHIP_RUNS/$seg"
  fi
done

if [[ -n "$ticket" ]]; then
  echo "tracker: $ticket"
  [[ -f "$ticket/spec.md" ]] && echo "spec: $ticket/spec.md"
fi
if [[ -n "$shiprun" ]]; then
  echo "ship-run: $shiprun"
fi
exit 0
