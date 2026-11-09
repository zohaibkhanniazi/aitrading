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
input int    InpMaxActive   = 20;     // setups waiting at once (oldest dropped)
input int    InpWarmup      = 500;    // setup candles read before the first entry candle
input group "Entry chart (attach to M3 or M5)"
input bool   InpCcWick      = false;  // CC = first candle trading below (false = closing below)
input double InpNccTol      = 0.0;    // NCC test tolerance (price)
input int    InpNccMax      = 200;    // stop following a BC after this many candles
input int    InpSwingConf   = 1;      // liquidity confirmed after N candles without a higher high
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
datetime lastBar = 0;
bool     warm = false;
datetime lastSetup = 0;     // open time of the last processed (closed) setup candle
datetime curSetupOpen = 0;
// setup timeframe state
bool     refSet = false;
double   refH = 0, refL = 0;
bool     cAct = false;
double   cH = 0, cL = 0;
double   lv[];              // breaker levels waiting for a BC
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

int OnInit()
{
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
   PrintFormat("FUNNEL [%s] real trades opened=%d skipped=%d (RR %.1f)", tf, nTrades, nSkip, InpRR);
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
         hit = (n == 1) ? lv[i] : MathMax(hit, lv[i]);
         ArrayRemove(lv, i, 1);
      }
      else if(InpShiftLow && r.low < lv[i])
         lv[i] = r.low;
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
      if(tH && !tL && r.close > r.open)
      {
         int s = ArraySize(lv);
         ArrayResize(lv, s + 1);
         lv[s] = cL;
         nValid++;
         if(ArraySize(lv) > InpMaxActive)
         {
            ArrayRemove(lv, 0, 1);
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
void OnSellSignal(const MqlRates &r, const Block &b)
{
   double e = r.close;
   double sl = b.ltH;
   double risk = sl - e;
   if(risk <= 0) return;
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
   PrintFormat("SIG %s entry %.2f SL %.2f stop %.2f spread %.2f | BC %s level %.2f | CC %s | NCC %s | liquidity %.2f | NCCLT %s low %.2f",
               TimeToString(r.time), e, sl, risk, spread, TimeToString(b.bcT), b.lvl, TimeToString(b.ccT),
               TimeToString(b.ncT), b.swH, TimeToString(b.ltT), b.ltL);
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
   OpenSell(sl);
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
      if(r.high >= b.lvl - InpNccTol)
      {
         b.swH = r.high;
         b.conf = 0;
         b.stage = 1;
         b.ncT = r.time;
         b.ncL = r.low;
         b.swT = r.time;
         nNcc++;
         DrawText(r.time, r.low, "NCC", clrDodgerBlue, ANCHOR_UPPER);
      }
   }
   else if(b.stage == 1)
   {
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
         if(b.conf >= InpSwingConf) b.stage = 2;
      }
   }
   else if(b.stage == 2)
   {
      // NCCLT: first candle after the BC hour that takes the liquidity
      if(r.high > b.swH && r.time >= b.endT)
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
      // SELL: first candle that closes below the NCCLT low; SL = NCCLT high
      if(r.close < b.ltL)
      {
         b.stage = 4;
         if(live) OnSellSignal(r, b);
         else     nLate++;
      }
   }
   if(b.stage < 4 && b.since > InpNccMax)
   {
      b.stage = 4;
      nExp++;
   }
}

// a setup candle closed below one or more levels: BC block, CC, catch up to now
void NewBc(const MqlRates &h, const double lvl, const datetime lastClosed)
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
         if(n > 0) NewBc(hr[j], hit, r1[0].time);
      }
   }
}
//+------------------------------------------------------------------+
