//+------------------------------------------------------------------+
//|  FibPullback_XAUUSD.mq5 (v1) -- Fibonacci retracement pullback    |
//|                                                                  |
//|  Swing leg (uptrend): latest confirmed fractal HIGH and the      |
//|  fractal LOW before it (Bill Williams 5-bar fractals).           |
//|  Zone   : retracement between InpZoneMin and InpZoneMax of the   |
//|           leg (0.5-0.618 golden zone, or 0.618-0.786 OTE).       |
//|  Valid  : since the high, price dipped into the zone, made no    |
//|           new high, and never broke the swing low (100%).        |
//|  Trigger: bullish candle closing above the previous high -> BUY. |
//|  Stop   : below the swing low (100%).                            |
//|  Target : fib extension (InpTpExt, 1.272 = 27.2% beyond high)    |
//|           or fixed RR (InpTpMode=1).                             |
//|  Trend  : close > EMA50 > EMA200. Sells are the mirror image.    |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Fibonacci"
input double InpZoneMin     = 0.50;   // zone starts at this retracement
input double InpZoneMax     = 0.618;  // zone ends at this retracement
input double InpMinLegAtr   = 2.0;    // swing leg must be >= this x ATR(14)
input int    InpLookback    = 150;    // bars searched for the swing
input int    InpTpMode      = 0;      // 0 = fib extension, 1 = fixed RR
input double InpTpExt       = 1.272;  // extension target (1.0 = retest the swing high)
input double InpRR          = 2.0;    // used when InpTpMode = 1
input double InpMinRR       = 1.0;    // skip if target/stop is below this
input group "Trend"
input bool   InpUseTrend    = true;
input int    InpEmaFast     = 50;
input int    InpEmaSlow     = 200;
input group "Risk"
input double InpRiskPercent = 1.0;
input double InpStopBuffer  = 0.10;
input double InpMinStop     = 0.80;
input double InpMaxStop     = 30.0;
input double InpMaxSpread   = 0.60;
input bool   InpAllowLong   = true;
input bool   InpAllowShort  = true;
input ulong  InpMagic       = 20261170;
input int    InpDeviation   = 30;

CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hAtr = INVALID_HANDLE;
datetime lastBar = 0, usedLong = 0, usedShort = 0;
int      cBars = 0, cLeg = 0, cZone = 0, cSig = 0, cTrades = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hFast = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hAtr  = iATR(_Symbol, _Period, 14);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hAtr == INVALID_HANDLE) return INIT_FAILED;
   PrintFormat("FibPullback started on %s %s zone %.3f-%.3f", _Symbol, EnumToString(_Period), InpZoneMin, InpZoneMax);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FUNNEL bars=%d legs=%d inZone=%d signals=%d trades=%d", cBars, cLeg, cZone, cSig, cTrades);
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hAtr  != INVALID_HANDLE) IndicatorRelease(hAtr);
}

double Val(const int h, const int shift)
{
   double b[];
   ArraySetAsSeries(b, true);
   return (CopyBuffer(h, 0, shift, 1, b) == 1) ? b[0] : -1;
}

bool IsFH(const int k) { double h = iHigh(_Symbol, _Period, k);
   return h > iHigh(_Symbol, _Period, k-1) && h > iHigh(_Symbol, _Period, k-2) && h > iHigh(_Symbol, _Period, k+1) && h > iHigh(_Symbol, _Period, k+2); }
bool IsFL(const int k) { double l = iLow(_Symbol, _Period, k);
   return l < iLow(_Symbol, _Period, k-1) && l < iLow(_Symbol, _Period, k-2) && l < iLow(_Symbol, _Period, k+1) && l < iLow(_Symbol, _Period, k+2); }

int Trend()
{
   if(!InpUseTrend) return 2;
   double f = Val(hFast, 1), s = Val(hSlow, 1);
   if(f < 0 || s < 0) return 0;
   double c = iClose(_Symbol, _Period, 1);
   if(c > f && f > s) return 1;
   if(c < f && f < s) return -1;
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

//--- dir +1: leg = fractal low (older) -> fractal high (newer). Fills swing levels and the leg id.
bool Leg(const int dir, double &sw0, double &sw100, datetime &id)
{
   int kE = -1;                                   // newest swing end (high for longs)
   for(int k = 3; k <= InpLookback; k++) if(dir > 0 ? IsFH(k) : IsFL(k)) { kE = k; break; }
   if(kE < 0) return false;
   int kS = -1;                                   // swing start before it (low for longs)
   for(int k = kE + 1; k <= InpLookback + 50; k++) if(dir > 0 ? IsFL(k) : IsFH(k)) { kS = k; break; }
   if(kS < 0) return false;
   sw0   = (dir > 0) ? iHigh(_Symbol, _Period, kE) : iLow(_Symbol, _Period, kE);    // 0% level
   sw100 = (dir > 0) ? iLow(_Symbol, _Period, kS)  : iHigh(_Symbol, _Period, kS);   // 100% level
   double leg = MathAbs(sw0 - sw100), atr = Val(hAtr, 1);
   if(atr <= 0 || leg < InpMinLegAtr * atr) return false;
   // since the swing end: no new extreme, no break of 100%, and a dip into the zone
   double zTop = sw0 - dir * InpZoneMin * leg;    // shallow edge of the zone
   bool inZone = false;
   for(int i = 1; i < kE; i++)
   {
      double h = iHigh(_Symbol, _Period, i), l = iLow(_Symbol, _Period, i);
      if(dir > 0) { if(h > sw0 || l < sw100) return false; if(l <= zTop) inZone = true; }
      else        { if(l < sw0 || h > sw100) return false; if(h >= zTop) inZone = true; }
   }
   cLeg++;
   if(!inZone) return false;
   cZone++;
   id = iTime(_Symbol, _Period, kE);
   return true;
}

void Try(const int dir)
{
   double sw0, sw100; datetime id;
   if(!Leg(dir, sw0, sw100, id)) return;
   if(id == (dir > 0 ? usedLong : usedShort)) return;
   double leg = MathAbs(sw0 - sw100);
   double zDeep = sw0 - dir * InpZoneMax * leg;   // deep edge of the zone
   double o1 = iOpen(_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   if(dir > 0 && !(c1 > o1 && c1 > iHigh(_Symbol, _Period, 2) && c1 >= zDeep && c1 < sw0)) return;
   if(dir < 0 && !(c1 < o1 && c1 < iLow(_Symbol, _Period, 2)  && c1 <= zDeep && c1 > sw0)) return;
   cSig++;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((ask - bid) > InpMaxSpread) return;
   double entry = (dir > 0) ? ask : bid;
   double sl = sw100 - dir * InpStopBuffer;
   double dist = dir * (entry - sl);
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return;
   double tp = (InpTpMode == 0) ? sw100 + dir * InpTpExt * leg : entry + dir * InpRR * dist;
   double rr = dir * (tp - entry) / dist;
   if(rr < InpMinRR) return;
   double lots = CalcLots(dist);
   if(lots <= 0) return;
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "FIB")
                       : trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "FIB");
   if(ok)
   {
      cTrades++;
      if(dir > 0) usedLong = id; else usedShort = id;
      PrintFormat("%s rr=%.2f sl=%.2f tp=%.2f leg=%.2f", (dir > 0 ? "BUY" : "SELL"), rr, sl, tp, leg);
   }
}

void OnTick()
{
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == lastBar) return;
   lastBar = bt;
   cBars++;
   if(HasOpenPosition()) return;
   int tr = Trend();
   if(tr == 0) return;
   if(InpAllowLong  && (tr == 1  || tr == 2)) Try(1);
   if(HasOpenPosition()) return;
   if(InpAllowShort && (tr == -1 || tr == 2)) Try(-1);
}
//+------------------------------------------------------------------+
