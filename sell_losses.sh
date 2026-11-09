#!/bin/bash
# Sell Setup: full list of signals and 2R losses on 3m and 5m (about 5 years, XAUUSDm).
# The test balance is 100,000 so no signal is skipped (1R is still $100).
# Each signal also lists its chain: BC hour, CC, NCC, liquidity, NCCLT (Pakistan time).
# Usage: ./sell_losses.sh      (MT5 must be closed)
cd "$(dirname "$0")"
export TESTSYM=${TESTSYM:-XAUUSDm} TESTDEP=${TESTDEP:-100000}
OUT="$HOME/Documents/aitrading-reports"
for v in ss_m3_r2 ss_m5_r2; do ./run.sh sell_setup "$v"; done
echo
python3 tools/sell_losses.py "$OUT/tester_ss_m3_r2.raw.log" M3 "$OUT/sell_setup_3m"
echo
python3 tools/sell_losses.py "$OUT/tester_ss_m5_r2.raw.log" M5 "$OUT/sell_setup_5m"
