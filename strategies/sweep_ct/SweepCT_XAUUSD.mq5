//+------------------------------------------------------------------+
//|  SweepCT_XAUUSD.mq5 (v1) -- Sweep & Close-Through (owner's rule)  |
//|                                                                  |
//|  SELL: a green candle takes (sweeps or breaks) the high of the   |
//|        most recent red candle (within InpLookback candles), then |
//|        a later candle closes its body below that red candle      |
//|        (its low, or its close if InpLevelMode = 1) -> sell at    |
//|        the next open.                                            |
//|  Cancel: a candle closes above the sweep high (structure broken) |
//|        or InpExpiry candles pass. A newer sweep replaces the     |
//|        older setup (latest scenario only).                       |
//|  BUY : mirror image.                                             |
//|  Stop beyond the sweep extreme + buffer x ATR, target InpRR.     |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Pattern"
input int    InpLookback    = 3;      // red/green candle searched within this many candles before the sweep
input int    InpSweepMode   = 0;      // 0 = sweep or break, 1 = sweep only (close back inside), 2 = break only (close beyond)
input int    InpLevelMode   = 0;      // 0 = close beyond the candle's low/high, 1 = beyond its body (close)
input int    InpExpiry      = 20;     // candles a setup stays alive
input group "Trade"
input double InpRR          = 2.0;
input double InpSlBufAtr    = 0.10;
input double InpRiskPercent = 1.0;
input double InpMinStop     = 0.80;
input double InpMinStopSpreads = 6.0;
input double InpMaxStop     = 30.0;
input double InpMaxSpread   = 0.60;
input bool   InpAllowLong   = true;
input bool   InpAllowShort  = true;
input ulong  InpMagic       = 20261240;
input int    InpDeviation   = 30;

struct Setup
{
   bool     act;
   double   lvl, ext;
   datetime born;
};

CTrade   trade;
Setup    sSell, sBuy;
int      hAtr = INVALID_HANDLE;
datetime lastBar = 0;
int      cNew = 0, cReplaced = 0, cTrig = 0, cCancel = 0, cExpire = 0, cTrades = 0, cSkip = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hAtr = iATR(_Symbol, _Period, 14);
   if(hAtr == INVALID_HANDLE) return INIT_FAILED;
   ZeroMemory(sSell); ZeroMemory(sBuy);
   PrintFormat("SweepCT started on %s %s", _Symbol, EnumToString(_Period));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FUNNEL setups=%d replaced=%d triggered=%d cancelled=%d expired=%d trades=%d skipped=%d",
               cNew, cReplaced, cTrig, cCancel, cExpire, cTrades, cSkip);
   if(hAtr != INVALID_HANDLE) IndicatorRelease(hAtr);
}

double Atr()
{
   double b[]; ArraySetAsSeries(b, true);
   return (CopyBuffer(hAtr, 0, 1, 1, b) == 1) ? b[0] : 0;
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

//--- offset of the most recent red (wantRed) or green candle among candles 2..1+InpLookback
int FindCandle(const bool wantRed)
{
   for(int i = 2; i <= 1 + InpLookback; i++)
   {
      double o = iOpen(_Symbol, _Period, i), c = iClose(_Symbol, _Period, i);
      if(wantRed ? c < o : c > o) return i;
   }
   return -1;
}

bool ModeOk(const bool closedBeyond)
{
   if(InpSweepMode == 1) return !closedBeyond;
   if(InpSweepMode == 2) return closedBeyond;
   return true;
}

void Enter(const int dir, const double ext)
{
   if(dir > 0 && !InpAllowLong) return;
   if(dir < 0 && !InpAllowShort) return;
   if(HasOpenPosition()) { cSkip++; return; }
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = ask - bid;
   if(spread > InpMaxSpread) { cSkip++; return; }
   double atr = Atr();
   if(atr <= 0) return;
   double entry = (dir > 0) ? ask : bid;
   double sl = ext - dir * InpSlBufAtr * atr;
   double dist = dir * (entry - sl);
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel || dist < InpMinStopSpreads * spread) { cSkip++; return; }
   double lots = CalcLots(dist);
   if(lots <= 0) { cSkip++; return; }
   double tp = entry + dir * InpRR * dist;
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "SCT")
                       : trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "SCT");
   if(ok) cTrades++;
}

void OnTick()
{
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == lastBar) return;
   lastBar = bt;
   if(iBars(_Symbol, _Period) < InpLookback + 20) return;

   double o1 = iOpen(_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   double h1 = iHigh(_Symbol, _Period, 1), l1 = iLow(_Symbol, _Period, 1);
   datetime t1 = iTime(_Symbol, _Period, 1);
   int age;
   bool sellSig = false, buySig = false;
   double sellExt = 0, buyExt = 0;

   // 1. existing setups: trigger, cancel or keep waiting
   if(sSell.act)
   {
      age = iBarShift(_Symbol, _Period, sSell.born) - 1;
      if(c1 < sSell.lvl)        { sellSig = true; sellExt = MathMax(sSell.ext, h1); sSell.act = false; cTrig++; }
      else if(c1 > sSell.ext)   { sSell.act = false; cCancel++; }
      else if(age > InpExpiry)  { sSell.act = false; cExpire++; }
      else                       sSell.ext = MathMax(sSell.ext, h1);
   }
   if(sBuy.act)
   {
      age = iBarShift(_Symbol, _Period, sBuy.born) - 1;
      if(c1 > sBuy.lvl)         { buySig = true; buyExt = MathMin(sBuy.ext, l1); sBuy.act = false; cTrig++; }
      else if(c1 < sBuy.ext)    { sBuy.act = false; cCancel++; }
      else if(age > InpExpiry)  { sBuy.act = false; cExpire++; }
      else                       sBuy.ext = MathMin(sBuy.ext, l1);
   }

   // 2. new setup on the candle that just closed (latest scenario replaces the older one)
   if(c1 > o1 && !sellSig)
   {
      int r = FindCandle(true);
      if(r > 0)
      {
         double rh = iHigh(_Symbol, _Period, r);
         if(h1 > rh && ModeOk(c1 > rh))
         {
            if(sSell.act) cReplaced++;
            sSell.act = true; sSell.ext = h1; sSell.born = t1; cNew++;
            sSell.lvl = (InpLevelMode == 0) ? iLow(_Symbol, _Period, r) : iClose(_Symbol, _Period, r);
         }
      }
   }
   if(c1 < o1 && !buySig)
   {
      int g = FindCandle(false);
      if(g > 0)
      {
         double gl = iLow(_Symbol, _Period, g);
         if(l1 < gl && ModeOk(c1 < gl))
         {
            if(sBuy.act) cReplaced++;
            sBuy.act = true; sBuy.ext = l1; sBuy.born = t1; cNew++;
            sBuy.lvl = (InpLevelMode == 0) ? iHigh(_Symbol, _Period, g) : iClose(_Symbol, _Period, g);
         }
      }
   }

   // 3. entries at this candle's open
   if(sellSig) Enter(-1, sellExt);
   if(buySig)  Enter(1, buyExt);
}
//+------------------------------------------------------------------+
