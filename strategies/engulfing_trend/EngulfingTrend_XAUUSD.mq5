//+------------------------------------------------------------------+
//|  EngulfingTrend_XAUUSD.mq5  (v1)                                 |
//|  Engulfing patterns, traded ONLY in the direction of the trend.  |
//|                                                                  |
//|  Trend UP   : close[1] > EMA(fast) > EMA(slow)  -> only BUYS      |
//|  Trend DOWN : close[1] < EMA(fast) < EMA(slow)  -> only SELLS     |
//|  Otherwise  : no trade.                                          |
//|                                                                  |
//|  BUY  signal: bar[2] bearish, bar[1] bullish, body engulfs.      |
//|  SELL signal: bar[2] bullish, bar[1] bearish, body engulfs.      |
//|  Entry : market at open of the new bar.                          |
//|  Stop  : beyond the pattern extreme (+/- buffer).                |
//|  Target: RR * stop distance. Risk: % of equity per trade.        |
//|  Test on DEMO / in the Strategy Tester first.                    |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input double InpRiskPercent   = 1.0;     // Risk per trade (% of equity)
input double InpRR            = 2.0;     // Take profit as multiple of risk (R)
input int    InpFastEma       = 50;      // Fast EMA period (trend)
input int    InpSlowEma       = 200;     // Slow EMA period (trend)
input double InpStopBuffer    = 0.10;    // Extra room beyond pattern extreme (USD)
input double InpMinStop       = 1.00;    // Skip if stop distance < this (USD)
input double InpMaxStop       = 30.00;   // Skip if stop distance > this (USD)
input double InpMaxSpread     = 0.60;    // Skip if spread > this (USD)
input double InpMinBodyRatio  = 0.0;     // Engulfing body >= ratio * previous body (0 = off)
input bool   InpAllowLong     = true;    // Allow buys
input bool   InpAllowShort    = true;    // Allow sells
input bool   InpUseSession    = false;   // Restrict trading hours (server time)
input int    InpStartHour     = 7;       // Session start hour
input int    InpEndHour       = 20;      // Session end hour
input ulong  InpMagic         = 20261026;// Magic number
input int    InpDeviation     = 30;      // Max slippage (points)

CTrade   trade;
int      fastHandle = INVALID_HANDLE;
int      slowHandle = INVALID_HANDLE;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);

   fastHandle = iMA(_Symbol, _Period, InpFastEma, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle = iMA(_Symbol, _Period, InpSlowEma, 0, MODE_EMA, PRICE_CLOSE);
   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE)
   {
      Print("Failed to create EMA indicators");
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fastHandle != INVALID_HANDLE) IndicatorRelease(fastHandle);
   if(slowHandle != INVALID_HANDLE) IndicatorRelease(slowHandle);
}

//+------------------------------------------------------------------+
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

//--- returns +1 uptrend, -1 downtrend, 0 none (uses closed bar 1)
int TrendDirection()
{
   double f[], s[];
   ArraySetAsSeries(f, true);
   ArraySetAsSeries(s, true);
   if(CopyBuffer(fastHandle, 0, 1, 1, f) != 1) return 0;
   if(CopyBuffer(slowHandle, 0, 1, 1, s) != 1) return 0;
   double c1 = iClose(_Symbol, _Period, 1);
   if(c1 > f[0] && f[0] > s[0]) return 1;
   if(c1 < f[0] && f[0] < s[0]) return -1;
   return 0;
}

//+------------------------------------------------------------------+
bool BullishEngulfing()
{
   double o1 = iOpen(_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   double o2 = iOpen(_Symbol, _Period, 2), c2 = iClose(_Symbol, _Period, 2);
   if(!(c2 < o2 && c1 > o1)) return false;
   if(!(o1 <= c2 && c1 >= o2)) return false;
   if(InpMinBodyRatio > 0.0 && (c1 - o1) < InpMinBodyRatio * (o2 - c2)) return false;
   return true;
}

bool BearishEngulfing()
{
   double o1 = iOpen(_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   double o2 = iOpen(_Symbol, _Period, 2), c2 = iClose(_Symbol, _Period, 2);
   if(!(c2 > o2 && c1 < o1)) return false;
   if(!(o1 >= c2 && c1 <= o2)) return false;
   if(InpMinBodyRatio > 0.0 && (o1 - c1) < InpMinBodyRatio * (c2 - o2)) return false;
   return true;
}

//+------------------------------------------------------------------+
double CalcLots(double stopDistance)
{
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;

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

//+------------------------------------------------------------------+
void OnTick()
{
   datetime barTime = iTime(_Symbol, _Period, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;

   if(HasOpenPosition()) return;

   if(InpUseSession)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;
   }

   int trend = TrendDirection();
   if(trend == 0) return;                       // no clear trend: stand aside

   bool wantBuy  = (trend ==  1 && InpAllowLong  && BullishEngulfing());
   bool wantSell = (trend == -1 && InpAllowShort && BearishEngulfing());
   if(!wantBuy && !wantSell) return;             // pattern against trend is ignored

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((ask - bid) > InpMaxSpread) return;

   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(wantBuy)
   {
      double sl = MathMin(iLow(_Symbol, _Period, 1), iLow(_Symbol, _Period, 2)) - InpStopBuffer;
      double dist = ask - sl;
      if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return;
      double lots = CalcLots(dist);
      if(lots <= 0) return;
      double tp = ask + InpRR * dist;
      trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "TrendEngulf");
   }
   else
   {
      double sl = MathMax(iHigh(_Symbol, _Period, 1), iHigh(_Symbol, _Period, 2)) + InpStopBuffer;
      double dist = sl - bid;
      if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return;
      double lots = CalcLots(dist);
      if(lots <= 0) return;
      double tp = bid - InpRR * dist;
      trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "TrendEngulf");
   }
}
//+------------------------------------------------------------------+
