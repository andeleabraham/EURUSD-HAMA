//+------------------------------------------------------------------+
//|  EURUSD Heiken Ashi Range Bot v6.27c                             |
//|  Reverted v6.26a H1 structure changes that caused late entries   |
//|  STANDARD / SENTINEL / MOMENTUM / ADAPTIVE / HARVESTER / CHRONO |
//+------------------------------------------------------------------+
#property copyright   "EURUSD HA Range Bot"
#property version     "6.27c"
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
// Trade management mode — controls how profits are protected during a live trade:
//   0 = STANDARD  — classic lock/trail. Locks at LockPct of TP, trails at TrailPct.
//   1 = SENTINEL  — conservative guardian. Early lock (40% TP), tighter trail, time decay exit.
//   2 = MOMENTUM  — structure-informed. Widens trail on aligned BOS, tightens on adverse CHoCH.
//   3 = ADAPTIVE  — full smart mode. Tracks peak/trough, dwindling detection, structure exits.
//   4 = HARVESTER — profit-tier slasher. Closes at $1/$1.50/$2 (per 0.01 lot) based on context.
//   5 = CHRONO   — session-aware hybrid. Slashes in quiet sessions, rides in active ones.
input int    TradeMgmtMode    = 3;      // 0-5: STD|SENT|MOM|ADAPT|HARVEST|CHRONO
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

input group "=== ASIAN SESSION MOMENTUM ==="
// When the LAST HOUR of the previous trading day moved strongly in a direction,
// Asian-session signals aligned with that direction get a confidence bonus and
// the zone filter can be relaxed (trade is allowed outside the normal LOWER/UPPER thirds).
// This reflects the tendency for Asian price action to continue the close-of-day bias
// before the London open resets the order flow.
input bool   AsianPrevDayMomEnabled = true;   // Enable prev-day last-hour momentum for Asian session
input double AsianMomentumBonusPts  = 6.0;    // Confidence bonus when aligned (add-only, never penalises)
input bool   AsianZoneStrictMode    = false;  // false=RELAX zone filter when momentum aligned; true=always enforce zones
// RELAX mode: when prev-day momentum aligns with signal AND multiple factors agree,
// the standard zone block (UPPER_THIRD for buy / LOWER_THIRD for sell) is lifted in Asian hours.
// The trade is entered with standard (not narrowed) SL and a logged CAUTION note.

input group "=== MANUAL RANGE OVERRIDE ==="
input bool   UseManualRange   = false;
input double ManualRangeHigh  = 0.0;
input double ManualRangeLow   = 0.0;

input group "=== EARLY SESSION RANGE ==="
input int    EarlySessionHours = 4;     // Use prev-day range when today's range is narrower than MinRangePips
input double MinRangePips      = 30.0;  // Minimum range width in pips before switching to prev-day reference

input group "=== HEIKEN ASHI SETTINGS ==="
input int    MaxConsecCandles    = 4;
input bool   TrendBoldEnabled    = true;   // Evaluate trend bold bet when MaxConsecCandles exceeded (instead of hard reset)
input int    SmallBoldMinScore   = 4;      // Min confluence score (0-10) for SMALL_BOLD tier (conservative TP)
input int    HugeBoldMinScore    = 7;      // Min score for HUGE_BOLD tier (TP chases full CI boundary)
input double SmallBoldTPPct      = 0.75;   // SMALL_BOLD TP: fraction of distance to CI boundary (0.75 = 75%)
input int    TrendBoldHardCap    = 12;     // Absolute hard cap: always reset when consec > this (safety)
// Entry mode:
// 1 = EARLY (default) — enter within first EarlyEntryMins of the confirming candle
//     Requires clean bottomless/topless candle (no double-sided wicks)
// 2 = LATE            — enter in last 5 min of the bar AFTER the confirming candle
input int    HAEntryMode         = 1;      // 1=Early entry (default), 2=Late entry
input int    EarlyEntryMins      = 5;      // Minutes window for early entry (5 min on 15M chart)
input bool   AllowLateEntry      = true;   // Also allow entry after early window closes (until bar closes)
input int    BollingerPeriod     = 21;     // Bollinger middle-line SMA period (M15)
input double NarrowBandPips      = 15.0;   // Band width (pips) below which Bollinger gate is relaxed

input group "=== KEY HOUR BONUS ==="
// Certain full-hour marks see institutional order flow and higher probability moves:
//   00:00 Asian open  03:00 Asia late  04:00 Pre-London  07:00 Frankfurt
//   08:00 London open  12:00 Midday  13:00 NY open  17:00 London close  21:00 NY close
input bool   KeyHourBonusEnabled = true;   // Award confidence bonus near key session-boundary hours
input double KeyHourBonusPts     = 8.0;   // Points within 15 min of key hour (half-points within 30 min)

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
input bool   UseMacroStructure   = true;   // Detect higher-TF swing structure (H4/D1) for macro bias
input ENUM_TIMEFRAMES MacroStructTF = PERIOD_H4; // Higher timeframe to use for macro structure
input double BoldBetMinConf      = 55.0;   // Min confidence % to trigger a bold-bet entry (MTF + FVG/OB aligned)
input bool   BollOverrideEnabled = true;   // Allow Bollinger gate to be bypassed by strong structural confluence
input int    BollOverrideMinScore= 3;      // Min confluence score (out of 10) needed to override Bollinger gate
input bool   UseOrderBlocks      = true;   // Detect H1 institutional order blocks
input double OBMinBodyPips       = 8.0;    // Minimum OB candle body size in pips (filters doji/tiny OBs)
input int    OBScanBars          = 60;     // H1 bars to scan (~2.5 days; was 30)
input bool   UseVolumeAnalysis   = true;   // Tick volume confirmation & divergence
input bool   UseLiquiditySweep   = true;   // Detect stop-hunt sweeps at key levels
input bool            UseFairValueGaps = true;      // Detect and display Fair Value Gaps
input ENUM_TIMEFRAMES FVGTimeframe     = PERIOD_H1;  // Timeframe for FVG detection (H1 recommended)
input double          FVGMinGapPips    = 10.0;       // Minimum gap size in pips to qualify (3-pip M15 gaps = noise)
input bool   UseH4SMC           = true;    // Detect H4-timeframe FVGs and Order Blocks (macro supply/demand map)
input double H4FVGMinGapPips    = 20.0;    // Min gap in pips for H4 FVG detection (major imbalances; H1 threshold is 10p)
input int    H4OBScanBars       = 40;      // H4 bars to scan for order blocks (~6.7 days of history)
input double MinConfidence       = 35.0;   // Minimum confidence % to take a trade (0-100)
//
// MacroBOS hard block: when the H4 trend has broken structure (g_MacroBOS=true),
// taking a trade in the OPPOSITE direction is a high-risk counter-trend bet.
// Default=true blocks it entirely so the bot does not fight a confirmed macro move.
input bool   MacroBOSHardBlock   = true;   // Block trades against confirmed H4 MacroBOS direction
input double CHoCHReversalTPScale = 0.65;   // TP multiplier for CHoCH reversal trades (counter-trend, cautious; 0=disabled)
//
// MTF / volume divergence caution: when H4 and H1 disagree (MTF not aligned) AND volume
// is declining against the price trend simultaneously, both signals are weak — skip the trade.
// If only ONE of the two diverges, all other factors still support the trade → full TP.
input bool   DivergenceCautionEnabled = true;  // Block trade when BOTH MTF diverged AND volume diverging
input double DivergenceLockTP    = 1.00;   // (legacy — no longer used for capping; reserved for future)

input group "=== MACRO TREND RIDE ==="
// When H4 structure has broken structure (MacroBOS confirmed), a large intraday move often follows
// in the BOS direction — typically 80-120+ pips within the London/NY session.
// Example: BEARISH BOS at 1.16950 → move to 1.15950 by 14:00-15:00.
// This mode enters WITH the BOS when HA candles confirm the trend is underway,
// using a wider SL ($2.75/0.01) and targeting the next major HTF level (up to $8).
// Asian session is blocked: Asia often makes a small counter-BOS move before the
// real continuation begins at London open. Wait for non-Asian confirmation.
input bool   MacroTrendRideEnabled  = true;   // Enable MacroBOS intraday trend-ride entries
input int    MacroTrendMinScore     = 5;      // Min ZoneContextScore (0-14) — higher = more selective
input double MacroTrendSL_USD       = 2.75;   // SL per 0.01 lot (wider space for trend volatility)
input double MacroTrendMinTP_USD    = 4.00;   // Floor TP per 0.01 lot (minimum target for a trend ride)
input double MacroTrendMaxTP_USD    = 8.00;   // Ceiling TP per 0.01 lot (cap at realistic intraday range)
input bool   MacroTrendAsianBlock   = true;   // Block during Asian session (wait for London/NY momentum)

input group "=== RANGE ZONE FILTERS ==="
// How far inside range boundaries before a trade is allowed (as % of total range)
input double MidZonePct       = 0.30;   // Mid zone = middle 30% of range (15% each side of mid)
input double ExtremePct       = 0.15;   // Extreme zone = outer 15% near H/L (avoid for trend)
// Mean reversion: enter when HA confirms bounce from range extreme
input bool   AllowMeanReversion = true; // Enable HA-confirmed mean reversion trades at range extremes
//
// Zone strictness controls how "wrong zone" trend trades are treated:
//   0 = STRICT        — Hard block. Zone is an absolute barrier; no exceptions ever.
//   1 = RELAXED       — Block unless Asian session + prev-day carry-over bias (original default).
//   2 = CONTEXT_AWARE — Smart mode. Scores structural confluence (up to 14 points):
//                       If score >= ZoneContextMinScore AND price is approaching a Fib/Pivot level
//                       → sets PENDING state; waits for that level to break + momentum before entry.
//                       If score sufficient AND no Fib barrier ahead (or already past one)
//                       → allows CAUTION entry, logged to journal for learning.
//                       Ideal for trending markets where the zone filter alone is misleading.
input int    ZoneStrictness        = 2;    // 0=STRICT | 1=RELAXED (Asian relax) | 2=CONTEXT_AWARE
input int    ZoneContextMinScore   = 4;    // Min confluence score (0-14) for CONTEXT_AWARE zone override
input bool   ZonePendingEnabled    = true; // CONTEXT mode: wait for Fib/Pivot breakout before entry
input double ZonePendingPips       = 10.0; // Pip lookahead: detect approaching Fib/Pivot within this range
input int    ZonePendingMaxBars    = 4;    // CONTEXT mode: auto-expire pending wait after N M15 bars (4=1hr)
//
// Extended zone analysis — channels, multi-day S/R, and Fib extensions
input bool   UseMurrayChannels    = true;  // Compute Murray Math octave levels from H4 swing range
input bool   UseWeeklySR          = true;  // Track weekly & 3-day H/L for multi-day support/resistance
input bool   UseFibExtensions     = true;  // Add 127.2% and 161.8% Fib extension levels beyond range

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
input int    PostTradeCoolBars  = 2;     // Cool-off bars after ANY trade closes before next entry (2 = 30 min)
input int    StartupGraceMins   = 4;     // After real restart, wait N minutes before allowing entry (0=disabled; skipped on timeframe switch)
input int    NoEntryAfterHour   = 21;    // No new entries after this server hour (0-23, 0=disabled)
input int    PrepMaxBars        = 8;     // Max bars PREPARING can wait for Bollinger confirm before expiring (0=no limit)
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
double g_PrevWeekHigh = 0, g_PrevWeekLow = 0;  // W1[1] previous completed week
double g_ThreeDayHigh = 0, g_ThreeDayLow = 0;  // rolling 3-day high/low (D1[0..2])
double g_Murray[9];            // Murray Math octave levels [0/8 .. 8/8]
double g_MurrayBase  = 0;     // Murray channel base price (lowest octave)
double g_MurrayRange = 0;     // Murray channel total range (8/8 - 0/8)
double g_FibExt1272  = 0;     // Fib 127.2% extension (above range for buys)
double g_FibExt1618  = 0;     // Fib 161.8% extension (above range for buys)
double g_FibExt1272L = 0;     // Fib 127.2% extension (below range for sells)
double g_FibExt1618L = 0;     // Fib 161.8% extension (below range for sells)
string g_ZoneHardness = "HARD";  // "SOFT" or "HARD" — zone boundary expected to hold?
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

// === ADAPTIVE TRADE MANAGEMENT TRACKING ===
double g_TroughProfit     = 0;       // lowest profit since trade opened (max adverse excursion)
int    g_BarsSincePeak    = 0;       // M15 bars since g_PeakProfit was last updated
int    g_TradeDir         = 0;       // +1=BUY, -1=SELL (set at entry, persisted during trade)
string g_EntryStructLabel = "";      // H1 structure label at entry time
string g_EntryMacroLabel  = "";      // Macro structure label at entry time
bool   g_EarlyLockEngaged = false;   // SENTINEL/ADAPTIVE: early lock level has been reached
int    g_StructShiftCount = 0;       // times H1 structure changed direction during trade
string g_LastMgmtAction   = "";      // last management action label (for dashboard/log)
string g_TradeMgmtModeName = "STANDARD"; // resolved mode name

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

// Bollinger middle line + bands (M15, BollingerPeriod SMA)
double   g_BollingerMid1   = 0;     // confirmed bar 1 (most recent closed bar)
double   g_BollingerMid2   = 0;     // confirmed bar 2
double   g_BollingerUpper1 = 0;     // upper band bar 1 (for narrow-band detection)
double   g_BollingerLower1 = 0;     // lower band bar 1
double   g_BollingerUpper2 = 0;     // upper band bar 2
double   g_BollingerLower2 = 0;     // lower band bar 2

// Prev-day last-hour momentum (for Asian session zone relaxation)
int      g_PrevDayLastHourDir  = 0;    // +1 = prev day last hour was bullish, -1 = bearish, 0 = unknown
bool     g_AsianZoneRelaxed    = false; // true = zone filter currently relaxed due to Asian momentum alignment

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
datetime g_BOSTime   = 0;                    // when BOS was last detected (persists BOS_PERSIST_BARS H1 bars)
datetime g_CHoCHTime = 0;                    // when CHoCH was last detected
int      g_BOSPersistBars   = 4;             // persist BOS/CHoCH for N H1 bars (~4h)
bool     g_BOSActive  = false;               // true while within persistence window
bool     g_CHoCHActive = false;              // true while within persistence window

// Macro (higher-TF) structure — H4/D1 — gives the overall directional map
double g_MacroSwingHigh1 = 0, g_MacroSwingHigh2 = 0;  // two most recent macro swing highs
double g_MacroSwingLow1  = 0, g_MacroSwingLow2  = 0;  // two most recent macro swing lows
string g_MacroStructLabel = "RANGING";                 // "BULLISH" / "BEARISH" / "RANGING"
bool   g_MacroBOS   = false;                           // Macro Break of Structure
bool   g_MacroCHoCH = false;                           // Macro Change of Character (major reversal signal)
datetime g_MacroBOSTime   = 0;                         // when Macro BOS was last detected
datetime g_MacroCHoCHTime = 0;                         // when Macro CHoCH was last detected
bool     g_MacroBOSActive  = false;                    // true while within persistence window
bool     g_MacroCHoCHActive = false;                   // true while within persistence window
int      g_CHoCHDir      = 0;                          // +1=bullish CHoCH (bearish→reversal up), -1=bearish CHoCH, 0=inactive
int      g_MacroCHoCHDir = 0;                          // +1=bullish macro CHoCH, -1=bearish macro CHoCH, 0=inactive
bool     g_IsCHoCHReversal = false;                    // true when current trade is a CHoCH-driven counter-trend reversal
bool   g_MTFAligned = false;   // true when macro (H4) and intermediate (H1) agree on direction
bool   g_BoldBet    = false;   // true when MTF aligned + FVG or OB present + HA valid
bool   g_BollOverridden     = false;  // true when Bollinger gate was bypassed by confluence override
string g_BollOverrideReason = "";     // factors that triggered the override
string g_BoldTier           = "NORMAL"; // entry tier: "NORMAL" / "SMALL_BOLD" / "HUGE_BOLD"
int    g_BarsSinceLevelBreak = 999;      // bars since a key level was crossed in setup direction
string g_LevelBreakLabel    = "";        // which level was broken

// Zone-pending state (CONTEXT_AWARE ZoneStrictness=2)
bool     g_ZonePending          = false;     // True: zone-blocked trade awaiting Fib/Pivot breakout
string   g_ZonePendingLevel     = "";        // Level being monitored (e.g. "Fib 61.8%", "Pivot S1")
int      g_ZonePendingDir       = 0;         // Direction of pending trade (1=buy, -1=sell)
datetime g_ZonePendingStartTime = 0;         // Time pending state was set (bars elapsed computed from delta)
bool     g_ZoneContextUsed      = false;     // True when CONTEXT_AWARE allowed a wrong-zone CAUTION entry

// Liquidity Sweep detection
bool   g_LiquiditySweep = false;             // price swept a key level and reversed
string g_SweepLevel     = "";                // which level was swept
int    g_SweepDir       = 0;                 // 1=bullish sweep (swept low), -1=bearish (swept high)

// Volume Analysis (tick volume)
string g_VolumeState   = "NORMAL";           // "HIGH" / "ABOVE_AVG" / "NORMAL" / "LOW"
double g_VolRatio      = 1.0;               // current vol / average vol
bool   g_VolDivergence = false;              // price trending but volume declining
bool   g_DivergenceCaution = false;          // true when TP was capped due to MTF/volume divergence
string g_LastBlockReason   = "";             // last TryEntry block message — only print when it changes

// Macro Trend Ride state
bool   g_MacroTrendRide  = false;  // true when MacroBOS trend-ride conditions are met on this bar
int    g_MacroTrendDir   = 0;      // 1=bullish ride (long), -1=bearish ride (short)
int    g_MacroTrendScore = 0;      // ZoneContextScore captured at time of detection (0-14)
int    g_BoldRejectConsec = 0;      // last consec count that printed a BOLD REJECTED (throttle)

// Order Blocks (institutional entry zones on H1) — up to 3 per direction
struct OBZone {
   double high;
   double low;
   datetime created;
   bool   mitigated;   // true once price closed through the zone
};
OBZone g_BullOBs[3];   int g_BullOBCount = 0;   // demand zones (nearest-first)
OBZone g_BearOBs[3];   int g_BearOBCount = 0;   // supply zones (nearest-first)
// Legacy aliases for backward compat (point to nearest active OB)
double g_BullOB_High = 0, g_BullOB_Low = 0;
double g_BearOB_High = 0, g_BearOB_Low = 0;
datetime g_BullOB_Time = 0;
datetime g_BearOB_Time = 0;

// Fair Value Gaps (FVG) — M15 imbalance zones
struct FVGZone {
   double high;       // upper edge of gap
   double low;        // lower edge of gap
   int    dir;        // 1=bullish FVG (gap up), -1=bearish FVG (gap down)
   datetime created;  // when detected
   bool   filled;     // true once price has traded through the CE (50% midpoint)
   ENUM_TIMEFRAMES tf;  // timeframe this FVG was detected on
};
FVGZone g_FVGs[];                          // active FVG array
int     g_FVGCount        = 0;             // number of active FVGs
bool    g_NearBullFVG     = false;         // price near a bullish FVG (expect support)
bool    g_NearBearFVG     = false;         // price near a bearish FVG (expect resistance)
double  g_NearestFVGHigh  = 0;             // nearest FVG zone high
double  g_NearestFVGLow   = 0;             // nearest FVG zone low
int     g_NearestFVGDir   = 0;             // direction of nearest FVG
bool    g_FVGOverlapBullish = false;        // H1 + H4 bullish FVGs overlap = strong demand
bool    g_FVGOverlapBearish = false;        // H1 + H4 bearish FVGs overlap = strong supply

// H4 Order Blocks (macro supply/demand zones — major institutional footprints spanning days)
double g_H4BullOB_High = 0, g_H4BullOB_Low = 0;  // H4 demand zone (bull OB)
double g_H4BearOB_High = 0, g_H4BearOB_Low = 0;  // H4 supply zone (bear OB)
datetime g_H4BullOB_Time = 0;
datetime g_H4BearOB_Time = 0;
bool   g_NearH4BullOB = false;    // price inside / within 15 pips of H4 demand zone
bool   g_NearH4BearOB = false;    // price inside / within 15 pips of H4 supply zone

// H4 Fair Value Gaps (macro imbalance zones — unfilled demand/supply from days-old moves)
FVGZone g_H4FVGs[];
int     g_H4FVGCount      = 0;
bool    g_NearBullH4FVG   = false;  // price near a bullish H4 FVG (macro demand)
bool    g_NearBearH4FVG   = false;  // price near a bearish H4 FVG (macro supply)
double  g_NearestH4FVGHigh = 0;
double  g_NearestH4FVGLow  = 0;
int     g_NearestH4FVGDir  = 0;

// Confidence model output (replaces tier system)
double g_Confidence       = 0;             // 0-100% confidence score for current setup
string g_ConfBreakdown    = "";            // per-factor score breakdown for audit logs
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
datetime g_PostTradeCoolUntil = 0;   // if > 0, post-trade cooloff active until this time
datetime g_StartupGraceUntil = 0;    // if > 0, startup grace period active until this time
datetime g_LastBlockPrintBar = 0;    // throttle TryEntry block diagnostics to once per M15 bar
datetime g_PrepStartTime     = 0;    // time when PREPARING state was first armed (for PrepMaxBars expiry)
bool     g_PreflightBullOK  = false; // all downstream TryEntry gates are green for a BUY
bool     g_PreflightBearOK  = false; // all downstream TryEntry gates are green for a SELL
string   g_PreflightBlocker = "";    // first failing gate during pre-flight (for diagnostic)
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

      // Restore adaptive management globals (best-effort from available data)
      g_TroughProfit     = (profit < 0.0) ? profit : 0.0;
      g_BarsSincePeak    = 0;   // can't recover — reset to 0
      g_TradeDir         = (posInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
      g_EntryStructLabel = g_StructureLabel;    // use current (best approximation)
      g_EntryMacroLabel  = g_MacroStructLabel;  // use current
      g_EarlyLockEngaged = (profit >= g_DynamicTP_USD * 0.35 * (lot / 0.01));
      g_StructShiftCount = 0;
      g_LastMgmtAction   = "RESTORED";
      g_TradeMgmtModeName = (TradeMgmtMode == 0) ? "STANDARD" :
                             (TradeMgmtMode == 1) ? "SENTINEL" :
                             (TradeMgmtMode == 2) ? "MOMENTUM" :
                             (TradeMgmtMode == 3) ? "ADAPTIVE" :
                             (TradeMgmtMode == 4) ? "HARVESTER" : "CHRONO";

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
   ArrayInitialize(g_Murray, 0);  // zero Murray octave array

   // Seed ranges from historical data immediately
   SeedRangesFromHistory();
   // Recover any pre-existing trade so management rules apply immediately
   RestoreExistingTrade();
   RecalcBias();
   // Seed zone label and live session bar so dashboard is correct before first tick
   UpdateLiveSessionBar();
   g_ZoneLabel = ClassifyZone(SymbolInfoDouble(_Symbol, SYMBOL_BID));

   // Startup grace period: wait N minutes before allowing entries after a real restart.
   // Skipped entirely when the user simply switches timeframe or symbol (REASON_CHARTCHANGE),
   // since that is not a logic restart — conditions are still valid.
   int  _reinitReason = UninitializeReason();
   bool _isTFSwitch   = (_reinitReason == REASON_CHARTCHANGE);
   if(StartupGraceMins > 0 && !_isTFSwitch) {
      g_StartupGraceUntil = TimeCurrent() + (datetime)(StartupGraceMins * 60);
      Print("[STARTUP GRACE] Waiting ", StartupGraceMins, " min(s) before allowing entries",
            " (until ", TimeToString(g_StartupGraceUntil, TIME_MINUTES), ") reason=", _reinitReason);
   } else if(_isTFSwitch) {
      Print("[STARTUP GRACE] Skipped — timeframe/symbol switch (reason=", _reinitReason, ")");
   }

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
                  ResetTradeGlobals(pnl);
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
      if(g_TradeOpen) {
         g_OpenBarCount++;
         g_BarsSincePeak++;
      }

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
      ComputeMurrayLevels();  // Murray Math octave channels from H4
      ComputeMultiDaySR();    // weekly + 3-day S/R levels

      // Prev-day last-hour direction — recalc once per day during Asian session
      if(AsianPrevDayMomEnabled) {
         MqlDateTime bdT;
         TimeToStruct(barTime, bdT);
         bool inAsian = (bdT.hour >= AsianStartHour && bdT.hour < AsianEndHour);
         // Recalc on the first bar of Asian session (hour == AsianStartHour, minute == 0)
         // or on bot start (g_PrevDayLastHourDir == 0 and we are currently in Asian session)
         if((bdT.hour == AsianStartHour && bdT.min == 0) ||
            (inAsian && g_PrevDayLastHourDir == 0))
            CalcPrevDayLastHourDir();
         // Reset outside Asian session so it is recalculated fresh each new day
         if(!inAsian)
            g_AsianZoneRelaxed = false;
      }

      // Market structure analysis (runs on new bar only — uses confirmed bars)
      if(UseSwingStructure)  DetectSwingStructure();
      if(UseMacroStructure)  { DetectMacroStructure(); DrawMacroStructureLevels(); }
      if(UseOrderBlocks)   { DetectOrderBlocks(); DrawOBZones(); }
      if(UseVolumeAnalysis)  AnalyzeVolume();
      if(UseLiquiditySweep)  DetectLiquiditySweep();
      if(UseFairValueGaps)   { DetectFairValueGaps(); DrawFVGZones(); }
      if(UseH4SMC)           { DetectH4OrderBlocks(); DetectH4FairValueGaps(); DrawH4SMCZones(); }

      // --- FVG H1+H4 overlap confluence detection ---
      DetectFVGOverlap();

      EvaluateHAPattern();
      CheckMacroTrendRide();   // must run after EvaluateHAPattern (uses g_HAConsecCount, g_MacroBOS, etc.)
   }

   // Fire TryEntry when trend signal active, mean reversion qualifies, OR macro trend ride armed
   if(!g_TradeOpen) {
      // === LIVE BAR FAST-TRACK ===
      // When PREPARING and all downstream gates are already green (pre-flight), monitor
      // the forming bar[0] every tick. As soon as it shows HA body alignment + Bollinger OK,
      // promote to INCOMING and enter — no need to wait for bar[0] to close.
      if(g_Signal == "PREPARING BUY" && g_PreflightBullOK) {
         double _bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double _barO = iOpen(_Symbol, PERIOD_M15, 0);
         double _barH = iHigh(_Symbol, PERIOD_M15, 0);
         double _barL = iLow (_Symbol, PERIOD_M15, 0);
         double _rng  = MathMax(_barH - _barL, _Point * 5);
         double _body = _bid - _barO;
         // Bullish body forming: close above open, top wick < 33% of range, body >= 20% of range
         bool liveOK = (_body > 0) &&
                       ((_barH - _bid) < _rng * 0.33) &&
                       (_body >= _rng * 0.20);
         if(liveOK && LiveHABollingerOK(1)) {
            Print("[FAST-TRACK BUY] Preflight green + live bar bullish body=",
                  DoubleToString(_body/_Point/10.0, 1), "pip @", DoubleToString(_bid,5),
                  " — promoting PREPARING BUY → BUY INCOMING");
            g_Signal = "BUY INCOMING";
            if(g_ConfirmCandleOpen == 0) g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 0);
         }
      }
      if(g_Signal == "PREPARING SELL" && g_PreflightBearOK) {
         double _bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double _barO = iOpen(_Symbol, PERIOD_M15, 0);
         double _barH = iHigh(_Symbol, PERIOD_M15, 0);
         double _barL = iLow (_Symbol, PERIOD_M15, 0);
         double _rng  = MathMax(_barH - _barL, _Point * 5);
         double _body = _barO - _bid;   // positive when bid < open = bearish
         // Bearish body forming: close below open, bottom wick < 33% of range, body >= 20% of range
         bool liveOK = (_body > 0) &&
                       ((_bid - _barL) < _rng * 0.33) &&
                       (_body >= _rng * 0.20);
         if(liveOK && LiveHABollingerOK(-1)) {
            Print("[FAST-TRACK SELL] Preflight green + live bar bearish body=",
                  DoubleToString(_body/_Point/10.0, 1), "pip @", DoubleToString(_bid,5),
                  " — promoting PREPARING SELL → SELL INCOMING");
            g_Signal = "SELL INCOMING";
            if(g_ConfirmCandleOpen == 0) g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 0);
         }
      }

      bool hasTrendSig = (g_Signal == "BUY INCOMING" || g_Signal == "SELL INCOMING");
      bool hasMeanRev  = (MeanReversionSetup() != 0);
      if(hasTrendSig || hasMeanRev || g_MacroTrendRide) TryEntry();
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
   ComputeMurrayLevels();
   ComputeMultiDaySR();
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
      // Early session guard: if today's candle is too narrow, use prev-day H/L as the
      // reference range so zone classification and Fibs stay meaningful.
      MqlDateTime nowDt;
      TimeToStruct(TimeCurrent(), nowDt);
      bool   earlySession   = (nowDt.hour < EarlySessionHours);
      double minRangePrice  = MinRangePips * _Point * 10.0;
      bool   tooNarrow      = ((todayH - todayL) < minRangePrice);

      if(earlySession && tooNarrow && g_PrevDayHigh > 0 && g_PrevDayLow > 0) {
         // Narrow early bar — anchor to prev-day H/L so zones are tradeable
         g_RangeHigh = g_PrevDayHigh;
         g_RangeLow  = g_PrevDayLow;
         g_RangeMid  = (g_PrevDayHigh + g_PrevDayLow) / 2.0;
      } else {
         g_RangeHigh = todayH;
         g_RangeLow  = todayL;
         g_RangeMid  = (todayH + todayL) / 2.0;
      }
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
//| PREV-DAY LAST-HOUR DIRECTION                                     |
//| Reads the last 4 M15 bars of the previous trading day and        |
//| determines net direction: +1 = bullish close, -1 = bearish,     |
//| 0 = flat/unknown.  Stored in g_PrevDayLastHourDir.              |
//| Called once per day on the first new bar after midnight.         |
//+------------------------------------------------------------------+
void CalcPrevDayLastHourDir()
{
   g_PrevDayLastHourDir = 0;

   MqlDateTime today;
   TimeToStruct(TimeCurrent(), today);
   datetime todayStart   = (datetime)(TimeCurrent() - (today.hour * 3600 + today.min * 60 + today.sec));
   datetime prevDayEnd   = todayStart - 1;   // last second of yesterday

   // Find the M15 bar that was live at the end of yesterday
   int endShift = iBarShift(_Symbol, PERIOD_M15, prevDayEnd, false);
   if(endShift < 0) return;

   // Last hour = 4 M15 bars; walk startShift bars back from the end bar
   int startShift = endShift + 3;   // 4 bars total (endShift..startShift, inclusive)
   if(startShift > 200) return;

   double firstOpen  = iOpen (_Symbol, PERIOD_M15, startShift);
   double lastClose  = iClose(_Symbol, PERIOD_M15, endShift);
   if(firstOpen <= 0 || lastClose <= 0) return;

   double movePips = (lastClose - firstOpen) / _Point / 10.0;
   if(movePips >= 3.0)       g_PrevDayLastHourDir = 1;    // last hour closed bullish
   else if(movePips <= -3.0) g_PrevDayLastHourDir = -1;   // last hour closed bearish

   Print("PrevDayLastHour: open=", DoubleToString(firstOpen, 5),
         " close=", DoubleToString(lastClose, 5),
         " move=", DoubleToString(movePips, 1), "pip → dir=", g_PrevDayLastHourDir);
}

//+------------------------------------------------------------------+
//| BOLLINGER MIDDLE LINE (SMA) for M15                              |
//| Populates g_BollingerMid1 (bar 1) and g_BollingerMid2 (bar 2)  |
//+------------------------------------------------------------------+
void CalcBollinger()
{
   int handle = iBands(_Symbol, PERIOD_M15, BollingerPeriod, 0, 2.0, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return;
   double mid[], upper[], lower[];
   ArraySetAsSeries(mid,   true);
   ArraySetAsSeries(upper, true);
   ArraySetAsSeries(lower, true);
   bool midOK   = (CopyBuffer(handle, 0, 0, 4, mid)   >= 3);  // buffer 0 = SMA midline
   bool upperOK = (CopyBuffer(handle, 1, 0, 4, upper) >= 3);  // buffer 1 = upper band
   bool lowerOK = (CopyBuffer(handle, 2, 0, 4, lower) >= 3);  // buffer 2 = lower band
   if(midOK) {
      g_BollingerMid1 = mid[1];   g_BollingerMid2 = mid[2];
   }
   if(upperOK) {
      g_BollingerUpper1 = upper[1]; g_BollingerUpper2 = upper[2];
   }
   if(lowerOK) {
      g_BollingerLower1 = lower[1]; g_BollingerLower2 = lower[2];
   }
   IndicatorRelease(handle);
}

//+------------------------------------------------------------------+
//| MARKET STRUCTURE DETECTION (H1 Swing Points)                     |
//| Scans H1 bars for swing highs/lows using a 3-bar left/right     |
//| confirmation.  Determines overall structure (bullish HH/HL,      |
//| bearish LH/LL, or ranging) and flags BOS / CHoCH events.        |
//| v6.23 improvements:                                              |
//|  - 2-pip min swing distance (was 1 pip) — filters noise          |
//|  - Price-break CHoCH: bearish trend → price breaks above last LH |
//|    = bullish CHoCH confirmed, and vice versa                     |
//|  - BOS/CHoCH persist for g_BOSPersistBars H1 bars (~4h)         |
//|    so confidence scorer doesn't miss one-tick events             |
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

   // --- Persistence decay: check if previous BOS/CHoCH events have expired ---
   datetime h1BarTime = iTime(_Symbol, PERIOD_H1, 0);
   if(g_BOSTime > 0 && h1BarTime - g_BOSTime > g_BOSPersistBars * PeriodSeconds(PERIOD_H1))
      g_BOSActive = false;
   if(g_CHoCHTime > 0 && h1BarTime - g_CHoCHTime > g_BOSPersistBars * PeriodSeconds(PERIOD_H1)) {
      g_CHoCHActive = false;
      g_CHoCHDir = 0;   // direction expires with the CHoCH event
   }

   // Fresh detection this tick (may re-trigger or upgrade)
   bool freshBOS   = false;
   bool freshCHoCH = false;

   if(shCount >= 2 && slCount >= 2)
   {
      // 20-point tolerance (2 pips) to avoid noise
      double tol = _Point * 20;
      bool HH = (g_SwingHigh1 > g_SwingHigh2 + tol);
      bool HL = (g_SwingLow1  > g_SwingLow2  + tol);
      bool LH = (g_SwingHigh1 < g_SwingHigh2 - tol);
      bool LL = (g_SwingLow1  < g_SwingLow2  - tol);

      if(HH && HL)       g_StructureLabel = "BULLISH";
      else if(LH && LL)  g_StructureLabel = "BEARISH";
      else                g_StructureLabel = "RANGING";

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      // --- BOS: live price breaks the most recent swing in trend direction ---
      if(g_StructureLabel == "BULLISH" && bid > g_SwingHigh1) freshBOS = true;
      if(g_StructureLabel == "BEARISH" && bid < g_SwingLow1)  freshBOS = true;

      // --- Classic CHoCH: HH/HL ↔ LH/LL pattern flip (with direction) ---
      if(prevStructure == "BULLISH"  && g_StructureLabel == "BEARISH") { freshCHoCH = true; g_CHoCHDir = -1; }  // bearish reversal
      if(prevStructure == "BEARISH"  && g_StructureLabel == "BULLISH") { freshCHoCH = true; g_CHoCHDir =  1; }  // bullish reversal

      // --- Price-break CHoCH (ICT concept): price breaks a swing in the OPPOSITE
      //     direction to the previous trend, confirming the character change.
      //     Bearish trend: price breaks above the most recent Lower High = bull CHoCH
      //     Bullish trend: price breaks below the most recent Higher Low = bear CHoCH
      if(prevStructure == "BEARISH" && shCount >= 1 && bid > g_SwingHigh1)
         { freshCHoCH = true; g_CHoCHDir =  1; }   // bullish reversal: breaking above swing high
      if(prevStructure == "BULLISH" && slCount >= 1 && bid < g_SwingLow1)
         { freshCHoCH = true; g_CHoCHDir = -1; }   // bearish reversal: breaking below swing low
   }

   // --- Apply persistence: fresh events set timestamp + activate ---
   if(freshBOS) {
      g_BOSTime   = h1BarTime;
      g_BOSActive = true;
   }
   if(freshCHoCH) {
      g_CHoCHTime   = h1BarTime;
      g_CHoCHActive = true;
   }

   // Expose to confidence scorer & other consumers
   g_BOS   = g_BOSActive;
   g_CHoCH = g_CHoCHActive;
}

//+------------------------------------------------------------------+
//| MACRO STRUCTURE DETECTION (H4/configurable TF)                   |
//| Same HH/HL / LH/LL algorithm as DetectSwingStructure but on a   |
//| higher timeframe to get the overall directional map.             |
//| Populates g_MacroStructLabel, g_MacroBOS, g_MacroCHoCH.         |
//| Also computes g_MTFAligned (H4 and H1 agree) and g_BoldBet flag.|
//+------------------------------------------------------------------+
void DetectMacroStructure()
{
   g_MacroBOS   = false;
   g_MacroCHoCH = false;
   g_MTFAligned = false;
   g_BoldBet    = false;

   int lookback = 2;   // H4 bars each side (2 bars = 8 hrs — broad swing confirmation)
   int scanBars = 40;  // H4 bars to scan (~6.7 days — enough for 2-3 full swing cycles)

   double macroHighs[], macroLows[];
   ArrayResize(macroHighs, 6);
   ArrayResize(macroLows,  6);
   int shCount = 0, slCount = 0;

   for(int i = lookback; i < scanBars - lookback && (shCount < 4 || slCount < 4); i++)
   {
      double h = iHigh(_Symbol, MacroStructTF, i);
      double l = iLow (_Symbol, MacroStructTF, i);

      bool isSH = true;
      for(int j = 1; j <= lookback; j++) {
         if(iHigh(_Symbol, MacroStructTF, i - j) >= h ||
            iHigh(_Symbol, MacroStructTF, i + j) >= h) { isSH = false; break; }
      }
      if(isSH && shCount < 4) macroHighs[shCount++] = h;

      bool isSL = true;
      for(int j = 1; j <= lookback; j++) {
         if(iLow(_Symbol, MacroStructTF, i - j) <= l ||
            iLow(_Symbol, MacroStructTF, i + j) <= l) { isSL = false; break; }
      }
      if(isSL && slCount < 4) macroLows[slCount++] = l;
   }

   g_MacroSwingHigh1 = (shCount >= 1) ? macroHighs[0] : 0;
   g_MacroSwingHigh2 = (shCount >= 2) ? macroHighs[1] : 0;
   g_MacroSwingLow1  = (slCount >= 1) ? macroLows[0]  : 0;
   g_MacroSwingLow2  = (slCount >= 2) ? macroLows[1]  : 0;

   string prevMacro = g_MacroStructLabel;

   // --- Persistence decay for macro BOS/CHoCH ---
   datetime h4BarTime = iTime(_Symbol, MacroStructTF, 0);
   int macroPersistBars = 2;   // persist for 2 H4 bars (~8h)
   if(g_MacroBOSTime > 0 && h4BarTime - g_MacroBOSTime > macroPersistBars * PeriodSeconds(MacroStructTF))
      g_MacroBOSActive = false;
   if(g_MacroCHoCHTime > 0 && h4BarTime - g_MacroCHoCHTime > macroPersistBars * PeriodSeconds(MacroStructTF)) {
      g_MacroCHoCHActive = false;
      g_MacroCHoCHDir = 0;   // direction expires with the macro CHoCH event
   }

   bool freshMacroBOS   = false;
   bool freshMacroCHoCH = false;

   if(shCount >= 2 && slCount >= 2)
   {
      // 2-pip tolerance (was 1 pip)
      double tol = _Point * 20;
      bool HH = (g_MacroSwingHigh1 > g_MacroSwingHigh2 + tol);
      bool HL = (g_MacroSwingLow1  > g_MacroSwingLow2  + tol);
      bool LH = (g_MacroSwingHigh1 < g_MacroSwingHigh2 - tol);
      bool LL = (g_MacroSwingLow1  < g_MacroSwingLow2  - tol);

      if(HH && HL)      g_MacroStructLabel = "BULLISH";
      else if(LH && LL) g_MacroStructLabel = "BEARISH";
      else              g_MacroStructLabel = "RANGING";

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(g_MacroStructLabel == "BULLISH" && bid > g_MacroSwingHigh1) freshMacroBOS = true;
      if(g_MacroStructLabel == "BEARISH" && bid < g_MacroSwingLow1)  freshMacroBOS = true;

      // Classic CHoCH: pattern flip (with direction)
      if(prevMacro == "BULLISH" && g_MacroStructLabel == "BEARISH") { freshMacroCHoCH = true; g_MacroCHoCHDir = -1; }  // bearish reversal
      if(prevMacro == "BEARISH" && g_MacroStructLabel == "BULLISH") { freshMacroCHoCH = true; g_MacroCHoCHDir =  1; }  // bullish reversal

      // Price-break CHoCH on macro TF (with direction)
      if(prevMacro == "BEARISH" && shCount >= 1 && bid > g_MacroSwingHigh1)
         { freshMacroCHoCH = true; g_MacroCHoCHDir =  1; }   // bullish reversal
      if(prevMacro == "BULLISH" && slCount >= 1 && bid < g_MacroSwingLow1)
         { freshMacroCHoCH = true; g_MacroCHoCHDir = -1; }   // bearish reversal
   }

   // Apply persistence
   if(freshMacroBOS)   { g_MacroBOSTime   = h4BarTime; g_MacroBOSActive   = true; }
   if(freshMacroCHoCH) { g_MacroCHoCHTime = h4BarTime; g_MacroCHoCHActive = true; }
   g_MacroBOS   = g_MacroBOSActive;
   g_MacroCHoCH = g_MacroCHoCHActive;

   // === MTF ALIGNMENT ===
   // Both macro (H4) and intermediate (H1) structure agree on direction.
   // This is the highest-conviction structural state — price has momentum on two timeframes.
   bool h1Bull = (g_StructureLabel == "BULLISH");
   bool h1Bear = (g_StructureLabel == "BEARISH");
   bool h4Bull = (g_MacroStructLabel == "BULLISH");
   bool h4Bear = (g_MacroStructLabel == "BEARISH");
   g_MTFAligned = (h1Bull && h4Bull) || (h1Bear && h4Bear);

   // === BOLD BET FLAG ===
   // Strongest setup: MTF aligned + at least one SMC confirmation (FVG or OB)
   // Signal direction must match macro direction — checked later in TryEntry/CalcConfidence.
   bool hasSMC = (g_NearBullFVG || g_NearBearFVG || g_BullOB_High > 0 || g_BearOB_High > 0 ||
                  g_NearBullH4FVG || g_NearBearH4FVG || g_H4BullOB_High > 0 || g_H4BearOB_High > 0);
   bool hasBOS = (g_BOS || g_MacroBOS);  // recent break of structure on either TF
   g_BoldBet = g_MTFAligned && (hasSMC || hasBOS);

   Print("MACRO STRUCT: ", g_MacroStructLabel,
         " H1:",     g_StructureLabel,
         " MTF:",    (g_MTFAligned ? "ALIGNED" : "diverged"),
         " BoldBet:", (g_BoldBet ? "YES" : "no"),
         " MacroBOS:", g_MacroBOS, " MacroCHoCH:", g_MacroCHoCH,
         " CHoCHDir:", (g_MacroCHoCHDir > 0 ? "Bull" : (g_MacroCHoCHDir < 0 ? "Bear" : "none")),
         " MacroSH=", DoubleToString(g_MacroSwingHigh1,5),
         " MacroSL=", DoubleToString(g_MacroSwingLow1,5));
}

//+------------------------------------------------------------------+
//| DRAW MACRO STRUCTURE LEVELS ON CHART                             |
//| Draws horizontal lines at the most recent macro swing high/low   |
//| so the trader can see the structural map at a glance.            |
//+------------------------------------------------------------------+
void DrawMacroStructureLevels()
{
   string shName = "HABOT_MACRO_SH";
   string slName = "HABOT_MACRO_SL";

   // Macro Swing High — drawn as a dashed red horizontal line
   if(g_MacroSwingHigh1 > 0) {
      if(ObjectFind(0, shName) < 0)
         ObjectCreate(0, shName, OBJ_HLINE, 0, 0, g_MacroSwingHigh1);
      ObjectSetDouble (0, shName, OBJPROP_PRICE,     g_MacroSwingHigh1);
      ObjectSetInteger(0, shName, OBJPROP_COLOR,     clrTomato);
      ObjectSetInteger(0, shName, OBJPROP_STYLE,     STYLE_DASH);
      ObjectSetInteger(0, shName, OBJPROP_WIDTH,     2);
      ObjectSetString (0, shName, OBJPROP_TOOLTIP,   "Macro Swing High (" + EnumToString(MacroStructTF) + ") " + DoubleToString(g_MacroSwingHigh1, 5));
      ObjectSetInteger(0, shName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, shName, OBJPROP_BACK,      true);
   }

   // Macro Swing Low — drawn as a dashed lime horizontal line
   if(g_MacroSwingLow1 > 0) {
      if(ObjectFind(0, slName) < 0)
         ObjectCreate(0, slName, OBJ_HLINE, 0, 0, g_MacroSwingLow1);
      ObjectSetDouble (0, slName, OBJPROP_PRICE,     g_MacroSwingLow1);
      ObjectSetInteger(0, slName, OBJPROP_COLOR,     clrSpringGreen);
      ObjectSetInteger(0, slName, OBJPROP_STYLE,     STYLE_DASH);
      ObjectSetInteger(0, slName, OBJPROP_WIDTH,     2);
      ObjectSetString (0, slName, OBJPROP_TOOLTIP,   "Macro Swing Low (" + EnumToString(MacroStructTF) + ") " + DoubleToString(g_MacroSwingLow1, 5));
      ObjectSetInteger(0, slName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, slName, OBJPROP_BACK,      true);
   }

   ChartRedraw(0);
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
//| ORDER BLOCK DETECTION (H1) — v6.23 multi-OB + invalidation      |
//| Scans H1 bars for strong impulse moves (3+ consecutive bars,     |
//| 12+ pips).  The last opposing candle before the impulse is the   |
//| "order block" — a zone where institutional orders were placed.   |
//| v6.23: tracks up to 3 OBs per direction (nearest to price first)|
//|        marks mitigated when H1 candle CLOSES through the zone    |
//+------------------------------------------------------------------+
void DetectOrderBlocks()
{
   // --- Step 1: mark existing OBs as mitigated if price closed through them ---
   double lastClose = iClose(_Symbol, PERIOD_H1, 1);  // last completed H1 candle close
   for(int b = 0; b < g_BullOBCount; b++) {
      if(!g_BullOBs[b].mitigated && lastClose < g_BullOBs[b].low)
         g_BullOBs[b].mitigated = true;   // price closed below demand zone = invalidated
   }
   for(int b = 0; b < g_BearOBCount; b++) {
      if(!g_BearOBs[b].mitigated && lastClose > g_BearOBs[b].high)
         g_BearOBs[b].mitigated = true;   // price closed above supply zone = invalidated
   }

   // Compress mitigated entries
   int wIdx = 0;
   for(int b = 0; b < g_BullOBCount; b++) {
      if(!g_BullOBs[b].mitigated) { if(wIdx != b) g_BullOBs[wIdx] = g_BullOBs[b]; wIdx++; }
   }
   g_BullOBCount = wIdx;
   wIdx = 0;
   for(int b = 0; b < g_BearOBCount; b++) {
      if(!g_BearOBs[b].mitigated) { if(wIdx != b) g_BearOBs[wIdx] = g_BearOBs[b]; wIdx++; }
   }
   g_BearOBCount = wIdx;

   // --- Step 2: scan for new OBs (only if we have room) ---
   int    scanBars   = OBScanBars;
   int    impulseLen = 3;
   double minImpulse = 12.0;
   double minBody    = OBMinBodyPips * _Point * 10.0;

   // --- BULLISH ORDER BLOCKS (demand zones) ---
   for(int i = impulseLen; i < scanBars && g_BullOBCount < 3; i++)
   {
      bool allBull = true;
      for(int j = 0; j < impulseLen; j++) {
         int idx = i - j;
         if(idx < 1) { allBull = false; break; }
         if(iClose(_Symbol, PERIOD_H1, idx) <= iOpen(_Symbol, PERIOD_H1, idx)) {
            allBull = false; break;
         }
      }
      if(!allBull) continue;

      double impOpen  = iOpen (_Symbol, PERIOD_H1, i);
      double impClose = iClose(_Symbol, PERIOD_H1, i - impulseLen + 1);
      if((impClose - impOpen) / _Point / 10.0 < minImpulse) continue;

      int ob = i + 1;
      if(ob >= scanBars) continue;
      double obO = iOpen (_Symbol, PERIOD_H1, ob);
      double obC = iClose(_Symbol, PERIOD_H1, ob);
      if(obC >= obO) continue;
      if((obO - obC) < minBody) continue;

      // Check not already tracked
      datetime obTime = iTime(_Symbol, PERIOD_H1, ob);
      bool exists = false;
      for(int b = 0; b < g_BullOBCount; b++) {
         if(g_BullOBs[b].created == obTime) { exists = true; break; }
      }
      if(exists) continue;

      g_BullOBs[g_BullOBCount].high      = obO;
      g_BullOBs[g_BullOBCount].low       = obC;
      g_BullOBs[g_BullOBCount].created   = obTime;
      g_BullOBs[g_BullOBCount].mitigated = false;
      g_BullOBCount++;
   }

   // --- BEARISH ORDER BLOCKS (supply zones) ---
   for(int i = impulseLen; i < scanBars && g_BearOBCount < 3; i++)
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
      if((impOpen - impClose) / _Point / 10.0 < minImpulse) continue;

      int ob = i + 1;
      if(ob >= scanBars) continue;
      double obO = iOpen (_Symbol, PERIOD_H1, ob);
      double obC = iClose(_Symbol, PERIOD_H1, ob);
      if(obC <= obO) continue;
      if((obC - obO) < minBody) continue;

      datetime obTime = iTime(_Symbol, PERIOD_H1, ob);
      bool exists = false;
      for(int b = 0; b < g_BearOBCount; b++) {
         if(g_BearOBs[b].created == obTime) { exists = true; break; }
      }
      if(exists) continue;

      g_BearOBs[g_BearOBCount].high      = obC;
      g_BearOBs[g_BearOBCount].low       = obO;
      g_BearOBs[g_BearOBCount].created   = obTime;
      g_BearOBs[g_BearOBCount].mitigated = false;
      g_BearOBCount++;
   }

   // --- Step 3: set legacy aliases to the OB nearest current price ---
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_BullOB_High = 0; g_BullOB_Low = 0; g_BullOB_Time = 0;
   g_BearOB_High = 0; g_BearOB_Low = 0; g_BearOB_Time = 0;
   double bestBullDist = 99999, bestBearDist = 99999;

   for(int b = 0; b < g_BullOBCount; b++) {
      double mid = (g_BullOBs[b].high + g_BullOBs[b].low) / 2.0;
      double dist = MathAbs(bid - mid);
      if(dist < bestBullDist) {
         bestBullDist  = dist;
         g_BullOB_High = g_BullOBs[b].high;
         g_BullOB_Low  = g_BullOBs[b].low;
         g_BullOB_Time = g_BullOBs[b].created;
      }
   }
   for(int b = 0; b < g_BearOBCount; b++) {
      double mid = (g_BearOBs[b].high + g_BearOBs[b].low) / 2.0;
      double dist = MathAbs(bid - mid);
      if(dist < bestBearDist) {
         bestBearDist  = dist;
         g_BearOB_High = g_BearOBs[b].high;
         g_BearOB_Low  = g_BearOBs[b].low;
         g_BearOB_Time = g_BearOBs[b].created;
      }
   }
}

//+------------------------------------------------------------------+
//| FAIR VALUE GAP (FVG) DETECTION                                    |
//| Detects on FVGTimeframe (default H1) with FVGMinGapPips minimum. |
//| M15 gaps of 3-5 pips are noise; H1 gaps of 10+ pips represent    |
//| genuine institutional order flow imbalances worth trading into.   |
//| Bullish FVG: bar3.low > bar1.high (gap up = unfilled demand)     |
//| Bearish FVG: bar3.high < bar1.low (gap down = unfilled supply)   |
//+------------------------------------------------------------------+
void DetectFairValueGaps()
{
   // Mark existing FVGs as filled using CE (Consequent Encroachment = 50% midpoint)
   // ICT concept: FVG is truly "filled" only when price reaches the midpoint, not just the edge
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   for(int f = 0; f < g_FVGCount; f++) {
      if(g_FVGs[f].filled) continue;
      double ce = (g_FVGs[f].high + g_FVGs[f].low) / 2.0;  // Consequent Encroachment level
      // Bullish FVG filled when price drops to CE or below
      if(g_FVGs[f].dir == 1 && bid <= ce)
         g_FVGs[f].filled = true;
      // Bearish FVG filled when price rises to CE or above
      if(g_FVGs[f].dir == -1 && bid >= ce)
         g_FVGs[f].filled = true;
      // Expire FVGs: H1/H4 gaps persist longer than M15 gaps
      int expiryHours = (FVGTimeframe >= PERIOD_H4) ? 5*24 : (FVGTimeframe >= PERIOD_H1) ? 5*24 : 48;
      if(TimeCurrent() - g_FVGs[f].created > expiryHours * 3600)
         g_FVGs[f].filled = true;
   }

   // Determine scan depth: cover ~3 days of bars on the chosen timeframe
   int tfMins   = PeriodSeconds(FVGTimeframe) / 60;
   int scanBars = MathMin((3 * 24 * 60) / MathMax(tfMins, 1), 200);  // ~3 days, cap at 200 bars
   double minGap = FVGMinGapPips * _Point * 10;

   for(int i = 2; i < scanBars; i++)
   {
      // 3-candle pattern: bar i+1 (oldest), bar i (middle), bar i-1 (newest)
      double bar1_high = iHigh(_Symbol, FVGTimeframe, i + 1);
      double bar1_low  = iLow (_Symbol, FVGTimeframe, i + 1);
      double bar3_high = iHigh(_Symbol, FVGTimeframe, i - 1);
      double bar3_low  = iLow (_Symbol, FVGTimeframe, i - 1);

      // Bullish FVG: bar3's low > bar1's high (gap between them = unfilled demand)
      if(bar3_low > bar1_high + minGap) {
         double gapHigh = bar3_low;
         double gapLow  = bar1_high;
         datetime gapTime = iTime(_Symbol, FVGTimeframe, i);
         if(!FVGExists(gapHigh, gapLow, 1))
            AddFVG(gapHigh, gapLow, 1, gapTime);
      }

      // Bearish FVG: bar3's high < bar1's low (gap between them = unfilled supply)
      if(bar3_high < bar1_low - minGap) {
         double gapHigh = bar1_low;
         double gapLow  = bar3_high;
         datetime gapTime = iTime(_Symbol, FVGTimeframe, i);
         if(!FVGExists(gapHigh, gapLow, -1))
            AddFVG(gapHigh, gapLow, -1, gapTime);
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
   g_FVGs[g_FVGCount].tf      = FVGTimeframe;
   g_FVGCount++;
}

//+------------------------------------------------------------------+
//| DRAW FVG ZONES ON CHART as semi-transparent rectangles           |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Draw Order Block (supply/demand) zones as chart rectangles        |
//+------------------------------------------------------------------+
void DrawOBZones()
{
   // Remove stale OB rectangles
   for(int i = ObjectsTotal(0, 0) - 1; i >= 0; i--) {
      string name = ObjectName(0, i, 0);
      if(StringFind(name, "HABOT_OB_") == 0)
         ObjectDelete(0, name);
   }

   datetime tEnd = TimeCurrent() + 3600 * 4;   // extend 4h to the right

   // --- Demand zone (Bull OB) — green ---
   if(g_BullOB_High > 0 && g_BullOB_Time > 0) {
      string name = "HABOT_OB_BULL";
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, g_BullOB_Time, g_BullOB_High, tEnd, g_BullOB_Low);
      else {
         ObjectSetInteger(0, name, OBJPROP_TIME,  0, g_BullOB_Time);
         ObjectSetDouble (0, name, OBJPROP_PRICE, 0, g_BullOB_High);
         ObjectSetInteger(0, name, OBJPROP_TIME,  1, tEnd);
         ObjectSetDouble (0, name, OBJPROP_PRICE, 1, g_BullOB_Low);
      }
      ObjectSetInteger(0, name, OBJPROP_COLOR,     clrLimeGreen);
      ObjectSetInteger(0, name, OBJPROP_STYLE,     STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,     1);
      ObjectSetInteger(0, name, OBJPROP_FILL,      true);
      ObjectSetInteger(0, name, OBJPROP_BACK,      true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
      ObjectSetString (0, name, OBJPROP_TEXT,      "Demand Zone (Bull OB)");
   }

   // --- Supply zone (Bear OB) — red ---
   if(g_BearOB_High > 0 && g_BearOB_Time > 0) {
      string name = "HABOT_OB_BEAR";
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, g_BearOB_Time, g_BearOB_High, tEnd, g_BearOB_Low);
      else {
         ObjectSetInteger(0, name, OBJPROP_TIME,  0, g_BearOB_Time);
         ObjectSetDouble (0, name, OBJPROP_PRICE, 0, g_BearOB_High);
         ObjectSetInteger(0, name, OBJPROP_TIME,  1, tEnd);
         ObjectSetDouble (0, name, OBJPROP_PRICE, 1, g_BearOB_Low);
      }
      ObjectSetInteger(0, name, OBJPROP_COLOR,     clrCrimson);
      ObjectSetInteger(0, name, OBJPROP_STYLE,     STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,     1);
      ObjectSetInteger(0, name, OBJPROP_FILL,      true);
      ObjectSetInteger(0, name, OBJPROP_BACK,      true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
      ObjectSetString (0, name, OBJPROP_TEXT,      "Supply Zone (Bear OB)");
   }
}

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
//| H4 ORDER BLOCK DETECTION                                         |
//| Detects major institutional demand/supply zones on H4.           |
//| H4 OBs represent multi-day price memory — the strongest zones.  |
//| Demand zone = bearish H4 candle just before a bullish impulse.   |
//| Supply zone = bullish H4 candle just before a bearish impulse.   |
//+------------------------------------------------------------------+
void DetectH4OrderBlocks()
{
   g_H4BullOB_High = 0;  g_H4BullOB_Low = 0;  g_H4BullOB_Time = 0;
   g_H4BearOB_High = 0;  g_H4BearOB_Low = 0;  g_H4BearOB_Time = 0;
   g_NearH4BullOB  = false;
   g_NearH4BearOB  = false;

   int    scanBars   = H4OBScanBars;
   int    impulseLen = 2;              // 2 H4 bars = 8-hour move
   double minImpulse = 20.0;          // min 20-pip impulse on H4
   double minBody    = 15.0 * _Point * 10.0;  // min 15-pip OB body
   double proxPips   = 15.0 * _Point * 10.0;  // "near" = within 15 pips
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- BULLISH ORDER BLOCK: bearish H4 candle just before bullish impulse ---
   for(int i = impulseLen; i < scanBars; i++)
   {
      bool allBull = true;
      for(int j = 0; j < impulseLen; j++) {
         int idx = i - j;
         if(idx < 1) { allBull = false; break; }
         if(iClose(_Symbol, PERIOD_H4, idx) <= iOpen(_Symbol, PERIOD_H4, idx)) {
            allBull = false; break;
         }
      }
      if(!allBull) continue;
      double impOpen  = iOpen (_Symbol, PERIOD_H4, i);
      double impClose = iClose(_Symbol, PERIOD_H4, i - impulseLen + 1);
      if((impClose - impOpen) / _Point / 10.0 < minImpulse) continue;
      int ob = i + 1;
      if(ob >= scanBars) continue;
      double obO = iOpen (_Symbol, PERIOD_H4, ob);
      double obC = iClose(_Symbol, PERIOD_H4, ob);
      if(obC >= obO) continue;
      if((obO - obC) < minBody) continue;
      g_H4BullOB_High = obO;
      g_H4BullOB_Low  = obC;
      g_H4BullOB_Time = iTime(_Symbol, PERIOD_H4, ob);
      break;
   }

   // --- BEARISH ORDER BLOCK: bullish H4 candle just before bearish impulse ---
   for(int i = impulseLen; i < scanBars; i++)
   {
      bool allBear = true;
      for(int j = 0; j < impulseLen; j++) {
         int idx = i - j;
         if(idx < 1) { allBear = false; break; }
         if(iClose(_Symbol, PERIOD_H4, idx) >= iOpen(_Symbol, PERIOD_H4, idx)) {
            allBear = false; break;
         }
      }
      if(!allBear) continue;
      double impOpen  = iOpen (_Symbol, PERIOD_H4, i);
      double impClose = iClose(_Symbol, PERIOD_H4, i - impulseLen + 1);
      if((impOpen - impClose) / _Point / 10.0 < minImpulse) continue;
      int ob = i + 1;
      if(ob >= scanBars) continue;
      double obO = iOpen (_Symbol, PERIOD_H4, ob);
      double obC = iClose(_Symbol, PERIOD_H4, ob);
      if(obC <= obO) continue;
      if((obC - obO) < minBody) continue;
      g_H4BearOB_High = obC;
      g_H4BearOB_Low  = obO;
      g_H4BearOB_Time = iTime(_Symbol, PERIOD_H4, ob);
      break;
   }

   // Proximity: is price currently inside or touching an H4 OB zone?
   if(g_H4BullOB_High > 0)
      g_NearH4BullOB = (bid >= g_H4BullOB_Low - proxPips && bid <= g_H4BullOB_High + proxPips);
   if(g_H4BearOB_High > 0)
      g_NearH4BearOB = (bid >= g_H4BearOB_Low - proxPips && bid <= g_H4BearOB_High + proxPips);
}

//+------------------------------------------------------------------+
//| H4 FAIR VALUE GAP DETECTION                                      |
//| Detects major imbalance zones on H4: 3-candle gap structure.    |
//| H4 FVGs = unfilled institutional orders spanning multi-day moves.|
//| Bullish H4 FVG: bar3.low > bar1.high (gap up = macro demand).   |
//| Bearish H4 FVG: bar3.high < bar1.low (gap down = macro supply). |
//+------------------------------------------------------------------+
void DetectH4FairValueGaps()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Mark filled using CE (Consequent Encroachment = 50% midpoint) / expired
   for(int f = 0; f < g_H4FVGCount; f++) {
      if(g_H4FVGs[f].filled) continue;
      double ce = (g_H4FVGs[f].high + g_H4FVGs[f].low) / 2.0;
      if(g_H4FVGs[f].dir == 1  && bid <= ce)
         g_H4FVGs[f].filled = true;
      if(g_H4FVGs[f].dir == -1 && bid >= ce)
         g_H4FVGs[f].filled = true;
      // H4 FVGs expire after 14 calendar days
      if(TimeCurrent() - g_H4FVGs[f].created > 14 * 24 * 3600)
         g_H4FVGs[f].filled = true;
   }

   // Scan ~10 trading days on H4 (60 bars)
   int    scanBars = MathMin((10 * 24 * 60) / 240, 200);
   double minGap   = H4FVGMinGapPips * _Point * 10;
   double tol      = 2.0 * _Point * 10;

   for(int i = 2; i < scanBars; i++)
   {
      double bar1_high = iHigh(_Symbol, PERIOD_H4, i + 1);
      double bar1_low  = iLow (_Symbol, PERIOD_H4, i + 1);
      double bar3_high = iHigh(_Symbol, PERIOD_H4, i - 1);
      double bar3_low  = iLow (_Symbol, PERIOD_H4, i - 1);

      // Bullish H4 FVG
      if(bar3_low > bar1_high + minGap) {
         double   gapHigh = bar3_low;
         double   gapLow  = bar1_high;
         datetime gapTime = iTime(_Symbol, PERIOD_H4, i);
         bool exists = false;
         for(int f = 0; f < g_H4FVGCount; f++) {
            if(g_H4FVGs[f].dir == 1 &&
               MathAbs(g_H4FVGs[f].high - gapHigh) < tol &&
               MathAbs(g_H4FVGs[f].low  - gapLow)  < tol) { exists = true; break; }
         }
         if(!exists) {
            if(g_H4FVGCount >= ArraySize(g_H4FVGs)) ArrayResize(g_H4FVGs, g_H4FVGCount + 10);
            g_H4FVGs[g_H4FVGCount].high    = gapHigh;
            g_H4FVGs[g_H4FVGCount].low     = gapLow;
            g_H4FVGs[g_H4FVGCount].dir     = 1;
            g_H4FVGs[g_H4FVGCount].created = gapTime;
            g_H4FVGs[g_H4FVGCount].filled  = false;
            g_H4FVGs[g_H4FVGCount].tf      = PERIOD_H4;
            g_H4FVGCount++;
         }
      }

      // Bearish H4 FVG
      if(bar3_high < bar1_low - minGap) {
         double   gapHigh = bar1_low;
         double   gapLow  = bar3_high;
         datetime gapTime = iTime(_Symbol, PERIOD_H4, i);
         bool exists = false;
         for(int f = 0; f < g_H4FVGCount; f++) {
            if(g_H4FVGs[f].dir == -1 &&
               MathAbs(g_H4FVGs[f].high - gapHigh) < tol &&
               MathAbs(g_H4FVGs[f].low  - gapLow)  < tol) { exists = true; break; }
         }
         if(!exists) {
            if(g_H4FVGCount >= ArraySize(g_H4FVGs)) ArrayResize(g_H4FVGs, g_H4FVGCount + 10);
            g_H4FVGs[g_H4FVGCount].high    = gapHigh;
            g_H4FVGs[g_H4FVGCount].low     = gapLow;
            g_H4FVGs[g_H4FVGCount].dir     = -1;
            g_H4FVGs[g_H4FVGCount].created = gapTime;
            g_H4FVGs[g_H4FVGCount].filled  = false;
            g_H4FVGs[g_H4FVGCount].tf      = PERIOD_H4;
            g_H4FVGCount++;
         }
      }
   }

   // Compress filled entries
   int writeIdx = 0;
   for(int f = 0; f < g_H4FVGCount; f++) {
      if(!g_H4FVGs[f].filled) {
         if(writeIdx != f) g_H4FVGs[writeIdx] = g_H4FVGs[f];
         writeIdx++;
      }
   }
   g_H4FVGCount = writeIdx;

   // Proximity check
   g_NearBullH4FVG    = false;
   g_NearBearH4FVG    = false;
   g_NearestH4FVGHigh = 0;
   g_NearestH4FVGLow  = 0;
   g_NearestH4FVGDir  = 0;
   double nearestDist = 99999;
   double proxPips    = 15.0 * _Point * 10;   // 15-pip proximity for H4 zones

   for(int f = 0; f < g_H4FVGCount; f++) {
      double mid    = (g_H4FVGs[f].high + g_H4FVGs[f].low) / 2.0;
      double dist   = MathAbs(bid - mid);
      bool   inside = (bid >= g_H4FVGs[f].low - proxPips && bid <= g_H4FVGs[f].high + proxPips);
      if(inside && dist < nearestDist) {
         nearestDist        = dist;
         g_NearestH4FVGHigh = g_H4FVGs[f].high;
         g_NearestH4FVGLow  = g_H4FVGs[f].low;
         g_NearestH4FVGDir  = g_H4FVGs[f].dir;
         if(g_H4FVGs[f].dir == 1)  g_NearBullH4FVG = true;
         if(g_H4FVGs[f].dir == -1) g_NearBearH4FVG = true;
      }
   }
}

//+------------------------------------------------------------------+
//| FVG OVERLAP DETECTION — H1 + H4 confluence                      |
//| When an unfilled H1 FVG zone overlaps an unfilled H4 FVG zone   |
//| in the same direction, it signals a very strong imbalance area   |
//| (institutional confluence across timeframes).                    |
//+------------------------------------------------------------------+
void DetectFVGOverlap()
{
   g_FVGOverlapBullish = false;
   g_FVGOverlapBearish = false;

   // Check every H1 FVG against every H4 FVG for zone overlap in same direction
   for(int h1 = 0; h1 < g_FVGCount; h1++) {
      if(g_FVGs[h1].filled) continue;
      for(int h4 = 0; h4 < g_H4FVGCount; h4++) {
         if(g_H4FVGs[h4].filled) continue;
         if(g_FVGs[h1].dir != g_H4FVGs[h4].dir) continue;

         // Two zones overlap if: one's low < other's high AND one's high > other's low
         bool overlaps = (g_FVGs[h1].low < g_H4FVGs[h4].high && g_FVGs[h1].high > g_H4FVGs[h4].low);
         if(!overlaps) continue;

         if(g_FVGs[h1].dir == 1)  g_FVGOverlapBullish = true;
         if(g_FVGs[h1].dir == -1) g_FVGOverlapBearish = true;

         // Once both are found, no need to keep checking
         if(g_FVGOverlapBullish && g_FVGOverlapBearish) return;
      }
   }
}

//+------------------------------------------------------------------+
//| DRAW H4 SMC ZONES on chart                                       |
//| H4 OBs = bold filled rectangles (ForestGreen / DarkRed).        |
//| H4 FVGs = filled rectangles (MediumBlue / DarkViolet).          |
//| Drawn behind price with thicker borders to distinguish from H1.  |
//+------------------------------------------------------------------+
void DrawH4SMCZones()
{
   // Remove old H4 OB zones
   for(int i = ObjectsTotal(0, 0) - 1; i >= 0; i--) {
      string oname = ObjectName(0, i, 0);
      if(StringFind(oname, "HABOT_H4OB_") == 0)
         ObjectDelete(0, oname);
   }

   datetime tEnd = TimeCurrent() + 3600 * 8;   // extend 8 hours right

   // --- H4 Demand Zone (Bull OB) ---
   if(g_H4BullOB_High > 0 && g_H4BullOB_Time > 0) {
      string name = "HABOT_H4OB_BULL";
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, g_H4BullOB_Time, g_H4BullOB_High, tEnd, g_H4BullOB_Low);
      else {
         ObjectSetInteger(0, name, OBJPROP_TIME,  0, g_H4BullOB_Time);
         ObjectSetDouble (0, name, OBJPROP_PRICE, 0, g_H4BullOB_High);
         ObjectSetInteger(0, name, OBJPROP_TIME,  1, tEnd);
         ObjectSetDouble (0, name, OBJPROP_PRICE, 1, g_H4BullOB_Low);
      }
      ObjectSetInteger(0, name, OBJPROP_COLOR,     clrForestGreen);
      ObjectSetInteger(0, name, OBJPROP_STYLE,     STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,     2);
      ObjectSetInteger(0, name, OBJPROP_FILL,      true);
      ObjectSetInteger(0, name, OBJPROP_BACK,      true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
      ObjectSetString (0, name, OBJPROP_TEXT,      "H4 Demand Zone (Bull OB)");
   }

   // --- H4 Supply Zone (Bear OB) ---
   if(g_H4BearOB_High > 0 && g_H4BearOB_Time > 0) {
      string name = "HABOT_H4OB_BEAR";
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, g_H4BearOB_Time, g_H4BearOB_High, tEnd, g_H4BearOB_Low);
      else {
         ObjectSetInteger(0, name, OBJPROP_TIME,  0, g_H4BearOB_Time);
         ObjectSetDouble (0, name, OBJPROP_PRICE, 0, g_H4BearOB_High);
         ObjectSetInteger(0, name, OBJPROP_TIME,  1, tEnd);
         ObjectSetDouble (0, name, OBJPROP_PRICE, 1, g_H4BearOB_Low);
      }
      ObjectSetInteger(0, name, OBJPROP_COLOR,     clrDarkRed);
      ObjectSetInteger(0, name, OBJPROP_STYLE,     STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,     2);
      ObjectSetInteger(0, name, OBJPROP_FILL,      true);
      ObjectSetInteger(0, name, OBJPROP_BACK,      true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
      ObjectSetString (0, name, OBJPROP_TEXT,      "H4 Supply Zone (Bear OB)");
   }

   // Remove old H4 FVG zones
   for(int i = ObjectsTotal(0, 0) - 1; i >= 0; i--) {
      string oname = ObjectName(0, i, 0);
      if(StringFind(oname, "HABOT_H4FVG_") == 0)
         ObjectDelete(0, oname);
   }

   // --- H4 FVG zones ---
   for(int f = 0; f < g_H4FVGCount; f++) {
      string   name = "HABOT_H4FVG_" + IntegerToString(f);
      datetime t1   = g_H4FVGs[f].created;
      datetime t2   = TimeCurrent() + 3600 * 2;
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, g_H4FVGs[f].high, t2, g_H4FVGs[f].low);
      else {
         ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
         ObjectSetDouble (0, name, OBJPROP_PRICE, 0, g_H4FVGs[f].high);
         ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
         ObjectSetDouble (0, name, OBJPROP_PRICE, 1, g_H4FVGs[f].low);
      }
      color h4fvgClr = (g_H4FVGs[f].dir == 1) ? clrMediumBlue : clrDarkViolet;
      ObjectSetInteger(0, name, OBJPROP_COLOR,     h4fvgClr);
      ObjectSetInteger(0, name, OBJPROP_STYLE,     STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,     2);
      ObjectSetInteger(0, name, OBJPROP_FILL,      true);
      ObjectSetInteger(0, name, OBJPROP_BACK,      true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
      ObjectSetString (0, name, OBJPROP_TEXT,      (g_H4FVGs[f].dir == 1 ? "H4 Bull FVG" : "H4 Bear FVG"));
   }

   ChartRedraw(0);
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
//| MURRAY MATH CHANNEL LEVELS                                       |
//| Computes 9 octave levels (0/8 through 8/8) from the H4 swing.   |
//| These act as natural support/resistance beyond intraday range.   |
//+------------------------------------------------------------------+
void ComputeMurrayLevels()
{
   if(!UseMurrayChannels) return;
   ArrayInitialize(g_Murray, 0);
   g_MurrayBase = 0;
   g_MurrayRange = 0;

   // Get H4 high/low over the last 32 bars (~5.3 days of H4 data)
   double h4High = 0, h4Low = 999999;
   double h4Highs[], h4Lows[];
   ArraySetAsSeries(h4Highs, true);
   ArraySetAsSeries(h4Lows, true);
   int copied = CopyHigh(_Symbol, PERIOD_H4, 0, 32, h4Highs);
   int copiedL = CopyLow(_Symbol, PERIOD_H4, 0, 32, h4Lows);
   if(copied < 16 || copiedL < 16) return;  // not enough data
   for(int i = 0; i < copied; i++)
      if(h4Highs[i] > h4High) h4High = h4Highs[i];
   for(int i = 0; i < copiedL; i++)
      if(h4Lows[i] < h4Low) h4Low = h4Lows[i];

   if(h4High <= h4Low || h4Low <= 0) return;

   // Murray Math: find the nearest power-of-2 fraction that contains the range
   double rawRange = h4High - h4Low;
   // Round range UP to a "Murray octave" — the smallest 2^n / 10^k that covers rawRange
   double murrayOctave = 0.00010;  // start small for forex
   while(murrayOctave < rawRange) murrayOctave *= 2.0;
   // Now murrayOctave >= rawRange

   // Base = floor of h4Low to nearest murrayOctave
   double base = MathFloor(h4Low / murrayOctave) * murrayOctave;
   // If base + murrayOctave < h4High, shift up
   if(base + murrayOctave < h4High)
      base = h4High - murrayOctave;

   g_MurrayBase  = base;
   g_MurrayRange = murrayOctave;

   // Compute 9 octave levels: 0/8, 1/8, 2/8, ... 8/8
   for(int i = 0; i <= 8; i++)
      g_Murray[i] = base + (murrayOctave * i) / 8.0;
}

//+------------------------------------------------------------------+
//| MULTI-DAY SUPPORT / RESISTANCE                                   |
//| Tracks: previous weekly H/L, rolling 3-day H/L                  |
//+------------------------------------------------------------------+
void ComputeMultiDaySR()
{
   // --- Previous completed week: W1[1] ---
   if(UseWeeklySR) {
      double wkH = iHigh(_Symbol, PERIOD_W1, 1);
      double wkL = iLow (_Symbol, PERIOD_W1, 1);
      if(wkH > 0 && wkL > 0) {
         g_PrevWeekHigh = wkH;
         g_PrevWeekLow  = wkL;
      }
      // --- Rolling 3-day H/L: D1[0], D1[1], D1[2] ---
      double dH[], dL[];
      ArraySetAsSeries(dH, true);
      ArraySetAsSeries(dL, true);
      int ch = CopyHigh(_Symbol, PERIOD_D1, 0, 3, dH);
      int cl = CopyLow (_Symbol, PERIOD_D1, 0, 3, dL);
      if(ch >= 3 && cl >= 3) {
         g_ThreeDayHigh = MathMax(dH[0], MathMax(dH[1], dH[2]));
         g_ThreeDayLow  = MathMin(dL[0], MathMin(dL[1], dL[2]));
      }
   }
}

//+------------------------------------------------------------------+
//| ZONE HARDNESS CLASSIFIER                                         |
//| Determines whether the current zone boundary (UPPER_THIRD for    |
//| buys, LOWER_THIRD for sells) is likely to HOLD ("HARD") or be   |
//| broken through ("SOFT"). If SOFT, the zone filter is relaxed.   |
//|                                                                  |
//| Factors that make a boundary SOFT:                               |
//|  • Price already broke multi-day S/R in trade direction          |
//|  • BOS or MacroBOS confirms structural break                    |
//|  • CHoCH direction aligned with trade direction                  |
//|  • Momentum elevated (ATR-based, HA consecutive >= 3)           |
//|  • Murray octave above/below is close (run room exists)          |
//| Factors that make a boundary HARD:                               |
//|  • Multiple multi-day S/R levels clustered ahead (resistance)    |
//|  • No structural break (range-bound)                             |
//|  • Low momentum / volume                                         |
//+------------------------------------------------------------------+
string ClassifyZoneHardness(int tradeDir, double price)
{
   int softScore = 0;

   // 1. Price vs multi-day S/R: if price already broke weekly high (buy) or low (sell)
   if(UseWeeklySR) {
      if(tradeDir == 1 && g_PrevWeekHigh > 0 && price > g_PrevWeekHigh)  softScore += 2;
      if(tradeDir == -1 && g_PrevWeekLow > 0 && price < g_PrevWeekLow)   softScore += 2;
      // Also check 3-day: already above 3-day high (buy) or below 3-day low (sell)
      if(tradeDir == 1 && g_ThreeDayHigh > 0 && price > g_ThreeDayHigh)  softScore += 1;
      if(tradeDir == -1 && g_ThreeDayLow > 0 && price < g_ThreeDayLow)   softScore += 1;
   }

   // 2. Structural breaks
   if(g_BOS) softScore += 1;
   if(g_MacroBOS) softScore += 2;

   // 3. CHoCH in trade direction
   if(g_CHoCH && g_CHoCHDir == tradeDir) softScore += 1;
   if(g_MacroCHoCH && g_MacroCHoCHDir == tradeDir) softScore += 1;

   // 4. Macro structure alignment
   if(tradeDir == 1 && g_MacroStructLabel == "BULLISH")  softScore += 1;
   if(tradeDir == -1 && g_MacroStructLabel == "BEARISH") softScore += 1;

   // 5. Momentum: HA consecutive >= 3 signals a trending move
   if(g_HAConsecCount >= 3) softScore += 1;

   // 6. Volume elevated (institutional participation)
   if(g_VolumeState == "HIGH" || g_VolumeState == "ABOVE_AVG") softScore += 1;

   // 7. Murray channel: check if there is room beyond current range boundary
   if(UseMurrayChannels && g_MurrayRange > 0) {
      double nextMurray = 0;
      for(int i = 0; i <= 8; i++) {
         if(g_Murray[i] <= 0) continue;
         if(tradeDir == 1 && g_Murray[i] > price && (nextMurray == 0 || g_Murray[i] < nextMurray))
            nextMurray = g_Murray[i];
         if(tradeDir == -1 && g_Murray[i] < price && (nextMurray == 0 || g_Murray[i] > nextMurray))
            nextMurray = g_Murray[i];
      }
      // If next Murray level is >= 8 pips away, there is room to run → SOFT
      if(nextMurray > 0 && MathAbs(nextMurray - price) >= 8.0 * _Point * 10)
         softScore += 1;
   }

   // 8. Fib extension exists beyond range → runway exists
   if(UseFibExtensions) {
      if(tradeDir == 1 && g_FibExt1272 > 0 && g_FibExt1272 > g_RangeHigh)  softScore += 1;
      if(tradeDir == -1 && g_FibExt1272L > 0 && g_FibExt1272L < g_RangeLow) softScore += 1;
   }

   // Penalise (reduce) for clustered resistance ahead
   int resistCount = 0;
   double lookAhead = 15.0 * _Point * 10;  // 15 pips ahead
   if(UseWeeklySR && tradeDir == 1) {
      if(g_PrevWeekHigh > price && g_PrevWeekHigh < price + lookAhead) resistCount++;
      if(g_ThreeDayHigh > price && g_ThreeDayHigh < price + lookAhead) resistCount++;
   }
   if(UseWeeklySR && tradeDir == -1) {
      if(g_PrevWeekLow < price && g_PrevWeekLow > price - lookAhead) resistCount++;
      if(g_ThreeDayLow < price && g_ThreeDayLow > price - lookAhead) resistCount++;
   }
   softScore -= resistCount;  // each clustered level subtracts 1

   // Decision: need softScore >= 3 to classify as SOFT
   return (softScore >= 3) ? "SOFT" : "HARD";
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

   // --- Fibonacci retracement levels ---
   // Use prev-day H/L as the Fib anchor when today's range is still too narrow
   // (happens during the early session — a 5-pip bar produces meaningless Fib levels).
   if(g_RangeHigh > 0 && g_RangeLow > 0) {
      double fibH = g_RangeHigh, fibL = g_RangeLow;
      double minRangePrice = MinRangePips * _Point * 10.0;
      if((fibH - fibL) < minRangePrice && g_PrevDayHigh > 0 && g_PrevDayLow > 0) {
         // Today's range is narrow — compute Fibs from yesterday's full day instead
         fibH = g_PrevDayHigh;
         fibL = g_PrevDayLow;
      }
      double span = fibH - fibL;
      g_Fib236 = fibH - 0.236 * span;
      g_Fib382 = fibH - 0.382 * span;
      g_Fib500 = fibH - 0.500 * span;   // = midpoint
      g_Fib618 = fibH - 0.618 * span;
      g_Fib764 = fibH - 0.764 * span;

      // --- Fib EXTENSIONS: levels beyond the range (for TP targeting) ---
      if(UseFibExtensions) {
         g_FibExt1272  = fibH + 0.272 * span;   // 127.2% above high (buy target)
         g_FibExt1618  = fibH + 0.618 * span;   // 161.8% above high (extended buy)
         g_FibExt1272L = fibL - 0.272 * span;   // 127.2% below low (sell target)
         g_FibExt1618L = fibL - 0.618 * span;   // 161.8% below low (extended sell)
      }
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
   // Check Fibonacci extension levels
   if(UseFibExtensions) {
      if(g_FibExt1272  > 0 && MathAbs(price - g_FibExt1272)  <= zone) return "Fib 127.2%";
      if(g_FibExt1618  > 0 && MathAbs(price - g_FibExt1618)  <= zone) return "Fib 161.8%";
      if(g_FibExt1272L > 0 && MathAbs(price - g_FibExt1272L) <= zone) return "Fib 127.2%L";
      if(g_FibExt1618L > 0 && MathAbs(price - g_FibExt1618L) <= zone) return "Fib 161.8%L";
   }
   // Check Murray Math octave levels
   if(UseMurrayChannels && g_MurrayRange > 0) {
      for(int mi = 0; mi <= 8; mi++) {
         if(g_Murray[mi] > 0 && MathAbs(price - g_Murray[mi]) <= zone)
            return "Murray " + IntegerToString(mi) + "/8";
      }
   }
   // Check multi-day S/R
   if(UseWeeklySR) {
      if(g_PrevWeekHigh > 0 && MathAbs(price - g_PrevWeekHigh) <= zone) return "Wk High";
      if(g_PrevWeekLow  > 0 && MathAbs(price - g_PrevWeekLow)  <= zone) return "Wk Low";
      if(g_ThreeDayHigh > 0 && MathAbs(price - g_ThreeDayHigh) <= zone) return "3D High";
      if(g_ThreeDayLow  > 0 && MathAbs(price - g_ThreeDayLow)  <= zone) return "3D Low";
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
   double prevConf = 0; // track delta per factor
   g_ConfBreakdown = ""; // reset breakdown

   // --- 1. HA PATTERN QUALITY (0-15) ---
   int consec = g_HAConsecCount;
   if(consec >= 5)      conf += 15.0;
   else if(consec >= 4) conf += 12.0;
   else if(consec >= 3) conf += 9.0;
   else if(consec >= 2) conf += 5.0;
   g_ConfBreakdown += "HA:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

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
   g_ConfBreakdown += " Sess:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- 3. ZONE POSITION (0-10) ---
   if(zone == "LOWER_THIRD" && tradeDir == 1)   conf += 10.0;  // buy from low
   else if(zone == "UPPER_THIRD" && tradeDir == -1)  conf += 10.0;  // sell from high
   else if(zone == "LOWER_THIRD" && tradeDir == -1)  conf += 3.0;   // sell from low (risky)
   else if(zone == "UPPER_THIRD" && tradeDir == 1)   conf += 3.0;   // buy from high (risky)
   else if(zone == "MID_ZONE")   conf += 1.0;   // mid = limited runway
   g_ConfBreakdown += " Zone:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- 4. CONFLUENCE — near a Fib/Pivot level, TYPE scores differently per direction ---
   // Support levels (S1, S2, Fib 61.8%, 76.4%) favour BUY; resist BUY headwind if selling from support
   // Resistance levels (R1, R2, Fib 23.6%, 38.2%) favour SELL; penalise BUY at resistance
   // PP and Fib 50% are neutral
   // STRUCTURE CONTEXT: BEARISH structure implies key supports have been broken (now act as resistance).
   //                    BULLISH structure implies key resistances are broken (now act as support).
   if(nearLevel != "") {
      bool isSupport    = (StringFind(nearLevel, "S1") >= 0 || StringFind(nearLevel, "S2") >= 0 ||
                           StringFind(nearLevel, "61.8") >= 0 || StringFind(nearLevel, "76.4") >= 0);
      bool isResistance = (StringFind(nearLevel, "R1") >= 0 || StringFind(nearLevel, "R2") >= 0 ||
                           StringFind(nearLevel, "23.6") >= 0 || StringFind(nearLevel, "38.2") >= 0);
      bool isNeutral    = (!isSupport && !isResistance);   // PP, Fib 50%

      bool supportIntact    = (g_StructureLabel != "BEARISH");  // BEARISH = support probably broken
      bool resistanceIntact = (g_StructureLabel != "BULLISH");  // BULLISH = resistance probably broken

      if(isNeutral) {
         conf += 6.0;   // mild boost for both directions
      } else if(isSupport) {
         if(tradeDir == 1)
            conf += supportIntact ? 12.0 : 3.0;   // intact support = great for buy; broken = weak
         else
            conf += supportIntact ? 2.0  : 8.0;   // broken support now acts as resistance = decent for sell
      } else {  // isResistance
         if(tradeDir == -1)
            conf += resistanceIntact ? 12.0 : 3.0; // intact resistance = great for sell; broken = weak
         else
            conf += resistanceIntact ? 2.0  : 8.0; // broken resistance now acts as support = decent for buy
      }
   }
   g_ConfBreakdown += " Cnfl:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- 5. BIAS ALIGNMENT (0-5, can go negative) ---
   if(tradeDir == 1  && g_TotalBias >= 2)   conf += 5.0;   // strong bull bias + buy
   else if(tradeDir == 1  && g_TotalBias >= 1)  conf += 3.0;
   else if(tradeDir == -1 && g_TotalBias <= -2) conf += 5.0;   // strong bear bias + sell
   else if(tradeDir == -1 && g_TotalBias <= -1) conf += 3.0;
   // Counter-trend penalty
   if(tradeDir == 1  && g_TotalBias <= -2) conf -= 5.0;
   if(tradeDir == -1 && g_TotalBias >= 2)  conf -= 5.0;
   g_ConfBreakdown += " Bias:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

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
   g_ConfBreakdown += " Room:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- 7. ATR VOLATILITY (0-10) ---
   double atrPips = (g_ATR > 0) ? (g_ATR / _Point / 10.0) : 10.0;
   if(atrPips >= 25.0)      conf += 10.0;  // very strong volatility
   else if(atrPips >= 15.0) conf += 7.0;
   else if(atrPips >= 10.0) conf += 5.0;
   else if(atrPips >= 7.0)  conf += 3.0;
   // < 7 = dead market, minimal confidence
   g_ConfBreakdown += " ATR:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- 8. SWING STRUCTURE (0-10) ---
   bool structAligned = false;
   if(UseSwingStructure) {
      if(g_StructureLabel == "BULLISH" && tradeDir == 1)  { conf += 5.0; structAligned = true; }
      if(g_StructureLabel == "BEARISH" && tradeDir == -1) { conf += 5.0; structAligned = true; }
      // Counter-structure penalty
      if(g_StructureLabel == "BULLISH" && tradeDir == -1)  conf -= 5.0;
      if(g_StructureLabel == "BEARISH" && tradeDir == 1)   conf -= 5.0;
      // BOS = strong continuation
      if(g_BOS && structAligned)   conf += 5.0;
      // CHoCH = reversal signal — direction-aware scoring:
      // Boost trades aligned with the reversal, penalise trades going with the dying trend
      if(g_CHoCH && g_CHoCHDir != 0) {
         if(g_CHoCHDir == tradeDir)  conf += 4.0;   // WITH reversal
         if(g_CHoCHDir == -tradeDir) conf -= 4.0;   // AGAINST reversal
      }
   }
   g_ConfBreakdown += " Struct:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

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
   g_ConfBreakdown += " Vol:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- 10. LIQUIDITY SWEEP (0-10) ---
   // Sweep = institutions hunted stops, then reversed. If sweep matches our
   // direction, this is the HIGHEST-EDGE setup pattern in smart money.
   if(UseLiquiditySweep && g_LiquiditySweep) {
      if(g_SweepDir == tradeDir)  conf += 10.0;  // aligned sweep = maximum edge
      else                         conf -= 3.0;   // sweep against us = danger
   }
   g_ConfBreakdown += " Sweep:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

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

      // Multi-OB cluster bonus: 2+ active OBs in trade direction = institutional stacking
      if(tradeDir == 1  && g_BullOBCount >= 2) conf += 3.0;
      if(tradeDir == -1 && g_BearOBCount >= 2) conf += 3.0;
   }
   g_ConfBreakdown += " OB:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

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
   g_ConfBreakdown += " FVG:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- 13. KEY HOUR BONUS (0-8) ---
   // Full-hour session boundaries where institutional order flow and volatility spikes
   // are statistically elevated. Award bonus scaled by proximity to the hour mark.
   //   Key hours (server time): 00 03 04 07 08 12 13 17 21
   double keyHourBonus = 0;
   if(KeyHourBonusEnabled) {
      // minutes elapsed into the current hour
      int minIntoHour = dt.min;
      // key hours where significant moves tend to start
      int keyHrs[] = {0, 3, 4, 7, 8, 12, 13, 17, 21};
      int nKey = ArraySize(keyHrs);
      int closestMinDist = 99;
      for(int ki = 0; ki < nKey; ki++) {
         int kh = keyHrs[ki];
         // Distance from start of a key hour: current hour == kh → offset forward
         if(dt.hour == kh)
            closestMinDist = MathMin(closestMinDist, minIntoHour);
         // Distance to start of a key hour: current hour + 1 == kh → offset backward
         if((dt.hour + 1) % 24 == kh)
            closestMinDist = MathMin(closestMinDist, 60 - minIntoHour);
      }
      if(closestMinDist <= 15)
         keyHourBonus = KeyHourBonusPts;              // within 15 min: full bonus
      else if(closestMinDist <= 30)
         keyHourBonus = KeyHourBonusPts * 0.5;        // within 30 min: half bonus
      conf += keyHourBonus;
   }
   g_ConfBreakdown += " KeyHr:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- 14. ASIAN SESSION PREV-DAY MOMENTUM ALIGNMENT (0-6) ---
   // During the Asian session, the last hour of the previous trading day often
   // acts as a directional hint — institutional carry-over before London resets flow.
   // Boost confidence when the signal aligns with that close-of-day direction.
   // Never penalises; only adds when in Asian session and prev-day dir is known.
   double asianMomBonus = 0;
   if(AsianPrevDayMomEnabled && g_PrevDayLastHourDir != 0) {
      MqlDateTime adt; TimeToStruct(TimeCurrent(), adt);
      bool inAsian = (adt.hour >= AsianStartHour && adt.hour < AsianEndHour);
      if(inAsian && tradeDir == g_PrevDayLastHourDir) {
         asianMomBonus = AsianMomentumBonusPts;
         conf += asianMomBonus;
      }
   }
   g_ConfBreakdown += " AsiMom:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- 15. MULTI-TIMEFRAME (MTF) STRUCTURE ALIGNMENT (0-12) ---
   // When both the macro (H4) and intermediate (H1) structure label agree with
   // the trade direction, the setup has strong institutional support on two timeframes.
   // This is the highest structural conviction state in the model.
   //   +8  : H4 and H1 both aligned with tradeDir (MTFAligned)
   //   +4  : Macro structure alone aligns (H1 may be RANGING)
   //   +4  : Bold-bet flag (MTF aligned + FVG or OB or BOS present)
   //   +0  : Counter-macro (no penalty — H1 is already penalised in Factor 8)
   //   CHoCH on macro TF = reversal signal — additional bonus if tradeDir matches new macro direction
   double mtfBonus = 0;
   bool macroAlignedWithTrade = (tradeDir == 1  && g_MacroStructLabel == "BULLISH") ||
                                 (tradeDir == -1 && g_MacroStructLabel == "BEARISH");
   if(UseMacroStructure) {
      if(g_MTFAligned && macroAlignedWithTrade) {
         mtfBonus += 8.0;   // highest conviction: both TFs agree
         if(g_BoldBet) mtfBonus += 4.0;   // + SMC confirmation on top
      } else if(macroAlignedWithTrade) {
         mtfBonus += 4.0;   // macro agrees but H1 is neutral/RANGING
      }
      // Macro BOS in trade direction = recent structural break confirming continuation
      if(g_MacroBOS && macroAlignedWithTrade) mtfBonus += 2.0;
      // Macro CHoCH = reversal signal on H4 — direction-aware scoring:
      // Boost trades aligned with the macro reversal, penalise trades going with the dying macro trend
      if(g_MacroCHoCH && g_MacroCHoCHDir != 0) {
         if(g_MacroCHoCHDir == tradeDir)  mtfBonus += 4.0;   // WITH macro reversal
         if(g_MacroCHoCHDir == -tradeDir) mtfBonus -= 4.0;   // AGAINST macro reversal
      }
      conf += mtfBonus;
   }
   g_ConfBreakdown += " MTF:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- FACTOR 16 — H4 FVG & Order Blocks (macro supply/demand confluences) ---
   // H4 zones represent multi-day institutional memory: the strongest SMC confirmation.
   // Being at an H4 demand/supply zone with MTF alignment = highest-conviction setup.
   // FVG + OB cluster at the same H4 level adds an extra "coin-cluster" bonus.
   double h4smcBonus = 0;
   if(UseH4SMC) {
      bool nearH4BullZone = g_NearBullH4FVG || g_NearH4BullOB;
      bool nearH4BearZone = g_NearBearH4FVG || g_NearH4BearOB;
      if(tradeDir == 1  && nearH4BullZone) {
         h4smcBonus += 10.0;
         if(g_NearBullH4FVG && g_NearH4BullOB) h4smcBonus += 4.0;  // FVG+OB cluster
      }
      if(tradeDir == -1 && nearH4BearZone) {
         h4smcBonus += 10.0;
         if(g_NearBearH4FVG && g_NearH4BearOB) h4smcBonus += 4.0;  // FVG+OB cluster
      }
      // Counter-zone: H4 supply sitting above a buy = real danger; penalise
      if(tradeDir == 1  && nearH4BearZone && !nearH4BullZone) h4smcBonus -= 5.0;
      if(tradeDir == -1 && nearH4BullZone && !nearH4BearZone) h4smcBonus -= 5.0;
      conf += h4smcBonus;
   }
   g_ConfBreakdown += " H4:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- FACTOR 17 — FVG H1+H4 OVERLAP CONFLUENCE (0-6) ---
   // When an unfilled H1 FVG overlaps an unfilled H4 FVG in the same direction,
   // both timeframes show the same institutional imbalance = highest conviction zone.
   if(UseFairValueGaps && UseH4SMC) {
      if(tradeDir == 1  && g_FVGOverlapBullish) conf += 6.0;
      if(tradeDir == -1 && g_FVGOverlapBearish) conf += 6.0;
   }
   g_ConfBreakdown += " FVGovlp:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- PENALTIES ---
   if(isSideways)  conf -= 8.0;
   if(isMeanRev)   conf -= 3.0;
   g_ConfBreakdown += " Pen:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

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
         " KeyHr:", (keyHourBonus > 0 ? "+" + DoubleToString(keyHourBonus,1) : "0"), "@", dt.hour, ":", dt.min,
         " AsianMom:", (asianMomBonus > 0 ? "+" + DoubleToString(asianMomBonus,1) : "0"),
         " PrevDayDir:", g_PrevDayLastHourDir,
         " MTF:", (g_MTFAligned ? "ALIGNED" : "div"), " +", DoubleToString(mtfBonus,1),
         " Macro:", g_MacroStructLabel, (g_MacroBOS ? " MacroBOS" : ""), (g_MacroCHoCH ? " MacroCHoCH" : ""),
         " BoldBet:", g_BoldBet,
         " Zone:", zone,
         " Cnfl:", (nearLevel == "" ? "none" : nearLevel+lvlType),
         " Struct:", g_StructureLabel, (g_BOS ? " BOS" : ""), (g_CHoCH ? " CHoCH" : ""),
         " Vol:", g_VolumeState, volDirStr, (g_VolDivergence ? " DIV" : ""),
         " Sweep:", (g_LiquiditySweep ? g_SweepLevel : "none"),
         " OB:", (nearOB ? "YES" : "no"),
         " FVG:", (nearFVG ? (g_NearestFVGDir == 1 ? "BULL" : "BEAR") : "none"),
         " H4SMC:", (UseH4SMC ? (h4smcBonus != 0 ? DoubleToString(h4smcBonus,1) : "0") : "off"),
         " H4FVG:", (g_NearBullH4FVG ? "BULL" : g_NearBearH4FVG ? "BEAR" : "none"),
         " H4OB:",  (g_NearH4BullOB  ? "BULL" : g_NearH4BearOB  ? "BEAR" : "none"),
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

   // Collect all known levels — increased capacity for Murray + multi-day + Fib ext
   double levels[];
   int    cnt = 0;
   ArrayResize(levels, 100);

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
   // Fib EXTENSIONS (beyond range — for trending markets)
   if(UseFibExtensions) {
      if(g_FibExt1272 > 0)  levels[cnt++] = g_FibExt1272;
      if(g_FibExt1618 > 0)  levels[cnt++] = g_FibExt1618;
      if(g_FibExt1272L > 0) levels[cnt++] = g_FibExt1272L;
      if(g_FibExt1618L > 0) levels[cnt++] = g_FibExt1618L;
   }
   // Murray Math octave levels (channel S/R beyond intraday range)
   if(UseMurrayChannels && g_MurrayRange > 0) {
      for(int m = 0; m <= 8; m++) {
         if(g_Murray[m] > 0) levels[cnt++] = g_Murray[m];
      }
   }
   // Multi-day S/R (weekly, 3-day)
   if(UseWeeklySR) {
      if(g_PrevWeekHigh > 0) levels[cnt++] = g_PrevWeekHigh;
      if(g_PrevWeekLow  > 0) levels[cnt++] = g_PrevWeekLow;
      if(g_ThreeDayHigh > 0) levels[cnt++] = g_ThreeDayHigh;
      if(g_ThreeDayLow  > 0) levels[cnt++] = g_ThreeDayLow;
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
   // Previous day (additional reference for TP)
   if(g_PrevDayHigh > 0) levels[cnt++] = g_PrevDayHigh;
   if(g_PrevDayLow  > 0) levels[cnt++] = g_PrevDayLow;
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
//+------------------------------------------------------------------+
//| BOLLINGER GATE OVERRIDE CHECK                                    |
//| Called when Bollinger midline test fails. Scores 10 confluence  |
//| factors; if score >= BollOverrideMinScore the gate is bypassed. |
//| Rationale: when a key level has genuinely broken with structure, |
//| volume, timing and macro backdrop the Boll midline is lagging   |
//| behind rapidly moving price — blocking here is a false negative. |
//| Position sizing still uses normal SL/TP — no extra risk taken.  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| MACRO TREND RIDE DETECTION                                       |
//| Fires when H4 BOS is confirmed and HA candles align in the BOS  |
//| direction with sufficient structural confluence (ZoneContextScore|
//| 0-12). Used to capture 80-120+ pip intraday trend moves that    |
//| follow a confirmed macro structural break.                       |
//| Sets g_MacroTrendRide / g_MacroTrendDir / g_MacroTrendScore.    |
//+------------------------------------------------------------------+
void CheckMacroTrendRide()
{
   g_MacroTrendRide  = false;
   g_MacroTrendDir   = 0;
   g_MacroTrendScore = 0;

   if(!MacroTrendRideEnabled || !UseMacroStructure) return;
   if(!g_MacroBOS) return;
   if(g_MacroStructLabel == "RANGING") return;

   int bosDir = (g_MacroStructLabel == "BULLISH") ? 1 : -1;

   // Do not fire if regular HA signal is pointing the OPPOSITE direction
   // (that would mean HA state machine and macro disagree — let state machine resolve first)
   if(g_Signal == "BUY INCOMING"  && bosDir == -1) return;
   if(g_Signal == "SELL INCOMING" && bosDir ==  1) return;

   // Asian session block
   // Asia often makes a small counter-BOS fake move before the real London continuation starts
   if(MacroTrendAsianBlock) {
      MqlDateTime mdt; TimeToStruct(TimeCurrent(), mdt);
      if(mdt.hour >= AsianStartHour && mdt.hour < AsianEndHour) return;
   }

   // HA confirmation: the last 2 closed bars must both be in the BOS direction
   double haO1, haH1, haL1, haC1;
   double haO2, haH2, haL2, haC2;
   CalcHA(1, haO1, haH1, haL1, haC1);
   CalcHA(2, haO2, haH2, haL2, haC2);
   bool ha1ok = (bosDir == 1) ? (haC1 > haO1) : (haC1 < haO1);
   bool ha2ok = (bosDir == 1) ? (haC2 > haO2) : (haC2 < haO2);
   if(!ha1ok || !ha2ok) return;

   // Bar-1 must be a clean candle: bottomless/bull or topless/bear (no shadow in direction)
   // Filter out dojis and mixed candles — only ride obvious momentum
   bool cleanBar = (bosDir == 1) ? IsBottomless(1) : IsTopless(1);
   if(!cleanBar) return;

   // ZoneContextScore confirms structural strength (MTF, volume, liquidity, OB, etc.)
   int score = ZoneContextScore(bosDir);
   if(score < MacroTrendMinScore) return;

   // Safety: refuse entry if BOTH indicators diverge (same rule as regular entries)
   if(DivergenceCautionEnabled) {
      bool mtfDiv = !g_MTFAligned;
      bool volDiv = (UseVolumeAnalysis && g_VolDivergence);
      if(mtfDiv && volDiv) {
         Print("[MACRO TREND RIDE] Blocked: MTF+Vol both diverged (score=", score, "/14)");
         return;
      }
   }

   g_MacroTrendRide  = true;
   g_MacroTrendDir   = bosDir;
   g_MacroTrendScore = score;
   Print("[MACRO TREND RIDE] Armed: ", g_MacroStructLabel, " BOS",
         " HAConsec=", g_HAConsecCount,
         " Score=", score, "/14",
         " Vol=", g_VolumeState,
         " MTF=", (g_MTFAligned ? "ALIGNED" : "diverged"),
         " dir=", (bosDir == 1 ? "BULL" : "BEAR"));
}

//+------------------------------------------------------------------+
//| LEVEL BREAK DETECTION                                            |
//| Returns how many M15 bars ago price last broke through a key    |
//| structural level in 'tradeDir'. Sets g_LevelBreakLabel.         |
//| Checked levels: S1/S2/R1/R2, SwingH/L (H1), MacroSwingH/L (H4).|
//| Used to gauge trend strength when MaxConsecCandles is exceeded.  |
//+------------------------------------------------------------------+
int CheckLevelBreakBars(int tradeDir)
{
   g_LevelBreakLabel = "";
   int    scanBack   = MathMax(TrendBoldHardCap + 2, MaxConsecCandles * 3 + 2);
   double tol        = 3.0 * _Point * 10;   // 3-pip tolerance for level cross

   // Collect candidate levels with labels
   double lvlPrice[10];
   string lvlName [10];
   int    nLvl = 0;

   if(tradeDir == 1) {
      // BUY: look for break above resistance levels
      if(g_PivotR1      > 0) { lvlPrice[nLvl] = g_PivotR1;           lvlName[nLvl++] = "R1"; }
      if(g_PivotR2      > 0) { lvlPrice[nLvl] = g_PivotR2;           lvlName[nLvl++] = "R2"; }
      if(g_SwingHigh1   > 0) { lvlPrice[nLvl] = g_SwingHigh1;        lvlName[nLvl++] = "H1-SwingH"; }
      if(g_SwingHigh2   > 0) { lvlPrice[nLvl] = g_SwingHigh2;        lvlName[nLvl++] = "H1-SwingH2"; }
      if(g_MacroSwingHigh1 > 0) { lvlPrice[nLvl] = g_MacroSwingHigh1; lvlName[nLvl++] = "H4-SwingH"; }
      if(g_CIHigh       > 0) { lvlPrice[nLvl] = g_CIHigh;            lvlName[nLvl++] = "CI-High"; }
   } else {
      // SELL: look for break below support levels
      if(g_PivotS1      > 0) { lvlPrice[nLvl] = g_PivotS1;           lvlName[nLvl++] = "S1"; }
      if(g_PivotS2      > 0) { lvlPrice[nLvl] = g_PivotS2;           lvlName[nLvl++] = "S2"; }
      if(g_SwingLow1    > 0) { lvlPrice[nLvl] = g_SwingLow1;         lvlName[nLvl++] = "H1-SwingL"; }
      if(g_SwingLow2    > 0) { lvlPrice[nLvl] = g_SwingLow2;         lvlName[nLvl++] = "H1-SwingL2"; }
      if(g_MacroSwingLow1 > 0)  { lvlPrice[nLvl] = g_MacroSwingLow1;  lvlName[nLvl++] = "H4-SwingL"; }
      if(g_CILow        > 0) { lvlPrice[nLvl] = g_CILow;             lvlName[nLvl++] = "CI-Low"; }
   }
   if(nLvl == 0) return 999;

   // Scan bars oldest-to-newest; return the most recent (smallest b) break found
   for(int b = 1; b <= scanBack; b++) {
      double closeB  = iClose(_Symbol, PERIOD_M15, b);
      double closeB1 = iClose(_Symbol, PERIOD_M15, b + 1);   // bar before b
      for(int li = 0; li < nLvl; li++) {
         bool crossed = (tradeDir == 1)
                        ? (closeB > lvlPrice[li] + tol && closeB1 < lvlPrice[li] - tol)
                        : (closeB < lvlPrice[li] - tol && closeB1 > lvlPrice[li] + tol);
         if(crossed) {
            g_LevelBreakLabel = lvlName[li] + "@" + DoubleToString(lvlPrice[li], 5);
            return b;
         }
      }
   }
   return 999;
}

//+------------------------------------------------------------------+
//| ZONE CONTEXT SCORE                                               |
//| Evaluates structural confluence to decide whether a wrong-zone  |
//| trend trade should be allowed (CONTEXT_AWARE mode). Returns 0-14|
//| — higher = stronger evidence the trend should override the zone. |
//+------------------------------------------------------------------+
int ZoneContextScore(int tradeDir)
{
   int score = 0;

   // 1-2: Key level break recency (most powerful signal — price broke structure in trade dir)
   int brkBars = CheckLevelBreakBars(tradeDir);
   if(brkBars <= MaxConsecCandles * 2)    score += 2;   // recent: ≤ 2× MaxConsec bars
   else if(brkBars <= MaxConsecCandles * 4) score += 1; // moderate: ≤ 4× MaxConsec bars

   // 3-4: H4 macro structure (heaviest non-level weight)
   if(tradeDir ==  1 && g_MacroStructLabel == "BULLISH") score += 2;
   if(tradeDir == -1 && g_MacroStructLabel == "BEARISH") score += 2;

   // 5: H1 swing structure aligned
   if(tradeDir ==  1 && g_StructureLabel == "BULLISH") score++;
   if(tradeDir == -1 && g_StructureLabel == "BEARISH") score++;

   // 6: H1 BOS (recent short-term structural break)
   if(g_BOS) score++;

   // 7: Macro BOS on H4 (multi-day structural break = high-conviction trending move)
   if(g_MacroBOS) score++;

   // 8: Volume elevated (institutional participation confirms the move)
   if(g_VolumeState == "HIGH" || g_VolumeState == "ABOVE_AVG") score++;

   // 9: HA consecutive >= 3 (price is trending, not ranging)
   if(g_HAConsecCount >= 3) score++;

   // 10: MTF alignment (H4 + H1 both point the same way = fullest conviction)
   if(g_MTFAligned) score++;

   // 11: Liquidity sweep in trade direction (stop hunt confirms directional intent)
   if(g_LiquiditySweep && g_SweepDir == tradeDir) score++;

   // 12: Multi-day S/R break (price already beyond weekly or 3-day boundary = strong trend)
   double p = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(UseWeeklySR) {
      if(tradeDir == 1 && g_PrevWeekHigh > 0 && p > g_PrevWeekHigh) score++;
      if(tradeDir == -1 && g_PrevWeekLow > 0 && p < g_PrevWeekLow)  score++;
   }

   // 13: Murray channel room (next octave level >= 8 pips from price → run room)
   if(UseMurrayChannels && g_MurrayRange > 0) {
      for(int mi = 0; mi <= 8; mi++) {
         if(g_Murray[mi] <= 0) continue;
         double md = (tradeDir == 1) ? (g_Murray[mi] - p) : (p - g_Murray[mi]);
         if(md >= 8.0 * _Point * 10) { score++; break; }
      }
   }

   return score;   // max 14 (was 12, +2 for multi-day/Murray)
}

//+------------------------------------------------------------------+
//| FIB LEVEL PRICE LOOKUP                                           |
//| Returns the price of a named Fib/Pivot level. Returns 0 if the  |
//| name is not recognised or data is not yet available.             |
//+------------------------------------------------------------------+
double FibLevelPrice(string levelName)
{
   if(levelName == "Pivot PP")  return g_PivotPP;
   if(levelName == "Pivot R1")  return g_PivotR1;
   if(levelName == "Pivot S1")  return g_PivotS1;
   if(levelName == "Pivot R2")  return g_PivotR2;
   if(levelName == "Pivot S2")  return g_PivotS2;
   if(levelName == "Fib 23.6%") return g_Fib236;
   if(levelName == "Fib 38.2%") return g_Fib382;
   if(levelName == "Fib 50.0%") return g_Fib500;
   if(levelName == "Fib 61.8%") return g_Fib618;
   if(levelName == "Fib 76.4%") return g_Fib764;
   // Fib extensions
   if(levelName == "Fib 127.2%")  return g_FibExt1272;
   if(levelName == "Fib 161.8%")  return g_FibExt1618;
   if(levelName == "Fib 127.2%L") return g_FibExt1272L;
   if(levelName == "Fib 161.8%L") return g_FibExt1618L;
   // Multi-day S/R
   if(levelName == "Wk High")  return g_PrevWeekHigh;
   if(levelName == "Wk Low")   return g_PrevWeekLow;
   if(levelName == "3D High")  return g_ThreeDayHigh;
   if(levelName == "3D Low")   return g_ThreeDayLow;
   // Murray Math
   if(StringFind(levelName, "Murray ") == 0) {
      string numStr = StringSubstr(levelName, 7, 1);
      int idx = (int)StringToInteger(numStr);
      if(idx >= 0 && idx <= 8 && g_Murray[idx] > 0) return g_Murray[idx];
   }
   return 0;
}

//+------------------------------------------------------------------+
//| FIB/PIVOT APPROACHING LEVEL                                      |
//| Finds the closest Fib/Pivot level that is AHEAD of 'price' in   |
//| the 'tradeDir' direction and within 'pipRadius' pips.            |
//|  BUY  (tradeDir=+1): looks for resistance ABOVE price.          |
//|  SELL (tradeDir=-1): looks for support BELOW price.             |
//| Returns the level name, or "" if none found within range.       |
//+------------------------------------------------------------------+
string FibApproachingLevel(double price, int tradeDir, double pipRadius)
{
   double r = pipRadius * _Point * 10.0;   // pips → price
   if(r <= 0 || price <= 0) return "";

   string lvlNames[12];
   double lvlPrices[12];
   int    cnt = 0;

   if(UseDailyPivot && g_PivotPP > 0) {
      lvlNames[cnt] = "Pivot PP"; lvlPrices[cnt++] = g_PivotPP;
      lvlNames[cnt] = "Pivot R1"; lvlPrices[cnt++] = g_PivotR1;
      lvlNames[cnt] = "Pivot S1"; lvlPrices[cnt++] = g_PivotS1;
      lvlNames[cnt] = "Pivot R2"; lvlPrices[cnt++] = g_PivotR2;
      lvlNames[cnt] = "Pivot S2"; lvlPrices[cnt++] = g_PivotS2;
   }
   if(g_Fib382 > 0) {
      lvlNames[cnt] = "Fib 23.6%"; lvlPrices[cnt++] = g_Fib236;
      lvlNames[cnt] = "Fib 38.2%"; lvlPrices[cnt++] = g_Fib382;
      lvlNames[cnt] = "Fib 50.0%"; lvlPrices[cnt++] = g_Fib500;
      lvlNames[cnt] = "Fib 61.8%"; lvlPrices[cnt++] = g_Fib618;
      lvlNames[cnt] = "Fib 76.4%"; lvlPrices[cnt++] = g_Fib764;
   }

   string closest     = "";
   double closestDist = r + 1;
   for(int i = 0; i < cnt; i++) {
      if(lvlPrices[i] <= 0) continue;
      double delta = lvlPrices[i] - price;   // positive = above, negative = below
      // BUY  → resistance ahead: level above price → delta ∈ (0, r]
      // SELL → support ahead:   level below price → delta ∈ [-r, 0)
      bool ahead = (tradeDir == 1) ? (delta > 0 && delta <= r)
                                   : (delta < 0 && delta >= -r);
      if(ahead) {
         double dist = MathAbs(delta);
         if(dist < closestDist) { closestDist = dist; closest = lvlNames[i]; }
      }
   }
   return closest;
}

bool BollingerOverrideCheck(int tradeDir, string &reason)
{
   int    score   = 0;
   string factors = "";
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // 1 — CI band breached: price has already moved beyond 1.5×ATR statistical boundary
   if(tradeDir ==  1 && g_CIHigh > 0 && bid > g_CIHigh) { score++; factors += "CI-High-break "; }
   if(tradeDir == -1 && g_CILow  > 0 && bid < g_CILow)  { score++; factors += "CI-Low-break ";  }

   // 2 — H1 swing structure aligned with trade direction
   if(tradeDir ==  1 && g_StructureLabel == "BULLISH") { score++; factors += "H1-Struct:BULL "; }
   if(tradeDir == -1 && g_StructureLabel == "BEARISH") { score++; factors += "H1-Struct:BEAR "; }

   // 3 — H1 BOS (recent structural break, short-term momentum confirmed)
   if(g_BOS) { score++; factors += "H1-BOS "; }

   // 4 — H4 macro structure aligned
   if(tradeDir ==  1 && g_MacroStructLabel == "BULLISH") { score++; factors += "Macro:BULL "; }
   if(tradeDir == -1 && g_MacroStructLabel == "BEARISH") { score++; factors += "Macro:BEAR "; }

   // 5 — Macro BOS (multi-day structural break — strongest structural signal)
   if(g_MacroBOS) { score++; factors += "MacroBOS "; }

   // 6 — Volume elevated (institutional participation backing the move)
   if(g_VolumeState == "HIGH" || g_VolumeState == "ABOVE_AVG") {
      score++; factors += "Vol:" + g_VolumeState + " ";
   }

   // 7 — Key session hour (moves that begin at session boundaries have extra follow-through)
   if(KeyHourBonusEnabled) {
      MqlDateTime khDt; TimeToStruct(TimeCurrent(), khDt);
      int keyHrs[] = {0, 3, 4, 7, 8, 12, 13, 17, 21};
      int closestMin = 99;
      for(int ki = 0; ki < ArraySize(keyHrs); ki++) {
         if(khDt.hour == keyHrs[ki])
            closestMin = MathMin(closestMin, khDt.min);
         if((khDt.hour + 1) % 24 == keyHrs[ki])
            closestMin = MathMin(closestMin, 60 - khDt.min);
      }
      if(closestMin <= 30) { score++; factors += "KeyHr(" + IntegerToString(closestMin) + "m) "; }
   }

   // 8 — H4 macro supply/demand zone in trade direction (institutional price memory)
   if(tradeDir ==  1 && (g_NearH4BullOB || g_NearBullH4FVG)) { score++; factors += "H4-DemandZone "; }
   if(tradeDir == -1 && (g_NearH4BearOB || g_NearBearH4FVG)) { score++; factors += "H4-SupplyZone "; }

   // 9 — Liquidity sweep in trade direction (stop hunt confirms directional intent)
   if(g_LiquiditySweep && g_SweepDir == tradeDir) { score++; factors += "LiqSweep "; }

   // 10 — MTF alignment (H4 and H1 both agree — fullest structural conviction)
   if(g_MTFAligned) { score++; factors += "MTF-aligned "; }

   reason = "score=" + IntegerToString(score) + "/" + IntegerToString(BollOverrideMinScore)
            + " [" + factors + "]";
   return (score >= BollOverrideMinScore);
}

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

   // === COLD-START RECOVERY ===
   // After restart all state is lost. If we have a consecutive chain of same-
   // direction candles and one of them (not necessarily bar 1) was the original
   // arming candle (bottomless/topless), re-arm the setup so the state machine
   // can pick up where it left off.  Only runs once — the first time both
   // setups are disarmed and we have at least 2 consecutive bars.
   if(!g_HABullSetup && !g_HABearSetup && g_Signal == "WAITING"
      && dir1 != 0 && g_HAConsecCount >= 2) {
      for(int ri = 1; ri <= g_HAConsecCount && ri <= TrendBoldHardCap; ri++) {
         if(dir1 == 1 && IsBottomless(ri)) {
            g_HABullSetup = true;
            g_Signal      = "PREPARING BUY";
            Print("[STARTUP RECOVERY] Re-armed BUY setup from bar ", ri,
                  " (bottomless bull). Consec=", g_HAConsecCount, "/", MaxConsecCandles);
            break;
         }
         if(dir1 == -1 && IsTopless(ri)) {
            g_HABearSetup = true;
            g_Signal      = "PREPARING SELL";
            Print("[STARTUP RECOVERY] Re-armed SELL setup from bar ", ri,
                  " (topless bear). Consec=", g_HAConsecCount, "/", MaxConsecCandles);
            break;
         }
      }
   }

   // === BUY SETUP STATE MACHINE ===
   // Step 1: bottomless bull → arm the setup (only if NOT already armed)
   // A 2nd/3rd consecutive bottomless candle falls to Step 2 as confirmation.
   if(bl1 && dir1 == 1 && !g_HABullSetup) {
      g_HABullSetup        = true;
      g_HABearSetup        = false;
      g_ConfirmCandleOpen  = 0;
      g_BoldTier           = "NORMAL";   // fresh arm — reset tier
      g_BoldRejectConsec   = 0;           // new setup — clear throttle
      g_BollOverridden     = false;
      g_BollOverrideReason = "";
      g_ZonePending        = false;
      g_ZoneContextUsed    = false;
      g_Signal             = "PREPARING BUY";
      g_PrepStartTime      = TimeCurrent();
      Print("PREPARING BUY: Bottomless bull candle detected (bar1). ",
            "Consec=", g_HAConsecCount, "/", MaxConsecCandles,
            " Boll=", DoubleToString(g_BollingerMid1, 5),
            " Zone=", g_ZoneLabel, " Bias=", g_TotalBias,
            " — waiting for next bull bar to confirm.");
   }
   // Step 2: setup armed → any bull candle (including further bottomless ones) is the confirming bar
   //         Normal gate: both HA body mids <= Boll midline.
   //         Narrow-band gate: band width < NarrowBandPips → relax to HA HIGH >= midline
   //         (compressed Boll means the full body-below-mid requirement is too strict)
   else if(g_HABullSetup && dir1 == 1) {
      if(g_HAConsecCount <= MaxConsecCandles) {
         double haO1b, haH1b, haL1b, haC1b, haO2b, haH2b, haL2b, haC2b;
         CalcHA(1, haO1b, haH1b, haL1b, haC1b);
         CalcHA(2, haO2b, haH2b, haL2b, haC2b);
         double bodyMid1 = (haO1b + haC1b) / 2.0;
         double bodyMid2 = (haO2b + haC2b) / 2.0;
         double bandWidthPips = (g_BollingerUpper1 > 0 && g_BollingerLower1 > 0)
                                ? (g_BollingerUpper1 - g_BollingerLower1) / _Point / 10.0
                                : 999.0;
         bool isNarrow = (g_BollingerUpper1 > 0 && bandWidthPips < NarrowBandPips);
         bool bollOK;
         if(g_BollingerMid1 <= 0) {
            bollOK = true;   // no band data — don't block
         } else if(isNarrow) {
            // Relaxed: HA high pokes above midline (upside momentum) AND body not above upper band
            bollOK = (haH1b >= g_BollingerMid1 && bodyMid1 <= g_BollingerUpper1 &&
                      haH2b >= g_BollingerMid2);
         } else {
            // Standard: both body mids below midline — price still has room to rally
            bollOK = (bodyMid1 <= g_BollingerMid1 && bodyMid2 <= g_BollingerMid2);
         }
         // Bollinger override: when strong multi-factor confluence supports the break,
         // the Boll midline lag should not veto. Position sizing unchanged (normal SL/TP).
         bool bollOverrideApplied = false;
         if(!bollOK && BollOverrideEnabled) {
            string ovReason = "";
            if(BollingerOverrideCheck(1, ovReason)) {
               bollOK             = true;
               bollOverrideApplied = true;
               g_BollOverridden     = true;
               g_BollOverrideReason = ovReason;
               Print("BUY: Bollinger gate OVERRIDDEN by confluence — ", ovReason);
            } else {
               g_BollOverridden     = false;
               g_BollOverrideReason = "insufficient: " + ovReason;
            }
         } else if(bollOK) {
            g_BollOverridden = false; g_BollOverrideReason = "";
         }
         if(bollOK) {
            if(g_ConfirmCandleOpen == 0)
               g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 1);
            g_Signal = "BUY INCOMING";
            if(bollOverrideApplied)
               Print("BUY INCOMING [BOLL OVERRIDE]: entering despite Boll midline — ", g_BollOverrideReason);
         } else {
            g_Signal            = "PREPARING BUY";
            g_ConfirmCandleOpen = 0;
            Print("PREPARING BUY: Bollinger gate BLOCKING",
                  (isNarrow ? " [NARROW band=" + DoubleToString(bandWidthPips,1) + "pip]" : ""),
                  " HA_H1=", DoubleToString(haH1b, 5),
                  " BodyMid1=", DoubleToString(bodyMid1, 5),
                  " BollMid=", DoubleToString(g_BollingerMid1, 5),
                  " BollUpper=", DoubleToString(g_BollingerUpper1, 5),
                  isNarrow ? " (need HA high >= BollMid)" : " (need body <= BollMid)",
                  " | Override-check: ", g_BollOverrideReason);
         }
      } else {
         // === TREND BOLD TIER EVALUATION (consec > MaxConsecCandles) ===
         // Rather than always hard-resetting, score the structural picture.
         // If a key level broke recently AND confluence is strong enough,
         // promote the setup to SMALL_BOLD or HUGE_BOLD and keep the signal live.
         // Normal SL always used — only TP differs between tiers.
         bool didReset = true;
         if(TrendBoldEnabled && g_HAConsecCount <= TrendBoldHardCap) {
            string ovReason = "";
            BollingerOverrideCheck(1, ovReason);
            int scoreIdx = StringFind(ovReason, "score=");
            int ovScore  = (scoreIdx >= 0) ? (int)StringToInteger(StringSubstr(ovReason, scoreIdx + 6, 2)) : 0;
            g_BarsSinceLevelBreak = CheckLevelBreakBars(1);
            string lvlTag = (g_BarsSinceLevelBreak < 999)
                            ? g_LevelBreakLabel + "(" + IntegerToString(g_BarsSinceLevelBreak) + "b)"
                            : "none";
            string tierInfo = "Consec=" + IntegerToString(g_HAConsecCount)
                            + " Score=" + IntegerToString(ovScore)
                            + " LvlBreak=" + lvlTag;
            // v6.23b: HUGE_BOLD needs only score (high conviction = override LvlBreak)
            //         SMALL_BOLD: LvlBreak OR elevated score (SmallBoldMinScore+1)
            if(ovScore >= HugeBoldMinScore) {
               g_BoldTier          = "HUGE_BOLD";
               g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 1);
               g_Signal            = "BUY INCOMING";
               didReset            = false;
               Print("[HUGE BOLD BUY] MaxConsec exceeded but strong trend — HUGE_BOLD: ", tierInfo);
            } else if(ovScore >= SmallBoldMinScore && (g_BarsSinceLevelBreak <= MaxConsecCandles * 3 || ovScore >= SmallBoldMinScore + 1)) {
               g_BoldTier          = "SMALL_BOLD";
               g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 1);
               g_Signal            = "BUY INCOMING";
               didReset            = false;
               Print("[SMALL BOLD BUY] MaxConsec exceeded — SMALL_BOLD (capped TP): ", tierInfo);
            } else {
               if(g_HAConsecCount != g_BoldRejectConsec) {
                  Print("[TREND BOLD REJECTED-BUY] Insufficient score/level break — staying armed. ", tierInfo);
                  g_BoldRejectConsec = g_HAConsecCount;
               }
            }
         }
         if(didReset) {
            // Stay armed with setup live — re-evaluate on the next bar when fresh
            // data (new level break, improved score, etc.) may qualify for BOLD.
            // Don't disarm g_HABullSetup — that causes a re-arm/reject spam loop.
            // A color-flip (bear bar) will properly disarm via the direction-change reset below.
            g_BoldTier          = "NORMAL";
            g_Signal            = "PREPARING BUY";
            g_ConfirmCandleOpen = 0;
         }
      }
   }

   // === SELL SETUP STATE MACHINE ===
   else if(tl1 && dir1 == -1 && !g_HABearSetup) {
      g_HABearSetup        = true;
      g_HABullSetup        = false;
      g_ConfirmCandleOpen  = 0;
      g_BoldTier           = "NORMAL";   // fresh arm — reset tier
      g_BoldRejectConsec   = 0;           // new setup — clear throttle
      g_BollOverridden     = false;
      g_BollOverrideReason = "";
      g_ZonePending        = false;
      g_ZoneContextUsed    = false;
      g_Signal             = "PREPARING SELL";
      g_PrepStartTime      = TimeCurrent();
      Print("PREPARING SELL: Topless bear candle detected (bar1). ",
            "Consec=", g_HAConsecCount, "/", MaxConsecCandles,
            " Boll=", DoubleToString(g_BollingerMid1, 5),
            " Zone=", g_ZoneLabel, " Bias=", g_TotalBias,
            " — waiting for next bear bar to confirm.");
   }
   else if(g_HABearSetup && dir1 == -1) {
      if(g_HAConsecCount <= MaxConsecCandles) {
         double haO1s, haH1s, haL1s, haC1s, haO2s, haH2s, haL2s, haC2s;
         CalcHA(1, haO1s, haH1s, haL1s, haC1s);
         CalcHA(2, haO2s, haH2s, haL2s, haC2s);
         double bodyMid1s = (haO1s + haC1s) / 2.0;
         double bodyMid2s = (haO2s + haC2s) / 2.0;
         double bandWidthPips = (g_BollingerUpper1 > 0 && g_BollingerLower1 > 0)
                                ? (g_BollingerUpper1 - g_BollingerLower1) / _Point / 10.0
                                : 999.0;
         bool isNarrow = (g_BollingerUpper1 > 0 && bandWidthPips < NarrowBandPips);
         bool bollOK;
         if(g_BollingerMid1 <= 0) {
            bollOK = true;
         } else if(isNarrow) {
            // Relaxed: HA low pokes below midline (downside momentum) AND body not below lower band
            bollOK = (haL1s <= g_BollingerMid1 && bodyMid1s >= g_BollingerLower1 &&
                      haL2s <= g_BollingerMid2);
         } else {
            // Standard: both body mids above midline
            bollOK = (bodyMid1s >= g_BollingerMid1 && bodyMid2s >= g_BollingerMid2);
         }
         // Bollinger override: same logic as BUY side — key-level break + confluence.
         bool bollOverrideAppliedS = false;
         if(!bollOK && BollOverrideEnabled) {
            string ovReasonS = "";
            if(BollingerOverrideCheck(-1, ovReasonS)) {
               bollOK              = true;
               bollOverrideAppliedS = true;
               g_BollOverridden      = true;
               g_BollOverrideReason  = ovReasonS;
               Print("SELL: Bollinger gate OVERRIDDEN by confluence — ", ovReasonS);
            } else {
               g_BollOverridden     = false;
               g_BollOverrideReason = "insufficient: " + ovReasonS;
            }
         } else if(bollOK) {
            g_BollOverridden = false; g_BollOverrideReason = "";
         }
         if(bollOK) {
            if(g_ConfirmCandleOpen == 0)
               g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 1);
            g_Signal = "SELL INCOMING";
            if(bollOverrideAppliedS)
               Print("SELL INCOMING [BOLL OVERRIDE]: entering despite Boll midline — ", g_BollOverrideReason);
         } else {
            g_Signal            = "PREPARING SELL";
            g_ConfirmCandleOpen = 0;
            Print("PREPARING SELL: Bollinger gate BLOCKING",
                  (isNarrow ? " [NARROW band=" + DoubleToString(bandWidthPips,1) + "pip]" : ""),
                  " HA_L1=", DoubleToString(haL1s, 5),
                  " BodyMid1=", DoubleToString(bodyMid1s, 5),
                  " BollMid=", DoubleToString(g_BollingerMid1, 5),
                  " BollLower=", DoubleToString(g_BollingerLower1, 5),
                  isNarrow ? " (need HA low <= BollMid)" : " (need body >= BollMid)",
                  " | Override-check: ", g_BollOverrideReason);
         }
      } else {
         // === TREND BOLD TIER EVALUATION (consec > MaxConsecCandles) ===
         bool didReset = true;
         if(TrendBoldEnabled && g_HAConsecCount <= TrendBoldHardCap) {
            string ovReason = "";
            BollingerOverrideCheck(-1, ovReason);
            int scoreIdx = StringFind(ovReason, "score=");
            int ovScore  = (scoreIdx >= 0) ? (int)StringToInteger(StringSubstr(ovReason, scoreIdx + 6, 2)) : 0;
            g_BarsSinceLevelBreak = CheckLevelBreakBars(-1);
            string lvlTag = (g_BarsSinceLevelBreak < 999)
                            ? g_LevelBreakLabel + "(" + IntegerToString(g_BarsSinceLevelBreak) + "b)"
                            : "none";
            string tierInfo = "Consec=" + IntegerToString(g_HAConsecCount)
                            + " Score=" + IntegerToString(ovScore)
                            + " LvlBreak=" + lvlTag;
            // v6.23b: HUGE_BOLD needs only score (high conviction = override LvlBreak)
            //         SMALL_BOLD: LvlBreak OR elevated score (SmallBoldMinScore+1)
            if(ovScore >= HugeBoldMinScore) {
               g_BoldTier          = "HUGE_BOLD";
               g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 1);
               g_Signal            = "SELL INCOMING";
               didReset            = false;
               Print("[HUGE BOLD SELL] MaxConsec exceeded but strong trend — HUGE_BOLD: ", tierInfo);
            } else if(ovScore >= SmallBoldMinScore && (g_BarsSinceLevelBreak <= MaxConsecCandles * 3 || ovScore >= SmallBoldMinScore + 1)) {
               g_BoldTier          = "SMALL_BOLD";
               g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 1);
               g_Signal            = "SELL INCOMING";
               didReset            = false;
               Print("[SMALL BOLD SELL] MaxConsec exceeded — SMALL_BOLD (capped TP): ", tierInfo);
            } else {
               if(g_HAConsecCount != g_BoldRejectConsec) {
                  Print("[TREND BOLD REJECTED-SELL] Insufficient score/level break — staying armed. ", tierInfo);
                  g_BoldRejectConsec = g_HAConsecCount;
               }
            }
         }
         if(didReset) {
            g_BoldTier          = "NORMAL";
            g_Signal            = "PREPARING SELL";
            g_ConfirmCandleOpen = 0;
         }
      }
   }
   // Direction flip — reset
   else if(dir1 == 1 && g_HABearSetup) {
      g_HABearSetup       = false;
      g_ConfirmCandleOpen = 0;
      g_BoldTier          = "NORMAL";
      g_ZonePending       = false;
      g_ZoneContextUsed   = false;
      g_Signal            = "WAITING";
      g_PreflightBearOK   = false;   // bear setup died
      g_PreflightBlocker  = "";
   }
   else if(dir1 == -1 && g_HABullSetup) {
      g_HABullSetup       = false;
      g_ConfirmCandleOpen = 0;
      g_BoldTier          = "NORMAL";
      g_ZonePending       = false;
      g_ZoneContextUsed   = false;
      g_Signal            = "WAITING";
      g_PreflightBullOK   = false;   // bull setup died
      g_PreflightBlocker  = "";
   }

   // === PREPARING EXPIRY — if Bollinger hasn't confirmed after PrepMaxBars, abandon setup ===
   if((g_Signal == "PREPARING BUY" || g_Signal == "PREPARING SELL") && PrepMaxBars > 0 && g_PrepStartTime > 0) {
      int barsSinceArm = Bars(_Symbol, PERIOD_M15, g_PrepStartTime, TimeCurrent());
      if(barsSinceArm >= PrepMaxBars) {
         Print("[PREPARING EXPIRED] ", g_Signal, " timed out after ", barsSinceArm,
               " bars (max=", PrepMaxBars, ") — Bollinger never confirmed. Resetting to WAITING.");
         g_Signal         = "WAITING";
         g_HABullSetup    = false;
         g_HABearSetup    = false;
         g_PrepStartTime  = 0;
         g_PreflightBullOK = false;
         g_PreflightBearOK = false;
         g_PreflightBlocker = "";
         return;
      }
   }

   // === STILL PREPARING diagnostic — structured confirmed / pending / next-gate report ===
   // v6.23a: threshold lowered from consec>=2 to consec>=1 so first armed bar gets a report
   if((g_Signal == "PREPARING BUY" || g_Signal == "PREPARING SELL") && g_HAConsecCount >= 1) {
      int  trD      = (g_Signal == "PREPARING BUY") ? 1 : -1;
      bool isBuy    = (trD == 1);
      // Recompute zone hardness for PREPARING diagnostic
      g_ZoneHardness = ClassifyZoneHardness(trD, SymbolInfoDouble(_Symbol, SYMBOL_BID));

      // --- Recompute Bollinger gate status (mirrors state-machine logic above) ---
      double hpO1, hpH1, hpL1, hpC1, hpO2, hpH2, hpL2, hpC2;
      CalcHA(1, hpO1, hpH1, hpL1, hpC1);
      CalcHA(2, hpO2, hpH2, hpL2, hpC2);
      double hpBodyMid1 = (hpO1 + hpC1) / 2.0;
      double hpBodyMid2 = (hpO2 + hpC2) / 2.0;
      double hpBandPips = (g_BollingerUpper1 > 0 && g_BollingerLower1 > 0)
                          ? (g_BollingerUpper1 - g_BollingerLower1) / _Point / 10.0 : 999.0;
      bool   hpNarrow   = (g_BollingerUpper1 > 0 && hpBandPips < NarrowBandPips);
      bool   hpBollOK   = false;
      string hpBollReq  = "";
      string hpBollStat = "";
      if(g_BollingerMid1 <= 0) {
         hpBollOK   = true;
         hpBollStat = "no Boll data";
      } else if(hpNarrow) {
         if(isBuy) {
            hpBollOK   = (hpH1 >= g_BollingerMid1 && hpBodyMid1 <= g_BollingerUpper1 && hpH2 >= g_BollingerMid2);
            hpBollReq  = "HA_H >= BollMid + HA_H2 >= BollMid2 [NARROW band]";
            hpBollStat = "HA_H1=" + DoubleToString(hpH1,5) + " BollMid=" + DoubleToString(g_BollingerMid1,5)
                         + " H2=" + DoubleToString(hpH2,5) + " BollMid2=" + DoubleToString(g_BollingerMid2,5);
         } else {
            hpBollOK   = (hpL1 <= g_BollingerMid1 && hpBodyMid1 >= g_BollingerLower1 && hpL2 <= g_BollingerMid2);
            hpBollReq  = "HA_L <= BollMid + HA_L2 <= BollMid2 [NARROW band]";
            hpBollStat = "HA_L1=" + DoubleToString(hpL1,5) + " BollMid=" + DoubleToString(g_BollingerMid1,5)
                         + " L2=" + DoubleToString(hpL2,5) + " BollMid2=" + DoubleToString(g_BollingerMid2,5);
         }
      } else {
         if(isBuy) {
            hpBollOK   = (hpBodyMid1 <= g_BollingerMid1 && hpBodyMid2 <= g_BollingerMid2);
            hpBollReq  = "BodyMid1 <= BollMid AND BodyMid2 <= BollMid2";
            hpBollStat = "BodyMid1=" + DoubleToString(hpBodyMid1,5) + " BollMid=" + DoubleToString(g_BollingerMid1,5)
                         + " BodyMid2=" + DoubleToString(hpBodyMid2,5) + " BollMid2=" + DoubleToString(g_BollingerMid2,5);
         } else {
            hpBollOK   = (hpBodyMid1 >= g_BollingerMid1 && hpBodyMid2 >= g_BollingerMid2);
            hpBollReq  = "BodyMid1 >= BollMid AND BodyMid2 >= BollMid2";
            hpBollStat = "BodyMid1=" + DoubleToString(hpBodyMid1,5) + " BollMid=" + DoubleToString(g_BollingerMid1,5)
                         + " BodyMid2=" + DoubleToString(hpBodyMid2,5) + " BollMid2=" + DoubleToString(g_BollingerMid2,5);
         }
      }

      // --- TryEntry gate pre-checks (forward look once Bollinger clears) ---
      // Compute live confidence so the diagnostic shows real values (not stale 0)
      CalcConfidence(trD, g_ZoneLabel, false, IsSideways(), g_NearLevel);

      bool hpBiasOK      = isBuy ? (g_TotalBias > -2) : (g_TotalBias < 2);
      bool hpConfOK      = (g_Confidence >= MinConfidence);
      bool hpDailyOK     = (MaxDailyTrades == 0 || g_DailyTradeCount < MaxDailyTrades);
      bool hpCooldownOK  = !(g_CooldownUntil > 0 && TimeCurrent() < g_CooldownUntil)
                           && !(g_PostTradeCoolUntil > 0 && TimeCurrent() < g_PostTradeCoolUntil)
                           && !(g_StartupGraceUntil > 0 && TimeCurrent() < g_StartupGraceUntil);
      bool hpTradeOpenOK = !g_TradeOpen;
      // Zone check — SOFT zones do not block (boundaries expected to break)
      bool hpZoneHard    = (g_ZoneHardness == "HARD");
      bool hpZoneOK      = !(isBuy  && g_ZoneLabel == "UPPER_THIRD" && g_RangeHigh > 0 && hpZoneHard) &&
                           !(!isBuy && g_ZoneLabel == "LOWER_THIRD" && g_RangeLow  > 0 && hpZoneHard);

      MqlDateTime hpDt; TimeToStruct(TimeCurrent(), hpDt);
      bool hpTimeOK = (NoEntryAfterHour == 0 || hpDt.hour < NoEntryAfterHour);
      bool hpForeignOK = !(RespectForeignTrades && g_ForeignCountSymbol > 0);
      bool hpDailyLossOK = (MaxDailyLossUSD == 0 || g_DailyPnL > -MaxDailyLossUSD);

      // --- MTF / SMC (informational — scored via confidence) ---
      string hpMTF = g_MTFAligned ? "ALIGNED" : "diverged";
      string hpH4  = g_NearH4BullOB || g_NearBullH4FVG ? "BULL zone" :
                     g_NearH4BearOB || g_NearBearH4FVG ? "BEAR zone" : "none near";

      // --- Compose confirmed list ---
      string confirmed = "";
      confirmed += "  ✓ HA " + (isBuy ? "BULL" : "BEAR") + " x" + IntegerToString(g_HAConsecCount) + "/" + IntegerToString(MaxConsecCandles);
      confirmed += " | Zone=" + g_ZoneLabel + "[" + g_ZoneHardness + "]";
      confirmed += " | Bias=" + IntegerToString(g_TotalBias) + (hpBiasOK ? " ok" : " [BLOCKED]");
      if(g_MTFAligned) confirmed += " | MTF=" + hpMTF;
      if(g_NearBullFVG || g_NearBearFVG) confirmed += " | H1FVG=" + (g_NearBullFVG ? "BULL" : "BEAR");
      if(g_BullOB_High > 0 || g_BearOB_High > 0) confirmed += " | H1OB=" + (g_BullOB_High > 0 ? "BULL" : "BEAR");
      if(g_BollOverridden) confirmed += " | ⚡BOLL-OVERRIDDEN (" + g_BollOverrideReason + ")";
      if(g_BoldTier != "NORMAL") confirmed += " | 🔥BOLD-TIER=" + g_BoldTier
                                              + " LvlBreak=" + (g_BarsSinceLevelBreak < 999
                                                ? g_LevelBreakLabel + "(" + IntegerToString(g_BarsSinceLevelBreak) + "b)"
                                                : "none");
      if(g_ZonePending)
         confirmed += " | 🕐ZONE-PENDING=" + g_ZonePendingLevel + "("
                      + IntegerToString((int)((TimeCurrent()-g_ZonePendingStartTime)/PeriodSeconds(PERIOD_M15)))
                      + "b elapsed)";
      else if(g_ZoneContextUsed)
         confirmed += " | 🟡ZONE-CONTEXT-OVERRIDE (ZoneStrictness=" + IntegerToString(ZoneStrictness) + ")";
      // Macro BOS direction check
      if(g_MacroBOS && UseMacroStructure) {
         bool macroOpp = (trD ==  1 && g_MacroStructLabel == "BEARISH") ||
                         (trD == -1 && g_MacroStructLabel == "BULLISH");
         if(macroOpp && MacroBOSHardBlock) {
            bool _chochEx = g_MacroCHoCH && (g_MacroCHoCHDir == trD);
            if(_chochEx)
               confirmed += " | ⚡MacroBOS=" + g_MacroStructLabel + " — CHoCH reversal (" + (g_MacroCHoCHDir>0?"Bull":"Bear") + ") exempts block";
            else
               confirmed += " | ❌MacroBOS=" + g_MacroStructLabel + " — will BLOCK entry";
         } else if(macroOpp)
            confirmed += " | ⚠️MacroBOS=" + g_MacroStructLabel + " opposes (block disabled)";
      }
      // MTF / volume divergence flag
      if(!g_MTFAligned)  confirmed += " | ⚠️MTF-DIVERGED";
      if(g_VolDivergence) confirmed += " | ⚠️VOL-DIVERGED";
      if(!g_MTFAligned && g_VolDivergence)
         confirmed += " → BOTH diverged: will BLOCK entry (DivergenceCautionEnabled)";
      else if(!g_MTFAligned || g_VolDivergence)
         confirmed += " → single divergence only — full TP applies";

      // --- Compose pending (current blocker) ---
      string pending = "";
      if(!hpBollOK && !g_BollOverridden) {
         pending += "  ✗ [Bollinger] " + hpBollReq + "\n";
         pending += "      Values: " + hpBollStat;
         if(hpNarrow) pending += " | BandWidth=" + DoubleToString(hpBandPips,1) + "pip (NARROW < " + DoubleToString(NarrowBandPips,1) + "p)";
         // Show override progress even when not yet at threshold
         if(BollOverrideEnabled) {
            string ovCheck = "";
            BollingerOverrideCheck(isBuy ? 1 : -1, ovCheck);
            pending += "\n      Override-check: " + ovCheck + " (need >= " + IntegerToString(BollOverrideMinScore) + ")";
         }
      } else if(g_BollOverridden) {
         pending += "  ⚡ Bollinger gate OVERRIDDEN — " + g_BollOverrideReason;
      } else {
         pending += "  ✓ Bollinger gate CLEAR";
      }

      // --- Compose next-gate forward look ---
      string nextGates = "";
      nextGates += "  " + (hpZoneOK      ? "✓" : "✗") + " Zone=" + g_ZoneLabel + " (" + (isBuy?"need not UPPER_THIRD":"need not LOWER_THIRD") + ")";
      nextGates += " | " + (hpBiasOK     ? "✓" : "✗") + " Bias=" + IntegerToString(g_TotalBias);
      nextGates += " | " + (hpConfOK     ? "✓" : "✗") + " Conf=" + DoubleToString(g_Confidence,1) + "% (min " + DoubleToString(MinConfidence,1) + "%)";
      nextGates += "\n  " + (hpDailyOK   ? "✓" : "✗") + " DailyTrades=" + IntegerToString(g_DailyTradeCount) + "/" + IntegerToString(MaxDailyTrades);
      nextGates += " | " + (hpDailyLossOK? "✓" : "✗") + " DailyPnL=$" + DoubleToString(g_DailyPnL,2) + " (limit=$-" + DoubleToString(MaxDailyLossUSD,2) + ")";
      string cooldownInfo = "none";
      if(!hpCooldownOK) {
         if(g_CooldownUntil > 0 && TimeCurrent() < g_CooldownUntil)
            cooldownInfo = "ConsecLoss→" + TimeToString(g_CooldownUntil, TIME_MINUTES);
         else if(g_PostTradeCoolUntil > 0 && TimeCurrent() < g_PostTradeCoolUntil)
            cooldownInfo = "PostTrade→" + TimeToString(g_PostTradeCoolUntil, TIME_MINUTES);
         else if(g_StartupGraceUntil > 0 && TimeCurrent() < g_StartupGraceUntil)
            cooldownInfo = "StartupGrace→" + TimeToString(g_StartupGraceUntil, TIME_MINUTES);
      }
      nextGates += " | " + (hpCooldownOK ? "✓" : "✗") + " Cooldown=" + cooldownInfo;
      nextGates += " | " + (hpTimeOK     ? "✓" : "✗") + " Time=" + IntegerToString(hpDt.hour) + "h (NoEntryAfter=" + IntegerToString(NoEntryAfterHour) + ")";
      nextGates += "\n  " + (hpForeignOK ? "✓" : "✗") + " ForeignTrades=" + IntegerToString(g_ForeignCountSymbol);
      nextGates += " | " + (hpTradeOpenOK? "✓" : "✗") + " TradeOpen=" + (g_TradeOpen ? "YES" : "no");
      nextGates += " | Struct=" + g_StructureLabel + " MacroStr=" + g_MacroStructLabel;
      nextGates += " | H4zones=" + hpH4;
      if(g_BoldBet) nextGates += " | BOLD BET active";

      Print("STILL " + g_Signal + " — bar " + IntegerToString(g_HAConsecCount) + " of max " + IntegerToString(MaxConsecCandles) + "\n",
            "  CONFIRMED:\n", confirmed, "\n",
            "  CURRENT BLOCKER:\n", pending, "\n",
            "  NEXT GATES (after Bollinger):\n", nextGates);
      Print("  SCORE BREAKDOWN: [", g_ConfBreakdown, "] = ", DoubleToString(g_Confidence,1), "%");

      // === CACHE PRE-FLIGHT RESULT for live bar fast-track ===
      // If ALL downstream gates are already green while PREPARING, the next HA candle
      // that aligns (even live/forming) can trigger an immediate entry.
      bool _macroBOSRawPF  = g_MacroBOS && UseMacroStructure && MacroBOSHardBlock &&
                              ((isBuy  && g_MacroStructLabel == "BEARISH") ||
                               (!isBuy && g_MacroStructLabel == "BULLISH"));
      bool _chochExmptPF   = g_MacroCHoCH && (g_MacroCHoCHDir == (isBuy ? 1 : -1));
      bool macroBOSBlockPF = _macroBOSRawPF && !_chochExmptPF;
      bool allDownGatesOK = hpZoneOK && hpBiasOK && hpConfOK && hpTimeOK &&
                            hpCooldownOK && hpForeignOK && hpDailyOK && hpDailyLossOK &&
                            !macroBOSBlockPF && !g_TradeOpen;

      if(isBuy)  g_PreflightBullOK = allDownGatesOK;
      else       g_PreflightBearOK = allDownGatesOK;

      if(!allDownGatesOK) {
         if(!hpTimeOK)         g_PreflightBlocker = "NoEntryAfter=" + IntegerToString(NoEntryAfterHour) + ":00";
         else if(!hpCooldownOK) g_PreflightBlocker = cooldownInfo;
         else if(!hpDailyOK)    g_PreflightBlocker = "DailyTrades=" + IntegerToString(g_DailyTradeCount) + "/" + IntegerToString(MaxDailyTrades);
         else if(!hpDailyLossOK)g_PreflightBlocker = "DailyLoss=$" + DoubleToString(g_DailyPnL,2);
         else if(!hpForeignOK)  g_PreflightBlocker = "ForeignTrade open";
         else if(!hpZoneOK)     g_PreflightBlocker = "Zone=" + g_ZoneLabel;
         else if(!hpBiasOK)     g_PreflightBlocker = "Bias=" + IntegerToString(g_TotalBias);
         else if(macroBOSBlockPF)g_PreflightBlocker = "MacroBOS=" + g_MacroStructLabel;
         else if(!hpConfOK)     g_PreflightBlocker = "Conf=" + DoubleToString(g_Confidence,1) + "% (min " + DoubleToString(MinConfidence,1) + "%";
         Print("[PREFLIGHT ", (isBuy?"BUY":"SELL"), " BLOCKED] ", g_PreflightBlocker,
               " — live bar fast-track disabled until this clears");
      } else {
         g_PreflightBlocker = "";
         Print("[PREFLIGHT ", (isBuy?"BUY":"SELL"), " ✓ GREEN] All downstream gates clear",
               " — live bar fast-track ARMED (Boll still needed)");
      }
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
//| LIVE BAR BOLLINGER CHECK                                         |
//| Checks whether the FORMING bar[0] passes the Bollinger gate,    |
//| using the current bid/ask as a provisional close price.          |
//| This allows fast-track entry before bar[0] fully closes.        |
//+------------------------------------------------------------------+
bool LiveHABollingerOK(int tradeDir)
{
   if(g_BollingerMid1 <= 0) return true;  // no Bollinger data — don't block

   double barO = iOpen  (_Symbol, PERIOD_M15, 0);
   double barH = iHigh  (_Symbol, PERIOD_M15, 0);
   double barL = iLow   (_Symbol, PERIOD_M15, 0);
   // Use bid for buy checks, ask for sell checks (more conservative)
   double barC = (tradeDir == 1)
                 ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                 : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Provisional HA close for bar[0]: average of OHLC with live price
   double haC0 = (barO + barH + barL + barC) / 4.0;
   // Provisional HA open for bar[0] = average of bar[1]'s HA open & close
   double haO1, haH1, haL1, haC1;
   CalcHA(1, haO1, haH1, haL1, haC1);
   double haO0    = (haO1 + haC1) / 2.0;
   double bodyMid = (haO0 + haC0) / 2.0;

   double bandPips = (g_BollingerUpper1 > 0 && g_BollingerLower1 > 0)
                     ? (g_BollingerUpper1 - g_BollingerLower1) / _Point / 10.0 : 999.0;
   bool isNarrow = (g_BollingerUpper1 > 0 && bandPips < NarrowBandPips);

   if(isNarrow) {
      // Relaxed: high/low pokes past midline, body stays inside bands
      if(tradeDir ==  1) return (barH >= g_BollingerMid1 && bodyMid <= g_BollingerUpper1);
      else               return (barL <= g_BollingerMid1 && bodyMid >= g_BollingerLower1);
   } else {
      // Standard: live body mid on the correct side of midline
      if(tradeDir ==  1) return (bodyMid <= g_BollingerMid1);
      else               return (bodyMid >= g_BollingerMid1);
   }
}

//+------------------------------------------------------------------+
//| ENTRY LOGIC v3                                                    |
//| Handles: trend trades, midrange caution, mean reversion          |
//+------------------------------------------------------------------+
void TryEntry()
{
   if(g_TradeOpen) return;

   // Throttle block diagnostics: print once per M15 bar, not every tick
   datetime _blockBar = iTime(_Symbol, PERIOD_M15, 0);
   bool _canPrintBlock = (_blockBar != g_LastBlockPrintBar);

   // === FOREIGN TRADE GUARD ===
   // If a non-bot trade exists on this symbol, respect the one-trade rule
   if(RespectForeignTrades && g_ForeignCountSymbol > 0) {
      if(_canPrintBlock) {
         Print("ENTRY BLOCKED: ", g_ForeignCountSymbol, " foreign trade(s) open on ", _Symbol,
               " (", DoubleToString(g_ForeignLotsSymbol,2), " lots) — one-trade rule");
         g_LastBlockPrintBar = _blockBar;
      }
      return;
   }

   // === DAILY TRADE LIMIT ===
   if(MaxDailyTrades > 0 && g_DailyTradeCount >= MaxDailyTrades) {
      if(_canPrintBlock) {
         Print("[ENTRY WAIT] DailyTrades=", g_DailyTradeCount, "/", MaxDailyTrades,
               " reached | Signal=", g_Signal);
         g_LastBlockPrintBar = _blockBar;
      }
      return;
   }

   // === DAILY LOSS LIMIT ===
   if(MaxDailyLossUSD > 0 && g_DailyPnL <= -MaxDailyLossUSD) {
      if(_canPrintBlock) {
         Print("[ENTRY WAIT] DailyPnL=$", DoubleToString(g_DailyPnL, 2),
               " hit limit $-", DoubleToString(MaxDailyLossUSD, 2), " | Signal=", g_Signal);
         g_LastBlockPrintBar = _blockBar;
      }
      return;
   }

   // === CONSECUTIVE LOSS COOLDOWN ===
   if(g_CooldownUntil > 0 && TimeCurrent() < g_CooldownUntil) {
      if(_canPrintBlock) {
         Print("[ENTRY WAIT] ConsecLossCooldown until ",
               TimeToString(g_CooldownUntil, TIME_MINUTES), " | Signal=", g_Signal);
         g_LastBlockPrintBar = _blockBar;
      }
      return;
   }
   if(g_CooldownUntil > 0 && TimeCurrent() >= g_CooldownUntil) {
      Print("COOLDOWN expired — resuming trading (consec losses reset)");
      g_CooldownUntil = 0;
      g_ConsecLosses  = 0;
   }

   // === POST-TRADE COOLDOWN ===
   if(g_PostTradeCoolUntil > 0 && TimeCurrent() < g_PostTradeCoolUntil) {
      if(_canPrintBlock) {
         Print("[ENTRY WAIT] PostTradeCooldown until ",
               TimeToString(g_PostTradeCoolUntil, TIME_MINUTES), " | Signal=", g_Signal);
         g_LastBlockPrintBar = _blockBar;
      }
      return;
   }
   if(g_PostTradeCoolUntil > 0 && TimeCurrent() >= g_PostTradeCoolUntil) {
      Print("[POST-TRADE COOLDOWN] expired — resuming trading");
      g_PostTradeCoolUntil = 0;
   }

   // === STARTUP GRACE PERIOD ===
   if(g_StartupGraceUntil > 0 && TimeCurrent() < g_StartupGraceUntil) {
      if(_canPrintBlock) {
         Print("[ENTRY WAIT] StartupGrace until ",
               TimeToString(g_StartupGraceUntil, TIME_MINUTES), " | Signal=", g_Signal);
         g_LastBlockPrintBar = _blockBar;
      }
      return;
   }
   if(g_StartupGraceUntil > 0 && TimeCurrent() >= g_StartupGraceUntil) {
      Print("[STARTUP GRACE] expired — allowing entries");
      g_StartupGraceUntil = 0;
   }

   // === NO ENTRY AFTER HOUR ===
   if(NoEntryAfterHour > 0) {
      MqlDateTime entryDt;
      TimeToStruct(TimeCurrent(), entryDt);
      if(entryDt.hour >= NoEntryAfterHour) {
         if(_canPrintBlock && g_Signal != "WAITING") {
            Print("[SESSION CUTOFF] ", g_Signal, " killed — past NoEntryAfter=",
                  IntegerToString(NoEntryAfterHour), ":00 (current=",
                  IntegerToString(entryDt.hour), ":", StringFormat("%02d", entryDt.min), ")");
            g_LastBlockPrintBar = _blockBar;
         }
         // Reset signal so dashboard doesn't show stale INCOMING after cutoff
         if(g_Signal == "BUY INCOMING" || g_Signal == "SELL INCOMING" ||
            g_Signal == "PREPARING BUY" || g_Signal == "PREPARING SELL") {
            g_Signal      = "WAITING";
            g_HABullSetup = false;
            g_HABearSetup = false;
         }
         return;
      }
   }

   // Check both trend signals AND mean reversion setup
   bool isTrendSignal = (g_Signal == "BUY INCOMING" || g_Signal == "SELL INCOMING");
   int  meanRevDir    = MeanReversionSetup();
   bool isMeanRev     = (meanRevDir != 0 && !isTrendSignal);
   bool isMacroTrend  = (g_MacroTrendRide && g_MacroTrendDir != 0 && MacroTrendRideEnabled);

   if(!isTrendSignal && !isMeanRev && !isMacroTrend) {
      if(_canPrintBlock && g_Signal != "WAITING") {
         Print("[ENTRY WAIT] No valid signal | g_Signal=", g_Signal,
               " MeanRev=", meanRevDir, " MacroTrend=", (g_MacroTrendRide ? "armed" : "off"));
         g_LastBlockPrintBar = _blockBar;
      }
      return;
   }

   // === ENTRY TIMING based on HAEntryMode, or MRV 5-minute window ===
   datetime barTime   = iTime(_Symbol, PERIOD_M15, 0);
   int secsElapsed    = (int)(TimeCurrent() - barTime);

   if(isMacroTrend && !isTrendSignal && !isMeanRev) {
      // Macro trend ride: high-conviction structural entry — accept any time during the bar.
      // H4 BOS is confirmed, HA momentum is aligned, score is gated. No tight timing window.
   } else if(isMeanRev) {
      // MRV: 5-minute entry window from the bar that opened after the 2nd confirming candle
      if(secsElapsed > 5 * 60) {
         g_MRVArmed = false; g_MRVConfirmOpen = 0;
         return;   // window expired — discard this MRV setup
      }
      // Within 5-min window: skip the standard HAEntryMode timing block
   } else if(HAEntryMode == 1) {
      // EARLY MODE: prefer entry within first EarlyEntryMins of the current bar.
      // If AllowLateEntry=true, also accept entry any time while the bar is open.
      // If confirming candle has double-sided wicks (doji-like), skip early entry.
      bool confirmIsClean = (g_Signal == "BUY INCOMING")
                            ? !IsBottomlessWithTopSpike(1)   // no spike above on bull
                            : !IsToplessWithBottomSpike(1);  // no spike below on bear

      if(!confirmIsClean) {
         // Impure confirming candle — only enter in the last 5 min of the bar
         if(secsElapsed < 600) {
            if(_canPrintBlock) {
               Print("[ENTRY WAIT] EntryTiming: double-wick candle, waiting for last 5min of bar (",
                     secsElapsed, "s elapsed, need >=600) | Signal=", g_Signal);
               g_LastBlockPrintBar = _blockBar;
            }
            return;
         }
      } else if(secsElapsed <= EarlyEntryMins * 60) {
         // Within early window — proceed immediately
      } else if(AllowLateEntry) {
         // Past early window but AllowLateEntry=true — enter now (late but valid)
         Print("LATE ENTRY: ", secsElapsed, "s into bar (early window was ",
               EarlyEntryMins * 60, "s). Signal=" + g_Signal);
      } else {
         // AllowLateEntry=false — wait for last 5 min of current bar only
         if(secsElapsed < 600) {
            if(_canPrintBlock) {
               Print("[ENTRY WAIT] EntryTiming: past early window, waiting for last 5min (",
                     secsElapsed, "s elapsed, need >=600) | Signal=", g_Signal);
               g_LastBlockPrintBar = _blockBar;
            }
            return;
         }
      }
   } else {
      // MODE 2: last 5 minutes of the current bar (confirming candle's successor)
      if(secsElapsed < 600) {
         if(_canPrintBlock) {
            Print("[ENTRY WAIT] EntryTiming: MODE2 waiting for last 5min (",
                  secsElapsed, "s elapsed, need >=600) | Signal=", g_Signal);
            g_LastBlockPrintBar = _blockBar;
         }
         return;
      }
   }

   // HA consecutive candle guard — include the forming bar (bar 0) in the count
   // so we never enter late when the live candle is already the 4th+ in a row.
   // Exempt BOLD tiers (EvaluateHAPattern already approved the extended count)
   // and Macro Trend Rides (structural breakout, not pattern count limited).
   int liveConsec = LiveHAConsecTotal();
   if(liveConsec > MaxConsecCandles && !isMacroTrend && g_BoldTier == "NORMAL") {
      Print("[SIGNAL EXPIRED] liveConsec=", liveConsec, " exceeded MaxConsecCandles=",
            MaxConsecCandles, " — resetting to WAITING");
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
   if(isTrendSignal)       tradeDir = (g_Signal == "BUY INCOMING") ? 1 : -1;
   else if(isMeanRev)      tradeDir = meanRevDir;
   else if(isMacroTrend)   tradeDir = g_MacroTrendDir;

   // === ZONE HARDNESS (SOFT/HARD) ===
   // Evaluate whether the zone boundary is expected to hold or break.
   // Must be computed after tradeDir is known.
   if(tradeDir != 0)
      g_ZoneHardness = ClassifyZoneHardness(tradeDir, price);
   else
      g_ZoneHardness = "HARD";  // unknown direction → conservative

   // === ZONE FILTERS FOR TREND TRADES ===
   // Standard rule: avoid UPPER_THIRD for buys (near range high = mean-reversion risk)
   //                and LOWER_THIRD for sells (near range low = bounce risk).
   //
   // ASIAN SESSION RELAXATION (AsianZoneStrictMode = false, default):
   //   When the last hour of the previous trading day moved in the SAME direction as
   //   the current signal, the zone filter is lifted during Asian hours.
   //   This reflects institutional carry-over bias before the London reset.
   //   The trade is logged as CAUTION and uses the standard (not narrowed) SL.
   //
   //   Additional CI validation: even in relax mode, the Bollinger band position is
   //   cross-checked — for a buy the HA high must reach at least the upper band,
   //   and for a sell the HA low must reach at least the lower band, confirming
   //   that price is genuinely pushing into the (unfavorable) zone rather than drifting.

   g_AsianZoneRelaxed = false;
   g_ZoneContextUsed  = false;
   if(isTrendSignal && !isMeanRev && !isMacroTrend) {
      MqlDateTime zdt; TimeToStruct(TimeCurrent(), zdt);
      bool inAsian = (zdt.hour >= AsianStartHour && zdt.hour < AsianEndHour);

      // Determine whether we would normally block this trade (trending into unfavourable zone)
      // SOFT zones are expected to break — do not block when g_ZoneHardness == "SOFT"
      bool wouldBlock = ((tradeDir == 1  && zone == "UPPER_THIRD" && g_RangeHigh > 0) ||
                         (tradeDir == -1 && zone == "LOWER_THIRD" && g_RangeLow  > 0))
                        && (g_ZoneHardness == "HARD");  // SOFT boundary → no block

      // If SOFT zone override applied, log it
      if(g_ZoneHardness == "SOFT" && !wouldBlock &&
         ((tradeDir == 1 && zone == "UPPER_THIRD") || (tradeDir == -1 && zone == "LOWER_THIRD"))) {
         string _softMsg = "SOFT ZONE PASS: " + zone + " boundary expected to break"
                         + " (Murray/weekly/struct confluence) — trade allowed";
         if(_softMsg != g_LastBlockReason) { Print(_softMsg); g_LastBlockReason = _softMsg; }
      }

      // Cancel stale pending state if direction flipped
      if(g_ZonePending && g_ZonePendingDir != tradeDir)
         g_ZonePending = false;

      if(wouldBlock) {
         // ── MODE 0: STRICT ─────────────────────────────────────────────────────────────
         if(ZoneStrictness == 0) {
            string _br = (tradeDir == 1 ? "BUY" : "SELL") + " skipped: " + zone +
                         " zone (ZoneStrictness=STRICT — no exceptions)";
            if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
            return;

         // ── MODE 1: RELAXED (original Asian carry-over behavior) ───────────────────────
         } else if(ZoneStrictness == 1) {
            bool prevDayAligned = (AsianPrevDayMomEnabled && g_PrevDayLastHourDir == tradeDir);
            bool ciConfirms     = false;
            if(tradeDir == 1 && g_BollingerUpper1 > 0) {
               double haO1z, haH1z, haL1z, haC1z;
               CalcHA(1, haO1z, haH1z, haL1z, haC1z);
               ciConfirms = (haH1z >= g_BollingerUpper1);   // wick reached or exceeded upper band
            } else if(tradeDir == -1 && g_BollingerLower1 > 0) {
               double haO1z, haH1z, haL1z, haC1z;
               CalcHA(1, haO1z, haH1z, haL1z, haC1z);
               ciConfirms = (haL1z <= g_BollingerLower1);   // wick at or below lower band
            } else {
               ciConfirms = true;   // no band data — don't block on CI
            }
            bool canRelax = inAsian && prevDayAligned && !AsianZoneStrictMode && ciConfirms;
            if(canRelax) {
               g_AsianZoneRelaxed = true;
               string _br = "ASIAN ZONE RELAX: zone=" + zone + " signal=" + g_Signal +
                            " PrevDayDir=" + IntegerToString(g_PrevDayLastHourDir) +
                            " CI=OK — CAUTION entry";
               if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
               // fall through to trade
            } else {
               string reason = "";
               if(!inAsian)               reason = "not in Asian session";
               else if(!prevDayAligned)   reason = "prev-day dir not aligned (" + IntegerToString(g_PrevDayLastHourDir) + ")";
               else if(AsianZoneStrictMode) reason = "StrictMode=true";
               else if(!ciConfirms)       reason = "CI band not confirmed (price not pushing into zone)";
               string _br = (tradeDir == 1 ? "BUY" : "SELL") + " skipped: " + zone +
                            " zone (" + reason + ")";
               if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
               return;
            }

         // ── MODE 2: CONTEXT_AWARE (structural confluence + Fib/Pivot pending logic) ────
         } else {
            // Step 1: score structural confluence — how strong is the trend evidence?
            int ctxScore = ZoneContextScore(tradeDir);

            if(ctxScore < ZoneContextMinScore) {
               // Not enough confluence to override the zone filter
               string _br = (tradeDir == 1 ? "BUY" : "SELL") + " skipped: " + zone +
                            " zone [CONTEXT score=" + IntegerToString(ctxScore) + "/14, need " +
                            IntegerToString(ZoneContextMinScore) + "+ for override]";
               if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
               g_ZonePending = false;
               return;
            }

            // Step 2: check for a Fib/Pivot level in the trade direction
            string atLvl      = NearFibPivotLevel(price);              // within FibPivotZonePips
            string approachLvl = ZonePendingEnabled
                                 ? FibApproachingLevel(price, tradeDir, ZonePendingPips)
                                 : "";

            if(g_ZonePending && g_ZonePendingDir == tradeDir) {
               // ── Continuing an existing PENDING wait — check if barrier was breached ──
               int barsSince = (int)((TimeCurrent() - g_ZonePendingStartTime)
                                     / PeriodSeconds(PERIOD_M15));
               double recentRange = iHigh(_Symbol, PERIOD_M15, 1) - iLow(_Symbol, PERIOD_M15, 1);
               bool momentumOK   = (g_ATR > 0 && recentRange >= g_ATR * 0.30);
               double pendLvlPx  = FibLevelPrice(g_ZonePendingLevel);
               bool levelBroken  = false;
               if(pendLvlPx > 0) {
                  double tol = FibPivotZonePips * _Point * 10.0;
                  levelBroken = (tradeDir == 1) ? (price >= pendLvlPx - tol)
                                                : (price <= pendLvlPx + tol);
               } else {
                  levelBroken = true;   // level data gone — let it through
               }
               if(levelBroken && momentumOK) {
                  Print("ZONE PENDING RESOLVED: ", g_ZonePendingLevel,
                        " breached + momentum (", DoubleToString(recentRange * 10000, 1),
                        " pip range vs ATR=", DoubleToString(g_ATR * 10000, 1),
                        ") after ", barsSince, " bars — CAUTION entry");
                  g_ZonePending     = false;
                  g_ZoneContextUsed = true;
                  // fall through to trade
               } else if(barsSince >= ZonePendingMaxBars) {
                  string expReason = levelBroken ? "level reached but no momentum"
                                                 : g_ZonePendingLevel + " not yet breached";
                  Print("ZONE PENDING EXPIRED after ", barsSince, " bars — ", expReason, " — resetting");
                  g_ZonePending = false;
                  return;
               } else {
                  string pndMsg = levelBroken ? "level reached, awaiting momentum"
                                              : ("awaiting " + g_ZonePendingLevel + " breakout");
                  string _br = "ZONE PENDING: " + pndMsg + " (" + IntegerToString(barsSince) +
                               "/" + IntegerToString(ZonePendingMaxBars) +
                               " bars, score=" + IntegerToString(ctxScore) + "/14)";
                  if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
                  return;
               }

            } else if(approachLvl != "" && atLvl == "") {
               // ── Price approaching (but not yet at) a key level — defer entry ──────────
               g_ZonePending          = true;
               g_ZonePendingLevel     = approachLvl;
               g_ZonePendingDir       = tradeDir;
               g_ZonePendingStartTime = TimeCurrent();
               Print("ZONE PENDING SET: ", zone, " zone, score=", ctxScore, "/14",
                     " — approaching ", approachLvl, " within ",
                     DoubleToString(ZonePendingPips, 1),
                     " pips; waiting for breakout + momentum before entry");
               return;

            } else {
               // ── No Fib barrier ahead, or price already at/past level — CAUTION entry ──
               string ctx = "score=" + IntegerToString(ctxScore) + "/14"
                           + (atLvl != "" ? " | at/past " + atLvl : " | no Fib barrier ahead");
               string _br = "ZONE CONTEXT OVERRIDE: " + zone + " — " + ctx + " — CAUTION entry";
               if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
               g_ZoneContextUsed = true;
               // fall through to trade
            }
         }
      } // end if(wouldBlock)
   }

   // === MID-ZONE ENTRY VALIDATION ===
   // Mid-zone trades are allowed BUT require stronger evidence:
   //   1. HA pattern must be clean (no double-sided wicks on confirming candle)
   //   2. ATR must show there is momentum (recent bar range > 30% of ATR)
   //   3. Price must be moving TOWARD the favorable third (not stalling at mid)
   // BOLD BET EXCEPTION: when g_BoldBet is true (MTF aligned + FVG/OB present)
   //   the exhaustion check (consec >= 3) is lifted — we trust the macro map over
   //   the mid-zone caution. The trade is logged as [BOLD BET].
   bool midZoneValidated = true;
   if(zone == "MID_ZONE" && isTrendSignal) {
      // Check confirming candle is clean
      bool cleanConfirm = (tradeDir == 1) ? !IsBottomlessWithTopSpike(1)
                                          : !IsToplessWithBottomSpike(1);
      if(!cleanConfirm) {
         if(g_LastBlockReason != "MID_WICK_INDECISION") {
            Print("MID_ZONE BUY/SELL skipped: confirming candle has opposing wick (indecision)");
            g_LastBlockReason = "MID_WICK_INDECISION";
         }
         return;
      }
      // Check recent bar has momentum (not flat)
      double recentRange = iHigh(_Symbol, PERIOD_M15, 1) - iLow(_Symbol, PERIOD_M15, 1);
      if(g_ATR > 0 && recentRange < g_ATR * 0.25) {
         if(g_LastBlockReason != "MID_NO_MOMENTUM") {
            Print("MID_ZONE trade skipped: recent bar range too small (no momentum) recentRange=",
                  DoubleToString(recentRange*10000,1), "pip ATR=", DoubleToString(g_ATR*10000,1));
            g_LastBlockReason = "MID_NO_MOMENTUM";
         }
         return;
      }
      // Check HA consecutive — mid zone with 3+ same candles (including forming) = exhaustion
      // Bold-bet exception: if MTF aligned + SMC present, bypass the exhaustion block
      bool macroMatchesTrade = (tradeDir == 1 && g_MacroStructLabel == "BULLISH") ||
                                (tradeDir == -1 && g_MacroStructLabel == "BEARISH");
      bool boldBetActive = g_BoldBet && macroMatchesTrade && (g_Confidence >= BoldBetMinConf);
      if(liveConsec >= 3 && !boldBetActive) {
         if(g_LastBlockReason != "MID_EXHAUSTION") {
            Print("MID_ZONE trade skipped: ", liveConsec, " consecutive HA candles incl live (exhausted at mid)");
            g_LastBlockReason = "MID_EXHAUSTION";
         }
         return;
      } else if(liveConsec >= 3 && boldBetActive) {
         Print("[BOLD BET] MID_ZONE exhaustion override: MTF=", g_MacroStructLabel,
               " H1=", g_StructureLabel, " FVG=", g_NearBullFVG || g_NearBearFVG,
               " OB=", (g_BullOB_High > 0 || g_BearOB_High > 0),
               " Conf=", DoubleToString(g_Confidence,1), "% — taking bold position");
      }
   }

   // === MEAN REVERSION ZONE GUARD ===
   if(isMeanRev && zone == "MID_ZONE") {
      Print("Mean rev skipped: price in MID_ZONE, not at extreme");
      return;
   }

   // === BIAS FILTER ===
   bool canBuy  = (g_TotalBias > -2);   // block BUY when STRONG BEAR (bias <= -2)
   bool canSell = (g_TotalBias <  2);   // block SELL when STRONG BULL (bias >= +2)
   if(tradeDir == 1  && !canBuy)  {
      string _br = "BUY blocked by STRONG BEAR bias (" + IntegerToString(g_TotalBias) + ")";
      if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
      return;
   }
   if(tradeDir == -1 && !canSell) {
      string _br = "SELL blocked by STRONG BULL bias (" + IntegerToString(g_TotalBias) + ")";
      if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
      return;
   }

   // === MACRO BOS DIRECTIONAL BLOCK ===
   // When H4 structure has broken (g_MacroBOS=true), a trade against that macro direction
   // is a counter-trend bet against an already-confirmed institutional move.
   // Example: MacroStruct=BEARISH + MacroBOS=true → refuse BUY signals.
   if(MacroBOSHardBlock && g_MacroBOS && UseMacroStructure) {
      bool macroOpposes = (tradeDir ==  1 && g_MacroStructLabel == "BEARISH") ||
                          (tradeDir == -1 && g_MacroStructLabel == "BULLISH");
      if(macroOpposes) {
         // CHoCH exemption: if macro CHoCH points in the trade direction,
         // the BOS is being challenged — allow a cautious reversal entry
         bool _chochExempt = (g_MacroCHoCH && g_MacroCHoCHDir == tradeDir);
         if(!_chochExempt) {
            string _br = "TRADE BLOCKED: MacroBOS=" + g_MacroStructLabel +
                         " — refusing " + (tradeDir == 1 ? "BUY" : "SELL") + " counter-macro trade";
            if(_br != g_LastBlockReason) {
               Print(_br, " (H4 structure confirmed). Set MacroBOSHardBlock=false to override.");
               g_LastBlockReason = _br;
            }
            return;
         }
         Print("[CHoCH OVERRIDE] MacroBOS=", g_MacroStructLabel, " would block ",
               (tradeDir == 1 ? "BUY" : "SELL"),
               " but MacroCHoCH(dir=", g_MacroCHoCHDir, ") grants exemption — proceeding cautiously");
      }
   }

   // === H1 BOS STRUCTURAL COHERENCE GATE ===
   // When H1 structure has confirmed a Break of Structure (BOS), taking a trade in the
   // OPPOSITE direction fights a confirmed intermediate-timeframe move.
   // Example: H1=BULLISH + BOS → block SELL.  H1=BEARISH + BOS → block BUY.
   // Exemptions:
   //  1) H1 CHoCH in the trade direction (reversal underway — H1 structure is challenged)
   //  2) MacroCHoCH in the trade direction (higher-TF reversal overrides H1 continuation)
   if(UseSwingStructure && g_BOSActive) {
      bool h1Opposes = (tradeDir ==  1 && g_StructureLabel == "BEARISH") ||
                       (tradeDir == -1 && g_StructureLabel == "BULLISH");
      if(h1Opposes) {
         bool _h1ChochExempt    = (g_CHoCHActive && g_CHoCHDir == tradeDir);
         bool _macroChochExempt = (g_MacroCHoCH && g_MacroCHoCHDir == tradeDir);
         if(!_h1ChochExempt && !_macroChochExempt) {
            string _br = "TRADE BLOCKED: H1 BOS=" + g_StructureLabel +
                         " — refusing " + (tradeDir == 1 ? "BUY" : "SELL") + " against confirmed H1 structure";
            if(_br != g_LastBlockReason) {
               Print(_br, " | SwingH:", DoubleToString(g_SwingHigh1,5),
                     " SwingL:", DoubleToString(g_SwingLow1,5));
               g_LastBlockReason = _br;
            }
            return;
         }
         if(_h1ChochExempt)
            Print("[H1 CHoCH EXEMPT] H1 BOS=", g_StructureLabel, " would block ",
                  (tradeDir==1?"BUY":"SELL"), " but H1 CHoCH(dir=", g_CHoCHDir, ") exempts");
         else
            Print("[MACRO CHoCH EXEMPT] H1 BOS=", g_StructureLabel, " would block ",
                  (tradeDir==1?"BUY":"SELL"), " but MacroCHoCH(dir=", g_MacroCHoCHDir, ") overrides H1");
      }
   }

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

   // === CHoCH REVERSAL TP REDUCTION ===
   // When trading WITH a CHoCH reversal signal but AGAINST the established macro/H1 trend,
   // scale back TP for a cautious quick-profit target — this is a counter-trend bet.
   g_IsCHoCHReversal = false;
   if(CHoCHReversalTPScale > 0 && CHoCHReversalTPScale < 1.0) {
      bool _macroOpposesTrade = (tradeDir == 1 && g_MacroStructLabel != "BULLISH") ||
                                (tradeDir == -1 && g_MacroStructLabel != "BEARISH");
      bool _macroCHoCHAligned = (g_MacroCHoCH && g_MacroCHoCHDir == tradeDir);
      bool _h1CHoCHAligned    = (g_CHoCH && g_CHoCHDir == tradeDir);
      if((_macroCHoCHAligned || _h1CHoCHAligned) && _macroOpposesTrade) {
         g_IsCHoCHReversal = true;
         double chochTP = baseTpUSD * CHoCHReversalTPScale;
         chochTP = MathMax(chochTP, g_DynamicSL_USD * 1.0);   // floor: at least 1:1 R:R
         Print("[CHoCH REVERSAL TP] $", DoubleToString(baseTpUSD,2),
               " → $", DoubleToString(chochTP,2),
               " (scale=", DoubleToString(CHoCHReversalTPScale*100,0), "%",
               _macroCHoCHAligned ? " MacroCHoCH" : "", _h1CHoCHAligned ? " H1CHoCH" : "", ")");
         baseTpUSD = chochTP;
         g_DynamicTP_USD = baseTpUSD;
      }
   }

   // === BOLD TIER TP OVERRIDE ===
   // Applied after ATR boost. Normal SL always preserved — only TP is adjusted.
   // SMALL_BOLD: target SmallBoldTPPct (75%) of distance from entry to CI boundary.
   //   Chase most of the trend move but leave room so we don't get stopped by late pullback.
   // HUGE_BOLD:  target full CI boundary — trend has multi-factor confirmation.
   if(g_BoldTier == "SMALL_BOLD" || g_BoldTier == "HUGE_BOLD") {
      double ciTarget = (tradeDir == 1) ? g_CIHigh : g_CILow;
      if(ciTarget > 0) {
         double ciDist  = MathAbs(ciTarget - price);
         double ciPips  = ciDist / _Point / 10.0;
         double ciUSD   = ciPips * 0.10;
         double pct     = (g_BoldTier == "HUGE_BOLD") ? 1.0 : SmallBoldTPPct;
         double boldTP  = ciUSD * pct;
         boldTP = MathMax(boldTP, baseTpUSD);   // never less than structural TP
         boldTP = MathMin(boldTP, 8.0);          // safety cap $8/0.01 lot
         if(boldTP != baseTpUSD) {
            Print("[", g_BoldTier, "] TP: $", DoubleToString(baseTpUSD,2),
                  " -> $", DoubleToString(boldTP,2),
                  " (CI=", DoubleToString(ciTarget,5),
                  " dist=", DoubleToString(ciPips,1), "pip pct=", DoubleToString(pct*100,0), "%)");
            baseTpUSD = boldTP;
            g_DynamicTP_USD = baseTpUSD;
         }
      } else if(g_BoldTier == "SMALL_BOLD") {
         // No CI: cap TP at SmallBoldTPPct of standard TP
         double cappedTP = MathMax(baseTpUSD * SmallBoldTPPct, g_DynamicSL_USD * RRRatio * 0.5);
         Print("[SMALL_BOLD] TP capped (no CI): $", DoubleToString(cappedTP,2));
         baseTpUSD = cappedTP;
         g_DynamicTP_USD = baseTpUSD;
      }
      // HUGE_BOLD without CI: use standard TP (structural already the best estimate)
   }

   // === MACRO TREND RIDE SL/TP OVERRIDE ===
   // Fires when CheckMacroTrendRide() armed the setup this bar.
   // Widens SL to give the trend room to breathe and targets the next HTF level
   // (Fib / Pivot / SwingH/L) clamped to [MacroTrendMinTP_USD, MacroTrendMaxTP_USD].
   // This override runs AFTER the BOLD TIER block so it always wins on SL/TP.
   if(isMacroTrend) {
      g_DynamicSL_USD = MacroTrendSL_USD;   // wider SL ($2.75 vs normal $2.50)

      // Find the next key HTF level ahead of price in the trade direction
      double htfTarget = FindNextTargetLevel(price, tradeDir);
      double htfTP = 0;
      if(htfTarget > 0) {
         double htfDist = MathAbs(htfTarget - price);
         double htfPips = htfDist / _Point / 10.0;   // convert points → pips
         htfTP = htfPips * 0.10;                     // $0.10/pip/0.01lot for EURUSD
      }

      // Clamp: if HTF level is within range, use it; else cap at MacroTrendMaxTP_USD
      if(htfTP >= MacroTrendMinTP_USD)
         baseTpUSD = MathMin(htfTP, MacroTrendMaxTP_USD);
      else
         baseTpUSD = MacroTrendMaxTP_USD;   // HTF close or missing — use full cap

      g_DynamicTP_USD = baseTpUSD;
      Print("[MACRO TREND RIDE] SL=$", DoubleToString(MacroTrendSL_USD,2),
            " TP=$", DoubleToString(baseTpUSD,2),
            htfTarget > 0 ? " HTFtarget=" + DoubleToString(htfTarget,5) : " (no HTF level, using cap)",
            " Score=", g_MacroTrendScore, "/14");
   }

   // === MTF / VOLUME DIVERGENCE BLOCK ===
   // Both conditions must fire together to block — either alone is insufficient.
   //   MTF diverged: H4 macro and H1 intermediate point in DIFFERENT directions.
   //   Vol diverged: price trending but tick volume declining (exhaustion signal).
   // When only one diverges, the trade is valid and runs to full TP.
   // Mean-reversion trades are exempt (they already target a short counter-move).
   // Macro trend rides are exempt: CheckMacroTrendRide() already refused to arm when
   // both MTF+Vol diverge, so isMacroTrend=true guarantees at most one divergence.
   g_DivergenceCaution = false;
   if(DivergenceCautionEnabled && !isMeanRev && !isMacroTrend) {
      bool mtfDiverged = !g_MTFAligned;
      bool volDiverged = (UseVolumeAnalysis && g_VolDivergence);
      if(mtfDiverged && volDiverged) {
         string _br = "TRADE BLOCKED: MTF+Volume both diverged";
         if(_br != g_LastBlockReason) {
            Print(_br, " — H4 and H1 disagree AND volume fading.",
                  " Set DivergenceCautionEnabled=false to override.");
            g_LastBlockReason = _br;
         }
         g_DivergenceCaution = true;
         return;
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
   string tag = isMacroTrend  ? (tradeDir==1 ? "MACRO_RIDE_BUY" : "MACRO_RIDE_SELL")
                : isMeanRev    ? (tradeDir==1 ? "MRV_BUY"        : "MRV_SELL")
                               : (tradeDir==1 ? "HA_BUY_v6"      : "HA_SELL_v6");
   if(HAEntryMode == 1 || isMacroTrend) tag = tag + "_E";
   if(g_DivergenceCaution)  tag = tag + "_DV";   // divergence-caution marker
   tag = tag + "_C" + confStr
             + "_SL" + DoubleToString(g_DynamicSL_USD, 2)
             + "_TP" + DoubleToString(g_DynamicTP_USD, 2);

   // === EXECUTE ===
   g_LastBlockReason = "";   // block cleared — trade is actually firing
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
      g_TroughProfit  = 0;
      g_BarsSincePeak = 0;
      g_TradeDir      = tradeDir;
      g_OpenBarCount  = 0;
      g_TradeOpenTime = TimeCurrent();
      g_IsNearMid     = isMidContext;
      g_IsMeanRev     = isMeanRev;
      g_Signal        = "WAITING";
      g_HABullSetup   = false;
      g_HABearSetup   = false;
      g_MRVArmed      = false;
      g_MRVConfirmOpen = 0;
      g_EntryStructLabel = g_StructureLabel;
      g_EntryMacroLabel  = g_MacroStructLabel;
      g_EarlyLockEngaged = false;
      g_StructShiftCount = 0;
      g_LastMgmtAction   = "";
      g_TradeMgmtModeName = (TradeMgmtMode == 0) ? "STANDARD" :
                             (TradeMgmtMode == 1) ? "SENTINEL" :
                             (TradeMgmtMode == 2) ? "MOMENTUM" :
                             (TradeMgmtMode == 3) ? "ADAPTIVE" :
                             (TradeMgmtMode == 4) ? "HARVESTER" : "CHRONO";
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
   g_ScaledLockUSD  = g_DynamicTP_USD * LockPct * scale;   // lock at LockPct of TP
   g_ScaledTrailUSD = g_DynamicTP_USD * TrailPct * scale;   // trail gap = TrailPct of TP
}

//+------------------------------------------------------------------+
//| RESET TRADE GLOBALS — centralised cleanup on any trade close     |
//| Called from ManageOpenTrade exits and FridayClose                |
//+------------------------------------------------------------------+
void ResetTradeGlobals(double closePnL)
{
   RecordTradeResult(closePnL);
   g_TradeOpen        = false;
   g_ProfitLocked     = false;
   g_PeakProfit       = 0;
   g_TroughProfit     = 0;
   g_BarsSincePeak    = 0;
   g_TradeDir         = 0;
   g_OpenBarCount     = 0;
   g_Signal           = "WAITING";
   g_EntryStructLabel = "";
   g_EntryMacroLabel  = "";
   g_EarlyLockEngaged = false;
   g_StructShiftCount = 0;
   g_LastMgmtAction   = "";
}

//+------------------------------------------------------------------+
//| TRADE MANAGEMENT v10 — 6-MODE SYSTEM                             |
//| Modes: STANDARD(0), SENTINEL(1), MOMENTUM(2), ADAPTIVE(3),     |
//|        HARVESTER(4), CHRONO(5)                                  |
//|                                                                  |
//| All modes share:                                                 |
//|   - Hard MaxLossUSD cap (absolute safety net)                   |
//|   - Mid-range stall exit (disabled by default)                  |
//|   - Max hold bars exit (loss-only safety net)                   |
//|                                                                  |
//| MODE 0 — STANDARD: Classic lock at LockPct, trail at TrailPct.  |
//| MODE 1 — SENTINEL: Early 40% TP lock, tighter 15% trail,       |
//|          time-decay exit when profit dwindles.                  |
//| MODE 2 — MOMENTUM: Structure-informed. Widens trail on aligned  |
//|          BOS, tightens on adverse CHoCH. Balanced approach.     |
//| MODE 3 — ADAPTIVE: Full smart. Peak/trough tracking, dwindling  |
//|          detection, structure exits, graduated protection.      |
//| MODE 4 — HARVESTER: Profit-tier slasher. Closes at $1/$1.5/$2  |
//|          per 0.01 lot based on structure/momentum context.      |
//|          Quick materialisation — slashes once a tier is hit.    |
//| MODE 5 — CHRONO: Session-aware hybrid. Auto-selects sub-mode   |
//|          based on the current hour:                             |
//|          Early Asian / Late NY → HARVEST slash ($1-$1.50)       |
//|          Mid Asian / London / NY → ADAPTIVE (ride with struct)  |
//|          London-NY overlap → MOMENTUM (wide trail, full ride)   |
//+------------------------------------------------------------------+
void ManageOpenTrade()
{
   if(!g_TradeOpen) return;

   // --- Locate our position ---
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
      Print("Position closed by broker (SL/TP) | P&L=$", DoubleToString(closedPnL, 2));
      ResetTradeGlobals(closedPnL);
      return;
   }

   double profit = posInfo.Commission() + posInfo.Swap() + posInfo.Profit();
   double scale  = g_CurrentLot / 0.01;

   // --- Track peak and trough ---
   if(profit > g_PeakProfit) {
      g_PeakProfit    = profit;
      g_BarsSincePeak = 0;   // reset on new peak
   }
   if(profit < g_TroughProfit)
      g_TroughProfit = profit;

   // --- Detect structure shift during trade (for MOMENTUM/ADAPTIVE) ---
   // Count when H1 structure label changes from what it was at entry or last check
   {
      string currentStruct = g_StructureLabel;
      if(g_EntryStructLabel != "" && currentStruct != g_EntryStructLabel) {
         // Structure has shifted from entry — update tracker
         // We only count once per direction change, not continuous
         static string s_lastCheckedStruct = "";
         if(currentStruct != s_lastCheckedStruct) {
            g_StructShiftCount++;
            s_lastCheckedStruct = currentStruct;
         }
      }
   }

   // --- Resolve effective mode ---
   int mode = TradeMgmtMode;
   if(mode < 0 || mode > 5) mode = 0;

   // === HARD LOSS CAP — MaxLossUSD per 0.01 lot, ALWAYS (all modes) ===
   double hardLossLimit = -(MaxLossUSD * scale);
   if(profit <= hardLossLimit) {
      Print("HARD LOSS CAP triggered: profit=$", DoubleToString(profit,2),
            " limit=$", DoubleToString(hardLossLimit,2));
      trade.PositionClose(posInfo.Ticket());
      ResetTradeGlobals(profit);
      return;
   }

   // === MID-RANGE STALL EXIT (optional — disabled by default, all modes) ===
   if(MidRangeStallUSD > 0 && g_IsNearMid && !g_ProfitLocked) {
      if(g_OpenBarCount >= MidRangeMaxBars) {
         double midStallLimit = MidRangeStallUSD * scale;
         if(profit < midStallLimit) {
            Print("STALL exit: open ", g_OpenBarCount, " bars profit=$",
                  DoubleToString(profit,2), " (below $", DoubleToString(midStallLimit,2), ")");
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }
      }
   }

   // === MAX HOLD TIME EXIT (loss-only safety net, all modes) ===
   if(g_OpenBarCount >= MaxHoldBars) {
      if(profit < 0) {
         Print("MAX HOLD exit after ", g_OpenBarCount, "/", MaxHoldBars,
               " bars (IN LOSS) | profit=$", DoubleToString(profit,2));
         trade.PositionClose(posInfo.Ticket());
         ResetTradeGlobals(profit);
         return;
      }
   }

   // ================================================================
   //  MODE-SPECIFIC LOCK & TRAIL LOGIC
   // ================================================================

   if(mode == 0) {
      // === MODE 0: STANDARD ===
      // Classic lock/trail. Lock at LockPct of TP, trail at TrailPct of TP.
      if(!g_ProfitLocked && profit >= g_ScaledLockUSD) {
         g_ProfitLocked = true;
         g_LastMgmtAction = "LOCK@" + DoubleToString(profit,2);
         Print("[STANDARD] PROFIT LOCK at $", DoubleToString(profit,2),
               " lock=$", DoubleToString(g_ScaledLockUSD,2));
      }
      if(g_ProfitLocked && profit < g_PeakProfit - g_ScaledTrailUSD) {
         g_LastMgmtAction = "TRAIL_CLOSE";
         Print("[STANDARD] TRAILING CLOSE: peak=$", DoubleToString(g_PeakProfit,2),
               " now=$", DoubleToString(profit,2), " trail=$", DoubleToString(g_ScaledTrailUSD,2));
         trade.PositionClose(posInfo.Ticket());
         ResetTradeGlobals(profit);
      }

   } else if(mode == 1) {
      // === MODE 1: SENTINEL (conservative guardian) ===
      // Early lock at 40% of TP, tight trail at 15% of TP.
      // Time-decay: if profit dwindled for >12 bars after a significant peak, cut.
      double earlyLockUSD  = g_DynamicTP_USD * 0.40 * scale;   // lock at 40% of TP
      double tightTrailUSD = g_DynamicTP_USD * 0.15 * scale;   // trail gap = 15% of TP

      // Early lock engagement
      if(!g_EarlyLockEngaged && profit >= earlyLockUSD) {
         g_EarlyLockEngaged = true;
         g_LastMgmtAction = "EARLY_LOCK@" + DoubleToString(profit,2);
         Print("[SENTINEL] EARLY LOCK at $", DoubleToString(profit,2),
               " threshold=$", DoubleToString(earlyLockUSD,2));
      }
      // Standard lock (higher threshold)
      if(!g_ProfitLocked && profit >= g_ScaledLockUSD) {
         g_ProfitLocked = true;
         g_LastMgmtAction = "FULL_LOCK@" + DoubleToString(profit,2);
         Print("[SENTINEL] FULL LOCK at $", DoubleToString(profit,2));
      }

      // Time-decay exit: peak was significant but profit has been dwindling
      // Fires when: had meaningful profit (>40% TP), now below 50% of peak, 12+ bars since peak
      if(g_EarlyLockEngaged && g_BarsSincePeak >= 12 && g_PeakProfit > earlyLockUSD) {
         if(profit < g_PeakProfit * 0.50 && profit > 0) {
            g_LastMgmtAction = "TIME_DECAY_EXIT";
            Print("[SENTINEL] TIME DECAY: peak=$", DoubleToString(g_PeakProfit,2),
                  " now=$", DoubleToString(profit,2), " bars_since_peak=", g_BarsSincePeak,
                  " — profit dwindled too long, protecting capital");
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }
      }

      // Structure reversal exit: H1 CHoCH against trade → tighten immediately
      bool structAgainst = false;
      if(g_CHoCHActive && g_CHoCHDir != 0 && g_CHoCHDir != g_TradeDir)
         structAgainst = true;
      if(g_BOSActive && g_StructureLabel != "" && g_EntryStructLabel != "" && g_StructureLabel != g_EntryStructLabel) {
         // BOS now confirms opposite direction to entry
         bool bosAgainst = (g_TradeDir == 1 && g_StructureLabel == "BEARISH") ||
                           (g_TradeDir == -1 && g_StructureLabel == "BULLISH");
         if(bosAgainst) structAgainst = true;
      }

      // Trailing close with tighter trail when early-locked
      double activeTrail = g_EarlyLockEngaged ? tightTrailUSD : g_ScaledTrailUSD;
      if(structAgainst && g_EarlyLockEngaged) {
         // Structure turned against us — use even tighter trail (10% of TP)
         activeTrail = g_DynamicTP_USD * 0.10 * scale;
         g_LastMgmtAction = "STRUCT_TIGHTEN";
      }

      if(g_EarlyLockEngaged && profit < g_PeakProfit - activeTrail && profit > 0) {
         g_LastMgmtAction = "SENTINEL_TRAIL";
         Print("[SENTINEL] TRAIL CLOSE: peak=$", DoubleToString(g_PeakProfit,2),
               " now=$", DoubleToString(profit,2), " trail=$", DoubleToString(activeTrail,2),
               structAgainst ? " (struct against!)" : "");
         trade.PositionClose(posInfo.Ticket());
         ResetTradeGlobals(profit);
         return;
      }
      // Also respect standard lock/trail if engaged
      if(g_ProfitLocked && profit < g_PeakProfit - tightTrailUSD) {
         g_LastMgmtAction = "SENTINEL_FULL_TRAIL";
         Print("[SENTINEL] FULL TRAIL CLOSE: peak=$", DoubleToString(g_PeakProfit,2),
               " now=$", DoubleToString(profit,2));
         trade.PositionClose(posInfo.Ticket());
         ResetTradeGlobals(profit);
      }

   } else if(mode == 2) {
      // === MODE 2: MOMENTUM (structure-informed, balanced) ===
      // Lock at 50% of TP, trail at 25% normally.
      // BOS with trade → widen trail to 40% of TP (let it run).
      // CHoCH against trade → tighten trail to 12% of TP (protect).
      double momLockUSD  = g_DynamicTP_USD * 0.50 * scale;
      double baseTrail   = g_DynamicTP_USD * 0.25 * scale;
      double wideTrail   = g_DynamicTP_USD * 0.40 * scale;
      double tightTrail  = g_DynamicTP_USD * 0.12 * scale;

      // Assess current structural alignment
      bool structWithTrade    = false;
      bool structAgainstTrade = false;

      // H1 BOS in trade direction → strong continuation signal
      if(g_BOSActive) {
         if((g_TradeDir == 1 && g_StructureLabel == "BULLISH") ||
            (g_TradeDir == -1 && g_StructureLabel == "BEARISH"))
            structWithTrade = true;
         if((g_TradeDir == 1 && g_StructureLabel == "BEARISH") ||
            (g_TradeDir == -1 && g_StructureLabel == "BULLISH"))
            structAgainstTrade = true;
      }
      // H1 CHoCH against trade → reversal warning
      if(g_CHoCHActive && g_CHoCHDir != 0 && g_CHoCHDir != g_TradeDir)
         structAgainstTrade = true;
      // Macro still with trade → confidence boost
      bool macroAligned = (g_TradeDir == 1 && g_MacroStructLabel == "BULLISH") ||
                          (g_TradeDir == -1 && g_MacroStructLabel == "BEARISH");

      // Select active trail width based on structure
      double activeTrail = baseTrail;
      if(structWithTrade && macroAligned)  activeTrail = wideTrail;    // both aligned → let it breathe
      else if(structWithTrade)             activeTrail = baseTrail;     // H1 with us, macro neutral
      else if(structAgainstTrade)          activeTrail = tightTrail;    // under threat → protect

      // Lock engagement at 50% of TP
      if(!g_ProfitLocked && profit >= momLockUSD) {
         g_ProfitLocked = true;
         g_LastMgmtAction = "MOM_LOCK@" + DoubleToString(profit,2);
         Print("[MOMENTUM] LOCK at $", DoubleToString(profit,2),
               " struct:", (structWithTrade ? "WITH" : structAgainstTrade ? "AGAINST" : "NEUTRAL"),
               " macro:", (macroAligned ? "ALIGNED" : "—"));
      }

      // Trailing close
      if(g_ProfitLocked && profit < g_PeakProfit - activeTrail) {
         g_LastMgmtAction = "MOM_TRAIL";
         Print("[MOMENTUM] TRAIL CLOSE: peak=$", DoubleToString(g_PeakProfit,2),
               " now=$", DoubleToString(profit,2), " trail=$", DoubleToString(activeTrail,2),
               " struct:", (structWithTrade ? "WITH" : structAgainstTrade ? "AGAINST" : "NEUTRAL"));
         trade.PositionClose(posInfo.Ticket());
         ResetTradeGlobals(profit);
      }

   } else if(mode == 3) {
      // === MODE 3: ADAPTIVE (full smart) ===
      // Graduated protection with three tiers:
      //   Tier 1: Early protection at 35% of TP with a medium trail
      //   Tier 2: Standard lock at LockPct of TP with structure-adjusted trail
      //   Tier 3: Extended run when profit > TP and structure supports it
      //
      // Dwindling detection: if profit reached significant peak but has been
      // oscillating/declining for many bars, accept the trade has stalled.
      //
      // Structure exits: H1 BOS/CHoCH during trade dynamically adjusts protection.

      double earlyLockUSD = g_DynamicTP_USD * 0.35 * scale;   // Tier 1: 35% of TP
      double stdLockUSD   = g_ScaledLockUSD;                   // Tier 2: standard LockPct
      double tpUSD        = g_ScaledTPUSD;                     // full TP for reference

      // --- Structural assessment ---
      bool structWith    = false;
      bool structAgainst = false;
      bool macroAligned  = (g_TradeDir == 1 && g_MacroStructLabel == "BULLISH") ||
                           (g_TradeDir == -1 && g_MacroStructLabel == "BEARISH");

      if(g_BOSActive) {
         if((g_TradeDir == 1 && g_StructureLabel == "BULLISH") ||
            (g_TradeDir == -1 && g_StructureLabel == "BEARISH"))
            structWith = true;
         if((g_TradeDir == 1 && g_StructureLabel == "BEARISH") ||
            (g_TradeDir == -1 && g_StructureLabel == "BULLISH"))
            structAgainst = true;
      }
      if(g_CHoCHActive && g_CHoCHDir != 0 && g_CHoCHDir != g_TradeDir)
         structAgainst = true;
      // Macro CHoCH against trade = high-confidence reversal signal
      bool macroCHoCHAgainst = (g_MacroCHoCH && g_MacroCHoCHDir != 0 && g_MacroCHoCHDir != g_TradeDir);

      // --- Tier 1: Early protection ---
      if(!g_EarlyLockEngaged && profit >= earlyLockUSD) {
         g_EarlyLockEngaged = true;
         g_LastMgmtAction = "ADAPT_EARLY@" + DoubleToString(profit,2);
         Print("[ADAPTIVE] TIER1 EARLY LOCK at $", DoubleToString(profit,2),
               " (35% of TP=$", DoubleToString(earlyLockUSD,2), ")");
      }
      // --- Tier 2: Standard lock ---
      if(!g_ProfitLocked && profit >= stdLockUSD) {
         g_ProfitLocked = true;
         g_LastMgmtAction = "ADAPT_LOCK@" + DoubleToString(profit,2);
         Print("[ADAPTIVE] TIER2 STANDARD LOCK at $", DoubleToString(profit,2));
      }

      // --- Calculate adaptive trail width ---
      // Base: 25% of TP. Adjusted by structure:
      //   +aligned BOS & macro: 40% (give room to run)
      //   +aligned BOS only:    30%
      //   +struct against:      12% (protect fast)
      //   +macro CHoCH against: 10% (high-urgency protect)
      //   +profit > TP:         45% (running hot — let it extend)
      double adaptiveTrail;
      if(macroCHoCHAgainst)                    adaptiveTrail = g_DynamicTP_USD * 0.10 * scale;
      else if(structAgainst)                   adaptiveTrail = g_DynamicTP_USD * 0.12 * scale;
      else if(profit >= tpUSD && structWith)   adaptiveTrail = g_DynamicTP_USD * 0.45 * scale;
      else if(structWith && macroAligned)       adaptiveTrail = g_DynamicTP_USD * 0.40 * scale;
      else if(structWith)                      adaptiveTrail = g_DynamicTP_USD * 0.30 * scale;
      else                                     adaptiveTrail = g_DynamicTP_USD * 0.25 * scale;

      // --- Dwindling detection ---
      // If: (a) reached meaningful profit (>35% of TP),
      //     (b) profit declined to <50% of peak for >10 bars,
      //     (c) not currently ripping to new highs → trade has stalled, cut it
      bool dwindling = false;
      if(g_EarlyLockEngaged && g_PeakProfit > earlyLockUSD && profit > 0) {
         if(g_BarsSincePeak >= 10 && profit < g_PeakProfit * 0.50) {
            dwindling = true;
         }
         // Extended dwindling: if >20 bars since peak and below 70% of peak
         if(g_BarsSincePeak >= 20 && profit < g_PeakProfit * 0.70) {
            dwindling = true;
         }
      }

      // --- Structure-accelerated exit ---
      // If structure both CHoCH'd against trade AND profit is declining → urgent cut
      bool structUrgent = structAgainst && g_EarlyLockEngaged && profit < g_PeakProfit * 0.65;

      // --- Execute dwindling or structure-urgent exit ---
      if(dwindling || structUrgent) {
         string reason = dwindling ? "DWINDLING" : "STRUCT_URGENT";
         g_LastMgmtAction = reason;
         Print("[ADAPTIVE] ", reason, " EXIT: peak=$", DoubleToString(g_PeakProfit,2),
               " now=$", DoubleToString(profit,2),
               " bars_since_peak=", g_BarsSincePeak,
               " struct:", (structWith ? "WITH" : structAgainst ? "AGAINST" : "NEUTRAL"),
               " macro:", (macroAligned ? "ALIGNED" : macroCHoCHAgainst ? "CHoCH_AGAINST" : "—"));
         trade.PositionClose(posInfo.Ticket());
         ResetTradeGlobals(profit);
         return;
      }

      // --- Trailing close (applies after early lock or standard lock) ---
      if(g_EarlyLockEngaged || g_ProfitLocked) {
         if(profit < g_PeakProfit - adaptiveTrail && profit > 0) {
            g_LastMgmtAction = "ADAPT_TRAIL";
            Print("[ADAPTIVE] TRAIL CLOSE: peak=$", DoubleToString(g_PeakProfit,2),
                  " now=$", DoubleToString(profit,2),
                  " trail=$", DoubleToString(adaptiveTrail,2),
                  " struct:", (structWith ? "WITH" : structAgainst ? "AGAINST" : "NEUTRAL"),
                  " tier:", (g_ProfitLocked ? "FULL" : "EARLY"));
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }
      }

      // --- Time decay (ADAPTIVE specific): very long holds with modest profit ---
      // After 32 bars (8 hours), if profit hasn't reached standard lock → progressive close
      if(g_OpenBarCount >= 32 && profit > 0 && !g_ProfitLocked) {
         double minAcceptable = earlyLockUSD * 0.60;   // at least 21% of TP after 8 hours
         if(profit < minAcceptable) {
            g_LastMgmtAction = "TIME_DECAY_STALL";
            Print("[ADAPTIVE] TIME DECAY: ", g_OpenBarCount, " bars, profit=$",
                  DoubleToString(profit,2), " below min acceptable $",
                  DoubleToString(minAcceptable,2), " — closing stalled trade");
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }
      }

   } else if(mode == 4) {
      // === MODE 4: HARVESTER (profit-tier slasher) ===
      // Philosophy: entries are strong — materialise profits at fixed dollar
      // thresholds instead of trailing.  The TARGET tier is selected once when
      // profit first reaches the base ($1.00/0.01 lot), informed by current
      // structure, macro alignment, and momentum.  Once the tier is hit the
      // trade is immediately "slashed" (closed).
      //
      // Tiers (per 0.01 lot, scaled to actual lot):
      //   QUICK  = $1.00   — structure against / neutral, dwindling risk
      //   MID    = $1.50   — partial alignment (one of H1 BOS or macro)
      //   FULL   = $2.00   — strong alignment (H1 BOS with + macro aligned)
      //
      // Safety nets:
      //   - If profit reached 85%+ of base tier then drops back 30%+ from
      //     peak within 6 bars → protect gains (don't let $0.90 → $0)
      //   - Dwindling: reached tier but stalling → close immediately

      double hvBase = 1.00 * scale;     // $1.00 per 0.01 lot
      double hvMid  = 1.50 * scale;     // $1.50 per 0.01 lot
      double hvFull = 2.00 * scale;     // $2.00 per 0.01 lot

      // --- Structural assessment ---
      bool hvStructWith    = false;
      bool hvStructAgainst = false;
      bool hvMacroAligned  = (g_TradeDir == 1 && g_MacroStructLabel == "BULLISH") ||
                             (g_TradeDir == -1 && g_MacroStructLabel == "BEARISH");

      if(g_BOSActive) {
         if((g_TradeDir == 1 && g_StructureLabel == "BULLISH") ||
            (g_TradeDir == -1 && g_StructureLabel == "BEARISH"))
            hvStructWith = true;
         if((g_TradeDir == 1 && g_StructureLabel == "BEARISH") ||
            (g_TradeDir == -1 && g_StructureLabel == "BULLISH"))
            hvStructAgainst = true;
      }
      if(g_CHoCHActive && g_CHoCHDir != 0 && g_CHoCHDir != g_TradeDir)
         hvStructAgainst = true;
      bool hvMacroCHoCH = (g_MacroCHoCH && g_MacroCHoCHDir != 0 && g_MacroCHoCHDir != g_TradeDir);

      // --- Select harvest tier based on current context ---
      double harvestTarget = hvBase;   // default: quick harvest
      string tierLabel     = "QUICK";

      if(hvStructWith && hvMacroAligned && !hvMacroCHoCH) {
         harvestTarget = hvFull;       // both aligned → max $2.00
         tierLabel     = "FULL";
      } else if((hvStructWith || hvMacroAligned) && !hvStructAgainst) {
         harvestTarget = hvMid;        // one aligned → mid $1.50
         tierLabel     = "MID";
      }
      // Force quick if structure actively against trade
      if(hvStructAgainst || hvMacroCHoCH) {
         harvestTarget = hvBase;
         tierLabel     = "QUICK";
      }

      // Update dashboard with target info
      if(profit < hvBase && g_LastMgmtAction == "")
         g_LastMgmtAction = "TARGET:" + tierLabel + "($" + DoubleToString(harvestTarget / scale, 2) + ")";

      // --- SLASH: profit hit the selected tier → close immediately ---
      if(profit >= harvestTarget) {
         g_LastMgmtAction = "SLASH_" + tierLabel;
         Print("[HARVESTER] SLASH ", tierLabel, " at $", DoubleToString(profit, 2),
               " target=$", DoubleToString(harvestTarget, 2),
               " struct:", (hvStructWith ? "WITH" : hvStructAgainst ? "AGAINST" : "NEUTRAL"),
               " macro:", (hvMacroAligned ? "ALIGNED" : hvMacroCHoCH ? "CHoCH_AGT" : "---"));
         trade.PositionClose(posInfo.Ticket());
         ResetTradeGlobals(profit);
         return;
      }

      // --- Step-down: if targeting MID/FULL but structure turns against → slash at base ---
      if(harvestTarget > hvBase && profit >= hvBase && hvStructAgainst) {
         g_LastMgmtAction = "SLASH_DOWNGRADE";
         Print("[HARVESTER] DOWNGRADE SLASH: target was ", tierLabel,
               " but struct turned against — closing at $", DoubleToString(profit, 2));
         trade.PositionClose(posInfo.Ticket());
         ResetTradeGlobals(profit);
         return;
      }

      // --- Safety net: profit reached near-base (85%+) but dwindling back ---
      // Protect: don't let a $0.85+ profit turn into a loss
      double nearBaseThresh = hvBase * 0.85;   // $0.85 per 0.01 lot
      if(g_PeakProfit >= nearBaseThresh && profit > 0) {
         // Peak was near/above $1 — monitor for pullback
         if(g_BarsSincePeak >= 6 && profit < g_PeakProfit * 0.70) {
            g_LastMgmtAction = "HARVEST_PROTECT";
            Print("[HARVESTER] PROTECT: peak=$", DoubleToString(g_PeakProfit, 2),
                  " now=$", DoubleToString(profit, 2),
                  " bars_since_peak=", g_BarsSincePeak,
                  " — profit dwindling before tier, protecting gains");
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }
      }

      // --- Extended dwindling: reached base tier but now sinking ---
      // Reached $1+ but has been declining for 8+ bars and below 60% of peak
      if(g_PeakProfit >= hvBase && g_BarsSincePeak >= 8 && profit > 0) {
         if(profit < g_PeakProfit * 0.60) {
            g_LastMgmtAction = "HARVEST_DWINDLE";
            Print("[HARVESTER] DWINDLE EXIT: peak=$", DoubleToString(g_PeakProfit, 2),
                  " now=$", DoubleToString(profit, 2),
                  " — profit decaying after reaching $1+ zone");
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }
      }

   } else {
      // === MODE 5: CHRONO (session-aware hybrid) ===
      // Philosophy: different sessions have different pip potential.
      // The mode auto-selects a sub-strategy based on the CURRENT hour:
      //
      //  EARLY ASIAN (hour 0-3):  Low volatility → aggressive HARVEST slash.
      //     Close at $1.00-$1.50 per 0.01 lot depending on bar acceleration.
      //
      //  MID/LATE ASIAN (hour 3-7):  Trade may carry into London →
      //     ADAPTIVE sub-mode (structure-informed, let it ride if aligned).
      //
      //  LONDON OPEN (hour 8-12):  Peak volatility → ADAPTIVE sub-mode,
      //     wider trails, structure-informed.  Ride the London move.
      //
      //  LONDON-NY OVERLAP (hour 13-16):  Maximum liquidity →
      //     MOMENTUM sub-mode (structure-adjusted trail widths).
      //
      //  NY ACTIVE (hour 17-19):  Moderate activity → ADAPTIVE sub-mode.
      //
      //  LATE NY / OFF-HOURS (hour 20-23):  Dying liquidity →
      //     aggressive HARVEST slash.  Don't hold into the void.
      //
      //  All hours respect session inputs (AsianStartHour etc.) for phase
      //  boundaries.  Bar-height acceleration adjusts slash aggressiveness.

      MqlDateTime cdt;
      TimeToStruct(TimeCurrent(), cdt);
      int ch = cdt.hour;

      // --- Measure recent bar acceleration (avg of last 3 closed M15 bar ranges vs ATR) ---
      double avgBarRange = 0;
      for(int bi = 1; bi <= 3; bi++)
         avgBarRange += iHigh(_Symbol, PERIOD_M15, bi) - iLow(_Symbol, PERIOD_M15, bi);
      avgBarRange /= 3.0;
      double accelRatio = (g_ATR > 0) ? (avgBarRange / g_ATR) : 0.5;
      // accelRatio > 1.0 = bars bigger than ATR (strong movement)
      // accelRatio < 0.5 = bars small (sluggish market)

      // --- Structural assessment (shared across sub-modes) ---
      bool crStructWith    = false;
      bool crStructAgainst = false;
      bool crMacroAligned  = (g_TradeDir == 1 && g_MacroStructLabel == "BULLISH") ||
                             (g_TradeDir == -1 && g_MacroStructLabel == "BEARISH");
      if(g_BOSActive) {
         if((g_TradeDir == 1 && g_StructureLabel == "BULLISH") ||
            (g_TradeDir == -1 && g_StructureLabel == "BEARISH"))
            crStructWith = true;
         if((g_TradeDir == 1 && g_StructureLabel == "BEARISH") ||
            (g_TradeDir == -1 && g_StructureLabel == "BULLISH"))
            crStructAgainst = true;
      }
      if(g_CHoCHActive && g_CHoCHDir != 0 && g_CHoCHDir != g_TradeDir)
         crStructAgainst = true;
      bool crMacroCHoCH = (g_MacroCHoCH && g_MacroCHoCHDir != 0 && g_MacroCHoCHDir != g_TradeDir);

      // --- Determine session phase ---
      // "SLASH" = harvest-style quick cut,  "RIDE" = adaptive/momentum trailing
      string chronoPhase = "RIDE";    // default
      string chronoSub   = "ADAPT";   // default sub-strategy label

      bool isEarlyAsian    = (ch >= AsianStartHour && ch < AsianStartHour + 3);
      bool isMidLateAsian  = (ch >= AsianStartHour + 3 && ch < AsianEndHour);
      bool isLondonOpen    = (ch >= LondonStartHour && ch < LondonStartHour + 5);
      bool isOverlap       = (ch >= NewYorkStartHour && ch < LondonEndHour);
      bool isNYActive      = (ch >= LondonEndHour && ch < NewYorkEndHour - 2);
      bool isLateNY        = (ch >= NewYorkEndHour - 2 && ch < NewYorkEndHour);
      bool isOffHours      = (ch >= NewYorkEndHour || ch < AsianStartHour);

      if(isEarlyAsian || isLateNY || isOffHours) {
         chronoPhase = "SLASH";
         chronoSub   = "HARVEST";
      } else if(isOverlap) {
         chronoPhase = "RIDE";
         chronoSub   = "MOMENTUM";
      } else if(isLondonOpen || isMidLateAsian || isNYActive) {
         chronoPhase = "RIDE";
         chronoSub   = "ADAPT";
      }

      // Update dashboard with current phase
      if(g_LastMgmtAction == "" || StringFind(g_LastMgmtAction, "PHASE:") == 0)
         g_LastMgmtAction = "PHASE:" + chronoSub + " @H" + IntegerToString(ch);

      // ===================================================
      //  SLASH sub-mode (early Asian, late NY, off-hours)
      // ===================================================
      if(chronoPhase == "SLASH") {
         // Slash tiers scaled by bar acceleration:
         //   Sluggish (accel < 0.5) → slash at $1.00 (take what you can)
         //   Normal  (0.5 - 1.0)    → slash at $1.00-$1.30 depending on struct
         //   Fast    (accel > 1.0)   → slash at $1.50 (market has legs)
         double slashTarget;
         string slashLabel;

         if(accelRatio > 1.0 && (crStructWith || crMacroAligned)) {
            slashTarget = 1.50 * scale;
            slashLabel  = "FAST";
         } else if(accelRatio >= 0.5 && crStructWith && !crStructAgainst) {
            slashTarget = 1.30 * scale;
            slashLabel  = "NORM+";
         } else {
            slashTarget = 1.00 * scale;
            slashLabel  = "QUICK";
         }

         // Slash when target hit
         if(profit >= slashTarget) {
            g_LastMgmtAction = "CR_SLASH_" + slashLabel;
            Print("[CHRONO] SLASH ", slashLabel, " at $", DoubleToString(profit, 2),
                  " target=$", DoubleToString(slashTarget, 2),
                  " accel=", DoubleToString(accelRatio, 2),
                  " hour=", ch, " phase=SLASH");
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }

         // Protect: peak near target (80%+) but fading 5+ bars
         if(g_PeakProfit >= slashTarget * 0.80 && profit > 0) {
            if(g_BarsSincePeak >= 5 && profit < g_PeakProfit * 0.70) {
               g_LastMgmtAction = "CR_SLASH_PROTECT";
               Print("[CHRONO] SLASH PROTECT: peak=$", DoubleToString(g_PeakProfit, 2),
                     " now=$", DoubleToString(profit, 2), " fading ", g_BarsSincePeak, " bars");
               trade.PositionClose(posInfo.Ticket());
               ResetTradeGlobals(profit);
               return;
            }
         }

         // Structure-against + reached $0.70+: don't wait → take it
         if(crStructAgainst && profit >= 0.70 * scale) {
            g_LastMgmtAction = "CR_SLASH_STRUCT_AGT";
            Print("[CHRONO] SLASH on struct against: profit=$", DoubleToString(profit, 2),
                  " in low-liquidity phase + adverse structure");
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }

      // ===================================================
      //  RIDE sub-mode: MOMENTUM (London-NY overlap)
      // ===================================================
      } else if(chronoSub == "MOMENTUM") {
         // Overlap is the highest-liquidity window.  Use momentum-style:
         // wider trails when structure supports, tighter when against.
         double crMomLock   = g_DynamicTP_USD * 0.50 * scale;
         double crBaseTrail = g_DynamicTP_USD * 0.25 * scale;
         double crWideTrail = g_DynamicTP_USD * 0.40 * scale;
         double crTightTrail= g_DynamicTP_USD * 0.12 * scale;

         double crTrail = crBaseTrail;
         if(crStructWith && crMacroAligned)     crTrail = crWideTrail;
         else if(crStructAgainst || crMacroCHoCH) crTrail = crTightTrail;

         // Lock at 50% TP
         if(!g_ProfitLocked && profit >= crMomLock) {
            g_ProfitLocked = true;
            g_LastMgmtAction = "CR_MOM_LOCK@" + DoubleToString(profit, 2);
            Print("[CHRONO] MOMENTUM LOCK at $", DoubleToString(profit, 2), " @H", ch);
         }

         // Trail
         if(g_ProfitLocked && profit < g_PeakProfit - crTrail) {
            g_LastMgmtAction = "CR_MOM_TRAIL";
            Print("[CHRONO] MOMENTUM TRAIL: peak=$", DoubleToString(g_PeakProfit, 2),
                  " now=$", DoubleToString(profit, 2), " trail=$", DoubleToString(crTrail, 2));
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }

         // Accelerated dwindling: high-liquidity phase should not stall
         if(g_ProfitLocked && g_BarsSincePeak >= 8 && profit < g_PeakProfit * 0.55 && profit > 0) {
            g_LastMgmtAction = "CR_MOM_DWINDLE";
            Print("[CHRONO] MOMENTUM DWINDLE: stalled in overlap session");
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }

      // ===================================================
      //  RIDE sub-mode: ADAPTIVE (mid/late Asian, London, NY)
      // ===================================================
      } else {
         // Full adaptive logic: graduated tiers, dwindling, structure exits.
         double crEarlyLock = g_DynamicTP_USD * 0.35 * scale;
         double crStdLock   = g_ScaledLockUSD;
         double crTP        = g_ScaledTPUSD;

         // Tier 1: early protect
         if(!g_EarlyLockEngaged && profit >= crEarlyLock) {
            g_EarlyLockEngaged = true;
            g_LastMgmtAction = "CR_ADAPT_EARLY@" + DoubleToString(profit, 2);
            Print("[CHRONO] ADAPTIVE EARLY LOCK at $", DoubleToString(profit, 2), " @H", ch);
         }
         // Tier 2: standard lock
         if(!g_ProfitLocked && profit >= crStdLock) {
            g_ProfitLocked = true;
            g_LastMgmtAction = "CR_ADAPT_LOCK@" + DoubleToString(profit, 2);
            Print("[CHRONO] ADAPTIVE LOCK at $", DoubleToString(profit, 2));
         }

         // Adaptive trail (structure-informed)
         double crAdaptTrail;
         if(crMacroCHoCH)                            crAdaptTrail = g_DynamicTP_USD * 0.10 * scale;
         else if(crStructAgainst)                    crAdaptTrail = g_DynamicTP_USD * 0.12 * scale;
         else if(profit >= crTP && crStructWith)     crAdaptTrail = g_DynamicTP_USD * 0.45 * scale;
         else if(crStructWith && crMacroAligned)     crAdaptTrail = g_DynamicTP_USD * 0.40 * scale;
         else if(crStructWith)                       crAdaptTrail = g_DynamicTP_USD * 0.30 * scale;
         else                                        crAdaptTrail = g_DynamicTP_USD * 0.25 * scale;

         // Dwindling detection
         bool crDwindling = false;
         if(g_EarlyLockEngaged && g_PeakProfit > crEarlyLock && profit > 0) {
            if(g_BarsSincePeak >= 10 && profit < g_PeakProfit * 0.50)
               crDwindling = true;
            if(g_BarsSincePeak >= 20 && profit < g_PeakProfit * 0.70)
               crDwindling = true;
         }

         // Structure-urgent exit
         bool crStructUrgent = crStructAgainst && g_EarlyLockEngaged && profit < g_PeakProfit * 0.65;

         if(crDwindling || crStructUrgent) {
            string rsn = crDwindling ? "CR_DWINDLE" : "CR_STRUCT_URGENT";
            g_LastMgmtAction = rsn;
            Print("[CHRONO] ", rsn, ": peak=$", DoubleToString(g_PeakProfit, 2),
                  " now=$", DoubleToString(profit, 2), " @H", ch);
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }

         // Trailing close
         if((g_EarlyLockEngaged || g_ProfitLocked) && profit < g_PeakProfit - crAdaptTrail && profit > 0) {
            g_LastMgmtAction = "CR_ADAPT_TRAIL";
            Print("[CHRONO] ADAPTIVE TRAIL: peak=$", DoubleToString(g_PeakProfit, 2),
                  " now=$", DoubleToString(profit, 2), " trail=$", DoubleToString(crAdaptTrail, 2));
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }

         // Time decay: 32+ bars without standard lock
         if(g_OpenBarCount >= 32 && profit > 0 && !g_ProfitLocked) {
            double minAccept = crEarlyLock * 0.60;
            if(profit < minAccept) {
               g_LastMgmtAction = "CR_TIME_DECAY";
               Print("[CHRONO] TIME DECAY after ", g_OpenBarCount, " bars @H", ch);
               trade.PositionClose(posInfo.Ticket());
               ResetTradeGlobals(profit);
               return;
            }
         }
      }
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

   // Post-trade cooldown: always applied after any trade (win or loss).
   // Prevents the bot from immediately re-entering the same or opposite setup
   // before conditions have had time to meaningfully change.
   if(PostTradeCoolBars > 0) {
      int coolSecs = PostTradeCoolBars * 15 * 60;
      g_PostTradeCoolUntil = TimeCurrent() + (datetime)coolSecs;
      Print("[POST-TRADE COOLDOWN] ", PostTradeCoolBars, " bar(s) cooloff until ",
            TimeToString(g_PostTradeCoolUntil, TIME_MINUTES),
            " | P&L=$", DoubleToString(profit,2));
   }

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
   int rx     = cx + 345;   // right-column X offset

   // --- Background panels created FIRST so all labels render on top ---
   // MT5 renders foreground objects in creation order: oldest = bottom, newest = top.
   {
      int    bgPad  = 5;
      int    bgW    = 340;
      int    bgX    = MathMax(0, cx - bgPad);
      int    bgY    = MathMax(0, cy - bgPad);
      string bgName = DASH_PREFIX + "BG_panel_L";
      if(ObjectFind(0, bgName) < 0) {
         ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, bgName, OBJPROP_CORNER,     corner);
         ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE,  bgX);
         ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE,  bgY);
         ObjectSetInteger(0, bgName, OBJPROP_XSIZE,       bgW);
         ObjectSetInteger(0, bgName, OBJPROP_YSIZE,       900);
         ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR,     C'8,12,28');
         ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
         ObjectSetInteger(0, bgName, OBJPROP_COLOR,        C'60,80,120');
         ObjectSetInteger(0, bgName, OBJPROP_BACK,         false);
         ObjectSetInteger(0, bgName, OBJPROP_ZORDER,       0);
         ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE,   false);
      }
      // Right-column panel
      int    bgWR   = 310;
      int    bgXR   = MathMax(0, rx - bgPad);
      string bgNameR = DASH_PREFIX + "BG_panel_R";
      if(ObjectFind(0, bgNameR) < 0) {
         ObjectCreate(0, bgNameR, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, bgNameR, OBJPROP_CORNER,     corner);
         ObjectSetInteger(0, bgNameR, OBJPROP_XDISTANCE,  bgXR);
         ObjectSetInteger(0, bgNameR, OBJPROP_YDISTANCE,  bgY);
         ObjectSetInteger(0, bgNameR, OBJPROP_XSIZE,       bgWR);
         ObjectSetInteger(0, bgNameR, OBJPROP_YSIZE,       900);
         ObjectSetInteger(0, bgNameR, OBJPROP_BGCOLOR,     C'8,12,28');
         ObjectSetInteger(0, bgNameR, OBJPROP_BORDER_TYPE, BORDER_FLAT);
         ObjectSetInteger(0, bgNameR, OBJPROP_COLOR,        C'60,80,120');
         ObjectSetInteger(0, bgNameR, OBJPROP_BACK,         false);
         ObjectSetInteger(0, bgNameR, OBJPROP_ZORDER,       0);
         ObjectSetInteger(0, bgNameR, OBJPROP_SELECTABLE,   false);
      }
   }

   // ---- helper macro replaced with inline calls ----
   DashLine("00_title",  "[ EURUSD HA RANGE BOT v6 ]",                         cx, cy, row, lh, corner, clrWhite,     10); row++;
   row++;
   DashLine("01_sess",   "Session : " + session,                                cx, cy, row, lh, corner, clrCyan,       9); row++;

   // Entry mode label
   string modeLabel;
   if(HAEntryMode == 1) {
      modeLabel = AllowLateEntry
         ? "EARLY+LATE (first " + IntegerToString(EarlyEntryMins) + "min, then any)"
         : "EARLY only (first " + IntegerToString(EarlyEntryMins) + "min of bar)";
   } else {
      modeLabel = "LATE  (last 5min of bar after 2nd candle)";
   }
   DashLine("01b_emode", "EntryMd : " + modeLabel,                             cx, cy, row, lh, corner, clrAqua,        8); row++;

   DashLine("02_sig",    "Signal  : " + g_Signal,                               cx, cy, row, lh, corner, sigColor,     10); row++;

   // Entry window status — ALWAYS rendered so Bias row never overlaps this row
   {
      string winStr;
      color  winClr;
      bool   isSigIncoming = (g_Signal == "BUY INCOMING" || g_Signal == "SELL INCOMING");
      bool   isSigPrep     = (g_Signal == "PREPARING BUY" || g_Signal == "PREPARING SELL");
      if(isSigIncoming) {
         datetime barNow  = iTime(_Symbol, PERIOD_M15, 0);
         int      elapsed = (int)(TimeCurrent() - barNow);
         int      window  = EarlyEntryMins * 60;
         if(elapsed <= window) {
            winStr = IntegerToString(window - elapsed) + "s left in early window";
            winClr = clrLime;
         } else if(AllowLateEntry) {
            winStr = "Late entry open (+" + IntegerToString(elapsed - window) + "s past early)";
            winClr = clrYellow;
         } else {
            int secsLeft = 900 - elapsed;  // 15-min bar = 900s
            winStr = "Early closed — last5min in " + IntegerToString(MathMax(0, 600 - elapsed)) + "s";
            winClr = clrGray;
         }
      } else if(isSigPrep) {
         winStr = "Setup armed — awaiting confirmation";
         winClr = clrOrange;
      } else {
         winStr = "—";
         winClr = clrDimGray;
      }
      DashLine("02b_win", "Window  : " + winStr, cx, cy, row, lh, corner, winClr, 8); row++;
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
   DashLine("04b_zone",  "Zone    : " + g_ZoneLabel + " [" + g_ZoneHardness + "]",   cx, cy, row, lh, corner, zoneClr,       9); row++;
   bool sw = IsSideways();
   DashLine("04c_sw",    "Sideways: " + (sw ? "YES (tight lock)" : "No"),       cx, cy, row, lh, corner, sw?clrOrange:clrGray, 9); row++;

   // Asian session prev-day momentum status
   if(AsianPrevDayMomEnabled) {
      MqlDateTime _adt; TimeToStruct(TimeCurrent(), _adt);
      bool _inAsian = (_adt.hour >= AsianStartHour && _adt.hour < AsianEndHour);
      if(_inAsian) {
         string _pdLabel = (g_PrevDayLastHourDir == 1)  ? "BULL (buy bias carry)"
                         : (g_PrevDayLastHourDir == -1) ? "BEAR (sell bias carry)"
                         :                                "flat / unknown";
         color  _pdClr   = (g_PrevDayLastHourDir == 1)  ? clrLime
                         : (g_PrevDayLastHourDir == -1) ? clrTomato : clrGray;
         DashLine("04e_pdm", "PrevDHr : " + _pdLabel +
                             (g_AsianZoneRelaxed ? "  [ZONE RELAX]" : ""),
                             cx, cy, row, lh, corner, g_AsianZoneRelaxed ? clrYellow : _pdClr, 8); row++;
      }
   }
   row++;

   string rhStr = (g_RangeHigh > 0) ? DoubleToString(g_RangeHigh, 5) : "N/A";
   string rlStr = (g_RangeLow  > 0) ? DoubleToString(g_RangeLow,  5) : "N/A";
   string rmStr = (g_RangeMid  > 0) ? DoubleToString(g_RangeMid,  5) : "N/A";

   // Show whether range is anchored to prev day (early session narrow-bar fallback)
   MqlDateTime _nowDt; TimeToStruct(TimeCurrent(), _nowDt);
   bool   _earlyNow    = (_nowDt.hour < EarlySessionHours);
   double _todaySpan   = iHigh(_Symbol, PERIOD_D1, 0) - iLow(_Symbol, PERIOD_D1, 0);
   bool   _usingPrev   = _earlyNow && (_todaySpan < MinRangePips * _Point * 10.0) && g_PrevDayHigh > 0;
   string rangeAnchor  = _usingPrev ? "PREV-DAY anchor (early session)" : "live today";
   color  rangeAncClr  = _usingPrev ? clrOrange : clrAqua;
   DashLine("04d_ranc", "RngSrc  : " + rangeAnchor,                             cx, cy, row, lh, corner, rangeAncClr,   8); row++;

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

   // --- H4 Macro Structure & MTF Alignment ---
   if(UseMacroStructure) {
      color  macroClr   = (g_MacroStructLabel == "BULLISH") ? clrLime :
                          (g_MacroStructLabel == "BEARISH") ? clrRed  : clrGray;
      string macroExtra = g_MacroBOS   ? " [MacroBOS]"   :
                          g_MacroCHoCH ? " [MacroCHoCH]" : "";
      DashLine("10bm_macro", "MacroStr: " + g_MacroStructLabel + macroExtra +
               " (" + EnumToString(MacroStructTF) + ")",
               cx, cy, row, lh, corner, macroClr, 9); row++;
      color  mtfClr = g_BoldBet    ? clrGold :
                      g_MTFAligned ? clrAqua : clrDimGray;
      string mtfStr = g_BoldBet    ? "BOLD BET [H4+H1+SMC aligned]" :
                      g_MTFAligned ? "MTF ALIGNED [H4+H1 agree]"    :
                                     "MTF diverged";
      DashLine("10bn_mtf", "MTF     : " + mtfStr,
               cx, cy, row, lh, corner, mtfClr, g_BoldBet ? 10 : 9); row++;

      // Macro Trend Ride status row
      if(MacroTrendRideEnabled) {
         color  rideClr = g_MacroTrendRide ? clrGold : clrDimGray;
         string rideStr = g_MacroTrendRide
                          ? (g_MacroTrendDir==1 ? "BULL RIDE" : "BEAR RIDE") +
                            " ARMED  Score=" + IntegerToString(g_MacroTrendScore) + "/14"
                          : "trend ride: no setup";
         DashLine("10bo_ride", "TrendRide: " + rideStr,
                  cx, cy, row, lh, corner, rideClr, 9); row++;
      }
   }

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

   // --- H4 Supply/Demand: Order Blocks & FVGs (macro zones) ---
   if(UseH4SMC) {
      // H4 Order Block row
      string h4obLine = "";
      if(g_H4BullOB_High > 0)
         h4obLine += "D:" + DoubleToString(g_H4BullOB_Low,5) + "-" + DoubleToString(g_H4BullOB_High,5);
      if(g_H4BearOB_High > 0) {
         if(h4obLine != "") h4obLine += "  ";
         h4obLine += "S:" + DoubleToString(g_H4BearOB_Low,5) + "-" + DoubleToString(g_H4BearOB_High,5);
      }
      color h4obClr = g_NearH4BullOB ? clrLimeGreen : g_NearH4BearOB ? clrTomato : clrDimGray;
      DashLine("10g_h4ob", "H4 OB   : " + (h4obLine != "" ? h4obLine : "none"),
               cx, cy, row, lh, corner, h4obClr, g_NearH4BullOB||g_NearH4BearOB ? 9 : 7); row++;

      // H4 FVG row
      string h4fvgStr = IntegerToString(g_H4FVGCount) + " active";
      if(g_NearBullH4FVG || g_NearBearH4FVG) {
         h4fvgStr += " | Near: " + (g_NearBullH4FVG ? "BULL" : "BEAR") + " H4FVG " +
                     DoubleToString(g_NearestH4FVGLow,5) + "-" + DoubleToString(g_NearestH4FVGHigh,5);
      }
      color h4fvgClr = g_NearBullH4FVG ? clrCornflowerBlue : g_NearBearH4FVG ? clrMediumOrchid : clrGray;
      DashLine("10h_h4fvg", "H4 FVG  : " + h4fvgStr,
               cx, cy, row, lh, corner, h4fvgClr, g_NearBullH4FVG||g_NearBearH4FVG ? 9 : 7); row++;
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

   // --- Left panel sizing (finalize height) ---
   {
      int    bgPad  = 5;
      int    bgW    = 340;
      int    bgH    = row * lh + bgPad * 2;
      int    bgX    = MathMax(0, cx - bgPad);
      int    bgY    = MathMax(0, cy - bgPad);
      string bgName = DASH_PREFIX + "BG_panel_L";
      ObjectSetInteger(0, bgName, OBJPROP_CORNER,    corner);
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, bgX);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, bgY);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE,      bgW);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE,      bgH);
   }

   // ======================================================================
   //  RIGHT COLUMN — Trade Status, Foreign Trades, Daily Stats, Cooldowns
   // ======================================================================
   int rowR = 0;

   DashLine("R_title", "[ TRADE & STATS ]",  rx, cy, rowR, lh, corner, clrWhite, 10); rowR++;
   rowR++;

   // --- Trade Status (ALL rows ALWAYS rendered — prevents label overlap) ---
   {
      color  tColor  = g_TradeOpen ? clrLime : clrGray;
      DashLine("R_trade", "Trade   : " + (g_TradeOpen ? "OPEN" : "NONE"),
               rx, cy, rowR, lh, corner, tColor, 9); rowR++;

      if(g_TradeOpen) {
         string modeStr = g_IsMeanRev ? "MEAN REV" : (g_IsNearMid ? "MID-validated" : "TREND");
         color  modeClr = g_IsMeanRev ? clrGold : (g_IsNearMid ? clrOrange : clrLime);
         DashLine("R_mode", "Mode    : " + modeStr + " | " + g_TradeMgmtModeName, rx, cy, rowR, lh, corner, modeClr, 9);
      } else {
         DashLine("R_mode", "Mode    : --- | " + g_TradeMgmtModeName, rx, cy, rowR, lh, corner, clrDimGray, 9);
      }
      rowR++;

      if(g_TradeOpen) {
         string confLbl = "Conf " + DoubleToString(g_Confidence, 0) + "%";
         color  cClr = (g_Confidence >= 80) ? clrGold : (g_Confidence >= 65) ? clrCyan : clrSilver;
         DashLine("R_sltp", confLbl +
                  "  SL:$" + DoubleToString(g_ScaledSLUSD, 2) +
                  "  TP:$" + DoubleToString(g_ScaledTPUSD, 2),
                  rx, cy, rowR, lh, corner, cClr, 8);
      } else {
         DashLine("R_sltp", "SL / TP : ---", rx, cy, rowR, lh, corner, clrDimGray, 8);
      }
      rowR++;

      if(g_TradeOpen) {
         DashLine("R_lktr", "Lock:$" + DoubleToString(g_ScaledLockUSD, 2) +
                  "  Trail:$" + DoubleToString(g_ScaledTrailUSD, 2),
                  rx, cy, rowR, lh, corner, clrAqua, 8);
      } else {
         DashLine("R_lktr", "Lock/Tr : ---", rx, cy, rowR, lh, corner, clrDimGray, 8);
      }
      rowR++;

      if(g_TradeOpen && g_NearLevel != "") {
         DashLine("R_cnfl", "Cnfl    : " + g_NearLevel, rx, cy, rowR, lh, corner, clrGold, 9);
      } else {
         DashLine("R_cnfl", "Cnfl    : ---", rx, cy, rowR, lh, corner, clrDimGray, 9);
      }
      rowR++;

      if(g_TradeOpen) {
         DashLine("R_hold", "Hold    : " + IntegerToString(g_OpenBarCount) + "/" +
                  IntegerToString(MaxHoldBars) + " bars  SincePk:" + IntegerToString(g_BarsSincePeak),
                  rx, cy, rowR, lh, corner, clrWhite, 9);
      } else {
         DashLine("R_hold", "Hold    : ---", rx, cy, rowR, lh, corner, clrDimGray, 9);
      }
      rowR++;

      if(g_TradeOpen) {
         double hardLoss = MaxLossUSD * g_CurrentLot / 0.01;
         DashLine("R_cap", "MaxLoss : -$" + DoubleToString(hardLoss, 2) + " cap",
                  rx, cy, rowR, lh, corner, clrTomato, 9);
      } else {
         DashLine("R_cap", "MaxLoss : ---", rx, cy, rowR, lh, corner, clrDimGray, 9);
      }
      rowR++;

      if(g_TradeOpen) {
         string lockStr = g_ProfitLocked
                          ? "LOCKED  peak:$" + DoubleToString(g_PeakProfit, 2)
                          : (g_EarlyLockEngaged ? "EARLY_LK" : "Watch") +
                            "  lock@$" + DoubleToString(g_ScaledLockUSD, 2);
         color  lColor  = g_ProfitLocked ? clrLime : g_EarlyLockEngaged ? clrYellow : clrOrange;
         DashLine("R_lock", "Lock    : " + lockStr, rx, cy, rowR, lh, corner, lColor, 9);
      } else {
         DashLine("R_lock", "Lock    : ---", rx, cy, rowR, lh, corner, clrDimGray, 9);
      }
      rowR++;

      // --- In-trade tracking (peak/trough/struct shift) ---
      if(g_TradeOpen) {
         string trackStr = "Pk:$" + DoubleToString(g_PeakProfit, 2) +
                           "  Lo:$" + DoubleToString(g_TroughProfit, 2) +
                           "  Shifts:" + IntegerToString(g_StructShiftCount);
         color  trackClr = (g_BarsSincePeak > 10) ? clrOrange :
                           (g_PeakProfit > g_ScaledLockUSD) ? clrLime : clrSilver;
         DashLine("R_track", "Track   : " + trackStr, rx, cy, rowR, lh, corner, trackClr, 8);
      } else {
         DashLine("R_track", "Track   : ---", rx, cy, rowR, lh, corner, clrDimGray, 8);
      }
      rowR++;

      // --- HARVESTER tier info (only when mode 4) ---
      if(g_TradeOpen && TradeMgmtMode == 4) {
         double hvScale = g_CurrentLot / 0.01;
         string hvStr = "$" + DoubleToString(1.00 * hvScale, 2) + " / " +
                        "$" + DoubleToString(1.50 * hvScale, 2) + " / " +
                        "$" + DoubleToString(2.00 * hvScale, 2);
         DashLine("R_hvtier", "Harvest : " + hvStr, rx, cy, rowR, lh, corner, clrGold, 8);
      } else {
         DashLine("R_hvtier", "", rx, cy, rowR, lh, corner, clrDimGray, 8);
      }
      rowR++;

      // --- CHRONO session phase info (only when mode 5) ---
      if(g_TradeOpen && TradeMgmtMode == 5) {
         MqlDateTime cdtD; TimeToStruct(TimeCurrent(), cdtD);
         int cdH = cdtD.hour;
         string crPhStr    = "RIDE";
         string crSubStr   = "ADAPT";
         color  crPhClr    = clrCyan;
         bool cdEarlyAsian = (cdH >= AsianStartHour && cdH < AsianStartHour + 3);
         bool cdLateNY     = (cdH >= NewYorkEndHour - 2 && cdH < NewYorkEndHour);
         bool cdOffHrs     = (cdH >= NewYorkEndHour || cdH < AsianStartHour);
         bool cdOverlap    = (cdH >= NewYorkStartHour && cdH < LondonEndHour);
         if(cdEarlyAsian || cdLateNY || cdOffHrs) {
            crPhStr  = "SLASH";
            crSubStr = "HARVEST";
            crPhClr  = clrOrangeRed;
         } else if(cdOverlap) {
            crSubStr = "MOMENTUM";
            crPhClr  = clrAqua;
         }
         DashLine("R_chrono", "Chrono  : " + crPhStr + " > " + crSubStr + " @H" + IntegerToString(cdH),
                  rx, cy, rowR, lh, corner, crPhClr, 8);
      } else {
         DashLine("R_chrono", "", rx, cy, rowR, lh, corner, clrDimGray, 8);
      }
      rowR++;

      // --- Last management action ---
      if(g_TradeOpen && g_LastMgmtAction != "") {
         DashLine("R_mgmt", "MgmtAct : " + g_LastMgmtAction, rx, cy, rowR, lh, corner, clrCyan, 8);
      } else {
         DashLine("R_mgmt", "MgmtAct : ---", rx, cy, rowR, lh, corner, clrDimGray, 8);
      }
      rowR++;
   }
   rowR++;

   // --- Foreign Trades ---
   DashLine("R_fhdr", "--- FOREIGN ---", rx, cy, rowR, lh, corner, clrSilver, 8); rowR++;
   if(g_ForeignCountSymbol > 0) {
      string fStr = IntegerToString(g_ForeignCountSymbol) + " on " + _Symbol
                    + " (" + DoubleToString(g_ForeignLotsSymbol, 2) + " lots)";
      DashLine("R_fgn",  "Foreign : " + fStr, rx, cy, rowR, lh, corner, clrOrangeRed, 8);
   } else if(g_ForeignCountTotal > 0) {
      DashLine("R_fgn",  "Foreign : " + IntegerToString(g_ForeignCountTotal) + " other pairs",
               rx, cy, rowR, lh, corner, clrGray, 8);
   } else {
      DashLine("R_fgn",  "Foreign : none", rx, cy, rowR, lh, corner, clrGray, 8);
   }
   rowR++;

   if(g_ForeignCountSymbol > 0) {
      DashLine("R_fgnd", "  " + g_ForeignSummary, rx, cy, rowR, lh, corner, clrOrange, 7);
   } else {
      DashLine("R_fgnd", "", rx, cy, rowR, lh, corner, clrGray, 7);
   }
   rowR++;

   if(g_ForeignCountSymbol > 0 && RespectForeignTrades) {
      DashLine("R_fgnw", "  >> Bot PAUSED (one-trade rule)", rx, cy, rowR, lh, corner, clrRed, 8);
   } else {
      DashLine("R_fgnw", "", rx, cy, rowR, lh, corner, clrGray, 8);
   }
   rowR++;
   rowR++;

   // --- Daily Stats ---
   DashLine("R_shdr", "--- DAILY STATS ---", rx, cy, rowR, lh, corner, clrWhite, 9); rowR++;
   {
      string dayStatsStr = "W:" + IntegerToString(g_DailyWins) +
                           " L:" + IntegerToString(g_DailyLosses) +
                           " P&L:$" + DoubleToString(g_DailyPnL, 2) +
                           " (" + IntegerToString(g_DailyTradeCount) + "/" +
                           (MaxDailyTrades > 0 ? IntegerToString(MaxDailyTrades) : "inf") + ")";
      color dayClr = g_DailyPnL > 0 ? clrLime : g_DailyPnL < 0 ? clrRed : clrGray;
      DashLine("R_dstat", "Today   : " + dayStatsStr, rx, cy, rowR, lh, corner, dayClr, 8); rowR++;
   }

   // Cooldowns (all slots always rendered — blank when inactive)
   if(MaxDailyLossUSD > 0 && g_DailyPnL <= -MaxDailyLossUSD) {
      DashLine("R_cool", "LOSS CAP -$" + DoubleToString(MathAbs(g_DailyPnL),2) + " STOPPED",
               rx, cy, rowR, lh, corner, clrRed, 8);
   } else if(g_CooldownUntil > 0 && TimeCurrent() < g_CooldownUntil) {
      int secsLeft = (int)(g_CooldownUntil - TimeCurrent());
      DashLine("R_cool", "COOLDOWN " + IntegerToString(secsLeft/60) + "m" +
               IntegerToString(secsLeft%60) + "s (" + IntegerToString(g_ConsecLosses) + " consec)",
               rx, cy, rowR, lh, corner, clrRed, 8);
   } else if(g_ConsecLosses > 0) {
      DashLine("R_cool", "ConsecL : " + IntegerToString(g_ConsecLosses) + "/" +
               IntegerToString(ConsecLossLimit),
               rx, cy, rowR, lh, corner, clrOrange, 8);
   } else {
      DashLine("R_cool", "", rx, cy, rowR, lh, corner, clrGray, 8);
   }
   rowR++;

   if(g_PostTradeCoolUntil > 0 && TimeCurrent() < g_PostTradeCoolUntil) {
      int ptSecs = (int)(g_PostTradeCoolUntil - TimeCurrent());
      DashLine("R_ptcool", "PostTrd : " + IntegerToString(ptSecs/60) + "m " +
               IntegerToString(ptSecs%60) + "s cooloff",
               rx, cy, rowR, lh, corner, clrOrange, 8);
   } else {
      DashLine("R_ptcool", "", rx, cy, rowR, lh, corner, clrGray, 8);
   }
   rowR++;

   if(g_StartupGraceUntil > 0 && TimeCurrent() < g_StartupGraceUntil) {
      int sgSecs = (int)(g_StartupGraceUntil - TimeCurrent());
      DashLine("R_grace", "Grace   : " + IntegerToString(sgSecs/60) + "m " +
               IntegerToString(sgSecs%60) + "s startup",
               rx, cy, rowR, lh, corner, clrYellow, 8);
   } else {
      DashLine("R_grace", "", rx, cy, rowR, lh, corner, clrGray, 8);
   }
   rowR++;

   // Geo & News notes (always rendered)
   rowR++;
   DashLine("R_geo",  GeoPoliticsNote != "" ? "Geo : " + GeoPoliticsNote : "",
            rx, cy, rowR, lh, corner, GeoPoliticsNote != "" ? clrLightGray : clrGray, 8); rowR++;
   DashLine("R_news", NewsNote != "" ? "News: " + NewsNote : "",
            rx, cy, rowR, lh, corner, NewsNote != "" ? clrLightGray : clrGray, 8); rowR++;

   // --- Right panel sizing ---
   {
      int    bgPad  = 5;
      int    bgWR   = 310;
      int    bgH    = rowR * lh + bgPad * 2;
      int    bgXR   = MathMax(0, rx - bgPad);
      int    bgY    = MathMax(0, cy - bgPad);
      string bgName = DASH_PREFIX + "BG_panel_R";
      ObjectSetInteger(0, bgName, OBJPROP_CORNER,    corner);
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, bgXR);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, bgY);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE,      bgWR);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE,      bgH);
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