//+------------------------------------------------------------------+
//|  SellSetup_XAUUSD.mq5 (v1) -- owner's Sell Setup, SELL only       |
//|  Same rules as pine/Sell_Setup_1H.pine. Attach it to M3 or M5.    |
//|  Setup timeframe (1H):                                            |
//|   1 independent candle = not inside the last independent candle   |
//|   2 R = newest independent red candle                             |
//|   3 valid pullback = a later GREEN candle takes R's high without   |
//|     taking R's low (low first, or both sides = R finished)        |
//|   4 breaker level = R's low; it shifts down wick to wick; BC = a   |
//|     setup candle closes below it (counts for every level below)   |
//|  Entry chart (M3 / M5):                                           |
//|   CC    = first candle inside the BC hour closing below the level |
//|   NCC   = first candle after CC whose high tests the level        |
//|   liquidity = highest high of NCC's swing (confirmed after         |
//|           InpSwingConf candles without a higher high)             |
//|   NCCLT = first candle AFTER the BC hour above the liquidity      |
//|   SELL  = first candle after NCCLT closing below the NCCLT low     |
//|   entry = next open, SL = NCCLT high (+ spread), TP = RR x risk   |
//|  The log also scores every signal at 1R / 2R / 3R / 4R on chart   |
//|  prices, like the TradingView table (lines start with FUNNEL).    |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input group "Setup timeframe"
input ENUM_TIMEFRAMES InpSetupTf = PERIOD_H1; // setup timeframe
input bool   InpShiftLow    = true;   // breaker level shifts down wick to wick
input bool   InpWickKeepR   = true;   // a wick below R's low keeps R (only a close below ends it)
input bool   InpCloseAbove  = true;   // pullback valid if the green closes above R's high (wick below R's low allowed)
input int    InpMaxActive   = 20;     // setups waiting at once (oldest dropped)
input int    InpWarmup      = 500;    // setup candles read before the first entry candle
input group "Entry chart (attach to M3 or M5)"
input bool   InpCcWick      = false;  // CC = first candle trading below (false = closing below)
input double InpNccTol      = 0.0;    // NCC test tolerance (price)
input int    InpNccMax      = 200;    // stop following a BC after this many candles
input int    InpSwingConf   = 1;      // liquidity confirmed after N candles without a higher high
input bool   InpNccGreen    = true;   // NCC must be a green candle that retests the breaking point
input bool   InpNccShift    = true;   // NCC moves to the next candle if it is green and higher
input bool   InpNcclRed     = true;   // NCCLT must be red: if the liquidity taker is green, NCCLT = the next red candle
input bool   InpRetest      = true;   // entry: after a close below the NCCLT low, sell when price retests the NCCLT low
input int    InpTrend       = 0;      // trend filter at the break: 0 off, 1 H4 close < EMA50, 2 D1 close < EMA50, 3 H4 structure down, 4 H1 close < EMA50, 5 H1 structure down
input group "Checks on the setup (at the break)"
input double InpSkipStopUnder = 0.0;  // skip if NCCLT range (stop) is below this $ (0 = off)
input double InpMinOvershoot  = 0.0;  // skip if NCCLT high is less than this $ above the liquidity (0 = off)
input int    InpNoTradeFrom   = -1;   // skip breaks from this server hour ... (-1 = off)
input int    InpNoTradeTo     = -1;   // ... up to (not incl.) this server hour
input double InpSlPad         = 0.0;  // SL = NCCLT high + this $ (wider stop)
input double InpSlFloor       = 0.0;  // stop at least this $ from the entry (wider stop, 0 = off)
input group "Stop"
input int    InpSlMode      = 0;      // 0 = SL at NCCLT high, 1 = SL at liquidity + InpSlBuf
input double InpSlBuf       = 0.30;   // buffer above the liquidity (InpSlMode 1)
input double InpMaxStopX    = 0.0;    // skip if stop > X x usual stop (median of last 50 signals); 0 = off
input double InpMinStopX    = 0.0;    // skip if stop < X x usual stop; 0 = off
input group "Trade"
input double InpRR          = 2.0;    // target in R
input double InpRiskMoney   = 100.0;  // money risked per trade = 1R (0 = use InpRiskPercent)
input double InpRiskPercent = 1.0;    // used only when InpRiskMoney = 0
input bool   InpSlAddSpread = true;   // stop = NCCLT high + spread (stopped when bid reaches it)
input double InpMaxSpread   = 0.0;    // skip when spread is above this (0 = off)
input double InpMinStop     = 0.0;    // skip when stop distance is below this (0 = off)
input double InpMaxStop     = 0.0;    // skip when stop distance is above this (0 = off)
input bool   InpTrade       = true;   // false = signals and chart-price stats only
input bool   InpDraw        = true;   // draw BC, CC, NCC, liquidity, NCCLT, SELL (live chart / visual test)
input ulong  InpMagic       = 20261110;
input int    InpDeviation   = 50;

#define NR 4
#define NY 30
#define Y0 2015
double RL[NR] = {1.0, 2.0, 3.0, 4.0};

struct Block
{
   double   lvl;     // breaker point (shifted R low) the BC closed below
   int      stage;   // 0 wait NCC, 1 build NCC swing, 2 wait NCCLT, 3 wait SELL, 4 done
   int      since;   // candles processed after CC
   double   swH;     // liquidity = highest high of the NCC swing
   int      conf;
   double   ltH;     // NCCLT high (= stop)
   double   ltL;     // NCCLT low (close below = SELL)
   datetime endT;    // end of the BC hour
   datetime bcT;     // chain times, printed with each signal
   datetime ccT;
   datetime ncT;
   datetime ltT;
   datetime swT;     // candle of the liquidity high
   double   ncL;     // NCC low
   double   ncH;     // NCC high
   bool     ncRun;   // NCC can still move to the next green, higher candle
   double   need;    // level NCCLT must take (liquidity, raised by red candles that took it)
   bool     brk;
   bool     took;
   double   gH;      // high of the latest green candle since the liquidity was taken    // the liquidity has been taken (waiting for a red candle = NCCLT)     // a candle closed below the NCCLT low (retest entry: waiting for the retest)
   ulong    tk;      // pending sell limit at the NCCLT low (real trade)
   datetime rT;      // 1H setup behind the BC: R candle, its low, pullback candle,
   double   rL;      //   how often the level shifted (and when last), setups closed below
   datetime pT;
   int      nSh;
   datetime shT;
   int      nSet;
};

struct VTrade
{
   datetime t;
   double   e;
   double   sl;
   int      year;
   int      res[NR]; // 0 open, 1 win, -1 loss
   datetime xt[NR];  // when each target or the stop was hit
};

CTrade   trade;
bool     gDraw = false;
int      gObj = 0;
int      hEmaH4 = INVALID_HANDLE, hEmaD1 = INVALID_HANDLE, hEmaH1 = INVALID_HANDLE;
int      nTrendSkip = 0, nCheckSkip = 0;

// stop used for the setup: NCCLT high, optionally padded or widened to a minimum distance
double EffSL(const double ltH, const double entry)
{
   double sl = ltH + InpSlPad;
   if(InpSlFloor > 0 && sl - entry < InpSlFloor) sl = entry + InpSlFloor;
   return sl;
}

// extra checks at the break; true = skip the setup
bool CheckSkip(const Block &b, const datetime t)
{
   if(InpSkipStopUnder > 0 && b.ltH - b.ltL < InpSkipStopUnder) return true;
   if(InpMinOvershoot > 0 && b.ltH - b.swH < InpMinOvershoot) return true;
   if(InpNoTradeFrom >= 0 && InpNoTradeTo >= 0)
   {
      MqlDateTime d;
      TimeToStruct(t, d);
      bool in = InpNoTradeFrom <= InpNoTradeTo ? (d.hour >= InpNoTradeFrom && d.hour < InpNoTradeTo)
                                               : (d.hour >= InpNoTradeFrom || d.hour < InpNoTradeTo);
      if(in) return true;
   }
   return false;
}
datetime lastBar = 0;
bool     warm = false;
datetime lastSetup = 0;     // open time of the last processed (closed) setup candle
datetime curSetupOpen = 0;
// setup timeframe state
bool     refSet = false;
double   refH = 0, refL = 0;
bool     cAct = false;
double   cH = 0, cL = 0;
datetime cT = 0;            // open time of the current R candle
double   lv[];              // breaker levels waiting for a BC
datetime lvRT[];            // per level: R candle time, R low, pullback candle time,
double   lvRL[];            //   number of wick-to-wick shifts, time of the last shift
datetime lvPT[];
int      lvSh[];
datetime lvST[];
datetime hRT = 0, hPT = 0, hST = 0;  // setup of the highest level the last BC closed below
double   hRL = 0;
int      hSh = 0;
Block    blocks[];
VTrade   vt[];
// funnel
int      nSetup = 0, nInside = 0, nValid = 0, nDrop = 0, nBc = 0, nCc = 0, nNoCc = 0;
int      nNcc = 0, nLt = 0, nSig = 0, nLate = 0, nExp = 0, nTrades = 0, nSkip = 0;
int      wR[NR];
int      lR[NR];
int      yW[NY][NR];
int      yL[NY][NR];
int      yN[NY];
double   sumStop = 0, minStop = 0, maxStop = 0, sumSpread = 0;
double   recentStops[];         // stops of the last 50 signals (the "usual" stop = their median)
int      nFiltered = 0, nFallback = 0;

int OnInit()
{
   hEmaH4 = iMA(_Symbol, PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE);
   hEmaD1 = iMA(_Symbol, PERIOD_D1, 50, 0, MODE_EMA, PRICE_CLOSE);
   hEmaH1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   gDraw = InpDraw && (!MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE));
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   if(PeriodSeconds(_Period) >= PeriodSeconds(InpSetupTf))
   {
      Print("Attach SellSetup to a chart lower than the setup timeframe (M3 or M5).");
      return INIT_PARAMETERS_INCORRECT;
   }
   for(int k = 0; k < NR; k++)
   {
      wR[k] = 0;
      lR[k] = 0;
      for(int y = 0; y < NY; y++) { yW[y][k] = 0; yL[y][k] = 0; }
   }
   for(int y = 0; y < NY; y++) yN[y] = 0;
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("Note: this account is not hedging, so overlapping sells merge into one position.");
   PrintFormat("SellSetup started on %s %s, setup %s, RR %.1f", _Symbol, EnumToString(_Period),
               EnumToString(InpSetupTf), InpRR);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   string tf = StringSubstr(EnumToString(_Period), 7);
   PrintFormat("FUNNEL [%s] setup candles=%d inside=%d valid pullbacks=%d dropped=%d BC=%d CC=%d noCC=%d NCC=%d NCCLT=%d SELL=%d late=%d expired=%d",
               tf, nSetup, nInside, nValid, nDrop, nBc, nCc, nNoCc, nNcc, nLt, nSig, nLate, nExp);
   PrintFormat("FUNNEL [%s] chart prices (like TradingView), every SELL, stop first if both in one candle:", tf);
   for(int k = 0; k < NR; k++)
   {
      int n = wR[k] + lR[k];
      PrintFormat("FUNNEL [%s] %.0fR: %d trades  %d W / %d L  win %.1f%%  net %+.1fR", tf, RL[k], n,
                  wR[k], lR[k], n > 0 ? 100.0 * wR[k] / n : 0.0, wR[k] * RL[k] - lR[k]);
   }
   for(int y = 0; y < NY; y++)
   {
      if(yN[y] == 0) continue;
      string s = StringFormat("FUNNEL [%s] %d n=%d", tf, Y0 + y, yN[y]);
      for(int k = 0; k < NR; k++)
      {
         int n = yW[y][k] + yL[y][k];
         s += StringFormat(" | %.0fR %.0f%% %+.0fR", RL[k], n > 0 ? 100.0 * yW[y][k] / n : 0.0,
                           yW[y][k] * RL[k] - yL[y][k]);
      }
      Print(s);
   }
   if(nSig > 0)
      PrintFormat("FUNNEL [%s] stop size: avg %.2f  min %.2f  max %.2f | avg spread at signal %.2f",
                  tf, sumStop / nSig, minStop, maxStop, sumSpread / nSig);
   PrintFormat("FUNNEL [%s] real trades opened=%d skipped=%d (RR %.1f) | trend skipped %d | checks skipped %d | stop filter skipped %d | SL mode %d (fallback to NCCLT high %d)",
               tf, nTrades, nSkip, InpRR, nTrendSkip, nCheckSkip, nFiltered, InpSlMode, nFallback);
}

//+------------------------------------------------------------------+
//| Drawing (only on a live chart or in a visual test)                |
//+------------------------------------------------------------------+
string ObjName(const string k)
{
   gObj++;
   return "SS_" + k + "_" + IntegerToString(gObj);
}

void DrawText(const datetime t, const double p, const string txt, const color c, const ENUM_ANCHOR_POINT a)
{
   if(!gDraw) return;
   string n = ObjName("t");
   if(!ObjectCreate(0, n, OBJ_TEXT, 0, t, p)) return;
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, n, OBJPROP_ANCHOR, a);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void DrawLine(const datetime t1, const double p1, const datetime t2, const double p2, const color c,
              const ENUM_LINE_STYLE st, const int w)
{
   if(!gDraw) return;
   string n = ObjName("l");
   if(!ObjectCreate(0, n, OBJ_TREND, 0, t1, p1, t2, p2)) return;
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_STYLE, st);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, w);
   ObjectSetInteger(0, n, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void DrawBox(const datetime t1, const double p1, const datetime t2, const double p2, const color c)
{
   if(!gDraw) return;
   string n = ObjName("b");
   if(!ObjectCreate(0, n, OBJ_RECTANGLE, 0, t1, p1, t2, p2)) return;
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, n, OBJPROP_FILL, false);
   ObjectSetInteger(0, n, OBJPROP_BACK, true);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Setup timeframe: one closed candle (same as bcLogic in the Pine)  |
//| returns how many waiting levels this candle closed below; hit =   |
//| the highest of those levels                                       |
//+------------------------------------------------------------------+
void LvRemove(const int i)
{
   ArrayRemove(lv, i, 1);
   ArrayRemove(lvRT, i, 1);
   ArrayRemove(lvRL, i, 1);
   ArrayRemove(lvPT, i, 1);
   ArrayRemove(lvSh, i, 1);
   ArrayRemove(lvST, i, 1);
}

int SetupCandle(const MqlRates &r, double &hit)
{
   nSetup++;
   bool ins = refSet && r.high <= refH && r.low >= refL;
   int n = 0;
   hit = 0.0;
   for(int i = ArraySize(lv) - 1; i >= 0; i--)
   {
      if(r.close < lv[i])
      {
         n++;
         if(n == 1 || lv[i] > hit)
         {
            hit = lv[i];
            hRT = lvRT[i];
            hRL = lvRL[i];
            hPT = lvPT[i];
            hSh = lvSh[i];
            hST = lvST[i];
         }
         LvRemove(i);
      }
      else if(InpShiftLow && r.low < lv[i])
      {
         lv[i] = r.low;
         lvSh[i]++;
         lvST[i] = r.time;
      }
   }
   if(ins)
   {
      nInside++;
      return n;
   }
   if(cAct)
   {
      bool tH = r.high > cH;
      bool tL = r.low < cL;
      // a wick below R's low without a close below keeps R; R's low moves to that wick
      if(InpWickKeepR && tL && r.close >= cL)
      {
         cL = r.low;
         tL = false;
      }
      // valid: green takes R's high without its low, or closes above R's high
      // (a wick below R's low is then allowed and the level starts at that wick)
      if(r.close > r.open && ((tH && !tL) || (InpCloseAbove && r.close > cH)))
      {
         int s = ArraySize(lv);
         ArrayResize(lv, s + 1);
         ArrayResize(lvRT, s + 1);
         ArrayResize(lvRL, s + 1);
         ArrayResize(lvPT, s + 1);
         ArrayResize(lvSh, s + 1);
         ArrayResize(lvST, s + 1);
         lv[s] = tL ? r.low : cL;
         lvRT[s] = cT;
         lvRL[s] = cL;
         lvPT[s] = r.time;
         lvSh[s] = 0;
         lvST[s] = 0;
         nValid++;
         if(ArraySize(lv) > InpMaxActive)
         {
            LvRemove(0);
            nDrop++;
         }
         cAct = false;
      }
      else if(tL)
         cAct = false;
   }
   if(r.close < r.open)
   {
      cAct = true;
      cH = r.high;
      cL = r.low;
      cT = r.time;
   }
   refSet = true;
   refH = r.high;
   refL = r.low;
   return n;
}

void Warmup()
{
   MqlRates hr[];
   ArraySetAsSeries(hr, false);
   int got = CopyRates(_Symbol, InpSetupTf, 1, InpWarmup, hr);
   double hit = 0;
   for(int i = 0; i < got; i++) SetupCandle(hr[i], hit);
   if(got > 0) lastSetup = hr[got - 1].time;
   else        lastSetup = iTime(_Symbol, InpSetupTf, 1);
   curSetupOpen = iTime(_Symbol, InpSetupTf, 0);
   // the funnel counts the test period only
   nSetup = 0;
   nInside = 0;
   nValid = 0;
   nDrop = 0;
   PrintFormat("warm-up: %d setup candles read, %d setups waiting", got, ArraySize(lv));
}

double Median(const double &a[])
{
   int n = ArraySize(a);
   if(n == 0) return 0.0;
   double b[];
   ArrayCopy(b, a);
   ArraySort(b);
   return (n % 2 == 1) ? b[n / 2] : 0.5 * (b[n / 2 - 1] + b[n / 2]);
}

// close of the last closed bar of tf before time t below its EMA50
bool BelowEma(const ENUM_TIMEFRAMES tf, const int h, const datetime t)
{
   int sh = iBarShift(_Symbol, tf, t, false);
   if(sh < 0) return true;
   sh += 1;
   double ema[];
   if(CopyBuffer(h, 0, sh, 1, ema) != 1) return true;
   return iClose(_Symbol, tf, sh) < ema[0];
}

// H4 structure: the last broken H4 swing point (3-candle fractal) was a low
bool StructureDown(const ENUM_TIMEFRAMES tf, const datetime t)
{
   int sh = iBarShift(_Symbol, tf, t, false);
   if(sh < 0) return true;
   MqlRates b[];
   ArraySetAsSeries(b, false);
   int n = CopyRates(_Symbol, tf, sh + 1, 300, b);
   if(n < 10) return true;
   double sH = 0, sL = 0;
   int state = 0;
   for(int i = 2; i < n; i++)
   {
      // the swing at i-1 is confirmed once candle i has closed
      if(b[i - 1].high > b[i - 2].high && b[i - 1].high > b[i].high) sH = b[i - 1].high;
      if(b[i - 1].low < b[i - 2].low && b[i - 1].low < b[i].low)     sL = b[i - 1].low;
      if(sL > 0 && b[i].close < sL) { state = -1; sL = 0; }
      if(sH > 0 && b[i].close > sH) { state = 1;  sH = 0; }
   }
   return state == -1;
}

bool TrendOk(const datetime t)
{
   if(InpTrend == 1) return BelowEma(PERIOD_H4, hEmaH4, t);
   if(InpTrend == 2) return BelowEma(PERIOD_D1, hEmaD1, t);
   if(InpTrend == 3) return StructureDown(PERIOD_H4, t);
   if(InpTrend == 4) return BelowEma(PERIOD_H1, hEmaH1, t);
   if(InpTrend == 5) return StructureDown(PERIOD_H1, t);
   return true;
}

void RemoveBlock(const int i)
{
   int n = ArraySize(blocks);
   for(int j = i; j < n - 1; j++) blocks[j] = blocks[j + 1];
   ArrayResize(blocks, n - 1);
}

void RemoveVT(const int i)
{
   int n = ArraySize(vt);
   for(int j = i; j < n - 1; j++) vt[j] = vt[j + 1];
   ArrayResize(vt, n - 1);
}

double CalcLots(const double stopDistance)
{
   double riskMoney = InpRiskMoney > 0 ? InpRiskMoney : AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
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

// real trade at the open of the candle after the SELL candle
void OpenSell(const double nccltHigh)
{
   if(!InpTrade) return;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = ask - bid;
   if(InpMaxSpread > 0 && spread > InpMaxSpread) { nSkip++; return; }
   double sl = nccltHigh + (InpSlAddSpread ? spread : 0.0);
   double dist = sl - bid;
   double minLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist <= 0 || dist <= minLevel) { nSkip++; return; }
   if(InpMinStop > 0 && dist < InpMinStop) { nSkip++; return; }
   if(InpMaxStop > 0 && dist > InpMaxStop) { nSkip++; return; }
   double lots = CalcLots(dist);
   if(lots <= 0) { nSkip++; return; }
   double tp = bid - InpRR * dist;
   if(trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "SellSetup"))
      nTrades++;
   else
      nSkip++;
}

// SELL candle closed: score it on chart prices and open the real trade
void OnSellSignal(const MqlRates &r, const Block &b, const double ePx, const bool retest)
{
   double e = ePx;
   double sl = InpRetest ? EffSL(b.ltH, ePx) : b.ltH + InpSlPad;
   if(InpSlMode == 1)
   {
      // stop at the liquidity the NCCLT took, plus a small buffer (if that is above the entry)
      double s1 = b.swH + InpSlBuf;
      if(s1 > e + InpSlBuf) sl = s1;
      else                  nFallback++;
   }
   double risk = sl - e;
   if(risk <= 0) return;
   // usual stop = median stop of the last 50 signals (needs at least 20)
   int nr = ArraySize(recentStops);
   double usual = (nr >= 20) ? Median(recentStops) : 0.0;
   if(nr >= 50) ArrayRemove(recentStops, 0, 1);
   int m = ArraySize(recentStops);
   ArrayResize(recentStops, m + 1);
   recentStops[m] = risk;
   if(usual > 0 && ((InpMaxStopX > 0 && risk > InpMaxStopX * usual) || (InpMinStopX > 0 && risk < InpMinStopX * usual)))
   {
      nFiltered++;
      return;
   }
   nSig++;
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   sumStop += risk;
   sumSpread += spread;
   if(nSig == 1 || risk < minStop) minStop = risk;
   if(nSig == 1 || risk > maxStop) maxStop = risk;
   MqlDateTime dt;
   TimeToStruct(r.time, dt);
   int s = ArraySize(vt);
   ArrayResize(vt, s + 1);
   vt[s].t = r.time;
   vt[s].e = e;
   vt[s].sl = sl;
   vt[s].year = dt.year;
   for(int k = 0; k < NR; k++) { vt[s].res[k] = 0; vt[s].xt[k] = 0; }
   int yi = dt.year - Y0;
   if(yi >= 0 && yi < NY) yN[yi]++;
   PrintFormat("SIG %s entry %.2f SL %.2f stop %.2f spread %.2f | BC %s level %.2f | CC %s | NCC %s | liquidity %.2f | NCCLT %s low %.2f | R %s low %.2f | PB %s | shifts %d last %s | setups %d",
               TimeToString(r.time), e, sl, risk, spread, TimeToString(b.bcT), b.lvl, TimeToString(b.ccT),
               TimeToString(b.ncT), b.swH, TimeToString(b.ltT), b.ltL, TimeToString(b.rT), b.rL,
               TimeToString(b.pT), b.nSh, b.shT > 0 ? TimeToString(b.shT) : "-", b.nSet);
   if(gDraw)
   {
      datetime t2 = r.time + 20 * PeriodSeconds(_Period);
      double tp = e - InpRR * risk;
      DrawLine(r.time, e, t2, e, clrDodgerBlue, STYLE_SOLID, 2);
      DrawLine(r.time, sl, t2, sl, clrRed, STYLE_SOLID, 2);
      DrawLine(r.time, tp, t2, tp, clrSeaGreen, STYLE_SOLID, 2);
      DrawText(r.time, sl, StringFormat("SELL %.2f  SL %.2f (NCCLT high)  TP %.2f (%.0fR)", e, sl, tp, InpRR),
               clrRed, ANCHOR_LEFT_LOWER);
   }
   if(retest)
   {
      // the retest candle itself may already reach the stop: loss (stop first)
      if(r.high >= sl)
      {
         int q = ArraySize(vt) - 1;
         string t2 = StringFormat("RES %s entry %.2f SL %.2f", TimeToString(vt[q].t), vt[q].e, vt[q].sl);
         for(int k = 0; k < NR; k++)
         {
            vt[q].res[k] = -1;
            vt[q].xt[k] = r.time;
            lR[k]++;
            if(yi >= 0 && yi < NY) yL[yi][k]++;
            t2 += StringFormat(" | %.0fR LOSS %s", RL[k], TimeToString(r.time));
         }
         Print(t2);
         RemoveVT(q);
      }
      return;                 // the real order is the sell limit placed at the break
   }
   OpenSell(sl);
}

// retest entry: sell limit at the NCCLT low, placed when a candle closes below it
ulong PlaceSellLimit(const double price, const double nccltHigh)
{
   if(!InpTrade) return 0;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = ask - bid;
   double sl = nccltHigh + (InpSlAddSpread ? spread : 0.0);
   double dist = sl - price;
   if(dist <= 0) { nSkip++; return 0; }
   if(InpMinStop > 0 && dist < InpMinStop) { nSkip++; return 0; }
   if(InpMaxStop > 0 && dist > InpMaxStop) { nSkip++; return 0; }
   double lots = CalcLots(dist);
   if(lots <= 0) { nSkip++; return 0; }
   double tp = price - InpRR * dist;
   bool ok;
   if(bid < price - SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point)
      ok = trade.SellLimit(lots, NormalizeDouble(price, _Digits), _Symbol, NormalizeDouble(sl, _Digits),
                           NormalizeDouble(tp, _Digits), ORDER_TIME_GTC, 0, "SellSetup");
   else
      ok = trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "SellSetup");
   if(!ok) { nSkip++; return 0; }
   nTrades++;
   return trade.ResultOrder();
}

void CancelPending(const ulong tk)
{
   if(tk > 0 && OrderSelect(tk)) trade.OrderDelete(tk);
}

// chart-price scoring of every signal (stop first if both in one candle)
void UpdateVirtual(const MqlRates &r)
{
   for(int i = ArraySize(vt) - 1; i >= 0; i--)
   {
      if(r.time <= vt[i].t) continue;
      bool hitSl = r.high >= vt[i].sl;
      bool pending = false;
      int yi = vt[i].year - Y0;
      bool yok = (yi >= 0 && yi < NY);
      for(int k = 0; k < NR; k++)
      {
         if(vt[i].res[k] != 0) continue;
         double tp = vt[i].e - RL[k] * (vt[i].sl - vt[i].e);
         if(hitSl)
         {
            vt[i].res[k] = -1;
            vt[i].xt[k] = r.time;
            lR[k]++;
            if(yok) yL[yi][k]++;
         }
         else if(r.low <= tp)
         {
            vt[i].res[k] = 1;
            vt[i].xt[k] = r.time;
            wR[k]++;
            if(yok) yW[yi][k]++;
         }
         else
            pending = true;
      }
      if(!pending)
      {
         string s = StringFormat("RES %s entry %.2f SL %.2f", TimeToString(vt[i].t), vt[i].e, vt[i].sl);
         for(int k = 0; k < NR; k++)
            s += StringFormat(" | %.0fR %s %s", RL[k], vt[i].res[k] > 0 ? "WIN" : "LOSS", TimeToString(vt[i].xt[k]));
         Print(s);
         RemoveVT(i);
      }
   }
}

// one entry-chart candle for one BC block (same as stepBlock in the Pine)
void StepBlock(Block &b, const MqlRates &r, const bool live)
{
   b.since++;
   if(b.stage == 0)
   {
      // NCC: first candle after CC that comes back up and tests the breaker point
      if(r.high >= b.lvl - InpNccTol && (!InpNccGreen || r.time < b.endT || r.close > r.open))
      {
         b.swH = r.high;
         b.conf = 0;
         b.stage = 1;
         b.ncT = r.time;
         b.ncL = r.low;
         b.ncH = r.high;
         b.ncRun = true;
         b.swT = r.time;
         nNcc++;
         DrawText(r.time, r.low, "NCC", clrDodgerBlue, ANCHOR_UPPER);
      }
   }
   else if(b.stage == 1)
   {
      // the next candle green and higher: NCC moves to it (repeats while they keep going up)
      if(b.ncRun && InpNccShift && r.close > r.open && r.high > b.ncH)
      {
         b.ncT = r.time;
         b.ncL = r.low;
         b.ncH = r.high;
      }
      else
         b.ncRun = false;
      // NCC swing: keep the highest high until InpSwingConf candles make no higher high
      if(r.high > b.swH)
      {
         b.swH = r.high;
         b.swT = r.time;
         b.conf = 0;
      }
      else
      {
         b.conf++;
         if(b.conf >= InpSwingConf)
         {
            b.need = b.swH;
            b.stage = 2;
         }
      }
   }
   else if(b.stage == 2)
   {
      // NCCLT: first candle after the BC hour that takes the liquidity
      // the liquidity is taken by a candle after the BC hour; NCCLT = that candle if it is
      // red, otherwise the next red candle
      // a red candle after a green one counts only if its high is above that green's high
      bool isRed = r.close < r.open;
      bool okLt = false;
      if(!b.took && r.high > b.need && r.time >= b.endT)
      {
         b.took = true;
         okLt = !InpNcclRed || isRed;
      }
      else if(b.took)
         okLt = isRed && r.high > b.gH;
      if(b.took && !okLt && !isRed) b.gH = r.high;
      if(okLt)
      {
         b.ltH = r.high;
         b.ltL = r.low;
         b.ltT = r.time;
         b.stage = 3;
         nLt++;
         DrawLine(b.swT, b.swH, r.time, b.swH, clrDodgerBlue, STYLE_SOLID, 2);
         DrawLine(b.ncT, b.ncL, r.time, b.ncL, clrDodgerBlue, STYLE_SOLID, 2);
         DrawText(r.time, r.high, "NCCLT", clrMagenta, ANCHOR_LOWER);
      }
   }
   else if(b.stage == 3)
   {
      // SELL: a candle closes below the NCCLT low; with retest entry, sell when a later
      // candle comes back up to the NCCLT low. SL = NCCLT high
      if(InpRetest && b.brk)
      {
         if(r.high >= b.ltL)
         {
            b.stage = 4;
            if(live) OnSellSignal(r, b, b.ltL, true);
            else     nLate++;
         }
      }
      else if(r.close < b.ltL && InpTrend > 0 && !TrendOk(r.time))
      {
         b.stage = 4;          // trend not down at the break: skip this setup
         nTrendSkip++;
      }
      else if(r.close < b.ltL && CheckSkip(b, r.time))
      {
         b.stage = 4;
         nCheckSkip++;
      }
      else if(r.close < b.ltL)
      {
         if(InpRetest)
         {
            b.brk = true;
            DrawText(r.time, r.low, "break", clrMagenta, ANCHOR_UPPER);
            if(live) b.tk = PlaceSellLimit(b.ltL, EffSL(b.ltH, b.ltL));
         }
         else
         {
            b.stage = 4;
            if(live) OnSellSignal(r, b, r.close, false);
            else     nLate++;
         }
      }
   }
   if(b.stage < 4 && b.since > InpNccMax)
   {
      b.stage = 4;
      nExp++;
      CancelPending(b.tk);
   }
}

// a setup candle closed below one or more levels: BC block, CC, catch up to now
void NewBc(const MqlRates &h, const double lvl, const datetime lastClosed, const int nSetups)
{
   nBc++;
   datetime bcT = h.time;
   datetime endT = h.time + PeriodSeconds(InpSetupTf);
   MqlRates lr[];
   ArraySetAsSeries(lr, false);
   int got = CopyRates(_Symbol, _Period, bcT, endT - 1, lr);
   int cc = -1;
   for(int i = 0; i < got; i++)
   {
      if(lr[i].time < bcT || lr[i].time >= endT) continue;
      bool brk = InpCcWick ? (lr[i].low < lvl) : (lr[i].close < lvl);
      if(brk) { cc = i; break; }
   }
   if(gDraw)
   {
      DrawBox(bcT, h.high, endT, h.low, clrRed);
      DrawText(bcT, h.high, "BC " + TimeToString(bcT, TIME_MINUTES), clrRed, ANCHOR_LEFT_LOWER);
      DrawLine(bcT, lvl, endT, lvl, clrRed, STYLE_DOT, 1);
   }
   if(cc < 0) { nNoCc++; return; }
   nCc++;
   DrawText(lr[cc].time, lr[cc].high, "CC", clrDodgerBlue, ANCHOR_LOWER);
   Block b;
   b.lvl = lvl;
   b.stage = 0;
   b.since = 0;
   b.swH = 0;
   b.conf = 0;
   b.ltH = 0;
   b.ltL = 0;
   b.endT = endT;
   b.bcT = bcT;
   b.ncT = 0;
   b.ltT = 0;
   b.swT = 0;
   b.ncL = 0;
   b.ncH = 0;
   b.ncRun = false;
   b.need = 0;
   b.brk = false;
   b.took = false;
   b.gH = 0;
   b.tk = 0;
   b.rT = hRT;
   b.rL = hRL;
   b.pT = hPT;
   b.nSh = hSh;
   b.shT = hST;
   b.nSet = nSetups;
   datetime ccT = lr[cc].time;
   b.ccT = ccT;
   if(lastClosed > ccT)
   {
      MqlRates cr[];
      ArraySetAsSeries(cr, false);
      int gc = CopyRates(_Symbol, _Period, ccT + 1, lastClosed, cr);
      for(int i = 0; i < gc && b.stage < 4; i++)
      {
         if(cr[i].time <= ccT || cr[i].time > lastClosed) continue;
         StepBlock(b, cr[i], cr[i].time == lastClosed);
      }
   }
   if(b.stage < 4)
   {
      int s = ArraySize(blocks);
      ArrayResize(blocks, s + 1);
      blocks[s] = b;
      if(ArraySize(blocks) > 30) RemoveBlock(0);
   }
}

void OnTick()
{
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == 0 || bt == lastBar) return;
   lastBar = bt;
   if(!warm)
   {
      Warmup();
      warm = true;
      return;
   }
   MqlRates r1[];
   ArraySetAsSeries(r1, false);
   if(CopyRates(_Symbol, _Period, 1, 1, r1) != 1) return;

   // a. chart-price scoring: the candle that just closed
   UpdateVirtual(r1[0]);

   // b. running BC blocks: the candle that just closed
   for(int i = ArraySize(blocks) - 1; i >= 0; i--)
   {
      StepBlock(blocks[i], r1[0], true);
      if(blocks[i].stage >= 4) RemoveBlock(i);
   }

   // c. setup candle(s) closed since the last check -> BC?
   datetime s0 = iTime(_Symbol, InpSetupTf, 0);
   if(s0 > 0 && s0 != curSetupOpen)
   {
      curSetupOpen = s0;
      MqlRates hr[];
      ArraySetAsSeries(hr, false);
      int got = CopyRates(_Symbol, InpSetupTf, lastSetup + 1, s0 - 1, hr);
      for(int j = 0; j < got; j++)
      {
         if(hr[j].time <= lastSetup || hr[j].time >= s0) continue;
         double hit = 0;
         int n = SetupCandle(hr[j], hit);
         lastSetup = hr[j].time;
         if(n > 0) NewBc(hr[j], hit, r1[0].time, n);
      }
   }
}
//+------------------------------------------------------------------+
