//+------------------------------------------------------------------+
//|  IndepPB_XAUUSD.mq5 (v1) -- Independent Candle Pullback, SELL only|
//|  Same rules as pine/Independent_Candle_PB.pine (owner's drawing): |
//|  1 = independent candle (own high/low); inside candles ignored.   |
//|  2 = red candle out of candle 1 (below its low) = pullback candle.|
//|  3 = first candle out of candle 2 takes its HIGH (sweep or close  |
//|      above) without taking its LOW = valid pullback.              |
//|  4 = a candle closes below candle 2's low -> SELL at next open.   |
//|  Stop = the pullback high (highest high since candle 3) + spread. |
//|  Cancel: close above the pullback high, or InpExpiry candles.     |
//|  Newest valid pullback replaces the older one.                    |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Pattern"
input bool   InpNeedLowBreak = true;   // candle 2 must go below candle 1's low
input bool   InpNeedGreen    = true;   // candle 3 must be green
input int    InpExpiry       = 30;     // candles a valid pullback stays alive
input group "Trade"
input double InpRR           = 2.0;    // target = entry - RR x stop distance
input double InpSlBufAtr     = 0.0;    // extra room above the pullback high (x ATR 14); spread is always added
input double InpRiskPercent  = 1.0;
input double InpMinStop      = 0.80;
input double InpMinStopSpreads = 6.0;
input double InpMaxStop      = 30.0;
input double InpMaxSpread    = 0.60;
input ulong  InpMagic        = 20261250;
input int    InpDeviation    = 30;

CTrade   trade;
int      hAtr = INVALID_HANDLE;
datetime lastBar = 0;
// independent (reference) candle
bool     refSet = false;
double   refH = 0, refL = 0;
// candidate candle 2
bool     cAct = false;
double   cH = 0, cL = 0;
// valid pullback
bool     vAct = false;
double   vLow = 0, vHigh = 0;
datetime vT3 = 0;
int      cInside = 0, cCand = 0, cValid = 0, cReplaced = 0, cSig = 0, cCancel = 0, cExpire = 0, cTrades = 0, cSkip = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hAtr = iATR(_Symbol, _Period, 14);
   if(hAtr == INVALID_HANDLE) return INIT_FAILED;
   PrintFormat("IndepPB (sell only) started on %s %s", _Symbol, EnumToString(_Period));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FUNNEL inside=%d candidates=%d valid=%d replaced=%d signals=%d cancelled=%d expired=%d trades=%d skipped=%d",
               cInside, cCand, cValid, cReplaced, cSig, cCancel, cExpire, cTrades, cSkip);
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

void Sell(const double pullbackHigh)
{
   if(HasOpenPosition()) { cSkip++; return; }
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = ask - bid;
   if(spread > InpMaxSpread) { cSkip++; return; }
   double sl = pullbackHigh + spread + InpSlBufAtr * Atr();
   double dist = sl - bid;
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel || dist < InpMinStopSpreads * spread) { cSkip++; return; }
   double lots = CalcLots(dist);
   if(lots <= 0) { cSkip++; return; }
   double tp = bid - InpRR * dist;
   if(trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "IPB"))
   {
      cTrades++;
      PrintFormat("SELL %.2f lots @ %.2f  SL %.2f (pullback high %.2f)  TP %.2f", lots, bid, sl, pullbackHigh, tp);
   }
}

void OnTick()
{
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == lastBar) return;
   lastBar = bt;
   double o1 = iOpen(_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   double h1 = iHigh(_Symbol, _Period, 1), l1 = iLow(_Symbol, _Period, 1);
   if(h1 <= 0) return;
   bool inside = refSet && h1 <= refH && l1 >= refL;
   if(inside) cInside++;

   // A. candle 4: close below candle 2's low (every candle)
   bool   sig = false;
   double pbHigh = 0;
   if(vAct)
   {
      int age = iBarShift(_Symbol, _Period, vT3) - 1;
      if(c1 < vLow)            { sig = true; pbHigh = MathMax(vHigh, h1); vAct = false; cSig++; }
      else if(c1 > vHigh)      { vAct = false; cCancel++; }
      else if(age > InpExpiry) { vAct = false; cExpire++; }
      else                       vHigh = MathMax(vHigh, h1);
   }

   // B. pattern built only from candles with their own high/low
   if(!inside)
   {
      if(cAct)
      {
         bool tH = h1 > cH, tL = l1 < cL;
         if(tH && !tL && (!InpNeedGreen || c1 > o1))
         {
            if(vAct) cReplaced++;
            vAct = true; vLow = cL; vHigh = h1; vT3 = iTime(_Symbol, _Period, 1); cValid++;
         }
         cAct = false;
      }
      if(c1 < o1 && refSet && (!InpNeedLowBreak || l1 < refL))
      {
         cAct = true; cH = h1; cL = l1; cCand++;
      }
      refSet = true; refH = h1; refL = l1;
   }

   // C. entry at this candle's open
   if(sig) Sell(pbHigh);
}
//+------------------------------------------------------------------+
