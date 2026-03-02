//+------------------------------------------------------------------+
//|  EURUSD Heiken Ashi Range Bot v5.0                               |
//|  Fixes: unified $2 lock/$1.75 max-loss, early entry default,    |
//|  range uses prior full-day H/L, zone NONE no longer blocks,     |
//|  mid-range trades fully validated before entry, smarter close   |
//+------------------------------------------------------------------+
#property copyright   "EURUSD HA Range Bot"
#property version     "5.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;

//=== INPUTS ===

input group "=== LOT SIZING ==="
input bool   AutoLotSize      = true;
input double ManualLotSize    = 0.01;
input double MaxLotSize       = 0.10;   // Hard cap lowered — protects against large early losses

input group "=== RISK & PROFIT (at 0.01 lot baseline) ==="
input double TakeProfitUSD    = 3.00;   // Full TP target (scaled with lot)
input double StopLossUSD      = 1.75;   // Broker SL price level ($1.75 per 0.01 lot, scaled)
input double MaxLossUSD       = 1.75;   // Hard max loss before forced close — NEVER exceed (per 0.01 lot)
input double LockProfitUSD    = 2.00;   // Lock profit at $2 (applies to ALL trade types, no exceptions)
input double TrailingLockUSD  = 0.30;   // Trail gap once locked (scaled)
// Mid-range / sideways: same $2 lock, but tighter TP to not overstay
input double MidRangeTPUSD    = 2.00;   // TP for mid-range/sideways trades — take it at $2 (per 0.01 lot)
// Mid-range time-exit: close if stalling below this profit after MidRangeMaxBars
input double MidRangeStallUSD = 0.50;   // Close mid-range trade if below this after stall period (per 0.01 lot)
input int    MidRangeMaxBars  = 16;     // Mid-range max hold before stall-exit check (bars, 16 = 4h)

input group "=== TIME FILTERS ==="
input int    MaxHoldBars      = 32;     // Max 15M bars to hold = 8 hours, then exit
input int    SidewaysBars     = 8;      // Bars to check for compressed/sideways range
input double SidewaysPips     = 15;     // If range < this many pips over SidewaysBars = sideways

input group "=== SESSION TIMES (Broker Server Time) ==="
input int    AsianStartHour   = 0;
input int    AsianEndHour     = 8;
input int    LondonStartHour  = 8;
input int    LondonEndHour    = 16;
input int    NewYorkStartHour = 13;
input int    NewYorkEndHour   = 21;

input group "=== MANUAL RANGE OVERRIDE ==="
input bool   UseManualRange   = false;
input double ManualRangeHigh  = 0.0;
input double ManualRangeLow   = 0.0;

input group "=== HEIKEN ASHI SETTINGS ==="
input int    MaxConsecCandles    = 4;
// Entry mode:
// 1 = EARLY (default) — enter within first EarlyEntryMins of the confirming candle
//     Requires clean bottomless/topless candle (no double-sided wicks)
// 2 = LATE            — enter in last 5 min of the bar AFTER the confirming candle
input int    HAEntryMode         = 1;      // 1=Early entry (default), 2=Late entry
input int    EarlyEntryMins      = 5;      // Minutes window for early entry (5 min on 15M chart)
input int    BollingerPeriod     = 21;     // Bollinger middle-line SMA period (M15)

input group "=== FIBONACCI & PIVOT CONFLUENCE ==="
input bool   UseFibPivot         = true;   // Enable Fib/Pivot confluence filter
input bool   RequireFibPivot     = false;  // If true: skip trade unless near a level; if false: just adjust targets
input double FibPivotZonePips    = 8.0;    // Pip radius to count as "near" a fib/pivot level
// Fibonacci levels drawn from the current session range
input bool   ShowFibLevels       = true;   // Draw fib lines on chart
// Daily pivot (standard floor pivot from previous day)
input bool   UseDailyPivot       = true;   // Include daily pivot S1/R1/PP in confluence

input group "=== RANGE ZONE FILTERS ==="
// How far inside range boundaries before a trade is allowed (as % of total range)
input double MidZonePct       = 0.30;   // Mid zone = middle 30% of range (15% each side of mid)
input double ExtremePct       = 0.15;   // Extreme zone = outer 15% near H/L (avoid for trend)
// Mean reversion: enter when HA confirms bounce from range extreme
input bool   AllowMeanReversion = true; // Enable HA-confirmed mean reversion trades at range extremes

input group "=== ATR & RANGE CONFIDENCE ==="
input int    ATRPeriod        = 14;
input double ATRMultiplierCI  = 1.5;

input group "=== GEOPOLITICAL BIAS ==="
input string GeoPoliticsNote  = "";
input int    EURGeoBias       = 0;
input int    USDGeoBias       = 0;

input group "=== NEWS EVENTS ==="
input string NewsNote         = "";
input int    NewsImpactEUR    = 0;
input int    NewsImpactUSD    = 0;

input group "=== DASHBOARD POSITION ==="
input int    DashboardCorner  = 0;
input int    DashboardX       = 10;
input int    DashboardY       = 20;

//=== GLOBALS ===
double g_AsianHigh  = 0, g_AsianLow  = 0, g_AsianOpen  = 0;
double g_LondonHigh = 0, g_LondonLow = 0, g_LondonOpen = 0;
double g_TodayHigh  = 0, g_TodayLow  = 0, g_TodayOpen  = 0;
double g_RangeHigh  = 0, g_RangeLow  = 0, g_RangeMid = 0;
double g_CIHigh     = 0, g_CILow     = 0, g_ATR      = 0;

// Session seeded flags — true only after a successful CopyHigh call
// (NOT set by UpdateLiveSessionBar so the retry keeps firing until real data arrives)
bool   g_AsianSeeded  = false;
bool   g_LondonSeeded = false;

bool   g_TradeOpen    = false;
bool   g_ProfitLocked = false;
double g_PeakProfit   = 0;
double g_CurrentLot   = 0.01;
int    g_TotalBias    = 0;

// Lot-scaled thresholds — recalculated at trade open
double g_ScaledLockUSD  = 2.00;
double g_ScaledTrailUSD = 0.30;
double g_ScaledTPUSD    = 3.00;
double g_ScaledSLUSD    = 2.00;

// Trade context flags set at entry
bool   g_IsNearMid      = false;   // trade entered near midrange → tighter targets
bool   g_IsMeanRev      = false;   // trade is a mean reversion setup
int    g_OpenBarCount   = 0;       // bars elapsed since trade opened
datetime g_TradeOpenTime = 0;

// HA state machine
bool   g_HABullSetup  = false;
bool   g_HABearSetup  = false;
string g_Signal       = "WAITING";
int    g_HAConsecCount= 0;
// Early entry: track when the 2nd (confirming) candle opened so we
// know whether we are within EarlyEntryMins of its start
datetime g_ConfirmCandleOpen = 0;   // time the confirming candle opened

// Bollinger middle line (M15, BollingerPeriod SMA)
double   g_BollingerMid1 = 0;       // confirmed bar 1 (most recent closed bar)
double   g_BollingerMid2 = 0;       // confirmed bar 2

// Mean reversion two-candle state machine
bool     g_MRVArmed       = false;
int      g_MRVDir         = 0;       // 1=buy bounce, -1=sell bounce
datetime g_MRVConfirmOpen = 0;       // open time of bar after 2nd confirming MRV candle

// Fibonacci & Pivot levels (recalculated each day/session)
double g_PivotPP  = 0, g_PivotR1 = 0, g_PivotS1 = 0;
double g_PivotR2  = 0, g_PivotS2 = 0;
double g_Fib236   = 0, g_Fib382  = 0, g_Fib500  = 0;
double g_Fib618   = 0, g_Fib764  = 0;
string g_NearLevel = "";    // label of the nearest confluence level at entry

// Zone classification for display
string g_ZoneLabel    = "UNKNOWN";

datetime g_LastBarTime  = 0;
datetime g_LastDayReset = 0;

string DASH_PREFIX = "HABOT_DASH_";

//+------------------------------------------------------------------+
//| RESTORE EXISTING TRADE STATE on EA attach / reload              |
//| Scans open positions and rebuilds all relevant globals so that   |
//| ManageOpenTrade(), the one-trade guard, and dashboard all work  |
//+------------------------------------------------------------------+
void RestoreExistingTrade()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i))         continue;
      if(posInfo.Symbol() != _Symbol)        continue;
      if(posInfo.Magic()  != 202502)         continue;

      // ---- Found a matching open position ----
      double   lot      = posInfo.Volume();
      datetime openTime = posInfo.Time();
      double   profit   = posInfo.Commission() + posInfo.Swap() + posInfo.Profit();
      string   comment  = posInfo.Comment();

      g_TradeOpen     = true;
      g_CurrentLot    = lot;
      g_TradeOpenTime = openTime;
      g_Signal        = "WAITING";   // block new entries while trade is live

      // Estimate bars elapsed since open (15-min bars)
      int elapsed = (int)((TimeCurrent() - openTime) / (15 * 60));
      g_OpenBarCount = (elapsed > 0) ? elapsed : 0;

      // Infer trade context from the stored comment/tag
      g_IsMeanRev = (StringFind(comment, "MRV") >= 0);
      g_IsNearMid = g_IsMeanRev;   // MRV is always mid-context; trend zone not recoverable

      // Rebuild scaled USD thresholds from current input values
      double lockBase = LockProfitUSD;
      double tpBase   = g_IsNearMid ? MidRangeTPUSD : TakeProfitUSD;
      double slBase   = StopLossUSD;
      SetScaledThresholds(lot, lockBase, tpBase, slBase);

      // Restore peak profit and lock flag
      g_PeakProfit   = (profit > 0.0) ? profit : 0.0;
      g_ProfitLocked = (profit >= g_ScaledLockUSD);

      Print("RESTORED position | Ticket:", posInfo.Ticket(),
            "  Lot:", DoubleToString(lot, 2),
            "  Bars:", g_OpenBarCount,
            "  P&L:$", DoubleToString(profit, 2),
            "  Locked:", (g_ProfitLocked ? "YES" : "NO"),
            "  MeanRev:", (g_IsMeanRev ? "YES" : "NO"),
            "  Tag:", comment);
      return;   // only one trade managed at a time
   }
   Print("RestoreExistingTrade: no matching position found");
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(202502);
   trade.SetDeviationInPoints(20);
   trade.SetAsyncMode(false);

   // Seed ranges from historical data immediately
   SeedRangesFromHistory();
   // Recover any pre-existing trade so management rules apply immediately
   RestoreExistingTrade();
   RecalcBias();
   // Seed zone label and live session bar so dashboard is correct before first tick
   UpdateLiveSessionBar();
   g_ZoneLabel = ClassifyZone(SymbolInfoDouble(_Symbol, SYMBOL_BID));
   UpdateDashboard();
   Print("HA Range Bot v5 initialized. Range H=", g_RangeHigh, " L=", g_RangeLow);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, DASH_PREFIX);
   ObjectsDeleteAll(0, "HABOT_LVL_");
   Comment("");
}

//+------------------------------------------------------------------+
//| MAIN TICK                                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   // Always manage open trade on every tick
   if(g_TradeOpen) ManageOpenTrade();

   // --- Retry session seeding if data wasn't ready on OnInit ---
   // Key: use !g_AsianSeeded / !g_LondonSeeded flags (NOT g_AsianHigh==0),
   // because UpdateLiveSessionBar sets H/L from bar[0] alone on every tick,
   // which would falsely block the retry from firing on tick 2+.
   MqlDateTime nowDt;
   TimeToStruct(TimeCurrent(), nowDt);
   datetime dayStart0 = (datetime)(TimeCurrent() - (nowDt.hour*3600 + nowDt.min*60 + nowDt.sec));
   if(!g_AsianSeeded) {
      datetime aStart = dayStart0 + (datetime)(AsianStartHour * 3600);
      datetime aEnd   = dayStart0 + (datetime)(AsianEndHour   * 3600);
      if(TimeCurrent() > aStart) {
         datetime aTo = (TimeCurrent() < aEnd) ? TimeCurrent() : aEnd;
         g_AsianSeeded = SeedSessionHL(aStart, aTo, g_AsianHigh, g_AsianLow, g_AsianOpen);
      }
   }
   if(!g_LondonSeeded) {
      datetime lStart = dayStart0 + (datetime)(LondonStartHour * 3600);
      datetime lEnd   = dayStart0 + (datetime)(LondonEndHour   * 3600);
      if(TimeCurrent() > lStart) {
         datetime lTo = (TimeCurrent() < lEnd) ? TimeCurrent() : lEnd;
         g_LondonSeeded = SeedSessionHL(lStart, lTo, g_LondonHigh, g_LondonLow, g_LondonOpen);
      }
   }

   // Always track live bar[0] for session ranges (captures new session opening immediately)
   UpdateLiveSessionBar();

   // Always keep zone label current so dashboard never shows UNKNOWN
   g_ZoneLabel = ClassifyZone(SymbolInfoDouble(_Symbol, SYMBOL_BID));

   // New bar processing
   datetime barTime = iTime(_Symbol, PERIOD_M15, 0);
   bool isNewBar = (barTime != g_LastBarTime);

   if(isNewBar)
   {
      g_LastBarTime = barTime;

      // Count bars since trade open
      if(g_TradeOpen) g_OpenBarCount++;

      // Daily reset check
      MqlDateTime dt;
      TimeToStruct(barTime, dt);
      datetime dayStart = (datetime)(barTime - (dt.hour*3600 + dt.min*60 + dt.sec));
      if(dayStart != g_LastDayReset) {
         g_LastDayReset = dayStart;
         ResetDailyRanges();
      }

      UpdateSessionRanges();
      g_CurrentLot = CalcLot();
      ComputeATR();
      CalcBollinger();
      SetActiveRange();
      RecalcBias();
      CalcFibPivotLevels();   // recalc on every new bar
      EvaluateHAPattern();
   }

   // Fire TryEntry when trend signal active OR mean reversion setup exists
   if(!g_TradeOpen) {
      bool hasTrendSig = (g_Signal == "BUY INCOMING" || g_Signal == "SELL INCOMING");
      bool hasMeanRev  = (MeanReversionSetup() != 0);
      if(hasTrendSig || hasMeanRev) TryEntry();
   }

   UpdateDashboard();
}

//+------------------------------------------------------------------+
//| SESSION RANGE HELPER                                             |
//| Uses CopyHigh/CopyLow with datetime-range signature — this asks  |
//| the terminal database directly and returns data immediately,     |
//| even on first attach, regardless of chart zoom or buffer state.  |
//| Also captures the session open (first bar open in the window).  |
//| Returns true if data was successfully read.                      |
//+------------------------------------------------------------------+
bool SeedSessionHL(datetime fromTime, datetime toTime, double &hi, double &lo, double &op)
{
   if(fromTime >= toTime) return false;

   double arrH[], arrL[], arrO[];
   // CopyXxx with datetime range: asks terminal DB, not chart buffer
   int copied = CopyHigh(_Symbol, PERIOD_M15, fromTime, toTime, arrH);
   if(copied <= 0) {
      Print("SeedSessionHL: CopyHigh returned ", copied,
            " from ", TimeToString(fromTime), " to ", TimeToString(toTime));
      return false;
   }
   CopyLow (_Symbol, PERIOD_M15, fromTime, toTime, arrL);
   CopyOpen(_Symbol, PERIOD_M15, fromTime, toTime, arrO);

   // CopyXxx with datetime range returns bars oldest→newest (index 0 = earliest)
   // arrO[0] is the open of the very first bar of this session = session open price
   if(ArraySize(arrO) > 0 && arrO[0] > 0 && op == 0) op = arrO[0];

   for(int i = 0; i < copied; i++) {
      if(arrH[i] > 0 && (hi == 0 || arrH[i] > hi)) hi = arrH[i];
      if(arrL[i] > 0 && (lo == 0 || arrL[i] < lo)) lo = arrL[i];
   }
   return true;
}

//+------------------------------------------------------------------+
//| Seed ranges from existing history bars on startup               |
//| Uses iHighest/iLowest calls — instant, like iHigh(D1,1)        |
//+------------------------------------------------------------------+
void SeedRangesFromHistory()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   datetime dayStart = (datetime)(TimeCurrent() - (now.hour*3600 + now.min*60 + now.sec));

   // --- Previous day: single call, always instant ---
   g_RangeHigh = iHigh(_Symbol, PERIOD_D1, 1);
   g_RangeLow  = iLow (_Symbol, PERIOD_D1, 1);
   if(g_RangeHigh > 0 && g_RangeLow > 0)
      g_RangeMid = (g_RangeHigh + g_RangeLow) / 2.0;

   // --- Today overall: midnight → now ---
   SeedSessionHL(dayStart, TimeCurrent(), g_TodayHigh, g_TodayLow, g_TodayOpen);

   // --- Asian session: only if we are past or inside Asian hours ---
   datetime asianStart = dayStart + (datetime)(AsianStartHour  * 3600);
   datetime asianEnd   = dayStart + (datetime)(AsianEndHour    * 3600);
   if(TimeCurrent() > asianStart) {
      datetime asianTo = (TimeCurrent() < asianEnd) ? TimeCurrent() : asianEnd;
      g_AsianSeeded = SeedSessionHL(asianStart, asianTo, g_AsianHigh, g_AsianLow, g_AsianOpen);
   }

   // --- London session: only if we are past or inside London hours ---
   datetime londonStart = dayStart + (datetime)(LondonStartHour * 3600);
   datetime londonEnd   = dayStart + (datetime)(LondonEndHour   * 3600);
   if(TimeCurrent() > londonStart) {
      datetime londonTo = (TimeCurrent() < londonEnd) ? TimeCurrent() : londonEnd;
      g_LondonSeeded = SeedSessionHL(londonStart, londonTo, g_LondonHigh, g_LondonLow, g_LondonOpen);
   }

   // Fallback: if today has no data at all, g_RangeHigh/Low from D1 already set above
   SetActiveRange();
   CalcFibPivotLevels();
   Print("SeedRangesFromHistory: PrevDay H=", DoubleToString(g_RangeHigh,5),
         " L=", DoubleToString(g_RangeLow,5),
         " | Asian H=", DoubleToString(g_AsianHigh,5), " L=", DoubleToString(g_AsianLow,5),
         " | London H=", DoubleToString(g_LondonHigh,5), " L=", DoubleToString(g_LondonLow,5));
}

//+------------------------------------------------------------------+
//| Reset at midnight
//+------------------------------------------------------------------+
void ResetDailyRanges()
{
   // Save yesterday's range as fallback
   double prevH = g_TodayHigh;
   double prevL = g_TodayLow;

   g_AsianHigh = 0; g_AsianLow  = 0; g_AsianOpen  = 0; g_AsianSeeded  = false;
   g_LondonHigh= 0; g_LondonLow = 0; g_LondonOpen = 0; g_LondonSeeded = false;
   g_TodayHigh = 0; g_TodayLow  = 0; g_TodayOpen  = 0;

   // Use yesterday as initial range (Asian session fallback)
   if(prevH > 0 && prevL > 0) {
      g_RangeHigh = prevH;
      g_RangeLow  = prevL;
      g_RangeMid  = (prevH + prevL) / 2.0;
   } else {
      // Grab from D1
      g_RangeHigh = iHigh(_Symbol, PERIOD_D1, 1);
      g_RangeLow  = iLow(_Symbol,  PERIOD_D1, 1);
      if(g_RangeHigh > 0 && g_RangeLow > 0)
         g_RangeMid = (g_RangeHigh + g_RangeLow) / 2.0;
   }

   g_ProfitLocked      = false;
   g_PeakProfit        = 0;
   g_HABullSetup       = false;
   g_HABearSetup       = false;
   g_Signal            = "WAITING";
   g_OpenBarCount      = 0;
   g_ConfirmCandleOpen = 0;
   g_MRVArmed          = false;
   g_MRVDir            = 0;
   g_MRVConfirmOpen    = 0;
   Print("Day reset. Prev range: H=", g_RangeHigh, " L=", g_RangeLow);
}

//+------------------------------------------------------------------+
//| Update session ranges from bar[1] (called on each new bar)      |
//+------------------------------------------------------------------+
void UpdateSessionRanges()
{
   double hi = iHigh(_Symbol, PERIOD_M15, 1);
   double lo = iLow(_Symbol,  PERIOD_M15, 1);
   datetime t = iTime(_Symbol, PERIOD_M15, 1);

   MqlDateTime bdt;
   TimeToStruct(t, bdt);
   int h = bdt.hour;

   if(g_TodayHigh == 0 || hi > g_TodayHigh) g_TodayHigh = hi;
   if(g_TodayLow  == 0 || lo < g_TodayLow)  g_TodayLow  = lo;

   if(h >= AsianStartHour && h < AsianEndHour) {
      if(g_AsianOpen == 0) g_AsianOpen = iOpen(_Symbol, PERIOD_M15, 1);
      if(g_AsianHigh == 0 || hi > g_AsianHigh) g_AsianHigh = hi;
      if(g_AsianLow  == 0 || lo < g_AsianLow)  g_AsianLow  = lo;
   }
   if(h >= LondonStartHour && h < LondonEndHour) {
      if(g_LondonOpen == 0) g_LondonOpen = iOpen(_Symbol, PERIOD_M15, 1);
      if(g_LondonHigh == 0 || hi > g_LondonHigh) g_LondonHigh = hi;
      if(g_LondonLow  == 0 || lo < g_LondonLow)  g_LondonLow  = lo;
   }
}

//+------------------------------------------------------------------+
//| Update session ranges from bar[0] (live bar — called every tick) |
//| Ensures session H/L shows data immediately as a new session opens|
//+------------------------------------------------------------------+
void UpdateLiveSessionBar()
{
   double liveHi = iHigh(_Symbol, PERIOD_M15, 0);
   double liveLo = iLow (_Symbol, PERIOD_M15, 0);
   double liveOp = iOpen(_Symbol, PERIOD_M15, 0);
   datetime liveT = iTime(_Symbol, PERIOD_M15, 0);

   MqlDateTime ldt;
   TimeToStruct(liveT, ldt);
   int h = ldt.hour;

   if(g_TodayHigh == 0 || liveHi > g_TodayHigh) g_TodayHigh = liveHi;
   if(g_TodayLow  == 0 || liveLo < g_TodayLow)  g_TodayLow  = liveLo;

   if(h >= AsianStartHour && h < AsianEndHour) {
      if(g_AsianOpen == 0) g_AsianOpen = liveOp;
      if(g_AsianHigh == 0 || liveHi > g_AsianHigh) g_AsianHigh = liveHi;
      if(g_AsianLow  == 0 || liveLo  < g_AsianLow)  g_AsianLow  = liveLo;
   }
   if(h >= LondonStartHour && h < LondonEndHour) {
      if(g_LondonOpen == 0) g_LondonOpen = liveOp;
      if(g_LondonHigh == 0 || liveHi > g_LondonHigh) g_LondonHigh = liveHi;
      if(g_LondonLow  == 0 || liveLo  < g_LondonLow)  g_LondonLow  = liveLo;
   }
   if(h >= NewYorkStartHour && h < NewYorkEndHour) {
      // NY session overlaps with London — TodayHigh/Low covers it,
      // but we also track it explicitly for any future NY-specific logic
      // (no separate NY globals exist yet — data flows into TodayHigh/Low)
   }
}

//+------------------------------------------------------------------+
//| Pick the right range to trade against for current session        |
//+------------------------------------------------------------------+
//| SET ACTIVE RANGE                                                  |
//| Primary range = previous complete day H/L (always reliable).     |
//| Session sub-ranges (Asian/London) used as context for zone bias  |
//| but the core H/L/Mid for filters is the prior day range.         |
//| This avoids the "Asian still forming → narrow London range" trap.|
//+------------------------------------------------------------------+
void SetActiveRange()
{
   if(UseManualRange && ManualRangeHigh > 0 && ManualRangeLow > 0) {
      g_RangeHigh = ManualRangeHigh;
      g_RangeLow  = ManualRangeLow;
      g_RangeMid  = (g_RangeHigh + g_RangeLow) / 2.0;
      return;
   }

   // --- Primary: prior D1 bar (yesterday's complete range) ---
   double prevDayH = iHigh (_Symbol, PERIOD_D1, 1);
   double prevDayL = iLow  (_Symbol, PERIOD_D1, 1);

   if(prevDayH > 0 && prevDayL > 0) {
      g_RangeHigh = prevDayH;
      g_RangeLow  = prevDayL;
      g_RangeMid  = (g_RangeHigh + g_RangeLow) / 2.0;
   }
   else if(g_TodayHigh > 0) {
      // Fallback: use what we have today
      g_RangeHigh = g_TodayHigh;
      g_RangeLow  = g_TodayLow;
      g_RangeMid  = (g_RangeHigh + g_RangeLow) / 2.0;
   }
   // g_AsianHigh/g_LondonHigh are still tracked and shown on dashboard
   // but no longer override the primary range
}

//+------------------------------------------------------------------+
//| Compute ATR on H1                                                 |
//+------------------------------------------------------------------+
void ComputeATR()
{
   int handle = iATR(_Symbol, PERIOD_H1, ATRPeriod);
   if(handle == INVALID_HANDLE) return;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, 0, 3, buf) > 0) {
      g_ATR = buf[1];  // use confirmed bar
   }
   IndicatorRelease(handle);

   if(g_TodayHigh > 0 && g_TodayLow > 0) {
      double mid   = (g_TodayHigh + g_TodayLow) / 2.0;
      g_CIHigh = mid + ATRMultiplierCI * g_ATR;
      g_CILow  = mid - ATRMultiplierCI * g_ATR;
   }
}

//+------------------------------------------------------------------+
//| BOLLINGER MIDDLE LINE (SMA) for M15                              |
//| Populates g_BollingerMid1 (bar 1) and g_BollingerMid2 (bar 2)  |
//+------------------------------------------------------------------+
void CalcBollinger()
{
   int handle = iBands(_Symbol, PERIOD_M15, BollingerPeriod, 0, 2.0, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return;
   double mid[];
   ArraySetAsSeries(mid, true);
   if(CopyBuffer(handle, 0, 0, 4, mid) >= 3) {   // buffer 0 = middle/SMA line
      g_BollingerMid1 = mid[1];   // confirmed bar 1
      g_BollingerMid2 = mid[2];   // confirmed bar 2
   }
   IndicatorRelease(handle);
}

//+------------------------------------------------------------------+
//| HEIKEN ASHI CALCULATION for bar at index idx                     |
//+------------------------------------------------------------------+
void CalcHA(int idx, double &haO, double &haH, double &haL, double &haC)
{
   double o  = iOpen (_Symbol, PERIOD_M15, idx);
   double h  = iHigh (_Symbol, PERIOD_M15, idx);
   double l  = iLow  (_Symbol, PERIOD_M15, idx);
   double c  = iClose(_Symbol, PERIOD_M15, idx);

   haC = (o + h + l + c) / 4.0;

   // HA Open needs the previous bar's HA values
   double prevO = iOpen (_Symbol, PERIOD_M15, idx + 1);
   double prevH = iHigh (_Symbol, PERIOD_M15, idx + 1);
   double prevL = iLow  (_Symbol, PERIOD_M15, idx + 1);
   double prevC = iClose(_Symbol, PERIOD_M15, idx + 1);

   double prevHaC = (prevO + prevH + prevL + prevC) / 4.0;
   double prevHaO = (iOpen(_Symbol, PERIOD_M15, idx + 2) + iClose(_Symbol, PERIOD_M15, idx + 2)) / 2.0;
   // Recursive prev HA open (simplified 2-step lookback — good enough for signal detection)
   haO = (prevHaO + prevHaC) / 2.0;

   haH = MathMax(h, MathMax(haO, haC));
   haL = MathMin(l, MathMin(haO, haC));
}

// Returns: 1=bull, -1=bear, 0=doji
int HADir(int idx)
{
   double haO, haH, haL, haC;
   CalcHA(idx, haO, haH, haL, haC);
   if(haC > haO + _Point) return  1;
   if(haC < haO - _Point) return -1;
   return 0;
}

// Bottomless = bullish candle with NO lower shadow (haLow == haOpen)
bool IsBottomless(int idx)
{
   double haO, haH, haL, haC;
   CalcHA(idx, haO, haH, haL, haC);
   return (haC > haO + _Point && MathAbs(haL - haO) <= _Point * 3);
}

// Topless = bearish candle with NO upper shadow (haHigh == haOpen)
bool IsTopless(int idx)
{
   double haO, haH, haL, haC;
   CalcHA(idx, haO, haH, haL, haC);
   return (haC < haO - _Point && MathAbs(haH - haO) <= _Point * 3);
}

// Bullish candle BUT has a noticeable upper wick too (spike on top = indecision)
// Used to reject weak confirming candles in early-entry mode
bool IsBottomlessWithTopSpike(int idx)
{
   double haO, haH, haL, haC;
   CalcHA(idx, haO, haH, haL, haC);
   if(haC <= haO) return false;           // not bullish
   double bodySize  = haC - haO;
   double upperWick = haH - haC;
   // Reject if upper wick > 40% of body (candle has meaningful resistance above)
   return (upperWick > bodySize * 0.4);
}

// Bearish candle BUT has a noticeable lower wick too
bool IsToplessWithBottomSpike(int idx)
{
   double haO, haH, haL, haC;
   CalcHA(idx, haO, haH, haL, haC);
   if(haC >= haO) return false;
   double bodySize   = haO - haC;
   double lowerWick  = haC - haL;
   return (lowerWick > bodySize * 0.4);
}

//+------------------------------------------------------------------+
//| FIBONACCI & PIVOT LEVELS ENGINE                                  |
//+------------------------------------------------------------------+
void CalcFibPivotLevels()
{
   // --- Standard Floor Pivot from previous D1 bar ---
   if(UseDailyPivot) {
      double prevH = iHigh(_Symbol, PERIOD_D1, 1);
      double prevL = iLow (_Symbol, PERIOD_D1, 1);
      double prevC = iClose(_Symbol, PERIOD_D1, 1);
      if(prevH > 0 && prevL > 0 && prevC > 0) {
         g_PivotPP = (prevH + prevL + prevC) / 3.0;
         g_PivotR1 = 2.0 * g_PivotPP - prevL;
         g_PivotS1 = 2.0 * g_PivotPP - prevH;
         g_PivotR2 = g_PivotPP + (prevH - prevL);
         g_PivotS2 = g_PivotPP - (prevH - prevL);
      }
   }

   // --- Fibonacci retracement levels from current session range ---
   if(g_RangeHigh > 0 && g_RangeLow > 0) {
      double span = g_RangeHigh - g_RangeLow;
      g_Fib236 = g_RangeHigh - 0.236 * span;
      g_Fib382 = g_RangeHigh - 0.382 * span;
      g_Fib500 = g_RangeHigh - 0.500 * span;   // = midpoint
      g_Fib618 = g_RangeHigh - 0.618 * span;
      g_Fib764 = g_RangeHigh - 0.764 * span;
   }

   // Draw lines if requested
   if(ShowFibLevels) DrawFibPivotLines();
}

//--- Returns the name of the nearest Fib or Pivot level within FibPivotZonePips
string NearFibPivotLevel(double price)
{
   double zone = FibPivotZonePips * _Point * 10;  // convert pips to price

   // Check pivots
   if(UseDailyPivot && g_PivotPP > 0) {
      if(MathAbs(price - g_PivotPP) <= zone) return "Pivot PP";
      if(MathAbs(price - g_PivotR1) <= zone) return "Pivot R1";
      if(MathAbs(price - g_PivotS1) <= zone) return "Pivot S1";
      if(MathAbs(price - g_PivotR2) <= zone) return "Pivot R2";
      if(MathAbs(price - g_PivotS2) <= zone) return "Pivot S2";
   }
   // Check Fibonacci levels
   if(g_Fib382 > 0) {
      if(MathAbs(price - g_Fib236) <= zone) return "Fib 23.6%";
      if(MathAbs(price - g_Fib382) <= zone) return "Fib 38.2%";
      if(MathAbs(price - g_Fib500) <= zone) return "Fib 50.0%";
      if(MathAbs(price - g_Fib618) <= zone) return "Fib 61.8%";
      if(MathAbs(price - g_Fib764) <= zone) return "Fib 76.4%";
   }
   return "";
}

//--- Draw Fib and Pivot horizontal lines on the chart
void DrawFibPivotLines()
{
   struct LevelDef { double price; color clr; string name; };
   LevelDef levels[10];
   int      count = 0;

   if(g_Fib382 > 0) {
      levels[count].price=g_Fib236; levels[count].clr=clrDodgerBlue;      levels[count].name="F_236"; count++;
      levels[count].price=g_Fib382; levels[count].clr=clrCornflowerBlue;  levels[count].name="F_382"; count++;
      levels[count].price=g_Fib500; levels[count].clr=clrYellow;          levels[count].name="F_500"; count++;
      levels[count].price=g_Fib618; levels[count].clr=clrCornflowerBlue;  levels[count].name="F_618"; count++;
      levels[count].price=g_Fib764; levels[count].clr=clrDodgerBlue;      levels[count].name="F_764"; count++;
   }
   if(UseDailyPivot && g_PivotPP > 0) {
      levels[count].price=g_PivotPP; levels[count].clr=clrWhite;      levels[count].name="P_PP"; count++;
      levels[count].price=g_PivotR1; levels[count].clr=clrLimeGreen;  levels[count].name="P_R1"; count++;
      levels[count].price=g_PivotS1; levels[count].clr=clrTomato;     levels[count].name="P_S1"; count++;
      levels[count].price=g_PivotR2; levels[count].clr=clrLimeGreen;  levels[count].name="P_R2"; count++;
      levels[count].price=g_PivotS2; levels[count].clr=clrTomato;     levels[count].name="P_S2"; count++;
   }

   for(int i = 0; i < count; i++) {
      string name = "HABOT_LVL_" + levels[i].name;
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_HLINE, 0, 0, levels[i].price);
      else
         ObjectSetDouble(0, name, OBJPROP_PRICE, levels[i].price);
      ObjectSetInteger(0, name, OBJPROP_COLOR,     levels[i].clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE,     STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,     1);
      ObjectSetInteger(0, name, OBJPROP_BACK,      true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
      // Label at right
      ObjectSetString(0, name,  OBJPROP_TEXT,      levels[i].name + " " + DoubleToString(levels[i].price, 5));
   }
}

//+------------------------------------------------------------------+
//| Count consecutive HA candles of same direction going back        |
//+------------------------------------------------------------------+
int CountConsecutive(int startIdx, int dir)
{
   int count = 0;
   for(int i = startIdx; i <= startIdx + 20; i++) {
      if(HADir(i) == dir) count++;
      else break;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Live consecutive count: includes the currently forming bar (0)  |
//| If bar 0 has a clear direction matching bar 1, it is counted too.|
//| Used for entry guards and dashboard display.                     |
//+------------------------------------------------------------------+
int LiveHAConsecTotal()
{
   int dir0 = HADir(0);
   if(dir0 != 0)
      return CountConsecutive(0, dir0);  // bar 0 included naturally
   return g_HAConsecCount;              // forming bar is a doji — use closed count only
}

//+------------------------------------------------------------------+
//| CORE HA PATTERN DETECTION                                         |
//| Called on every new bar using confirmed closed candles           |
//+------------------------------------------------------------------+
void EvaluateHAPattern()
{
   // bar 1 = most recently closed bar
   // bar 2 = the one before that

   int dir1 = HADir(1);  // most recent closed
   int dir2 = HADir(2);  // prior closed

   bool bl1 = IsBottomless(1);
   bool bl2 = IsBottomless(2);
   bool tl1 = IsTopless(1);
   bool tl2 = IsTopless(2);

   // Count consecutive same-color candles ending at bar 1
   g_HAConsecCount = CountConsecutive(1, dir1);

   // === BUY SETUP STATE MACHINE ===
   // Step 1: bottomless bull → arm the setup
   if(bl1 && dir1 == 1) {
      g_HABullSetup        = true;
      g_HABearSetup        = false;
      g_ConfirmCandleOpen  = 0;       // not yet on confirming candle
      g_Signal             = "PREPARING BUY";
   }
   // Step 2: setup armed → next bull candle is the CONFIRMING candle
   //         Validate: both arm (bar2) and confirming (bar1) HA body mids <= Bollinger midline
   else if(g_HABullSetup && dir1 == 1) {
      if(g_HAConsecCount <= MaxConsecCandles) {
         // Bollinger gate: HA body midpoints of both candles must be <= SMA midline for BUY
         double haO1b, haH1b, haL1b, haC1b, haO2b, haH2b, haL2b, haC2b;
         CalcHA(1, haO1b, haH1b, haL1b, haC1b);
         CalcHA(2, haO2b, haH2b, haL2b, haC2b);
         double bodyMid1 = (haO1b + haC1b) / 2.0;
         double bodyMid2 = (haO2b + haC2b) / 2.0;
         bool bollOK = (g_BollingerMid1 <= 0 ||
                        (bodyMid1 <= g_BollingerMid1 && bodyMid2 <= g_BollingerMid2));
         if(bollOK) {
            if(g_ConfirmCandleOpen == 0)
               g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 1);
            g_Signal = "BUY INCOMING";
         } else {
            g_Signal            = "PREPARING BUY";  // Bollinger not validated yet
            g_ConfirmCandleOpen = 0;
         }
      } else {
         g_Signal            = "WAITING";
         g_HABullSetup       = false;
         g_ConfirmCandleOpen = 0;
      }
   }

   // === SELL SETUP STATE MACHINE ===
   else if(tl1 && dir1 == -1) {
      g_HABearSetup        = true;
      g_HABullSetup        = false;
      g_ConfirmCandleOpen  = 0;
      g_Signal             = "PREPARING SELL";
   }
   else if(g_HABearSetup && dir1 == -1) {
      if(g_HAConsecCount <= MaxConsecCandles) {
         // Bollinger gate: HA body midpoints of both candles must be >= SMA midline for SELL
         double haO1s, haH1s, haL1s, haC1s, haO2s, haH2s, haL2s, haC2s;
         CalcHA(1, haO1s, haH1s, haL1s, haC1s);
         CalcHA(2, haO2s, haH2s, haL2s, haC2s);
         double bodyMid1s = (haO1s + haC1s) / 2.0;
         double bodyMid2s = (haO2s + haC2s) / 2.0;
         bool bollOK = (g_BollingerMid1 <= 0 ||
                        (bodyMid1s >= g_BollingerMid1 && bodyMid2s >= g_BollingerMid2));
         if(bollOK) {
            if(g_ConfirmCandleOpen == 0)
               g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 1);
            g_Signal = "SELL INCOMING";
         } else {
            g_Signal            = "PREPARING SELL"; // Bollinger not validated yet
            g_ConfirmCandleOpen = 0;
         }
      } else {
         g_Signal            = "WAITING";
         g_HABearSetup       = false;
         g_ConfirmCandleOpen = 0;
      }
   }
   // Direction flip — reset
   else if(dir1 == 1 && g_HABearSetup) {
      g_HABearSetup       = false;
      g_ConfirmCandleOpen = 0;
      g_Signal            = "WAITING";
   }
   else if(dir1 == -1 && g_HABullSetup) {
      g_HABullSetup       = false;
      g_ConfirmCandleOpen = 0;
      g_Signal            = "WAITING";
   }

   // === MEAN REVERSION TWO-CANDLE STATE MACHINE ===
   // Bar-level (confirmed closed bars only). Bollinger validates each candle body mid.
   if(AllowMeanReversion && g_RangeHigh > 0 && g_RangeLow > 0) {
      double mrvRangeSize = g_RangeHigh - g_RangeLow;
      double mrvPrice     = (iHigh(_Symbol, PERIOD_M15, 1) + iLow(_Symbol, PERIOD_M15, 1)) / 2.0;
      double mrvPos       = (mrvPrice - g_RangeLow) / mrvRangeSize;

      double haO1m, haH1m, haL1m, haC1m, haO2m, haH2m, haL2m, haC2m;
      CalcHA(1, haO1m, haH1m, haL1m, haC1m);
      CalcHA(2, haO2m, haH2m, haL2m, haC2m);
      double mrvBodyMid1 = (haO1m + haC1m) / 2.0;
      double mrvBodyMid2 = (haO2m + haC2m) / 2.0;

      // --- ARM: bar[1] at extreme zone, correct HA direction, Bollinger gate ---
      if(!g_MRVArmed && g_MRVConfirmOpen == 0) {
         if(mrvPos <= ExtremePct && dir1 == 1 &&
            (g_BollingerMid1 <= 0 || mrvBodyMid1 <= g_BollingerMid1)) {
            g_MRVArmed = true; g_MRVDir = 1; g_MRVConfirmOpen = 0;
            Print("MRV ARMED: BUY bounce setup, pos=", DoubleToString(mrvPos, 3));
         }
         else if(mrvPos >= (1.0 - ExtremePct) && dir1 == -1 &&
                 (g_BollingerMid1 <= 0 || mrvBodyMid1 >= g_BollingerMid1)) {
            g_MRVArmed = true; g_MRVDir = -1; g_MRVConfirmOpen = 0;
            Print("MRV ARMED: SELL bounce setup, pos=", DoubleToString(mrvPos, 3));
         }
      }
      // --- CONFIRM: armed + bar[1] same direction + near extreme + Bollinger both bars ---
      else if(g_MRVArmed && g_MRVConfirmOpen == 0) {
         bool mrvStillExtreme = (g_MRVDir == 1) ? (mrvPos <= ExtremePct * 2.0)
                                                 : (mrvPos >= (1.0 - ExtremePct * 2.0));
         bool mrvBollOK = (g_BollingerMid1 <= 0) ||
                          (g_MRVDir == 1 ? (mrvBodyMid1 <= g_BollingerMid1 && mrvBodyMid2 <= g_BollingerMid2)
                                         : (mrvBodyMid1 >= g_BollingerMid1 && mrvBodyMid2 >= g_BollingerMid2));
         if(dir1 == g_MRVDir && mrvStillExtreme && mrvBollOK) {
            g_MRVConfirmOpen = iTime(_Symbol, PERIOD_M15, 0);  // entry window starts on this bar
            Print("MRV CONFIRMED dir=", g_MRVDir, " — 5-min entry window open");
         } else {
            g_MRVArmed = false; g_MRVDir = 0; g_MRVConfirmOpen = 0;
         }
      }
      // --- RESET on direction flip ---
      if(g_MRVArmed && ((g_MRVDir == 1 && dir1 == -1) || (g_MRVDir == -1 && dir1 == 1))) {
         g_MRVArmed = false; g_MRVDir = 0; g_MRVConfirmOpen = 0;
      }
   } else {
      // Range not set — clear MRV state
      g_MRVArmed = false; g_MRVDir = 0; g_MRVConfirmOpen = 0;
   }

   // If signal was already triggered last bar and we're on a new bar now,
   // only keep it alive if direction is still same (signal persists through bar)
   // Reset after attempted entry
}

//+------------------------------------------------------------------+
//| ZONE CLASSIFIER                                                  |
//| Returns "LOWER_THIRD" / "MID_ZONE" / "UPPER_THIRD"             |
//| NEVER returns "NONE" — if range not set, uses pivot PP or mid   |
//+------------------------------------------------------------------+
string ClassifyZone(double price)
{
   double rangeH = g_RangeHigh;
   double rangeL = g_RangeLow;

   // If range still not set, try D1 bar 1 direct
   if(rangeH <= 0 || rangeL <= 0) {
      rangeH = iHigh(_Symbol, PERIOD_D1, 1);
      rangeL = iLow (_Symbol, PERIOD_D1, 1);
   }
   // If still nothing, use pivot PP as midpoint with ATR as width
   if(rangeH <= 0 && g_PivotPP > 0 && g_ATR > 0) {
      rangeH = g_PivotPP + g_ATR;
      rangeL = g_PivotPP - g_ATR;
   }
   // Absolute fallback — treat everything as middle so trades can still fire
   if(rangeH <= 0 || rangeL <= 0 || rangeH == rangeL) return "MID_ZONE";

   double rangeSize = rangeH - rangeL;
   double pos       = (price - rangeL) / rangeSize;

   double midBot = 0.5 - MidZonePct / 2.0;
   double midTop = 0.5 + MidZonePct / 2.0;

   if(pos >= midBot && pos <= midTop)  return "MID_ZONE";
   if(pos > midTop)                    return "UPPER_THIRD";
   return "LOWER_THIRD";
}

//+------------------------------------------------------------------+
//| Is the market currently in a sideways / compressed state?        |
//| Checks the H-L range of last N bars                              |
//+------------------------------------------------------------------+
bool IsSideways()
{
   if(SidewaysBars <= 0) return false;

   double hi = 0, lo = 999999;
   int    bars = MathMin(SidewaysBars, iBars(_Symbol, PERIOD_M15) - 1);
   for(int i = 1; i <= bars; i++) {
      double h = iHigh(_Symbol, PERIOD_M15, i);
      double l = iLow (_Symbol, PERIOD_M15, i);
      if(h > hi) hi = h;
      if(l < lo) lo = l;
   }
   double rangePips = (hi - lo) / _Point / 10.0; // convert to pips (5-digit)
   return (rangePips < SidewaysPips);
}

//+------------------------------------------------------------------+
//| MEAN REVERSION SETUP                                             |
//| Returns 1=BUY reversion, -1=SELL reversion, 0=no confirmed setup |
//| Relies on the bar-level two-candle state machine in              |
//| EvaluateHAPattern() — no tick-level re-checks here              |
//+------------------------------------------------------------------+
int MeanReversionSetup()
{
   if(!AllowMeanReversion) return 0;
   if(g_MRVConfirmOpen <= 0)  return 0;   // state machine has not confirmed yet
   return g_MRVDir;
}

//+------------------------------------------------------------------+
//| Combine bias from geo/news inputs                                |
//+------------------------------------------------------------------+
void RecalcBias()
{
   // Positive = bullish EUR/USD, Negative = bearish EUR/USD
   g_TotalBias = (EURGeoBias - USDGeoBias) + (NewsImpactEUR - NewsImpactUSD);
}

//+------------------------------------------------------------------+
//| Auto lot from balance                                            |
//+------------------------------------------------------------------+
double CalcLot()
{
   if(!AutoLotSize) return NormalizeDouble(ManualLotSize, 2);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double lot;
   if(bal <= 20.0)
      lot = 0.01;
   else
      lot = 0.01 + MathFloor((bal - 20.0) / 10.0) * 0.01;
   return NormalizeDouble(MathMin(lot, MaxLotSize), 2);
}

//+------------------------------------------------------------------+
//| Convert USD amount to price distance                             |
//+------------------------------------------------------------------+
double USDtoPoints(double usdAmount, double lot)
{
   // For EURUSD: 1 pip = 0.0001
   // 1 lot EURUSD: 1 pip = $10, 0.01 lot = $0.10 per pip
   // pip value per lot = tickValue / tickSize
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickVal <= 0 || tickSize <= 0 || lot <= 0) {
      // Fallback: for EURUSD standard, 1 pip = $10 per lot
      double pipValue = 10.0 * lot;  // USD per pip per lot
      double pips = usdAmount / pipValue;
      return pips * 0.0001;           // return as price distance
   }

   double pricePerUSD = tickSize / (tickVal * lot);
   return usdAmount * pricePerUSD;
}

//+------------------------------------------------------------------+
//| ENTRY LOGIC v3                                                    |
//| Handles: trend trades, midrange caution, mean reversion          |
//+------------------------------------------------------------------+
void TryEntry()
{
   if(g_TradeOpen) return;

   // Check both trend signals AND mean reversion setup
   bool isTrendSignal = (g_Signal == "BUY INCOMING" || g_Signal == "SELL INCOMING");
   int  meanRevDir    = MeanReversionSetup();
   bool isMeanRev     = (meanRevDir != 0 && !isTrendSignal);

   if(!isTrendSignal && !isMeanRev) return;

   // === ENTRY TIMING based on HAEntryMode, or MRV 5-minute window ===
   datetime barTime   = iTime(_Symbol, PERIOD_M15, 0);
   int secsElapsed    = (int)(TimeCurrent() - barTime);

   if(isMeanRev) {
      // MRV: 5-minute entry window from the bar that opened after the 2nd confirming candle
      if(secsElapsed > 5 * 60) {
         g_MRVArmed = false; g_MRVConfirmOpen = 0;
         return;   // window expired — discard this MRV setup
      }
      // Within 5-min window: skip the standard HAEntryMode timing block
   } else if(HAEntryMode == 1) {
      // EARLY MODE: enter within first EarlyEntryMins of the confirming candle
      // g_ConfirmCandleOpen is the open of the 2nd (confirming) closed bar
      // The CURRENT bar (index 0) is the one AFTER the confirming bar — we want
      // to enter as soon as the confirming candle has just closed and the new bar
      // opens. So: allow entry in the first EarlyEntryMins seconds of bar 0
      // BUT only when the confirming candle was also bottomless (strong setup).
      // If confirming candle had spikes both sides (doji-like HA), skip early entry.
      bool confirmIsClean = (g_Signal == "BUY INCOMING")
                            ? !IsBottomlessWithTopSpike(1)   // no spike above on bull
                            : !IsToplessWithBottomSpike(1);  // no spike below on bear

      if(!confirmIsClean) {
         // Confirming candle has spikes on both sides — fall back to late entry
         if(secsElapsed < 600) return;
      } else {
         // Clean confirming candle: allow entry in first EarlyEntryMins
         if(secsElapsed > EarlyEntryMins * 60) {
            // Past the early window — still allow late entry as fallback
            if(secsElapsed < 600) return;
         }
         // else: within early window, proceed
      }
   } else {
      // MODE 2 (default): last 5 minutes of the confirming bar's SUCCESSOR
      // i.e. enter in last 5 min of the bar after the confirming candle
      if(secsElapsed < 600) return;
   }

   // HA consecutive candle guard — include the forming bar (bar 0) in the count
   // so we never enter late when the live candle is already the 4th+ in a row
   int liveConsec = LiveHAConsecTotal();
   if(liveConsec > MaxConsecCandles) {
      g_Signal = "WAITING"; g_HABullSetup = false; g_HABearSetup = false;
      return;
   }

   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price   = (ask + bid) / 2.0;
   double lot     = g_CurrentLot;
   double scale   = lot / 0.01;
   double minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   // === ZONE CLASSIFICATION ===
   string zone = ClassifyZone(price);
   g_ZoneLabel = zone;

   bool isSideways = IsSideways();

   // === DETERMINE DIRECTION ===
   int tradeDir = 0; // 1=buy, -1=sell
   if(isTrendSignal)    tradeDir = (g_Signal == "BUY INCOMING") ? 1 : -1;
   else if(isMeanRev)   tradeDir = meanRevDir;

   // === ZONE FILTERS FOR TREND TRADES ===
   if(isTrendSignal && !isMeanRev) {
      // Avoid UPPER_THIRD for buys and LOWER_THIRD for sells — those are against mean reversion
      if(tradeDir == 1 && zone == "UPPER_THIRD" && g_RangeHigh > 0) {
         Print("BUY skipped: in UPPER_THIRD (mean reversion risk near range high)");
         return;
      }
      if(tradeDir == -1 && zone == "LOWER_THIRD" && g_RangeLow > 0) {
         Print("SELL skipped: in LOWER_THIRD (mean reversion risk near range low)");
         return;
      }
   }

   // === MID-ZONE ENTRY VALIDATION ===
   // Mid-zone trades are allowed BUT require stronger evidence:
   //   1. HA pattern must be clean (no double-sided wicks on confirming candle)
   //   2. ATR must show there is momentum (recent bar range > 30% of ATR)
   //   3. Price must be moving TOWARD the favorable third (not stalling at mid)
   bool midZoneValidated = true;
   if(zone == "MID_ZONE" && isTrendSignal) {
      // Check confirming candle is clean
      bool cleanConfirm = (tradeDir == 1) ? !IsBottomlessWithTopSpike(1)
                                          : !IsToplessWithBottomSpike(1);
      if(!cleanConfirm) {
         Print("MID_ZONE BUY/SELL skipped: confirming candle has opposing wick (indecision)");
         return;
      }
      // Check recent bar has momentum (not flat)
      double recentRange = iHigh(_Symbol, PERIOD_M15, 1) - iLow(_Symbol, PERIOD_M15, 1);
      if(g_ATR > 0 && recentRange < g_ATR * 0.25) {
         Print("MID_ZONE trade skipped: recent bar range too small (no momentum) recentRange=",
               DoubleToString(recentRange*10000,1), "pip ATR=", DoubleToString(g_ATR*10000,1));
         return;
      }
      // Check HA consecutive — mid zone with 3+ same candles (including forming) = exhaustion
      if(liveConsec >= 3) {
         Print("MID_ZONE trade skipped: ", liveConsec, " consecutive HA candles incl live (exhausted at mid)");
         return;
      }
   }

   // === MEAN REVERSION ZONE GUARD ===
   if(isMeanRev && zone == "MID_ZONE") {
      Print("Mean rev skipped: price in MID_ZONE, not at extreme");
      return;
   }

   // === BIAS FILTER ===
   bool canBuy  = (g_TotalBias >= 0);
   bool canSell = (g_TotalBias <= 0);
   if(tradeDir == 1  && !canBuy)  { Print("BUY blocked by bias");  return; }
   if(tradeDir == -1 && !canSell) { Print("SELL blocked by bias"); return; }

   // === TARGETS — unified $2 lock for all trade types ===
   // Mid-zone and sideways: same $2 lock but tighter TP ($2 — take it once we're there)
   // This stops the bot from overstaying a mid-range trade hoping for $3
   bool isMidContext = (zone == "MID_ZONE" || isSideways || isMeanRev);
   double lockBase = LockProfitUSD;      // always $2 — no exceptions
   double tpBase   = isMidContext ? MidRangeTPUSD : TakeProfitUSD;
   double slBase   = StopLossUSD;

   double slUSD = slBase * scale;
   double tpUSD = tpBase * scale;

   double slDist = USDtoPoints(slUSD, lot);
   double tpDist = USDtoPoints(tpUSD, lot);
   if(slDist < minStop + _Point * 5) slDist = minStop + _Point * 5;
   if(tpDist < minStop + _Point * 5) tpDist = minStop + _Point * 5;

   // === FIB / PIVOT CONFLUENCE ===
   g_NearLevel = "";
   if(UseFibPivot) {
      string lvlName = NearFibPivotLevel(price);
      g_NearLevel = lvlName;
      bool hasConfluence = (lvlName != "");
      if(RequireFibPivot && !hasConfluence) {
         Print("Skipped: RequireFibPivot=true but price not near any Fib/Pivot level");
         return;
      }
      if(hasConfluence)
         Print("Confluence level nearby: ", lvlName);
   }

   string tag = isMeanRev ? (tradeDir==1 ? "MRV_BUY" : "MRV_SELL")
                          : (tradeDir==1 ? "HA_BUY_v5" : "HA_SELL_v5");
   if(HAEntryMode == 1) tag = tag + "_E";

   // === EXECUTE ===
   bool ok = false;
   if(tradeDir == 1) {
      double sl = NormalizeDouble(ask - slDist, _Digits);
      double tp = NormalizeDouble(ask + tpDist, _Digits);
      Print("Attempting ", tag, " | Zone:", zone, " Mid:", isMidContext,
            " Fib/Pivot:", g_NearLevel, " Lot:", lot, " Ask:", ask, " SL:", sl, " TP:", tp);
      ok = trade.Buy(lot, _Symbol, ask, sl, tp, tag);
   } else {
      double sl = NormalizeDouble(bid + slDist, _Digits);
      double tp = NormalizeDouble(bid - tpDist, _Digits);
      Print("Attempting ", tag, " | Zone:", zone, " Mid:", isMidContext,
            " Fib/Pivot:", g_NearLevel, " Lot:", lot, " Bid:", bid, " SL:", sl, " TP:", tp);
      ok = trade.Sell(lot, _Symbol, bid, sl, tp, tag);
   }

   if(ok) {
      SetScaledThresholds(lot, lockBase, tpBase, slBase);
      g_TradeOpen     = true;
      g_ProfitLocked  = false;
      g_PeakProfit    = 0;
      g_OpenBarCount  = 0;
      g_TradeOpenTime = TimeCurrent();
      g_IsNearMid     = isMidContext;
      g_IsMeanRev     = isMeanRev;
      g_Signal        = "WAITING";
      g_HABullSetup   = false;
      g_HABearSetup   = false;
      g_MRVArmed      = false;
      g_MRVConfirmOpen = 0;
      Print(tag, " OPENED | Lock@$", DoubleToString(g_ScaledLockUSD,2),
            " TP=$", DoubleToString(g_ScaledTPUSD,2),
            " MidContext:", isMidContext);
   } else {
      Print(tag, " FAILED: ", trade.ResultComment(), " Code:", trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//| Scale all USD thresholds proportionally to lot size             |
//| lockBase and tpBase are per-0.01-lot amounts                    |
//+------------------------------------------------------------------+
void SetScaledThresholds(double lot, double lockBase, double tpBase, double slBase)
{
   double scale      = lot / 0.01;
   g_ScaledLockUSD   = lockBase * scale;
   g_ScaledTrailUSD  = TrailingLockUSD * scale;
   g_ScaledTPUSD     = tpBase   * scale;
   g_ScaledSLUSD     = slBase   * scale;
}

//+------------------------------------------------------------------+
//| TRADE MANAGEMENT v5                                              |
//| - Hard $1.75/0.01lot max loss (scaled) — never blow past this   |
//| - $2 lock for all contexts                                       |
//| - Mid-range stall exit: close if stalling at low profit too long |
//| - Max hold time: only exits if NOT meaningfully profitable       |
//| - Sideways: accelerate lock (same $2 level, tighter trail)       |
//+------------------------------------------------------------------+
void ManageOpenTrade()
{
   if(!g_TradeOpen) return;

   bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == 202502) {
            found = true;
            break;
         }
      }
   }

   if(!found) {
      g_TradeOpen    = false;
      g_ProfitLocked = false;
      g_PeakProfit   = 0;
      g_OpenBarCount = 0;
      g_Signal       = "WAITING";
      return;
   }

   double profit = posInfo.Commission() + posInfo.Swap() + posInfo.Profit();
   if(profit > g_PeakProfit) g_PeakProfit = profit;

   // === HARD LOSS CAP — $1.75 per 0.01 lot, ALWAYS, no exceptions ===
   // Broker SL is set at $2 as a safety net but we close early at $1.75
   double hardLossLimit = -(MaxLossUSD * g_CurrentLot / 0.01);
   if(profit <= hardLossLimit) {
      Print("HARD LOSS CAP triggered: profit=$", DoubleToString(profit,2),
            " limit=$", DoubleToString(hardLossLimit,2));
      trade.PositionClose(posInfo.Ticket());
      g_TradeOpen = false; g_ProfitLocked = false;
      g_PeakProfit = 0; g_OpenBarCount = 0; g_Signal = "WAITING";
      return;
   }

   // === MID-RANGE / MEAN-REV STALL EXIT ===
   // If this was a mid-range or mean-rev trade and it's been open MidRangeMaxBars
   // without reaching the lock level, close it if still near breakeven.
   // This prevents mid-range trades from turning into losers by overstaying.
   if(g_IsNearMid && !g_ProfitLocked && g_OpenBarCount >= MidRangeMaxBars) {
      double midStallLimit = MidRangeStallUSD * g_CurrentLot / 0.01;
      if(profit < midStallLimit) {
         Print("MID-RANGE STALL exit: open ", g_OpenBarCount, " bars profit=$",
               DoubleToString(profit,2), " (below stall threshold $",
               DoubleToString(midStallLimit,2), ")");
         trade.PositionClose(posInfo.Ticket());
         g_TradeOpen = false; g_ProfitLocked = false;
         g_PeakProfit = 0; g_OpenBarCount = 0; g_Signal = "WAITING";
         return;
      }
   }

   // === MAX HOLD TIME EXIT ===
   if(g_OpenBarCount >= MaxHoldBars) {
      if(profit < g_ScaledLockUSD * 0.5) {
         Print("MAX HOLD TIME exit after ", g_OpenBarCount, " bars | profit=$", DoubleToString(profit,2));
         trade.PositionClose(posInfo.Ticket());
         g_TradeOpen = false; g_ProfitLocked = false;
         g_PeakProfit = 0; g_OpenBarCount = 0; g_Signal = "WAITING";
         return;
      }
   }

   // === SIDEWAYS: tighten trail once locked (don't use $1 lock — still $2) ===
   if(g_ProfitLocked && IsSideways()) {
      double sidewaysTrail = 0.15 * (g_CurrentLot / 0.01);
      if(g_ScaledTrailUSD > sidewaysTrail) {
         g_ScaledTrailUSD = sidewaysTrail;
         Print("SIDEWAYS tightened trail to $", DoubleToString(g_ScaledTrailUSD,2));
      }
   }

   // === STANDARD PROFIT LOCK ($2 always) ===
   if(!g_ProfitLocked && profit >= g_ScaledLockUSD) {
      g_ProfitLocked = true;
      Print("PROFIT LOCK engaged at $", DoubleToString(profit,2),
            " lock=$", DoubleToString(g_ScaledLockUSD,2));
   }

   // === TRAILING CLOSE ===
   if(g_ProfitLocked && profit < g_PeakProfit - g_ScaledTrailUSD) {
      Print("TRAILING CLOSE: peak=$", DoubleToString(g_PeakProfit,2),
            " now=$", DoubleToString(profit,2),
            " trail=$", DoubleToString(g_ScaledTrailUSD,2));
      trade.PositionClose(posInfo.Ticket());
      g_TradeOpen = false; g_ProfitLocked = false;
      g_PeakProfit = 0; g_OpenBarCount = 0; g_Signal = "WAITING";
   }
}

//+------------------------------------------------------------------+
//| DASHBOARD — OBJ_LABEL objects, moveable via inputs              |
//+------------------------------------------------------------------+
void DashLine(string suffix, string text,
              int baseX, int baseY, int row, int lineH,
              int corner, color clr, int fontSize)
{
   string name = DASH_PREFIX + suffix;
   int    yPos = baseY + row * lineH;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,    corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, baseX);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, yPos);
   ObjectSetString (0, name, OBJPROP_TEXT,      text);
   ObjectSetString (0, name, OBJPROP_FONT,      "Courier New");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,true);
   ObjectSetInteger(0, name, OBJPROP_SELECTED,  false);
   ObjectSetInteger(0, name, OBJPROP_BACK,      false);
}

void UpdateDashboard()
{
   string session = GetSession();
   string biasStr = g_TotalBias >= 2  ? "STRONG BULL" :
                    g_TotalBias == 1  ? "MILD BULL"   :
                    g_TotalBias == -1 ? "MILD BEAR"   :
                    g_TotalBias <= -2 ? "STRONG BEAR"  : "NEUTRAL";

   color sigColor = clrGray;
   if(g_Signal == "BUY INCOMING")   sigColor = clrLime;
   if(g_Signal == "SELL INCOMING")  sigColor = clrRed;
   if(g_Signal == "PREPARING BUY")  sigColor = clrYellow;
   if(g_Signal == "PREPARING SELL") sigColor = clrOrange;

   color biasColor = g_TotalBias > 0 ? clrLime : g_TotalBias < 0 ? clrRed : clrGray;

   int cx     = DashboardX;
   int cy     = DashboardY;
   int corner = DashboardCorner;
   int lh     = 14;  // pixels per line
   int row    = 0;

   // ---- helper macro replaced with inline calls ----
   DashLine("00_title",  "[ EURUSD HA RANGE BOT v5 ]",                         cx, cy, row, lh, corner, clrWhite,     10); row++;
   row++;
   DashLine("01_sess",   "Session : " + session,                                cx, cy, row, lh, corner, clrCyan,       9); row++;

   // Entry mode label
   string modeLabel = (HAEntryMode == 1)
      ? "EARLY (first " + IntegerToString(EarlyEntryMins) + "min of 2nd candle)"
      : "LATE  (last 5min of bar after 2nd candle)";
   DashLine("01b_emode", "EntryMd : " + modeLabel,                             cx, cy, row, lh, corner, clrAqua,        8); row++;

   DashLine("02_sig",    "Signal  : " + g_Signal,                               cx, cy, row, lh, corner, sigColor,     10); row++;

   // Early-entry window countdown when signal is armed
   if(HAEntryMode == 1 && g_ConfirmCandleOpen > 0 &&
      (g_Signal == "BUY INCOMING" || g_Signal == "SELL INCOMING")) {
      datetime barNow   = iTime(_Symbol, PERIOD_M15, 0);
      int      elapsed  = (int)(TimeCurrent() - barNow);
      int      window   = EarlyEntryMins * 60;
      string   winStr   = (elapsed <= window)
                          ? IntegerToString(window - elapsed) + "s left in early window"
                          : "Early window closed — late-entry mode";
      color    winClr   = (elapsed <= window) ? clrLime : clrGray;
      DashLine("02b_win", "Window  : " + winStr,                                cx, cy, row, lh, corner, winClr,        8); row++;
   }

   DashLine("03_bias",   "Bias    : " + biasStr + " (" + IntegerToString(g_TotalBias) + ")",
                                                                                 cx, cy, row, lh, corner, biasColor,     9); row++;
   DashLine("04_lot",    "Lot     : " + DoubleToString(g_CurrentLot, 2),        cx, cy, row, lh, corner, clrWhite,      9); row++;

   // Zone info
   color zoneClr = (g_ZoneLabel == "MID_ZONE") ? clrOrange :
                   (g_ZoneLabel == "UPPER_THIRD") ? clrTomato :
                   (g_ZoneLabel == "LOWER_THIRD") ? clrLime : clrGray;
   DashLine("04b_zone",  "Zone    : " + g_ZoneLabel,                            cx, cy, row, lh, corner, zoneClr,       9); row++;
   bool sw = IsSideways();
   DashLine("04c_sw",    "Sideways: " + (sw ? "YES (tight lock)" : "No"),       cx, cy, row, lh, corner, sw?clrOrange:clrGray, 9); row++;
   row++;

   string rhStr = (g_RangeHigh > 0) ? DoubleToString(g_RangeHigh, 5) : "N/A";
   string rlStr = (g_RangeLow  > 0) ? DoubleToString(g_RangeLow,  5) : "N/A";
   string rmStr = (g_RangeMid  > 0) ? DoubleToString(g_RangeMid,  5) : "N/A";
   DashLine("05_rh",     "PrevDay H: " + rhStr,                                 cx, cy, row, lh, corner, clrYellow,     9); row++;
   DashLine("06_rl",     "PrevDay L: " + rlStr,                                 cx, cy, row, lh, corner, clrYellow,     9); row++;
   DashLine("07_rm",     "PrevDay M: " + rmStr,                                 cx, cy, row, lh, corner, clrYellow,     9); row++;
   string bollStr = (g_BollingerMid1 > 0) ? DoubleToString(g_BollingerMid1, 5) : "N/A";
   DashLine("07b_boll",  "Boll Mid : " + bollStr,                               cx, cy, row, lh, corner, clrAqua,       9); row++;
   row++;

   string cihStr = (g_CIHigh > 0) ? DoubleToString(g_CIHigh, 5) : "N/A";
   string cilStr = (g_CILow  > 0) ? DoubleToString(g_CILow,  5) : "N/A";
   DashLine("08_atr",    "ATR H1  : " + DoubleToString(g_ATR * 10000, 1) + " pips",
                                                                                 cx, cy, row, lh, corner, clrWhite,      9); row++;
   DashLine("09_cih",    "CI High : " + cihStr,                                 cx, cy, row, lh, corner, clrLightBlue,  9); row++;
   DashLine("10_cil",    "CI Low  : " + cilStr,                                 cx, cy, row, lh, corner, clrLightBlue,  9); row++;
   row++;

   // Fib / Pivot nearest level
   if(UseFibPivot) {
      double midNow  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      string nearest = NearFibPivotLevel(midNow);
      string ppStr   = (g_PivotPP > 0) ? DoubleToString(g_PivotPP, 5) : "N/A";
      color  fpClr   = (nearest != "") ? clrGold : clrGray;
      DashLine("10b_fp",  "FibPivot: " + (nearest != "" ? nearest : "none nearby") + "  PP:" + ppStr,
                                                                                 cx, cy, row, lh, corner, fpClr,         8); row++;
      row++;
   }

   // Asian session O/H/L
   if(g_AsianSeeded || g_AsianHigh > 0) {
      DashLine("11a_asian",  "Asian   : O:" + DoubleToString(g_AsianOpen, 5),  cx, cy, row, lh, corner, clrSilver, 9); row++;
      DashLine("11b_asian",  "          H:" + DoubleToString(g_AsianHigh, 5) +
                             "  L:" + DoubleToString(g_AsianLow,  5),           cx, cy, row, lh, corner, clrSilver, 9); row++;
   } else {
      DashLine("11a_asian",  "Asian   : Forming...",                           cx, cy, row, lh, corner, clrGray,   9); row++;
      DashLine("11b_asian",  "",                                                cx, cy, row, lh, corner, clrGray,   9); row++;
   }
   // London session O/H/L
   if(g_LondonSeeded || g_LondonHigh > 0) {
      DashLine("12a_london", "London  : O:" + DoubleToString(g_LondonOpen, 5), cx, cy, row, lh, corner, clrSilver, 9); row++;
      DashLine("12b_london", "          H:" + DoubleToString(g_LondonHigh, 5) +
                             "  L:" + DoubleToString(g_LondonLow,  5),          cx, cy, row, lh, corner, clrSilver, 9); row++;
   } else {
      DashLine("12a_london", "London  : Forming...",                           cx, cy, row, lh, corner, clrGray,   9); row++;
      DashLine("12b_london", "",                                                cx, cy, row, lh, corner, clrGray,   9); row++;
   }
   row++;

   int    liveConsecDash = LiveHAConsecTotal();
   string consecStr      = IntegerToString(g_HAConsecCount) + " closed";
   string liveExtra      = (liveConsecDash > g_HAConsecCount)
                           ? " + 1 forming = " + IntegerToString(liveConsecDash)
                           : " (live doji/flat)";
   color  consecClr      = (liveConsecDash >= MaxConsecCandles) ? clrOrange :
                           (liveConsecDash >= 3)                ? clrYellow : clrWhite;
   DashLine("13_consec", "HA Consec: " + consecStr + liveExtra,
                                                                                 cx, cy, row, lh, corner, consecClr,    9); row++;

   color  tColor   = g_TradeOpen ? clrLime : clrGray;
   DashLine("14_trade",  "Trade   : " + (g_TradeOpen ? "OPEN" : "NONE"),        cx, cy, row, lh, corner, tColor,        9); row++;

   if(g_TradeOpen) {
      string modeStr  = g_IsMeanRev ? "MEAN REV" : (g_IsNearMid ? "MID-validated" : "TREND");
      color  modeClr  = g_IsMeanRev ? clrGold : (g_IsNearMid ? clrOrange : clrLime);
      DashLine("14b_mode", "Mode    : " + modeStr,                              cx, cy, row, lh, corner, modeClr,       9); row++;
      if(g_NearLevel != "")
         DashLine("14d_lvl", "Cnfl    : " + g_NearLevel,                        cx, cy, row, lh, corner, clrGold,       9); row++;
      DashLine("14c_bars", "Hold    : " + IntegerToString(g_OpenBarCount) + "/" + IntegerToString(MaxHoldBars) + " bars",
                                                                                 cx, cy, row, lh, corner, clrWhite,      9); row++;
      double hardLoss  = MaxLossUSD * g_CurrentLot / 0.01;
      DashLine("14e_cap",  "MaxLoss : -$" + DoubleToString(hardLoss,2) + " cap",
                                                                                 cx, cy, row, lh, corner, clrTomato,     9); row++;
      string lockStr = g_ProfitLocked
                       ? "LOCKED  peak:$" + DoubleToString(g_PeakProfit, 2)
                       : "Watch  lock@$" + DoubleToString(g_ScaledLockUSD, 2);
      color  lColor  = g_ProfitLocked ? clrLime : clrOrange;
      DashLine("15_lock", "Lock    : " + lockStr,                               cx, cy, row, lh, corner, lColor,        9); row++;
   }

   if(GeoPoliticsNote != "") { row++;
      DashLine("16_geo",  "Geo : " + GeoPoliticsNote,                           cx, cy, row, lh, corner, clrLightGray,  8); row++;
   }
   if(NewsNote != "") {
      DashLine("17_news", "News: " + NewsNote,                                  cx, cy, row, lh, corner, clrLightGray,  8); row++;
   }
}

//+------------------------------------------------------------------+
string GetSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(h >= AsianStartHour   && h < AsianEndHour)   return "ASIAN";
   if(h >= LondonStartHour  && h < LondonEndHour)  return "LONDON";
   if(h >= NewYorkStartHour && h < NewYorkEndHour) return "NEW YORK";
   return "OFF-HOURS";
}
//+------------------------------------------------------------------+