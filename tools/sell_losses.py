#!/usr/bin/env python3
"""Sell Setup: every signal of one tester run with its 1H setup, its 3m/5m chain and 1R-4R results.
All times in Pakistan time (server time + 5 h).
Usage: sell_losses.py <tester raw log> <M3|M5> <output prefix>
Writes <prefix>_signals.csv (every signal) and <prefix>_2R_losses.csv, prints the latest 2R losses."""
import csv, re, sys, datetime as dt

log, tf, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(log, 'rb').read()
t = raw.decode('utf-16', 'replace') if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else raw.decode('utf-8', 'replace')
lines = [l for l in t.splitlines() if re.search(r'\(XAUUSD[a-z]?,' + tf + r'\)', l)]
start = max((i for i, l in enumerate(lines) if 'SellSetup started' in l), default=0)
lines = lines[start:]


def pkt(s):
    if not s or s == '-' or s.startswith('1970'):
        return ''
    return (dt.datetime.strptime(s, '%Y.%m.%d %H:%M') + dt.timedelta(hours=5)).strftime('%Y-%m-%d %H:%M')


T = r'(\d{4}\.\d\d\.\d\d \d\d:\d\d)'
sig = re.compile(r'SIG ' + T + r' entry ([\d.]+) SL ([\d.]+) stop ([\d.]+) spread ([\d.]+) \| BC ' + T +
                 r' level ([\d.]+) \| CC ' + T + r' \| NCC ' + T + r' \| liquidity ([\d.]+) \| NCCLT ' + T +
                 r' low ([\d.]+)(?: \| R ' + T + r' low ([\d.]+) \| PB ' + T +
                 r' \| shifts (\d+) last (\S+(?: \d\d:\d\d)?) \| setups (\d+))?')
res = re.compile(r'RES ' + T + r' entry ([\d.]+) SL ([\d.]+)(.*)$')
S, Rz = {}, {}
for l in lines:
    m = sig.search(l)
    if m:
        S.setdefault(m.group(1), []).append(m.groups())
        continue
    m = res.search(l)
    if m:
        Rz.setdefault(m.group(1), []).append(re.findall(r'(\d)R (WIN|LOSS) ' + T, m.group(4)))

head = ['R candle (1H)', 'R low', 'Pullback candle (1H)', 'Level shifts', 'Last shift (1H)', 'BC candle (1H)',
        'Breaker level at BC', 'Setups closed below', 'CC', 'NCC', 'Liquidity', 'NCCLT', 'NCCLT low',
        'SELL candle', 'Entry', 'SL (NCCLT high)', 'Stop', 'TP 2R', '1R', '2R', '3R', '4R', '2R closed']
rows = []
for k in sorted(S):
    for i, g in enumerate(S[k]):
        r = Rz.get(k, [])
        r = r[i] if i < len(r) else []
        rr = {p[0]: (p[1], pkt(p[2])) for p in r}
        e, sl = float(g[1]), float(g[2])
        rows.append([pkt(g[12]) if g[12] else '', g[13] or '', pkt(g[14]) if g[14] else '', g[15] or '',
                     pkt(g[16]) if g[16] else '', pkt(g[5]), g[6], g[17] or '', pkt(g[7]), pkt(g[8]), g[9],
                     pkt(g[10]), g[11], pkt(g[0]), g[1], g[2], g[3], f'{e - 2 * (sl - e):.2f}'] +
                    [rr.get(str(n), ('open', ''))[0] for n in (1, 2, 3, 4)] + [rr.get('2', ('', ''))[1]])
with open(prefix + '_signals.csv', 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(head)
    w.writerows(rows)
loss = [r for r in rows if r[19] == 'LOSS']
with open(prefix + '_2R_losses.csv', 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(head)
    w.writerows(loss)
win = sum(1 for r in rows if r[19] == 'WIN')
print(f'{tf}: {len(rows)} signals, 2R: {win} wins / {len(loss)} losses (chart prices, Pakistan time)')
print('Latest 2R losses:  R candle | pullback | BC candle (level) | NCCLT | SELL entry / SL | stopped')
for r in loss[-15:]:
    print(f'  R {r[0]} | PB {r[2]} | BC {r[5]} ({r[6]}) | NCCLT {r[11]} | SELL {r[13]} {r[14]} / {r[15]} | {r[22]}')
print('Saved:', prefix + '_signals.csv', 'and', prefix + '_2R_losses.csv')
