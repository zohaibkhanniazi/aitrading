//+------------------------------------------------------------------+
//|  MtfFractal_XAUUSD.mq5 (v1) -- analyse high, enter low            |
//|                                                                  |
//|  H4  direction : close > EMA50 > EMA200 = buys only (mirror)     |
//|  H1  level     : an H1 candle closes above the latest H1 fractal |
//|                  high (the proven H1 breakout). The broken level |
//|                  becomes the zone. Target = where the H1 trade   |
//|                  would aim: breakout close + 2 x H1 risk.        |
//|  M15 entry     : price pulls back to the zone, then an M15 candle|
//|  (chart TF)      closes above the latest M15 fractal high (turn  |
//|                  back up) -> BUY. Stop below the pullback low.   |
//|  Cancel        : H1-stop level broken, target reached first, or  |
//|                  no entry within InpExpiryBars H1 candles.       |
//|  Attach to the ENTRY timeframe chart (M15 or M5).                |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Timeframes"
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H4;  // direction
input ENUM_TIMEFRAMES InpLevelTF = PERIOD_H1;  // levels (fractal breakout)
input int    InpEmaFast     = 50;
input int    InpEmaSlow     = 200;
input group "Zone"
input double InpTgtR        = 2.0;    // target = H1 breakout close + this x H1 risk
input double InpZoneAtr     = 0.25;   // pullback must come within this x ATR(H1) of the broken level
input int    InpExpiryBars  = 24;     // H1 candles a zone stays alive
input int    InpLookback    = 100;    // candles searched for fractals
input group "Exits"
input int    InpTpMode      = 0;      // 0 = H1 target, 1 = fixed RR on the small stop
input double InpRR          = 3.0;    // used when InpTpMode = 1
input double InpMinRR       = 1.5;    // skip if the target is less than this x the stop
input group "Risk"
input double InpRiskPercent = 1.0;
input double InpStopBuffer  = 0.10;
input double InpMinStop     = 0.80;
input double InpMinStopSpreads = 6.0; // stop must be at least this many spreads
input double InpMaxStop     = 30.0;
input double InpMaxSpread   = 0.60;
input bool   InpAllowLong   = true;
input bool   InpAllowShort  = true;
input ulong  InpMagic       = 20261200;
input int    InpDeviation   = 30;

CTrade   trade;
int      hF = INVALID_HANDLE, hS = INVALID_HANDLE, hAtrH = INVALID_HANDLE;
datetime lastBar = 0, lastLvlBar = 0, usedUp = 0, usedDn = 0;
int      zSt[2];
double   zLvl[2], zRef[2], zTgt[2];
datetime zBorn[2], zTouch[2];
int      cZone = 0, cTouch = 0, cTrig = 0, cRR = 0, cTrades = 0, cExp = 0, cInv = 0, cMiss = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hF    = iMA(_Symbol, InpTrendTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hS    = iMA(_Symbol, InpTrendTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hAtrH = iATR(_Symbol, InpLevelTF, 14);
   if(hF == INVALID_HANDLE || hS == INVALID_HANDLE || hAtrH == INVALID_HANDLE) return INIT_FAILED;
   zSt[0] = zSt[1] = 0;
   if(PeriodSeconds(_Period) >= PeriodSeconds(InpLevelTF)) Print("WARNING: attach to a timeframe below the level timeframe (e.g. M15)");
   PrintFormat("MtfFractal started on %s: trend %s, levels %s, entry %s", _Symbol,
               EnumToString(InpTrendTF), EnumToString(InpLevelTF), EnumToString(_Period));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FUNNEL zones=%d touched=%d triggers=%d rrSkip=%d trades=%d expired=%d invalid=%d targetFirst=%d",
               cZone, cTouch, cTrig, cRR, cTrades, cExp, cInv, cMiss);
   if(hF != INVALID_HANDLE) IndicatorRelease(hF);
   if(hS != INVALID_HANDLE) IndicatorRelease(hS);
   if(hAtrH != INVALID_HANDLE) IndicatorRelease(hAtrH);
}

double Val(const int h, const int shift)
{
   double b[];
   ArraySetAsSeries(b, true);
   return (CopyBuffer(h, 0, shift, 1, b) == 1) ? b[0] : -1;
}

//--- latest fractal on tf confirmed by candle 2 of that tf. kind +1 = high, -1 = low
bool Fract(const ENUM_TIMEFRAMES tf, const int kind, double &level, datetime &when)
{
   for(int k = 4; k <= InpLookback; k++)
   {
      if(kind > 0)
      {
         double h = iHigh(_Symbol, tf, k);
         if(h > iHigh(_Symbol, tf, k - 1) && h > iHigh(_Symbol, tf, k - 2) && h > iHigh(_Symbol, tf, k + 1) && h > iHigh(_Symbol, tf, k + 2))
         { level = h; when = iTime(_Symbol, tf, k); return true; }
      }
      else
      {
         double l = iLow(_Symbol, tf, k);
         if(l < iLow(_Symbol, tf, k - 1) && l < iLow(_Symbol, tf, k - 2) && l < iLow(_Symbol, tf, k + 1) && l < iLow(_Symbol, tf, k + 2))
         { level = l; when = iTime(_Symbol, tf, k); return true; }
      }
   }
   return false;
}

int Trend()
{
   double f = Val(hF, 1), s = Val(hS, 1);
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

//--- a new H1 candle closed: look for an H1 fractal breakout in the H4 direction
void OnLevelBar()
{
   int tr = Trend();
   if(tr == 0) return;
   double up, dn; datetime tu, td;
   if(!Fract(InpLevelTF, 1, up, tu) || !Fract(InpLevelTF, -1, dn, td)) return;
   double c1 = iClose(_Symbol, InpLevelTF, 1), c2 = iClose(_Symbol, InpLevelTF, 2);
   datetime now = iTime(_Symbol, InpLevelTF, 0);
   if(tr == 1 && InpAllowLong && c1 > up && c2 <= up && tu != usedUp && dn < c1)
   {
      zSt[0] = 1; zLvl[0] = up; zRef[0] = dn; zTgt[0] = c1 + InpTgtR * (c1 - dn);
      zBorn[0] = now; zTouch[0] = 0; usedUp = tu; cZone++;
   }
   if(tr == -1 && InpAllowShort && c1 < dn && c2 >= dn && td != usedDn && up > c1)
   {
      zSt[1] = 1; zLvl[1] = dn; zRef[1] = up; zTgt[1] = c1 - InpTgtR * (up - c1);
      zBorn[1] = now; zTouch[1] = 0; usedDn = td; cZone++;
   }
}

//--- a new entry-timeframe candle closed: manage the zone of direction dir
void OnEntryBar(const int dir, const double atrH)
{
   int s = (dir > 0) ? 0 : 1;
   if(zSt[s] != 1) return;
   if(iBarShift(_Symbol, InpLevelTF, zBorn[s]) > InpExpiryBars) { zSt[s] = 0; cExp++; return; }
   double h1 = iHigh(_Symbol, _Period, 1), l1 = iLow(_Symbol, _Period, 1);
   double c1 = iClose(_Symbol, _Period, 1), c2 = iClose(_Symbol, _Period, 2);

   if(dir > 0)
   {
      if(c1 < zRef[s])     { zSt[s] = 0; cInv++;  return; }    // pullback broke the H1 stop level
      if(h1 >= zTgt[s])    { zSt[s] = 0; cMiss++; return; }    // ran to target without us
      if(zTouch[s] == 0 && l1 <= zLvl[s] + InpZoneAtr * atrH) { zTouch[s] = iTime(_Symbol, _Period, 1); cTouch++; }
   }
   else
   {
      if(c1 > zRef[s])     { zSt[s] = 0; cInv++;  return; }
      if(l1 <= zTgt[s])    { zSt[s] = 0; cMiss++; return; }
      if(zTouch[s] == 0 && h1 >= zLvl[s] - InpZoneAtr * atrH) { zTouch[s] = iTime(_Symbol, _Period, 1); cTouch++; }
   }
   if(zTouch[s] == 0) return;

   // entry-TF turn: close through the latest entry-TF fractal formed after the H1 breakout
   double fx; datetime ft;
   if(!Fract(_Period, dir > 0 ? 1 : -1, fx, ft) || ft < zBorn[s]) return;
   if(dir > 0 && !(c1 > fx && c2 <= fx)) return;
   if(dir < 0 && !(c1 < fx && c2 >= fx)) return;
   cTrig++;
   if(HasOpenPosition()) return;

   int k = iBarShift(_Symbol, _Period, zTouch[s]);           // candles since the touch
   if(k < 1) k = 1;
   double ext = (dir > 0) ? iLow(_Symbol, _Period, iLowest(_Symbol, _Period, MODE_LOW, k, 1))
                          : iHigh(_Symbol, _Period, iHighest(_Symbol, _Period, MODE_HIGH, k, 1));
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = ask - bid;
   if(spread > InpMaxSpread) return;
   double entry = (dir > 0) ? ask : bid;
   double sl = ext - dir * InpStopBuffer;
   double dist = dir * (entry - sl);
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel || dist < InpMinStopSpreads * spread) return;
   double tp = (InpTpMode == 0) ? zTgt[s] : entry + dir * InpRR * dist;
   double rr = dir * (tp - entry) / dist;
   zSt[s] = 0;                                               // one attempt per zone
   if(rr < InpMinRR) { cRR++; return; }
   double lots = CalcLots(dist);
   if(lots <= 0) return;
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "MTF")
                       : trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "MTF");
   if(ok) { cTrades++; PrintFormat("%s rr=%.2f stop=%.2f level=%.2f target=%.2f", (dir > 0 ? "BUY" : "SELL"), rr, dist, zLvl[s], tp); }
}

void OnTick()
{
   datetime lb = iTime(_Symbol, InpLevelTF, 0);
   if(lb != lastLvlBar) { lastLvlBar = lb; OnLevelBar(); }
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == lastBar) return;
   lastBar = bt;
   double atrH = Val(hAtrH, 1);
   if(atrH <= 0) return;
   OnEntryBar( 1, atrH);
   OnEntryBar(-1, atrH);
}
//+------------------------------------------------------------------+
