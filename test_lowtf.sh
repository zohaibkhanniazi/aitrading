#!/bin/bash
# RSI(2) and fractal breakout (1R target, break-even at 0.5R) on M1 and M3.
# Usage: ./test_lowtf.sh        (MT5 must be closed)
cd "$(dirname "$0")"
export TESTSYM=${TESTSYM:-XAUUSDm}
./run.sh rsi2 r2lo
./run.sh fractal fslo
echo "== M1/M3 tests finished"
