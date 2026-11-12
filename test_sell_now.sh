#!/bin/bash
# Sell Setup, current rules, SELL only: 1H setup, entries on 3m and on 5m, about 5 years of XAUUSDm.
# No trend filter. Real trades at 2R (1R = $100, test balance 100,000) + every signal scored at 1R-4R.
# Usage: ./test_sell_now.sh      (MT5 must be closed)
cd "$(dirname "$0")"
export TESTSYM=${TESTSYM:-XAUUSDm} TESTDEP=${TESTDEP:-100000}
OUT="$HOME/Documents/aitrading-reports"
for v in st_m3_0off st_m5_0off; do ./run.sh sell_setup "$v"; done
{
  for v in st_m3_0off st_m5_0off; do
    echo "== $v  (chart prices, every signal, 1R-4R)"
    iconv -f UTF-16 -t UTF-8 "$OUT/tester_$v.raw.log" 2>/dev/null | grep "FUNNEL" | sed 's/^.*FUNNEL/FUNNEL/' \
      | awk '/setup candles=/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' | grep -v "chart prices"
    echo "-- real trades at 2R with spread:"
    cat "$OUT/summary_$v.txt" 2>/dev/null
    echo
  done
} | tee "$OUT/sell_now_results.txt"
echo "Saved: $OUT/sell_now_results.txt"
