//+------------------------------------------------------------------+
//|  SilverBulletM1_XAUUSD.mq5 (v1) -- timeframe is an input (default M1)                       |
//|  ICT Silver Bullet: inside a 1-hour window (New York local time: |
//|  London 03-04, NY AM 10-11, NY PM 14-15), after a liquidity      |
//|  sweep, enter on the pullback into the first M5 fair value gap   |
//|  in the reversal direction. Sells = mirror (prices negated).     |
//|  NY time is derived from server time via InpServerGmtOffset and  |
//|  US daylight saving rules.                                       |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Time"
input int    InpServerGmtOffset = 0;   // broker server time minus UTC, in hours
input bool   InpUseLondon    = true;   // 03:00-04:00 New York
input bool   InpUseNyAm      = true;   // 10:00-11:00 New York
input bool   InpUseNyPm      = true;   // 14:00-15:00 New York
input int    InpWindowLenH   = 1;
input group "Setup"
input bool   InpRequireSweep = true;   // liquidity sweep before the FVG
input ENUM_TIMEFRAMES InpTF = PERIOD_M1; // signal/entry timeframe
input int    InpSweepWithin  = 12;     // M5 bars before the FVG that may contain the sweep
input int    InpSweepLookback= 24;     // M5 bars of prior lows that must be taken out
input int    InpFvgSearch    = 10;     // how many recent bars to search for the FVG
input double InpFvgMinAtr    = 0.10;   // min FVG size (x M5 ATR)
input int    InpEntryMode    = 0;      // 0 = FVG edge, 1 = FVG midpoint
input int    InpSlMode       = 0;      // 0 = below FVG first candle low, 1 = below sweep low
input group "Exits"
input int    InpLegs         = 1;      // 1 = single trade (uses RR), 2 = legs at Leg1R+Leg3R, 3 = legs at Leg1R+Leg2R+Leg3R
input double InpLeg1R        = 1.0;
input double InpLeg2R        = 2.0;
input double InpLeg3R        = 3.0;
input bool   InpMoveBE       = true;   // move stop to break-even once price reaches BeTriggerR
input double InpBeTriggerR   = 1.0;
input double InpBeOffset     = 0.0;    // USD beyond entry for the break-even stop
input group "Risk"
input double InpRiskPercent  = 1.0;   // total risk, split equally across legs
input double InpRR           = 2.0;   // used when Legs = 1
input double InpStopBuffer   = 0.10;
input double InpMinStop      = 0.80;
input double InpMaxStop      = 30.0;
input double InpMaxSpread    = 0.60;
input bool   InpAllowLong    = true;
input bool   InpAllowShort   = true;
input ulong  InpMagic        = 20261130;
input int    InpDeviation    = 30;

struct SBar { datetime t; double o, h, l, c; };
CTrade trade;
int hAtr5 = INVALID_HANDLE;
datetime lastBar = 0;
int lastWin[2];
long cCalls=0, cWin=0, cFvg=0, cSweep=0, cTouch=0, cEntry=0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hAtr5 = iATR(_Symbol, InpTF, 14);
   if(hAtr5 == INVALID_HANDLE) return INIT_FAILED;
   lastWin[0] = 0; lastWin[1] = 0;
   if(_Period != InpTF) Print("WARNING: attach to the same timeframe as InpTF");
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   if(hAtr5 != INVALID_HANDLE) IndicatorRelease(hAtr5);
   PrintFormat("FUNNEL calls=%d inWindow=%d fvg=%d sweep=%d touch=%d entries=%d", (int)cCalls,(int)cWin,(int)cFvg,(int)cSweep,(int)cTouch,(int)cEntry);
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

//--- hours to add to UTC to get New York local time (-4 summer, -5 winter)
int NyOffsetHours(const datetime utc)
{
   MqlDateTime d, m;
   TimeToStruct(utc, d);
   int y = d.year;
   datetime mar1 = StringToTime(StringFormat("%d.03.01 00:00", y));
   TimeToStruct(mar1, m);
   int firstSunMar = 1 + (7 - m.day_of_week) % 7;
   datetime dstStart = StringToTime(StringFormat("%d.03.%02d 07:00", y, firstSunMar + 7));
   datetime nov1 = StringToTime(StringFormat("%d.11.01 00:00", y));
   TimeToStruct(nov1, m);
   int firstSunNov = 1 + (7 - m.day_of_week) % 7;
   datetime dstEnd = StringToTime(StringFormat("%d.11.%02d 06:00", y, firstSunNov));
   return (utc >= dstStart && utc < dstEnd) ? -4 : -5;
}
int NyHour(const datetime serverTime)
{
   datetime utc = serverTime - InpServerGmtOffset * 3600;
   datetime ny  = utc + NyOffsetHours(utc) * 3600;
   MqlDateTime d; TimeToStruct(ny, d);
   return d.hour;
}
int WindowId(const datetime serverTime)
{
   int h = NyHour(serverTime);
   if(InpUseLondon && h >= 3  && h < 3  + InpWindowLenH) return 1;
   if(InpUseNyAm   && h >= 10 && h < 10 + InpWindowLenH) return 2;
   if(InpUseNyPm   && h >= 14 && h < 14 + InpWindowLenH) return 3;
   return 0;
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
   int wid = WindowId(iTime(_Symbol, InpTF, 0));
   if(wid == 0) return false;
   cWin++;

   int need = InpFvgSearch + InpSweepWithin + InpSweepLookback + 10;
   SBar m5[];
   int n = LoadBars(InpTF, need, dir, m5);
   if(n < need - 5) return false;
   double a[]; ArraySetAsSeries(a, true);
   if(CopyBuffer(hAtr5, 0, 1, 1, a) != 1 || a[0] <= 0) return false;
   double atr = a[0];

   int kf = -1;
   for(int k = 3; k <= InpFvgSearch; k++)
   {
      if(m5[k].c <= m5[k].o) continue;                 // displacement candle must be bullish
      double gap = m5[k-1].l - m5[k+1].h;
      if(gap <= 0 || gap < InpFvgMinAtr * atr) continue;
      if(WindowId(m5[k-1].t) != wid) continue;          // formed inside this window
      kf = k; break;
   }
   if(kf < 0) return false;
   cFvg++;

   double lowSweep = DBL_MAX;
   for(int i = kf; i <= kf + InpSweepWithin; i++) lowSweep = MathMin(lowSweep, m5[i].l);
   if(InpRequireSweep)
   {
      double prior = DBL_MAX;
      for(int i2 = kf + InpSweepWithin + 1; i2 <= kf + InpSweepWithin + InpSweepLookback; i2++)
         prior = MathMin(prior, m5[i2].l);
      if(!(lowSweep < prior)) return false;
   }
   cSweep++;

   double top = m5[kf-1].l, bottom = m5[kf+1].h;
   double level = (InpEntryMode == 0) ? top : (top + bottom) / 2.0;
   if(!(m5[1].l <= level && m5[1].c > bottom)) return false;
   for(int s = kf - 2; s >= 2; s--)
      if(m5[s].l <= level) return false;                // not the first touch
   cTouch++;

   int di = (dir > 0) ? 0 : 1;
   int wkey = DayKey(m5[1].t) * 10 + wid;
   if(lastWin[di] == wkey) return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((ask - bid) > InpMaxSpread) return false;
   double e = (dir > 0) ? ask : -bid;
   double base = (InpSlMode == 0) ? m5[kf+1].l : lowSweep;
   double sl = base - InpStopBuffer;
   double dist = e - sl;
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return false;
   double lots = CalcLots(dist);
   if(lots <= 0) return false;
   double slR = NormalizeDouble(dir * sl, _Digits);

   int legs = InpLegs;
   double rs[3];
   rs[0] = InpRR; rs[1] = 0; rs[2] = 0;
   if(legs >= 2)
   {
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double each = MathFloor(lots / legs / step) * step;
      if(each >= minLot)
      {
         lots = NormalizeDouble(each, 2);
         rs[0] = InpLeg1R;
         if(legs == 2) rs[1] = InpLeg3R;
         else { rs[1] = InpLeg2R; rs[2] = InpLeg3R; }
      }
      else legs = 1;                                   // too small to split
   }
   bool okAll = true;
   for(int i = 0; i < legs; i++)
   {
      double tp = e + rs[i] * dist;
      double tpR = NormalizeDouble(dir * tp, _Digits);
      string cm = StringFormat("SB|%.2f", rs[i]);
      bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, slR, tpR, cm)
                          : trade.Sell(lots, _Symbol, 0.0, slR, tpR, cm);
      if(!ok) okAll = false;
   }
   if(okAll) { cEntry++; lastWin[di] = wkey; }
   return okAll;
}

//--- move the stop of open legs to break-even once price has travelled BeTriggerR x risk
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
         double dist = (tp - open) / rmul;
         if(sl < open - _Point && bid >= open + InpBeTriggerR * dist)
            trade.PositionModify(ticket, NormalizeDouble(open + InpBeOffset, _Digits), tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double dist = (open - tp) / rmul;
         if(sl > open + _Point && ask <= open - InpBeTriggerR * dist)
            trade.PositionModify(ticket, NormalizeDouble(open - InpBeOffset, _Digits), tp);
      }
   }
}

void OnTick()
{
   if(InpMoveBE) ManageBE();
   datetime bt = iTime(_Symbol, InpTF, 0);
   if(bt == lastBar) return;
   lastBar = bt;
   if(HasOpenPosition()) return;
   if(InpAllowLong && TrySetup(1)) return;
   if(InpAllowShort) TrySetup(-1);
}
