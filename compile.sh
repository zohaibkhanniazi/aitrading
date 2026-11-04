#!/bin/bash
# Pull and compile one strategy's EA without running a backtest. MT5 can stay open.
# Usage: ./compile.sh <strategy>      e.g. ./compile.sh tsmom_live
set -u
STRAT="${1:?usage: ./compile.sh <strategy folder>}"
REPO="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/MetaTrader 5.app"
PREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"
WINE="$APP/Contents/SharedSupport/wine/bin/wine64"
[ -x "$WINE" ] || WINE="$APP/Contents/SharedSupport/wine/bin/wine"
MT5DIR="$PREFIX/drive_c/Program Files/MetaTrader 5"
export WINEPREFIX="$PREFIX"

git -C "$REPO" pull --ff-only || exit 1
SRC=$(ls "$REPO/strategies/$STRAT/"*.mq5 2>/dev/null | head -1)
[ -n "$SRC" ] || { echo "No .mq5 in strategies/$STRAT"; exit 1; }
WIN_SRC="MQL5\\Experts\\aitrading\\strategies\\$STRAT\\$(basename "$SRC")"
(cd "$MT5DIR" && "$WINE" metaeditor64.exe "/compile:$WIN_SRC" /log) >/dev/null 2>&1
LOG="${SRC%.mq5}.log"
[ -f "$LOG" ] && iconv -f UTF-16 -t UTF-8 "$LOG" 2>/dev/null | grep -iE "error|warning|result" | tail -10
EX5="${SRC%.mq5}.ex5"
if [ "$EX5" -nt "$SRC" ]; then echo "OK: compiled $(basename "$EX5"). In MT5: Navigator -> right-click Expert Advisors -> Refresh."; else echo "Compile FAILED - send the lines above to Claude."; exit 1; fi
