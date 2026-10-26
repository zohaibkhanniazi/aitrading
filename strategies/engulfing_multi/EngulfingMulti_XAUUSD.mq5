//+------------------------------------------------------------------+
//|  EngulfingMulti_XAUUSD.mq5  (v1)  = EngulfingConfirm + multi-leg exits                               |
//|  Trend-aligned engulfing with switchable confirmations.          |
//|                                                                  |
//|  Trend UP  : close > EMA(fast) > EMA(slow) -> buys only          |
//|  Trend DOWN: close < EMA(fast) < EMA(slow) -> sells only         |
//|                                                                  |
//|  Optional confirmations (each can be turned on/off):             |
//|   1 ADX      : trend strength above a minimum                    |
//|   2 Slope    : fast EMA rising (buys) / falling (sells)          |
//|   3 RSI      : no buying when overbought / selling when oversold |
//|   4 ATR body : engulfing candle body >= k * ATR (a real move)    |
//|   5 Pullback : pattern touched the fast EMA zone (buy the dip)   |
//|   6 Session  : trade only inside chosen server hours             |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input group "Core"
input double InpRiskPercent   = 1.0;     // Risk per trade (% of equity)
input double InpRR            = 2.0;     // Take profit (multiple of risk)
input int    InpFastEma       = 50;      // Fast EMA
input int    InpSlowEma       = 200;     // Slow EMA
input double InpStopBuffer    = 0.10;    // Stop buffer beyond pattern (USD)
input double InpMinStop       = 1.00;    // Min stop distance (USD)
input double InpMaxStop       = 30.00;   // Max stop distance (USD)
input double InpMaxSpread     = 0.60;    // Max spread (USD)
input bool   InpAllowLong     = true;
input bool   InpAllowShort    = true;
input group "Exits"
input int    InpLegs         = 3;      // 1 = single trade (uses RR), 2 = legs at Leg1R+Leg3R, 3 = Leg1R+Leg2R+Leg3R
input double InpLeg1R        = 1.0;
input double InpLeg2R        = 2.0;
input double InpLeg3R        = 3.0;
input bool   InpMoveBE       = true;   // move stops to break-even once price reaches BeTriggerR
input double InpBeTriggerR   = 1.0;
input double InpBeOffset     = 0.0;
input group "Confirmations"
input bool   InpUseAdx        = false;   // 1 ADX strength filter
input int    InpAdxPeriod     = 14;
input double InpAdxMin        = 20.0;
input bool   InpUseSlope      = false;    // 2 EMA slope filter
input int    InpSlopeBars     = 5;
input bool   InpUseRsi        = false;    // 3 RSI exhaustion filter
input int    InpRsiPeriod     = 14;
input double InpRsiBuyMax     = 70.0;
input double InpRsiSellMin    = 30.0;
input bool   InpUseAtrBody    = true;    // 4 Engulfing body vs ATR
input int    InpAtrPeriod     = 14;
input double InpMinBodyAtr    = 0.8;
input bool   InpUsePullback   = false;   // 5 Pullback to fast EMA
input double InpPullbackAtr   = 0.5;
input bool   InpUseSession    = false;   // 6 Session filter
input int    InpStartHour     = 7;
input int    InpEndHour       = 20;
input group "Other"
input ulong  InpMagic         = 20261120;
input int    InpDeviation     = 30;

CTrade   trade;
int hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hAdx = INVALID_HANDLE,
    hRsi = INVALID_HANDLE, hAtr = INVALID_HANDLE;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hFast = iMA(_Symbol, _Period, InpFastEma, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, _Period, InpSlowEma, 0, MODE_EMA, PRICE_CLOSE);
   hAdx  = iADX(_Symbol, _Period, InpAdxPeriod);
   hRsi  = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   hAtr  = iATR(_Symbol, _Period, InpAtrPeriod);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hAdx == INVALID_HANDLE ||
      hRsi == INVALID_HANDLE || hAtr == INVALID_HANDLE)
   {
      Print("Failed to create indicators");
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   int h[5] = {hFast, hSlow, hAdx, hRsi, hAtr};
   for(int i = 0; i < 5; i++)
      if(h[i] != INVALID_HANDLE) IndicatorRelease(h[i]);
}

//--- value of buffer 0 of an indicator at a shift, or -1 on failure
double Val(const int handle, const int shift)
{
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(handle, 0, shift, 1, b) != 1) return -1.0;
   return b[0];
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

//--- +1 up, -1 down, 0 none
int Trend()
{
   double f = Val(hFast, 1), s = Val(hSlow, 1);
   if(f < 0 || s < 0) return 0;
   double c1 = iClose(_Symbol, _Period, 1);
   if(c1 > f && f > s) return 1;
   if(c1 < f && f < s) return -1;
   return 0;
}

bool BullishEngulfing()
{
   double o1 = iOpen(_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   double o2 = iOpen(_Symbol, _Period, 2), c2 = iClose(_Symbol, _Period, 2);
   return (c2 < o2 && c1 > o1 && o1 <= c2 && c1 >= o2);
}

bool BearishEngulfing()
{
   double o1 = iOpen(_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   double o2 = iOpen(_Symbol, _Period, 2), c2 = iClose(_Symbol, _Period, 2);
   return (c2 > o2 && c1 < o1 && o1 >= c2 && c1 <= o2);
}

//--- all enabled confirmations for direction dir (+1 buy / -1 sell)
bool Confirmed(const int dir)
{
   double atr = Val(hAtr, 1);

   if(InpUseAdx)
   {
      double adx = Val(hAdx, 1);
      if(adx < 0 || adx < InpAdxMin) return false;
   }
   if(InpUseSlope)
   {
      double now = Val(hFast, 1), past = Val(hFast, 1 + InpSlopeBars);
      if(now < 0 || past < 0) return false;
      if(dir > 0 && !(now > past)) return false;
      if(dir < 0 && !(now < past)) return false;
   }
   if(InpUseRsi)
   {
      double rsi = Val(hRsi, 1);
      if(rsi < 0) return false;
      if(dir > 0 && rsi > InpRsiBuyMax) return false;
      if(dir < 0 && rsi < InpRsiSellMin) return false;
   }
   if(InpUseAtrBody)
   {
      if(atr <= 0) return false;
      double body = MathAbs(iClose(_Symbol, _Period, 1) - iOpen(_Symbol, _Period, 1));
      if(body < InpMinBodyAtr * atr) return false;
   }
   if(InpUsePullback)
   {
      if(atr <= 0) return false;
      double f = Val(hFast, 1);
      if(f < 0) return false;
      if(dir > 0)
      {
         double lo = MathMin(iLow(_Symbol, _Period, 1), iLow(_Symbol, _Period, 2));
         if(lo > f + InpPullbackAtr * atr) return false;
      }
      else
      {
         double hi = MathMax(iHigh(_Symbol, _Period, 1), iHigh(_Symbol, _Period, 2));
         if(hi < f - InpPullbackAtr * atr) return false;
      }
   }
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
   double lots   = riskMoney / lossPerLot;
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   if(lots < minLot) return 0.0;
   if(lots > maxLot) lots = maxLot;
   return NormalizeDouble(lots, 2);
}

//--- open 1..3 legs; dir=+1 buy, -1 sell
void OpenLegs(const int dir, const double entry, const double sl, const double dist, double lots)
{
   int legs = InpLegs;
   double rs[3]; rs[0] = InpRR; rs[1] = 0; rs[2] = 0;
   if(legs >= 2)
   {
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double each = MathFloor(lots / legs / step) * step;
      if(each >= minLot)
      {
         lots = NormalizeDouble(each, 2);
         rs[0] = InpLeg1R;
         if(legs == 2) rs[1] = InpLeg3R; else { rs[1] = InpLeg2R; rs[2] = InpLeg3R; }
      }
      else legs = 1;
   }
   for(int i = 0; i < legs; i++)
   {
      double tp = NormalizeDouble(entry + dir * rs[i] * dist, _Digits);
      string cm = StringFormat("EM|%.2f", rs[i]);
      if(dir > 0) trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), tp, cm);
      else        trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), tp, cm);
   }
}

void ManageBE()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string cm = PositionGetString(POSITION_COMMENT);
      int p = StringFind(cm, "|");
      if(p < 0) continue;
      double rmul = StringToDouble(StringSubstr(cm, p + 1));
      if(rmul <= 0) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
      {
         double d = (tp - open) / rmul;
         if(sl < open - _Point && bid >= open + InpBeTriggerR * d)
            trade.PositionModify(ticket, NormalizeDouble(open + InpBeOffset, _Digits), tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double d = (open - tp) / rmul;
         if(sl > open + _Point && ask <= open - InpBeTriggerR * d)
            trade.PositionModify(ticket, NormalizeDouble(open - InpBeOffset, _Digits), tp);
      }
   }
}

void OnTick()
{
   if(InpMoveBE) ManageBE();
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

   int trend = Trend();
   if(trend == 0) return;

   bool wantBuy  = (trend ==  1 && InpAllowLong  && BullishEngulfing() && Confirmed(1));
   bool wantSell = (trend == -1 && InpAllowShort && BearishEngulfing() && Confirmed(-1));
   if(!wantBuy && !wantSell) return;

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
      OpenLegs(1, ask, sl, dist, lots);
   }
   else
   {
      double sl = MathMax(iHigh(_Symbol, _Period, 1), iHigh(_Symbol, _Period, 2)) + InpStopBuffer;
      double dist = sl - bid;
      if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return;
      double lots = CalcLots(dist);
      if(lots <= 0) return;
      OpenLegs(-1, bid, sl, dist, lots);
   }
}
//+------------------------------------------------------------------+
