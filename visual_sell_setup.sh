#!/bin/bash
# Watch the Sell Setup bot on MT5 (Exness prices) candle by candle in the Strategy Tester.
# It draws what the bot sees: BC box, CC, NCC, liquidity + NCC low lines, NCCLT, SELL with SL/TP.
# MT5 times are server time (UTC+0) = Pakistan time minus 5 hours.
# Usage: ./visual_sell_setup.sh [M3|M5] [from] [to]     e.g. ./visual_sell_setup.sh M5 2026.11.04 2026.11.07
# MT5 must be closed. Close MT5 yourself when you are done looking.
set -u
TF="${1:-M5}"; FROM="${2:-2026.11.04}"; TO="${3:-2026.11.07}"
REPO="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/MetaTrader 5.app"
PREFIX="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"
WINE="$APP/Contents/SharedSupport/wine/bin/wine64"
[ -x "$WINE" ] || WINE="$APP/Contents/SharedSupport/wine/bin/wine"
MT5DIR="$PREFIX/drive_c/Program Files/MetaTrader 5"
export WINEPREFIX="$PREFIX"
if pgrep -fi "terminal64" >/dev/null; then echo "MetaTrader 5 is running. Quit it (Cmd+Q) and run again."; exit 1; fi
"$REPO/compile.sh" sell_setup || exit 1
rm -f "$MT5DIR/MQL5/Profiles/Tester/"*.set 2>/dev/null
cat > "$MT5DIR/tester_run.ini" <<INI
[Tester]
Expert=aitrading\\strategies\\sell_setup\\SellSetup_XAUUSD
Symbol=${TESTSYM:-XAUUSDm}
Period=$TF
Model=1
FromDate=$FROM
ToDate=$TO
Deposit=100000
Currency=USD
Leverage=500
Optimization=0
Visual=1
ShutdownTerminal=0
[TesterInputs]
InpRR=2.0
InpRiskMoney=100.0
InpDraw=true
INI
echo "Opening the visual test ($TF, $FROM - $TO). Use the speed slider at the top; pause to look at any setup."
(cd "$MT5DIR" && "$WINE" terminal64.exe "/config:tester_run.ini") >/dev/null 2>&1
