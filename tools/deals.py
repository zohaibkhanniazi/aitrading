"""List every deal of an MT5 tester report with New York and Pakistan times.
Usage: python3 tools/deals.py report.htm [YYYY.MM.DD]"""
import sys, re, datetime as dt
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dashboard as D
t = D.load(sys.argv[1])
rows = list(D.ROW.finditer(t))
def ny(ts):
    u = dt.datetime.strptime(ts, "%Y.%m.%d %H:%M:%S")
    # US DST 2026: Mar 8 - Nov 1
    off = -4 if dt.datetime(2026,3,8,7) <= u < dt.datetime(2026,11,1,6) else -5
    return u + dt.timedelta(hours=off), u + dt.timedelta(hours=5)
since = sys.argv[2] if len(sys.argv) > 2 else "0"
for m in rows:
    time, _, sym, typ, d, vol, price, order, comm, swap, profit, bal, cmt = m.groups()
    if time[:10] < since: continue
    n, p = ny(time)
    print(f"{time}  NY {n:%a %H:%M}  PKT {p:%a %d %H:%M}  {typ:5} {d:4} vol {vol:>5} @ {price:>10}  profit {profit:>10}  {cmt}")
