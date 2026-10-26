#!/usr/bin/env python3
"""Append one backtest result to results.csv. Usage: log_result.py report.htm strategy variant csv_path"""
import sys, os, csv, re, datetime
sys.path.insert(0, os.path.dirname(__file__))
from summarize import stats, load

rep, strat, var, out = sys.argv[1:5]
t = load(rep)
s = stats(rep)
inputs = re.search(r"Inputs: (.*?) Company:", t)
inputs = re.sub(r"\s+", " ", inputs.group(1)).strip() if inputs else ""
per = re.search(r"Period: (\w+) \(([\d. -]+)\)", t)
symbol = (re.search(r"Symbol: (\S+)", t) or [None, "?"])[1]
model = ""
checks = [s["trades"] >= 200, s["ret"] > 0, s["pf"] >= 1.3, s["dd"] <= 25]
row = dict(time=datetime.datetime.now().strftime("%Y-%m-%d %H:%M"), strategy=strat, variant=var, symbol=symbol,
           tf=per.group(1) if per else "", period=per.group(2).strip() if per else "", trades=s["trades"],
           win_rate=s["wr"], profit_factor=s["pf"], return_pct=round(s["ret"], 1), max_dd_pct=round(s["dd"], 1),
           score=sum(checks), inputs=inputs)
new = not os.path.exists(out)
with open(out, "a", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(row))
    if new: w.writeheader()
    w.writerow(row)
