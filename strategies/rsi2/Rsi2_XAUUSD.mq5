//+------------------------------------------------------------------+
//|  Rsi2_XAUUSD.mq5 (v1) -- RSI(2) mean reversion (Connors style)    |
//|                                                                  |
//|  Trend : close above SMA200 = only buys, below = only sells.     |
//|  Entry : RSI(2) closes below 10 (buy the dip) / above 90 (sell   |
//|          the rally) -> market order at the next candle open.     |
//|  Exit  : candle closes back above SMA5 (buy) / below SMA5 (sell) |
//|          -> close at the next open. Small, frequent wins.        |
//|  Safety: protective stop at InpStopAtr x ATR(14) (sizing uses    |
//|          it: 1% risk = loss if the stop is hit), time stop after |
//|          InpMaxBars candles.                                     |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Signal"
input int    InpRsiPeriod   = 2;
input double InpRsiBuy      = 10.0;   // buy when RSI below this
input double InpRsiSell     = 90.0;   // sell when RSI above this
input bool   InpUseTrend    = true;
input int    InpTrendSma    = 200;
input int    InpExitSma     = 5;
input group "Exits"
input double InpStopAtr     = 3.0;    // protective stop distance (x ATR 14)
input int    InpMaxBars     = 20;     // close after this many candles (0 = off)
input group "Risk"
input double InpRiskPercent = 1.0;    // risk to the protective stop
input double InpMinStop     = 0.80;
input double InpMaxStop     = 100.0;
input double InpMaxSpread   = 0.60;
input bool   InpAllowLong   = true;
input bool   InpAllowShort  = true;
input ulong  InpMagic       = 20261190;
input int    InpDeviation   = 30;

CTrade   trade;
int      hRsi = INVALID_HANDLE, hTrend = INVALID_HANDLE, hExit = INVALID_HANDLE, hAtr = INVALID_HANDLE;
datetime lastBar = 0;
int      cSig = 0, cTrades = 0, cExitSma = 0, cExitTime = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hRsi   = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   hTrend = iMA(_Symbol, _Period, InpTrendSma, 0, MODE_SMA, PRICE_CLOSE);
   hExit  = iMA(_Symbol, _Period, InpExitSma, 0, MODE_SMA, PRICE_CLOSE);
   hAtr   = iATR(_Symbol, _Period, 14);
   if(hRsi == INVALID_HANDLE || hTrend == INVALID_HANDLE || hExit == INVALID_HANDLE || hAtr == INVALID_HANDLE) return INIT_FAILED;
   PrintFormat("RSI2 EA started on %s %s", _Symbol, EnumToString(_Period));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FUNNEL signals=%d trades=%d exitSma=%d exitTime=%d", cSig, cTrades, cExitSma, cExitTime);
   if(hRsi   != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hTrend != INVALID_HANDLE) IndicatorRelease(hTrend);
   if(hExit  != INVALID_HANDLE) IndicatorRelease(hExit);
   if(hAtr   != INVALID_HANDLE) IndicatorRelease(hAtr);
}

double Val(const int h, const int shift)
{
   double b[];
   ArraySetAsSeries(b, true);
   return (CopyBuffer(h, 0, shift, 1, b) == 1) ? b[0] : -1;
}

ulong MyPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic) return t;
   }
   return 0;
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

void OnTick()
{
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == lastBar) return;
   lastBar = bt;

   double c1 = iClose(_Symbol, _Period, 1);
   double sma5 = Val(hExit, 1);
   if(sma5 <= 0) return;

   // ---- manage the open trade (exits are decided on candle close)
   ulong t = MyPosition();
   if(t > 0)
   {
      long type = PositionGetInteger(POSITION_TYPE);
      int held = iBarShift(_Symbol, _Period, (datetime)PositionGetInteger(POSITION_TIME));
      bool smaExit  = (type == POSITION_TYPE_BUY) ? (c1 > sma5) : (c1 < sma5);
      bool timeExit = (InpMaxBars > 0 && held >= InpMaxBars);
      if(smaExit || timeExit)
      {
         if(trade.PositionClose(t)) { if(smaExit) cExitSma++; else cExitTime++; }
      }
      return;
   }

   // ---- new entry
   double rsi = Val(hRsi, 1), trend = Val(hTrend, 1), atr = Val(hAtr, 1);
   if(rsi < 0 || trend <= 0 || atr <= 0) return;
   int dir = 0;
   if(InpAllowLong  && rsi < InpRsiBuy  && (!InpUseTrend || c1 > trend)) dir = 1;
   if(InpAllowShort && rsi > InpRsiSell && (!InpUseTrend || c1 < trend)) dir = -1;
   if(dir == 0) return;
   cSig++;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((ask - bid) > InpMaxSpread) return;
   double dist = InpStopAtr * atr;
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return;
   double lots = CalcLots(dist);
   if(lots <= 0) return;
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(ask - dist, _Digits), 0.0, "R2")
                       : trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(bid + dist, _Digits), 0.0, "R2");
   if(ok) cTrades++;
}
//+------------------------------------------------------------------+
