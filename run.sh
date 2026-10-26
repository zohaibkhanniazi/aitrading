#!/bin/bash
# One-command: git pull -> compile EA -> run Strategy Tester -> open report.
# Usage: ./run.sh <strategy_folder_name>     e.g. ./run.sh bullish_engulfing
# MetaTrader 5 must be CLOSED before running (the tester launches its own copy).
set -u
STRAT="${1:-bullish_engulfing}"
REPO="$(cd "$(dirname "$0")" && pwd)"

APP="/Applications/MetaTrader 5.app"
PREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"
WINE="$(find "$APP" -name wine64 -type f 2>/dev/null | head -1)"
[ -z "$WINE" ] && WINE="$(find "$APP" -name wine -type f 2>/dev/null | head -1)"
MT5DIR="$PREFIX/drive_c/Program Files/MetaTrader 5"

[ -x "$WINE" ] || { echo "Cannot find Wine inside $APP. Edit APP at top of run.sh."; exit 1; }
[ -d "$MT5DIR" ] || { echo "Cannot find $MT5DIR. Edit PREFIX at top of run.sh."; exit 1; }
if pgrep -fi "terminal64" >/dev/null; then echo "MetaTrader 5 is running. Quit it (Cmd+Q) and run again."; exit 1; fi
export WINEPREFIX="$PREFIX"

echo "== 1/4 git pull"; git -C "$REPO" pull --ff-only || exit 1

SRC=$(ls "$REPO/strategies/$STRAT/"*.mq5 2>/dev/null | head -1)
[ -n "$SRC" ] || { echo "No .mq5 in strategies/$STRAT"; exit 1; }
WIN_SRC="C:\\Program Files\\MetaTrader 5\\MQL5\\Experts\\aitrading\\strategies\\$STRAT\\$(basename "$SRC")"

echo "== 2/4 compile"
"$WINE" "C:\\Program Files\\MetaTrader 5\\metaeditor64.exe" /compile:"$WIN_SRC" /log >/dev/null 2>&1
LOG="${SRC%.mq5}.log"
[ -f "$LOG" ] && iconv -f UTF-16 -t UTF-8 "$LOG" 2>/dev/null | tail -3
EX5="${SRC%.mq5}.ex5"
[ "$EX5" -nt "$SRC" ] || { echo "Compile failed - see $LOG"; exit 1; }

echo "== 3/4 backtest (may take a few minutes)"
cp "$REPO/strategies/$STRAT/tester.ini" "$MT5DIR/tester_$STRAT.ini"
touch "$MT5DIR/.start"
"$WINE" "C:\\Program Files\\MetaTrader 5\\terminal64.exe" /config:"C:\\Program Files\\MetaTrader 5\\tester_$STRAT.ini"

echo "== 4/4 report"
REPORT=$(find "$MT5DIR" -maxdepth 2 -newer "$MT5DIR/.start" \( -name "*$STRAT*.htm" -o -name "*$STRAT*.html" \) 2>/dev/null | head -1)
if [ -n "$REPORT" ]; then
  mkdir -p "$REPO/reports"; cp "$REPORT" "$REPO/reports/$STRAT.htm"
  echo "Report: $REPO/reports/$STRAT.htm"; open "$REPO/reports/$STRAT.htm"
else
  echo "No report found. Check tester.ini (Symbol must match your broker's gold symbol, e.g. XAUUSDc/XAUUSDm)."
fi
