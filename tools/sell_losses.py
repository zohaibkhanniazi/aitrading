#!/usr/bin/env python3
"""Sell Setup: every signal of one tester run with its chain and 1R-4R results, times in Pakistan time.
Usage: sell_losses.py <tester raw log> <M3|M5> <output prefix>
Writes <prefix>_signals.csv (every signal) and <prefix>_2R_losses.csv, prints the latest 2R losses."""
import csv, re, sys, datetime as dt

log, tf, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(log, 'rb').read()
t = raw.decode('utf-16', 'replace') if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else raw.decode('utf-8', 'replace')
lines = [l for l in t.splitlines() if f'(XAUUSDm,{tf})' in l or f'(XAUUSDc,{tf})' in l or f'(XAUUSD,{tf})' in l]
start = max((i for i, l in enumerate(lines) if 'SellSetup started' in l), default=0)
lines = lines[start:]

def pkt(s):
    return (dt.datetime.strptime(s, '%Y.%m.%d %H:%M') + dt.timedelta(hours=5)).strftime('%Y-%m-%d %H:%M')

T = r'(\d{4}\.\d\d\.\d\d \d\d:\d\d)'
sig = re.compile(r'SIG ' + T + r' entry ([\d.]+) SL ([\d.]+) stop ([\d.]+) spread ([\d.]+) \| BC ' + T +
                 r' level ([\d.]+) \| CC ' + T + r' \| NCC ' + T + r' \| liquidity ([\d.]+) \| NCCLT ' + T + r' low ([\d.]+)')
res = re.compile(r'RES ' + T + r' entry ([\d.]+) SL ([\d.]+)(.*)$')
S, Rz = {}, {}
for l in lines:
    m = sig.search(l)
    if m:
        S.setdefault(m.group(1), []).append(m.groups())
        continue
    m = res.search(l)
    if m:
        parts = re.findall(r'(\d)R (WIN|LOSS) ' + T, m.group(4))
        Rz.setdefault(m.group(1), []).append(parts)

head = ['SELL candle', 'Entry', 'SL (NCCLT high)', 'Stop size', 'BC hour', 'Breaker level', 'CC', 'NCC',
        'Liquidity', 'NCCLT', 'NCCLT low'] + [f'{k}R' for k in (1, 2, 3, 4)] + [f'{k}R closed' for k in (1, 2, 3, 4)]
rows = []
for k in sorted(S):
    for i, g in enumerate(S[k]):
        r = Rz.get(k, [])
        r = r[i] if i < len(r) else []
        rr = {p[0]: (p[1], pkt(p[2])) for p in r}
        rows.append([pkt(g[0]), g[1], g[2], g[3], pkt(g[5]), g[6], pkt(g[7]), pkt(g[8]), g[9], pkt(g[10]), g[11]] +
                    [rr.get(str(n), ('open', ''))[0] for n in (1, 2, 3, 4)] + [rr.get(str(n), ('', ''))[1] for n in (1, 2, 3, 4)])
with open(prefix + '_signals.csv', 'w', newline='') as f:
    w = csv.writer(f); w.writerow(head); w.writerows(rows)
loss = [r for r in rows if r[12] == 'LOSS']
with open(prefix + '_2R_losses.csv', 'w', newline='') as f:
    w = csv.writer(f); w.writerow(head); w.writerows(loss)
win = sum(1 for r in rows if r[12] == 'WIN')
print(f'{tf}: {len(rows)} signals, 2R: {win} wins / {len(loss)} losses (chart prices, Pakistan time)')
print('Latest 2R losses:  SELL candle | entry | SL | NCCLT | stopped')
for r in loss[-15:]:
    print(f'  {r[0]} | {r[1]} | {r[2]} | NCCLT {r[9]} | stopped {r[16]}')
print('Saved:', prefix + '_signals.csv', 'and', prefix + '_2R_losses.csv')
