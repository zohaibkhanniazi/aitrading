//+------------------------------------------------------------------+
//|  TsmomLive_XAUUSD.mq5 (v1) -- LIVE time-series momentum on gold   |
//|  Attach to any XAUUSD chart. Same rules as the tested Tsmom EA,  |
//|  plus: real-account lock, kill switch, lot cap, status panel,    |
//|  and it rebalances once per calendar month (also after restarts).|
//|                                                                  |
//|  Research:                                                       |
//|   Moskowitz, Ooi & Pedersen (2012) "Time series momentum",       |
//|     Journal of Financial Economics: go long if the past 12-month |
//|     return is positive, short if negative, hold 1 month, size    |
//|     each position to a constant volatility.                      |
//|   Hurst, Ooi & Pedersen (2017) "A Century of Evidence on Trend-  |
//|     Following Investing": equal blend of 1, 3 and 12-month       |
//|     signals, monthly rebalance, 10% volatility target.           |
//|                                                                  |
//|  Mode 0 = one lookback (InpLookbackDays)                         |
//|  Mode 1 = blend of 1, 3 and 12-month signals (21/63/252 days)    |
//|  Mode 2 = benchmark: always long, same volatility sizing         |
//|  Rebalance on the first trading day of each month (or week).     |
//+------------------------------------------------------------------+
#property copyright "v1"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

input int    InpMode         = 1;      // 0 = single lookback, 1 = 1/3/12-month blend, 2 = always long (benchmark)
input int    InpLookbackDays = 252;    // mode 0 lookback (252 = 12 months)
input int    InpRebalance    = 0;      // 0 = monthly, 1 = weekly
input double InpTargetVol    = 15.0;   // annualised volatility target, %
input int    InpVolDays      = 60;     // days used to estimate volatility
input double InpMaxLeverage  = 3.0;    // cap: position value / equity
input double InpMinChange    = 0.25;   // resize only when the size changes by more than 25%
input bool   InpAllowShort   = true;
input group "Safety"
input bool   InpEnableTrading    = true;   // false = show the panel only, no trades
input bool   InpAllowRealAccount = false;  // must be true to run on a REAL account
input double InpMaxLots          = 1.0;    // hard cap on position size
input bool   InpShowPanel        = true;
input ulong  InpMagic        = 20261230;
input int    InpDeviation    = 50;

CTrade   trade;
datetime lastBar = 0;
int      cRebal = 0, cFlip = 0, cResize = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL && !InpAllowRealAccount)
   {
      Comment("TSMOM LIVE: stopped. Real account detected. Set InpAllowRealAccount = true to confirm.");
      Print("REFUSED: real account. Set InpAllowRealAccount = true to confirm.");
      return INIT_FAILED;
   }
   EventSetTimer(60);
   PrintFormat("TSMOM started on %s, mode %d, target vol %.1f%%", _Symbol, InpMode, InpTargetVol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   PrintFormat("FUNNEL rebalances=%d flips=%d resizes=%d", cRebal, cFlip, cResize);
}

double Ret(const int days)
{
   double c1 = iClose(_Symbol, PERIOD_D1, 1), c0 = iClose(_Symbol, PERIOD_D1, 1 + days);
   if(c1 <= 0 || c0 <= 0) return 0;
   return c1 / c0 - 1.0;
}

double Sign(const double x) { return (x > 0) ? 1.0 : (x < 0 ? -1.0 : 0.0); }

//--- annualised volatility of daily log returns
double AnnVol()
{
   int n = InpVolDays;
   double s = 0, s2 = 0;
   int m = 0;
   for(int i = 1; i <= n; i++)
   {
      double a = iClose(_Symbol, PERIOD_D1, i), b = iClose(_Symbol, PERIOD_D1, i + 1);
      if(a <= 0 || b <= 0) continue;
      double r = MathLog(a / b);
      s += r; s2 += r * r; m++;
   }
   if(m < 20) return 0;
   double mean = s / m, var = s2 / m - mean * mean;
   return (var > 0) ? MathSqrt(var) * MathSqrt(252.0) : 0;
}

//--- signed net lots of this EA
double NetLots()
{
   double net = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      double v = PositionGetDouble(POSITION_VOLUME);
      net += (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? v : -v;
   }
   return net;
}

void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         trade.PositionClose(t);
   }
}

string GvKey() { return "TSMOM_month_" + _Symbol + "_" + IntegerToString((long)InpMagic); }
int  MonthKey(const datetime t) { MqlDateTime d; TimeToStruct(t, d); return d.year * 12 + d.mon; }

//--- signal parts for the panel and the trade
double Signal(double &r1, double &r3, double &r12)
{
   r1 = Ret(21); r3 = Ret(63); r12 = Ret(252);
   double sig;
   if(InpMode == 0)      sig = Sign(Ret(InpLookbackDays));
   else if(InpMode == 1) sig = (Sign(r1) + Sign(r3) + Sign(r12)) / 3.0;
   else                  sig = 1.0;
   if(sig < 0 && !InpAllowShort) sig = 0;
   return sig;
}

double TargetLots(const double sig, double &vol)
{
   vol = AnnVol();
   double price = iClose(_Symbol, PERIOD_D1, 1);
   double cs = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(vol <= 0 || price <= 0 || cs <= 0) return 0;
   double value = MathMin(eq * (InpTargetVol / 100.0) / vol * MathAbs(sig), InpMaxLeverage * eq);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lots = MathFloor(value / (price * cs) / step) * step;
   if(lots < minLot) lots = 0;
   lots = MathMin(lots, MathMin(maxLot, InpMaxLots));
   return Sign(sig) * lots;
}

string Arrow(const double r) { return (r > 0) ? "UP" : (r < 0 ? "DOWN" : "-"); }

void Panel()
{
   if(!InpShowPanel) return;
   double r1, r3, r12, vol;
   double sig = Signal(r1, r3, r12);
   double want = TargetLots(sig, vol);
   double have = NetLots();
   int last = GlobalVariableCheck(GvKey()) ? (int)GlobalVariableGet(GvKey()) : 0;
   string pos = (want > 0) ? "LONG " : (want < 0 ? "SHORT " : "FLAT ");
   Comment("TSMOM LIVE (gold trend following, monthly)\n",
           "Status: ", (InpEnableTrading ? "ACTIVE" : "PANEL ONLY"), "\n",
           "1 month : ", DoubleToString(r1 * 100, 1), "%  ", Arrow(r1), "\n",
           "3 months: ", DoubleToString(r3 * 100, 1), "%  ", Arrow(r3), "\n",
           "12 months: ", DoubleToString(r12 * 100, 1), "%  ", Arrow(r12), "\n",
           "Score: ", DoubleToString(sig, 2), "  (+1 full long ... -1 full short)\n",
           "Gold volatility: ", DoubleToString(vol * 100, 1), "% a year\n",
           "Target: ", pos, DoubleToString(MathAbs(want), 2), " lots  |  Holding: ", DoubleToString(have, 2), " lots\n",
           "Last rebalance month: ", (last > 0 ? IntegerToString((last - 1) / 12) + "-" + IntegerToString((last - 1) % 12 + 1) : "never"),
           "  |  Next: first trading day of next month");
}

void OnTimer() { Panel(); }

void OnTick()
{
   datetime bt = iTime(_Symbol, PERIOD_D1, 0);
   if(bt == lastBar) return;
   lastBar = bt;
   Panel();
   if(!InpEnableTrading) return;
   if(iBars(_Symbol, PERIOD_D1) < 260) return;
   int mk = MonthKey(bt);
   if(GlobalVariableCheck(GvKey()) && (int)GlobalVariableGet(GvKey()) == mk) return;   // already done this month
   cRebal++;

   double r1, r3, r12, vol;
   double sig = Signal(r1, r3, r12);
   double want = TargetLots(sig, vol);
   double have = NetLots();
   bool flip = (Sign(want) != Sign(have));
   bool resize = (!flip && MathAbs(have) > 0 && MathAbs(MathAbs(want) - MathAbs(have)) / MathAbs(have) > InpMinChange);
   PrintFormat("REBAL %d-%02d r1=%.1f%% r3=%.1f%% r12=%.1f%% score=%.2f vol=%.1f%% want=%.2f have=%.2f",
               (mk - 1) / 12, (mk - 1) % 12 + 1, r1 * 100, r3 * 100, r12 * 100, sig, vol * 100, want, have);
   bool ok = true;
   if(flip || resize)
   {
      if(flip) cFlip++; else cResize++;
      CloseAll();
      if(want > 0)      ok = trade.Buy(NormalizeDouble(want, 2), _Symbol, 0.0, 0.0, 0.0, "TSMOM");
      else if(want < 0) ok = trade.Sell(NormalizeDouble(-want, 2), _Symbol, 0.0, 0.0, 0.0, "TSMOM");
      PrintFormat("ORDER result %d %s", (int)trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   if(ok) GlobalVariableSet(GvKey(), (double)mk);
   Panel();
}
//+------------------------------------------------------------------+
