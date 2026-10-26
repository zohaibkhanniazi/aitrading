//+------------------------------------------------------------------+
//|  PdRaid_XAUUSD.mq5 (v1) -- run on M5                             |
//|  Previous-day high/low raid + market structure shift (MSS).      |
//|  Long: price trades below yesterday's low (raid), then M5 closes |
//|  above the last swing high before the raid low (MSS).            |
//|  Entry: at the MSS close (EntryFib = 0) or on the retrace into   |
//|  EntryFib of the leg (0.5 / 0.62 / 0.705 / 0.79 = OTE zone).     |
//|  Stop below the raid low. TP: RR (0) or yesterday's other        |
//|  extreme (1). Sells = mirror (prices negated).                   |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Time (broker server hours)"
input int    InpTradeStartH  = 7;
input int    InpTradeEndH    = 17;
input group "Setup"
input double InpEntryFib     = 0.0;    // 0 = enter at MSS, else retrace fraction of the leg
input int    InpTpMode       = 0;      // 0 = RR, 1 = other side of yesterday's range
input int    InpSwingN       = 2;
input int    InpMaxBarsSinceLow = 90;  // raid low must be this recent (M5 bars)
input group "Risk"
input double InpRiskPercent  = 1.0;
input double InpRR           = 2.0;
input double InpStopBuffer   = 0.10;
input double InpMinStop      = 0.80;
input double InpMaxStop      = 30.0;
input double InpMaxSpread    = 0.60;
input bool   InpAllowLong    = true;
input bool   InpAllowShort   = true;
input ulong  InpMagic        = 20261103;
input int    InpDeviation    = 30;

struct SBar { datetime t; double o, h, l, c; };
CTrade trade;
datetime lastBar = 0;
int lastTradeKey = 0;
long cCalls=0, cInWin=0, cSweep=0, cMss=0, cTouch=0, cEntry=0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   if(_Period != PERIOD_M5) Print("WARNING: designed for M5");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   PrintFormat("FUNNEL calls=%d inWindow=%d raid=%d mss=%d touch=%d entries=%d", (int)cCalls,(int)cInWin,(int)cSweep,(int)cMss,(int)cTouch,(int)cEntry);
}

int LoadBars(const ENUM_TIMEFRAMES tf, const int count, const int dir, SBar &out[])
{
   MqlRates r[]; ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, tf, 0, count, r);
   if(n <= 0) return 0;
   ArrayResize(out, n);
   for(int i = 0; i < n; i++)
   {
      out[i].t = r[i].time;
      if(dir > 0) { out[i].o=r[i].open; out[i].c=r[i].close; out[i].h=r[i].high; out[i].l=r[i].low; }
      else        { out[i].o=-r[i].open; out[i].c=-r[i].close; out[i].h=-r[i].low; out[i].l=-r[i].high; }
   }
   return n;
}
int DayKey(const datetime t) { MqlDateTime d; TimeToStruct(t, d); return d.year * 1000 + d.day_of_year; }
int HourOf(const datetime t) { MqlDateTime d; TimeToStruct(t, d); return d.hour; }
bool IsSwingHigh(const SBar &b[], const int s, const int n)
{
   if(s - InpSwingN < 1 || s + InpSwingN >= n) return false;
   for(int k = 1; k <= InpSwingN; k++)
      if(!(b[s].h > b[s-k].h && b[s].h > b[s+k].h)) return false;
   return true;
}
double CalcLots(const double stopDistance)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0) tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0.0;
   double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0) return 0.0;
   double lots = riskMoney / lossPerLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
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
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic) return true;
   }
   return false;
}

bool TrySetup(const int dir)
{
   cCalls++;
   int h0 = HourOf(iTime(_Symbol, PERIOD_M5, 0));
   if(h0 < InpTradeStartH || h0 >= InpTradeEndH) return false;
   cInWin++;
   double pdH = iHigh(_Symbol, PERIOD_D1, 1), pdL = iLow(_Symbol, PERIOD_D1, 1);
   if(pdH <= 0 || pdL <= 0) return false;
   double level  = (dir > 0) ? pdL : -pdH;      // mirrored space: raid of the low
   double target = (dir > 0) ? pdH : -pdL;

   SBar m5[];
   int n = LoadBars(PERIOD_M5, 400, dir, m5);
   if(n < 300) return false;
   int key = DayKey(m5[1].t);
   if(lastTradeKey == key) return false;

   bool swept = false;
   int L = -1;
   double Lval = DBL_MAX;
   for(int i = n - 1; i >= 1; i--)
   {
      if(DayKey(m5[i].t) != key) continue;
      if(!swept) { if(m5[i].l < level) { swept = true; L = i; Lval = m5[i].l; } }
      else if(m5[i].l < Lval) { Lval = m5[i].l; L = i; }
   }
   if(!swept) return false;
   cSweep++;
   if(L > InpMaxBarsSinceLow) return false;

   int sh = -1;
   for(int s = L + 1; s <= L + 30 && s < n; s++)
      if(IsSwingHigh(m5, s, n)) { sh = s; break; }
   if(sh < 0) return false;

   int c = -1;
   for(int s2 = L - 1; s2 >= 1; s2--)
      if(m5[s2].c > m5[sh].h) { c = s2; break; }
   if(c < 0) return false;
   cMss++;

   if(InpEntryFib <= 0.0)
   {
      if(c != 1) return false;
   }
   else
   {
      if(c < 2) return false;
      double legHigh = -DBL_MAX;
      for(int s3 = L - 1; s3 >= 2; s3--) legHigh = MathMax(legHigh, m5[s3].h);
      double lvl = legHigh - InpEntryFib * (legHigh - Lval);
      if(!(m5[1].l <= lvl && m5[1].c > Lval)) return false;
      for(int s4 = c - 1; s4 >= 2; s4--)
         if(m5[s4].l <= lvl) return false;            // not the first touch
   }
   cTouch++;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((ask - bid) > InpMaxSpread) return false;
   double e = (dir > 0) ? ask : -bid;
   double sl = Lval - InpStopBuffer;
   double dist = e - sl;
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return false;
   double tp = (InpTpMode == 0) ? e + InpRR * dist : target;
   if(tp < e + dist) return false;
   double lots = CalcLots(dist);
   if(lots <= 0) return false;
   double slR = NormalizeDouble(dir * sl, _Digits), tpR = NormalizeDouble(dir * tp, _Digits);
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, slR, tpR, "PdRaid")
                       : trade.Sell(lots, _Symbol, 0.0, slR, tpR, "PdRaid");
   if(ok) { cEntry++; lastTradeKey = key; }
   return ok;
}

void OnTick()
{
   datetime bt = iTime(_Symbol, PERIOD_M5, 0);
   if(bt == lastBar) return;
   lastBar = bt;
   if(HasOpenPosition()) return;
   if(InpAllowLong && TrySetup(1)) return;
   if(InpAllowShort) TrySetup(-1);
}
