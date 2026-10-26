#!/bin/bash
# One-command: git pull -> compile EA -> run Strategy Tester -> open report.
# Usage: ./run.sh <strategy> [variant|group|all]  (group = prefix, e.g. "tune" runs variants/tune_*.ini)
# (old) Usage: ./run.sh <strategy> [variant|all]   e.g. ./run.sh engulfing_confirm all
#   variant = a file strategies/<strategy>/variants/<variant>.ini ; "all" runs every variant and compares.
# MetaTrader 5 must be CLOSED before running (the tester launches its own copy).
set -u
OUT="$HOME/Documents/aitrading-reports"; mkdir -p "$OUT"
exec > >(tee "$OUT/last_run.txt") 2>&1
STRAT="${1:-bullish_engulfing}"
REPO="$(cd "$(dirname "$0")" && pwd)"

APP="/Applications/MetaTrader 5.app"
PREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"
WINE="$APP/Contents/SharedSupport/wine/bin/wine64"
[ -x "$WINE" ] || WINE="$APP/Contents/SharedSupport/wine/bin/wine"
MT5DIR="$PREFIX/drive_c/Program Files/MetaTrader 5"

[ -x "$WINE" ] || { echo "Cannot find Wine inside $APP. Edit APP at top of run.sh."; exit 1; }
[ -d "$MT5DIR" ] || { echo "Cannot find $MT5DIR. Edit PREFIX at top of run.sh."; exit 1; }
if pgrep -fi "terminal64" >/dev/null; then echo "MetaTrader 5 is running. Quit it (Cmd+Q) and run again."; exit 1; fi
export WINEPREFIX="$PREFIX"

echo "== 1/4 git pull"; git -C "$REPO" pull --ff-only || exit 1

SRC=$(ls "$REPO/strategies/$STRAT/"*.mq5 2>/dev/null | head -1)
[ -n "$SRC" ] || { echo "No .mq5 in strategies/$STRAT"; exit 1; }
WIN_SRC="MQL5\\Experts\\aitrading\\strategies\\$STRAT\\$(basename "$SRC")"

echo "== 2/4 compile"
(cd "$MT5DIR" && "$WINE" metaeditor64.exe "/compile:$WIN_SRC" /log) 2>&1 | tail -5
LOG="${SRC%.mq5}.log"
[ -f "$LOG" ] && iconv -f UTF-16 -t UTF-8 "$LOG" 2>/dev/null | tail -3
EX5="${SRC%.mq5}.ex5"
[ "$EX5" -nt "$SRC" ] || { echo "Compile failed - see $LOG"; [ -f "$LOG" ] && cp "$LOG" "$OUT/compile.log"; exit 1; }

VAR="${2:-}"
run_one() {  # $1 = ini path
  local INI="$1"
  local REP; REP=$(grep -i '^Report=' "$INI" | head -1 | cut -d= -f2 | tr -d '\r\n ')
  # MT5 remembers the previous run's inputs in a .set file; delete it so every run starts from the EA defaults
  rm -f "$MT5DIR/MQL5/Profiles/Tester/"*.set 2>/dev/null
  cp "$INI" "$MT5DIR/tester_run.ini"
  # Optional: TESTSYM=XAUUSDm ./run.sh ...  -> test on the account's own gold symbol (standard account: USD, 1000)
  if [ -n "$TESTSYM" ]; then
    sed -e "s/^Symbol=.*/Symbol=$TESTSYM/" -e "s/^Currency=.*/Currency=USD/" -e "s/^Deposit=.*/Deposit=1000/" "$MT5DIR/tester_run.ini" > "$MT5DIR/tester_run.tmp" && mv "$MT5DIR/tester_run.tmp" "$MT5DIR/tester_run.ini"
  fi
  touch "$MT5DIR/.start"
  echo "== backtest: $REP (may take a few minutes)"
  (cd "$MT5DIR" && "$WINE" terminal64.exe "/config:tester_run.ini")
  for i in $(seq 1 60); do pgrep -fi "terminal64|metatester64" >/dev/null || break; sleep 2; done
  sleep 3
  local REPORT; REPORT=$(find "$MT5DIR" -maxdepth 2 -newer "$MT5DIR/.start" -name "$REP.htm*" 2>/dev/null | head -1)
  if [ -z "$REPORT" ]; then echo "No report for $REP. Check Symbol in the ini."; return 1; fi
  mkdir -p "$REPO/reports"
  cp "$MT5DIR/$REP"*.png "$REPO/reports/" 2>/dev/null; cp "$MT5DIR/$REP"*.png "$OUT/" 2>/dev/null
  cp "$REPORT" "$REPO/reports/$REP.htm"; cp "$REPORT" "$OUT/$REP.htm"
  local TL; TL=$(ls -t "$MT5DIR"/Tester/Agent-*/logs/*.log 2>/dev/null | head -1)
  [ -n "$TL" ] && { iconv -f UTF-16 -t UTF-8 "$TL" 2>/dev/null | grep -E "FUNNEL|error|failed|invalid|zero|not enough" | tail -20 > "$OUT/tester_$REP.txt"; cp "$TL" "$OUT/tester_$REP.raw.log" 2>/dev/null; }
  echo "===== RESULT: $REP ====="
  python3 "$REPO/tools/summarize.py" "$REPO/reports/$REP.htm" | tee "$OUT/summary_$REP.txt"
  python3 "$REPO/tools/log_result.py" "$REPO/reports/$REP.htm" "$STRAT" "$REP" "$OUT/results.csv" && python3 "$REPO/tools/report.py" "$OUT/results.csv" "$OUT/leaderboard.html" >/dev/null
  python3 "$REPO/tools/dashboard.py" "$REPO/reports/$REP.htm" "$REPO/reports/$REP-dashboard.html" "$REP" && cp "$REPO/reports/$REP-dashboard.html" "$OUT/"
  LAST_DASH="$REPO/reports/$REP-dashboard.html"
}

SD="$REPO/strategies/$STRAT"
FILES=()
if [ "$VAR" = "all" ]; then
  for f in "$SD"/variants/*.ini; do FILES+=("$f"); done
elif [ -n "$VAR" ] && [ ! -f "$SD/variants/$VAR.ini" ]; then
  for f in "$SD"/variants/"$VAR"_*.ini; do [ -f "$f" ] && FILES+=("$f"); done
fi
if [ "${#FILES[@]}" -gt 0 ]; then
  ARGS=()
  for f in "${FILES[@]}"; do
    n=$(basename "$f" .ini); rep=$(grep -i '^Report=' "$f" | head -1 | cut -d= -f2 | tr -d '\r\n ')
    run_one "$f" && ARGS+=("$n=$REPO/reports/$rep.htm")
  done
  echo "== comparison"
  [ "${#ARGS[@]}" -gt 0 ] || { echo "No reports produced."; exit 1; }
  python3 "$REPO/tools/compare.py" "$REPO/reports/$STRAT-${VAR:-all}-compare.html" "${ARGS[@]}" | tee "$OUT/compare_${STRAT}_${VAR:-all}.txt"
  cp "$REPO/reports/$STRAT-${VAR:-all}-compare.html" "$OUT/"; open "$REPO/reports/$STRAT-${VAR:-all}-compare.html"
else
  INI="$SD/tester.ini"; [ -n "$VAR" ] && INI="$SD/variants/$VAR.ini"
  [ -f "$INI" ] || { echo "Missing $INI"; exit 1; }
  LAST_DASH=""
  run_one "$INI" && [ -n "$LAST_DASH" ] && open "$LAST_DASH"
fi
