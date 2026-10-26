#!/bin/bash
# Run every variant of several strategies, then show the combined leaderboard.
# Usage: ./runmulti.sh asian_sweep silver_bullet pd_raid
REPO="$(cd "$(dirname "$0")" && pwd)"
OUT="$HOME/Documents/aitrading-reports"
[ "$#" -gt 0 ] || { echo "Usage: ./runmulti.sh <strategy> [<strategy> ...]"; exit 1; }
for s in "$@"; do
  echo "######## $s ########"
  "$REPO/run.sh" "$s" all
done
python3 "$REPO/tools/report.py" "$OUT/results.csv" "$OUT/leaderboard.html" && cp "$OUT/leaderboard.html" "$REPO/reports/leaderboard.html" 2>/dev/null; open "$OUT/leaderboard.html"
