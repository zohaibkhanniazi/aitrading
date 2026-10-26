//+------------------------------------------------------------------+
//|  Pullback_XAUUSD.mq5 (v1) -- trend pullback, any timeframe        |
//|                                                                  |
//|  Trend  : on InpTrendTF, close > EMA50 > EMA200 = up (mirror down)|
//|  Pullback (chart TF): within the last N candles price touched    |
//|           the EMA20, but no candle closed below the EMA50.        |
//|  Trigger: a bullish candle closes above the previous candle's    |
//|           high and back above the EMA20 -> BUY at next open.     |
//|  Stop   : below the pullback low (lowest low of last N candles). |
//|  Cost guard: stop must be >= InpMinStopSpreads x spread, so the  |
//|           spread never eats more than ~1/8 of the risk (M1!).    |
//|  Sells are the mirror image.                                     |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Trend"
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H1;  // higher timeframe that sets the direction
input int    InpTrendFast   = 50;
input int    InpTrendSlow   = 200;
input group "Pullback"
input int    InpPullEma     = 20;     // EMA the pullback must touch
input int    InpSupportEma  = 50;     // no close beyond this EMA during the pullback
input int    InpPullBars    = 10;     // candles searched for the touch
input group "Session (server time = GMT)"
input bool   InpUseSession  = true;
input int    InpStartHour   = 7;      // London open
input int    InpEndHour     = 20;     // NY afternoon
input group "Risk"
input double InpRiskPercent = 1.0;
input double InpRR          = 2.0;
input bool   InpMoveBE      = false;
input double InpBeTriggerR  = 1.0;
input double InpStopBuffer  = 0.10;
input double InpMinStop     = 0.80;
input double InpMinStopSpreads = 8.0; // stop must be at least this many spreads
input double InpMaxStop     = 30.0;
input double InpMaxSpread   = 0.60;
input bool   InpAllowLong   = true;
input bool   InpAllowShort  = true;
input ulong  InpMagic       = 20261160;
input int    InpDeviation   = 30;

CTrade   trade;
int      hTF = INVALID_HANDLE, hTS = INVALID_HANDLE, hPull = INVALID_HANDLE, hSup = INVALID_HANDLE;
datetime lastBar = 0;
int      cooldown = 0;
int      cBars = 0, cTrend = 0, cSig = 0, cCost = 0, cTrades = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hTF   = iMA(_Symbol, InpTrendTF, InpTrendFast, 0, MODE_EMA, PRICE_CLOSE);
   hTS   = iMA(_Symbol, InpTrendTF, InpTrendSlow, 0, MODE_EMA, PRICE_CLOSE);
   hPull = iMA(_Symbol, _Period, InpPullEma, 0, MODE_EMA, PRICE_CLOSE);
   hSup  = iMA(_Symbol, _Period, InpSupportEma, 0, MODE_EMA, PRICE_CLOSE);
   if(hTF == INVALID_HANDLE || hTS == INVALID_HANDLE || hPull == INVALID_HANDLE || hSup == INVALID_HANDLE) return INIT_FAILED;
   PrintFormat("Pullback EA started on %s %s, trend TF %s", _Symbol, EnumToString(_Period), EnumToString(InpTrendTF));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FUNNEL bars=%d trendOk=%d signals=%d costBlocked=%d trades=%d", cBars, cTrend, cSig, cCost, cTrades);
   if(hTF != INVALID_HANDLE) IndicatorRelease(hTF);
   if(hTS != INVALID_HANDLE) IndicatorRelease(hTS);
   if(hPull != INVALID_HANDLE) IndicatorRelease(hPull);
   if(hSup != INVALID_HANDLE) IndicatorRelease(hSup);
}

double Val(const int h, const int shift)
{
   double b[];
   ArraySetAsSeries(b, true);
   return (CopyBuffer(h, 0, shift, 1, b) == 1) ? b[0] : -1;
}

int Trend()
{
   double f = Val(hTF, 1), s = Val(hTS, 1);
   if(f < 0 || s < 0) return 0;
   double c = iClose(_Symbol, InpTrendTF, 1);
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

//--- pullback + trigger for direction dir; returns the pullback extreme in ext
bool Setup(const int dir, double &ext)
{
   int n = InpPullBars;
   double ep[], es[];
   ArraySetAsSeries(ep, true); ArraySetAsSeries(es, true);
   if(CopyBuffer(hPull, 0, 1, n, ep) != n || CopyBuffer(hSup, 0, 1, n, es) != n) return false;
   bool touched = false;
   ext = (dir > 0) ? DBL_MAX : -DBL_MAX;
   for(int i = 1; i <= n; i++)
   {
      double h = iHigh(_Symbol, _Period, i), l = iLow(_Symbol, _Period, i), c = iClose(_Symbol, _Period, i);
      if(dir > 0)
      {
         if(c < es[i-1]) return false;            // closed below the support EMA: trend broken
         if(l <= ep[i-1]) touched = true;
         ext = MathMin(ext, l);
      }
      else
      {
         if(c > es[i-1]) return false;
         if(h >= ep[i-1]) touched = true;
         ext = MathMax(ext, h);
      }
   }
   if(!touched) return false;
   double o1 = iOpen(_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   if(dir > 0) return (c1 > o1 && c1 > iHigh(_Symbol, _Period, 2) && c1 > ep[0]);
   return (c1 < o1 && c1 < iLow(_Symbol, _Period, 2) && c1 < ep[0]);
}

void OnTick()
{
   if(InpMoveBE) ManageBE();
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == lastBar) return;
   lastBar = bt;
   cBars++;
   if(cooldown > 0) cooldown--;
   if(HasOpenPosition() || cooldown > 0) return;
   if(InpUseSession)
   {
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;
   }
   int tr = Trend();
   if(tr == 0) return;
   if(tr > 0 && !InpAllowLong) return;
   if(tr < 0 && !InpAllowShort) return;
   cTrend++;
   double ext;
   if(!Setup(tr, ext)) return;
   cSig++;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = ask - bid;
   if(spread > InpMaxSpread) return;
   double entry = (tr > 0) ? ask : bid;
   double sl = (tr > 0) ? ext - InpStopBuffer : ext + InpStopBuffer;
   double dist = (tr > 0) ? entry - sl : sl - entry;
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return;
   if(dist < InpMinStopSpreads * spread) { cCost++; return; }
   double lots = CalcLots(dist);
   if(lots <= 0) return;
   double tp = entry + tr * InpRR * dist;
   bool ok = (tr > 0) ? trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "PB")
                      : trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "PB");
   if(ok) { cTrades++; cooldown = InpPullBars; }
}
//+------------------------------------------------------------------+
