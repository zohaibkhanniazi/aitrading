//+------------------------------------------------------------------+
//|  SilverBulletLive_XAUUSD.mq5 (v1) LIVE-READY -- attach to an M5 chart
//|  Same logic as the tested research EA (single trade, 2R, stop to
//|  break-even at 1R) + safety features: kill switch, real-account
//|  confirmation, daily loss limit, min-lot guard, status panel.                       |
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
input int    InpSweepWithin  = 12;     // M5 bars before the FVG that may contain the sweep
input int    InpSweepLookback= 24;     // M5 bars of prior lows that must be taken out
input int    InpFvgSearch    = 10;     // how many recent bars to search for the FVG
input double InpFvgMinAtr    = 0.10;   // min FVG size (x M5 ATR)
input int    InpEntryMode    = 0;      // 0 = FVG edge, 1 = FVG midpoint
input int    InpSlMode       = 0;      // 0 = below FVG first candle low, 1 = below sweep low
input group "Safety"
input bool   InpEnableTrading    = true;   // master kill switch (false = no new trades, open trades still managed)
input bool   InpAllowRealAccount = false;  // must be set to true to run on a REAL account
input double InpDailyLossPct     = 3.0;    // stop opening trades for the day if equity falls this % from the day's start
input bool   InpAllowMinLot      = false;  // if risk-based lot is below the broker minimum: trade the minimum lot anyway
input double InpMaxRiskPctMinLot = 3.0;    // ...but only if that minimum lot risks no more than this % of equity
input double InpFixedLot         = 0.0;    // >0 = always trade this lot size (e.g. 0.01) instead of % risk
input double InpMaxRiskPctFixed  = 10.0;   // fixed-lot safety: skip the trade if its stop would lose more than this % of equity
input bool   InpShowPanel        = true;
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
input ulong  InpMagic        = 20261110;
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
   hAtr5 = iATR(_Symbol, PERIOD_M5, 14);
   if(hAtr5 == INVALID_HANDLE) return INIT_FAILED;
   lastWin[0] = 0; lastWin[1] = 0;
   if(_Period != PERIOD_M5) Print("WARNING: designed for an M5 chart");
   if(StringFind(_Symbol, "XAU") < 0) Print("WARNING: this EA was tested on gold (XAU) only. Symbol: ", _Symbol);
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL && !InpAllowRealAccount)
   {
      Print("REFUSED: this is a REAL account. Set InpAllowRealAccount = true in the inputs to confirm you want to trade it.");
      Comment("Silver Bullet LIVE: stopped.\nReal account detected. Set InpAllowRealAccount = true to confirm.");
      return INIT_FAILED;
   }
   PrintFormat("Silver Bullet LIVE started on %s | account mode %d | risk %.2f%% | legs %d | BE %d",
               _Symbol, (int)AccountInfoInteger(ACCOUNT_TRADE_MODE), InpRiskPercent, InpLegs, (int)InpMoveBE);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   if(hAtr5 != INVALID_HANDLE) IndicatorRelease(hAtr5);
   Comment("");
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
   if(InpFixedLot > 0)
   {
      double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tv <= 0) tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(ts <= 0 || tv <= 0) return 0.0;
      double lot = MathMax(InpFixedLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
      double lossMoney = (stopDistance / ts) * tv * lot;
      double pct = lossMoney / AccountInfoDouble(ACCOUNT_EQUITY) * 100.0;
      PrintFormat("Fixed lot %.2f: stop %.2f would lose %.2f %s = %.1f%% of equity", lot, stopDistance, lossMoney,
                  AccountInfoString(ACCOUNT_CURRENCY), pct);
      if(pct > InpMaxRiskPctFixed) { Print("SKIPPED: fixed-lot risk above InpMaxRiskPctFixed"); return 0.0; }
      return NormalizeDouble(lot, 2);
   }
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
   if(lots < minLot)
   {
      if(!InpAllowMinLot) return 0.0;
      double riskPct = lossPerLot * minLot / AccountInfoDouble(ACCOUNT_EQUITY) * 100.0;
      if(riskPct > InpMaxRiskPctMinLot) return 0.0;
      return minLot;
   }
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
   int wid = WindowId(iTime(_Symbol, PERIOD_M5, 0));
   if(wid == 0) return false;
   cWin++;

   int need = InpFvgSearch + InpSweepWithin + InpSweepLookback + 10;
   SBar m5[];
   int n = LoadBars(PERIOD_M5, need, dir, m5);
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
      PrintFormat("ORDER %s lots=%.2f sl=%.2f tp=%.2f ok=%d ret=%d %s", (dir > 0 ? "BUY" : "SELL"), lots, slR, tpR, (int)ok,
                  (int)trade.ResultRetcode(), trade.ResultRetcodeDescription());
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

//--- true if equity is down more than InpDailyLossPct since the start of the server day
bool DailyLossHit()
{
   int key = DayKey(TimeCurrent());
   string kk = "SBL_key_" + IntegerToString((long)InpMagic);
   string ke = "SBL_eq_"  + IntegerToString((long)InpMagic);
   if(!GlobalVariableCheck(kk) || (int)GlobalVariableGet(kk) != key)
   {
      GlobalVariableSet(kk, (double)key);
      GlobalVariableSet(ke, AccountInfoDouble(ACCOUNT_EQUITY));
   }
   double start = GlobalVariableGet(ke);
   return (start > 0 && AccountInfoDouble(ACCOUNT_EQUITY) < start * (1.0 - InpDailyLossPct / 100.0));
}

void ShowPanel()
{
   if(!InpShowPanel) return;
   int wid = WindowId(TimeCurrent());
   string win = (wid == 1 ? "London window" : (wid == 2 ? "NY AM window" : (wid == 3 ? "NY PM window" : "outside windows")));
   string st = !InpEnableTrading ? "DISABLED (kill switch)" : (DailyLossHit() ? "PAUSED: daily loss limit hit" : "ACTIVE");
   Comment("Silver Bullet LIVE\n",
           "Status: ", st, "\n",
           "Time now: ", win, "\n",
           "Equity: ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), " ", AccountInfoString(ACCOUNT_CURRENCY), "\n",
           "Open position: ", (HasOpenPosition() ? "yes" : "no"), "\n",
           "Risk/trade: ", DoubleToString(InpRiskPercent, 2), "%  |  Legs: ", InpLegs, "  |  BE: ", (InpMoveBE ? "on" : "off"));
}

void OnTick()
{
   if(InpMoveBE) ManageBE();                       // always manage open trades
   datetime bt = iTime(_Symbol, PERIOD_M5, 0);
   if(bt == lastBar) return;
   lastBar = bt;
   ShowPanel();
   if(!InpEnableTrading) return;
   if(HasOpenPosition()) return;
   if(DailyLossHit()) return;
   if(InpAllowLong && TrySetup(1)) return;
   if(InpAllowShort) TrySetup(-1);
}
