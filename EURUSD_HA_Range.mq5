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
input bool   AutoLotSize      = false;   // OFF by default — user can enable for risk-based sizing
input double ManualLotSize    = 0.01;    // Default for small accounts ($10+)
input double MaxLotSize       = 0.10;   // Hard cap — protects against large early losses
input double RiskPercent      = 2.0;    // Max risk per trade as % of balance (only when AutoLotSize=true)

input group "=== RISK & PROFIT (per 0.01 lot baseline) ==="
input double MaxLossUSD       = 2.50;   // Hard max loss before forced close (per 0.01 lot)
// Dynamic SL/TP: the bot finds structural SL (nearest invalidation) and calculates TP from R:R.
// The SL is clamped within MinSL/MaxSL range. TP = SL × RRRatio.
input double MinSL_USD        = 1.50;   // Minimum SL per 0.01 lot (15 pips) — won't go tighter
input double MaxSL_USD        = 2.50;   // Maximum SL per 0.01 lot (25 pips) — won't go wider
input double RRRatio          = 1.8;    // Reward:Risk ratio (1.8 = for every $1 risk, target $1.80)
// Lock/trail are now proportional to the dynamic SL, not fixed per tier
input double LockPct          = 0.75;   // Lock profit at 75% of TP — only secure near-target profits
input double TrailPct         = 0.30;   // Trail gap = 30% of TP — generous room to fluctuate
// Mid-range time-exit: close if stalling in LOSS after MidRangeMaxBars
input double MidRangeStallUSD = 0.00;   // Stall exit disabled — trust the SL/TP
input int    MidRangeMaxBars  = 16;     // Bars before mid-range stall check (only if MidRangeStallUSD > 0)

input group "=== TIME FILTERS ==="
input int    MaxHoldBars      = 48;     // Max 15M bars to hold = 12 hours — give trades room to develop
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

input group "=== MARKET STRUCTURE (Smart Money Concepts) ==="
input bool   UseSwingStructure   = true;   // Detect H1 swing highs/lows for BOS/CHoCH
input bool   UseOrderBlocks      = true;   // Detect H1 institutional order blocks
input bool   UseVolumeAnalysis   = true;   // Tick volume confirmation & divergence
input bool   UseLiquiditySweep   = true;   // Detect stop-hunt sweeps at key levels
input bool   UseFairValueGaps    = true;   // Detect and display M15/H1 Fair Value Gaps
input double MinConfidence       = 35.0;   // Minimum confidence % to take a trade (0-100)

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

input group "=== FOREIGN TRADE AWARENESS ==="
input bool   RespectForeignTrades = true;   // Block new entries if a non-bot trade exists on this symbol

input group "=== OVERTRADING PROTECTION ==="
input int    MaxDailyTrades     = 3;     // Max trades per day (0 = unlimited)
input double MaxDailyLossUSD    = 5.0;   // Stop trading after cumulative daily loss exceeds this (0=disabled)
input int    ConsecLossLimit    = 2;     // After N consecutive SL hits, pause trading
input int    CooldownBars       = 8;     // Bars to pause after consecutive loss limit hit (8 = 2 hours)
input int    NoEntryAfterHour   = 21;    // No new entries after this server hour (0-23, 0=disabled)
input int    FridayCloseHour    = 20;    // Force close open trades on Friday at this hour (0=disabled)

input group "=== DASHBOARD POSITION ==="
input int    DashboardCorner  = 0;
input int    DashboardX       = 10;
input int    DashboardY       = 20;

//=== GLOBALS ===

// Foreign trade tracking (non-bot positions on this account)
int    g_ForeignCountSymbol = 0;    // foreign trades on THIS symbol (EURUSD)
int    g_ForeignCountTotal  = 0;    // foreign trades on ALL symbols
double g_ForeignLotsSymbol  = 0.0;  // total lots of foreign trades on this symbol
string g_ForeignSummary     = "";   // human-readable summary for dashboard

double g_AsianHigh  = 0, g_AsianLow  = 0, g_AsianOpen  = 0;
double g_LondonHigh = 0, g_LondonLow = 0, g_LondonOpen = 0;
double g_NYHigh     = 0, g_NYLow     = 0, g_NYOpen     = 0;
double g_TodayHigh  = 0, g_TodayLow  = 0, g_TodayOpen  = 0;
double g_RangeHigh  = 0, g_RangeLow  = 0, g_RangeMid = 0;
double g_PrevDayHigh= 0, g_PrevDayLow = 0;  // yesterday only (fixed reference)
double g_CIHigh     = 0, g_CILow     = 0, g_ATR      = 0;
int    g_InitTickCount = 0;  // count ticks since attach; D1[0] not trusted until threshold

// Session seeded flags — true only after a successful CopyHigh call
// (NOT set by UpdateLiveSessionBar so the retry keeps firing until real data arrives)
bool   g_AsianSeeded  = false;
bool   g_LondonSeeded = false;
bool   g_NYSeeded     = false;

bool   g_TradeOpen    = false;
bool   g_ProfitLocked = false;
double g_PeakProfit   = 0;
double g_CurrentLot   = 0.01;
int    g_TotalBias    = 0;

// Auto market-derived bias components (recalculated every tick)
int    g_IntraDayBias   = 0;   // today open vs current price (momentum)
int    g_GapBias        = 0;   // prev day close vs today open (overnight gap)
int    g_AsianBias      = 0;   // asian session open vs current price
int    g_LondonBias     = 0;   // london session open vs current price
int    g_NYBias         = 0;   // new york session open vs current price
int    g_MarketAutoBias = 0;   // combined auto bias (intraday + gap)
double g_IntraDayPct   = 0.0; // raw % for display
double g_GapPct        = 0.0; // raw % for display
double g_AsianPct      = 0.0; // raw % for display
double g_LondonPct     = 0.0; // raw % for display
double g_NYPct         = 0.0; // raw % for display

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
// Confidence system (replaces old tier system)

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

// Market Structure (H1 swing points)
double g_SwingHigh1 = 0, g_SwingHigh2 = 0;  // two most recent swing highs (H1)
double g_SwingLow1  = 0, g_SwingLow2  = 0;  // two most recent swing lows (H1)
string g_StructureLabel = "RANGING";          // "BULLISH" / "BEARISH" / "RANGING"
bool   g_BOS         = false;                // Break of Structure on this bar
bool   g_CHoCH       = false;                // Change of Character (trend reversal)

// Liquidity Sweep detection
bool   g_LiquiditySweep = false;             // price swept a key level and reversed
string g_SweepLevel     = "";                // which level was swept
int    g_SweepDir       = 0;                 // 1=bullish sweep (swept low), -1=bearish (swept high)

// Volume Analysis (tick volume)
string g_VolumeState   = "NORMAL";           // "HIGH" / "ABOVE_AVG" / "NORMAL" / "LOW"
double g_VolRatio      = 1.0;               // current vol / average vol
bool   g_VolDivergence = false;              // price trending but volume declining

// Order Blocks (institutional entry zones on H1)
double g_BullOB_High = 0, g_BullOB_Low = 0; // last bear candle before bull impulse
double g_BearOB_High = 0, g_BearOB_Low = 0; // last bull candle before bear impulse

// Fair Value Gaps (FVG) — M15 imbalance zones
struct FVGZone {
   double high;       // upper edge of gap
   double low;        // lower edge of gap
   int    dir;        // 1=bullish FVG (gap up), -1=bearish FVG (gap down)
   datetime created;  // when detected
   bool   filled;     // true once price has traded through the gap
};
FVGZone g_FVGs[];                          // active FVG array
int     g_FVGCount        = 0;             // number of active FVGs
bool    g_NearBullFVG     = false;         // price near a bullish FVG (expect support)
bool    g_NearBearFVG     = false;         // price near a bearish FVG (expect resistance)
double  g_NearestFVGHigh  = 0;             // nearest FVG zone high
double  g_NearestFVGLow   = 0;             // nearest FVG zone low
int     g_NearestFVGDir   = 0;             // direction of nearest FVG

// Confidence model output (replaces tier system)
double g_Confidence       = 0;             // 0-100% confidence score for current setup
double g_DynamicSL_USD    = 2.0;           // structural SL for current setup (per 0.01 lot)
double g_DynamicTP_USD    = 3.6;           // calculated TP = SL × RRRatio (per 0.01 lot)

// Fibonacci & Pivot levels (recalculated each day/session)
double g_PivotPP  = 0, g_PivotR1 = 0, g_PivotS1 = 0;
double g_PivotR2  = 0, g_PivotS2 = 0;
double g_Fib236   = 0, g_Fib382  = 0, g_Fib500  = 0;
double g_Fib618   = 0, g_Fib764  = 0;
string g_NearLevel = "";    // label of the nearest confluence level at entry

// Zone classification for display
string g_ZoneLabel    = "UNKNOWN";

// Overtrading protection
int      g_DailyTradeCount = 0;      // trades opened today
int      g_ConsecLosses    = 0;      // consecutive SL/hard-loss exits
datetime g_CooldownUntil   = 0;      // if > 0, no entries until this time
int      g_DailyWins       = 0;      // wins today (for dashboard)
int      g_DailyLosses     = 0;      // losses today (for dashboard)
double   g_DailyPnL        = 0.0;    // cumulative P&L today

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

      // Recover confidence-based SL/TP from comment or use defaults
      // New comment format: ...C75_SL2.00_TP3.60
      g_DynamicSL_USD = MaxSL_USD;   // safe default
      g_DynamicTP_USD = MaxSL_USD * RRRatio;
      int slIdx = StringFind(comment, "_SL");
      int tpIdx = StringFind(comment, "_TP");
      if(slIdx >= 0 && tpIdx >= 0) {
         g_DynamicSL_USD = StringToDouble(StringSubstr(comment, slIdx + 3, tpIdx - slIdx - 3));
         g_DynamicTP_USD = StringToDouble(StringSubstr(comment, tpIdx + 3));
      }
      // Also try to recover confidence
      int cIdx = StringFind(comment, "C");
      if(cIdx >= 0) {
         string cStr = StringSubstr(comment, cIdx + 1, 3);
         double cVal = StringToDouble(cStr);
         if(cVal > 0 && cVal <= 100) g_Confidence = cVal;
      }

      // Rebuild scaled USD thresholds from recovered SL/TP
      SetScaledThresholds(lot);

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
//| SCAN FOREIGN TRADES                                              |
//| Counts open positions NOT placed by this bot (magic != 202502).  |
//| Separates same-symbol vs total-account foreign trades.           |
//+------------------------------------------------------------------+
void ScanForeignTrades()
{
   int    countSym   = 0;
   int    countAll   = 0;
   double lotsSym    = 0.0;
   string details    = "";

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;

      // Skip our own bot's trades
      if(posInfo.Magic() == 202502) continue;

      // This is a foreign trade (manual, other EA, etc.)
      countAll++;
      string sym   = posInfo.Symbol();
      double lot   = posInfo.Volume();
      long   magic = posInfo.Magic();
      double pnl   = posInfo.Commission() + posInfo.Swap() + posInfo.Profit();
      string dir   = (posInfo.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";

      if(sym == _Symbol)
      {
         countSym++;
         lotsSym += lot;
         if(details != "") details += "; ";
         details += dir + " " + DoubleToString(lot, 2) + "lot";
         if(magic != 0)
            details += " (EA:" + IntegerToString(magic) + ")";
         else
            details += " (manual)";
         details += " P&L:$" + DoubleToString(pnl, 2);
      }
   }

   // Log when foreign trades appear or disappear
   if(countSym > 0 && g_ForeignCountSymbol == 0)
      Print("FOREIGN TRADE DETECTED on ", _Symbol, ": ", details);
   if(countSym == 0 && g_ForeignCountSymbol > 0)
      Print("FOREIGN TRADE CLOSED — ", _Symbol, " clear, bot can trade again");

   g_ForeignCountSymbol = countSym;
   g_ForeignCountTotal  = countAll;
   g_ForeignLotsSymbol  = lotsSym;
   g_ForeignSummary     = details;
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
   ObjectsDeleteAll(0, "HABOT_FVG_");
   Comment("");
}

//+------------------------------------------------------------------+
//| MAIN TICK                                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   // Track ticks since attach — D1[0] data may be stale on first few ticks
   // while the terminal syncs history. We wait 20 ticks before trusting it.
   if(g_InitTickCount < 100) g_InitTickCount++;

   // Scan for foreign (non-bot) trades every tick
   ScanForeignTrades();

   // === FRIDAY WEEKEND CLOSE ===
   if(FridayCloseHour > 0 && g_TradeOpen) {
      MqlDateTime fridayDt;
      TimeToStruct(TimeCurrent(), fridayDt);
      if(fridayDt.day_of_week == 5 && fridayDt.hour >= FridayCloseHour) {
         // Force close before weekend
         for(int i = PositionsTotal() - 1; i >= 0; i--) {
            if(posInfo.SelectByIndex(i)) {
               if(posInfo.Symbol() == _Symbol && posInfo.Magic() == 202502) {
                  double pnl = posInfo.Commission() + posInfo.Swap() + posInfo.Profit();
                  Print("FRIDAY CLOSE: closing before weekend | P&L=$", DoubleToString(pnl, 2));
                  trade.PositionClose(posInfo.Ticket());
                  RecordTradeResult(pnl);
                  g_TradeOpen = false; g_ProfitLocked = false;
                  g_PeakProfit = 0; g_OpenBarCount = 0; g_Signal = "WAITING";
               }
            }
         }
      }
   }

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
   if(!g_NYSeeded) {
      datetime nStart = dayStart0 + (datetime)(NewYorkStartHour * 3600);
      datetime nEnd   = dayStart0 + (datetime)(NewYorkEndHour   * 3600);
      if(TimeCurrent() > nStart) {
         datetime nTo = (TimeCurrent() < nEnd) ? TimeCurrent() : nEnd;
         g_NYSeeded = SeedSessionHL(nStart, nTo, g_NYHigh, g_NYLow, g_NYOpen);
      }
   }

   // Always track live bar[0] for session ranges (captures new session opening immediately)
   UpdateLiveSessionBar();

   // Always keep zone label current so dashboard never shows UNKNOWN
   g_ZoneLabel = ClassifyZone(SymbolInfoDouble(_Symbol, SYMBOL_BID));

   // Recalc bias every tick so dashboard always reflects live price movement
   RecalcBias();

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

      // Market structure analysis (runs on new bar only — uses confirmed bars)
      if(UseSwingStructure)  DetectSwingStructure();
      if(UseOrderBlocks)     DetectOrderBlocks();
      if(UseVolumeAnalysis)  AnalyzeVolume();
      if(UseLiquiditySweep)  DetectLiquiditySweep();
      if(UseFairValueGaps)   { DetectFairValueGaps(); DrawFVGZones(); }

      EvaluateHAPattern();
   }

   // Fire TryEntry when trend signal active OR mean reversion setup exists
   if(!g_TradeOpen) {
      bool hasTrendSig = (g_Signal == "BUY INCOMING" || g_Signal == "SELL INCOMING");
      bool hasMeanRev  = (MeanReversionSetup() != 0);
      if(hasTrendSig || hasMeanRev) TryEntry();
   }

   // Keep range fresh every tick (g_TodayHigh/Low grows on each tick)
   SetActiveRange();

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
//+------------------------------------------------------------------+
//| Get the open price of the session that starts at sessionStart.   |
//| Strategy: walk from M15 → M30 → H1 → H4 until a bar whose open |
//| time matches sessionStart exactly is found. This avoids the      |
//| CopyOpen datetime-range buffer dependency (only has bars since   |
//| chart was loaded). H1 bars open at the exact session-start hour  |
//| so iBarShift→iOpen on H1 is always reliable.                    |
//+------------------------------------------------------------------+
double GetSessionOpen(datetime sessionStart)
{
   // Try each TF from smallest to largest — stop as soon as a valid bar is found
   // whose open time == sessionStart (i.e. the bar was born exactly at session open)
   ENUM_TIMEFRAMES tfs[] = {PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4};
   for(int t = 0; t < ArraySize(tfs); t++)
   {
      // iBarShift with exact=false: returns the bar whose open <= sessionStart
      int shift = iBarShift(_Symbol, tfs[t], sessionStart, false);
      if(shift < 0) continue;
      datetime barTime = iTime(_Symbol, tfs[t], shift);
      if(barTime == sessionStart)          // bar opens exactly at session boundary
      {
         double op = iOpen(_Symbol, tfs[t], shift);
         if(op > 0) {
            Print("GetSessionOpen: ", TimeToString(sessionStart),
                  " found on ", EnumToString(tfs[t]),
                  " bar[", shift, "] open=", DoubleToString(op, 5));
            return op;
         }
      }
   }
   // Fallback: accept the nearest bar's open even if not exactly on the boundary
   int shift = iBarShift(_Symbol, PERIOD_H1, sessionStart, false);
   if(shift >= 0) {
      double op = iOpen(_Symbol, PERIOD_H1, shift);
      if(op > 0) {
         Print("GetSessionOpen fallback: ", TimeToString(sessionStart),
               " nearest H1 bar[", shift, "] open=", DoubleToString(op, 5));
         return op;
      }
   }
   return 0;
}

bool SeedSessionHL(datetime fromTime, datetime toTime, double &hi, double &lo, double &op)
{
   if(fromTime >= toTime) return false;

   // --- Session open: use H1/M30/M15 bar at fromTime — always reliable ---
   // This avoids the CopyOpen datetime-range approach which only returns bars
   // that are already in the chart buffer (i.e. since the bot started).
   if(op == 0)
      op = GetSessionOpen(fromTime);

   // --- Session H/L: CopyHigh/CopyLow still fine for range (just need extremes) ---
   double arrH[], arrL[];
   int copied = CopyHigh(_Symbol, PERIOD_M15, fromTime, toTime, arrH);
   if(copied <= 0) {
      Print("SeedSessionHL: CopyHigh returned ", copied,
            " from ", TimeToString(fromTime), " to ", TimeToString(toTime));
      return (op > 0);   // open succeeded even if H/L failed — return true so seeded flag is set
   }
   CopyLow(_Symbol, PERIOD_M15, fromTime, toTime, arrL);

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

   // --- New York session: only if we are past or inside NY hours ---
   datetime nyStart = dayStart + (datetime)(NewYorkStartHour * 3600);
   datetime nyEnd   = dayStart + (datetime)(NewYorkEndHour   * 3600);
   if(TimeCurrent() > nyStart) {
      datetime nyTo = (TimeCurrent() < nyEnd) ? TimeCurrent() : nyEnd;
      g_NYSeeded = SeedSessionHL(nyStart, nyTo, g_NYHigh, g_NYLow, g_NYOpen);
   }

   // Fallback: if today has no data at all, g_RangeHigh/Low from D1 already set above
   SetActiveRange();
   CalcFibPivotLevels();
   Print("SeedRangesFromHistory: PrevDay H=", DoubleToString(g_RangeHigh,5),
         " L=", DoubleToString(g_RangeLow,5),
         " | Asian H=", DoubleToString(g_AsianHigh,5), " L=", DoubleToString(g_AsianLow,5),
         " | London H=", DoubleToString(g_LondonHigh,5), " L=", DoubleToString(g_LondonLow,5),
         " | NY H=", DoubleToString(g_NYHigh,5), " L=", DoubleToString(g_NYLow,5));
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
   g_NYHigh    = 0; g_NYLow     = 0; g_NYOpen     = 0; g_NYSeeded     = false;
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
   g_DailyTradeCount   = 0;
   g_DailyWins         = 0;
   g_DailyLosses       = 0;
   g_DailyPnL          = 0.0;
   // Don't reset g_ConsecLosses or g_CooldownUntil — they persist across days
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
      // g_AsianOpen NOT set here — only GetSessionOpen/SeedSessionHL sets it
      if(g_AsianHigh == 0 || hi > g_AsianHigh) g_AsianHigh = hi;
      if(g_AsianLow  == 0 || lo < g_AsianLow)  g_AsianLow  = lo;
   }
   if(h >= LondonStartHour && h < LondonEndHour) {
      // g_LondonOpen NOT set here — only GetSessionOpen/SeedSessionHL sets it
      if(g_LondonHigh == 0 || hi > g_LondonHigh) g_LondonHigh = hi;
      if(g_LondonLow  == 0 || lo < g_LondonLow)  g_LondonLow  = lo;
   }
   if(h >= NewYorkStartHour && h < NewYorkEndHour) {
      // g_NYOpen NOT set here — only GetSessionOpen/SeedSessionHL sets it
      if(g_NYHigh == 0 || hi > g_NYHigh) g_NYHigh = hi;
      if(g_NYLow  == 0 || lo < g_NYLow)  g_NYLow  = lo;
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
      // g_AsianOpen is intentionally NOT set here — only SeedSessionHL sets it
      // from arrO[0] (the open of the very first bar of the Asian session window)
      if(g_AsianHigh == 0 || liveHi > g_AsianHigh) g_AsianHigh = liveHi;
      if(g_AsianLow  == 0 || liveLo  < g_AsianLow)  g_AsianLow  = liveLo;
   }
   if(h >= LondonStartHour && h < LondonEndHour) {
      // g_LondonOpen is intentionally NOT set here — only SeedSessionHL sets it
      // from arrO[0] (the open of the very first bar of the London session window)
      if(g_LondonHigh == 0 || liveHi > g_LondonHigh) g_LondonHigh = liveHi;
      if(g_LondonLow  == 0 || liveLo  < g_LondonLow)  g_LondonLow  = liveLo;
   }
   if(h >= NewYorkStartHour && h < NewYorkEndHour) {
      // g_NYOpen NOT set here — only SeedSessionHL sets it
      if(g_NYHigh == 0 || liveHi > g_NYHigh) g_NYHigh = liveHi;
      if(g_NYLow  == 0 || liveLo  < g_NYLow)  g_NYLow  = liveLo;
   }
   // removed old empty NY block
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

   // --- Previous day: fixed anchor, read from D1[1] ---
   double prevDayH = iHigh(_Symbol, PERIOD_D1, 1);
   double prevDayL = iLow (_Symbol, PERIOD_D1, 1);
   if(prevDayH > 0 && prevDayL > 0) {
      g_PrevDayHigh = prevDayH;
      g_PrevDayLow  = prevDayL;
   }

   // --- Today's live range: D1[0] is the current day's bar — grows every tick.
   // iHigh/iLow on D1[0] is the broker's live forming daily bar — always accurate.
   double todayH = iHigh(_Symbol, PERIOD_D1, 0);
   double todayL = iLow (_Symbol, PERIOD_D1, 0);
   if(todayH > 0) g_TodayHigh = todayH;
   if(todayL > 0) g_TodayLow  = todayL;

   // --- Active range = today's D1[0] only ---
   // Yesterday is kept as a separate reference (g_PrevDayHigh/Low) on the dashboard
   // but no longer merged into the active range. This ensures Range H/L reflects
   // today's actual price action, not yesterday's stale levels.
   if(todayH > 0 && todayL > 0) {
      g_RangeHigh = todayH;
      g_RangeLow  = todayL;
      g_RangeMid  = (todayH + todayL) / 2.0;
   }
   else if(g_PrevDayHigh > 0 && g_PrevDayLow > 0) {
      // Fallback only if D1[0] isn't available yet (e.g. very first tick of new day)
      g_RangeHigh = g_PrevDayHigh;
      g_RangeLow  = g_PrevDayLow;
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
//| MARKET STRUCTURE DETECTION (H1 Swing Points)                     |
//| Scans H1 bars for swing highs/lows using a 3-bar left/right     |
//| confirmation.  Determines overall structure (bullish HH/HL,      |
//| bearish LH/LL, or ranging) and flags BOS / CHoCH events.        |
//+------------------------------------------------------------------+
void DetectSwingStructure()
{
   int lookback = 3;   // bars each side to confirm a swing point
   int scanBars = 50;  // H1 bars to scan

   double swingHighs[];
   double swingLows[];
   ArrayResize(swingHighs, 6);
   ArrayResize(swingLows, 6);
   int shCount = 0, slCount = 0;

   for(int i = lookback; i < scanBars - lookback && (shCount < 4 || slCount < 4); i++)
   {
      double h = iHigh(_Symbol, PERIOD_H1, i);
      double l = iLow (_Symbol, PERIOD_H1, i);

      // --- swing high: bar high > all neighbours within lookback ---
      bool isSH = true;
      for(int j = 1; j <= lookback; j++) {
         if(iHigh(_Symbol, PERIOD_H1, i - j) >= h ||
            iHigh(_Symbol, PERIOD_H1, i + j) >= h) { isSH = false; break; }
      }
      if(isSH && shCount < 4) swingHighs[shCount++] = h;

      // --- swing low: bar low < all neighbours within lookback ---
      bool isSL = true;
      for(int j = 1; j <= lookback; j++) {
         if(iLow(_Symbol, PERIOD_H1, i - j) <= l ||
            iLow(_Symbol, PERIOD_H1, i + j) <= l) { isSL = false; break; }
      }
      if(isSL && slCount < 4) swingLows[slCount++] = l;
   }

   g_SwingHigh1 = (shCount >= 1) ? swingHighs[0] : 0;
   g_SwingHigh2 = (shCount >= 2) ? swingHighs[1] : 0;
   g_SwingLow1  = (slCount >= 1) ? swingLows[0]  : 0;
   g_SwingLow2  = (slCount >= 2) ? swingLows[1]  : 0;

   string prevStructure = g_StructureLabel;
   g_BOS   = false;
   g_CHoCH = false;

   if(shCount >= 2 && slCount >= 2)
   {
      // 10-point tolerance (1 pip) to avoid noise
      bool HH = (g_SwingHigh1 > g_SwingHigh2 + _Point * 10);
      bool HL = (g_SwingLow1  > g_SwingLow2  + _Point * 10);
      bool LH = (g_SwingHigh1 < g_SwingHigh2 - _Point * 10);
      bool LL = (g_SwingLow1  < g_SwingLow2  - _Point * 10);

      if(HH && HL)       g_StructureLabel = "BULLISH";
      else if(LH && LL)  g_StructureLabel = "BEARISH";
      else                g_StructureLabel = "RANGING";

      // BOS: live price breaks the most recent swing in trend direction
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(g_StructureLabel == "BULLISH" && bid > g_SwingHigh1)  g_BOS = true;
      if(g_StructureLabel == "BEARISH" && bid < g_SwingLow1)   g_BOS = true;

      // CHoCH: structure just flipped direction
      if(prevStructure == "BULLISH"  && g_StructureLabel == "BEARISH") g_CHoCH = true;
      if(prevStructure == "BEARISH"  && g_StructureLabel == "BULLISH") g_CHoCH = true;
   }
}

//+------------------------------------------------------------------+
//| LIQUIDITY SWEEP DETECTION                                         |
//| Checks if the last closed M15 bar swept a key level (session     |
//| H/L, prev day H/L, swing H/L) and then closed back inside —     |
//| indicating a stop-hunt / institutional liquidity grab.            |
//+------------------------------------------------------------------+
void DetectLiquiditySweep()
{
   g_LiquiditySweep = false;
   g_SweepLevel = "";
   g_SweepDir = 0;

   double barH = iHigh (_Symbol, PERIOD_M15, 1);
   double barL = iLow  (_Symbol, PERIOD_M15, 1);
   double barC = iClose(_Symbol, PERIOD_M15, 1);
   double tol  = 2.0 * _Point * 10;   // 2 pip pierce required

   // --- Low levels (buy-side liquidity pools — stops cluster below) ---
   double loLvl[];  string loNm[];
   int loCnt = 0;
   ArrayResize(loLvl, 8);  ArrayResize(loNm, 8);
   if(g_AsianLow  > 0)  { loLvl[loCnt] = g_AsianLow;   loNm[loCnt] = "Asian Low";   loCnt++; }
   if(g_LondonLow > 0)  { loLvl[loCnt] = g_LondonLow;  loNm[loCnt] = "London Low";  loCnt++; }
   if(g_NYLow     > 0)  { loLvl[loCnt] = g_NYLow;      loNm[loCnt] = "NY Low";      loCnt++; }
   if(g_PrevDayLow > 0) { loLvl[loCnt] = g_PrevDayLow; loNm[loCnt] = "PrevDay Low"; loCnt++; }
   if(g_SwingLow1  > 0) { loLvl[loCnt] = g_SwingLow1;  loNm[loCnt] = "Swing Low";   loCnt++; }

   // --- High levels (sell-side liquidity pools — stops cluster above) ---
   double hiLvl[];  string hiNm[];
   int hiCnt = 0;
   ArrayResize(hiLvl, 8);  ArrayResize(hiNm, 8);
   if(g_AsianHigh  > 0) { hiLvl[hiCnt] = g_AsianHigh;   hiNm[hiCnt] = "Asian High";   hiCnt++; }
   if(g_LondonHigh > 0) { hiLvl[hiCnt] = g_LondonHigh;  hiNm[hiCnt] = "London High";  hiCnt++; }
   if(g_NYHigh     > 0) { hiLvl[hiCnt] = g_NYHigh;      hiNm[hiCnt] = "NY High";      hiCnt++; }
   if(g_PrevDayHigh > 0){ hiLvl[hiCnt] = g_PrevDayHigh; hiNm[hiCnt] = "PrevDay High"; hiCnt++; }
   if(g_SwingHigh1  > 0){ hiLvl[hiCnt] = g_SwingHigh1;  hiNm[hiCnt] = "Swing High";   hiCnt++; }

   // Bullish sweep: bar dipped BELOW a low level, closed back ABOVE  → expect UP
   for(int i = 0; i < loCnt; i++) {
      if(barL < loLvl[i] - tol && barC > loLvl[i]) {
         g_LiquiditySweep = true;
         g_SweepLevel = loNm[i];
         g_SweepDir = 1;
         Print("LIQUIDITY SWEEP UP: ", loNm[i], " at ", DoubleToString(loLvl[i], 5),
               " | BarL:", DoubleToString(barL, 5), " C:", DoubleToString(barC, 5));
         return;
      }
   }
   // Bearish sweep: bar spiked ABOVE a high level, closed back BELOW → expect DOWN
   for(int i = 0; i < hiCnt; i++) {
      if(barH > hiLvl[i] + tol && barC < hiLvl[i]) {
         g_LiquiditySweep = true;
         g_SweepLevel = hiNm[i];
         g_SweepDir = -1;
         Print("LIQUIDITY SWEEP DN: ", hiNm[i], " at ", DoubleToString(hiLvl[i], 5),
               " | BarH:", DoubleToString(barH, 5), " C:", DoubleToString(barC, 5));
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| VOLUME ANALYSIS (Tick Volume on M15)                              |
//| Compares the last completed bar's tick volume to the 20-bar      |
//| average.  Also detects volume divergence (price trending but     |
//| volume declining — a sign of a weakening move).                  |
//+------------------------------------------------------------------+
void AnalyzeVolume()
{
   int avgPeriod = 20;
   long volumes[];
   ArraySetAsSeries(volumes, true);

   if(CopyTickVolume(_Symbol, PERIOD_M15, 0, avgPeriod + 2, volumes) < avgPeriod + 2) {
      g_VolumeState = "NORMAL";
      g_VolRatio = 1.0;
      g_VolDivergence = false;
      return;
   }

   // Average of bars 2..avgPeriod+1 (confirmed, excludes bar 0 forming + bar 1 just closed)
   long totalVol = 0;
   for(int i = 2; i <= avgPeriod + 1; i++) totalVol += volumes[i];
   double avgVol = (double)totalVol / avgPeriod;

   double currVol = (double)volumes[1];   // last completed bar
   g_VolRatio = (avgVol > 0) ? currVol / avgVol : 1.0;

   if(g_VolRatio >= 1.8)       g_VolumeState = "HIGH";
   else if(g_VolRatio >= 1.3)  g_VolumeState = "ABOVE_AVG";
   else if(g_VolRatio <= 0.5)  g_VolumeState = "LOW";
   else                        g_VolumeState = "NORMAL";

   // Divergence: price making new highs/lows over 5 bars but volume declining
   g_VolDivergence = false;
   double c1 = iClose(_Symbol, PERIOD_M15, 1);
   double c3 = iClose(_Symbol, PERIOD_M15, 3);
   double c5 = iClose(_Symbol, PERIOD_M15, 5);
   bool priceMove = (c1 > c3 && c3 > c5) || (c1 < c3 && c3 < c5);
   bool volDrop   = (volumes[1] < volumes[3] && volumes[3] < volumes[5]);
   if(priceMove && volDrop)
      g_VolDivergence = true;
}

//+------------------------------------------------------------------+
//| ORDER BLOCK DETECTION (H1)                                        |
//| Scans H1 bars for strong impulse moves (3+ consecutive bars,     |
//| 12+ pips).  The last opposing candle before the impulse is the   |
//| "order block" — a zone where institutional orders were placed.   |
//| Price often returns to these zones for high-quality entries.     |
//+------------------------------------------------------------------+
void DetectOrderBlocks()
{
   g_BullOB_High = 0;  g_BullOB_Low  = 0;
   g_BearOB_High = 0;  g_BearOB_Low  = 0;

   int scanBars       = 30;     // H1 bars to scan
   int impulseLen     = 3;      // min consecutive H1 candles for an impulse
   double minPips     = 12.0;   // min total impulse size in pips

   // --- BULLISH ORDER BLOCK: bearish H1 candle before a bullish impulse ---
   for(int i = impulseLen; i < scanBars; i++)
   {
      // Check bars i (oldest) down to i-impulseLen+1 (newest) are all bullish
      bool allBull = true;
      for(int j = 0; j < impulseLen; j++) {
         int idx = i - j;
         if(idx < 1) { allBull = false; break; }
         if(iClose(_Symbol, PERIOD_H1, idx) <= iOpen(_Symbol, PERIOD_H1, idx)) {
            allBull = false; break;
         }
      }
      if(!allBull) continue;

      // Check impulse size
      double impOpen  = iOpen (_Symbol, PERIOD_H1, i);                    // open of oldest impulse bar
      double impClose = iClose(_Symbol, PERIOD_H1, i - impulseLen + 1);   // close of newest
      if((impClose - impOpen) / _Point / 10.0 < minPips) continue;

      // OB = the candle just before the impulse (one bar older)
      int ob = i + 1;
      if(ob >= scanBars) continue;
      double obO = iOpen (_Symbol, PERIOD_H1, ob);
      double obC = iClose(_Symbol, PERIOD_H1, ob);
      if(obC < obO) {   // bearish candle = valid bullish OB
         g_BullOB_High = obO;
         g_BullOB_Low  = obC;
         break;         // most recent OB found
      }
   }

   // --- BEARISH ORDER BLOCK: bullish H1 candle before a bearish impulse ---
   for(int i = impulseLen; i < scanBars; i++)
   {
      bool allBear = true;
      for(int j = 0; j < impulseLen; j++) {
         int idx = i - j;
         if(idx < 1) { allBear = false; break; }
         if(iClose(_Symbol, PERIOD_H1, idx) >= iOpen(_Symbol, PERIOD_H1, idx)) {
            allBear = false; break;
         }
      }
      if(!allBear) continue;

      double impOpen  = iOpen (_Symbol, PERIOD_H1, i);
      double impClose = iClose(_Symbol, PERIOD_H1, i - impulseLen + 1);
      if((impOpen - impClose) / _Point / 10.0 < minPips) continue;

      int ob = i + 1;
      if(ob >= scanBars) continue;
      double obO = iOpen (_Symbol, PERIOD_H1, ob);
      double obC = iClose(_Symbol, PERIOD_H1, ob);
      if(obC > obO) {   // bullish candle = valid bearish OB
         g_BearOB_High = obC;
         g_BearOB_Low  = obO;
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| FAIR VALUE GAP (FVG) DETECTION — M15                              |
//| An FVG is a 3-candle pattern where the middle candle's body      |
//| creates a gap between candle 1's wick and candle 3's wick.       |
//| Bullish FVG: bar3.high < bar1.low (gap up = demand zone)        |
//| Bearish FVG: bar3.low  > bar1.high (gap down = supply zone)     |
//| Price tends to return to fill these gaps — key institutional     |
//| reference points for entries and targets.                        |
//+------------------------------------------------------------------+
void DetectFairValueGaps()
{
   // Mark existing FVGs as filled if price has traded through them
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   for(int f = 0; f < g_FVGCount; f++) {
      if(g_FVGs[f].filled) continue;
      // Bullish FVG filled when price drops into the gap
      if(g_FVGs[f].dir == 1 && bid <= g_FVGs[f].high && bid >= g_FVGs[f].low)
         g_FVGs[f].filled = true;
      // Bearish FVG filled when price rises into the gap
      if(g_FVGs[f].dir == -1 && bid >= g_FVGs[f].low && bid <= g_FVGs[f].high)
         g_FVGs[f].filled = true;
      // Expire FVGs older than 48 hours
      if(TimeCurrent() - g_FVGs[f].created > 48 * 3600)
         g_FVGs[f].filled = true;
   }

   // Scan last 30 M15 bars for new FVGs (only check confirmed bars 1+)
   int scanBars = 30;
   double minGapPips = 3.0;  // minimum gap size to be significant
   double minGap = minGapPips * _Point * 10;

   for(int i = 2; i < scanBars; i++)
   {
      // 3-candle pattern: bar i+1 (oldest), bar i (middle), bar i-1 (newest)
      double bar1_high = iHigh(_Symbol, PERIOD_M15, i + 1);  // oldest
      double bar1_low  = iLow (_Symbol, PERIOD_M15, i + 1);
      double bar3_high = iHigh(_Symbol, PERIOD_M15, i - 1);  // newest
      double bar3_low  = iLow (_Symbol, PERIOD_M15, i - 1);

      // Bullish FVG: bar3's low > bar1's high (gap between them = demand)
      if(bar3_low > bar1_high + minGap) {
         double gapHigh = bar3_low;
         double gapLow  = bar1_high;
         datetime gapTime = iTime(_Symbol, PERIOD_M15, i);
         if(!FVGExists(gapHigh, gapLow, 1)) {
            AddFVG(gapHigh, gapLow, 1, gapTime);
         }
      }

      // Bearish FVG: bar3's high < bar1's low (gap between them = supply)
      if(bar3_high < bar1_low - minGap) {
         double gapHigh = bar1_low;
         double gapLow  = bar3_high;
         datetime gapTime = iTime(_Symbol, PERIOD_M15, i);
         if(!FVGExists(gapHigh, gapLow, -1)) {
            AddFVG(gapHigh, gapLow, -1, gapTime);
         }
      }
   }

   // Clean up filled FVGs — compress array
   int writeIdx = 0;
   for(int f = 0; f < g_FVGCount; f++) {
      if(!g_FVGs[f].filled) {
         if(writeIdx != f) g_FVGs[writeIdx] = g_FVGs[f];
         writeIdx++;
      }
   }
   g_FVGCount = writeIdx;

   // Determine if price is near any active FVG
   g_NearBullFVG = false;
   g_NearBearFVG = false;
   g_NearestFVGHigh = 0;
   g_NearestFVGLow  = 0;
   g_NearestFVGDir  = 0;
   double nearestDist = 99999;
   double proxPips = 5.0 * _Point * 10;  // within 5 pips of FVG edge

   for(int f = 0; f < g_FVGCount; f++) {
      double mid = (g_FVGs[f].high + g_FVGs[f].low) / 2.0;
      double dist = MathAbs(bid - mid);

      // "Near" = price within 5 pips of FVG zone, or inside it
      bool inside = (bid >= g_FVGs[f].low - proxPips && bid <= g_FVGs[f].high + proxPips);
      if(inside && dist < nearestDist) {
         nearestDist      = dist;
         g_NearestFVGHigh = g_FVGs[f].high;
         g_NearestFVGLow  = g_FVGs[f].low;
         g_NearestFVGDir  = g_FVGs[f].dir;
         if(g_FVGs[f].dir == 1)  g_NearBullFVG = true;
         if(g_FVGs[f].dir == -1) g_NearBearFVG = true;
      }
   }
}

bool FVGExists(double high, double low, int dir)
{
   double tol = 1.0 * _Point * 10;
   for(int f = 0; f < g_FVGCount; f++) {
      if(g_FVGs[f].dir == dir &&
         MathAbs(g_FVGs[f].high - high) < tol &&
         MathAbs(g_FVGs[f].low  - low)  < tol)
         return true;
   }
   return false;
}

void AddFVG(double high, double low, int dir, datetime created)
{
   if(g_FVGCount >= ArraySize(g_FVGs))
      ArrayResize(g_FVGs, g_FVGCount + 10);
   g_FVGs[g_FVGCount].high    = high;
   g_FVGs[g_FVGCount].low     = low;
   g_FVGs[g_FVGCount].dir     = dir;
   g_FVGs[g_FVGCount].created = created;
   g_FVGs[g_FVGCount].filled  = false;
   g_FVGCount++;
}

//+------------------------------------------------------------------+
//| DRAW FVG ZONES ON CHART as semi-transparent rectangles           |
//+------------------------------------------------------------------+
void DrawFVGZones()
{
   // Remove old FVG rectangles
   for(int i = ObjectsTotal(0, 0) - 1; i >= 0; i--) {
      string name = ObjectName(0, i, 0);
      if(StringFind(name, "HABOT_FVG_") == 0)
         ObjectDelete(0, name);
   }

   // Draw active FVGs
   for(int f = 0; f < g_FVGCount; f++) {
      string name = "HABOT_FVG_" + IntegerToString(f);
      datetime t1 = g_FVGs[f].created;
      datetime t2 = TimeCurrent() + 3600;   // extend to current time + 1h

      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, g_FVGs[f].high, t2, g_FVGs[f].low);
      else {
         ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
         ObjectSetDouble (0, name, OBJPROP_PRICE, 0, g_FVGs[f].high);
         ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
         ObjectSetDouble (0, name, OBJPROP_PRICE, 1, g_FVGs[f].low);
      }

      color fvgClr = (g_FVGs[f].dir == 1) ? clrDodgerBlue : clrCrimson;
      ObjectSetInteger(0, name, OBJPROP_COLOR, fvgClr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_FILL,  true);
      ObjectSetInteger(0, name, OBJPROP_BACK,  true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetString (0, name, OBJPROP_TEXT, (g_FVGs[f].dir == 1 ? "Bull FVG" : "Bear FVG"));
   }
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

//+------------------------------------------------------------------+
//| CONFIDENCE-BASED PROBABILITY MODEL                               |
//| Scores how likely a setup is to succeed on a 0-100 scale.       |
//| Combines every analysis dimension into a weighted probability.  |
//| This replaces the old tier (1/2/3) classification.              |
//|                                                                  |
//| Factor weights (sum = 100):                                      |
//|  1. HA Pattern:      15  (clean consecutive candles)            |
//|  2. Session Quality: 10  (London/NY overlap = best)             |
//|  3. Zone Position:   10  (trade from extreme toward mid)        |
//|  4. Confluence:      10  (near Fib/Pivot level)                 |
//|  5. Bias Alignment:   5  (trade with market bias)               |
//|  6. Range Room:      10  (enough room for TP target)            |
//|  7. ATR Volatility:  10  (enough movement to reach target)      |
//|  8. Swing Structure: 10  (BOS/CHoCH alignment)                 |
//|  9. Volume:           5  (institutional activity confirms)      |
//| 10. Liquidity Sweep: 10  (stop hunt reversal = highest edge)    |
//| 11. Order Block:      5  (inside institutional zone)            |
//| 12. Fair Value Gap:  10  (FVG support/resistance)               |
//|                ──────── = 110 raw, normalized to 100             |
//| Penalties reduce score: sideways, counter-trend, divergence     |
//+------------------------------------------------------------------+
double CalcConfidence(int tradeDir, string zone, bool isMeanRev, bool isSideways, string nearLevel)
{
   double conf = 0;   // accumulate weighted confidence

   // --- 1. HA PATTERN QUALITY (0-15) ---
   // Consecutive HA candles in trade direction = trend strength
   // g_HAConsecCount is already set by EvaluateHAPattern for the active signal direction
   int consec = g_HAConsecCount;
   if(consec >= 5)      conf += 15.0;   // very strong HA trend
   else if(consec >= 4) conf += 12.0;
   else if(consec >= 3) conf += 9.0;    // minimum pattern
   else if(consec >= 2) conf += 5.0;    // early entry (if EarlyEntry on)
   // 0-1 consecutive = very weak, no points

   // --- 2. SESSION QUALITY (0-10) ---
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   bool isLondon  = (h >= LondonStartHour  && h < LondonEndHour);
   bool isNY      = (h >= NewYorkStartHour && h < NewYorkEndHour);
   bool isOverlap = isLondon && isNY;   // 13:00-16:00 = prime time
   if(isOverlap)       conf += 10.0;
   else if(isNY)       conf += 7.0;
   else if(isLondon)   conf += 7.0;
   else                conf += 2.0;  // Asian/off-hours: minimal

   // --- 3. ZONE POSITION (0-10) ---
   if(zone == "LOWER_THIRD" && tradeDir == 1)   conf += 10.0;  // buy from low
   else if(zone == "UPPER_THIRD" && tradeDir == -1)  conf += 10.0;  // sell from high
   else if(zone == "LOWER_THIRD" && tradeDir == -1)  conf += 3.0;   // sell from low (risky)
   else if(zone == "UPPER_THIRD" && tradeDir == 1)   conf += 3.0;   // buy from high (risky)
   else if(zone == "MID_ZONE")   conf += 1.0;   // mid = limited runway

   // --- 4. CONFLUENCE — near a Fib/Pivot level, TYPE scores differently per direction ---
   // Support levels (S1, S2, Fib 61.8%, 76.4%) favour BUY; resist BUY headwind if selling from support
   // Resistance levels (R1, R2, Fib 23.6%, 38.2%) favour SELL; penalise BUY at resistance
   // PP and Fib 50% are neutral
   if(nearLevel != "") {
      bool isSupport    = (StringFind(nearLevel, "S1") >= 0 || StringFind(nearLevel, "S2") >= 0 ||
                           StringFind(nearLevel, "61.8") >= 0 || StringFind(nearLevel, "76.4") >= 0);
      bool isResistance = (StringFind(nearLevel, "R1") >= 0 || StringFind(nearLevel, "R2") >= 0 ||
                           StringFind(nearLevel, "23.6") >= 0 || StringFind(nearLevel, "38.2") >= 0);
      bool isNeutral    = (!isSupport && !isResistance);   // PP, Fib 50%

      if(isNeutral) {
         conf += 6.0;   // mild boost for both directions
      } else if(isSupport) {
         if(tradeDir == 1)  conf += 12.0;  // buying at support = strong confirmation
         else               conf +=  2.0;  // selling at support = fighting against the level
      } else {  // isResistance
         if(tradeDir == -1) conf += 12.0;  // selling at resistance = strong confirmation
         else               conf +=  2.0;  // buying at resistance = fighting against the level
      }
   }

   // --- 5. BIAS ALIGNMENT (0-5, can go negative) ---
   if(tradeDir == 1  && g_TotalBias >= 2)   conf += 5.0;   // strong bull bias + buy
   else if(tradeDir == 1  && g_TotalBias >= 1)  conf += 3.0;
   else if(tradeDir == -1 && g_TotalBias <= -2) conf += 5.0;   // strong bear bias + sell
   else if(tradeDir == -1 && g_TotalBias <= -1) conf += 3.0;
   // Counter-trend penalty
   if(tradeDir == 1  && g_TotalBias <= -2) conf -= 5.0;
   if(tradeDir == -1 && g_TotalBias >= 2)  conf -= 5.0;

   // --- 6. RANGE ROOM (0-10) ---
   if(g_RangeHigh > 0 && g_RangeLow > 0) {
      double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double roomForBuy = g_RangeHigh - bid;
      double roomForSell = bid - g_RangeLow;
      double room = (tradeDir == 1) ? roomForBuy : roomForSell;
      double roomPips = room / _Point / 10.0;
      if(roomPips >= 40.0)      conf += 10.0;  // massive room
      else if(roomPips >= 25.0) conf += 7.0;
      else if(roomPips >= 15.0) conf += 4.0;
      else                      conf += 1.0;   // tight
   }

   // --- 7. ATR VOLATILITY (0-10) ---
   double atrPips = (g_ATR > 0) ? (g_ATR / _Point / 10.0) : 10.0;
   if(atrPips >= 25.0)      conf += 10.0;  // very strong volatility
   else if(atrPips >= 15.0) conf += 7.0;
   else if(atrPips >= 10.0) conf += 5.0;
   else if(atrPips >= 7.0)  conf += 3.0;
   // < 7 = dead market, minimal confidence

   // --- 8. SWING STRUCTURE (0-10) ---
   bool structAligned = false;
   if(UseSwingStructure) {
      if(g_StructureLabel == "BULLISH" && tradeDir == 1)  { conf += 5.0; structAligned = true; }
      if(g_StructureLabel == "BEARISH" && tradeDir == -1) { conf += 5.0; structAligned = true; }
      // Counter-structure penalty
      if(g_StructureLabel == "BULLISH" && tradeDir == -1)  conf -= 5.0;
      if(g_StructureLabel == "BEARISH" && tradeDir == 1)   conf -= 5.0;
      // BOS = strong continuation, CHoCH = reversal confirmed
      if(g_BOS && structAligned)   conf += 5.0;
      if(g_CHoCH && structAligned) conf += 3.0;
   }

   // --- 9. VOLUME CONFIRMATION (directional) ---
   // High volume in the TRADE direction = institutional participation = gold.
   // High volume AGAINST the trade direction = potential exhaustion move = warning.
   if(UseVolumeAnalysis) {
      // Determine price direction on the last completed bar
      double barClose = iClose(_Symbol, PERIOD_M15, 1);
      double barOpen  = iOpen (_Symbol, PERIOD_M15, 1);
      int barPriceDir = (barClose > barOpen + _Point * 3) ? 1
                      : (barClose < barOpen - _Point * 3) ? -1 : 0;  // 0 = doji

      bool volWithTrade = (barPriceDir == tradeDir);   // volume bar moved in trade direction
      bool volAgainst   = (barPriceDir != 0 && barPriceDir != tradeDir);

      if(g_VolumeState == "HIGH") {
         if(volWithTrade)  conf += 7.0;   // strong directional volume = best scenario
         else if(volAgainst) conf += 1.0; // high volume against us = possible exhaustion (slight positive — selling climax can precede reversal)
         else              conf += 3.0;   // high vol neutral bar
      } else if(g_VolumeState == "ABOVE_AVG") {
         if(volWithTrade)  conf += 4.0;
         else              conf += 2.0;
      } else if(g_VolumeState == "LOW") {
         conf -= 3.0;   // dead volume = unreliable
      }
      if(g_VolDivergence) conf -= 3.0;  // price trending but volume fading = weakening
   }

   // --- 10. LIQUIDITY SWEEP (0-10) ---
   // Sweep = institutions hunted stops, then reversed. If sweep matches our
   // direction, this is the HIGHEST-EDGE setup pattern in smart money.
   if(UseLiquiditySweep && g_LiquiditySweep) {
      if(g_SweepDir == tradeDir)  conf += 10.0;  // aligned sweep = maximum edge
      else                         conf -= 3.0;   // sweep against us = danger
   }

   // --- 11. ORDER BLOCK PROXIMITY (directional, with opposing OB penalty) ---
   bool nearOB = false;
   if(UseOrderBlocks) {
      double obTol = 3.0 * _Point * 10;
      double bidNow = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      // Aligned OB: trade in direction of institutional impulse
      if(tradeDir == 1 && g_BullOB_High > 0) {
         if(bidNow >= g_BullOB_Low - obTol && bidNow <= g_BullOB_High + obTol) {
            conf += 7.0; nearOB = true;   // buying inside bull order block = best setup
         }
      }
      if(tradeDir == -1 && g_BearOB_High > 0) {
         if(bidNow >= g_BearOB_Low - obTol && bidNow <= g_BearOB_High + obTol) {
            conf += 7.0; nearOB = true;   // selling inside bear order block = best setup
         }
      }

      // Opposing OB: trading INTO an institutional supply/demand zone (headwind penalty)
      if(tradeDir == 1 && g_BearOB_High > 0 && !nearOB) {
         // Buying but price is approaching a BEAR OB (supply zone above)
         if(bidNow >= g_BearOB_Low - obTol * 3 && bidNow <= g_BearOB_High + obTol) {
            conf -= 5.0;  // buying into supply = significant headwind
            Print("OB HEADWIND: buying into Bear OB supply zone [",
                  DoubleToString(g_BearOB_Low,5), "-", DoubleToString(g_BearOB_High,5), "]");
         }
      }
      if(tradeDir == -1 && g_BullOB_High > 0 && !nearOB) {
         // Selling but price is approaching a BULL OB (demand zone below)
         if(bidNow <= g_BullOB_High + obTol * 3 && bidNow >= g_BullOB_Low - obTol) {
            conf -= 5.0;  // selling into demand = significant headwind
            Print("OB HEADWIND: selling into Bull OB demand zone [",
                  DoubleToString(g_BullOB_Low,5), "-", DoubleToString(g_BullOB_High,5), "]");
         }
      }
   }

   // --- 12. FAIR VALUE GAP (0-10) ---
   bool nearFVG = false;
   if(UseFairValueGaps) {
      // Bullish FVG near price supports a buy; bearish FVG supports a sell
      if(tradeDir == 1 && g_NearBullFVG) { conf += 10.0; nearFVG = true; }
      if(tradeDir == -1 && g_NearBearFVG) { conf += 10.0; nearFVG = true; }
      // Opposing FVG = headwind
      if(tradeDir == 1 && g_NearBearFVG && !g_NearBullFVG) conf -= 3.0;
      if(tradeDir == -1 && g_NearBullFVG && !g_NearBearFVG) conf -= 3.0;
   }

   // --- PENALTIES ---
   if(isSideways)  conf -= 8.0;   // choppy market = unreliable signals
   if(isMeanRev)   conf -= 3.0;   // MRV = limited runway, lower confidence

   // Clamp to 0-100
   conf = MathMax(0, MathMin(100, conf));

   // Store globally for dashboard and entry logic
   g_Confidence = conf;

   // Determine level type label for logging
   string lvlType = "";
   if(nearLevel != "") {
      bool _isSup = (StringFind(nearLevel,"S1")>=0 || StringFind(nearLevel,"S2")>=0 ||
                     StringFind(nearLevel,"61.8")>=0 || StringFind(nearLevel,"76.4")>=0);
      bool _isRes = (StringFind(nearLevel,"R1")>=0 || StringFind(nearLevel,"R2")>=0 ||
                     StringFind(nearLevel,"23.6")>=0 || StringFind(nearLevel,"38.2")>=0);
      lvlType = _isSup ? "(SUP)" : _isRes ? "(RES)" : "(NEU)";
   }
   // Determine volume direction label for logging
   string volDirStr = "";
   if(UseVolumeAnalysis && g_VolumeState != "LOW") {
      double _c = iClose(_Symbol,PERIOD_M15,1); double _o = iOpen(_Symbol,PERIOD_M15,1);
      int _vd = (_c > _o+_Point*3) ? 1 : (_c < _o-_Point*3) ? -1 : 0;
      volDirStr = (_vd == tradeDir)  ? "+aligned"
                : (_vd != 0)        ? "-against" : "=doji";
   }

   Print("CONFIDENCE: ", DoubleToString(conf, 1), "%",
         " HA:", consec,
         " ATR:", DoubleToString(atrPips, 1), "pip",
         " Sess:", (isOverlap ? "OVERLAP" : isLondon ? "LONDON" : isNY ? "NY" : "OTHER"),
         " Zone:", zone,
         " Cnfl:", (nearLevel == "" ? "none" : nearLevel+lvlType),
         " Struct:", g_StructureLabel, (g_BOS ? " BOS" : ""), (g_CHoCH ? " CHoCH" : ""),
         " Vol:", g_VolumeState, volDirStr, (g_VolDivergence ? " DIV" : ""),
         " Sweep:", (g_LiquiditySweep ? g_SweepLevel : "none"),
         " OB:", (nearOB ? "YES" : "no"),
         " FVG:", (nearFVG ? (g_NearestFVGDir == 1 ? "BULL" : "BEAR") : "none"),
         " Bias:", g_TotalBias,
         " MRV:", isMeanRev, " Side:", isSideways);

   return conf;
}

//+------------------------------------------------------------------+
//| STRUCTURAL STOP-LOSS CALCULATION                                 |
//| Finds the nearest invalidation level behind our entry.          |
//| For BUY: SL below nearest support (swing low, bull OB low, FVG)|
//| For SELL: SL above nearest resistance (swing high, bear OB)    |
//| Returns SL distance in USD per 0.01 lot, clamped to min/max.   |
//+------------------------------------------------------------------+
double CalcStructuralSL(int tradeDir)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry = (tradeDir == 1) ? ask : bid;

   // Collect invalidation levels
   double levels[];
   int cnt = 0;
   ArrayResize(levels, 20);

   if(tradeDir == 1) {
      // BUY invalidation: supports BELOW entry
      if(g_SwingLow1 > 0 && g_SwingLow1 < entry) levels[cnt++] = g_SwingLow1;
      if(g_SwingLow2 > 0 && g_SwingLow2 < entry) levels[cnt++] = g_SwingLow2;
      if(g_BullOB_Low > 0 && g_BullOB_Low < entry) levels[cnt++] = g_BullOB_Low;
      if(g_RangeLow > 0 && g_RangeLow < entry) levels[cnt++] = g_RangeLow;
      if(g_AsianLow > 0 && g_AsianLow < entry) levels[cnt++] = g_AsianLow;
      // FVG lows (bullish FVGs below = demand support)
      for(int f = 0; f < g_FVGCount; f++) {
         if(g_FVGs[f].dir == 1 && g_FVGs[f].low < entry && g_FVGs[f].low > 0)
            levels[cnt++] = g_FVGs[f].low;
      }
   } else {
      // SELL invalidation: resistance ABOVE entry
      if(g_SwingHigh1 > 0 && g_SwingHigh1 > entry) levels[cnt++] = g_SwingHigh1;
      if(g_SwingHigh2 > 0 && g_SwingHigh2 > entry) levels[cnt++] = g_SwingHigh2;
      if(g_BearOB_High > 0 && g_BearOB_High > entry) levels[cnt++] = g_BearOB_High;
      if(g_RangeHigh > 0 && g_RangeHigh > entry) levels[cnt++] = g_RangeHigh;
      if(g_AsianHigh > 0 && g_AsianHigh > entry) levels[cnt++] = g_AsianHigh;
      // FVG highs (bearish FVGs above = supply resistance)
      for(int f = 0; f < g_FVGCount; f++) {
         if(g_FVGs[f].dir == -1 && g_FVGs[f].high > entry && g_FVGs[f].high > 0)
            levels[cnt++] = g_FVGs[f].high;
      }
   }

   // Find the NEAREST invalidation level (smallest distance from entry)
   double bestDist = 99999;
   double pipValue = _Point * 10;
   double minSLdist = MinSL_USD / 10.0;  // convert USD/0.01lot to price distance
   double maxSLdist = MaxSL_USD / 10.0;

   for(int i = 0; i < cnt; i++) {
      double dist = MathAbs(entry - levels[i]);
      if(dist < minSLdist * 0.5) continue;  // too close, skip (would give SL < min)
      if(dist < bestDist) bestDist = dist;
   }

   // If no structural level found, use ATR-based fallback
   if(bestDist >= 99000) {
      double atrDist = (g_ATR > 0) ? g_ATR * 1.5 : 20 * pipValue;
      bestDist = atrDist;
   }

   // Add a small buffer beyond the structural level (2 pips)
   bestDist += 2.0 * pipValue;

   // Convert price distance to USD per 0.01 lot
   // For EURUSD: 1 pip = $0.10 per 0.01 lot
   double slPips = bestDist / pipValue;
   double slUSD  = slPips * 0.10;   // $0.10 per pip per 0.01 lot

   // Clamp to user limits
   slUSD = MathMax(MinSL_USD, MathMin(MaxSL_USD, slUSD));

   // Store globally
   g_DynamicSL_USD = slUSD;
   g_DynamicTP_USD = slUSD * RRRatio;   // TP = SL × R:R

   Print("STRUCTURAL SL: $", DoubleToString(slUSD, 2), "/0.01lot",
         " (", DoubleToString(slPips, 1), " pips)",
         " TP: $", DoubleToString(g_DynamicTP_USD, 2),
         " R:R=1:", DoubleToString(RRRatio, 1));

   return slUSD;
}

//+------------------------------------------------------------------+
//| Find the nearest pivot/fib level in the trade direction          |
//| Returns the price of the first target level beyond entry price  |
//| (0 if none found) — used to place TP at structural levels       |
//+------------------------------------------------------------------+
double FindNextTargetLevel(double entryPrice, int tradeDir)
{
   double best   = 0;
   double bestDist = 99999;
   double minDist  = 5.0 * _Point * 10;  // at least 5 pips away

   // Collect all known levels
   double levels[];
   int    cnt = 0;
   ArrayResize(levels, 60);

   if(UseDailyPivot && g_PivotPP > 0) {
      levels[cnt++] = g_PivotPP;
      levels[cnt++] = g_PivotR1;
      levels[cnt++] = g_PivotS1;
      levels[cnt++] = g_PivotR2;
      levels[cnt++] = g_PivotS2;
   }
   if(g_Fib382 > 0) {
      levels[cnt++] = g_Fib236;
      levels[cnt++] = g_Fib382;
      levels[cnt++] = g_Fib500;
      levels[cnt++] = g_Fib618;
      levels[cnt++] = g_Fib764;
   }
   // Range extremes
   if(g_RangeHigh > 0) levels[cnt++] = g_RangeHigh;
   if(g_RangeLow  > 0) levels[cnt++] = g_RangeLow;
   if(g_RangeMid  > 0) levels[cnt++] = g_RangeMid;
   // Swing structure levels (H1)
   if(g_SwingHigh1 > 0) levels[cnt++] = g_SwingHigh1;
   if(g_SwingHigh2 > 0) levels[cnt++] = g_SwingHigh2;
   if(g_SwingLow1  > 0) levels[cnt++] = g_SwingLow1;
   if(g_SwingLow2  > 0) levels[cnt++] = g_SwingLow2;
   // Order block edges (institutional S/R)
   if(g_BullOB_High > 0) levels[cnt++] = g_BullOB_High;
   if(g_BullOB_Low  > 0) levels[cnt++] = g_BullOB_Low;
   if(g_BearOB_High > 0) levels[cnt++] = g_BearOB_High;
   if(g_BearOB_Low  > 0) levels[cnt++] = g_BearOB_Low;
   // Session extremes as targets
   if(g_AsianHigh > 0) levels[cnt++] = g_AsianHigh;
   if(g_AsianLow  > 0) levels[cnt++] = g_AsianLow;
   if(g_LondonHigh > 0) levels[cnt++] = g_LondonHigh;
   if(g_LondonLow  > 0) levels[cnt++] = g_LondonLow;
   // Fair Value Gap edges (institutional imbalance = magnets)
   for(int f = 0; f < g_FVGCount; f++) {
      if(cnt >= ArraySize(levels) - 2) break;
      levels[cnt++] = g_FVGs[f].high;
      levels[cnt++] = g_FVGs[f].low;
   }

   for(int i = 0; i < cnt; i++) {
      double lvl = levels[i];
      if(lvl <= 0) continue;
      double dist = 0;
      if(tradeDir == 1)  dist = lvl - entryPrice;   // buy: target above
      else                dist = entryPrice - lvl;   // sell: target below
      if(dist < minDist) continue;   // too close or wrong direction
      if(dist < bestDist) { bestDist = dist; best = lvl; }
   }
   return best;
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
      // mrvPos sanity: must be within [-0.10, 1.10] — if price is way outside the
      // range the range is stale; do not arm. Valid extreme is [0, ExtremePct].
      bool mrvInBounds = (mrvPos >= -0.10 && mrvPos <= 1.10);
      if(!g_MRVArmed && g_MRVConfirmOpen == 0 && mrvInBounds) {
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
//| BIAS ENGINE                                                      |
//| Combines manual (geo/news) inputs with automatic market signals: |
//|  1. Intraday momentum  — today open vs current price            |
//|  2. Overnight gap      — prev day close vs today open           |
//|  3. Asian session dir  — asian open vs current (info only)      |
//|  4. London session dir — london open vs current (info only)     |
//|  5. New York session   — NY open vs current (info only)         |
//| Auto bias drives the total when manual inputs are neutral (0).  |
//+------------------------------------------------------------------+
void RecalcBias()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- 1. Intraday momentum: D1 open vs current price ---
   // Use iOpen(D1,0) — the broker's authoritative daily open — not the first M15
   // bar from midnight, which can be hours before/after the actual market open.
   g_IntraDayPct = 0.0; g_IntraDayBias = 0;
   double d1Open = iOpen(_Symbol, PERIOD_D1, 0);
   if(d1Open > 0) g_TodayOpen = d1Open;  // keep g_TodayOpen fresh from D1 source
   if(d1Open > 0 && bid > 0) {
      g_IntraDayPct = (bid - d1Open) / d1Open * 100.0;
      if     (g_IntraDayPct >=  0.30) g_IntraDayBias =  2;  // strong bull day
      else if(g_IntraDayPct >=  0.10) g_IntraDayBias =  1;  // mild bull
      else if(g_IntraDayPct <= -0.30) g_IntraDayBias = -2;  // strong bear day
      else if(g_IntraDayPct <= -0.10) g_IntraDayBias = -1;  // mild bear
   }

   // --- 2. Overnight / weekend gap: prev D1 close vs today D1 open ---
   // iClose(D1,1) = last completed day's close (Friday if today is Monday).
   // iOpen(D1,0)  = today's D1 open as defined by the broker — captures the
   // full Sunday-open vs Friday-close gap, not just midnight M15.
   g_GapPct = 0.0; g_GapBias = 0;
   double prevClose = iClose(_Symbol, PERIOD_D1, 1);
   if(prevClose > 0 && d1Open > 0) {
      g_GapPct = (d1Open - prevClose) / prevClose * 100.0;
      if     (g_GapPct >=  0.08) g_GapBias =  1;  // gap up → bullish opening
      else if(g_GapPct <= -0.08) g_GapBias = -1;  // gap down → bearish opening
   }

   // --- 3. Asian session direction (display only — not in total) ---
   g_AsianPct = 0.0; g_AsianBias = 0;
   if(g_AsianOpen > 0 && bid > 0) {
      g_AsianPct = (bid - g_AsianOpen) / g_AsianOpen * 100.0;
      if     (g_AsianPct >=  0.07) g_AsianBias =  1;
      else if(g_AsianPct <= -0.07) g_AsianBias = -1;
   }

   // --- 4. London session direction (display only — not in total) ---
   g_LondonPct = 0.0; g_LondonBias = 0;
   if(g_LondonOpen > 0 && bid > 0) {
      g_LondonPct = (bid - g_LondonOpen) / g_LondonOpen * 100.0;
      if     (g_LondonPct >=  0.07) g_LondonBias =  1;
      else if(g_LondonPct <= -0.07) g_LondonBias = -1;
   }

   // --- 5. New York session direction (display only — not in total) ---
   g_NYPct = 0.0; g_NYBias = 0;
   if(g_NYOpen > 0 && bid > 0) {
      g_NYPct = (bid - g_NYOpen) / g_NYOpen * 100.0;
      if     (g_NYPct >=  0.07) g_NYBias =  1;
      else if(g_NYPct <= -0.07) g_NYBias = -1;
   }

   // --- Combined auto bias (intraday has more weight than gap) ---
   g_MarketAutoBias = g_IntraDayBias + g_GapBias;

   // --- Manual inputs ---
   int manualBias = (EURGeoBias - USDGeoBias) + (NewsImpactEUR - NewsImpactUSD);

   // --- Total: manual + auto, clamped to [-3, +3] ---
   // When manual = 0, auto drives it. When manual is set, it weights on top.
   g_TotalBias = manualBias + g_MarketAutoBias;
   if(g_TotalBias >  3) g_TotalBias =  3;
   if(g_TotalBias < -3) g_TotalBias = -3;
}

//+------------------------------------------------------------------+
//| Auto lot from balance                                            |
//+------------------------------------------------------------------+
double CalcLot()
{
   if(!AutoLotSize) return NormalizeDouble(ManualLotSize, 2);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   // Risk-based position sizing: risk RiskPercent% of balance per trade
   // Uses MaxSL_USD as the worst-case SL to ensure we never over-risk
   double riskUSD = bal * RiskPercent / 100.0;
   double worstSL = MaxSL_USD;
   if(worstSL <= 0) worstSL = 2.50;  // safety fallback
   double lot = (riskUSD / worstSL) * 0.01;
   lot = MathFloor(lot * 100.0) / 100.0;  // round DOWN to nearest 0.01
   if(lot < 0.01) lot = 0.01;
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

   // === FOREIGN TRADE GUARD ===
   // If a non-bot trade exists on this symbol, respect the one-trade rule
   if(RespectForeignTrades && g_ForeignCountSymbol > 0) {
      Print("ENTRY BLOCKED: ", g_ForeignCountSymbol, " foreign trade(s) open on ", _Symbol,
            " (", DoubleToString(g_ForeignLotsSymbol,2), " lots) — one-trade rule");
      return;
   }

   // === DAILY TRADE LIMIT ===
   if(MaxDailyTrades > 0 && g_DailyTradeCount >= MaxDailyTrades) {
      return;   // silent — already logged when limit was hit
   }

   // === DAILY LOSS LIMIT ===
   if(MaxDailyLossUSD > 0 && g_DailyPnL <= -MaxDailyLossUSD) {
      return;   // daily loss cap hit — stop trading for today
   }

   // === CONSECUTIVE LOSS COOLDOWN ===
   if(g_CooldownUntil > 0 && TimeCurrent() < g_CooldownUntil) {
      return;   // still in cooldown after consecutive losses
   }
   if(g_CooldownUntil > 0 && TimeCurrent() >= g_CooldownUntil) {
      Print("COOLDOWN expired — resuming trading (consec losses reset)");
      g_CooldownUntil = 0;
      g_ConsecLosses  = 0;
   }

   // === NO ENTRY AFTER HOUR ===
   if(NoEntryAfterHour > 0) {
      MqlDateTime entryDt;
      TimeToStruct(TimeCurrent(), entryDt);
      if(entryDt.hour >= NoEntryAfterHour) {
         return;   // too late in the day
      }
   }

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
   bool canBuy  = (g_TotalBias > -3);
   bool canSell = (g_TotalBias <  3);
   if(tradeDir == 1  && !canBuy)  { Print("BUY blocked by STRONG BEAR bias (", g_TotalBias, ")");  return; }
   if(tradeDir == -1 && !canSell) { Print("SELL blocked by STRONG BULL bias (", g_TotalBias, ")"); return; }

   // === FIB / PIVOT CONFLUENCE (check BEFORE tier calc) ===
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

   // === CONFIDENCE-BASED PROBABILITY MODEL ===
   // Scores the setup 0-100% and computes dynamic SL/TP
   bool isMidContext = (zone == "MID_ZONE" || isSideways);
   double confidence = CalcConfidence(tradeDir, zone, isMeanRev, isSideways, g_NearLevel);

   // === CONFIDENCE GATE — reject low-probability setups ===
   if(confidence < MinConfidence) {
      Print("ENTRY REJECTED: confidence ", DoubleToString(confidence, 1),
            "% < min ", DoubleToString(MinConfidence, 1), "%");
      return;
   }

   // === STRUCTURAL STOP-LOSS ===
   double slBase = CalcStructuralSL(tradeDir);  // sets g_DynamicSL_USD, g_DynamicTP_USD

   // === ATR-INFORMED TP BOOST ===
   // If a structural level is closer than R:R-derived TP, use that;
   // if a level is further and within reach, extend TP
   double baseTpUSD = g_DynamicTP_USD;  // SL × RRRatio (from CalcStructuralSL)
   double targetLvl = FindNextTargetLevel(price, tradeDir);
   if(targetLvl > 0) {
      double targetDist = MathAbs(targetLvl - price);
      double targetPips = targetDist / _Point / 10.0;
      double targetUSD  = targetPips * 0.10;
      // If the structural target gives more than R:R TP, use it (capped at $6/0.01)
      if(targetUSD > baseTpUSD && targetUSD <= 6.0) {
         Print("TP EXTENDED to structural level: $", DoubleToString(targetUSD, 2),
               " (at ", DoubleToString(targetLvl, 5), ", ", DoubleToString(targetPips, 1), " pips)");
         baseTpUSD = targetUSD;
         g_DynamicTP_USD = baseTpUSD;
      }
   }

   // Scale SL/TP by lot size
   double slUSD = g_DynamicSL_USD * scale;
   double tpUSD = baseTpUSD * scale;

   double slDist = USDtoPoints(slUSD, lot);
   double tpDist = USDtoPoints(tpUSD, lot);
   if(slDist < minStop + _Point * 5) slDist = minStop + _Point * 5;
   if(tpDist < minStop + _Point * 5) tpDist = minStop + _Point * 5;

   // Build comment tag with confidence and SL/TP for recovery
   string confStr = IntegerToString((int)MathRound(confidence));
   string tag = isMeanRev ? (tradeDir==1 ? "MRV_BUY" : "MRV_SELL")
                          : (tradeDir==1 ? "HA_BUY_v6" : "HA_SELL_v6");
   if(HAEntryMode == 1) tag = tag + "_E";
   tag = tag + "_C" + confStr
             + "_SL" + DoubleToString(g_DynamicSL_USD, 2)
             + "_TP" + DoubleToString(g_DynamicTP_USD, 2);

   // === EXECUTE ===
   bool ok = false;
   if(tradeDir == 1) {
      double sl = NormalizeDouble(ask - slDist, _Digits);
      double tp = NormalizeDouble(ask + tpDist, _Digits);
      Print("Attempting ", tag, " | Conf:", DoubleToString(confidence,1), "% Zone:", zone,
            " Lot:", lot, " Ask:", ask, " SL:", sl, " TP:", tp,
            " SL$:", DoubleToString(g_DynamicSL_USD,2), " TP$:", DoubleToString(baseTpUSD,2));
      ok = trade.Buy(lot, _Symbol, ask, sl, tp, tag);
   } else {
      double sl = NormalizeDouble(bid + slDist, _Digits);
      double tp = NormalizeDouble(bid - tpDist, _Digits);
      Print("Attempting ", tag, " | Conf:", DoubleToString(confidence,1), "% Zone:", zone,
            " Lot:", lot, " Bid:", bid, " SL:", sl, " TP:", tp,
            " SL$:", DoubleToString(g_DynamicSL_USD,2), " TP$:", DoubleToString(baseTpUSD,2));
      ok = trade.Sell(lot, _Symbol, bid, sl, tp, tag);
   }

   if(ok) {
      SetScaledThresholds(lot);
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
      g_DailyTradeCount++;
      if(MaxDailyTrades > 0 && g_DailyTradeCount >= MaxDailyTrades)
         Print("DAILY TRADE LIMIT reached (", g_DailyTradeCount, "/", MaxDailyTrades, ")");
      Print(tag, " OPENED | Conf:", DoubleToString(confidence,1), "%",
            " SL=$", DoubleToString(g_ScaledSLUSD,2),
            " TP=$", DoubleToString(g_ScaledTPUSD,2),
            " Lock=$", DoubleToString(g_ScaledLockUSD,2),
            " Trail=$", DoubleToString(g_ScaledTrailUSD,2),
            " DayTrade#", g_DailyTradeCount);
   } else {
      Print(tag, " FAILED: ", trade.ResultComment(), " Code:", trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//| Scale all USD thresholds proportionally to lot size             |
//| Uses dynamic SL/TP from confidence model (g_DynamicSL_USD etc) |
//| Lock = TP × LockPct, Trail = TP × TrailPct                     |
//+------------------------------------------------------------------+
void SetScaledThresholds(double lot)
{
   double scale = lot / 0.01;
   g_ScaledSLUSD    = g_DynamicSL_USD * scale;
   g_ScaledTPUSD    = g_DynamicTP_USD * scale;
   g_ScaledLockUSD  = g_DynamicTP_USD * LockPct * scale;   // lock at 60% of TP
   g_ScaledTrailUSD = g_DynamicTP_USD * TrailPct * scale;   // trail gap = 20% of TP
}

//+------------------------------------------------------------------+
//| TRADE MANAGEMENT v7 — CONFIDENCE-BASED DYNAMIC                   |
//| - Hard MaxLossUSD/0.01lot cap — absolute safety net             |
//| - Dynamic lock/trail from LockPct/TrailPct × TP                |
//| - Mid-range stall exit for low-momentum trades                  |
//| - Max hold bars — exit if trade is stalling below lock level    |
//| - Sideways: tighten trail when market chops                     |
//| - High-confidence trail widening when profit exceeds 2× lock   |
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
      double closedPnL = GetLastClosedDealProfit();
      RecordTradeResult(closedPnL);
      Print("Position closed by broker (SL/TP) | P&L=$", DoubleToString(closedPnL, 2));
      g_TradeOpen    = false;
      g_ProfitLocked = false;
      g_PeakProfit   = 0;
      g_OpenBarCount = 0;
      g_Signal       = "WAITING";
      return;
   }

   double profit = posInfo.Commission() + posInfo.Swap() + posInfo.Profit();
   if(profit > g_PeakProfit) g_PeakProfit = profit;

   // === HARD LOSS CAP — MaxLossUSD per 0.01 lot, ALWAYS ===
   double hardLossLimit = -(MaxLossUSD * g_CurrentLot / 0.01);
   if(profit <= hardLossLimit) {
      Print("HARD LOSS CAP triggered: profit=$", DoubleToString(profit,2),
            " limit=$", DoubleToString(hardLossLimit,2));
      trade.PositionClose(posInfo.Ticket());
      RecordTradeResult(profit);
      g_TradeOpen = false; g_ProfitLocked = false;
      g_PeakProfit = 0; g_OpenBarCount = 0; g_Signal = "WAITING";
      return;
   }

   // === MID-RANGE STALL EXIT (optional — disabled by default) ===
   // Only fires when MidRangeStallUSD > 0 (user explicitly enables).
   // Philosophy: trust the analysis. If confidence allowed the trade, give it time.
   if(MidRangeStallUSD > 0 && g_IsNearMid && !g_ProfitLocked) {
      if(g_OpenBarCount >= MidRangeMaxBars) {
         double midStallLimit = MidRangeStallUSD * g_CurrentLot / 0.01;
         if(profit < midStallLimit) {
            Print("STALL exit: open ", g_OpenBarCount, " bars profit=$",
                  DoubleToString(profit,2), " (below $", DoubleToString(midStallLimit,2), ")");
            trade.PositionClose(posInfo.Ticket());
            RecordTradeResult(profit);
            g_TradeOpen = false; g_ProfitLocked = false;
            g_PeakProfit = 0; g_OpenBarCount = 0; g_Signal = "WAITING";
            return;
         }
      }
   }

   // === MAX HOLD TIME EXIT ===
   // ONLY exits trades that are in LOSS after max hold — profitable trades keep running.
   // If the confidence allowed the entry, trust it to reach TP or SL.
   // This is a pure safety net for trades stuck in drawdown, not a profit-clipper.
   if(g_OpenBarCount >= MaxHoldBars) {
      if(profit < 0) {
         Print("MAX HOLD exit after ", g_OpenBarCount, "/", MaxHoldBars,
               " bars (IN LOSS) | profit=$", DoubleToString(profit,2),
               " conf:", DoubleToString(g_Confidence,1), "%");
         trade.PositionClose(posInfo.Ticket());
         RecordTradeResult(profit);
         g_TradeOpen = false; g_ProfitLocked = false;
         g_PeakProfit = 0; g_OpenBarCount = 0; g_Signal = "WAITING";
         return;
      }
      // Profitable but past max hold: keep running — SL/TP or trailing will close it
   }

   // === STANDARD PROFIT LOCK ===
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
      RecordTradeResult(profit);
      g_TradeOpen = false; g_ProfitLocked = false;
      g_PeakProfit = 0; g_OpenBarCount = 0; g_Signal = "WAITING";
   }
}

//+------------------------------------------------------------------+
//| GET LAST CLOSED DEAL PROFIT                                      |
//| When broker closes position (SL/TP), we query deal history to   |
//| find the P&L so we can track consecutive losses properly.       |
//+------------------------------------------------------------------+
double GetLastClosedDealProfit()
{
   // Select recent history (last 24 hours)
   datetime from = TimeCurrent() - 86400;
   datetime to   = TimeCurrent() + 3600;
   if(!HistorySelect(from, to)) return 0.0;

   int totalDeals = HistoryDealsTotal();
   // Walk backwards to find the most recent deal matching our symbol + magic
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != 202502) continue;
      // Must be an "out" deal (closing a position)
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT) continue;
      double pnl = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP);
      return pnl;
   }
   return 0.0;  // fallback if nothing found
}

//+------------------------------------------------------------------+
//| RECORD TRADE RESULT — tracks wins/losses, consecutive losses,   |
//| and triggers cooldown when ConsecLossLimit is hit               |
//+------------------------------------------------------------------+
void RecordTradeResult(double profit)
{
   g_DailyPnL += profit;
   if(profit >= 0) {
      g_DailyWins++;
      g_ConsecLosses = 0;   // reset streak on any non-loss
   } else {
      g_DailyLosses++;
      g_ConsecLosses++;
      if(ConsecLossLimit > 0 && g_ConsecLosses >= ConsecLossLimit) {
         int coolSecs = CooldownBars * 15 * 60;  // bars * 15min
         g_CooldownUntil = TimeCurrent() + (datetime)coolSecs;
         Print("CONSECUTIVE LOSS LIMIT hit (", g_ConsecLosses, " in a row) — ",
               "COOLDOWN until ", TimeToString(g_CooldownUntil),
               " (", CooldownBars, " bars / ", CooldownBars*15, " min)");
      }
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
   ObjectSetInteger(0, name, OBJPROP_ZORDER,    1);   // above background panel
}

void UpdateDashboard()
{
   string session = GetSession();

   string biasStr  = g_TotalBias >= 2  ? "STRONG BULL" :
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
   DashLine("00_title",  "[ EURUSD HA RANGE BOT v6 ]",                         cx, cy, row, lh, corner, clrWhite,     10); row++;
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

   // --- Auto bias breakdown ---
   // Intraday
   string idPct  = (g_TodayOpen > 0)
                   ? (g_IntraDayPct >= 0 ? "+" : "") + DoubleToString(g_IntraDayPct, 2) + "%"
                   : "n/a";
   string idLbl  = g_IntraDayBias >= 2 ? "STRONG BULL" : g_IntraDayBias == 1 ? "BULL" :
                   g_IntraDayBias <= -2 ? "STRONG BEAR" : g_IntraDayBias == -1 ? "BEAR" : "NEUT";
   DashLine("03a_id",    "  Intraday : " + idPct + " → " + idLbl,
                                                                                 cx, cy, row, lh, corner, (g_IntraDayBias>0?clrLime:g_IntraDayBias<0?clrRed:clrGray), 8); row++;
   // Gap
   string gapPct = (g_GapPct != 0.0)
                   ? (g_GapPct >= 0 ? "+" : "") + DoubleToString(g_GapPct, 2) + "% gap"
                   : "no gap";
   string gapLbl = g_GapBias == 1 ? "GAP UP" : g_GapBias == -1 ? "GAP DN" : "flat";
   DashLine("03b_gap",   "  Gap open : " + gapPct + " → " + gapLbl,
                                                                                 cx, cy, row, lh, corner, (g_GapBias>0?clrLime:g_GapBias<0?clrRed:clrGray), 8); row++;
   // Asian session bias
   string aPct   = (g_AsianOpen > 0)
                   ? (g_AsianPct >= 0 ? "+" : "") + DoubleToString(g_AsianPct, 2) + "%"
                   : "n/a";
   string aLbl   = g_AsianBias == 1 ? "BULL" : g_AsianBias == -1 ? "BEAR" : "NEUT";
   DashLine("03c_ab",    "  Asian    : " + aPct + " → " + aLbl,
                                                                                 cx, cy, row, lh, corner, (g_AsianBias>0?clrLime:g_AsianBias<0?clrRed:clrGray), 8); row++;
   // London session bias
   string lPct   = (g_LondonOpen > 0)
                   ? (g_LondonPct >= 0 ? "+" : "") + DoubleToString(g_LondonPct, 2) + "%"
                   : "n/a";
   string lLbl   = g_LondonBias == 1 ? "BULL" : g_LondonBias == -1 ? "BEAR" : "NEUT";
   DashLine("03d_lb",    "  London   : " + lPct + " → " + lLbl,
                                                                                 cx, cy, row, lh, corner, (g_LondonBias>0?clrLime:g_LondonBias<0?clrRed:clrGray), 8); row++;
   // New York session bias
   string nyPct  = (g_NYOpen > 0)
                   ? (g_NYPct >= 0 ? "+" : "") + DoubleToString(g_NYPct, 2) + "%"
                   : "n/a";
   string nyLbl  = g_NYBias == 1 ? "BULL" : g_NYBias == -1 ? "BEAR" : "NEUT";
   DashLine("03e_nyb",   "  NewYork  : " + nyPct + " → " + nyLbl,
                                                                                 cx, cy, row, lh, corner, (g_NYBias>0?clrLime:g_NYBias<0?clrRed:clrGray), 8); row++;
   // Manual override indication
   int manualBias = (EURGeoBias - USDGeoBias) + (NewsImpactEUR - NewsImpactUSD);
   if(manualBias != 0) {
      DashLine("03e_man", "  Manual   : " + (manualBias > 0 ? "+" : "") + IntegerToString(manualBias) + " (geo/news override)",
                                                                                 cx, cy, row, lh, corner, clrGold,             8); row++;
   }
   double riskUsd = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   DashLine("04_lot",    "Lot     : " + DoubleToString(g_CurrentLot, 2) +
            " (Risk " + DoubleToString(RiskPercent,1) + "% = $" + DoubleToString(riskUsd,2) + ")",
                                                                                 cx, cy, row, lh, corner, clrWhite,      9); row++;

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
   DashLine("05_rh",     "Range   H: " + rhStr,                                 cx, cy, row, lh, corner, clrAqua,       9); row++;
   DashLine("06_rl",     "Range   L: " + rlStr,                                 cx, cy, row, lh, corner, clrAqua,       9); row++;
   DashLine("07_rm",     "Range   M: " + rmStr,                                 cx, cy, row, lh, corner, clrAqua,       9); row++;
   // Yesterday's fixed reference (does not expand intraday)
   string pdHStr = (g_PrevDayHigh > 0) ? "Prev H:" + DoubleToString(g_PrevDayHigh, 5) +
                                         "  L:"    + DoubleToString(g_PrevDayLow,  5) : "PrevDay: N/A";
   DashLine("07a_pd",    pdHStr,                                                 cx, cy, row, lh, corner, clrYellow,     8); row++;
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

   // --- Market Structure & Smart Money ---
   color structClr = (g_StructureLabel == "BULLISH") ? clrLime :
                     (g_StructureLabel == "BEARISH") ? clrRed : clrGray;
   string structStr = g_StructureLabel;
   if(g_BOS)   structStr += " BOS";
   if(g_CHoCH) structStr += " CHoCH!";
   DashLine("10b_struct", "Struct  : " + structStr,                              cx, cy, row, lh, corner, structClr, 9); row++;
   if(g_SwingHigh1 > 0 || g_SwingLow1 > 0)
      DashLine("10b2_sw",  "  SH:" + (g_SwingHigh1>0 ? DoubleToString(g_SwingHigh1,5) : "n/a") +
                            " SL:" + (g_SwingLow1>0 ? DoubleToString(g_SwingLow1,5) : "n/a"),
                                                                                 cx, cy, row, lh, corner, clrSilver, 8);
   else
      DashLine("10b2_sw",  "",                                                   cx, cy, row, lh, corner, clrGray, 8);
   row++;

   color volClr = (g_VolumeState == "HIGH" || g_VolumeState == "ABOVE_AVG") ? clrLime :
                  (g_VolumeState == "LOW") ? clrRed : clrGray;
   DashLine("10c_vol",   "Volume  : " + g_VolumeState + " (x" + DoubleToString(g_VolRatio,1) + ")" +
                          (g_VolDivergence ? " DIVERGENCE" : ""),                 cx, cy, row, lh, corner, volClr, 9); row++;

   if(g_LiquiditySweep)
      DashLine("10d_sweep", "Sweep   : " + g_SweepLevel + (g_SweepDir==1?" BUY":" SELL"),
                                                                                 cx, cy, row, lh, corner, clrGold, 9);
   else
      DashLine("10d_sweep", "",                                                  cx, cy, row, lh, corner, clrGray, 8);
   row++;

   string obLine = "";
   if(g_BullOB_High > 0) obLine += "Bull:" + DoubleToString(g_BullOB_Low,5) + "-" + DoubleToString(g_BullOB_High,5);
   if(g_BearOB_High > 0) {
      if(obLine != "") obLine += " ";
      obLine += "Bear:" + DoubleToString(g_BearOB_Low,5) + "-" + DoubleToString(g_BearOB_High,5);
   }
   if(obLine != "")
      DashLine("10e_ob",  "OB      : " + obLine,                                cx, cy, row, lh, corner, clrYellow, 7);
   else
      DashLine("10e_ob",  "",                                                    cx, cy, row, lh, corner, clrGray, 7);
   row++;

   // --- Fair Value Gaps ---
   if(UseFairValueGaps) {
      string fvgStr = IntegerToString(g_FVGCount) + " active";
      if(g_NearBullFVG || g_NearBearFVG) {
         fvgStr += " | Near: " + (g_NearBullFVG ? "BULL" : "BEAR") + " FVG " +
                   DoubleToString(g_NearestFVGLow, 5) + "-" + DoubleToString(g_NearestFVGHigh, 5);
      }
      color fvgClr = (g_NearBullFVG || g_NearBearFVG) ? clrDodgerBlue : clrGray;
      DashLine("10f_fvg",  "FVG     : " + fvgStr,                               cx, cy, row, lh, corner, fvgClr, 8); row++;
   } else {
      DashLine("10f_fvg",  "",                                                   cx, cy, row, lh, corner, clrGray, 8); row++;
   }

   // --- Confidence Score (live, recalculated from current signals) ---
   {
      string confStr2 = DoubleToString(g_Confidence, 1) + "%";
      color  confClr2 = (g_Confidence >= 80) ? clrGold :
                        (g_Confidence >= MinConfidence) ? clrLime :
                        (g_Confidence > 0) ? clrOrange : clrGray;
      string confLine = "Conf    : " + confStr2 +
                        "  SL:$" + DoubleToString(g_DynamicSL_USD, 2) +
                        "  TP:$" + DoubleToString(g_DynamicTP_USD, 2) +
                        "  R:R=1:" + DoubleToString(RRRatio, 1);
      DashLine("10g_conf", confLine,                                             cx, cy, row, lh, corner, confClr2, 8); row++;
   }
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
   // New York session O/H/L
   if(g_NYSeeded || g_NYHigh > 0) {
      DashLine("13a_ny",     "NewYork : O:" + DoubleToString(g_NYOpen, 5),     cx, cy, row, lh, corner, clrSilver, 9); row++;
      DashLine("13b_ny",     "          H:" + DoubleToString(g_NYHigh, 5) +
                             "  L:" + DoubleToString(g_NYLow,  5),              cx, cy, row, lh, corner, clrSilver, 9); row++;
   } else {
      DashLine("13a_ny",     "NewYork : Waiting...",                           cx, cy, row, lh, corner, clrGray,   9); row++;
      DashLine("13b_ny",     "",                                                cx, cy, row, lh, corner, clrGray,   9); row++;
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

   // --- Foreign trade awareness ---
   if(g_ForeignCountSymbol > 0) {
      string fStr = IntegerToString(g_ForeignCountSymbol) + " foreign on " + _Symbol
                    + " (" + DoubleToString(g_ForeignLotsSymbol, 2) + " lots)";
      DashLine("13c_fgn",  "FOREIGN : " + fStr,                                 cx, cy, row, lh, corner, clrOrangeRed, 9); row++;
      DashLine("13d_fgnd", "  " + g_ForeignSummary,                             cx, cy, row, lh, corner, clrOrange,    8); row++;
      if(RespectForeignTrades)
         DashLine("13e_fgnw", "  >> Bot PAUSED (one-trade rule)",               cx, cy, row, lh, corner, clrRed,       8); row++;
   } else if(g_ForeignCountTotal > 0) {
      string fAllStr = IntegerToString(g_ForeignCountTotal) + " foreign on other pairs";
      DashLine("13c_fgn",  "Foreign : " + fAllStr,                              cx, cy, row, lh, corner, clrGray,      8); row++;
      DashLine("13d_fgnd", "",                                                   cx, cy, row, lh, corner, clrGray,      8); row++;
      DashLine("13e_fgnw", "",                                                   cx, cy, row, lh, corner, clrGray,      8); row++;
   } else {
      DashLine("13c_fgn",  "Foreign : none",                                    cx, cy, row, lh, corner, clrGray,      8); row++;
      DashLine("13d_fgnd", "",                                                   cx, cy, row, lh, corner, clrGray,      8); row++;
      DashLine("13e_fgnw", "",                                                   cx, cy, row, lh, corner, clrGray,      8); row++;
   }
   row++;

   color  tColor   = g_TradeOpen ? clrLime : clrGray;
   DashLine("14_trade",  "Trade   : " + (g_TradeOpen ? "OPEN" : "NONE"),        cx, cy, row, lh, corner, tColor,        9); row++;

   if(g_TradeOpen) {
      string modeStr  = g_IsMeanRev ? "MEAN REV" : (g_IsNearMid ? "MID-validated" : "TREND");
      color  modeClr  = g_IsMeanRev ? clrGold : (g_IsNearMid ? clrOrange : clrLime);
      DashLine("14b_mode", "Mode    : " + modeStr,                              cx, cy, row, lh, corner, modeClr,       9); row++;

      // Confidence + dynamic SL/TP display
      string confLabel = "Conf " + DoubleToString(g_Confidence, 0) + "%";
      color  confClr = (g_Confidence >= 80) ? clrGold : (g_Confidence >= 65) ? clrCyan : clrSilver;
      DashLine("14b2_conf", confLabel +
               "  SL:$" + DoubleToString(g_ScaledSLUSD, 2) +
               "  TP:$" + DoubleToString(g_ScaledTPUSD, 2) +
               "  Lock:$" + DoubleToString(g_ScaledLockUSD, 2) +
               "  Trail:$" + DoubleToString(g_ScaledTrailUSD, 2),               cx, cy, row, lh, corner, confClr,       8); row++;

      if(g_NearLevel != "")
         DashLine("14d_lvl", "Cnfl    : " + g_NearLevel,                        cx, cy, row, lh, corner, clrGold,       9); row++;

      // Hold bar display — simple max hold (no graduated cutoffs)
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

   // --- Daily trading stats ---
   row++;
   string dayStatsStr = "W:" + IntegerToString(g_DailyWins) +
                        " L:" + IntegerToString(g_DailyLosses) +
                        " P&L:$" + DoubleToString(g_DailyPnL, 2) +
                        " (" + IntegerToString(g_DailyTradeCount) + "/" +
                        (MaxDailyTrades > 0 ? IntegerToString(MaxDailyTrades) : "∞") + " trades)";
   color dayClr = g_DailyPnL > 0 ? clrLime : g_DailyPnL < 0 ? clrRed : clrGray;
   DashLine("18_dstat", "Today   : " + dayStatsStr,                             cx, cy, row, lh, corner, dayClr,        8); row++;

   // Cooldown / consecutive loss warning
   if(MaxDailyLossUSD > 0 && g_DailyPnL <= -MaxDailyLossUSD) {
      DashLine("18b_cool", "DAILY LOSS CAP HIT: -$" + DoubleToString(MathAbs(g_DailyPnL),2) + " (max -$" + DoubleToString(MaxDailyLossUSD,2) + ") — NO MORE TRADES",
                                                                                 cx, cy, row, lh, corner, clrRed,       8); row++;
   } else if(g_CooldownUntil > 0 && TimeCurrent() < g_CooldownUntil) {
      int secsLeft = (int)(g_CooldownUntil - TimeCurrent());
      DashLine("18b_cool", "COOLDOWN: " + IntegerToString(secsLeft/60) + "m " +
               IntegerToString(secsLeft%60) + "s (" + IntegerToString(g_ConsecLosses) + " consec losses)",
                                                                                 cx, cy, row, lh, corner, clrRed,       8); row++;
   } else if(g_ConsecLosses > 0) {
      DashLine("18b_cool", "ConsecL : " + IntegerToString(g_ConsecLosses) + "/" + IntegerToString(ConsecLossLimit) + " before cooldown",
                                                                                 cx, cy, row, lh, corner, clrOrange,    8); row++;
   } else {
      DashLine("18b_cool", "",                                                   cx, cy, row, lh, corner, clrGray,      8); row++;
   }

   // --- Semi-transparent background panel (drawn last; OBJ_RECTANGLE_LABEL renders behind OBJ_LABEL) ---
   {
      int    bgPad = 5;
      int    bgW   = 258;
      int    bgH   = row * lh + bgPad * 2;
      int    bgX   = MathMax(0, cx - bgPad);
      int    bgY   = MathMax(0, cy - bgPad);
      string bgName = DASH_PREFIX + "BG_panel";
      if(ObjectFind(0, bgName) < 0)
         ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER,     corner);
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE,  bgX);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE,  bgY);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE,       bgW);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE,       bgH);
      ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR,     C'8,12,28');  // dark navy
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_COLOR,        C'60,80,120'); // subtle blue-grey border
      ObjectSetInteger(0, bgName, OBJPROP_TRANSPARENCY, 45);           // 0=opaque 100=invisible; 45≈55% visible
      ObjectSetInteger(0, bgName, OBJPROP_BACK,         false);
      ObjectSetInteger(0, bgName, OBJPROP_ZORDER,       0);            // below all text labels
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE,   false);
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