//+------------------------------------------------------------------+
//|  Tsmom_XAUUSD.mq5 (v1) -- time-series momentum on gold (D1 chart) |
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
input ulong  InpMagic        = 20261220;
input int    InpDeviation    = 50;

CTrade   trade;
datetime lastBar = 0;
int      cRebal = 0, cFlip = 0, cResize = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   if(_Period != PERIOD_D1) Print("WARNING: attach to a D1 chart");
   PrintFormat("TSMOM started on %s, mode %d, target vol %.1f%%", _Symbol, InpMode, InpTargetVol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
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

bool RebalanceDay()
{
   MqlDateTime a, b;
   TimeToStruct(iTime(_Symbol, PERIOD_D1, 0), a);
   TimeToStruct(iTime(_Symbol, PERIOD_D1, 1), b);
   if(InpRebalance == 0) return a.mon != b.mon;
   return a.day_of_week < b.day_of_week;                 // first trading day of a new week
}

void OnTick()
{
   datetime bt = iTime(_Symbol, PERIOD_D1, 0);
   if(bt == lastBar) return;
   bool first = (lastBar == 0);
   lastBar = bt;
   if(!first && !RebalanceDay()) return;
   if(iBars(_Symbol, PERIOD_D1) < 260) return;
   cRebal++;

   // 1. direction / strength of the signal
   double sig;
   if(InpMode == 0)      sig = Sign(Ret(InpLookbackDays));
   else if(InpMode == 1) sig = (Sign(Ret(21)) + Sign(Ret(63)) + Sign(Ret(252))) / 3.0;
   else                  sig = 1.0;
   if(sig < 0 && !InpAllowShort) sig = 0;

   // 2. size for the volatility target
   double vol = AnnVol();
   double price = iClose(_Symbol, PERIOD_D1, 1);
   double cs = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(vol <= 0 || price <= 0 || cs <= 0) return;
   double value = eq * (InpTargetVol / 100.0) / vol * MathAbs(sig);
   value = MathMin(value, InpMaxLeverage * eq);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lots = MathFloor(value / (price * cs) / step) * step;
   if(lots < minLot) lots = 0;
   if(lots > maxLot) lots = maxLot;
   double want = Sign(sig) * lots;

   // 3. trade only when the direction flips or the size changes enough
   double have = NetLots();
   bool flip = (Sign(want) != Sign(have));
   bool resize = (!flip && MathAbs(have) > 0 && MathAbs(MathAbs(want) - MathAbs(have)) / MathAbs(have) > InpMinChange);
   PrintFormat("REBAL sig=%.2f vol=%.1f%% want=%.2f have=%.2f", sig, vol * 100, want, have);
   if(!flip && !resize) return;
   if(flip) cFlip++; else cResize++;
   CloseAll();
   if(want > 0) trade.Buy(NormalizeDouble(want, 2), _Symbol, 0.0, 0.0, 0.0, "TSMOM");
   else if(want < 0) trade.Sell(NormalizeDouble(-want, 2), _Symbol, 0.0, 0.0, 0.0, "TSMOM");
}
//+------------------------------------------------------------------+
