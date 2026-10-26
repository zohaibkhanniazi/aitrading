#!/usr/bin/env python3
"""Build a self-contained HTML dashboard from an MT5 Strategy Tester report.
Usage: dashboard.py report.htm out.html [strategy_name]
Cent accounts (USC) are shown in USD (divided by 100). No external dependencies."""
import re, sys, html, math
from collections import defaultdict

N8 = r"-?\d{1,3}(?: \d{3})*\.\d{8}"
ROW = re.compile(
    r"(\d{4}\.\d\d\.\d\d \d\d:\d\d:\d\d) (\d+) (\w+) (buy|sell) (in|out) ([\d.]+) ([\d.]+) (\d+) "
    rf"({N8}) ({N8}) ({N8}) ({N8})(?: ((?:tp|sl|so)\b|[A-Za-z]\w*))?")


def load(path):
    raw = open(path, "rb").read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff") or raw[:200].count(b"\x00") > 20:
        t = raw.decode("utf-16", errors="replace")
    else:
        t = raw.decode("utf-8", errors="replace")
    t = re.sub(r"<[^>]*>", " ", t).replace("&nbsp;", " ")
    return re.sub(r"\s+", " ", t)


def fnum(s):
    return float(s.replace(" ", ""))


def grab(t, label):
    m = re.search(re.escape(label) + r" (-?\d[\d ]*\.?\d*)", t)
    return fnum(m.group(1)) if m else None


def parse(t):
    cur = (re.search(r"Currency: (\w+)", t) or [None, "USD"])[1]
    div = 100.0 if cur == "USC" else 1.0
    dep = grab(t, "Initial Deposit:") or 0
    trades = []
    prev_bal = dep
    for m in ROW.finditer(t):
        time, _, sym, typ, d, vol, price, order, comm, swap, profit, bal, cmt = m.groups()
        if d != "out":
            continue
        bal = fnum(bal)
        trades.append(dict(time=time, pnl=bal - prev_bal, bal=bal, reason=(cmt or "").lower()))
        prev_bal = bal
    per = re.search(r"Period: (\w+) \(([\d. -]+)\)", t)
    meta = dict(
        cur=cur, div=div, dep=dep,
        symbol=(re.search(r"Symbol: (\S+)", t) or [None, "?"])[1],
        expert=(re.search(r"Expert: (\S+)", t) or [None, "?"])[1],
        tf=per.group(1) if per else "?", period=per.group(2).strip() if per else "?",
        server=(re.search(r"Strategy Tester Report (\S+) \(Build", t) or [None, ""])[1],
        quality=(re.search(r"History Quality: (\d+)%", t) or [None, "?"])[1],
        pf=grab(t, "Profit Factor:"),
        sharpe=grab(t, "Sharpe Ratio:"),
    )
    return meta, trades


# ---------- svg helpers ----------
def nice_ticks(lo, hi, n=5):
    if hi == lo:
        hi = lo + 1
    step = (hi - lo) / n
    mag = 10 ** math.floor(math.log10(step))
    for k in (1, 2, 2.5, 5, 10):
        if step <= k * mag:
            step = k * mag
            break
    start = math.floor(lo / step) * step
    out, v = [], start
    while v <= hi + step * 0.5:
        out.append(v)
        v += step
    return out


W, H, PL, PR, PT, PB = 720, 260, 56, 14, 14, 30


def fmt_money(v):
    return f"{v:,.0f}"


def line_chart(xs, ys, kind="line", base=None, color="var(--accent)", fill=True, yfmt=fmt_money, xlabels=None):
    if not ys:
        return "<p class='muted'>No data</p>"
    lo, hi = min(ys + ([base] if base is not None else [])), max(ys + ([base] if base is not None else []))
    pad = (hi - lo) * 0.08 or 1
    lo, hi = lo - pad, hi + pad
    ticks = nice_ticks(lo, hi)
    lo, hi = min(lo, ticks[0]), max(hi, ticks[-1])
    x0, x1 = PL, W - PR
    y0, y1 = H - PB, PT
    sx = lambda i: x0 + (x1 - x0) * (i / max(len(ys) - 1, 1))
    sy = lambda v: y0 + (y1 - y0) * ((v - lo) / (hi - lo))
    g = []
    for tv in ticks:
        y = sy(tv)
        g.append(f"<line x1='{x0}' x2='{x1}' y1='{y:.1f}' y2='{y:.1f}' class='grid'/>"
                 f"<text x='{x0-6}' y='{y+4:.1f}' text-anchor='end' class='ax'>{yfmt(tv)}</text>")
    pts = " ".join(f"{sx(i):.1f},{sy(v):.1f}" for i, v in enumerate(ys))
    if base is not None:
        by = sy(base)
        g.append(f"<line x1='{x0}' x2='{x1}' y1='{by:.1f}' y2='{by:.1f}' class='base'/>")
    if fill:
        ref = sy(base if base is not None else lo)
        g.append(f"<polygon points='{x0},{ref:.1f} {pts} {x1},{ref:.1f}' fill='{color}' opacity='0.12'/>")
    g.append(f"<polyline points='{pts}' fill='none' stroke='{color}' stroke-width='1.8' stroke-linejoin='round'/>")
    if xlabels:
        for i, lab in xlabels:
            g.append(f"<text x='{sx(i):.1f}' y='{H-10}' text-anchor='middle' class='ax'>{html.escape(lab)}</text>")
    return f"<svg viewBox='0 0 {W} {H}' role='img'>{''.join(g)}</svg>"


def bar_chart(labels, vals, signed=True, yfmt=fmt_money, colors=None):
    if not vals:
        return "<p class='muted'>No data</p>"
    lo, hi = min(0, min(vals)), max(0, max(vals))
    pad = (hi - lo) * 0.08 or 1
    lo, hi = (lo - pad if lo < 0 else 0), hi + pad
    ticks = nice_ticks(lo, hi)
    lo, hi = min(lo, ticks[0]), max(hi, ticks[-1])
    x0, x1, y0, y1 = PL, W - PR, H - PB, PT
    sy = lambda v: y0 + (y1 - y0) * ((v - lo) / (hi - lo))
    n = len(vals)
    bw = (x1 - x0) / n
    g = []
    for tv in ticks:
        y = sy(tv)
        g.append(f"<line x1='{x0}' x2='{x1}' y1='{y:.1f}' y2='{y:.1f}' class='grid'/>"
                 f"<text x='{x0-6}' y='{y+4:.1f}' text-anchor='end' class='ax'>{yfmt(tv)}</text>")
    zy = sy(0)
    g.append(f"<line x1='{x0}' x2='{x1}' y1='{zy:.1f}' y2='{zy:.1f}' class='base'/>")
    step = max(1, n // 12)
    for i, v in enumerate(vals):
        x = x0 + i * bw + bw * 0.15
        y = sy(max(v, 0)); h = abs(sy(v) - zy)
        c = (colors[i] if colors else ("var(--up)" if v >= 0 else "var(--down)"))
        g.append(f"<rect x='{x:.1f}' y='{y:.1f}' width='{bw*0.7:.1f}' height='{max(h,0.5):.1f}' fill='{c}' rx='1.5'>"
                 f"<title>{html.escape(str(labels[i]))}: {yfmt(v)}</title></rect>")
        if i % step == 0:
            g.append(f"<text x='{x+bw*0.35:.1f}' y='{H-10}' text-anchor='middle' class='ax'>{html.escape(str(labels[i]))}</text>")
    return f"<svg viewBox='0 0 {W} {H}' role='img'>{''.join(g)}</svg>"


def build(meta, trades, title):
    d = meta["div"]
    usd = lambda v: v / d
    n = len(trades)
    wins = [t for t in trades if t["pnl"] > 0]
    losses = [t for t in trades if t["pnl"] <= 0]
    gp = sum(t["pnl"] for t in wins); gl = -sum(t["pnl"] for t in losses)
    net = sum(t["pnl"] for t in trades)
    pf = gp / gl if gl else float("inf")
    wr = len(wins) / n * 100 if n else 0
    avgw = usd(gp / len(wins)) if wins else 0
    avgl = usd(gl / len(losses)) if losses else 0
    be_wr = (avgl / (avgw + avgl) * 100) if (avgw + avgl) else 0
    exp = usd(net / n) if n else 0
    dep = meta["dep"]
    bal = [dep] + [t["bal"] for t in trades]
    peak, dd, maxdd, maxdd_usd = dep, [], 0, 0
    for b in bal:
        peak = max(peak, b)
        ddp = (peak - b) / peak * 100 if peak else 0
        dd.append(-ddp)
        if ddp > maxdd:
            maxdd, maxdd_usd = ddp, usd(peak - b)
    streak = cur = 0
    for t in trades:
        cur = cur + 1 if t["pnl"] <= 0 else 0
        streak = max(streak, cur)
    bars = [bal[0]] + bal[1:]
    eq_usd = [usd(b) for b in bars]
    # month labels for x axis
    xl = []
    last = None
    for i, t in enumerate(trades):
        mth = t["time"][:7]
        if mth != last and (len(xl) == 0 or i - xl[-1][0] > max(n // 12, 1)):
            xl.append((i + 1, mth[2:].replace(".", "/")))
        last = mth
    equity_svg = line_chart(list(range(len(eq_usd))), eq_usd, base=usd(dep), xlabels=xl)
    dd_svg = line_chart(list(range(len(dd))), dd, base=0, color="var(--down)", yfmt=lambda v: f"{v:.0f}%", xlabels=xl)
    mon = defaultdict(float)
    for t in trades:
        mon[t["time"][:7]] += t["pnl"]
    mk = sorted(mon)
    month_svg = bar_chart([m[2:].replace(".", "/") for m in mk], [usd(mon[m]) for m in mk])
    hrs = defaultdict(lambda: [0, 0])
    for t in trades:
        # entry hour unknown for exit row; use exit hour as session proxy
        h = int(t["time"][11:13]); hrs[h][1] += 1
        if t["pnl"] > 0: hrs[h][0] += 1
    hk = sorted(hrs)
    hour_svg = bar_chart([f"{h:02d}" for h in hk], [hrs[h][0] / hrs[h][1] * 100 for h in hk],
                         yfmt=lambda v: f"{v:.0f}%", colors=["var(--accent)"] * len(hk))
    rs = defaultdict(int)
    for t in trades:
        rs[t["reason"] or "other"] += 1
    reason_txt = " · ".join(f"{k.upper()} {v}" for k, v in sorted(rs.items(), key=lambda x: -x[1]))
    wr_cls = "good" if wr >= be_wr else "bad"

    def card(lbl, val, sub="", cls=""):
        return (f"<div class='card'><div class='lbl'>{lbl}</div><div class='val {cls}'>{val}</div>"
                f"<div class='sub'>{sub}</div></div>")

    cards = "".join([
        card("Win rate", f"{wr:.1f}%", f"{len(wins)} wins / {len(losses)} losses · break-even {be_wr:.1f}%", wr_cls),
        card("Net profit", f"{usd(net):+,.0f} USD", f"{net/dep*100:+.1f}% on {usd(dep):,.0f}", "good" if net >= 0 else "bad"),
        card("Profit factor", f"{pf:.2f}", "gross profit / gross loss", "good" if pf >= 1.3 else ("bad" if pf < 1 else "")),
        card("Max drawdown", f"{maxdd:.1f}%", f"{maxdd_usd:,.0f} USD from peak", "bad" if maxdd > 25 else ""),
        card("Trades", f"{n}", reason_txt),
        card("Avg win / loss", f"{avgw:,.1f} / -{avgl:,.1f}", f"expectancy {exp:+.2f} USD per trade"),
        card("Longest losing run", f"{streak}", "trades in a row"),
        card("Final balance", f"{usd(bal[-1]):,.0f} USD", f"started {usd(dep):,.0f} USD"),
    ])
    sub = f"{html.escape(meta['symbol'])} · {html.escape(meta['tf'])} · {html.escape(meta['period'])} · {html.escape(meta['server'])} · history quality {meta['quality']}%"
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{html.escape(title)} results</title>
<style>
:root{{--bg:#f6f7f9;--panel:#fff;--text:#14171c;--muted:#68707d;--line:#e3e6eb;--accent:#2f6fed;--up:#1a9a63;--down:#d6455a}}
@media (prefers-color-scheme:dark){{:root{{--bg:#0f1115;--panel:#171a21;--text:#e8eaee;--muted:#8d95a3;--line:#262b35;--accent:#6b9bff;--up:#34c28a;--down:#ff6b7f}}}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}}
main{{max-width:1100px;margin:0 auto;padding:24px 16px 48px}}
h1{{font-size:22px;margin:0 0 4px}}.muted,.sub{{color:var(--muted)}}p.muted{{margin:8px 0 0}}
.grid4{{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:12px;margin:18px 0}}
.card,.panel{{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px}}
.lbl{{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}}
.val{{font-size:26px;font-weight:650;margin:4px 0 2px}}.sub{{font-size:12px}}
.good{{color:var(--up)}}.bad{{color:var(--down)}}
.charts{{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:12px}}
@media(max-width:520px){{.charts{{grid-template-columns:1fr}}}}
.panel h2{{font-size:14px;margin:0 0 8px}}svg{{width:100%;height:auto;display:block}}
.grid{{stroke:var(--line);stroke-width:1}}.base{{stroke:var(--muted);stroke-width:1;stroke-dasharray:4 3}}
.ax{{fill:var(--muted);font-size:11px}}
</style></head><body><main>
<h1>{html.escape(title)}</h1><div class="muted">{sub}</div>
<div class="grid4">{cards}</div>
<div class="charts">
<div class="panel"><h2>Balance (USD)</h2>{equity_svg}</div>
<div class="panel"><h2>Drawdown from peak</h2>{dd_svg}</div>
<div class="panel"><h2>Profit by month (USD)</h2>{month_svg}</div>
<div class="panel"><h2>Win rate by exit hour (server time)</h2>{hour_svg}</div>
</div>
<p class="muted">Backtest only. Past results do not guarantee future performance. Costs shown follow the broker's tester data.</p>
</main></body></html>"""


if __name__ == "__main__":
    src, out = sys.argv[1], sys.argv[2]
    name = sys.argv[3] if len(sys.argv) > 3 else "Strategy"
    meta, trades = parse(load(src))
    open(out, "w", encoding="utf-8").write(build(meta, trades, name))
    print(f"Dashboard: {out}  ({len(trades)} trades)")
