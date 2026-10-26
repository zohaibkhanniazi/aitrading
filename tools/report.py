#!/usr/bin/env python3
"""Build the leaderboard/final report from results.csv. Usage: report.py results.csv out.html"""
import sys, csv, html
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1])))
# keep the latest row per (strategy, variant, period)
latest = {}
for r in rows:
    latest[(r["strategy"], r["variant"], r["period"])] = r
rows = list(latest.values())
for r in rows:
    for k in ("trades", "score"): r[k] = int(float(r[k]))
    for k in ("win_rate", "profit_factor", "return_pct", "max_dd_pct"): r[k] = float(r[k])

# robustness: same strategy+inputs (ignoring period) tested in 2+ periods
groups = defaultdict(list)
for r in rows:
    groups[(r["strategy"], r["inputs"])].append(r)
robust = []
for (strat, inp), rs in groups.items():
    periods = {r["period"] for r in rs}
    if len(periods) >= 2:
        ok = all(r["profit_factor"] > 1.0 and r["return_pct"] > 0 for r in rs)
        avg_pf = sum(r["profit_factor"] for r in rs) / len(rs)
        worst_dd = max(r["max_dd_pct"] for r in rs)
        robust.append((ok, avg_pf, worst_dd, strat, rs[0]["variant"], len(periods), inp))
robust.sort(key=lambda x: (not x[0], -x[1]))

def cls(v, g, b, hi=True):
    return "good" if (v >= g if hi else v <= g) else ("bad" if (v < b if hi else v > b) else "")

lb = sorted(rows, key=lambda r: (-r["score"], -r["profit_factor"]))
lb_html = "".join(
    f"<tr><td>{html.escape(r['strategy'])}</td><td>{html.escape(r['variant'])}</td><td>{html.escape(r['period'])}</td>"
    f"<td>{r['trades']}</td><td class='{cls(r['win_rate'],40,33)}'>{r['win_rate']:.1f}%</td>"
    f"<td class='{cls(r['profit_factor'],1.3,1.0)}'>{r['profit_factor']:.2f}</td><td class='{cls(r['return_pct'],20,0)}'>{r['return_pct']:+.1f}%</td>"
    f"<td class='{cls(r['max_dd_pct'],20,30,False)}'>{r['max_dd_pct']:.1f}%</td><td>{r['score']}/4</td></tr>" for r in lb)
rb_html = "".join(
    f"<tr><td>{'PASS' if ok else 'fail'}</td><td>{html.escape(s)}</td><td>{html.escape(v)}</td><td>{n}</td><td>{pf:.2f}</td><td>{dd:.1f}%</td></tr>"
    for ok, pf, dd, s, v, n, inp in robust) or "<tr><td colspan=6>No setting has been tested on 2+ periods yet.</td></tr>"
open(sys.argv[2], "w", encoding="utf-8").write(f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Strategy report</title><style>
:root{{--bg:#f6f7f9;--panel:#fff;--text:#14171c;--muted:#68707d;--line:#e3e6eb;--up:#1a9a63;--down:#d6455a}}
@media (prefers-color-scheme:dark){{:root{{--bg:#0f1115;--panel:#171a21;--text:#e8eaee;--muted:#8d95a3;--line:#262b35;--up:#34c28a;--down:#ff6b7f}}}}
body{{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,Segoe UI,sans-serif}}main{{max-width:1050px;margin:0 auto;padding:24px 16px}}
h1{{font-size:22px}}h2{{font-size:16px;margin-top:28px}}table{{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);overflow:hidden;border-radius:12px}}
th,td{{padding:8px 10px;text-align:right;border-bottom:1px solid var(--line)}}th:nth-child(-n+3),td:nth-child(-n+3){{text-align:left}}
th{{font-size:11px;text-transform:uppercase;color:var(--muted)}}.good{{color:var(--up);font-weight:600}}.bad{{color:var(--down);font-weight:600}}p{{color:var(--muted)}}</style></head><body><main>
<h1>Strategy report</h1><p>{len(rows)} backtests logged. Score = checks passed of 4: 200+ trades, positive return, profit factor 1.3+, drawdown 25% or less.</p>
<h2>Robustness: same settings tested on several periods</h2>
<table><tr><th>Result</th><th>Strategy</th><th>Variant</th><th>Periods</th><th>Avg PF</th><th>Worst DD</th></tr>{rb_html}</table>
<h2>Leaderboard (all runs)</h2>
<table><tr><th>Strategy</th><th>Variant</th><th>Period</th><th>Trades</th><th>Win</th><th>PF</th><th>Return</th><th>Max DD</th><th>Score</th></tr>{lb_html}</table>
<p>Backtests only. A strong result does not guarantee future profit; confirm with real-tick tests and a demo forward test.</p></main></body></html>""")
print("Report:", sys.argv[2], f"({len(rows)} runs)")
