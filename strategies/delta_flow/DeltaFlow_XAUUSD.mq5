//+------------------------------------------------------------------+
//|  DeltaFlow_XAUUSD.mq5 (v1) -- order-flow DELTA PROXY strategy     |
//|                                                                  |
//|  Delta per bar = (buy ticks - sell ticks), classified by the     |
//|  tick rule (price up = buy, price down = sell, flat = same side  |
//|  as the last move). If the feed sets BUY/SELL tick flags they    |
//|  are used instead. This is a PROXY: CFDs have no real volume.    |
//|  BACKTEST WITH Model=4 (every tick based on real ticks).        |
//|                                                                  |
//|  Delta strength dz = bar delta / std-dev of the last N deltas.   |
//|  Mode 0  absorption reversal: price makes a new N-bar low but    |
//|          buyers dominate (dz >= Z)  -> BUY (mirror for SELL)     |
//|  Mode 1  delta breakout with trend: close breaks the N-bar high  |
//|          with dz >= Z and EMA trend up -> BUY (mirror for SELL)  |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Signal"
input int    InpMode        = 0;      // 0 = absorption reversal, 1 = delta breakout + trend
input int    InpSwingN      = 10;     // bars used for the swing low/high
input int    InpZBars       = 50;     // bars used for the delta std-dev
input double InpDeltaZ      = 1.0;    // required delta strength (x std-dev)
input bool   InpNeedBodyDir = false;  // signal bar body must point the trade way
input int    InpEmaFast     = 50;
input int    InpEmaSlow     = 200;
input group "Session (server time)"
input bool   InpUseSession  = false;
input int    InpStartHour   = 13;
input int    InpEndHour     = 20;
input group "Risk"
input double InpRiskPercent = 1.0;
input double InpRR          = 2.0;
input bool   InpMoveBE      = true;
input double InpBeTriggerR  = 1.0;
input double InpStopBuffer  = 0.10;
input double InpMinStop     = 0.80;
input double InpMaxStop     = 30.0;
input double InpMaxSpread   = 0.60;
input bool   InpAllowLong   = true;
input bool   InpAllowShort  = true;
input ulong  InpMagic       = 20261140;
input int    InpDeviation   = 30;

CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE;
datetime lastBar = 0;
double   dl[];              // delta of each closed bar (oldest first)
int      cSig = 0, cTrades = 0, cBars = 0, cNoTicks = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hFast = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE) return INIT_FAILED;
   ArrayResize(dl, 0);
   Print("DeltaFlow started on ", _Symbol, " ", EnumToString(_Period), " mode ", InpMode, " (needs real ticks in the tester: Model=4)");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FUNNEL bars=%d noTicks=%d signals=%d trades=%d", cBars, cNoTicks, cSig, cTrades);
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
}

//--- delta proxy of the bar that started at time t0
bool BarDelta(const datetime t0, double &delta)
{
   MqlTick ticks[];
   ulong from = (ulong)t0 * 1000;
   ulong to   = (ulong)(t0 + PeriodSeconds(_Period)) * 1000 - 1;
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, from, to);
   if(n < 5) return false;
   double d = 0, prevMid = 0;
   int side = 0;
   for(int i = 0; i < n; i++)
   {
      double mid = (ticks[i].bid + ticks[i].ask) / 2.0;
      if((ticks[i].flags & TICK_FLAG_BUY) != 0 && (ticks[i].flags & TICK_FLAG_SELL) == 0)       side = 1;
      else if((ticks[i].flags & TICK_FLAG_SELL) != 0 && (ticks[i].flags & TICK_FLAG_BUY) == 0)  side = -1;
      else if(prevMid > 0)
      {
         if(mid > prevMid + _Point * 0.5)      side = 1;
         else if(mid < prevMid - _Point * 0.5) side = -1;
      }
      prevMid = mid;
      d += side;
   }
   delta = d;
   return true;
}

double StdDev()
{
   int n = ArraySize(dl);
   int m = MathMin(n - 1, InpZBars);        // exclude the newest (the signal bar)
   if(m < 20) return 0;
   double s = 0, s2 = 0;
   for(int i = n - 2; i > n - 2 - m; i--) { s += dl[i]; s2 += dl[i] * dl[i]; }
   double mean = s / m;
   double var = s2 / m - mean * mean;
   return (var > 0) ? MathSqrt(var) : 0;
}

double Val(const int h, const int shift)
{
   double b[];
   ArraySetAsSeries(b, true);
   return (CopyBuffer(h, 0, shift, 1, b) == 1) ? b[0] : -1;
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic) return true;
   }
   return false;
}

double CalcLots(const double stopDistance)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0 || tv <= 0) return 0.0;
   double lossPerLot = (stopDistance / ts) * tv;
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

void ManageBE()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN), sl = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
      if(tp <= 0 || InpRR <= 0) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
      {
         double r = (tp - open) / InpRR;
         if(sl < open - _Point && bid >= open + InpBeTriggerR * r) trade.PositionModify(t, NormalizeDouble(open, _Digits), tp);
      }
      else
      {
         double r = (open - tp) / InpRR;
         if(sl > open + _Point && ask <= open - InpBeTriggerR * r) trade.PositionModify(t, NormalizeDouble(open, _Digits), tp);
      }
   }
}

//--- signal on the bar that just closed (shift 1); dir +1 / -1 / 0
int Signal(const double dz)
{
   double o1 = iOpen(_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   double h1 = iHigh(_Symbol, _Period, 1), l1 = iLow(_Symbol, _Period, 1);
   double hh = -DBL_MAX, ll = DBL_MAX;
   for(int i = 2; i <= InpSwingN + 1; i++) { hh = MathMax(hh, iHigh(_Symbol, _Period, i)); ll = MathMin(ll, iLow(_Symbol, _Period, i)); }

   if(InpMode == 0)                                   // absorption reversal
   {
      if(l1 < ll && dz >=  InpDeltaZ && (!InpNeedBodyDir || c1 > o1)) return  1;
      if(h1 > hh && dz <= -InpDeltaZ && (!InpNeedBodyDir || c1 < o1)) return -1;
   }
   else                                               // delta breakout with trend
   {
      double f = Val(hFast, 1), s = Val(hSlow, 1);
      if(f < 0 || s < 0) return 0;
      if(c1 > hh && c1 > o1 && dz >=  InpDeltaZ && c1 > f && f > s) return  1;
      if(c1 < ll && c1 < o1 && dz <= -InpDeltaZ && c1 < f && f < s) return -1;
   }
   return 0;
}

void OnTick()
{
   if(InpMoveBE) ManageBE();
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == lastBar) return;
   lastBar = bt;
   cBars++;

   // delta of the bar that just closed
   double d;
   if(!BarDelta(iTime(_Symbol, _Period, 1), d)) { cNoTicks++; ArrayResize(dl, ArraySize(dl) + 1); dl[ArraySize(dl) - 1] = 0; return; }
   int n = ArraySize(dl);
   ArrayResize(dl, n + 1);
   dl[n] = d;
   if(n + 1 > 600) { ArrayRemove(dl, 0, 100); }

   if(HasOpenPosition()) return;
   if(InpUseSession)
   {
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;
   }
   double sd = StdDev();
   if(sd <= 0) return;
   double dz = d / sd;
   int dir = Signal(dz);
   if(dir == 0) return;
   if(dir > 0 && !InpAllowLong) return;
   if(dir < 0 && !InpAllowShort) return;
   cSig++;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((ask - bid) > InpMaxSpread) return;
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dir > 0)
   {
      double sl = iLow(_Symbol, _Period, 1) - InpStopBuffer, dist = ask - sl;
      if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return;
      double lots = CalcLots(dist); if(lots <= 0) return;
      if(trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(ask + InpRR * dist, _Digits), "DF"))
      { cTrades++; PrintFormat("BUY dz=%.2f delta=%.0f lots=%.2f sl=%.2f", dz, d, lots, sl); }
   }
   else
   {
      double sl = iHigh(_Symbol, _Period, 1) + InpStopBuffer, dist = sl - bid;
      if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return;
      double lots = CalcLots(dist); if(lots <= 0) return;
      if(trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(bid - InpRR * dist, _Digits), "DF"))
      { cTrades++; PrintFormat("SELL dz=%.2f delta=%.0f lots=%.2f sl=%.2f", dz, d, lots, sl); }
   }
}
//+------------------------------------------------------------------+
