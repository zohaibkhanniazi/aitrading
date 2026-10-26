# Strategy rules (owner: zohaib) -- source of truth

## Strategy 1: Trend-aligned engulfing (strategies/engulfing_trend, engulfing_confirm)
- Bullish engulfing -> buy only in uptrend (close > EMA50 > EMA200); bearish engulfing -> sell only in downtrend.
- Pattern against the trend is ignored. No trade when there is no clear trend.
- Stop beyond the pattern extreme, TP = 2R, 1% risk, one position at a time.
- Tested confirmations: ADX, EMA slope, RSI, ATR body size, pullback, session.

## Strategy 2: Smart-money order block (strategies/smc_ob)  -- owner's rules
1. **1H POI** = order block + liquidity.
   - Order block is considered **only when it comes with an FVG** (fair value gap / imbalance).
2. Filter down to **30 min** to make the stop loss smaller.
3. Filter further to **15 min**.
4. Take the trade on **5 min**: order block / mitigation block entry.

### How the code interprets them (decisions confirmed by owner)
- H1 order block = last opposite candle before a strong break of structure.
- Liquidity = a swing high/low (or equal highs/lows) must be swept first (coded: OB candle makes a new low vs the previous 10 H1 bars).
- M5 entry = M5 change of character after tapping the refined zone, then enter on the first pullback into the M5 order block.
- Zone is mitigated (dead) once an H1 candle closes through it.
- FVG: 3-candle gap left by the impulse after the OB (newer candle low > older candle high), minimum size 0.05 x H1 ATR.

### Open questions / to refine with the owner
- Exact mitigation-block definition; FVG on which timeframe(s); take-profit target (fixed RR vs next liquidity).

## Testing standard (checklist)
200+ trades, profit factor >= 1.3, max drawdown <= 25%, profitable in 2+ other periods, then real-ticks run, then demo forward test.
