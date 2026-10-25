"""
Bullish Engulfing strategy - backtester (v1)

Rules (all adjustable in CONFIG):
  Signal : previous candle bearish, current candle bullish, and the current
           body fully engulfs the previous body (open <= prev close,
           close >= prev open). Optional downtrend filter (close < SMA).
  Entry  : OPEN of the NEXT candle after the signal (no look-ahead).
  Stop   : lowest low of the two pattern candles (minus optional buffer).
  Target : entry + RR * (entry - stop).
  Size   : risk a fixed % of equity per trade, no leverage.
  Costs  : fee + slippage applied per side.

Usage:
  python bullish_engulfing_bot.py --csv data.csv
  python bullish_engulfing_bot.py --demo
CSV needs columns: time, open, high, low, close  (case-insensitive)
"""
import argparse
import numpy as np
import pandas as pd

CONFIG = dict(
    start_equity=10_000.0,
    risk_per_trade=0.01,      # 1% of equity risked per trade
    rr=2.0,                   # take profit = 2R
    stop_buffer_pct=0.0,      # extra room below the pattern low (e.g. 0.001 = 0.1%)
    use_trend_filter=True,    # only take signals when price is below SMA (pullback/reversal)
    sma_period=50,
    min_body_ratio=0.0,       # current body must be >= ratio * previous body (0 = off)
    fee_pct=0.0005,           # 0.05% per side
    slippage_pct=0.0002,      # 0.02% per side
)


def load_csv(path):
    df = pd.read_csv(path)
    df.columns = [c.strip().lower() for c in df.columns]
    df["time"] = pd.to_datetime(df["time"])
    return df.sort_values("time").reset_index(drop=True)[["time", "open", "high", "low", "close"]]


def demo_data(n=5000, seed=7):
    """Synthetic random-walk candles, only to prove the code runs."""
    rng = np.random.default_rng(seed)
    close = 100 * np.exp(np.cumsum(rng.normal(0, 0.004, n)))
    open_ = np.r_[close[0], close[:-1]] * (1 + rng.normal(0, 0.001, n))
    high = np.maximum(open_, close) * (1 + np.abs(rng.normal(0, 0.002, n)))
    low = np.minimum(open_, close) * (1 - np.abs(rng.normal(0, 0.002, n)))
    t = pd.date_range("2024-01-01", periods=n, freq="h")
    return pd.DataFrame(dict(time=t, open=open_, high=high, low=low, close=close))


def add_signals(df, cfg):
    o, c = df["open"], df["close"]
    po, pc = o.shift(1), c.shift(1)
    sig = (pc < po) & (c > o) & (o <= pc) & (c >= po)
    if cfg["min_body_ratio"] > 0:
        sig &= (c - o) >= cfg["min_body_ratio"] * (po - pc)
    if cfg["use_trend_filter"]:
        sig &= c < c.rolling(cfg["sma_period"]).mean()
    df = df.copy()
    df["signal"] = sig.fillna(False)
    df["pattern_low"] = np.minimum(df["low"], df["low"].shift(1))
    return df


def backtest(df, cfg=CONFIG):
    df = add_signals(df, cfg)
    equity = cfg["start_equity"]
    cost = cfg["fee_pct"] + cfg["slippage_pct"]
    trades, curve = [], []
    i, n = 1, len(df)
    while i < n - 1:
        curve.append(equity)
        if not df["signal"].iat[i]:
            i += 1
            continue

        entry_bar = i + 1
        entry = df["open"].iat[entry_bar] * (1 + cfg["slippage_pct"])
        stop = df["pattern_low"].iat[i] * (1 - cfg["stop_buffer_pct"])
        risk_per_unit = entry - stop
        if risk_per_unit <= 0:
            i += 1
            continue
        target = entry + cfg["rr"] * risk_per_unit

        units = equity * cfg["risk_per_trade"] / risk_per_unit
        units = min(units, equity / entry)  # no leverage
        entry_fee = units * entry * cfg["fee_pct"]

        exit_price, exit_bar, reason = None, None, None
        for j in range(entry_bar, n):
            lo, hi = df["low"].iat[j], df["high"].iat[j]
            if lo <= stop:                 # stop checked first = conservative
                exit_price, exit_bar, reason = stop * (1 - cfg["slippage_pct"]), j, "SL"
                break
            if hi >= target:
                exit_price, exit_bar, reason = target * (1 - cfg["slippage_pct"]), j, "TP"
                break
        if exit_price is None:             # close at last bar
            exit_bar, exit_price, reason = n - 1, df["close"].iat[n - 1], "EOD"

        exit_fee = units * exit_price * cfg["fee_pct"]
        pnl = units * (exit_price - entry) - entry_fee - exit_fee
        equity += pnl
        trades.append(dict(
            entry_time=df["time"].iat[entry_bar], exit_time=df["time"].iat[exit_bar],
            entry=entry, stop=stop, target=target, exit=exit_price,
            reason=reason, pnl=pnl, equity=equity,
        ))
        i = exit_bar + 1                   # one position at a time

    return pd.DataFrame(trades), pd.Series(curve or [cfg["start_equity"]])


def report(trades, curve, cfg=CONFIG):
    if trades.empty:
        print("No trades taken.")
        return
    wins = trades[trades.pnl > 0]
    losses = trades[trades.pnl <= 0]
    pf = wins.pnl.sum() / abs(losses.pnl.sum()) if len(losses) and losses.pnl.sum() != 0 else float("inf")
    dd = ((curve.cummax() - curve) / curve.cummax()).max()
    print("=" * 40)
    print(f"Trades        : {len(trades)}")
    print(f"Win rate      : {len(wins) / len(trades):.1%}")
    print(f"Profit factor : {pf:.2f}")
    print(f"Avg win/loss  : {wins.pnl.mean() if len(wins) else 0:.2f} / {losses.pnl.mean() if len(losses) else 0:.2f}")
    print(f"Net return    : {trades.equity.iat[-1] / cfg['start_equity'] - 1:.2%}")
    print(f"Max drawdown  : {dd:.2%}")
    print(f"Exits         : {trades.reason.value_counts().to_dict()}")
    print("=" * 40)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv")
    ap.add_argument("--demo", action="store_true")
    a = ap.parse_args()
    data = load_csv(a.csv) if a.csv else demo_data()
    if not a.csv:
        print("(using synthetic demo data - NOT real market results)")
    t, eq = backtest(data)
    report(t, eq)
    t.to_csv("trades.csv", index=False)
