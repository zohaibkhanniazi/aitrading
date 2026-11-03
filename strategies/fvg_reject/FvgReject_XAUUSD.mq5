//+------------------------------------------------------------------+
//|  FvgReject_XAUUSD.mq5 (v1) -- failed retest of an FVG impulse     |
//|                                                                  |
//|  1 Impulse : aggressive candle (body >= InpBodyAtr x ATR) that    |
//|              leaves a fair value gap (>= InpFvgMinAtr x ATR).     |
//|              Consecutive impulse candles extend the move; the     |
//|              highest high of the move is the LEVEL.               |
//|  2 Retrace : price pulls back at least InpRetrace of the move.    |
//|              The level is now fixed.                              |
//|  3 Retest  : a candle reaches the level (mode 0: within           |
//|              InpTouchAtr x ATR, mode 1: wick above it) but its    |
//|              BODY stays below the level  -> SELL next open.       |
//|              A body close above the level cancels the setup.      |
//|              Price falling below the impulse start cancels it.    |
//|  Stop      : above the retest wick / level + buffer. Target 2R.   |
//|  Mirror    : aggressive drop, retest of the low that cannot       |
//|              close below it -> BUY.                               |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Setup"
input int    InpMode        = 0;      // 0 = touch the level, 1 = wick must go beyond the level (sweep)
input double InpBodyAtr     = 1.0;    // impulse candle body >= this x ATR(14)
input double InpFvgMinAtr   = 0.30;   // FVG size >= this x ATR(14)
input double InpRetrace     = 0.30;   // pullback needed before the retest (fraction of the move)
input double InpTouchAtr    = 0.20;   // mode 0: how close to the level counts as a touch (x ATR)
input int    InpMaxBars     = 100;    // setup expires after this many bars
input group "Exits"
input int    InpTpMode      = 0;      // 0 = fixed RR, 1 = impulse start (if it gives >= InpMinRR)
input double InpRR          = 2.0;
input double InpMinRR       = 1.0;
input bool   InpMoveBE      = false;
input double InpBeTriggerR  = 1.0;
input group "Risk"
input double InpRiskPercent = 1.0;
input double InpStopBuffer  = 0.10;
input double InpMinStop     = 0.80;
input double InpMaxStop     = 30.0;
input double InpMaxSpread   = 0.60;
input bool   InpAllowLong   = true;
input bool   InpAllowShort  = true;
input ulong  InpMagic       = 20261180;
input int    InpDeviation   = 30;

CTrade   trade;
int      hAtr = INVALID_HANDLE;
datetime lastBar = 0;
// one setup per impulse direction: [0] = up impulse (sell setup), [1] = down impulse (buy setup)
int      st[2];             // 0 idle, 1 impulse running, 2 waiting for the retest
double   lvl[2], org[2];    // level (move extreme) and impulse start, in "transformed" prices
int      age[2];
int      cImp = 0, cRet = 0, cBreak = 0, cDeep = 0, cExp = 0, cSig = 0, cTrades = 0;

//--- transformed prices: for a down impulse (u = -1) the chart is mirrored so one code path handles both
double TH(const int i, const int u) { return u > 0 ?  iHigh(_Symbol, _Period, i) : -iLow(_Symbol, _Period, i); }
double TL(const int i, const int u) { return u > 0 ?  iLow(_Symbol, _Period, i)  : -iHigh(_Symbol, _Period, i); }
double TO(const int i, const int u) { return u * iOpen(_Symbol, _Period, i); }
double TC(const int i, const int u) { return u * iClose(_Symbol, _Period, i); }

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   hAtr = iATR(_Symbol, _Period, 14);
   if(hAtr == INVALID_HANDLE) return INIT_FAILED;
   st[0] = st[1] = 0;
   PrintFormat("FvgReject started on %s %s mode %d", _Symbol, EnumToString(_Period), InpMode);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFormat("FUNNEL impulses=%d retraced=%d broken=%d tooDeep=%d expired=%d signals=%d trades=%d",
               cImp, cRet, cBreak, cDeep, cExp, cSig, cTrades);
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

void ManageBE()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN), sl = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
      if(tp <= 0 || sl <= 0) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         double r = open - sl;                                  // initial risk while the stop is below entry
         if(r > _Point && bid >= open + InpBeTriggerR * r) trade.PositionModify(t, NormalizeDouble(open, _Digits), tp);
      }
      else
      {
         double r = sl - open;
         if(r > _Point && ask <= open - InpBeTriggerR * r) trade.PositionModify(t, NormalizeDouble(open, _Digits), tp);
      }
   }
}

//--- trade against impulse u: u=+1 (up impulse) -> SELL, u=-1 -> BUY. tStop/tTarget are transformed prices.
void Enter(const int u, const double tStop, const double tOrigin)
{
   int dir = -u;
   if(dir > 0 && !InpAllowLong) return;
   if(dir < 0 && !InpAllowShort) return;
   if(HasOpenPosition()) return;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((ask - bid) > InpMaxSpread) return;
   double entry = (dir > 0) ? ask : bid;
   double sl = u * tStop;                         // back to real prices
   double dist = MathAbs(entry - sl);
   if(dir > 0 && sl >= entry) return;
   if(dir < 0 && sl <= entry) return;
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist < InpMinStop || dist > InpMaxStop || dist <= minLevel) return;
   double tp = entry + dir * InpRR * dist;
   if(InpTpMode == 1)
   {
      double t2 = u * tOrigin;
      double rr = dir * (t2 - entry) / dist;
      if(rr < InpMinRR) return;
      tp = t2;
   }
   double lots = CalcLots(dist);
   if(lots <= 0) return;
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "RJ")
                       : trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "RJ");
   if(ok) { cTrades++; PrintFormat("%s lots=%.2f sl=%.2f tp=%.2f level=%.2f", (dir > 0 ? "BUY" : "SELL"), lots, sl, tp, u * lvl[u > 0 ? 0 : 1]); }
}

void Process(const int u, const double atr)
{
   int s = (u > 0) ? 0 : 1;
   // impulse candle = bar 2, gap between bar 3 and bar 1, all closed
   bool imp = TC(2, u) > TO(2, u) && (TC(2, u) - TO(2, u)) >= InpBodyAtr * atr &&
              (TL(1, u) - TH(3, u)) >= InpFvgMinAtr * atr;

   if(st[s] == 0 && imp)
   {
      st[s] = 1; age[s] = 0; cImp++;
      org[s] = MathMin(TL(3, u), MathMin(TL(4, u), TL(5, u)));   // where the move started
      lvl[s] = MathMax(TH(1, u), TH(2, u));
      return;
   }
   if(st[s] == 1)                                   // move still running: extend the level
   {
      age[s]++;
      lvl[s] = MathMax(lvl[s], TH(1, u));
      if(TL(1, u) <= lvl[s] - InpRetrace * (lvl[s] - org[s])) { st[s] = 2; age[s] = 0; cRet++; }
      else if(age[s] > InpMaxBars) { st[s] = 0; cExp++; }
      return;
   }
   if(st[s] == 2)                                   // waiting for the retest of the level
   {
      age[s]++;
      if(TL(1, u) < org[s])  { st[s] = 0; cDeep++;  return; }   // whole move given back
      if(TC(1, u) > lvl[s])  { st[s] = 0; cBreak++; return; }   // body closed beyond the level
      double reach = TH(1, u);
      bool touched = (InpMode == 1) ? (reach > lvl[s]) : (reach >= lvl[s] - InpTouchAtr * atr);
      bool bodyBelow = MathMax(TO(1, u), TC(1, u)) < lvl[s];
      if(touched && bodyBelow)
      {
         cSig++;
         double tStop = MathMax(reach, lvl[s]) + InpStopBuffer;
         Enter(u, tStop, org[s]);
         st[s] = 0;
         return;
      }
      if(age[s] > InpMaxBars) { st[s] = 0; cExp++; }
   }
}

void OnTick()
{
   if(InpMoveBE) ManageBE();
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == lastBar) return;
   lastBar = bt;
   double atr = Atr();
   if(atr <= 0) return;
   Process( 1, atr);
   Process(-1, atr);
}
//+------------------------------------------------------------------+
