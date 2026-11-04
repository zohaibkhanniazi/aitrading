//+------------------------------------------------------------------+
//|  PoiEntry_XAUUSD.mq5 (v1) -- same model as ICT Toolkit v2 (Pine)  |
//|                                                                  |
//|  POI (InpPoiTF, default H1), checked when a POI candle closes:   |
//|    bullish FVG = low of candle 1 above high of candle 3.         |
//|    OB + FVG    = candle 3 is a down candle -> zone = its range.  |
//|    FVG         = the gap itself. (Bearish = mirror image.)       |
//|  Entry (chart timeframe):                                        |
//|    1. price trades into the POI                                  |
//|    2. internal structure (swing length InpSwingLen) breaks in    |
//|       the POI direction: CHoCH (or BOS/CHoCH)                    |
//|    3. enter at market; stop beyond the pullback extreme (or the  |
//|       POI far edge) + buffer x ATR; target InpRR x risk.         |
//|  POI dies when a candle closes beyond its far edge or after      |
//|  InpPoiLife POI candles. One attempt per POI.                    |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "POI (higher timeframe)"
input ENUM_TIMEFRAMES InpPoiTF = PERIOD_H1;
input int    InpPoiType     = 0;      // 0 = OB + FVG, 1 = FVG, 2 = both
input int    InpPoiLife     = 48;     // POI expires after this many POI candles
input int    InpMaxPoi      = 8;
input group "Entry (chart timeframe)"
input int    InpSwingLen    = 3;      // swing length for BOS / CHoCH (3 = Pine internal, 10 = external)
input int    InpConfirm     = 0;      // 0 = CHoCH only, 1 = BOS or CHoCH
input int    InpStopMode    = 0;      // 0 = beyond the pullback extreme, 1 = beyond the POI far edge
input double InpSlBufAtr    = 0.10;   // stop buffer (x ATR 14, chart timeframe)
input double InpRR          = 3.0;
input int    InpMaxOpen     = 3;      // max simultaneous trades
input group "Risk"
input double InpRiskPercent = 1.0;
input double InpMinStop     = 0.80;
input double InpMinStopSpreads = 6.0;
input double InpMaxStop     = 30.0;
input double InpMaxSpread   = 0.60;
input bool   InpAllowLong   = true;
input bool   InpAllowShort  = true;
input ulong  InpMagic       = 20261210;
input int    InpDeviation   = 30;

struct Poi
{
   double   top, bot, ext;
   int      dir, state;
   datetime born;
};

CTrade   trade;
Poi      pois[];
int      hAtr = INVALID_HANDLE;
datetime lastBar = 0, lastPoiBar = 0;
double   hiP = 0, loP = 0;
bool     hiBroken = true, loBroken = true;
int      trend = 0;
int      cPoi = 0, cTouch = 0, cConf = 0, cTrades = 0, cKill = 0, cExp = 0, cSkip = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hAtr = iATR(_Symbol, _Period, 14);
   if(hAtr == INVALID_HANDLE) return INIT_FAILED;
   ArrayResize(pois, 0);
   PrintFormat("PoiEntry started on %s: POI %s, entry %s", _Symbol, EnumToString(InpPoiTF), EnumToString(_Period));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FUNNEL pois=%d touched=%d confirmed=%d trades=%d skipped=%d killed=%d expired=%d",
               cPoi, cTouch, cConf, cTrades, cSkip, cKill, cExp);
   if(hAtr != INVALID_HANDLE) IndicatorRelease(hAtr);
}

double Atr()
{
   double b[]; ArraySetAsSeries(b, true);
   return (CopyBuffer(hAtr, 0, 1, 1, b) == 1) ? b[0] : 0;
}

int CountOpen()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic) n++;
   }
   return n;
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

void AddPoi(const int dir, const double top, const double bot)
{
   if(dir > 0 && !InpAllowLong) return;
   if(dir < 0 && !InpAllowShort) return;
   int n = ArraySize(pois);
   ArrayResize(pois, n + 1);
   pois[n].top = top; pois[n].bot = bot; pois[n].dir = dir;
   pois[n].state = 0; pois[n].ext = 0; pois[n].born = iTime(_Symbol, _Period, 0);
   cPoi++;
   if(ArraySize(pois) > InpMaxPoi) ArrayRemove(pois, 0, 1);
}

//--- a POI-timeframe candle just closed: candles 1..3 of that timeframe
void CheckNewPoi()
{
   double l1 = iLow(_Symbol, InpPoiTF, 1), h1 = iHigh(_Symbol, InpPoiTF, 1);
   double l3 = iLow(_Symbol, InpPoiTF, 3), h3 = iHigh(_Symbol, InpPoiTF, 3);
   double o3 = iOpen(_Symbol, InpPoiTF, 3), c3 = iClose(_Symbol, InpPoiTF, 3);
   if(l1 <= 0 || l3 <= 0) return;
   if(l1 > h3)                                    // bullish FVG
   {
      if(InpPoiType != 0) AddPoi(1, l1, h3);
      if(InpPoiType != 1 && c3 < o3) AddPoi(1, h3, l3);
   }
   if(h1 < l3)                                    // bearish FVG
   {
      if(InpPoiType != 0) AddPoi(-1, l3, h1);
      if(InpPoiType != 1 && c3 > o3) AddPoi(-1, h3, l3);
   }
}

//--- chart-timeframe structure: new swings, then BOS (+-1) / CHoCH (+-2) on the candle that just closed
int Structure()
{
   int L = InpSwingLen, k = L + 1;
   double hk = iHigh(_Symbol, _Period, k), lk = iLow(_Symbol, _Period, k);
   bool ph = true, pl = true;
   for(int j = 1; j <= L; j++)
   {
      if(iHigh(_Symbol, _Period, k - j) >= hk || iHigh(_Symbol, _Period, k + j) >= hk) ph = false;
      if(iLow(_Symbol, _Period, k - j)  <= lk || iLow(_Symbol, _Period, k + j)  <= lk) pl = false;
   }
   if(ph) { hiP = hk; hiBroken = false; }
   if(pl) { loP = lk; loBroken = false; }

   double c1 = iClose(_Symbol, _Period, 1);
   int res = 0;
   if(!hiBroken && c1 > hiP)      { hiBroken = true; res = (trend == -1) ? 2 : 1;   trend = 1; }
   else if(!loBroken && c1 < loP) { loBroken = true; res = (trend == 1)  ? -2 : -1; trend = -1; }
   return res;
}

void Enter(const int dir, const Poi &p)
{
   if(CountOpen() >= InpMaxOpen) { cSkip++; return; }
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = ask - bid;
   if(spread > InpMaxSpread) { cSkip++; return; }
   double atr = Atr();
   if(atr <= 0) return;
   double entry = (dir > 0) ? ask : bid;
   double sl;
   if(InpStopMode == 0) sl = p.ext - dir * InpSlBufAtr * atr;
   else                 sl = (dir > 0) ? p.bot - InpSlBufAtr * atr : p.top + InpSlBufAtr * atr;
   double dist = dir * (entry - sl);
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel || dist < InpMinStopSpreads * spread) { cSkip++; return; }
   double lots = CalcLots(dist);
   if(lots <= 0) { cSkip++; return; }
   double tp = entry + dir * InpRR * dist;
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "POI")
                       : trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "POI");
   if(ok) { cTrades++; PrintFormat("%s stop=%.2f zone %.2f-%.2f", (dir > 0 ? "BUY" : "SELL"), dist, p.bot, p.top); }
}

void ProcessPois(const int res)
{
   double h1 = iHigh(_Symbol, _Period, 1), l1 = iLow(_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   datetime now = iTime(_Symbol, _Period, 0);
   for(int i = ArraySize(pois) - 1; i >= 0; i--)
   {
      int  d = pois[i].dir;
      bool remove = false;
      if(now - pois[i].born > (long)InpPoiLife * PeriodSeconds(InpPoiTF)) { remove = true; cExp++; }
      else if(d > 0 ? c1 < pois[i].bot : c1 > pois[i].top)               { remove = true; cKill++; }
      else
      {
         if(pois[i].state == 0 && (d > 0 ? l1 <= pois[i].top : h1 >= pois[i].bot))
         {
            pois[i].state = 1; pois[i].ext = (d > 0) ? l1 : h1; cTouch++;
         }
         if(pois[i].state == 1)
         {
            pois[i].ext = (d > 0) ? MathMin(pois[i].ext, l1) : MathMax(pois[i].ext, h1);
            bool conf = (InpConfirm == 0) ? (res == 2 * d) : (res == d || res == 2 * d);
            if(conf) { cConf++; Enter(d, pois[i]); remove = true; }
         }
      }
      if(remove) ArrayRemove(pois, i, 1);
   }
}

void OnTick()
{
   datetime pb = iTime(_Symbol, InpPoiTF, 0);
   bool newPoiBar = (pb != lastPoiBar);
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == lastBar && !newPoiBar) return;
   if(newPoiBar)
   {
      bool first = (lastPoiBar == 0);
      lastPoiBar = pb;
      if(!first) CheckNewPoi();
   }
   if(bt == lastBar) return;
   lastBar = bt;
   int res = Structure();
   ProcessPois(res);
}
//+------------------------------------------------------------------+
