#!/bin/bash
# Sell Setup checks on losing trades, 3m and 5m, about 5 years, H4 EMA50 trend filter on, 2R:
#   1base | 2nosmall = skip stop < $1 | 3overshoot = NCCLT high must be >= $0.50 above liquidity
#   4hours = no breaks 19:00-24:00 server | 5pad1 = SL +$1 | 6floor15 = stop at least $1.50 | 7combo = 2+3+4
# Usage: ./test_sell_checks.sh      (MT5 must be closed)
cd "$(dirname "$0")"
export TESTSYM=${TESTSYM:-XAUUSDm} TESTDEP=${TESTDEP:-100000}
OUT="$HOME/Documents/aitrading-reports"
./run.sh sell_setup sk
{
  echo "== Chart prices (like TradingView), 1R-4R:"
  for v in $(ls strategies/sell_setup/variants | grep "^sk_" | sed "s/.ini$//"); do
    echo "-- $v"
    iconv -f UTF-16 -t UTF-8 "$OUT/tester_$v.raw.log" 2>/dev/null | grep "FUNNEL" | sed 's/^.*FUNNEL/FUNNEL/' \
      | awk '/setup candles=/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' | grep -v "chart prices"
  done
  echo
  echo "== Real trades at 2R with spread:"
  cat "$OUT/compare_sell_setup_sk.txt" 2>/dev/null
} | tee "$OUT/sell_check_tests.txt"
echo "Saved: $OUT/sell_check_tests.txt"
