#!/bin/bash
# Sell Setup with a trend filter (checked at the break), 3m and 5m, about 5 years, XAUUSDm, 2R, 1R = $100:
#   0off = no filter | 1h4ema = H4 close < EMA50 | 2d1ema = D1 close < EMA50 | 3h4struct = H4 lower lows
#   4h1ema = H1 close < EMA50 | 5h1struct = H1 lower lows
# Usage: ./test_sell_trend.sh      (MT5 must be closed)
cd "$(dirname "$0")"
export TESTSYM=${TESTSYM:-XAUUSDm} TESTDEP=${TESTDEP:-100000}
OUT="$HOME/Documents/aitrading-reports"
./run.sh sell_setup st
{
  echo "== Chart prices (like TradingView), 1R-4R:"
  for v in st_m3_0off st_m3_1h4ema st_m3_2d1ema st_m3_3h4struct st_m3_4h1ema st_m3_5h1struct st_m5_0off st_m5_1h4ema st_m5_2d1ema st_m5_3h4struct st_m5_4h1ema st_m5_5h1struct; do
    echo "-- $v"
    iconv -f UTF-16 -t UTF-8 "$OUT/tester_$v.raw.log" 2>/dev/null | grep "FUNNEL" | sed 's/^.*FUNNEL/FUNNEL/' \
      | awk '/setup candles=/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' | grep -v "chart prices"
  done
  echo
  echo "== Real trades at 2R with spread:"
  cat "$OUT/compare_sell_setup_st.txt" 2>/dev/null
} | tee "$OUT/sell_trend_tests.txt"
echo "Saved: $OUT/sell_trend_tests.txt"
