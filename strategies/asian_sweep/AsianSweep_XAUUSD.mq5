//+------------------------------------------------------------------+
//|  AsianSweep_XAUUSD.mq5 (v1) -- run on M5                         |
//|  London sweep of the Asian range, then reversal.                 |
//|  Asian range = high/low of bars in [AsiaStartH, AsiaEndH) server |
//|  time. During [AsiaEndH, TradeEndH): if price sweeps one side    |
//|  of the range and then closes back inside (mode 0) or breaks the |
//|  last swing against the sweep (mode 1), trade toward the other   |
//|  side. Sells are the mirror of buys (prices negated).            |
//|  Stop beyond the sweep extreme. TP: RR (0) or opposite range (1).|
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Sessions (broker server time)"
input int    InpAsiaStartH   = 0;
input int    InpAsiaEndH     = 7;
input int    InpTradeEndH    = 12;
input group "Setup"
input int    InpEntryMode    = 0;      // 0 = close back inside range, 1 = break of last swing
input int    InpTpMode       = 0;      // 0 = RR, 1 = opposite side of Asian range
input int    InpSwingN       = 2;
input double InpMinRange     = 4.0;    // USD
input double InpMaxRange     = 60.0;   // USD
input group "Risk"
input double InpRiskPercent  = 1.0;
input double InpRR           = 2.0;
input double InpStopBuffer   = 0.10;
input double InpMinStop      = 0.80;
input double InpMaxStop      = 30.0;
input double InpMaxSpread    = 0.60;
input bool   InpAllowLong    = true;
input bool   InpAllowShort   = true;
input ulong  InpMagic        = 20261101;
input int    InpDeviation    = 30;

struct SBar { datetime t; double o, h, l, c; };
CTrade trade;
datetime lastBar = 0;
int lastTradeKey = 0;
long cCalls=0, cRange=0, cSwept=0, cTrig=0, cEntry=0;

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
   PrintFormat("FUNNEL calls=%d rangeOk=%d swept=%d trigger=%d entries=%d", (int)cCalls,(int)cRange,(int)cSwept,(int)cTrig,(int)cEntry);
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
   SBar m5[];
   int n = LoadBars(PERIOD_M5, 400, dir, m5);
   if(n < 300) return false;
   int key = DayKey(m5[1].t);
   int h1 = HourOf(m5[1].t);
   if(h1 < InpAsiaEndH || h1 >= InpTradeEndH) return false;
   if(lastTradeKey == key) return false;

   double aHi = -DBL_MAX, aLo = DBL_MAX;
   int cntA = 0, firstPost = -1;
   for(int i = n - 1; i >= 1; i--)
   {
      if(DayKey(m5[i].t) != key) continue;
      int hr = HourOf(m5[i].t);
      if(hr >= InpAsiaStartH && hr < InpAsiaEndH)
      { aHi = MathMax(aHi, m5[i].h); aLo = MathMin(aLo, m5[i].l); cntA++; }
      else if(hr >= InpAsiaEndH && hr < InpTradeEndH && firstPost < 0) firstPost = i;
   }
   if(cntA < 20 || firstPost < 0) return false;
   double range = aHi - aLo;
   if(range < InpMinRange || range > InpMaxRange) return false;
   cRange++;

   double level = aLo;                 // mirrored space: sweep of the low
   bool swept = false;
   double extreme = DBL_MAX, swingLvl = 0;
   int sweepIdx = -1, trig = -1;
   for(int i2 = firstPost; i2 >= 1; i2--)
   {
      if(!swept)
      {
         if(m5[i2].l < level)
         {
            swept = true; extreme = m5[i2].l; sweepIdx = i2;
            swingLvl = -DBL_MAX;
            for(int s = sweepIdx + 1; s <= sweepIdx + 30 && s < n; s++)
               if(IsSwingHigh(m5, s, n)) { swingLvl = m5[s].h; break; }
         }
      }
      else extreme = MathMin(extreme, m5[i2].l);

      if(swept)
      {
         if(InpEntryMode == 0) { if(m5[i2].c > level) { trig = i2; break; } }
         else if(swingLvl > -DBL_MAX) { if(m5[i2].c > swingLvl && m5[i2].c > level) { trig = i2; break; } }
      }
   }
   if(swept) cSwept++;
   if(trig != 1) return false;
   cTrig++;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((ask - bid) > InpMaxSpread) return false;
   double e = (dir > 0) ? ask : -bid;
   double sl = extreme - InpStopBuffer;
   double dist = e - sl;
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return false;
   double tp = (InpTpMode == 0) ? e + InpRR * dist : aHi;
   if(tp < e + dist) return false;
   double lots = CalcLots(dist);
   if(lots <= 0) return false;
   double slR = NormalizeDouble(dir * sl, _Digits), tpR = NormalizeDouble(dir * tp, _Digits);
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, slR, tpR, "AsiaSweep")
                       : trade.Sell(lots, _Symbol, 0.0, slR, tpR, "AsiaSweep");
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
