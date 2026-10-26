//+------------------------------------------------------------------+
//|  Fractal_XAUUSD.mq5 (v1) -- Bill Williams fractal structure       |
//|                                                                  |
//|  Fractal high: candle with 2 lower highs on each side (5 bars).  |
//|  Fractal low : candle with 2 higher lows on each side.           |
//|  Confirmed only after 2 more candles close (no look-ahead).      |
//|                                                                  |
//|  Mode 0  BREAKOUT  : trend up + candle closes above the latest   |
//|          fractal high -> BUY, stop below the latest fractal low. |
//|  Mode 1  SWEEP     : trend up + candle wicks below the latest    |
//|          fractal low but closes back above it -> BUY, stop below |
//|          that candle's low.  (Sells are the mirror image.)       |
//|  Trend   : close > EMA fast > EMA slow (switchable).             |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Signal"
input int    InpMode        = 0;      // 0 = fractal breakout, 1 = fractal sweep & reclaim
input int    InpLookback    = 100;    // bars searched for the latest fractals
input bool   InpUseTrend    = true;   // trade only with the EMA trend
input int    InpEmaFast     = 50;
input int    InpEmaSlow     = 200;
input group "Risk"
input double InpRiskPercent = 1.0;
input double InpRR          = 2.0;
input bool   InpMoveBE      = true;   // stop to break-even once price reaches BeTriggerR
input double InpBeTriggerR  = 1.0;
input double InpStopBuffer  = 0.10;
input double InpMinStop     = 0.80;
input double InpMaxStop     = 30.0;
input double InpMaxSpread   = 0.60;
input bool   InpAllowLong   = true;
input bool   InpAllowShort  = true;
input ulong  InpMagic       = 20261150;
input int    InpDeviation   = 30;

CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE;
datetime lastBar = 0;
datetime usedLong = 0, usedShort = 0;   // fractal already traded (one trade per fractal)
int      cBars = 0, cTrend = 0, cSig = 0, cTrades = 0, cStop = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hFast = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE) return INIT_FAILED;
   PrintFormat("Fractal EA started on %s %s mode %d", _Symbol, EnumToString(_Period), InpMode);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FUNNEL bars=%d trendOk=%d signals=%d stopOk=%d trades=%d", cBars, cTrend, cSig, cStop, cTrades);
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
}

double Val(const int h, const int shift)
{
   double b[];
   ArraySetAsSeries(b, true);
   return (CopyBuffer(h, 0, shift, 1, b) == 1) ? b[0] : -1;
}

//--- latest fractal confirmed by bar 2 (so bar 1 is the test candle). kind +1 = high, -1 = low
bool LatestFractal(const int kind, double &level, datetime &when)
{
   for(int k = 4; k <= InpLookback; k++)
   {
      if(kind > 0)
      {
         double h = iHigh(_Symbol, _Period, k);
         if(h > iHigh(_Symbol, _Period, k - 1) && h > iHigh(_Symbol, _Period, k - 2) &&
            h > iHigh(_Symbol, _Period, k + 1) && h > iHigh(_Symbol, _Period, k + 2))
         { level = h; when = iTime(_Symbol, _Period, k); return true; }
      }
      else
      {
         double l = iLow(_Symbol, _Period, k);
         if(l < iLow(_Symbol, _Period, k - 1) && l < iLow(_Symbol, _Period, k - 2) &&
            l < iLow(_Symbol, _Period, k + 1) && l < iLow(_Symbol, _Period, k + 2))
         { level = l; when = iTime(_Symbol, _Period, k); return true; }
      }
   }
   return false;
}

int Trend()
{
   if(!InpUseTrend) return 2;                       // 2 = both directions allowed
   double f = Val(hFast, 1), s = Val(hSlow, 1);
   if(f < 0 || s < 0) return 0;
   double c1 = iClose(_Symbol, _Period, 1);
   if(c1 > f && f > s) return 1;
   if(c1 < f && f < s) return -1;
   return 0;
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
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
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

bool Open(const int dir, const double sl)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((ask - bid) > InpMaxSpread) return false;
   double entry = (dir > 0) ? ask : bid;
   double dist = (dir > 0) ? entry - sl : sl - entry;
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return false;
   cStop++;
   double lots = CalcLots(dist);
   if(lots <= 0) return false;
   double tp = entry + dir * InpRR * dist;
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "FR")
                       : trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "FR");
   if(ok) { cTrades++; PrintFormat("%s lots=%.2f sl=%.2f tp=%.2f", (dir > 0 ? "BUY" : "SELL"), lots, sl, tp); }
   return ok;
}

void OnTick()
{
   if(InpMoveBE) ManageBE();
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == lastBar) return;
   lastBar = bt;
   cBars++;
   if(HasOpenPosition()) return;

   int tr = Trend();
   if(tr == 0) return;
   cTrend++;

   double up, dn; datetime tUp, tDn;
   if(!LatestFractal(1, up, tUp) || !LatestFractal(-1, dn, tDn)) return;
   double o1 = iOpen(_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   double h1 = iHigh(_Symbol, _Period, 1), l1 = iLow(_Symbol, _Period, 1);
   double c2 = iClose(_Symbol, _Period, 2);
   bool longOk  = InpAllowLong  && (tr == 1  || tr == 2);
   bool shortOk = InpAllowShort && (tr == -1 || tr == 2);

   if(InpMode == 0)                                          // breakout of the latest fractal
   {
      if(longOk && c1 > up && c2 <= up && tUp != usedLong && dn < c1)
      { cSig++; if(Open(1, dn - InpStopBuffer)) usedLong = tUp; return; }
      if(shortOk && c1 < dn && c2 >= dn && tDn != usedShort && up > c1)
      { cSig++; if(Open(-1, up + InpStopBuffer)) usedShort = tDn; return; }
   }
   else                                                      // sweep of the latest fractal & close back inside
   {
      if(longOk && l1 < dn && c1 > dn && tDn != usedLong)
      { cSig++; if(Open(1, l1 - InpStopBuffer)) usedLong = tDn; return; }
      if(shortOk && h1 > up && c1 < up && tUp != usedShort)
      { cSig++; if(Open(-1, h1 + InpStopBuffer)) usedShort = tUp; return; }
   }
}
//+------------------------------------------------------------------+
