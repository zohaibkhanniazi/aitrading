//+------------------------------------------------------------------+
//|  BullishEngulfing_XAUUSD.mq5                                     |
//|  Bullish engulfing Expert Advisor (v1) - BUY only                |
//|                                                                  |
//|  Signal : bar[2] bearish, bar[1] bullish, bar[1] body engulfs    |
//|           bar[2] body (open1 <= close2, close1 >= open2).        |
//|           Optional filter: close[1] below SMA (pullback/reversal)|
//|  Entry  : market BUY at the open of the new bar (bar[0]).        |
//|  Stop   : lowest low of bar[1] and bar[2] minus buffer.          |
//|  Target : entry + RR * (entry - stop).                           |
//|  Size   : risk % of equity per trade.                            |
//|                                                                  |
//|  Attach to an XAUUSD chart (any Exness gold symbol, e.g.         |
//|  XAUUSD, XAUUSDm). Test on a DEMO account first.                 |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- inputs
input double InpRiskPercent   = 1.0;     // Risk per trade (% of equity)
input double InpRR            = 2.0;     // Take profit as multiple of risk (R)
input double InpStopBuffer    = 0.10;    // Extra room below pattern low (price units, USD)
input double InpMinStop       = 1.00;    // Skip trade if stop distance < this (USD)
input double InpMaxStop       = 30.00;   // Skip trade if stop distance > this (USD)
input double InpMaxSpread     = 0.60;    // Skip trade if spread > this (USD)
input bool   InpUseTrend      = true;    // Only trade when close is below SMA
input int    InpSmaPeriod     = 50;      // SMA period
input double InpMinBodyRatio  = 0.0;     // Engulfing body >= ratio * previous body (0 = off)
input bool   InpUseSession    = false;   // Restrict trading hours (server time)
input int    InpStartHour     = 7;       // Session start hour (server time)
input int    InpEndHour       = 20;      // Session end hour (server time)
input ulong  InpMagic         = 20261025;// Magic number
input int    InpDeviation     = 30;      // Max slippage (points)

CTrade trade;
int    smaHandle = INVALID_HANDLE;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpUseTrend)
   {
      smaHandle = iMA(_Symbol, _Period, InpSmaPeriod, 0, MODE_SMA, PRICE_CLOSE);
      if(smaHandle == INVALID_HANDLE)
      {
         Print("Failed to create SMA indicator");
         return INIT_FAILED;
      }
   }
   PrintFormat("BullishEngulfing EA started on %s, timeframe %s", _Symbol, EnumToString(_Period));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(smaHandle != INVALID_HANDLE) IndicatorRelease(smaHandle);
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

//+------------------------------------------------------------------+
bool IsBullishEngulfing()
{
   double o1 = iOpen(_Symbol, _Period, 1),  c1 = iClose(_Symbol, _Period, 1);
   double o2 = iOpen(_Symbol, _Period, 2),  c2 = iClose(_Symbol, _Period, 2);

   if(!(c2 < o2)) return false;            // previous bar bearish
   if(!(c1 > o1)) return false;            // current signal bar bullish
   if(!(o1 <= c2 && c1 >= o2)) return false; // body engulfs previous body

   if(InpMinBodyRatio > 0.0 && (c1 - o1) < InpMinBodyRatio * (o2 - c2))
      return false;

   if(InpUseTrend)
   {
      double sma[];
      ArraySetAsSeries(sma, true);
      if(CopyBuffer(smaHandle, 0, 1, 1, sma) != 1) return false;
      if(!(c1 < sma[0])) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
double CalcLots(double stopDistance)
{
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0) tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0.0;

   double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0) return 0.0;

   double lots    = riskMoney / lossPerLot;
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / step) * step;
   if(lots < minLot)
   {
      PrintFormat("Calculated lot %.4f below minimum %.4f - skipping (risk too small for this stop)", lots, minLot);
      return 0.0;
   }
   if(lots > maxLot) lots = maxLot;
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // act once per new bar
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

   if(!IsBullishEngulfing()) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((ask - bid) > InpMaxSpread)
   {
      PrintFormat("Signal skipped: spread %.2f > max %.2f", ask - bid, InpMaxSpread);
      return;
   }

   double patternLow = MathMin(iLow(_Symbol, _Period, 1), iLow(_Symbol, _Period, 2));
   double sl = patternLow - InpStopBuffer;
   double stopDistance = ask - sl;

   if(stopDistance < InpMinStop || stopDistance > InpMaxStop)
   {
      PrintFormat("Signal skipped: stop distance %.2f outside [%.2f, %.2f]", stopDistance, InpMinStop, InpMaxStop);
      return;
   }

   // broker minimum stop distance
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(stopDistance <= minLevel) return;

   double tp   = ask + InpRR * stopDistance;
   double lots = CalcLots(stopDistance);
   if(lots <= 0) return;

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   if(trade.Buy(lots, _Symbol, 0.0, sl, tp, "BullEngulf"))
      PrintFormat("BUY %.2f lots @ %.2f SL %.2f TP %.2f", lots, ask, sl, tp);
   else
      PrintFormat("Buy failed: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+
