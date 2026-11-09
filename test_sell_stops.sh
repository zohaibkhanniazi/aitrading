#!/bin/bash
# Sell Setup stop tests on 3m and 5m (about 5 years, XAUUSDm, target 2R, 1R = $100, test balance 100,000):
#   1base  = SL at NCCLT high (your rules)
#   2big   = skip signals whose stop is more than 2x the usual stop
#   3small = skip signals whose stop is less than 0.8x the usual stop
#   4liq   = SL at the liquidity level + $0.30 instead of the NCCLT high
# Usage: ./test_sell_stops.sh      (MT5 must be closed)
cd "$(dirname "$0")"
export TESTSYM=${TESTSYM:-XAUUSDm} TESTDEP=${TESTDEP:-100000}
OUT="$HOME/Documents/aitrading-reports"
./run.sh sell_setup sv
{
  echo "== Chart prices (like TradingView), every signal taken, 1R-4R:"
  for v in sv_m3_1base sv_m3_2big sv_m3_3small sv_m3_4liq sv_m5_1base sv_m5_2big sv_m5_3small sv_m5_4liq; do
    echo "-- $v"
    grep -h "FUNNEL" "$OUT/tester_$v.txt" 2>/dev/null | sed 's/^.*FUNNEL/FUNNEL/' | grep -v "chart prices"
  done
  echo
  echo "== Real trades at 2R with spread:"
  cat "$OUT/compare_sell_setup_sv.txt" 2>/dev/null
} | tee "$OUT/sell_stop_tests.txt"
echo "Saved: $OUT/sell_stop_tests.txt"
