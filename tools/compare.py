#!/usr/bin/env python3
"""Compare several tester reports. Usage: compare.py out.html label=report.htm [label=report.htm ...]"""
import sys, html, os
sys.path.insert(0, os.path.dirname(__file__))
from summarize import stats

rows = []
for a in sys.argv[2:]:
    label, path = a.split("=", 1)
    if os.path.exists(path):
        rows.append((label, stats(path)))
if not rows:
    sys.exit("no reports to compare")
cand = [r for r in rows if r[1]["ret"] > 0 and r[1]["dd"] < 40]
best = max(cand, key=lambda r: r[1]["ret"])[0] if cand else None

print(f"{'variant':<12}{'trades':>7}{'win%':>7}{'PF':>6}{'net%':>8}{'maxDD%':>8}")
for l, s in rows:
    print(f"{l:<12}{s['trades']:>7}{s['wr']:>7.1f}{s['pf']:>6.2f}{s['ret']:>8.1f}{s['dd']:>8.1f}" + ("  <- best" if l == best else ""))

def cls(v, good, bad, higher=True):
    if higher: return "good" if v >= good else ("bad" if v < bad else "")
    return "good" if v <= good else ("bad" if v > bad else "")

body = "".join(
    f"<tr{' class=best' if l == best else ''}><td>{html.escape(l)}</td><td>{s['trades']}</td>"
    f"<td class='{cls(s['wr'],40,33)}'>{s['wr']:.1f}%</td><td class='{cls(s['pf'],1.3,1.0)}'>{s['pf']:.2f}</td>"
    f"<td class='{cls(s['ret'],20,0)}'>{s['ret']:+.1f}%</td><td class='{cls(s['dd'],20,30,False)}'>{s['dd']:.1f}%</td></tr>"
    for l, s in rows)
open(sys.argv[1], "w", encoding="utf-8").write(f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Variant comparison</title><style>
:root{{--bg:#f6f7f9;--panel:#fff;--text:#14171c;--muted:#68707d;--line:#e3e6eb;--up:#1a9a63;--down:#d6455a}}
@media (prefers-color-scheme:dark){{:root{{--bg:#0f1115;--panel:#171a21;--text:#e8eaee;--muted:#8d95a3;--line:#262b35;--up:#34c28a;--down:#ff6b7f}}}}
body{{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 -apple-system,Segoe UI,sans-serif}}
main{{max-width:900px;margin:0 auto;padding:24px 16px}}h1{{font-size:22px}}
table{{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}}
th,td{{padding:10px 12px;text-align:right;border-bottom:1px solid var(--line)}}th:first-child,td:first-child{{text-align:left}}
th{{font-size:12px;text-transform:uppercase;color:var(--muted);letter-spacing:.04em}}
.good{{color:var(--up);font-weight:600}}.bad{{color:var(--down);font-weight:600}}tr.best td:first-child{{font-weight:700}}
p{{color:var(--muted);font-size:13px}}</style></head><body><main><h1>Variant comparison</h1>
<table><tr><th>Variant</th><th>Trades</th><th>Win rate</th><th>Profit factor</th><th>Net return</th><th>Max drawdown</th></tr>{body}</table>
<p>Bold name = best return with drawdown under 40%. Green/red follow the thresholds from the checklist. More confirmations means fewer trades, so check the trade count too.</p>
</main></body></html>""")
