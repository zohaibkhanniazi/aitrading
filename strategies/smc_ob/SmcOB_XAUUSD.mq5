//+------------------------------------------------------------------+
//|  SmcOB_XAUUSD.mq5  (v1)   -- run on an M5 chart / tester M5      |
//|                                                                  |
//|  Top-down order block strategy (bullish described; bearish is    |
//|  the exact mirror, implemented by negating prices):              |
//|                                                                  |
//|  1. H1 POI : last bearish candle before a candle that closes     |
//|     above the recent H1 range high (break of structure), with a  |
//|     minimum displacement. Optional: that candle must have swept  |
//|     liquidity (new low versus the previous N H1 bars).           |
//|     Zone is dead once an H1 candle closes below it (mitigated).  |
//|  2. Refine : inside the H1 candle, take the last bearish M30     |
//|     candle, then inside that the last bearish M15 candle.        |
//|     (smaller zone -> tighter stop)                               |
//|  3. M5     : price taps the refined zone, then breaks the last   |
//|     lower high (change of character). Enter on the first pullback|
//|     into the M5 order block (last bearish candle before the      |
//|     break). Stop below the sweep low (or M5 OB low), TP = RR.    |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input group "H1 zone"
input int    InpH1Bars       = 150;    // H1 bars to scan
input int    InpStructBars   = 8;      // Bars defining the range that must be broken
input int    InpImpulseBars  = 6;      // Max bars back from break to find the OB candle
input double InpDispAtr      = 1.0;    // Min move from OB low to peak (x H1 ATR)
input bool   InpRequireLiq   = true;   // Require liquidity sweep before the OB
input int    InpLiqBars      = 10;     // Liquidity lookback (H1 bars)
input bool   InpZoneBody     = false;  // Zone = candle body only (else full range)
input bool   InpFreshOnly    = false;  // Skip zones already revisited before
input int    InpMaxZones     = 6;      // Max zones evaluated per bar
input group "Refinement"
input bool   InpUseM30       = true;   // Refine to M30 candle
input bool   InpUseM15       = true;   // Refine to M15 candle
input group "M5 entry"
input int    InpTapWindow    = 36;     // M5 bars to look back for the tap
input int    InpChochBars    = 24;     // M5 bars before the tap to find the lower high
input int    InpSwingN       = 2;      // Swing sensitivity (bars each side)
input int    InpSlMode       = 0;      // 0 = below tap/sweep low, 1 = below M5 OB low
input group "Risk"
input double InpRiskPercent  = 1.0;
input double InpRR           = 3.0;
input double InpStopBuffer   = 0.10;   // USD
input double InpMinStop      = 0.80;   // USD
input double InpMaxStop      = 20.00;  // USD
input double InpMaxSpread    = 0.60;   // USD
input bool   InpAllowLong    = true;
input bool   InpAllowShort   = true;
input bool   InpUseSession   = false;
input int    InpStartHour    = 7;
input int    InpEndHour      = 20;
input ulong  InpMagic        = 20261028;
input int    InpDeviation    = 30;

struct SBar { datetime t; double o, h, l, c; };
struct Zone { datetime t; double lo, hi, rlo, rhi; };

CTrade   trade;
int      hAtr1 = INVALID_HANDLE;
datetime lastBar = 0;
datetime lastSetup[2];

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hAtr1 = iATR(_Symbol, PERIOD_H1, 14);
   if(hAtr1 == INVALID_HANDLE) return INIT_FAILED;
   lastSetup[0] = 0;
   lastSetup[1] = 0;
   if(_Period != PERIOD_M5)
      Print("WARNING: this EA is designed for an M5 chart / M5 tester period.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hAtr1 != INVALID_HANDLE) IndicatorRelease(hAtr1);
}

//--- load bars; index = shift (0 = newest). dir<0 mirrors prices (negated)
int LoadBars(const ENUM_TIMEFRAMES tf, const int count, const int dir, SBar &out[])
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, tf, 0, count, r);
   if(n <= 0) return 0;
   ArrayResize(out, n);
   for(int i = 0; i < n; i++)
   {
      out[i].t = r[i].time;
      if(dir > 0)
      {
         out[i].o = r[i].open;  out[i].c = r[i].close;
         out[i].h = r[i].high;  out[i].l = r[i].low;
      }
      else
      {
         out[i].o = -r[i].open; out[i].c = -r[i].close;
         out[i].h = -r[i].low;  out[i].l = -r[i].high;
      }
   }
   return n;
}

//+------------------------------------------------------------------+
int FindZones(const SBar &b1[], const int n, const double atr, Zone &zs[])
{
   int cnt = 0;
   ArrayResize(zs, 0);
   int maxJ = n - InpStructBars - InpImpulseBars - InpLiqBars - 4;
   for(int j = 1; j <= maxJ && cnt < InpMaxZones; j++)
   {
      double ref = -DBL_MAX;
      for(int k = j + 1; k <= j + InpStructBars; k++) ref = MathMax(ref, b1[k].h);
      if(b1[j].c <= ref) continue;                     // no break of structure

      int ob = -1;
      for(int k2 = j + 1; k2 <= j + InpImpulseBars; k2++)
         if(b1[k2].c < b1[k2].o) { ob = k2; break; }   // last opposite candle
      if(ob < 0) continue;

      double peak = -DBL_MAX;
      for(int k3 = j; k3 <= ob; k3++) peak = MathMax(peak, b1[k3].h);
      if(peak - b1[ob].l < InpDispAtr * atr) continue; // weak impulse

      if(InpRequireLiq)
      {
         double mn = DBL_MAX;
         for(int k4 = ob + 1; k4 <= ob + InpLiqBars; k4++) mn = MathMin(mn, b1[k4].l);
         if(!(b1[ob].l < mn)) continue;                // no liquidity sweep
      }

      double lo = InpZoneBody ? b1[ob].c : b1[ob].l;
      double hi = InpZoneBody ? b1[ob].o : b1[ob].h;

      bool bad = false;
      for(int m1 = 1; m1 < ob; m1++)
         if(b1[m1].c < lo) { bad = true; break; }      // mitigated / broken
      if(bad) continue;
      if(InpFreshOnly)
      {
         for(int m2 = 2; m2 < j; m2++)
            if(b1[m2].l <= hi) { bad = true; break; }
         if(bad) continue;
      }

      bool dup = false;
      for(int q = 0; q < cnt; q++)
         if(zs[q].t == b1[ob].t) { dup = true; break; }
      if(dup) continue;

      ArrayResize(zs, cnt + 1);
      zs[cnt].t = b1[ob].t;
      zs[cnt].lo = lo;  zs[cnt].hi = hi;
      zs[cnt].rlo = lo; zs[cnt].rhi = hi;
      cnt++;
   }
   return cnt;
}

//--- last opposite (bearish in mirrored space) candle inside [t0,t1)
bool Refine(const SBar &bars[], const int n, const datetime t0, const datetime t1,
            double &lo, double &hi, datetime &tt)
{
   for(int i = 0; i < n; i++)
   {
      if(bars[i].t < t0) break;
      if(bars[i].t >= t1) continue;
      if(bars[i].c < bars[i].o)
      {
         lo = InpZoneBody ? bars[i].c : bars[i].l;
         hi = InpZoneBody ? bars[i].o : bars[i].h;
         tt = bars[i].t;
         return true;
      }
   }
   return false;
}

bool IsSwingHigh(const SBar &b[], const int s, const int n)
{
   if(s - InpSwingN < 1 || s + InpSwingN >= n) return false;
   for(int k = 1; k <= InpSwingN; k++)
      if(!(b[s].h > b[s - k].h && b[s].h > b[s + k].h)) return false;
   return true;
}

//+------------------------------------------------------------------+
double CalcLots(const double stopDistance)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0) tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0.0;
   double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0) return 0.0;
   double lots   = riskMoney / lossPerLot;
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   if(lots < minLot) return 0.0;
   if(lots > maxLot) lots = maxLot;
   return NormalizeDouble(lots, 2);
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool TryEntry(const int dir, const Zone &z, const SBar &m5[], const int n5)
{
   // 1. tap: lowest low of the recent window must reach the refined zone but not break the H1 zone
   int L = -1;
   double lowest = DBL_MAX;
   for(int s = 1; s <= InpTapWindow; s++)
   {
      if(m5[s].c < z.lo) return false;                 // closed through the zone
      if(m5[s].l < lowest) { lowest = m5[s].l; L = s; }
   }
   if(L < 0) return false;
   if(!(lowest <= z.rhi) || !(lowest > z.lo)) return false;

   // 2. last lower high before the tap low
   int sh = -1;
   for(int s2 = L + 1; s2 <= L + InpChochBars; s2++)
      if(IsSwingHigh(m5, s2, n5)) { sh = s2; break; }
   if(sh < 0) return false;

   // 3. change of character: first close above it after the tap low
   int c = -1;
   for(int s3 = L - 1; s3 >= 1; s3--)
      if(m5[s3].c > m5[sh].h) { c = s3; break; }
   if(c < 2) return false;

   // 4. M5 order block: last bearish candle before the break
   int ob = -1;
   for(int s4 = c + 1; s4 <= L; s4++)
      if(m5[s4].c < m5[s4].o) { ob = s4; break; }
   if(ob < 0) return false;
   double obHi = m5[ob].h, obLo = m5[ob].l;

   // 5. first pullback into the OB happened on the last closed bar and it held
   if(!(m5[1].l <= obHi && m5[1].c > obLo)) return false;
   for(int s5 = 2; s5 < c; s5++)
      if(m5[s5].l <= obHi) return false;

   int di = (dir > 0) ? 0 : 1;
   if(lastSetup[di] == m5[c].t) return false;
   lastSetup[di] = m5[c].t;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((ask - bid) > InpMaxSpread) return false;

   double e    = (dir > 0) ? ask : -bid;              // entry in mirrored space
   double base = (InpSlMode == 0) ? MathMin(lowest, obLo) : obLo;
   double sl   = base - InpStopBuffer;
   double dist = e - sl;
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return false;

   double lots = CalcLots(dist);
   if(lots <= 0) return false;
   double tp = e + InpRR * dist;

   double slReal = NormalizeDouble(dir * sl, _Digits);
   double tpReal = NormalizeDouble(dir * tp, _Digits);
   bool ok;
   if(dir > 0) ok = trade.Buy(lots, _Symbol, 0.0, slReal, tpReal, "SMC");
   else        ok = trade.Sell(lots, _Symbol, 0.0, slReal, tpReal, "SMC");
   return ok;
}

bool TryDir(const int dir)
{
   SBar h1[], m30[], m15[], m5[];
   int n1 = LoadBars(PERIOD_H1, InpH1Bars, dir, h1);
   int need5 = InpTapWindow + InpChochBars + 20;
   int n5 = LoadBars(PERIOD_M5, need5, dir, m5);
   if(n1 < InpH1Bars / 2 || n5 < need5 - 5) return false;

   double a[];
   ArraySetAsSeries(a, true);
   if(CopyBuffer(hAtr1, 0, 1, 1, a) != 1 || a[0] <= 0) return false;
   double atr = a[0];

   Zone zs[];
   int nz = FindZones(h1, n1, atr, zs);
   if(nz == 0) return false;

   int n30 = 0, n15 = 0;
   if(InpUseM30) n30 = LoadBars(PERIOD_M30, InpH1Bars * 2 + 10, dir, m30);
   if(InpUseM15) n15 = LoadBars(PERIOD_M15, InpH1Bars * 4 + 10, dir, m15);

   for(int zi = 0; zi < nz; zi++)
   {
      Zone z = zs[zi];
      datetime t0 = z.t, t1 = z.t + PeriodSeconds(PERIOD_H1);
      double rl, rh;
      datetime tt;
      if(InpUseM30 && n30 > 0 && Refine(m30, n30, t0, t1, rl, rh, tt))
      {
         z.rlo = rl; z.rhi = rh;
         t0 = tt; t1 = tt + PeriodSeconds(PERIOD_M30);
      }
      if(InpUseM15 && n15 > 0 && Refine(m15, n15, t0, t1, rl, rh, tt))
      {
         z.rlo = rl; z.rhi = rh;
      }
      if(TryEntry(dir, z, m5, n5)) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime bt = iTime(_Symbol, PERIOD_M5, 0);
   if(bt == lastBar) return;
   lastBar = bt;

   if(HasOpenPosition()) return;

   if(InpUseSession)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;
   }

   if(InpAllowLong && TryDir(1)) return;
   if(InpAllowShort) TryDir(-1);
}
//+------------------------------------------------------------------+
