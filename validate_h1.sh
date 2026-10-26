#!/bin/bash
# Runs the validation batches for the three H1 candidates, one after another.
# Usage: ./validate_h1.sh        (MT5 must be closed)
cd "$(dirname "$0")"
export TESTSYM=${TESTSYM:-XAUUSDm}
./run.sh fractal fv
./run.sh engulfing_multi ev
./run.sh pullback pv
echo "== all validation batches finished"
