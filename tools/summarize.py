#!/usr/bin/env python3
"""Summarise an MT5 Strategy Tester report (.htm or stripped .txt) in plain numbers.
Usage: summarize.py report.htm [display_divisor]
For cent accounts (USC) the divisor is 100 so amounts show in USD."""
import re, sys

def load(path):
    raw = open(path, "rb").read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff") or raw[:200].count(b"\x00") > 20:
        t = raw.decode("utf-16", errors="replace")
    else:
        t = raw.decode("utf-8", errors="replace")
    t = re.sub(r"<[^>]*>", " ", t).replace("&nbsp;", " ")
    return re.sub(r"\s+", " ", t)

def num(t, label, pct=False):
    m = re.search(re.escape(label) + r"\s*(-?\d[\d ]*\.?\d*)\s*(?:\(([\d.]+)%\))?", t)
    if not m: return None
    v = float(m.group(1).replace(" ", ""))
    return (v, float(m.group(2))) if pct and m.group(2) else v

def main():
    path = sys.argv[1]
    div = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    t = load(path)
    cur = re.search(r"Currency: (\w+)", t)
    cur = cur.group(1) if cur else "?"
    if cur == "USC" and len(sys.argv) <= 2: div = 100.0
    unit = "USD" if div != 1.0 or cur == "USD" else cur
    dep = num(t, "Initial Deposit:") or 0
    net = num(t, "Total Net Profit:") or 0
    gp = num(t, "Gross Profit:") or 0
    gl = num(t, "Gross Loss:") or 0
    pf = num(t, "Profit Factor:")
    trades = num(t, "Total Trades:") or 0
    wins = re.search(r"Profit Trades \(% of total\): (\d+) \(([\d.]+)%\)", t)
    losses = re.search(r"Loss Trades \(% of total\): (\d+)", t)
    dd = re.search(r"Equity Drawdown Maximal: (-?[\d ]+\.\d+) \(([\d.]+)%\)", t)
    avgw = num(t, "Average profit trade:")
    avgl = num(t, "Average loss trade:")
    mcl = re.search(r"Maximum consecutive losses \(\$\): (\d+)", t)
    per = re.search(r"Period: (\w+) \(([\d. -]+)\)", t)
    f = lambda x: f"{x/div:,.2f}"
    lines = [
        f"Period        : {per.group(2) if per else '?'} ({per.group(1) if per else '?'})",
        f"Start balance : {f(dep)} {unit}",
        f"End balance   : {f(dep+net)} {unit}",
        f"Net profit    : {f(net)} {unit}  ({net/dep*100:+.1f}%)" if dep else f"Net profit: {f(net)}",
        f"Trades        : {int(trades)}",
        f"Win rate      : {wins.group(2)}%  ({wins.group(1)} wins / {losses.group(1) if losses else '?'} losses)" if wins else "Win rate: ?",
        f"Profit factor : {pf}",
        f"Avg win / loss: {f(avgw or 0)} / {f(avgl or 0)} {unit}",
        f"Max drawdown  : {dd.group(2)}%  ({f(float(dd.group(1).replace(' ','')))} {unit})" if dd else "Max drawdown: ?",
        f"Max losing run: {mcl.group(1)} trades" if mcl else "",
    ]
    print("\n".join(l for l in lines if l))

main()
