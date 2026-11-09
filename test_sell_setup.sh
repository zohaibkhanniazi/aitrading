#!/bin/bash
# Sell Setup (1H setup -> 3m / 5m entry), SELL only, on about 5 years of XAUUSDm.
# Runs 8 backtests: M3 and M5, each with the target at 1R, 2R, 3R and 4R (1R = $100 risk).
# Then prints the chart-price win rates of every signal (same method as the TradingView table).
# Usage: ./test_sell_setup.sh      (MT5 must be closed)
cd "$(dirname "$0")"
export TESTSYM=${TESTSYM:-XAUUSDm}
OUT="$HOME/Documents/aitrading-reports"
./run.sh sell_setup ss
echo
echo "== Chart-price results of every SELL signal (no spread, stop first if both in one candle)"
for r in ss_m3_r2 ss_m5_r2; do
  grep -h "FUNNEL" "$OUT/tester_$r.txt" 2>/dev/null | sed 's/^.*FUNNEL/FUNNEL/'
  echo
done | tee "$OUT/sell_setup_winrates.txt"
echo "== Real trades above include the spread. Saved: $OUT/sell_setup_winrates.txt"
