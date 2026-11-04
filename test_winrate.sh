#!/bin/bash
# High-win-rate tests: RSI(2) mean reversion + fractal breakout H1 with 0.5R / 1R targets.
# Usage: ./test_winrate.sh        (MT5 must be closed)
cd "$(dirname "$0")"
export TESTSYM=${TESTSYM:-XAUUSDm}
./run.sh rsi2 r2
./run.sh fractal fs
echo "== win-rate tests finished"
