//+------------------------------------------------------------------+
//|  EURUSD Heiken Ashi Range Bot v7.00                              |
//|  NB probabilistic gate + OB/FVG/HPL/SMC + 6-mode trade mgmt     |
//|  STANDARD / SENTINEL / MOMENTUM / ADAPTIVE / HARVESTER / CHRONO |
//+------------------------------------------------------------------+
#property copyright   "EURUSD HA Range Bot"
#property version     "7.00"
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
input double MinSL_USD        = 0.50;   // Minimum SL per 0.01 lot — floor avoids broker reject; HA-based SL can be as low as 0.8
input double MaxSL_USD        = 1.25;   // Hard SL cap per 0.01 lot (~12.5 pips) — a bad entry is costly; don't give more away
input double RRRatio          = 1.8;    // Reward:Risk ratio (1.8 = for every $1 risk, target $1.80)
input double MaxTP_USD        = 2.50;   // Hard TP ceiling per 0.01 lot — 2.0-2.5 USD is statistically achievable; beyond this risks missing the exit
// Stop-loss options — UseSL=false: no broker SL order; trade closed at profit or EOD (never overnight)
input bool   UseSL             = true;   // true=place broker SL; false=manage exit manually (EOD close enforced)
input int    EODCloseHour      = 21;     // When UseSL=false: force-close any open trade at this hour (server time)
input double SLBufferPips      = 2.0;   // Extra pip cushion added to structural SL for breathing room (TP unchanged)
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
input int    TradeMgmtMode    = 0;      // 0-5: STD|SENT|MOM|ADAPT|HARVEST|CHRONO
// Pause new-trade scanning while bot has an open trade.
// true = focus entirely on managing the open trade (default, recommended).
// false = continue scanning/arming signals even while a trade is running.
// Note: foreign-only trades do NOT trigger the pause — bot can still arm.
input bool   PauseScanInTrade = true;    // Pause signal scanning while bot trade open
// Smart loss exit: close losing trades early when structure shifts against them.
// 0 = OFF, 1 = ADAPTIVE+CHRONO+HARVESTER only (default), 2 = ALL modes
input int    LossStructExit   = 1;      // 0=OFF | 1=ADAPT/CHRONO/HARVEST | 2=ALL
// Mid-range time-exit: close if stalling in LOSS after MidRangeMaxBars
input double MidRangeStallUSD = 0.00;   // Stall exit disabled — trust the SL/TP
input int    MidRangeMaxBars  = 16;     // Bars before mid-range stall check (only if MidRangeStallUSD > 0)

input group "=== HORIZONTAL PRICE LEVELS (HPL) ==="
input bool   UseHPL             = true;   // Enable horizontal price level (consolidation) detection
input int    HPLScanBars        = 100;    // M15 bars to scan for repeated price touches (~25 hours)
input double HPLClusterPips     = 3.0;    // Max pip spread to cluster touches into one level
input int    HPLMinTouches      = 3;      // Minimum bar-highs or bar-lows needed to form a level
input int    HPLMaxZones        = 5;      // Max HPL zones to track per direction (resist + support)
input double HPLBreakPips       = 5.0;    // Pips past zone needed for a convincing break (zone invalid)
input double HPLBlockBufferPips = 1.5;    // Extra pip buffer: how close price must be to trigger block
input bool   HPLBlockBuysAtResist = true; // Block BUY entries at unbroken resistance HPL
input bool   HPLBlockSellsAtSupport = true; // Block SELL entries at unbroken support HPL

input group "=== TIME FILTERS ==="
input int    MaxHoldBars      = 48;     // Max 15M bars to hold = 12 hours — give trades room to develop
input int    SidewaysBars     = 8;      // Bars to check for compressed/sideways range
input double SidewaysPips     = 15;     // If range < this many pips over SidewaysBars = sideways

input group "=== SESSION TRADING MODE ==="
// Restricts NEW trade entries to selected sessions. Open trades continue and are closed by SL/TP or EOD.
// 0=All sessions (default)  1=Asian only  2=London only  3=Asian+London
input int    SessionMode       = 0;      // 0=All | 1=Asian | 2=London | 3=Asian+London

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
input int    AsianObserveBars      = 4;      // v6.32: first N M15 bars of Asian open = observe-only (4 = 1 hour)
input int    LondonObserveBars     = 2;      // v6.32: first N M15 bars of London open = observe-only (2 = 30 min; fakeout detection covers the rest)
input int    NYObserveBars         = 2;      // v6.32: first N M15 bars of NY open (13:00) = observe-only (2 = 30 min; fakeout detection covers the rest)
// RELAX mode: when prev-day momentum aligns with signal AND multiple factors agree,
// the standard zone block (UPPER_THIRD for buy / LOWER_THIRD for sell) is lifted in Asian hours.
// The trade is entered with standard (not narrowed) SL and a logged CAUTION note.
// Enhanced Asian bias (v7.00): after the observe window, once price moves >= AsianBiasMovePips
// in a direction, the session has an established bias. Aligned HA signals earn +8 conf pts;
// counter-direction signals lose -5 pts. This captures the "Asian session direction rule"
// (first hours define the drift until London joins at 08:00).
input bool   AsianBiasEnabled      = true;   // Enable enhanced Asian session directional bias
input double AsianBiasMovePips     = 10.0;   // Min pip move from Asian open to establish bias

input group "=== MANUAL RANGE OVERRIDE ==="
input bool   UseManualRange   = false;
input double ManualRangeHigh  = 0.0;
input double ManualRangeLow   = 0.0;

input group "=== EARLY SESSION RANGE ==="
input int    EarlySessionHours = 4;     // Use prev-day range when today's range is narrower than MinRangePips
input double MinRangePips      = 30.0;  // Minimum range width in pips before switching to prev-day reference

input group "=== MOVING AVERAGES (M15) ==="
// MA200 = macro direction filter (above=bull, below=bear).
// MA50/20 = intraday trend alignment and touch/cross entry gate.
input bool   UseMAFilter           = true;   // Master toggle for all MA gates
input int    MA200Period           = 200;
input int    MA50Period            = 50;
input int    MA20Period            = 20;
input ENUM_MA_METHOD MAMethod      = MODE_EMA;  // MA calculation method
input double MA50TouchPips         = 5.0;   // Max pips from MA50 to count as touching/crossing
input double MA20TouchPips         = 3.0;   // Max pips from MA20 (bonus) to count as touching
input bool   MA200MacroHardBlock   = true;  // Block buy below MA200 / sell above MA200 (unless CHoCH override)
// When MA200MacroHardBlock fires but signals are strong, place a pending BuyStop/SellStop at MA200+buffer
// so the trade only opens once price actually crosses the MA200 line, avoiding premature entries.
input double MA200PendingPips      = 2.0;   // Buffer pips above/below MA200 for pending order entry price
input int    MA200PendingMaxBars   = 8;     // Auto-cancel pending order after this many M15 bars (8 = 2 hrs)
input bool   MA200FakeJumpBlock    = true;  // Block buys when price jumped above MA200 but MA50 hasn't followed (likely reversal)
input bool   MA5020EntryRequired   = true;  // Require price touching or having crossed MA50 for entry

input group "=== DAILY EXTENSION CAP ==="
// Prevents chasing moves already extended far from today's open.
// Extension is measured as % of the D1 ATR already consumed in one direction from daily open.
// 30% cap example: if D1 ATR=80 pips and price has fallen 24+ pips from today's open, block sells.
// Block lifts when price retraces back inside the cap (e.g. rebound from -34% to -7%).
input bool   UseDailyExtCap        = true;   // Toggle daily extension cap
input double DailyExtCapPct        = 30.0;   // % of D1 ATR: block if current move from open exceeds this
input int    MaxConsecCandles    = 4;
// Spike candle filter: a single HA candle whose total range exceeds SpikeATRMult × ATR is an
// abnormal impulse (often news-driven). Skip arming the setup; reset the counter so the NEXT
// two clean candles become the fresh pattern.
input bool   InvalidateSpikeCandles = true;   // Skip spike HA candles as setup triggers
input double SpikeATRMult           = 2.0;    // HA total range > N×ATR = spike (2.0 = 200% of ATR)
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
input int    MacroTrendMinScore     = 5;      // Min ZoneContextScore (0-15) — higher = more selective
input double MacroTrendSL_USD       = 1.75;   // SL per 0.01 lot (slightly wider for trend volatility)
input double MacroTrendMinTP_USD    = 1.80;   // Floor TP per 0.01 lot (minimum target for a trend ride)
input double MacroTrendMaxTP_USD    = 2.50;   // Ceiling TP per 0.01 lot — capped at achievable target (mirrors MaxTP_USD)
input bool   MacroTrendAsianBlock   = true;   // Block during Asian session (wait for London/NY momentum)

input group "=== RANGE ZONE FILTERS ==="
// How far inside range boundaries before a trade is allowed (as % of total range)
input double MidZonePct       = 0.30;   // Mid zone = middle 30% of range (15% each side of mid)
input double ExtremePct       = 0.15;   // Extreme zone = outer 15% near H/L (avoid for trend)
// Mean reversion: enter when HA confirms bounce from range extreme
input bool   AllowMeanReversion = true; // Enable HA-confirmed mean reversion trades at range extremes
input double MRV_SLScale        = 0.75; // v6.36: SL multiplier for MRV trades (tighter SL since range-bound)
input double MRV_TPScale        = 0.60; // v6.36: TP multiplier for MRV trades (shorter target to midrange)
//
// Zone strictness controls how "wrong zone" trend trades are treated:
//   0 = STRICT        — Hard block. Zone is an absolute barrier; no exceptions ever.
//   1 = RELAXED       — Block unless Asian session + prev-day carry-over bias (original default).
//   2 = CONTEXT_AWARE — Smart mode. Scores structural confluence (up to 15 points):
//                       If score >= ZoneContextMinScore AND price is approaching a Fib/Pivot level
//                       → sets PENDING state; waits for that level to break + momentum before entry.
//                       If score sufficient AND no Fib barrier ahead (or already past one)
//                       → allows CAUTION entry, logged to journal for learning.
//                       Ideal for trending markets where the zone filter alone is misleading.
input int    ZoneStrictness        = 2;    // 0=STRICT | 1=RELAXED (Asian relax) | 2=CONTEXT_AWARE
input int    ZoneContextMinScore   = 4;    // Min confluence score (0-15) for CONTEXT_AWARE zone override
input bool   ZonePendingEnabled    = true; // CONTEXT mode: wait for Fib/Pivot breakout before entry
input double ZonePendingPips       = 10.0; // Pip lookahead: detect approaching Fib/Pivot within this range
input int    ZonePendingMaxBars    = 4;    // CONTEXT mode: auto-expire pending wait after N M15 bars (4=1hr)
//
// Extended zone analysis — channels, multi-day S/R, and Fib extensions
input bool   UseMurrayChannels    = true;  // Compute Murray Math octave levels from H4 swing range
input bool   UseWeeklySR          = true;  // Track weekly & 3-day H/L for multi-day support/resistance
input bool   UseFibExtensions     = true;  // Add 127.2% and 161.8% Fib extension levels beyond range

input group "=== ZONE APPROACH PRIMER (ZAP) v7 ==="
// ZAP watches ALL institutional zones each bar. When price is within ZAPProximityPips of
// a confluence cluster (CI H/L, OB, FVG, HPL, Murray, Pivot, Fib, Weekly S/R), the bot arms
// its directional bias BEFORE any HA signal fires. When the first bottomless/topless HA candle
// then appears AT the zone, it goes DIRECTLY to INCOMING (skips PREPARING state).
// Fakeout sweep: if price punches ZAPFakeoutPips PAST the zone (liquidity sweep), g_ZAPFakeout
// is set — the reversal candle entry is the highest-conviction setup and bypasses NB suppression.
input bool   UseZAP             = true;    // Enable Zone Approach Primer (zone-first brain)
input double ZAPProximityPips   = 15.0;    // Pips from zone edge to arm ZAP
input int    ZAPMinScore        = 2;       // Min zone types converging to qualify as a primer
input bool   ZAPFastTrack       = true;    // First HA candle at zone → direct INCOMING (no PREPARING)
input int    ZAPMaxBars         = 12;      // ZAP expiry: bars without HA confirmation (12 = 3 hours)
input double ZAPFakeoutPips     = 5.0;     // Pips past zone boundary = liquidity sweep (fakeout signal)
input bool   UseZoneConfluence  = true;    // Use zone confluence % to lower confidence threshold
// Quick-entry combo: when ZAP is armed AND Asian bias is established in the SAME direction,
// the confidence gate drops to AsianZAPMinConf — these setups are historically clean.
// The full confidence model still scores the trade; this just lowers the bar at which it fires.
input bool   QuickEntryEnabled  = true;    // Enable lower confidence gate for ZAP+AsianBias+HA confluence
input double AsianZAPMinConf    = 22.0;   // Minimum confidence when ZAP+AsianBias fully aligned (Asian session)
// EURUSD 3-4AM momentum window: direction established in this window tends to follow through
// cleanly for 1-3 USD per 0.01 lot. Give an additional confidence bonus for signals in that hour.
input bool   AM34BonusEnabled   = true;   // Extra confidence for 3-4 AM signals (Asian continuation/flip hour)
input double AM34BonusPts       = 8.0;    // Confidence bonus when signal fires between 3:00 and 4:00 server time

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

input group "=== ECONOMIC CALENDAR ==="
input bool   ShowCalendar        = true;   // Display live economic calendar on the Trade dashboard
input int    CalendarLookAheadH  = 6;      // Hours ahead to scan for EUR/USD events (1-12)
input int    CalendarMinImpact   = 2;      // Minimum importance: 1=all  2=moderate+  3=high only
input int    CalendarMaxEvents   = 3;      // Events to show on dashboard (1-4)
input int    CalendarNoTradeMins = 30;     // Block new entries within N min of HIGH impact event (0=off)
input int    CalendarLookBackH   = 4;      // Hours back to scan for released EUR/USD events shown as Recent News (0=off)

input group "=== FOREIGN TRADE AWARENESS ==="
input bool   RespectForeignTrades = true;   // Block new entries if a non-bot trade exists on this symbol

input group "=== OVERTRADING PROTECTION ==="
input int    MaxDailyTrades     = 5;     // Max trades per day (0 = unlimited; more trades can offset losses — house always wins)
input bool   OneTradePerSession  = false; // Allow multiple trades per session — a session can offer 2+ good setups
input double MaxDailyLossUSD    = 5.0;   // Stop trading after cumulative daily loss exceeds this (0=disabled)
input int    ConsecLossLimit    = 2;     // After N consecutive SL hits, pause trading
input int    CooldownBars       = 8;     // Bars to pause after consecutive loss limit hit (8 = 2 hours)
input int    PostTradeCoolBars  = 1;     // Cool-off bars after any trade closes before next entry (1 = 15 min)
input int    StartupGraceMins   = 4;     // After real restart, wait N minutes before allowing entry (0=disabled; skipped on timeframe switch)
input int    NoEntryAfterHour   = 21;    // No new entries after this server hour (0-23, 0=disabled)
input int    PrepMaxBars        = 8;     // Max bars PREPARING can wait for Bollinger confirm before expiring (0=no limit)
input int    FridayCloseHour    = 20;    // Force close open trades on Friday at this hour (0=disabled)

input group "=== RISK MANAGEMENT (v6.36) ==="
input double MaxSpreadPips       = 2.5;   // Block entry when spread exceeds this (0=disabled)
input double MaxDrawdownPct      = 5.0;   // Block entries when account drawdown exceeds this % from peak equity (0=disabled)

input group "=== DASHBOARD POSITION ==="
input int    DashboardCorner  = 0;
input int    DashboardX       = 10;
input int    DashboardY       = 20;

input group "=== NB BRAIN (Signal Co-Driver) ==="
// Self-training Naive Bayes: re-runs every new bar, predicts P(UP)% and P(DOWN)% from 9 live features.
// NB is a signal CO-DRIVER: high NB confidence drives BUY/SELL INCOMING directly (skips PREPARING).
// Strong NB disagreement suppresses HA arming. Classes: UP(0)/DOWN(1)/NEUTRAL(2) — absolute direction.
// Disable by setting UseNBBrain=false; set NBMinPosterior=0 to disable soft suppression gate.
input bool   UseNBBrain        = true;   // Enable NB signal co-driver (runs every bar)
input double NBHighThreshold   = 55.0;   // P(direction)% at which NB drives direct INCOMING
input double NBMinPosterior    = 35.0;   // P(direction)% minimum to arm PREPARING; below = suppress
input int    NB_LookbackBars   = 100;    // M15 bars of training history (100 = ~25h fast init)
input int    NB_Lookahead      = 2;      // Bars ahead for label (2 = 30 min)
input double NB_WinMultiplier  = 0.9;   // UP/DOWN label if |move| >= ATR * this within lookahead
input int    NB_RetrainBars    = 1;      // Retrain every N new bars (1 = every bar, freshest model)
input bool   NBSessionTrain    = true;   // Train separate NB model per session (Asian/London/NY)
input bool   NBOnlineLearn     = true;   // Online reinforcement: refine model from each bar outcome
input double NBOnlineWeight    = 0.15;   // Max blend weight of online updates vs batch (0=off, 0.5=max)

//=== GLOBALS ===

// Foreign trade tracking (non-bot positions on this account)
int    g_ForeignCountSymbol = 0;    // foreign trades on THIS symbol (EURUSD)
int    g_ForeignCountTotal  = 0;    // foreign trades on ALL symbols
double g_PeakEquity         = 0;    // v6.36: peak equity watermark for drawdown tracking
double g_ForeignLotsSymbol  = 0.0;  // total lots of foreign trades on this symbol
string g_ForeignSummary     = "";   // human-readable summary for dashboard

// Per-trade detail for manual trades panel
struct ManualTradeInfo {
   ulong    ticket;
   int      dir;        // 1=BUY, -1=SELL
   double   lots;
   double   openPrice;
   double   sl;         // 0 if not set
   double   tp;         // 0 if not set
   double   pnl;        // profit + swap + commission (net)
   bool     isManual;   // true = magic == 0
   long     magic;
};
ManualTradeInfo g_ManualTrades[4];   // up to 4 same-symbol foreign trades
int             g_ManualTradeCount = 0;

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
string g_BollRoomLabel = "";  // Bollinger headroom label: "ROOM" (below upper/above lower), "CAPPED" (at band), "" (no data)
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
string g_ComebackLabel     = "";       // comeback potential label for dashboard (HIGH/MODERATE/LOW)
string g_SignalPendingReason = "";     // short reason why signal survives HA reset (dashboard sub-line)

// HA chain cache — proper recursive calculation built once per new bar.
// The old CalcHA used a 2-bar lookback which under-smoothed HA Open, causing
// late direction flips, missed bottomless/topless candles, and short counts.
double g_HACacheO[50];     // HA Open  for bars 0..49
double g_HACacheH[50];     // HA High  for bars 0..49
double g_HACacheL[50];     // HA Low   for bars 0..49
double g_HACacheC[50];     // HA Close for bars 0..49
datetime g_HACacheBar = 0; // bar-0 open time when cache was last built

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
bool   g_HADirFlip    = false;        // true when bar1 HA dir is opposite bar2 HA dir (momentum flip)
int    g_HAConsecSinceKeyLevel = 0;   // consecutive clean HA bars since last key S/R/Fib level was crossed
string g_KeyLevelCrossLabel    = "";  // label of the most recently crossed key level
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
int      g_AsianBarCount       = 0;    // v6.29: bars elapsed since Asian session started today
int      g_LondonBarCount      = 0;    // v6.32: bars elapsed since London session started today
int      g_NYBarCount          = 0;    // v6.32: bars elapsed since NY session started today (from 13:00)

// Session fake-out watch (v6.32): after the observe window, if price moved AGAINST macro structure,
// block entries in the fake-out direction — wait for price to rebound back before allowing entry.
bool     g_SessionFakeoutWatch = false;  // true when observe-window move opposed macro structure
int      g_FakeoutDir          = 0;      // direction of the fake move (+1=faked up, -1=faked down)
datetime g_FakeoutExpiry       = 0;      // auto-expire after ~2 hours if no follow-through

// Inter-session context (v6.33): compare what the PREVIOUS session delivered in its final hour
// vs what the new session's observe window did — classifies the observe move as:
//   BULL/BEAR TRAP [HIGH]  — observe opposes BOTH macro AND previous session (double-confirmed trap)
//   BULL/BEAR TRAP [MEDIUM]— observe opposes macro; previous session context weak/mixed/unknown
//   CONTINUATION           — observe aligns with macro (green light)
//   SESS REVERSAL          — observe aligns with macro but NOT previous session (turn underway)
int    g_PrevSessCloseDir    = 0;     // direction of last ~4 M15 bars of the previous session (+1/-1/0)
int    g_PrevSessConsistency = 0;     // how many of the 4 bar-over-bar checks agreed (0-4)
bool   g_PrevSessStrong      = false; // true when 3+ of 4 checks agreed (clean directional session close)
string g_PrevSessName        = "";    // which session was "previous": "PrevDay" / "Asian" / "London"
string g_InterSessContext    = "";    // e.g. "Asian-close:Bear(S) | Lon-obs:Bull | macro:Bear → BULL TRAP [HIGH]"
string g_FakeoutConfidence   = "";    // "HIGH" / "MEDIUM" / "" (empty when no fakeout active)

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
bool   g_RealCandleAligned = false;          // v6.29: true when real candle direction matches HA on bars 1 & 2
string g_LastBlockReason   = "";             // last TryEntry block message — only print when it changes

// Moving Average values (v6.34) — M15 EMA200/50/20 for macro + intraday gates
int    g_hMA200 = INVALID_HANDLE;
int    g_hMA50  = INVALID_HANDLE;
int    g_hMA20  = INVALID_HANDLE;
// v6.36: Persistent indicator handles (avoid create/destroy per bar)
int    g_hATR   = INVALID_HANDLE;   // H1 ATR handle
int    g_hBands = INVALID_HANDLE;   // M15 Bollinger Bands handle
datetime g_LastH4BarTime = 0;        // v6.36: track H4 bar for frequency gating
datetime g_M1M5BlockStart = 0;       // v6.36: when M1/M5 double-oppose started (soft timeout)
double g_MA200 = 0, g_MA50 = 0, g_MA20 = 0;  // current MA levels (bar 0 live)
bool   g_AboveMA200   = false;  // current bid > MA200
bool   g_AboveMA50    = false;  // current bid > MA50
bool   g_AboveMA20    = false;  // current bid > MA20
bool   g_MA50Touch    = false;  // price touching or has crossed MA50 (within MA50TouchPips)
bool   g_MA20Touch    = false;  // price touching or has crossed MA20 (bonus — tighter)
bool   g_MA200CrossUp = false;  // bar 1 closed above MA200 while bar 2 was below (fresh bull cross)
bool   g_MA200CrossDn = false;  // bar 1 closed below MA200 while bar 2 was above (fresh bear cross)
bool   g_MA50CrossUp  = false;  // bar 1 crossed MA50 upward — augments CHoCH in bear macro
bool   g_MA50CrossDn  = false;  // bar 1 crossed MA50 downward — augments CHoCH in bull macro
string g_MAStatusLabel = "";    // dashboard summary string
// v6.35: MA convergence / fake-jump detection
bool   g_MAsAligned      = false; // true when MA50 and MA20 are both on the same side of MA200 (genuine alignment)
bool   g_MA200FakeJumpUp = false; // price jumped above MA200 but MA50 still below → likely false BOS, expect reversal to MA50
bool   g_MA200FakeJumpDn = false; // price dropped below MA200 but MA50 still above → likely false BOS, expect reversal to MA50
// v6.35: Pending order state for MA200 boundary crossings
int      g_PendingMA200Ticket = 0;     // order ticket of live pending order (0 = none)
int      g_PendingMA200Dir    = 0;     // direction of pending: 1=BuyStop, -1=SellStop
datetime g_PendingMA200Bar    = 0;     // bar time when pending was placed (for age tracking)
double   g_PendingMA200Entry  = 0;     // entry price of the pending order

// Daily extension cap (v6.34)
double g_DailyOpenPx      = 0;   // open of first M15 bar today (server midnight)
double g_DailyExtDownPct  = 0;   // how far below daily open as % of D1 ATR (positive = below)
double g_DailyExtUpPct    = 0;   // how far above daily open as % of D1 ATR (positive = above)

// HA alignment quality — updated by EvaluateHAPattern each bar
string g_HAQualityLabel = "—";  // PURE / MIXED / IMPURE / DOJI
int    g_HAQualityScore = 0;    // count of bottomless (bull) or topless (bear) bars in last chain (0-4)
int    g_HAQualityTotal = 0;    // total bars checked for quality (denominator)
bool   g_ConfirmPure   = false; // true when the confirming bar (bar1) is bottomless/topless

// Macro Trend Ride state
bool   g_MacroTrendRide  = false;  // true when MacroBOS trend-ride conditions are met on this bar
int    g_MacroTrendDir   = 0;      // 1=bullish ride (long), -1=bearish ride (short)
int    g_MacroTrendScore = 0;      // ZoneContextScore captured at time of detection (0-15)
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

// Horizontal Price Levels (HPL) — multi-touch consolidation/rejection zones
struct HPLZone {
   double   high;        // upper edge of the cluster zone
   double   low;         // lower edge of the cluster zone
   int      dir;         // +1 = resistance (highs cluster), -1 = support (lows cluster)
   int      touches;     // number of bar-highs or bar-lows in this cluster
   datetime firstTime;   // time of earliest bar that contributed a touch
   bool     broken;      // true once price closed convincingly past the zone
};
HPLZone g_HPLZones[];        // detected HPL zones (resist + support combined)
int     g_HPLCount    = 0;   // number of active HPL zones
bool    g_HPLResistBlock = false;  // true when an unbroken RESIST HPL is overhead (BUY blocked)
bool    g_HPLSupportBlock = false; // true when an unbroken SUPPORT HPL is below (SELL blocked)
double  g_HPLResistHigh = 0, g_HPLResistLow = 0;   // nearest blocking resistance band
double  g_HPLSupportHigh = 0, g_HPLSupportLow = 0; // nearest blocking support band

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

// === ZONE APPROACH PRIMER (ZAP) globals — v7.00 ===
bool   g_ZAPActive        = false;  // true when price is near a zone confluence cluster
int    g_ZAPDir           = 0;      // +1=BUY primer, -1=SELL primer, 0=unarmed
int    g_ZAPScore         = 0;      // number of zone types converging at this price
string g_ZAPLabel         = "";     // human-readable zone types (e.g. "CIL FVG BullOB")
bool   g_ZAPFakeout       = false;  // true after a liquidity sweep past zone boundary
double g_ZAPZonePrice     = 0;      // price of the swept zone (for logging)
datetime g_ZAPStartTime   = 0;      // when ZAP was last armed (for expiry tracking)
double g_ZoneConfluencePct = 0;     // 0-100%: % of max possible zone score converging

// === ENHANCED ASIAN BIAS globals — v7.00 ===
bool   g_AsianBiasActive  = false;  // true once Asian session established >= AsianBiasMovePips move
int    g_AsianBiasDir     = 0;      // +1=BULL bias, -1=BEAR bias, 0=no bias
string g_AsianBiasLabel   = "";     // display label: "BULL BIAS +12.3pip" etc.

// Confidence model output (replaces tier system)
double g_Confidence       = 0;             // 0-100% confidence score for current setup
string g_ConfBreakdown    = "";            // per-factor score breakdown for audit logs
double g_ConfidenceStatic = 0;             // v6.38: confidence cached at signal arm (bar1); stable baseline
datetime g_ConfidenceArmedBar = 0;         // v6.38: bar time when confidence was last pre-cached

// --- NB Brain globals ---
#define HA_NB_FEATURES   9
#define HA_NB_MAX_BINS   4
#define HA_NB_CLASSES    3   // 0=UP, 1=DOWN, 2=NEUTRAL (absolute direction classes)
int    g_HaNB_FeatureBins[HA_NB_FEATURES];
double g_HaNB_Prior[HA_NB_CLASSES];
double g_HaNB_Likelihood[HA_NB_CLASSES][HA_NB_FEATURES][HA_NB_MAX_BINS];
int    g_HaNB_SampleCount = 0;
double g_NBPosteriorWin   = 0.0;   // P(UP|features) % — live, updated every bar
double g_NBPosteriorLoss  = 0.0;   // P(DOWN|features) % — live, updated every bar
double g_NBPosteriorHold  = 0.0;   // P(NEUTRAL|features) % — live, updated every bar
double g_NBBuyProb        = 0.0;   // alias for g_NBPosteriorWin  (P(UP) for buy signal use)
double g_NBSellProb       = 0.0;   // alias for g_NBPosteriorLoss (P(DOWN) for sell signal use)
int    g_NBPredDir        = 0;     // NB top prediction direction: 1=UP, -1=DOWN, 0=neutral
int    g_HaNB_BarCounter  = 0;     // bars elapsed since last retrain
bool   g_HaNB_Trained     = false; // true once model has been trained at least once
int    g_hNB_MA10         = INVALID_HANDLE;  // persistent SMA10 for NB training
int    g_hNB_MA30         = INVALID_HANDLE;  // persistent SMA30 for NB training
// Session-stratified NB: separate model per session (0=Asian / 1=London / 2=NY)
double g_HaNB_Prior_S[3][HA_NB_CLASSES];
double g_HaNB_Likelihood_S[3][HA_NB_CLASSES][HA_NB_FEATURES][HA_NB_MAX_BINS];
int    g_HaNB_SampleCount_S[3];            // training samples per session model
bool   g_HaNB_Trained_S[3];               // true once each session model has been trained
int    g_CurNBSessionIdx    = 3;           // current session (0=Asian/1=London/2=NY/3=Off)
int    g_PrevNBSessionIdx   = 3;           // previous session (detect crossings for retrain)
// Online reinforcement accumulator (updated each bar, blended into live inference)
int    g_OL_ClassCounts[3][HA_NB_CLASSES];
int    g_OL_FCounts[3][HA_NB_CLASSES][HA_NB_FEATURES][HA_NB_MAX_BINS];
int    g_OL_TotalUpdates[3];               // total live updates since last batch retrain per session
// Previous-bar state for online labelling
int    g_PrevBarFeats[HA_NB_FEATURES];
int    g_PrevBarNBDir    = 0;
bool   g_PrevBarFeatValid = false;
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
int      g_DailyTradeCount   = 0;    // trades opened today
int      g_AsianTradeCount   = 0;    // v6.37: trades opened during Asian session today
int      g_LondonTradeCount  = 0;    // v6.37: trades opened during London session today
int      g_NYTradeCount      = 0;    // v6.37: trades opened during NY session today
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
double   g_DailyPnL        = 0.0;    // cumulative P&L today (bot trades only)
// Manual / foreign trade daily stats (recalculated from HistorySelect each bar)
int      g_DailyManualCount  = 0;
int      g_DailyManualWins   = 0;
int      g_DailyManualLosses = 0;
double   g_DailyManualPnL    = 0.0;

datetime g_LastBarTime  = 0;
datetime g_LastDayReset = 0;

// Economic Calendar cache (populated by FetchCalendarEvents every 60 s)
struct CalEvent { datetime time; string currency; string name; int importance; };
CalEvent            g_CalEvents[4];          // up to 4 upcoming EUR/USD events
int                 g_CalEventCount      = 0;
datetime            g_CalLastFetch       = 0;
bool                g_NewsNoTrade        = false;  // HIGH impact event within CalendarNoTradeMins
bool                g_CalCountriesLoaded = false;
MqlCalendarCountry  g_CalCountries[];           // filled once by CalendarCountries()
int                 g_CalCountryCount    = 0;
// Recent released events (actual results already published)
struct CalPastEvent {
   datetime time; string currency; string name; int importance;
   int    impact;    // +1 = EUR/USD bullish, -1 = bearish, 0 = neutral/na
   double actual;   // released actual value (DBL_MAX = not provided)
   double forecast; // consensus forecast   (DBL_MAX = not provided)
};
CalPastEvent g_CalPastEvents[4];   // up to 4 most-recent released events
int          g_CalPastCount  = 0;
int          g_CalNewsScore  = 0;  // net EUR/USD sentiment from recent data (-10..+10)

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

      g_TradeOpen          = true;
      g_CurrentLot         = lot;
      g_TradeOpenTime      = openTime;
      g_Signal             = "WAITING";   // block new entries while trade is live
      g_ConfidenceStatic   = 0; g_ConfidenceArmedBar = 0;  // v6.38: trade live on startup

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
//| MANUAL TRADE STRUCTURAL CONFIDENCE                               |
//| Scores how well current market structure supports a manual trade  |
//| direction. Returns 0-100. Independent of HA/Bollinger chain.     |
//+------------------------------------------------------------------+
int ManualTradeConf(int tradeDir)
{
   // Each factor worth ~12-15 pts; cap at 100.
   int score = 0;

   // H4 macro structure
   int macroDir = (g_MacroStructLabel == "BULLISH") ? 1 : (g_MacroStructLabel == "BEARISH") ? -1 : 0;
   if(macroDir == tradeDir)        score += 15;
   else if(macroDir == -tradeDir)  score -= 10;

   // H1 structure
   int h1Dir = (g_StructureLabel == "BULLISH") ? 1 : (g_StructureLabel == "BEARISH") ? -1 : 0;
   if(h1Dir == tradeDir)           score += 12;
   else if(h1Dir == -tradeDir)     score -= 8;

   // Bias
   if(tradeDir == 1  && g_TotalBias >= 2)   score += 10;
   else if(tradeDir == 1  && g_TotalBias >= 1) score += 5;
   else if(tradeDir == -1 && g_TotalBias <= -2) score += 10;
   else if(tradeDir == -1 && g_TotalBias <= -1) score += 5;
   else if(tradeDir == 1  && g_TotalBias <= -2) score -= 8;
   else if(tradeDir == -1 && g_TotalBias >= 2)  score -= 8;

   // FVG support
   if(tradeDir == 1  && g_NearBullFVG) score += 8;
   if(tradeDir == -1 && g_NearBearFVG) score += 8;
   if(tradeDir == 1  && g_NearBearFVG) score -= 5;  // FVG overhead opposing buy
   if(tradeDir == -1 && g_NearBullFVG) score -= 5;

   // Order block support
   if(tradeDir == 1  && g_BullOB_High > 0) score += 8;
   if(tradeDir == -1 && g_BearOB_High > 0) score += 8;

   // H4 OB support
   if(tradeDir == 1  && g_NearH4BullOB) score += 8;
   if(tradeDir == -1 && g_NearH4BearOB) score += 8;

   // HPL: unbroken zone opposing the trade = structural headwind
   if(tradeDir == 1  && g_HPLResistBlock)  score -= 15;
   if(tradeDir == -1 && g_HPLSupportBlock) score -= 15;

   // Sideways market
   if(IsSideways()) score -= 8;

   // Liquidity sweep in trade direction = smart money entry
   if(g_LiquiditySweep) score += 6;

   // Recent news releases: g_CalNewsScore > 0 = EUR/USD bullish data, < 0 = bearish
   // Only counted when ShowCalendar is active and CalendarLookBackH > 0
   if(ShowCalendar && CalendarLookBackH > 0) {
      int _nsFactor = 0;
      if(g_CalNewsScore >= 4)       _nsFactor = 10;
      else if(g_CalNewsScore >= 2)  _nsFactor = 6;
      else if(g_CalNewsScore >= 1)  _nsFactor = 3;
      else if(g_CalNewsScore <= -4) _nsFactor = -10;
      else if(g_CalNewsScore <= -2) _nsFactor = -6;
      else if(g_CalNewsScore <= -1) _nsFactor = -3;
      score += (tradeDir == 1 ? _nsFactor : -_nsFactor);
   }

   // Map to 0-100 (raw range is roughly -50 to +75)
   // Shift so that 0 raw = 40% (neutral-ish baseline)
   int pct = 40 + score;
   if(pct < 0)   pct = 0;
   if(pct > 100) pct = 100;
   return pct;
}

//+------------------------------------------------------------------+
//| SCAN FOREIGN TRADES                                              |
//| Counts open positions NOT placed by this bot (magic != 202502).  |
//| Separates same-symbol vs total-account foreign trades.           |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Recalculate manual-trade daily stats from closed deal history.   |
//| Bot trades (magic 202502) are tracked event-driven; this covers  |
//| all manually-placed / third-party-EA deals for today.            |
//+------------------------------------------------------------------+
void CalcDailyStatsBySource()
{
   g_DailyManualCount  = 0;
   g_DailyManualWins   = 0;
   g_DailyManualLosses = 0;
   g_DailyManualPnL    = 0.0;

   MqlDateTime dayDt;
   TimeToStruct(TimeCurrent(), dayDt);
   dayDt.hour = 0; dayDt.min = 0; dayDt.sec = 0;
   datetime dayStart = StructToTime(dayDt);

   if(!HistorySelect(dayStart, TimeCurrent())) return;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      if(magic == 202502) continue;   // bot trades tracked separately via event
      double pnl = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP);
      g_DailyManualCount++;
      g_DailyManualPnL += pnl;
      if(pnl >= 0.0) g_DailyManualWins++;
      else            g_DailyManualLosses++;
   }
}

void ScanForeignTrades()
{
   int    countSym   = 0;
   int    countAll   = 0;
   double lotsSym    = 0.0;
   string details    = "";
   g_ManualTradeCount = 0;

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

         // Save detailed info for the manual trades panel (up to 4)
         if(g_ManualTradeCount < 4) {
            ManualTradeInfo mt;
            mt.ticket    = posInfo.Ticket();
            mt.dir       = (posInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
            mt.lots      = lot;
            mt.openPrice = posInfo.PriceOpen();
            mt.sl        = posInfo.StopLoss();
            mt.tp        = posInfo.TakeProfit();
            mt.pnl       = pnl;
            mt.isManual  = (magic == 0);
            mt.magic     = magic;
            g_ManualTrades[g_ManualTradeCount] = mt;
            g_ManualTradeCount++;
         }
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
// v6.34: Update M15 MA values and daily extension cap each tick.
// Handles are created in OnInit; this just reads the latest buffer values.
void UpdateMAValues()
{
   if(!UseMAFilter) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pipSize = _Point * ((int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) % 2 == 1 ? 10 : 1);
   // --- MA levels: use bar-0 (live) for gate checks ---
   double ma200_0[], ma50_0[], ma20_0[];
   double ma200_1[], ma50_1[], ma200_2[], ma50_2[], ma20_1[], ma20_2[];
   if(g_hMA200 != INVALID_HANDLE && CopyBuffer(g_hMA200, 0, 0, 3, ma200_0) == 3) {
      g_MA200       = ma200_0[2];   // index 2 = newest (bar 0)
      double ma200_b1 = ma200_0[1]; // bar 1
      double ma200_b2 = ma200_0[0]; // bar 2
      g_AboveMA200   = (bid > g_MA200);
      double cl1_raw[], cl2_raw[];  // bar 1 / bar 2 M15 close prices
      double c1 = iClose(_Symbol, PERIOD_M15, 1);
      double c2 = iClose(_Symbol, PERIOD_M15, 2);
      g_MA200CrossUp = (c1 > ma200_b1 && c2 <= ma200_b2);  // fresh bull cross bar1
      g_MA200CrossDn = (c1 < ma200_b1 && c2 >= ma200_b2);  // fresh bear cross bar1
   }
   if(g_hMA50 != INVALID_HANDLE && CopyBuffer(g_hMA50, 0, 0, 3, ma50_0) == 3) {
      g_MA50      = ma50_0[2];     // bar 0
      double ma50_b1 = ma50_0[1];  // bar 1
      double ma50_b2 = ma50_0[0];  // bar 2
      g_AboveMA50 = (bid > g_MA50);
      double distPips = MathAbs(bid - g_MA50) / pipSize;
      g_MA50Touch = (distPips <= MA50TouchPips);
      double c1 = iClose(_Symbol, PERIOD_M15, 1);
      double c2 = iClose(_Symbol, PERIOD_M15, 2);
      g_MA50CrossUp = (c1 > ma50_b1 && c2 <= ma50_b2);
      g_MA50CrossDn = (c1 < ma50_b1 && c2 >= ma50_b2);
   }
   if(g_hMA20 != INVALID_HANDLE && CopyBuffer(g_hMA20, 0, 0, 1, ma20_0) == 1) {
      g_MA20      = ma20_0[0];
      g_AboveMA20 = (bid > g_MA20);
      g_MA20Touch = (MathAbs(bid - g_MA20) / pipSize <= MA20TouchPips);
   }
   // --- Build status label ---
   string above200 = g_AboveMA200 ? "A200" : "B200";
   string above50  = g_AboveMA50  ? "A50"  : "B50";
   string above20  = g_AboveMA20  ? "A20"  : "B20";
   string cross    = g_MA200CrossUp ? " X200^" : (g_MA200CrossDn ? " X200v" :
                    (g_MA50CrossUp  ? " X50^"  : (g_MA50CrossDn  ? " X50v" : "")));
   string touch    = (g_MA50Touch ? " T50" : "") + (g_MA20Touch ? "+T20" : "");
   g_MAStatusLabel = above200 + " " + above50 + " " + above20 + cross + touch;

   // --- v6.35: MA alignment and fake-jump detection ---
   // "Aligned" means all three MAs stacked in the same direction:
   //   Bull aligned: price > MA200 AND MA50 > MA200 AND MA20 > MA200 (golden-stack territory)
   //   Bear aligned: price < MA200 AND MA50 < MA200 AND MA20 < MA200
   g_MAsAligned      = (g_AboveMA200 && g_MA50 > g_MA200 && g_MA20 > g_MA200)
                     || (!g_AboveMA200 && g_MA50 < g_MA200 && g_MA20 < g_MA200);
   // Fake jump: price has crossed MA200 but MA50 has NOT followed yet.
   // This is the most common false BOS — institutions push price through MA200 briefly
   // then sell/buy it back towards MA50 (mean reversion to the slower average).
   // When g_MA200FakeJumpUp is true: price is above MA200 but MA50 is still below — bearish reversal likely.
   // When g_MA200FakeJumpDn is true: price is below MA200 but MA50 is still above — bullish bounce likely.
   g_MA200FakeJumpUp = (g_MA200 > 0 && g_MA50 > 0 && g_AboveMA200  && g_MA50 < g_MA200);
   g_MA200FakeJumpDn = (g_MA200 > 0 && g_MA50 > 0 && !g_AboveMA200 && g_MA50 > g_MA200);
   if(g_MA200FakeJumpUp || g_MA200FakeJumpDn) {
      // Label shows whether MA20 has also failed to follow (strongest false-breakout case)
      bool _fkBothBehind = g_MA20 > 0
                           && (g_MA200FakeJumpUp ? (g_MA20 < g_MA200) : (g_MA20 > g_MA200));
      g_MAStatusLabel += " [FKJMP" + (g_MA200FakeJumpUp ? "^" : "v")
                       + (_fkBothBehind ? "(50+20)" : "(50)") + "]";
   }

   // --- Daily extension cap ---
   if(UseDailyExtCap) {
      // Seed daily open once per day (or on first call)
      MqlDateTime _ddt; TimeToStruct(TimeCurrent(), _ddt);
      datetime _todayMidnight = (TimeCurrent() / 86400) * 86400;
      if(g_DailyOpenPx == 0) {
         // Try to find the first M15 bar that opened at or after midnight
         int _dayBar = iBarShift(_Symbol, PERIOD_M15, _todayMidnight, false);
         g_DailyOpenPx = (_dayBar >= 0) ? iOpen(_Symbol, PERIOD_M15, _dayBar) : bid;
      }
      // D1 ATR for reference distance
      double _d1atr = 0;
      int _hATRd1 = iATR(_Symbol, PERIOD_D1, 14);
      double _atrBuf[];
      if(_hATRd1 != INVALID_HANDLE && CopyBuffer(_hATRd1, 0, 1, 1, _atrBuf) == 1)
         _d1atr = _atrBuf[0];
      if(_d1atr > 0 && g_DailyOpenPx > 0) {
         double _moveDn = g_DailyOpenPx - bid;   // positive when below open
         double _moveUp = bid - g_DailyOpenPx;   // positive when above open
         g_DailyExtDownPct = MathMax(0, _moveDn / _d1atr * 100.0);
         g_DailyExtUpPct   = MathMax(0, _moveUp / _d1atr * 100.0);
      }
      // Reset daily open at midnight
      static datetime _lastDay = 0;
      if(_lastDay != _todayMidnight) {
         _lastDay       = _todayMidnight;
         g_DailyOpenPx  = 0;   // will be re-seeded above next tick
         g_DailyExtDownPct = 0;
         g_DailyExtUpPct   = 0;
      }
   }
}

//+------------------------------------------------------------------+
// v6.35: Manage the MA200 pending BuyStop / SellStop order.
// Called every tick. Handles:
//   1. Age expiry — cancel after MA200PendingMaxBars bars
//   2. Signal lost — cancel if HA signal is no longer in the pending direction
//   3. MA200 drift — modify entry price each bar to track the moving MA200
//   4. Trade opened — clear state once the pending fills (detected via g_TradeOpen)
void ManageMA200Pending()
{
   if(g_PendingMA200Ticket == 0) return;

   // If a market trade is now open (pending filled), clear state
   if(g_TradeOpen) {
      g_PendingMA200Ticket = 0; g_PendingMA200Dir = 0;
      g_PendingMA200Bar    = 0; g_PendingMA200Entry = 0;
      return;
   }

   // Confirm the order still exists in the terminal
   if(!OrderSelect(g_PendingMA200Ticket)) {
      g_PendingMA200Ticket = 0; g_PendingMA200Dir = 0;
      g_PendingMA200Bar    = 0; g_PendingMA200Entry = 0;
      return;
   }

   datetime curBar = iTime(_Symbol, PERIOD_M15, 0);

   // Age check — cancel if too old
   if(MA200PendingMaxBars > 0 && g_PendingMA200Bar > 0) {
      int barsOld = (int)iBarShift(_Symbol, PERIOD_M15, g_PendingMA200Bar, false);
      if(barsOld >= MA200PendingMaxBars) {
         Print("[MA200 PENDING] Expired (", barsOld, " bars old, max=", MA200PendingMaxBars, ") — cancelling #", g_PendingMA200Ticket);
         trade.OrderDelete(g_PendingMA200Ticket);
         g_PendingMA200Ticket = 0; g_PendingMA200Dir = 0;
         g_PendingMA200Bar    = 0; g_PendingMA200Entry = 0;
         return;
      }
   }

   // Signal check — cancel if HA signal no longer supports pending direction
   bool sigStillValid = (g_PendingMA200Dir == 1  && (g_HABullSetup || g_Signal == "PREPARING BUY"))
                      || (g_PendingMA200Dir == -1 && (g_HABearSetup || g_Signal == "PREPARING SELL"));
   if(!sigStillValid) {
      Print("[MA200 PENDING] Signal gone — cancelling #", g_PendingMA200Ticket);
      trade.OrderDelete(g_PendingMA200Ticket);
      g_PendingMA200Ticket = 0; g_PendingMA200Dir = 0;
      g_PendingMA200Bar    = 0; g_PendingMA200Entry = 0;
      return;
   }

   // MA200 drift — update entry price on each new bar so it tracks the MA
   if(g_MA200 > 0 && curBar != g_PendingMA200Bar) {
      double pipSize  = _Point * ((int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) % 2 == 1 ? 10 : 1);
      double bufDist  = MA200PendingPips * pipSize;
      double newEntry = (g_PendingMA200Dir == 1) ? NormalizeDouble(g_MA200 + bufDist, _Digits)
                                                  : NormalizeDouble(g_MA200 - bufDist, _Digits);
      if(MathAbs(newEntry - g_PendingMA200Entry) >= _Point * 2) {
         // Re-derive SL/TP from the new entry
         double lot     = g_CurrentLot;
         double _slUSD  = g_DynamicSL_USD * (lot / 0.01);
         double _tpUSD  = g_DynamicTP_USD * (lot / 0.01);
         double _slDist = USDtoPoints(_slUSD, lot);
         double _tpDist = USDtoPoints(_tpUSD, lot);
         double _minSp  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
         if(_slDist < _minSp + _Point * 5) _slDist = _minSp + _Point * 5;
         if(_tpDist < _minSp + _Point * 5) _tpDist = _minSp + _Point * 5;
         double newSL = (g_PendingMA200Dir == 1) ? NormalizeDouble(newEntry - _slDist, _Digits)
                                                  : NormalizeDouble(newEntry + _slDist, _Digits);
         double newTP = (g_PendingMA200Dir == 1) ? NormalizeDouble(newEntry + _tpDist, _Digits)
                                                  : NormalizeDouble(newEntry - _tpDist, _Digits);
         if(trade.OrderModify(g_PendingMA200Ticket, newEntry, newSL, newTP, ORDER_TIME_GTC, 0)) {
            g_PendingMA200Entry = newEntry;
            Print("[MA200 PENDING] Modified entry to ", DoubleToString(newEntry,5),
                  " (MA200=", DoubleToString(g_MA200,5), ")");
         }
      }
   }
}

//+------------------------------------------------------------------+
// v6.33: Seed session bar counters at startup so they reflect the correct value
// even when the EA loads mid-session (not just on the next new-bar event).
// Uses iBarShift on PERIOD_M15 from the session-start datetime today.
void SeedSessionBarCounts()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   bool _sInAsian  = (dt.hour >= AsianStartHour   && dt.hour < AsianEndHour);
   bool _sInLondon = (dt.hour >= LondonStartHour  && dt.hour < LondonEndHour);
   bool _sInNY     = (dt.hour >= NewYorkStartHour && dt.hour < NewYorkEndHour);
   datetime _today = (TimeCurrent() / 86400) * 86400;  // midnight of server today
   if(_sInAsian) {
      datetime _sessStart = _today + (datetime)(AsianStartHour * 3600);
      int _bars = (int)iBarShift(_Symbol, PERIOD_M15, _sessStart, false);
      g_AsianBarCount = (_bars >= 0) ? _bars + 1 : 1;
      Print("[SEED] AsianBarCount=", g_AsianBarCount, " (now ", dt.hour, ":",
            IntegerToString(dt.min, 2, '0'), " Asian started ", AsianStartHour, ":00)");
   }
   if(_sInLondon) {
      datetime _sessStart = _today + (datetime)(LondonStartHour * 3600);
      int _bars = (int)iBarShift(_Symbol, PERIOD_M15, _sessStart, false);
      g_LondonBarCount = (_bars >= 0) ? _bars + 1 : 1;
      Print("[SEED] LondonBarCount=", g_LondonBarCount, " (now ", dt.hour, ":",
            IntegerToString(dt.min, 2, '0'), " London started ", LondonStartHour, ":00)");
   }
   if(_sInNY) {
      datetime _sessStart = _today + (datetime)(NewYorkStartHour * 3600);
      int _bars = (int)iBarShift(_Symbol, PERIOD_M15, _sessStart, false);
      g_NYBarCount = (_bars >= 0) ? _bars + 1 : 1;
      Print("[SEED] NYBarCount=", g_NYBarCount, " (now ", dt.hour, ":",
            IntegerToString(dt.min, 2, '0'), " NY started ", NewYorkStartHour, ":00)");
   }
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

   // Warm up HA chain cache immediately so cold-start recovery has accurate values
   BuildHACache();
   // v6.34: Create M15 MA indicator handles
   if(UseMAFilter) {
      g_hMA200 = iMA(_Symbol, PERIOD_M15, MA200Period, 0, MAMethod, PRICE_CLOSE);
      g_hMA50  = iMA(_Symbol, PERIOD_M15, MA50Period,  0, MAMethod, PRICE_CLOSE);
      g_hMA20  = iMA(_Symbol, PERIOD_M15, MA20Period,  0, MAMethod, PRICE_CLOSE);
      if(g_hMA200==INVALID_HANDLE || g_hMA50==INVALID_HANDLE || g_hMA20==INVALID_HANDLE)
         Print("[MA INIT] WARNING: one or more MA handles failed to create");
      else
         Print("[MA INIT] M15 MA handles ready: MA", MA200Period, "/MA", MA50Period, "/MA", MA20Period);
   }
   // v6.36: Create persistent ATR and Bollinger handles (avoid per-bar create/destroy overhead)
   g_hATR   = iATR  (_Symbol, PERIOD_H1,  ATRPeriod);
   g_hBands = iBands(_Symbol, PERIOD_M15, BollingerPeriod, 0, 2.0, PRICE_CLOSE);
   if(g_hATR == INVALID_HANDLE)   Print("[INIT] WARNING: ATR handle creation failed");
   if(g_hBands == INVALID_HANDLE) Print("[INIT] WARNING: Bollinger handle creation failed");
   // v6.33: Seed session bar counters so observe windows are correct when EA loads mid-session
   SeedSessionBarCounts();
   UpdateMAValues();  // v6.34: seed MA values at startup

   // Startup grace period: wait N minutes before allowing entries after a TRUE COLD START.
   // Skipped on warm restarts where market data is already in memory:
   //   REASON_CHARTCHANGE (3) = TF/symbol switch
   //   REASON_PARAMETERS  (5) = user changed inputs
   //   REASON_RECOMPILE   (2) = code recompiled in MetaEditor
   //   REASON_REMOVE      (1) = EA removed and re-added
   //   REASON_TEMPLATE    (7) = chart template applied
   //   REASON_ACCOUNT     (6) = account change
   // Grace only fires on: first attach (0), terminal close (9), chart close (4).
   int  _reinitReason = UninitializeReason();
   bool _isWarmRestart = (_reinitReason == REASON_CHARTCHANGE ||
                          _reinitReason == REASON_PARAMETERS  ||
                          _reinitReason == REASON_RECOMPILE   ||
                          _reinitReason == REASON_REMOVE       ||
                          _reinitReason == REASON_TEMPLATE     ||
                          _reinitReason == REASON_ACCOUNT);
   if(StartupGraceMins > 0 && !_isWarmRestart) {
      g_StartupGraceUntil = TimeCurrent() + (datetime)(StartupGraceMins * 60);
      Print("[STARTUP GRACE] Cold start — waiting ", StartupGraceMins, " min(s) before allowing entries",
            " (until ", TimeToString(g_StartupGraceUntil, TIME_MINUTES), ") reason=", _reinitReason);
   } else if(_isWarmRestart) {
      g_StartupGraceUntil = 0;   // clear any leftover grace from previous init
      Print("[STARTUP GRACE] Skipped — warm restart (reason=", _reinitReason, " ",
            (_reinitReason == REASON_CHARTCHANGE ? "TF_SWITCH" :
             _reinitReason == REASON_PARAMETERS  ? "PARAMS" :
             _reinitReason == REASON_RECOMPILE   ? "RECOMPILE" :
             _reinitReason == REASON_REMOVE       ? "REMOVE+ADD" :
             _reinitReason == REASON_TEMPLATE     ? "TEMPLATE" : "ACCOUNT"),
            ") — data in memory, no wait needed");
   }

   FetchCalendarEvents();         // v6.39: initial calendar load
   g_CalLastFetch = TimeCurrent();

   // NB Brain: initialise + warm-up train + immediately compute live posteriors
   if(UseNBBrain) {
      InitNBBrain();          // bins, uniform priors, create persistent MA handles
      if(NBSessionTrain) {    // pre-train all 3 session models on startup
         for(int _si = 0; _si < 3; _si++) BuildAndTrainNBBrain_Session(_si);
      }
      BuildAndTrainNBBrain(); // always train global model as fallback
      CalcNBLiveProbs();      // immediately sets g_NBBuyProb/SellProb for dashboard
   }

   UpdateDashboard();
   // v6.36: Timer-driven dashboard (1 Hz instead of per-tick)
   EventSetTimer(1);
   Print("HA Range Bot v6.36 initialized. Range H=", g_RangeHigh, " L=", g_RangeLow);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| TIMER — dashboard refresh at 1 Hz (v6.36)                       |
//+------------------------------------------------------------------+
void OnTimer()
{
   UpdateDashboard();
   // Refresh economic calendar cache every 60 seconds
   if(ShowCalendar && TimeCurrent() - g_CalLastFetch >= 60) {
      FetchCalendarEvents();
      g_CalLastFetch = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, DASH_PREFIX);
   ObjectsDeleteAll(0, "HABOT_");   // clears FVG, OB, H4OB, H4FVG, LVL, ZONE, all bot objects
   EventKillTimer();  // v6.36: stop dashboard timer
   // v6.34: Release MA indicator handles
   if(g_hMA200 != INVALID_HANDLE) { IndicatorRelease(g_hMA200); g_hMA200 = INVALID_HANDLE; }
   if(g_hMA50  != INVALID_HANDLE) { IndicatorRelease(g_hMA50);  g_hMA50  = INVALID_HANDLE; }
   if(g_hMA20  != INVALID_HANDLE) { IndicatorRelease(g_hMA20);  g_hMA20  = INVALID_HANDLE; }
   // v6.36: Release persistent ATR and Bollinger handles
   if(g_hATR   != INVALID_HANDLE) { IndicatorRelease(g_hATR);   g_hATR   = INVALID_HANDLE; }
   if(g_hBands != INVALID_HANDLE) { IndicatorRelease(g_hBands); g_hBands = INVALID_HANDLE; }
   // v6.43: Release NB Brain persistent MA handles
   if(g_hNB_MA10 != INVALID_HANDLE) { IndicatorRelease(g_hNB_MA10); g_hNB_MA10 = INVALID_HANDLE; }
   if(g_hNB_MA30 != INVALID_HANDLE) { IndicatorRelease(g_hNB_MA30); g_hNB_MA30 = INVALID_HANDLE; }
   // v6.35: Cancel any live MA200 pending order on EA removal/deinit
   if(g_PendingMA200Ticket != 0) {
      if(OrderSelect(g_PendingMA200Ticket))
         trade.OrderDelete(g_PendingMA200Ticket);
      g_PendingMA200Ticket = 0;
   }
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

   // v6.36: track peak equity watermark for drawdown protection
   double _eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(_eq > g_PeakEquity) g_PeakEquity = _eq;

   // Scan for foreign (non-bot) trades every tick
   ScanForeignTrades();
   CalcDailyStatsBySource();

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

   // === v7.00: UseSL=false — EOD FORCE CLOSE ===
   // When the user runs without a broker SL, every open trade MUST be closed before
   // the end of day so no position is held overnight. Fires at EODCloseHour.
   if(!UseSL && g_TradeOpen) {
      MqlDateTime _eodDt; TimeToStruct(TimeCurrent(), _eodDt);
      if(_eodDt.hour >= EODCloseHour) {
         for(int _ei = PositionsTotal() - 1; _ei >= 0; _ei--) {
            if(posInfo.SelectByIndex(_ei)) {
               if(posInfo.Symbol() == _Symbol && posInfo.Magic() == 202502) {
                  double _eodPnl = posInfo.Commission() + posInfo.Swap() + posInfo.Profit();
                  Print("[EOD CLOSE] No-SL mode: closing trade at hour ", _eodDt.hour,
                        " | P&L=$", DoubleToString(_eodPnl, 2));
                  trade.PositionClose(posInfo.Ticket());
                  ResetTradeGlobals(_eodPnl);
               }
            }
         }
      }
   }

   // Always manage open trade on every tick
   if(g_TradeOpen) ManageOpenTrade();
   // v6.35: Manage MA200 boundary pending order (cancel if stale/signal-lost/filled)
   if(g_PendingMA200Ticket != 0) ManageMA200Pending();

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

   // Ensure HA chain cache is current (O(1) check; rebuilds only on new bar or first tick)
   BuildHACache();

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
      UpdateMAValues();  // v6.36: moved from per-tick to per-bar (values only change on bar close)
      SetActiveRange();
      RecalcBias();
      CalcFibPivotLevels();   // recalc on every new bar
      ComputeMurrayLevels();  // Murray Math octave channels from H4
      ComputeMultiDaySR();    // weekly + 3-day S/R levels

      // NB Brain: retrain when due + compute live posteriors every bar (drives EvaluateHAPattern)
      RunNBEveryBar();

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

         // v6.29: Asian observation bar counter
         // Increments each new bar during Asian session; resets when session starts or outside Asian
         if(inAsian) {
            if(bdT.hour == AsianStartHour && bdT.min == 0) {
               g_AsianBarCount  = 1;  // first bar of session
               g_AsianTradeCount = 0; // v6.37: reset slot for the new Asian session
            } else {
               g_AsianBarCount++;
            }
         } else {
            g_AsianBarCount = 0;     // outside Asian — reset
         }
      }

      // v6.32: London and NY observation bar counters — run unconditionally (not inside AsianPrevDayMomEnabled)
      {
         MqlDateTime bdT2; TimeToStruct(barTime, bdT2);
         // London bar counter
         bool inLondon = (bdT2.hour >= LondonStartHour && bdT2.hour < LondonEndHour);
         if(inLondon) {
            if(bdT2.hour == LondonStartHour && bdT2.min == 0) {
               g_LondonBarCount  = 1;
               g_LondonTradeCount = 0; // v6.37: reset slot for the new London session
            } else {
               g_LondonBarCount++;
            }
         } else {
            g_LondonBarCount = 0;
         }
         // NY bar counter — starts at 13:00, independent of London overlap
         bool inNY = (bdT2.hour >= NewYorkStartHour && bdT2.hour < NewYorkEndHour);
         if(inNY) {
            if(bdT2.hour == NewYorkStartHour && bdT2.min == 0) {
               g_NYBarCount  = 1;
               g_NYTradeCount = 0; // v6.37: reset slot for the new NY session
            } else {
               g_NYBarCount++;
            }
         } else {
            g_NYBarCount = 0;
         }

         // --- v6.33: Inter-session momentum — record what the previous session delivered ---
         // On Asian open  : reuse g_PrevDayLastHourDir (already computed by CalcPrevDayLastHourDir).
         // On London open : measure the last 4 confirmed M15 bars = last ~1hr of Asian session.
         // On NY open     : measure the last 4 confirmed M15 bars = last ~1hr before NY (London mid).
         // The stored direction is used below when the observe window completes to classify
         // whether the observe move is a TRAP or a real CONTINUATION / SESSION REVERSAL.
         bool inAsian2 = (bdT2.hour >= AsianStartHour && bdT2.hour < AsianEndHour);
         if(inAsian2 && g_AsianBarCount == 1) {
            // Re-use the prev-day last-hour momentum that the existing CalcPrevDayLastHourDir() computed
            g_PrevSessCloseDir    = g_PrevDayLastHourDir;
            g_PrevSessConsistency = (g_PrevDayLastHourDir != 0) ? 4 : 0;
            g_PrevSessStrong      = (g_PrevDayLastHourDir != 0);
            g_PrevSessName        = "PrevDay";
            if(g_PrevDayLastHourDir != 0)
               Print("[INTER-SESS] Asian open — prevDay closed ",
                     (g_PrevDayLastHourDir > 0 ? "Bull" : "Bear"), " (prevDayMom)");
         }
         if(inLondon && g_LondonBarCount == 1) {
            // bars[1..4] vs bars[2..5]: 4 consecutive mid-price comparisons → direction of Asian last hour
            int _pv = 0;
            for(int _pi = 1; _pi <= 4; _pi++) {
               double _m0 = (iHigh(_Symbol,PERIOD_M15,_pi  ) + iLow(_Symbol,PERIOD_M15,_pi  )) / 2.0;
               double _m1 = (iHigh(_Symbol,PERIOD_M15,_pi+1) + iLow(_Symbol,PERIOD_M15,_pi+1)) / 2.0;
               if(_m0 > _m1 + _Point) _pv++; else if(_m0 < _m1 - _Point) _pv--;
            }
            g_PrevSessCloseDir    = (_pv > 0) ? 1 : (_pv < 0) ? -1 : 0;
            g_PrevSessConsistency = MathAbs(_pv);
            g_PrevSessStrong      = (MathAbs(_pv) >= 3);
            g_PrevSessName        = "Asian";
            Print("[INTER-SESS] London open — Asian closed ",
                  (g_PrevSessCloseDir > 0 ? "Bull" : g_PrevSessCloseDir < 0 ? "Bear" : "Flat"),
                  " consist=", IntegerToString(g_PrevSessConsistency), "/4",
                  g_PrevSessStrong ? " [STRONG]" : " [mixed/weak]");
         }
         if(inNY && g_NYBarCount == 1) {
            // bars[1..4]: last ~1hr before NY open (last hour of London mid-session)
            int _pv = 0;
            for(int _pi = 1; _pi <= 4; _pi++) {
               double _m0 = (iHigh(_Symbol,PERIOD_M15,_pi  ) + iLow(_Symbol,PERIOD_M15,_pi  )) / 2.0;
               double _m1 = (iHigh(_Symbol,PERIOD_M15,_pi+1) + iLow(_Symbol,PERIOD_M15,_pi+1)) / 2.0;
               if(_m0 > _m1 + _Point) _pv++; else if(_m0 < _m1 - _Point) _pv--;
            }
            g_PrevSessCloseDir    = (_pv > 0) ? 1 : (_pv < 0) ? -1 : 0;
            g_PrevSessConsistency = MathAbs(_pv);
            g_PrevSessStrong      = (MathAbs(_pv) >= 3);
            g_PrevSessName        = "London";
            Print("[INTER-SESS] NY open — pre-NY (London) delivered ",
                  (g_PrevSessCloseDir > 0 ? "Bull" : g_PrevSessCloseDir < 0 ? "Bear" : "Flat"),
                  " consist=", IntegerToString(g_PrevSessConsistency), "/4",
                  g_PrevSessStrong ? " [STRONG]" : " [mixed/weak]");
         }

         // --- Session fake-out detection (v6.33 — inter-session aware) ---
         // Fires on the bar AFTER each observe window completes (barCount == ObserveBars+1).
         //
         // Combines three signals:
         //   obsDir   = direction price moved during the observe window (net: first→last bar)
         //   macroDir = macro structure direction (H4/D1 label)
         //   prevDir  = g_PrevSessCloseDir (what the previous session did in its final hour)
         //
         // Classification:
         //   HIGH TRAP   — obsDir opposes BOTH macro AND prevSess (prevSess was strong/clean)
         //                 Example: Asian bearish(strong) + macro bearish → London observe bullish
         //                 = BULL TRAP before London continues the bear.
         //   MEDIUM TRAP — obsDir opposes macro; prevSess is weak/mixed/unknown (less certainty)
         //   CONTINUATION— obsDir aligns with macro (safe to trade in macro direction)
         //   SESS REVERSAL— obsDir aligns with macro but NOT prevSess (true session turn)
         bool justFinishedAsian  = (inAsian2 && AsianObserveBars  > 0 && g_AsianBarCount  == AsianObserveBars  + 1);
         bool justFinishedLondon = (inLondon && LondonObserveBars > 0 && g_LondonBarCount == LondonObserveBars + 1);
         bool justFinishedNY     = (inNY     && NYObserveBars     > 0 && g_NYBarCount     == NYObserveBars     + 1);
         if(justFinishedAsian || justFinishedLondon || justFinishedNY) {
            string sessName  = justFinishedNY ? "NY" : (justFinishedLondon ? "London" : "Asian");
            int    obsN      = justFinishedNY ? NYObserveBars : (justFinishedLondon ? LondonObserveBars : AsianObserveBars);
            double obsOldMid = (iHigh(_Symbol,PERIOD_M15,obsN) + iLow(_Symbol,PERIOD_M15,obsN)) / 2.0;
            double obsNewMid = (iHigh(_Symbol,PERIOD_M15,1   ) + iLow(_Symbol,PERIOD_M15,1   )) / 2.0;
            int obsDir   = (obsNewMid > obsOldMid + _Point) ? 1 : (obsNewMid < obsOldMid - _Point) ? -1 : 0;
            int macroDir = (g_MacroStructLabel == "BULLISH") ? 1 : (g_MacroStructLabel == "BEARISH") ? -1 : 0;
            int prevDir  = g_PrevSessCloseDir;
            string obsStr   = (obsDir   > 0) ? "Bull" : (obsDir   < 0) ? "Bear" : "Flat";
            string macroStr = (macroDir > 0) ? "Bull" : (macroDir < 0) ? "Bear" : "Flat";
            string prevStr  = (prevDir  > 0) ? "Bull" : (prevDir  < 0) ? "Bear" : "—";
            bool prevKnown       = (prevDir  != 0);
            bool obsAlignsMacro  = (obsDir   != 0 && obsDir  == macroDir);
            bool obsAlignsPrev   = (prevKnown      && obsDir  == prevDir);
            bool prevAlignsMacro = (prevKnown      && prevDir == macroDir);
            // HIGH: observe opposes macro AND a strong clean prevSess that agreed with macro
            bool highConf = (!obsAlignsMacro && !obsAlignsPrev && prevKnown
                             && prevAlignsMacro && g_PrevSessStrong && obsDir != 0 && macroDir != 0);
            // MEDIUM: observe opposes macro; prevSess context is weak/mixed/unavailable
            bool medConf  = (!obsAlignsMacro && !highConf && obsDir != 0 && macroDir != 0);
            if(highConf || medConf) {
               g_SessionFakeoutWatch = true;
               g_FakeoutDir          = obsDir;
               g_FakeoutExpiry       = TimeCurrent() + 8 * 15 * 60;  // auto-expire after 2 hours
               g_FakeoutConfidence   = highConf ? "HIGH" : "MEDIUM";
               g_InterSessContext    = g_PrevSessName + "-close:" + prevStr
                                       + (g_PrevSessStrong ? "(S)" : "")
                                       + " | " + sessName + "-obs:" + obsStr
                                       + " | macro:" + macroStr
                                       + " -> " + (obsDir > 0 ? "BULL" : "BEAR")
                                       + " TRAP [" + g_FakeoutConfidence + "]";
               Print("[SESS FAKEOUT ", g_FakeoutConfidence, "] ", g_InterSessContext);
            } else if(obsAlignsMacro) {
               string tag = obsAlignsPrev ? "CONTINUATION" : "SESS REVERSAL";
               g_InterSessContext  = g_PrevSessName + "-close:" + prevStr + " | " + sessName
                                     + "-obs:" + obsStr + " | macro:" + macroStr + " -> " + tag;
               g_FakeoutConfidence = "";
               if(g_SessionFakeoutWatch) {
                  Print("[SESS FAKEOUT CLEARED] ", g_InterSessContext);
                  g_SessionFakeoutWatch = false; g_FakeoutDir = 0; g_FakeoutExpiry = 0;
               } else {
                  Print("[INTER-SESS] ", g_InterSessContext);
               }
            } else {
               // obsDir==0 or macroDir==0 — no strong signal; update context only
               g_InterSessContext = sessName + "-obs:" + obsStr + " | macro:" + macroStr + " (no bias)";
            }
         }
         // Auto-expire stale fakeout watch
         if(g_SessionFakeoutWatch && g_FakeoutExpiry > 0 && TimeCurrent() > g_FakeoutExpiry) {
            Print("[SESS FAKEOUT EXPIRED] watch cleared after timeout | was: ", g_InterSessContext);
            g_SessionFakeoutWatch = false; g_FakeoutDir = 0; g_FakeoutExpiry = 0;
            g_FakeoutConfidence   = "";
         }
      }

      // Market structure analysis (runs on new bar only — uses confirmed bars)
      if(UseSwingStructure)  DetectSwingStructure();
      if(UseMacroStructure)  { DetectMacroStructure(); DrawMacroStructureLevels(); }
      if(UseOrderBlocks)   { DetectOrderBlocks(); DrawOBZones(); }
      if(UseVolumeAnalysis)  AnalyzeVolume();
      if(UseLiquiditySweep)  DetectLiquiditySweep();
      if(UseFairValueGaps)   { DetectFairValueGaps(); DrawFVGZones(); }
      if(UseHPL)             { DetectHPLZones(); DrawHPLZones(); }
      if(UseH4SMC) {
         datetime h4t = iTime(_Symbol, PERIOD_H4, 0);
         if(h4t != g_LastH4BarTime) {   // v6.36: only recompute on new H4 bar
            g_LastH4BarTime = h4t;
            DetectH4OrderBlocks(); DetectH4FairValueGaps(); DrawH4SMCZones();
         }
      }

      // --- FVG H1+H4 overlap confluence detection ---
      DetectFVGOverlap();

      // --- Zone Approach Primer + Asian Bias (v7.00) — always runs to keep ZAP state fresh ---
      DetectZoneApproach();
      ComputeAsianBias();

      // --- Signal scanning: skip when bot has open trade and PauseScanInTrade ---
      // Structure detection above ALWAYS runs (needed for trade management + comeback).
      // Only HA pattern evaluation and macro trend ride arming are paused.
      if(!(PauseScanInTrade && g_TradeOpen)) {
         EvaluateHAPattern();
         CheckMacroTrendRide();   // must run after EvaluateHAPattern (uses g_HAConsecCount, g_MacroBOS, etc.)
      }
   }

   // Re-run NB inference every tick — cheap (9 feature lookups, no training),
   // keeps dashboard and fast-track promotion in sync with live price.
   if(UseNBBrain && g_HaNB_Trained)
      CalcNBLiveProbs();

   // Fire TryEntry when trend signal active, mean reversion qualifies, OR macro trend ride armed.
   // When PauseScanInTrade is on and bot has a trade, the signal scanning above was already
   // skipped, so g_Signal stays WAITING and TryEntry() won't fire. The !g_TradeOpen guard
   // is the ultimate safety net regardless.
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
         // v6.29: Real candle alignment — confirmed bars 1 & 2 must also be bullish
         if(liveOK) {
            double _ftRC1 = iClose(_Symbol, PERIOD_M15, 1);
            double _ftRO1 = iOpen (_Symbol, PERIOD_M15, 1);
            double _ftRC2 = iClose(_Symbol, PERIOD_M15, 2);
            double _ftRO2 = iOpen (_Symbol, PERIOD_M15, 2);
            if(_ftRC1 < _ftRO1 && _ftRC2 < _ftRO2) liveOK = false;  // both confirmed bars bearish = block
         }
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
         // v6.29: Real candle alignment — confirmed bars 1 & 2 must also be bearish
         if(liveOK) {
            double _ftRC1 = iClose(_Symbol, PERIOD_M15, 1);
            double _ftRO1 = iOpen (_Symbol, PERIOD_M15, 1);
            double _ftRC2 = iClose(_Symbol, PERIOD_M15, 2);
            double _ftRO2 = iOpen (_Symbol, PERIOD_M15, 2);
            if(_ftRC1 > _ftRO1 && _ftRC2 > _ftRO2) liveOK = false;  // both confirmed bars bullish = block
         }
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
   g_ConfidenceStatic  = 0; g_ConfidenceArmedBar = 0;  // v6.38: day reset — clear cache
   g_OpenBarCount      = 0;
   g_ConfirmCandleOpen = 0;
   g_MRVArmed          = false;
   g_MRVDir            = 0;
   g_MRVConfirmOpen    = 0;
   g_DailyTradeCount   = 0;
   g_AsianTradeCount   = 0;   // v6.37: full day reset
   g_LondonTradeCount  = 0;
   g_NYTradeCount      = 0;
   g_DailyWins         = 0;
   g_DailyLosses       = 0;
   g_DailyPnL          = 0.0;
   g_DailyManualCount  = 0;
   g_DailyManualWins   = 0;
   g_DailyManualLosses = 0;
   g_DailyManualPnL    = 0.0;
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
   if(g_hATR == INVALID_HANDLE) return;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_hATR, 0, 0, 3, buf) > 0) {
      g_ATR = buf[1];  // use confirmed bar
   }

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
   if(g_hBands == INVALID_HANDLE) return;
   double mid[], upper[], lower[];
   ArraySetAsSeries(mid,   true);
   ArraySetAsSeries(upper, true);
   ArraySetAsSeries(lower, true);
   bool midOK   = (CopyBuffer(g_hBands, 0, 0, 4, mid)   >= 3);  // buffer 0 = SMA midline
   bool upperOK = (CopyBuffer(g_hBands, 1, 0, 4, upper) >= 3);  // buffer 1 = upper band
   bool lowerOK = (CopyBuffer(g_hBands, 2, 0, 4, lower) >= 3);  // buffer 2 = lower band
   if(midOK) {
      g_BollingerMid1 = mid[1];   g_BollingerMid2 = mid[2];
   }
   if(upperOK) {
      g_BollingerUpper1 = upper[1]; g_BollingerUpper2 = upper[2];
   }
   if(lowerOK) {
      g_BollingerLower1 = lower[1]; g_BollingerLower2 = lower[2];
   }
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

   // === H1 CONSECUTIVE OVERRIDE ===
   // The swing-point algorithm requires 3 confirmed bars each side, so during a fast
   // run of same-direction candles the label can lag by several bars.  If the last 4+
   // closed H1 HA candles are all the same direction but the label disagrees, override
   // it immediately — this is what the trader sees on the chart.
   {
      // Compute H1 HA via a 10-bar recursive chain (same formula as BuildHACache)
      const int H1_SEED = 10;
      double h1haO[11], h1haC[11];
      h1haO[H1_SEED] = (iOpen(_Symbol, PERIOD_H1, H1_SEED) + iClose(_Symbol, PERIOD_H1, H1_SEED)) / 2.0;
      h1haC[H1_SEED] = (iOpen(_Symbol, PERIOD_H1, H1_SEED) + iHigh(_Symbol, PERIOD_H1, H1_SEED)
                       + iLow(_Symbol, PERIOD_H1, H1_SEED) + iClose(_Symbol, PERIOD_H1, H1_SEED)) / 4.0;
      for(int k = H1_SEED - 1; k >= 1; k--) {
         double bO = iOpen(_Symbol, PERIOD_H1, k), bH = iHigh(_Symbol, PERIOD_H1, k);
         double bL = iLow (_Symbol, PERIOD_H1, k), bC = iClose(_Symbol, PERIOD_H1, k);
         h1haC[k] = (bO + bH + bL + bC) / 4.0;
         h1haO[k] = (h1haO[k+1] + h1haC[k+1]) / 2.0;
      }
      // Count consecutive H1 HA direction from bar 1 outward
      int h1ConsecDir = 0;
      if     (h1haC[1] > h1haO[1] + _Point) h1ConsecDir =  1;
      else if(h1haC[1] < h1haO[1] - _Point) h1ConsecDir = -1;
      int h1Consec = 0;
      for(int k = 1; k <= 6 && h1ConsecDir != 0; k++) {
         int kDir = (h1haC[k] > h1haO[k] + _Point) ? 1 : ((h1haC[k] < h1haO[k] - _Point) ? -1 : 0);
         if(kDir == h1ConsecDir) h1Consec++;
         else break;
      }
      // Override when 4+ consecutive H1 HA bars disagree with current label
      if(h1Consec >= 4) {
         string ovLabel = (h1ConsecDir == 1) ? "BULLISH" : "BEARISH";
         if(g_StructureLabel != ovLabel) {
            Print("[H1 CONSEC OVERRIDE] ", h1Consec,
                  " consecutive H1 HA candles = ", ovLabel,
                  " — overriding stale label (was ", g_StructureLabel, ")");
            g_StructureLabel = ovLabel;
            // If the new label is the opposite of current, fire a synthetic CHoCH
            // so the entry block (below in TryEntry) also activates.
            int synthDir = h1ConsecDir;   // +1=bull override, -1=bear override
            if(!g_CHoCHActive || g_CHoCHDir != synthDir) {
               g_CHoCHDir    = synthDir;
               g_CHoCHTime   = h1BarTime;
               g_CHoCHActive = true;
               Print("[H1 CONSEC OVERRIDE] Synthetic CHoCH fired: dir=", synthDir);
            }
         }
      }
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
   else if(g_VolRatio <= 0.3)  g_VolumeState = "DEAD";     // v6.36: new tier — hard block
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

   // v6.36: batch copy price arrays instead of per-bar iHigh/iLow
   int copyBars = scanBars + 2;  // need bars 0..scanBars+1
   double fvgHigh[], fvgLow[];
   datetime fvgTime[];
   ArraySetAsSeries(fvgHigh, true);
   ArraySetAsSeries(fvgLow,  true);
   ArraySetAsSeries(fvgTime, true);
   if(CopyHigh(_Symbol, FVGTimeframe, 0, copyBars, fvgHigh) < copyBars) return;
   if(CopyLow (_Symbol, FVGTimeframe, 0, copyBars, fvgLow)  < copyBars) return;
   if(CopyTime(_Symbol, FVGTimeframe, 0, copyBars, fvgTime) < copyBars) return;

   for(int i = 2; i < scanBars; i++)
   {
      // 3-candle pattern: bar i+1 (oldest), bar i (middle), bar i-1 (newest)
      double bar1_high = fvgHigh[i + 1];
      double bar1_low  = fvgLow [i + 1];
      double bar3_high = fvgHigh[i - 1];
      double bar3_low  = fvgLow [i - 1];

      // Bullish FVG: bar3's low > bar1's high (gap between them = unfilled demand)
      if(bar3_low > bar1_high + minGap) {
         double gapHigh = bar3_low;
         double gapLow  = bar1_high;
         datetime gapT  = fvgTime[i];
         if(!FVGExists(gapHigh, gapLow, 1))
            AddFVG(gapHigh, gapLow, 1, gapT);
      }

      // Bearish FVG: bar3's high < bar1's low (gap between them = unfilled supply)
      if(bar3_high < bar1_low - minGap) {
         double gapHigh = bar1_low;
         double gapLow  = bar3_high;
         datetime gapT  = fvgTime[i];
         if(!FVGExists(gapHigh, gapLow, -1))
            AddFVG(gapHigh, gapLow, -1, gapT);
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
//| HORIZONTAL PRICE LEVEL (HPL) DETECTION                           |
//| Scans recent M15 bars for price levels where bar highs (resist)  |
//| or bar lows (support) cluster within HPLClusterPips of each      |
//| other at least HPLMinTouches times = emergent S/R zone.          |
//+------------------------------------------------------------------+
void DetectHPLZones()
{
   // Reset block flags
   g_HPLResistBlock  = false;
   g_HPLSupportBlock = false;
   g_HPLResistHigh   = 0; g_HPLResistLow   = 0;
   g_HPLSupportHigh  = 0; g_HPLSupportLow  = 0;

   if(!UseHPL) { g_HPLCount = 0; return; }

   int totalBars = iBars(_Symbol, PERIOD_M15);
   int scanBars  = MathMin(HPLScanBars, totalBars - 2);
   if(scanBars < HPLMinTouches) { g_HPLCount = 0; return; }

   double clusterPips = HPLClusterPips * _Point * 10.0;  // pips → price

   // Collect all bar highs and lows with their bar times
   double  barHighs[]; datetime barHighTimes[];
   double  barLows[];  datetime barLowTimes[];
   ArrayResize(barHighs,     scanBars);
   ArrayResize(barHighTimes, scanBars);
   ArrayResize(barLows,      scanBars);
   ArrayResize(barLowTimes,  scanBars);

   for(int i = 1; i <= scanBars; i++) {   // skip forming bar 0
      barHighs[i-1]     = iHigh(_Symbol, PERIOD_M15, i);
      barHighTimes[i-1] = iTime(_Symbol, PERIOD_M15, i);
      barLows[i-1]      = iLow (_Symbol, PERIOD_M15, i);
      barLowTimes[i-1]  = iTime(_Symbol, PERIOD_M15, i);
   }

   // ─── cluster helper: given a sorted array find groups ────────────────────────
   // We'll use a simple O(n²) pass — n ≤ 100, perfectly acceptable.
   // For each candidate level (each bar H or L), count how many others lie within
   // clusterPips. Record the best cluster per distinct region.

   ArrayResize(g_HPLZones, (HPLMaxZones * 2) + 4);
   g_HPLCount = 0;

   // Process RESISTANCE levels (bar highs)
   int resistFound = 0;
   bool usedHigh[];
   ArrayResize(usedHigh, scanBars);
   ArrayInitialize(usedHigh, false);

   for(int i = 0; i < scanBars && resistFound < HPLMaxZones; i++) {
      if(usedHigh[i]) continue;
      double anchor = barHighs[i];
      double zHigh  = anchor;
      double zLow   = anchor;
      int    count  = 1;
      datetime earliest = barHighTimes[i];

      for(int j = i + 1; j < scanBars; j++) {
         if(usedHigh[j]) continue;
         if(MathAbs(barHighs[j] - anchor) <= clusterPips) {
            if(barHighs[j] > zHigh) zHigh = barHighs[j];
            if(barHighs[j] < zLow)  zLow  = barHighs[j];
            if(barHighTimes[j] < earliest) earliest = barHighTimes[j];
            usedHigh[j] = true;
            count++;
         }
      }
      usedHigh[i] = true;

      if(count >= HPLMinTouches) {
         // Check if this cluster is already covered by a previously added zone
         bool duplicate = false;
         for(int z = 0; z < g_HPLCount; z++) {
            if(g_HPLZones[z].dir == 1 &&
               MathAbs((g_HPLZones[z].high + g_HPLZones[z].low) / 2.0 - (zHigh + zLow) / 2.0) < clusterPips * 2)
            { duplicate = true; break; }
         }
         if(!duplicate) {
            double buf = 0.5 * _Point * 10.0;   // 0.5 pip visual buffer
            g_HPLZones[g_HPLCount].high      = zHigh + buf;
            g_HPLZones[g_HPLCount].low       = zLow  - buf;
            g_HPLZones[g_HPLCount].dir       = 1;   // resistance
            g_HPLZones[g_HPLCount].touches   = count;
            g_HPLZones[g_HPLCount].firstTime = earliest;
            g_HPLZones[g_HPLCount].broken    = false;
            g_HPLCount++;
            resistFound++;
         }
      }
   }

   // Process SUPPORT levels (bar lows)
   int supportFound = 0;
   bool usedLow[];
   ArrayResize(usedLow, scanBars);
   ArrayInitialize(usedLow, false);

   for(int i = 0; i < scanBars && supportFound < HPLMaxZones; i++) {
      if(usedLow[i]) continue;
      double anchor = barLows[i];
      double zHigh  = anchor;
      double zLow   = anchor;
      int    count  = 1;
      datetime earliest = barLowTimes[i];

      for(int j = i + 1; j < scanBars; j++) {
         if(usedLow[j]) continue;
         if(MathAbs(barLows[j] - anchor) <= clusterPips) {
            if(barLows[j] > zHigh) zHigh = barLows[j];
            if(barLows[j] < zLow)  zLow  = barLows[j];
            if(barLowTimes[j] < earliest) earliest = barLowTimes[j];
            usedLow[j] = true;
            count++;
         }
      }
      usedLow[i] = true;

      if(count >= HPLMinTouches) {
         bool duplicate = false;
         for(int z = 0; z < g_HPLCount; z++) {
            if(g_HPLZones[z].dir == -1 &&
               MathAbs((g_HPLZones[z].high + g_HPLZones[z].low) / 2.0 - (zHigh + zLow) / 2.0) < clusterPips * 2)
            { duplicate = true; break; }
         }
         if(!duplicate) {
            double buf = 0.5 * _Point * 10.0;
            g_HPLZones[g_HPLCount].high      = zHigh + buf;
            g_HPLZones[g_HPLCount].low       = zLow  - buf;
            g_HPLZones[g_HPLCount].dir       = -1;  // support
            g_HPLZones[g_HPLCount].touches   = count;
            g_HPLZones[g_HPLCount].firstTime = earliest;
            g_HPLZones[g_HPLCount].broken    = false;
            g_HPLCount++;
            supportFound++;
         }
      }
   }

   // Mark zones as broken
   double lastClose = iClose(_Symbol, PERIOD_M15, 1);
   double breakPips = HPLBreakPips * _Point * 10.0;
   for(int z = 0; z < g_HPLCount; z++) {
      if(g_HPLZones[z].dir == 1  && lastClose > g_HPLZones[z].high + breakPips)
         g_HPLZones[z].broken = true;   // resistance cleanly broken upward
      if(g_HPLZones[z].dir == -1 && lastClose < g_HPLZones[z].low  - breakPips)
         g_HPLZones[z].broken = true;   // support cleanly broken downward
   }

   // Determine block flags based on current bid price
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double bufPx  = HPLBlockBufferPips * _Point * 10.0;

   for(int z = 0; z < g_HPLCount; z++) {
      if(g_HPLZones[z].broken) continue;
      if(g_HPLZones[z].dir == 1) {
         // Resistance — block BUY if price is inside zone or within buffer below it
         if(bid >= g_HPLZones[z].low - bufPx && bid <= g_HPLZones[z].high + bufPx) {
            if(!g_HPLResistBlock || g_HPLZones[z].low < g_HPLResistLow) {
               g_HPLResistBlock = true;
               g_HPLResistHigh  = g_HPLZones[z].high;
               g_HPLResistLow   = g_HPLZones[z].low;
            }
         }
      } else {
         // Support — block SELL if price is inside zone or within buffer above it
         if(bid >= g_HPLZones[z].low - bufPx && bid <= g_HPLZones[z].high + bufPx) {
            if(!g_HPLSupportBlock || g_HPLZones[z].high > g_HPLSupportHigh) {
               g_HPLSupportBlock = true;
               g_HPLSupportHigh  = g_HPLZones[z].high;
               g_HPLSupportLow   = g_HPLZones[z].low;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| DRAW HPL ZONES ON CHART as semi-transparent rectangles            |
//| Resistance = semi-transparent orange, Support = semi-transparent  |
//| teal. Broken zones drawn in dim grey.                            |
//+------------------------------------------------------------------+
void DrawHPLZones()
{
   // Remove stale HPL rectangles
   for(int i = ObjectsTotal(0, 0) - 1; i >= 0; i--) {
      string nm = ObjectName(0, i, 0);
      if(StringFind(nm, "HABOT_HPL_") == 0)
         ObjectDelete(0, nm);
   }

   if(!UseHPL || g_HPLCount == 0) return;

   datetime tEnd = TimeCurrent() + 3600 * 6;  // extend 6 h to the right

   for(int z = 0; z < g_HPLCount; z++) {
      string nm    = "HABOT_HPL_" + (g_HPLZones[z].dir == 1 ? "R_" : "S_") + IntegerToString(z);
      bool   isResist = (g_HPLZones[z].dir == 1);
      bool   broken   = g_HPLZones[z].broken;

      color  zoneClr  = broken ? clrDimGray
                                : (isResist ? clrOrangeRed : clrTeal);
      string label    = (isResist ? "Resist HPL " : "Support HPL ") +
                        IntegerToString(g_HPLZones[z].touches) + "t" +
                        (broken ? " [BROKEN]" : "");

      if(ObjectFind(0, nm) < 0)
         ObjectCreate(0, nm, OBJ_RECTANGLE, 0,
                      g_HPLZones[z].firstTime, g_HPLZones[z].high,
                      tEnd,                    g_HPLZones[z].low);
      else {
         ObjectSetInteger(0, nm, OBJPROP_TIME,  0, g_HPLZones[z].firstTime);
         ObjectSetDouble (0, nm, OBJPROP_PRICE, 0, g_HPLZones[z].high);
         ObjectSetInteger(0, nm, OBJPROP_TIME,  1, tEnd);
         ObjectSetDouble (0, nm, OBJPROP_PRICE, 1, g_HPLZones[z].low);
      }
      ObjectSetInteger(0, nm, OBJPROP_COLOR,      zoneClr);
      ObjectSetInteger(0, nm, OBJPROP_STYLE,      STYLE_SOLID);
      ObjectSetInteger(0, nm, OBJPROP_WIDTH,       1);
      ObjectSetInteger(0, nm, OBJPROP_FILL,        true);
      ObjectSetInteger(0, nm, OBJPROP_BACK,        true);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE,  false);
      ObjectSetString (0, nm, OBJPROP_TEXT,        label);
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

   // v6.36: batch copy price arrays
   int copyBars = scanBars + 2;
   double h4High[], h4Low[];
   datetime h4Time[];
   ArraySetAsSeries(h4High, true);
   ArraySetAsSeries(h4Low,  true);
   ArraySetAsSeries(h4Time, true);
   if(CopyHigh(_Symbol, PERIOD_H4, 0, copyBars, h4High) < copyBars) return;
   if(CopyLow (_Symbol, PERIOD_H4, 0, copyBars, h4Low)  < copyBars) return;
   if(CopyTime(_Symbol, PERIOD_H4, 0, copyBars, h4Time) < copyBars) return;

   for(int i = 2; i < scanBars; i++)
   {
      double bar1_high = h4High[i + 1];
      double bar1_low  = h4Low [i + 1];
      double bar3_high = h4High[i - 1];
      double bar3_low  = h4Low [i - 1];

      // Bullish H4 FVG
      if(bar3_low > bar1_high + minGap) {
         double   gapHigh = bar3_low;
         double   gapLow  = bar1_high;
         datetime gapTime = h4Time[i];
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
         datetime gapTime = h4Time[i];
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
//| BUILD HA CHAIN CACHE — proper recursive Heikin-Ashi calculation  |
//| Seeds from bar 50 (raw OHLC midpoint) and iterates forward to   |
//| bar 0.  After ~15 bars the seed error is negligible (<0.1 pip). |
//| Called once per new bar; bar 0 is recomputed on-the-fly in      |
//| CalcHA() using the cached bar 1 values + current tick OHLC.     |
//+------------------------------------------------------------------+
void BuildHACache()
{
   datetime curBar = iTime(_Symbol, PERIOD_M15, 0);
   if(curBar == g_HACacheBar && g_HACacheBar != 0) return;  // already current
   g_HACacheBar = curBar;

   // Seed: use raw OHLC midpoint of bar 50 as the initial haOpen.
   // The error from this approximation decays exponentially and is
   // negligible by bar ~35 (well before the bars we actually read).
   int seedIdx = 49;
   double seedO = iOpen (_Symbol, PERIOD_M15, seedIdx + 1);
   double seedH = iHigh (_Symbol, PERIOD_M15, seedIdx + 1);
   double seedL = iLow  (_Symbol, PERIOD_M15, seedIdx + 1);
   double seedC = iClose(_Symbol, PERIOD_M15, seedIdx + 1);
   double prevHaO = (seedO + seedC) / 2.0;
   double prevHaC = (seedO + seedH + seedL + seedC) / 4.0;

   // Forward iterate from oldest cached bar to newest
   for(int i = seedIdx; i >= 0; i--)
   {
      double o = iOpen (_Symbol, PERIOD_M15, i);
      double h = iHigh (_Symbol, PERIOD_M15, i);
      double l = iLow  (_Symbol, PERIOD_M15, i);
      double c = iClose(_Symbol, PERIOD_M15, i);

      double haC = (o + h + l + c) / 4.0;
      double haO = (prevHaO + prevHaC) / 2.0;
      double haH = MathMax(h, MathMax(haO, haC));
      double haL = MathMin(l, MathMin(haO, haC));

      g_HACacheO[i] = haO;
      g_HACacheH[i] = haH;
      g_HACacheL[i] = haL;
      g_HACacheC[i] = haC;

      prevHaO = haO;
      prevHaC = haC;
   }
}

//+------------------------------------------------------------------+
//| HEIKEN ASHI CALCULATION for bar at index idx                     |
//| Reads from the pre-built chain cache (bars 1-49) or computes    |
//| bar 0 on-the-fly using current tick data + cached bar 1 values. |
//+------------------------------------------------------------------+
void CalcHA(int idx, double &haO, double &haH, double &haL, double &haC)
{
   // Bar 0 (forming): recompute every tick using CURRENT OHLC + cached prev bar
   if(idx == 0 && g_HACacheBar != 0)
   {
      double o = iOpen (_Symbol, PERIOD_M15, 0);
      double h = iHigh (_Symbol, PERIOD_M15, 0);
      double l = iLow  (_Symbol, PERIOD_M15, 0);
      double c = iClose(_Symbol, PERIOD_M15, 0);
      haC = (o + h + l + c) / 4.0;
      haO = (g_HACacheO[1] + g_HACacheC[1]) / 2.0;
      haH = MathMax(h, MathMax(haO, haC));
      haL = MathMin(l, MathMin(haO, haC));
      return;
   }

   // Closed bars (1-49): read directly from cache
   if(idx >= 1 && idx < 50 && g_HACacheBar != 0)
   {
      haO = g_HACacheO[idx];
      haH = g_HACacheH[idx];
      haL = g_HACacheL[idx];
      haC = g_HACacheC[idx];
      return;
   }

   // Fallback for indices beyond cache or cache not yet built —
   // uses a local 10-step recursion (much better than old 2-step)
   double chainO[12], chainC[12];
   // Seed from idx+11
   chainO[11] = (iOpen(_Symbol, PERIOD_M15, idx + 11) + iClose(_Symbol, PERIOD_M15, idx + 11)) / 2.0;
   chainC[11] = (iOpen(_Symbol, PERIOD_M15, idx + 11) + iHigh(_Symbol, PERIOD_M15, idx + 11)
                + iLow(_Symbol, PERIOD_M15, idx + 11) + iClose(_Symbol, PERIOD_M15, idx + 11)) / 4.0;
   for(int j = 10; j >= 0; j--)
   {
      int bi = idx + j;
      double bO = iOpen(_Symbol, PERIOD_M15, bi), bH = iHigh(_Symbol, PERIOD_M15, bi);
      double bL = iLow(_Symbol, PERIOD_M15, bi),  bC = iClose(_Symbol, PERIOD_M15, bi);
      chainC[j] = (bO + bH + bL + bC) / 4.0;
      chainO[j] = (chainO[j+1] + chainC[j+1]) / 2.0;
   }
   haO = chainO[0];
   haC = chainC[0];
   double oh = iHigh(_Symbol, PERIOD_M15, idx), ol = iLow(_Symbol, PERIOD_M15, idx);
   haH = MathMax(oh, MathMax(haO, haC));
   haL = MathMin(ol, MathMin(haO, haC));
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

// HA Doji: body < 25% of total candle range = indecision even if technically directional.
// This catches spinning tops that HADir() still classifies as bull or bear.
// After a doji, the consecutive clean-candle counter is broken and must restart fresh.
bool IsHADoji(int idx)
{
   double haO, haH, haL, haC;
   CalcHA(idx, haO, haH, haL, haC);
   double range = haH - haL;
   if(range < _Point * 2) return true;   // essentially flat = hard doji
   return (MathAbs(haC - haO) < range * 0.25);
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

   // 9. Bollinger band headroom — room to move in trade direction
   //    BUY:  price below upper band → room to rise (+1); prev-day bullish momentum aligned → extra (+1)
   //    SELL: price above lower band → room to fall (+1); prev-day bearish momentum aligned → extra (+1)
   //    Asian session with alignment → additional boost (+1, up to +3 total)
   //    If price is at/past the band in trade direction → HARD (no bonus)
   g_BollRoomLabel = "";
   if(g_BollingerUpper1 > 0 && g_BollingerLower1 > 0) {
      double bollTol = 2.0 * _Point * 10;  // 2-pip tolerance
      bool bollRoom = false;
      if(tradeDir == 1 && price < g_BollingerUpper1 - bollTol) {
         bollRoom = true;
      } else if(tradeDir == -1 && price > g_BollingerLower1 + bollTol) {
         bollRoom = true;
      }
      if(bollRoom) {
         softScore += 1;  // base: room to move within Bollinger envelope
         g_BollRoomLabel = "ROOM";
         // Prev-day momentum aligned → price was already trending this way at close
         if(g_PrevDayLastHourDir == tradeDir) softScore += 1;
         // Asian session + prev-day alignment → strongest carry-over signal
         MqlDateTime _hdt; TimeToStruct(TimeCurrent(), _hdt);
         bool _inAsianH = (_hdt.hour >= AsianStartHour && _hdt.hour < AsianEndHour);
         if(_inAsianH && g_PrevDayLastHourDir == tradeDir) softScore += 1;
      } else {
         g_BollRoomLabel = "CAPPED";
      }
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
//| NB BRAIN — Lightweight Self-Training Naive Bayes Engine          |
//| Learns P(WIN | 9 market features) from the last NB_LookbackBars. |
//| Provides an independent probabilistic gate alongside the         |
//| additive confidence scorer. Retrained every NB_RetrainBars bars. |
//+------------------------------------------------------------------+

//--- Feature bin definitions (9 features) --------------------------
// F0: Range zone     — 3 bins: 0=LOW(LOWER_THIRD) / 1=MID / 2=HIGH(UPPER_THIRD)
// F1: Session        — 4 bins: 0=Asian / 1=London / 2=NY / 3=Off
// F2: HA streak tier — 4 bins: 0=weak(1) / 1=mild(2) / 2=strong(3-4) / 3=v.strong(5+)
// F3: Volume state   — 3 bins: 0=Low / 1=Normal / 2=High
// F4: Structure      — 3 bins: 0=BEARISH / 1=NEUTRAL / 2=BULLISH
// F5: FVG alignment  — 3 bins: 0=none / 1=aligned / 2=opposing
// F6: OB alignment   — 3 bins: 0=none / 1=aligned / 2=opposing
// F7: Liq sweep      — 3 bins: 0=none / 1=aligned / 2=opposing
// F8: Dir flip       — 2 bins: 0=no flip / 1=flip (bar1 dir opposite bar2 — momentum reversal)

void InitNBBrain()
{
   g_HaNB_FeatureBins[0] = 3;  // F0: zone 0=LOWER/1=MID/2=UPPER
   g_HaNB_FeatureBins[1] = 4;  // F1: session 0=Asian/1=London/2=NY/3=Off
   g_HaNB_FeatureBins[2] = 4;  // F2: 0=strongBear/1=mildBear/2=mildBull/3=strongBull (absolute)
   g_HaNB_FeatureBins[3] = 3;  // F3: volume 0=Low/1=Normal/2=High
   g_HaNB_FeatureBins[4] = 3;  // F4: structure 0=BEARISH/1=NEUTRAL/2=BULLISH
   g_HaNB_FeatureBins[5] = 3;  // F5: FVG 0=none/1=BullFVG/2=BearFVG (absolute)
   g_HaNB_FeatureBins[6] = 3;  // F6: OB  0=none/1=nearBullOB/2=nearBearOB (absolute)
   g_HaNB_FeatureBins[7] = 3;  // F7: Sweep 0=none/1=bullSweep->UP/2=bearSweep->DOWN (absolute)
   g_HaNB_FeatureBins[8] = 2;  // F8: dir flip 0=no/1=yes
   // Flat uniform priors — overwritten on first train
   for(int c = 0; c < HA_NB_CLASSES; c++) g_HaNB_Prior[c] = 1.0 / HA_NB_CLASSES;
   for(int c = 0; c < HA_NB_CLASSES; c++)
      for(int f = 0; f < HA_NB_FEATURES; f++)
         for(int v = 0; v < HA_NB_MAX_BINS; v++)
            g_HaNB_Likelihood[c][f][v] = 1.0 / g_HaNB_FeatureBins[f];
   g_HaNB_Trained    = false;
   g_HaNB_BarCounter = 0;
   g_NBBuyProb = g_NBSellProb = 0.0;
   g_NBPredDir = 0;
   // Initialise session-stratified model state
   for(int _s_ = 0; _s_ < 3; _s_++) {
      g_HaNB_Trained_S[_s_]     = false;
      g_HaNB_SampleCount_S[_s_] = 0;
      g_OL_TotalUpdates[_s_]    = 0;
      for(int _c_ = 0; _c_ < HA_NB_CLASSES; _c_++) {
         g_HaNB_Prior_S[_s_][_c_] = 1.0 / HA_NB_CLASSES;
         g_OL_ClassCounts[_s_][_c_] = 0;
         for(int _f_ = 0; _f_ < HA_NB_FEATURES; _f_++)
            for(int _v_ = 0; _v_ < HA_NB_MAX_BINS; _v_++) {
               g_HaNB_Likelihood_S[_s_][_c_][_f_][_v_] = 1.0 / g_HaNB_FeatureBins[_f_];
               g_OL_FCounts[_s_][_c_][_f_][_v_] = 0;
            }
      }
   }
   g_PrevBarFeatValid = false;
   g_CurNBSessionIdx  = 3;
   g_PrevNBSessionIdx = 3;
   // Persistent MA handles for training loop — avoids per-bar iMA() overhead
   if(g_hNB_MA10 == INVALID_HANDLE)
      g_hNB_MA10 = iMA(_Symbol, PERIOD_M15, 10, 0, MODE_SMA, PRICE_CLOSE);
   if(g_hNB_MA30 == INVALID_HANDLE)
      g_hNB_MA30 = iMA(_Symbol, PERIOD_M15, 30, 0, MODE_SMA, PRICE_CLOSE);
}

// Get zone bin from price relative to range (mirrors ClassifyZone logic, direction-aware)
// Returns 0=LOW / 1=MID / 2=HIGH
int GetNBZoneBin(double price, double rangeH, double rangeL)
{
   if(rangeH <= 0 || rangeL <= 0 || rangeH == rangeL) return 1; // MID fallback
   double rangeSize = rangeH - rangeL;
   double pos       = (price - rangeL) / rangeSize;
   double midBot    = 0.5 - MidZonePct / 2.0;
   double midTop    = 0.5 + MidZonePct / 2.0;
   if(pos < midBot) return 0; // LOWER_THIRD
   if(pos > midTop) return 2; // UPPER_THIRD
   return 1;                  // MID_ZONE
}

// Get session bin from an hour value
int GetNBSessionBin(int h)
{
   if(h >= AsianStartHour   && h < AsianEndHour)   return 0;
   if(h >= LondonStartHour  && h < LondonEndHour)  return 1;
   if(h >= NewYorkStartHour && h < NewYorkEndHour)  return 2;
   return 3;
}

// Reconstruct HA for a single historical bar index using a 5-bar seed
// Returns HA Open and HA Close (sufficient for direction + streak)
void GetHAHistBar(int barIdx, double &haO, double &haC)
{
   // Seed using 5 bars back to get a reasonable HA Open
   int seedStart = barIdx + 5;
   double seedO = iOpen (_Symbol, PERIOD_M15, seedStart);
   double seedH = iHigh (_Symbol, PERIOD_M15, seedStart);
   double seedL = iLow  (_Symbol, PERIOD_M15, seedStart);
   double seedC = iClose(_Symbol, PERIOD_M15, seedStart);
   double prevHAO = (seedO + seedH + seedL + seedC) / 4.0;
   double prevHAC = prevHAO;

   // Walk forward from seedStart to barIdx
   for(int i = seedStart - 1; i >= barIdx; i--) {
      double o = iOpen (_Symbol, PERIOD_M15, i);
      double h = iHigh (_Symbol, PERIOD_M15, i);
      double l = iLow  (_Symbol, PERIOD_M15, i);
      double c = iClose(_Symbol, PERIOD_M15, i);
      double curHAC = (o + h + l + c) / 4.0;
      double curHAO = (prevHAO + prevHAC) / 2.0;
      prevHAO = curHAO;
      prevHAC = curHAC;
   }
   haO = prevHAO;
   haC = prevHAC;
}

// Count consecutive candles in the same direction at barIdx (look back up to 8 bars).
// Uses real OHLC close vs open — 10-20x faster than HA reconstruction; good approximation for training.
int GetNBHAConsecBin(int barIdx, int directionForBuy)
{
   int consec = 0;
   for(int i = barIdx; i <= barIdx + 7; i++) {
      double o = iOpen (_Symbol, PERIOD_M15, i);
      double c = iClose(_Symbol, PERIOD_M15, i);
      bool isBull = (c > o + _Point);
      bool isBear = (c < o - _Point);
      if(directionForBuy == 1 && isBull)  consec++;
      else if(directionForBuy == -1 && isBear) consec++;
      else break;
   }
   // Bin: 0=weak(1), 1=mild(2), 2=strong(3-4), 3=v.strong(5+)
   if(consec <= 1) return 0;
   if(consec == 2) return 1;
   if(consec <= 4) return 2;
   return 3;
}

// Build live feature vector — all features ABSOLUTE (direction-independent).
// Classes trained as UP(0)/DOWN(1)/NEUTRAL(2), so no tradeDir dependency in features.
void GetNBLiveFeatures(int &out[])
{
   ArrayResize(out, HA_NB_FEATURES);

   // F0: range zone (absolute: 0=LOWER / 1=MID / 2=UPPER)
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   out[0] = GetNBZoneBin(bid, g_RangeHigh, g_RangeLow);

   // F1: session
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   out[1] = GetNBSessionBin(dt.hour);

   // F2: absolute HA direction + streak — uses both bar1 (confirmed) and bar0 (forming) for
   // tick-by-tick sensitivity: consensus makes it strong, divergence makes it mild.
   {
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double b0o  = iOpen(_Symbol, PERIOD_M15, 0);
      double c1   = iClose(_Symbol, PERIOD_M15, 1);
      double o1   = iOpen (_Symbol, PERIOD_M15, 1);
      int    dir0 = (bid > b0o + _Point*3)  ? 1 : (bid < b0o - _Point*3)  ? -1 : 0;  // forming bar
      int    dir1 = (c1  > o1  + _Point)    ? 1 : (c1  < o1  - _Point)    ? -1 : 0;  // last closed
      int    net  = dir0 + dir1;  // -2..+2
      if(net >= 2)       out[2] = (g_HAConsecCount >= 3) ? 3 : 2;  // both bull
      else if(net <= -2) out[2] = (g_HAConsecCount >= 3) ? 0 : 1;  // both bear
      else if(net == 1)  out[2] = 2;   // mild bull
      else if(net == -1) out[2] = 1;   // mild bear
      else               out[2] = 1;   // flat/mixed
   }

   // F3: volume state (direction-agnostic: 0=Low/1=Normal/2=High)
   out[3] = (g_VolumeState == "LOW" || g_VolumeState == "DEAD") ? 0
          : (g_VolumeState == "HIGH" || g_VolumeState == "ABOVE_AVG") ? 2 : 1;

   // F4: market structure (absolute: 0=BEARISH/1=NEUTRAL/2=BULLISH)
   out[4] = (g_StructureLabel == "BULLISH") ? 2 : (g_StructureLabel == "BEARISH") ? 0 : 1;

   // F5: 3-bar OHLC Fair Value Gap (live bars 0/1/2) — consistent with training detection.
   // Bullish FVG: bar0.low > bar2.high (gap below current price — bullish imbalance)
   // Bearish FVG: bar0.high < bar2.low (gap above current price — bearish imbalance)
   {
      double l0 = iLow (_Symbol, PERIOD_M15, 0);
      double h0 = iHigh(_Symbol, PERIOD_M15, 0);
      double h2 = iHigh(_Symbol, PERIOD_M15, 2);
      double l2 = iLow (_Symbol, PERIOD_M15, 2);
      // Use live bid as bar0 low bound (forming bar)
      l0 = MathMin(l0, SymbolInfoDouble(_Symbol, SYMBOL_BID));
      h0 = MathMax(h0, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
      if(l0 > h2 + _Point * 2)        out[5] = 1;  // bullish FVG
      else if(h0 < l2 - _Point * 2)   out[5] = 2;  // bearish FVG
      else                             out[5] = 0;
   }

   // F6: always 0 — OB replay not available historically; consistent with training
   out[6] = 0;

   // F7: always 0 — Sweep replay not available historically; consistent with training
   out[7] = 0;

   // F8: direction flip — bar1 vs bar2 (confirmed) OR live bar vs bar1 (forming)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double b0o = iOpen (_Symbol, PERIOD_M15, 0);
      double c1  = iClose(_Symbol, PERIOD_M15, 1);
      double o1  = iOpen (_Symbol, PERIOD_M15, 1);
      double c2  = iClose(_Symbol, PERIOD_M15, 2);
      double o2  = iOpen (_Symbol, PERIOD_M15, 2);
      int dir0 = (bid > b0o + _Point*3)  ? 1 : (bid < b0o - _Point*3)  ? -1 : 0;
      int dir1 = (c1  > o1  + _Point)    ? 1 : (c1  < o1  - _Point)    ? -1 : 0;
      int dir2 = (c2  > o2  + _Point)    ? 1 : (c2  < o2  - _Point)    ? -1 : 0;
      bool flip_1v2 = (dir1 != 0 && dir2 != 0 && dir1 != dir2);  // confirmed bar1 vs bar2
      bool flip_0v1 = (dir0 != 0 && dir1 != 0 && dir0 != dir1);  // forming bar vs bar1
      out[8] = (flip_1v2 || flip_0v1) ? 1 : 0;
   }
}

// Build historical feature vector for training at barIdx.
// All features ABSOLUTE (no tradeDir). Uses persistent g_hNB_MA10/MA30 — no handle creation in loop.
void GetNBHistoricalFeatures(int barIdx, int &out[])
{
   ArrayResize(out, HA_NB_FEATURES);

   // F0: zone approximated from D1 bar
   int d1Idx = barIdx / 96 + 1;
   double dH = iHigh(_Symbol, PERIOD_D1, d1Idx);
   double dL = iLow (_Symbol, PERIOD_D1, d1Idx);
   double bC = iClose(_Symbol, PERIOD_M15, barIdx);
   out[0] = GetNBZoneBin(bC, dH, dL);

   // F1: session
   datetime barTime = iTime(_Symbol, PERIOD_M15, barIdx);
   MqlDateTime bdt; TimeToStruct(barTime, bdt);
   out[1] = GetNBSessionBin(bdt.hour);

   // F2: absolute direction + streak (0=strongBear/1=mildBear/2=mildBull/3=strongBull)
   // Net bull-bear in last 3+current bar; maps to 4 absolute bins
   {
      int bulls = 0, bears = 0;
      for(int k = barIdx; k <= barIdx + 3; k++) {
         double ko = iOpen (_Symbol, PERIOD_M15, k);
         double kc = iClose(_Symbol, PERIOD_M15, k);
         if(kc > ko + _Point) bulls++;
         else if(kc < ko - _Point) bears++;
      }
      int net = bulls - bears;
      out[2] = (net >= 2) ? 3 : (net >= 1) ? 2 : (net <= -2) ? 0 : 1;
   }

   // F3: volume state
   long volBuf[21];
   if(CopyTickVolume(_Symbol, PERIOD_M15, barIdx, 21, volBuf) == 21) {
      long vsum = 0;
      for(int i = 1; i <= 20; i++) vsum += volBuf[i];
      double vavg = (double)vsum / 20.0;
      double vr = (vavg > 0) ? (double)volBuf[0] / vavg : 1.0;
      out[3] = (vr < 0.6) ? 0 : (vr > 1.5) ? 2 : 1;
   } else out[3] = 1;

   // F4: structure proxy from persistent SMA handles (no per-bar handle creation)
   {
      double sma10Buf[1], sma30Buf[1];
      bool hasMA = (g_hNB_MA10 != INVALID_HANDLE && g_hNB_MA30 != INVALID_HANDLE &&
                    CopyBuffer(g_hNB_MA10, 0, barIdx, 1, sma10Buf) == 1 &&
                    CopyBuffer(g_hNB_MA30, 0, barIdx, 1, sma30Buf) == 1);
      if(hasMA) {
         double gap = sma10Buf[0] - sma30Buf[0];
         out[4] = (gap > 2.0*_Point*10) ? 2 : (gap < -2.0*_Point*10) ? 0 : 1;
      } else out[4] = 1;
   }

   // F5: 3-bar OHLC Fair Value Gap at barIdx — same definition as live inference.
   // Bullish: low[barIdx] > high[barIdx+2]; Bearish: inverse.
   {
      int avail = Bars(_Symbol, PERIOD_M15);
      if(barIdx + 2 < avail) {
         double l0h = iLow (_Symbol, PERIOD_M15, barIdx);
         double h0h = iHigh(_Symbol, PERIOD_M15, barIdx);
         double h2h = iHigh(_Symbol, PERIOD_M15, barIdx + 2);
         double l2h = iLow (_Symbol, PERIOD_M15, barIdx + 2);
         if(l0h > h2h + _Point * 2)       out[5] = 1;  // bullish FVG
         else if(h0h < l2h - _Point * 2)  out[5] = 2;  // bearish FVG
         else                              out[5] = 0;
      } else out[5] = 0;
   }
   // F6,F7: OB/Sweep replay not feasible historically — keep 0 (consistent with prior training)
   out[6] = 0;
   out[7] = 0;

   // F8: direction flip from bar direction change
   {
      double curO = iOpen (_Symbol, PERIOD_M15, barIdx);
      double curC = iClose(_Symbol, PERIOD_M15, barIdx);
      double prvO = iOpen (_Symbol, PERIOD_M15, barIdx + 1);
      double prvC = iClose(_Symbol, PERIOD_M15, barIdx + 1);
      int curDir = (curC > curO + _Point) ? 1 : (curC < curO - _Point) ? -1 : 0;
      int prvDir = (prvC > prvO + _Point) ? 1 : (prvC < prvO - _Point) ? -1 : 0;
      out[8] = (curDir != 0 && prvDir != 0 && curDir != prvDir) ? 1 : 0;
   }
}

// Train NB model from last NB_LookbackBars of M15 history.
// Classes are absolute: 0=UP (rose >= ATR*mult) / 1=DOWN (fell >= ATR*mult) / 2=NEUTRAL.
// No tradeDir — one model serves both BUY and SELL signal decisions.
void BuildAndTrainNBBrain()
{
   int avail = Bars(_Symbol, PERIOD_M15);
   int total = NB_LookbackBars + NB_Lookahead + 10;
   if(avail < total) {
      Print("[NB Brain] Not enough M15 bars: have ", avail, ", need ", total, " — skipping train");
      return;
   }

   int nSamples = NB_LookbackBars - NB_Lookahead;
   if(nSamples <= 0) return;

   int classCounts[HA_NB_CLASSES];
   ArrayInitialize(classCounts, 0);
   int fCounts[HA_NB_CLASSES][HA_NB_FEATURES][HA_NB_MAX_BINS];
   ArrayInitialize(fCounts, 0);
   int validCount = 0;

   for(int i = 0; i < nSamples; i++) {
      int barIdx = NB_Lookahead + i;

      // Local ATR (range average over 14 bars)
      double atrSum = 0;
      for(int a = barIdx; a < barIdx + 14 && a < avail; a++)
         atrSum += (iHigh(_Symbol, PERIOD_M15, a) - iLow(_Symbol, PERIOD_M15, a));
      double atrLocal = atrSum / 14.0;
      if(atrLocal <= 0) continue;

      // Absolute label: UP(0) / DOWN(1) / NEUTRAL(2)
      double futureClose = iClose(_Symbol, PERIOD_M15, barIdx - NB_Lookahead);
      double baseClose   = iClose(_Symbol, PERIOD_M15, barIdx);
      double delta       = futureClose - baseClose;
      double thresh      = atrLocal * NB_WinMultiplier;

      int label;
      if(delta >= thresh)       label = 0; // UP
      else if(delta <= -thresh) label = 1; // DOWN
      else                      label = 2; // NEUTRAL

      int feats[];
      GetNBHistoricalFeatures(barIdx, feats);

      classCounts[label]++;
      for(int f = 0; f < HA_NB_FEATURES; f++) {
         int bin = feats[f];
         if(bin >= 0 && bin < g_HaNB_FeatureBins[f])
            fCounts[label][f][bin]++;
      }
      validCount++;
   }

   if(validCount < 20) {
      Print("[NB Brain] Too few valid samples (", validCount, ") — skipping model update");
      return;
   }

   for(int c = 0; c < HA_NB_CLASSES; c++)
      g_HaNB_Prior[c] = (double)classCounts[c] / (double)validCount;

   for(int c = 0; c < HA_NB_CLASSES; c++) {
      for(int f = 0; f < HA_NB_FEATURES; f++) {
         int nBins = g_HaNB_FeatureBins[f];
         for(int v = 0; v < HA_NB_MAX_BINS; v++) {
            if(v < nBins)
               g_HaNB_Likelihood[c][f][v] =
                  ((double)fCounts[c][f][v] + 1.0) / ((double)classCounts[c] + (double)nBins);
            else
               g_HaNB_Likelihood[c][f][v] = 0.0;
         }
      }
   }

   g_HaNB_SampleCount = validCount;
   g_HaNB_Trained     = true;
   Print("[NB Brain] Trained ", validCount, " samples | P(UP)=", DoubleToString(g_HaNB_Prior[0]*100,1),
         "% P(DOWN)=", DoubleToString(g_HaNB_Prior[1]*100,1),
         "% P(NEUTRAL)=", DoubleToString(g_HaNB_Prior[2]*100,1), "%");
}

// Train an NB model using ONLY historical bars from session sessIdx (0=Asian/1=London/2=NY).
// Filters the same NB_LookbackBars window by session hour, so Asian trains on Asian bars only.
// Stores in g_HaNB_Prior_S[sessIdx] / g_HaNB_Likelihood_S[sessIdx] and resets online accumulator.
void BuildAndTrainNBBrain_Session(int sessIdx)
{
   int avail = Bars(_Symbol, PERIOD_M15);
   int total = NB_LookbackBars + NB_Lookahead + 10;
   if(avail < total) {
      Print("[NB Sess ", sessIdx, "] Not enough bars (", avail, "/", total, ") — skipping");
      return;
   }
   int nSamples = NB_LookbackBars - NB_Lookahead;
   if(nSamples <= 0) return;

   int classCounts[HA_NB_CLASSES];
   ArrayInitialize(classCounts, 0);
   int fCounts[HA_NB_CLASSES][HA_NB_FEATURES][HA_NB_MAX_BINS];
   ArrayInitialize(fCounts, 0);
   int validCount = 0;

   for(int i = 0; i < nSamples; i++) {
      int barIdx = NB_Lookahead + i;
      // Session filter: only train on bars belonging to sessIdx
      datetime barTime = iTime(_Symbol, PERIOD_M15, barIdx);
      MqlDateTime bdt; TimeToStruct(barTime, bdt);
      if(GetNBSessionBin(bdt.hour) != sessIdx) continue;

      // Local ATR (14-bar average range)
      double atrSum = 0;
      for(int a = barIdx; a < barIdx + 14 && a < avail; a++)
         atrSum += (iHigh(_Symbol, PERIOD_M15, a) - iLow(_Symbol, PERIOD_M15, a));
      double atrLocal = atrSum / 14.0;
      if(atrLocal <= 0) continue;

      // Absolute label: UP(0) / DOWN(1) / NEUTRAL(2)
      double futureClose = iClose(_Symbol, PERIOD_M15, barIdx - NB_Lookahead);
      double baseClose   = iClose(_Symbol, PERIOD_M15, barIdx);
      double delta       = futureClose - baseClose;
      double thresh      = atrLocal * NB_WinMultiplier;
      int label;
      if(delta >= thresh)       label = 0;
      else if(delta <= -thresh) label = 1;
      else                      label = 2;

      int feats[];
      GetNBHistoricalFeatures(barIdx, feats);
      classCounts[label]++;
      for(int f = 0; f < HA_NB_FEATURES; f++) {
         int bin = feats[f];
         if(bin >= 0 && bin < g_HaNB_FeatureBins[f])
            fCounts[label][f][bin]++;
      }
      validCount++;
   }

   if(validCount < 10) {
      Print("[NB Sess ", sessIdx, "] Too few session bars (", validCount, ") — model skipped");
      return;
   }

   // Build priors and likelihoods with Laplace smoothing
   for(int c = 0; c < HA_NB_CLASSES; c++)
      g_HaNB_Prior_S[sessIdx][c] = (double)classCounts[c] / (double)validCount;
   for(int c = 0; c < HA_NB_CLASSES; c++) {
      for(int f = 0; f < HA_NB_FEATURES; f++) {
         int nBins = g_HaNB_FeatureBins[f];
         for(int v = 0; v < HA_NB_MAX_BINS; v++) {
            if(v < nBins)
               g_HaNB_Likelihood_S[sessIdx][c][f][v] =
                  ((double)fCounts[c][f][v] + 1.0) / ((double)classCounts[c] + (double)nBins);
            else
               g_HaNB_Likelihood_S[sessIdx][c][f][v] = 0.0;
         }
      }
   }

   // Reset online accumulator for this session (fresh batch model, discard stale online evidence)
   g_OL_TotalUpdates[sessIdx] = 0;
   for(int c = 0; c < HA_NB_CLASSES; c++) {
      g_OL_ClassCounts[sessIdx][c] = 0;
      for(int f = 0; f < HA_NB_FEATURES; f++)
         for(int v = 0; v < HA_NB_MAX_BINS; v++)
            g_OL_FCounts[sessIdx][c][f][v] = 0;
   }

   g_HaNB_SampleCount_S[sessIdx] = validCount;
   g_HaNB_Trained_S[sessIdx]     = true;
   string _sn = (sessIdx == 0) ? "Asian" : (sessIdx == 1) ? "London" : "NY";
   Print("[NB Sess:", _sn, "] Trained ", validCount, " bars | P(UP)=",
         DoubleToString(g_HaNB_Prior_S[sessIdx][0]*100,1), "% P(DOWN)=",
         DoubleToString(g_HaNB_Prior_S[sessIdx][1]*100,1), "% P(NEUTRAL)=",
         DoubleToString(g_HaNB_Prior_S[sessIdx][2]*100,1), "%");
}

// Compute live P(UP)/P(DOWN)/P(NEUTRAL) from current NB model and live market features.
// Updates g_NBBuyProb, g_NBSellProb, g_NBPosteriorWin/Loss/Hold, g_NBPredDir every call.
void CalcNBLiveProbs()
{
   // --- Session-stratified inference: use per-session model when trained ---
   if(NBSessionTrain) {
      int _s = g_CurNBSessionIdx;
      if(_s <= 2 && g_HaNB_Trained_S[_s]) {
         int _sf[];
         GetNBLiveFeatures(_sf);
         // Online blend weight — grows with sample count, capped at NBOnlineWeight
         double _olB = 0.0;
         if(NBOnlineLearn && g_OL_TotalUpdates[_s] >= 5)
            _olB = MathMin(NBOnlineWeight, (double)g_OL_TotalUpdates[_s] / 100.0);
         double _pr[HA_NB_CLASSES];
         double _tot = 0.0;
         for(int _c = 0; _c < HA_NB_CLASSES; _c++) {
            double _bp = g_HaNB_Prior_S[_s][_c];
            double _p  = _bp;
            if(_olB > 0 && g_OL_TotalUpdates[_s] > 0) {
               double _op = (g_OL_ClassCounts[_s][_c] + 1.0) /
                            (g_OL_TotalUpdates[_s] + (double)HA_NB_CLASSES);
               _p = (1.0 - _olB) * _bp + _olB * _op;
            }
            for(int _f = 0; _f < HA_NB_FEATURES; _f++) {
               int _b = _sf[_f];
               if(_b >= 0 && _b < g_HaNB_FeatureBins[_f]) {
                  double _bL = g_HaNB_Likelihood_S[_s][_c][_f][_b];
                  double _L  = _bL;
                  if(_olB > 0 && g_OL_ClassCounts[_s][_c] > 0) {
                     int _nB = g_HaNB_FeatureBins[_f];
                     double _oL = (g_OL_FCounts[_s][_c][_f][_b] + 1.0) /
                                  (g_OL_ClassCounts[_s][_c] + (double)_nB);
                     _L = (1.0 - _olB) * _bL + _olB * _oL;
                  }
                  if(_L > 0) _p *= _L;
               }
            }
            _pr[_c] = _p; _tot += _p;
         }
         if(_tot > 0) {
            g_NBBuyProb       = (_pr[0] / _tot) * 100.0;
            g_NBSellProb      = (_pr[1] / _tot) * 100.0;
            g_NBPosteriorWin  = g_NBBuyProb;
            g_NBPosteriorLoss = g_NBSellProb;
            g_NBPosteriorHold = (_pr[2] / _tot) * 100.0;
         } else {
            g_NBBuyProb = g_NBSellProb = g_NBPosteriorWin = g_NBPosteriorLoss = g_NBPosteriorHold = 33.3;
         }
         if(g_NBBuyProb >= g_NBSellProb && g_NBBuyProb > 40.0)      g_NBPredDir =  1;
         else if(g_NBSellProb > g_NBBuyProb && g_NBSellProb > 40.0) g_NBPredDir = -1;
         else                                                         g_NBPredDir =  0;
         return;  // session model used — skip global fallback
      }
   }
   // --- Global model fallback (all-session blend, active while session models warm up) ---
   if(!g_HaNB_Trained) return;

   int liveFeats[];
   GetNBLiveFeatures(liveFeats);

   double probs[HA_NB_CLASSES];
   double total = 0.0;
   for(int c = 0; c < HA_NB_CLASSES; c++) {
      double p = g_HaNB_Prior[c];
      for(int f = 0; f < HA_NB_FEATURES; f++) {
         int bin = liveFeats[f];
         if(bin >= 0 && bin < g_HaNB_FeatureBins[f] && g_HaNB_Likelihood[c][f][bin] > 0)
            p *= g_HaNB_Likelihood[c][f][bin];
      }
      probs[c] = p; total += p;
   }

   if(total > 0) {
      g_NBBuyProb       = (probs[0] / total) * 100.0;  // P(UP)
      g_NBSellProb      = (probs[1] / total) * 100.0;  // P(DOWN)
      g_NBPosteriorWin  = g_NBBuyProb;
      g_NBPosteriorLoss = g_NBSellProb;
      g_NBPosteriorHold = (probs[2] / total) * 100.0;  // P(NEUTRAL)
   } else {
      g_NBBuyProb = g_NBSellProb = g_NBPosteriorWin = g_NBPosteriorLoss = g_NBPosteriorHold = 33.3;
   }

   if(g_NBBuyProb >= g_NBSellProb && g_NBBuyProb > 40.0)       g_NBPredDir =  1;
   else if(g_NBSellProb > g_NBBuyProb && g_NBSellProb > 40.0)  g_NBPredDir = -1;
   else                                                          g_NBPredDir =  0;
}

// Called on every new bar: retrain NB when due, then compute live posteriors immediately.
// NB_RetrainBars=1 means model stays maximally fresh (retrain each bar; ~100 samples * 9 feats).

// Reinforcement update: compare last bar's saved features against bar[1]'s actual close direction.
// Labels the outcome and adds it to the online accumulator for the current session.
// The accumulator is blended into live inference proportionally via NBOnlineWeight.
void OnlineUpdateNB()
{
   if(!g_PrevBarFeatValid) return;
   int s = g_CurNBSessionIdx;
   if(s > 2) return;  // off-hours: no update

   // Actual outcome of bar[1] (the bar whose features we captured last call)
   double o1   = iOpen (_Symbol, PERIOD_M15, 1);
   double c1   = iClose(_Symbol, PERIOD_M15, 1);
   double atr  = (g_ATR > 0) ? g_ATR : 0.0002;
   double delta = c1 - o1;
   double thresh = atr * NB_WinMultiplier * 0.5;  // half-ATR threshold for online labelling
   int label;
   if(delta >= thresh)       label = 0;  // UP
   else if(delta <= -thresh) label = 1;  // DOWN
   else                      label = 2;  // NEUTRAL

   // Accumulate into the session's online store
   g_OL_ClassCounts[s][label]++;
   for(int f = 0; f < HA_NB_FEATURES; f++) {
      int bin = g_PrevBarFeats[f];
      if(bin >= 0 && bin < g_HaNB_FeatureBins[f])
         g_OL_FCounts[s][label][f][bin]++;
   }
   g_OL_TotalUpdates[s]++;
   g_PrevBarFeatValid = false;  // consumed
}

void RunNBEveryBar()
{
   if(!UseNBBrain) return;

   // Detect session crossing — retrain that session's model fresh when we enter it
   MqlDateTime _nbDt; TimeToStruct(TimeCurrent(), _nbDt);
   int curSess = GetNBSessionBin(_nbDt.hour);
   g_CurNBSessionIdx = curSess;
   if(NBSessionTrain && curSess != g_PrevNBSessionIdx) {
      g_PrevNBSessionIdx = curSess;
      if(curSess <= 2)
         BuildAndTrainNBBrain_Session(curSess);  // retrain on entering new session
      g_PrevBarFeatValid = false;  // discard prev-bar state at session boundary
   }

   // Online reinforcement update from previous confirmed bar
   if(NBOnlineLearn && g_PrevBarFeatValid)
      OnlineUpdateNB();

   // Periodic batch retrain
   g_HaNB_BarCounter++;
   if(g_HaNB_BarCounter >= NB_RetrainBars) {
      g_HaNB_BarCounter = 0;
      if(NBSessionTrain && curSess <= 2)
         BuildAndTrainNBBrain_Session(curSess);
      else
         BuildAndTrainNBBrain();
   }

   // Compute live posteriors (uses session model if NBSessionTrain + trained, else global)
   CalcNBLiveProbs();

   // Capture this bar's live features for next bar's online update
   if(NBOnlineLearn) {
      int _tmpF[];
      GetNBLiveFeatures(_tmpF);
      for(int _fi = 0; _fi < HA_NB_FEATURES; _fi++)
         g_PrevBarFeats[_fi] = _tmpF[_fi];
      g_PrevBarNBDir     = g_NBPredDir;
      g_PrevBarFeatValid = true;
   }
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
      } else if(g_VolumeState == "DEAD") {
         conf -= 15.0;  // v6.36: dead volume = near-zero liquidity, very unreliable
      } else if(g_VolumeState == "LOW") {
         conf -= 8.0;   // dead volume = unreliable, ranging market (v6.29: was -3, now -8)
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

   // --- FACTOR 18 — HA + REAL CANDLE ALIGNMENT (v6.29) ---
   // When HA direction matches the real (OHLC) candle direction on bars 1 and 2,
   // the signal has genuine price confirmation — not just a smoothed artifact.
   // Both aligned = strong gift; both misaligned = strong penalty; mixed = slight penalty.
   {
      double _rc1 = iClose(_Symbol, PERIOD_M15, 1);
      double _ro1 = iOpen (_Symbol, PERIOD_M15, 1);
      double _rc2 = iClose(_Symbol, PERIOD_M15, 2);
      double _ro2 = iOpen (_Symbol, PERIOD_M15, 2);
      bool realMatch1 = (tradeDir == 1) ? (_rc1 > _ro1) : (_rc1 < _ro1);
      bool realMatch2 = (tradeDir == 1) ? (_rc2 > _ro2) : (_rc2 < _ro2);
      g_RealCandleAligned = (realMatch1 && realMatch2);
      if(realMatch1 && realMatch2)       conf += 6.0;    // both aligned = genuine momentum
      else if(!realMatch1 && !realMatch2) conf -= 6.0;   // both misaligned = HA is misleading
      else                                conf -= 2.0;   // mixed = slight distrust
   }
   g_ConfBreakdown += " CdlAlign:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- FACTOR 19 — BOLLINGER BAND HEADROOM (0-8) ---
   // If price is below the upper band (buy) or above the lower band (sell),
   // there is room to move → boost confidence. Stronger during Asian session
   // when prev-day momentum aligns (carry-over bias with Bollinger runway).
   {
      double bollBonus = 0;
      if(g_BollingerUpper1 > 0 && g_BollingerLower1 > 0) {
         double bTol = 2.0 * _Point * 10;
         bool bRoom = (tradeDir == 1  && SymbolInfoDouble(_Symbol, SYMBOL_BID) < g_BollingerUpper1 - bTol) ||
                      (tradeDir == -1 && SymbolInfoDouble(_Symbol, SYMBOL_BID) > g_BollingerLower1 + bTol);
         if(bRoom) {
            bollBonus += 4.0;  // base: Bollinger runway exists
            // Aligned with prev-day close momentum → stronger carry-over
            if(g_PrevDayLastHourDir == tradeDir) bollBonus += 2.0;
            // Asian session with alignment → $2 move is realistic on 0.01 lot
            MqlDateTime _bdt; TimeToStruct(TimeCurrent(), _bdt);
            bool _inAsianB = (_bdt.hour >= AsianStartHour && _bdt.hour < AsianEndHour);
            if(_inAsianB && g_PrevDayLastHourDir == tradeDir) bollBonus += 2.0;
         } else {
            // Price at or past Bollinger band in trade direction → limited room
            bollBonus -= 3.0;
         }
      }
      conf += bollBonus;
   }
   g_ConfBreakdown += " BollRm:" + DoubleToString(conf - prevConf, 0); prevConf = conf;

   // --- 20. ZAP ZONE CONFLUENCE (+3 per zone score pt, max +15) v7.00 ---
   if(UseZAP && g_ZAPActive && g_ZAPDir == tradeDir) {
      double zapBonus = MathMin(g_ZAPScore * 3.0, 15.0);
      conf += zapBonus;
      g_ConfBreakdown += " ZAP:+" + DoubleToString(zapBonus, 0);
   }
   // --- 21. ZAP FAKEOUT (liquidity sweep confirmed → reversal bias +10) v7.00 ---
   if(UseZAP && g_ZAPFakeout && g_ZAPDir == tradeDir) {
      conf += 10.0;
      g_ConfBreakdown += " ZAPFko:+10";
   }
   // --- 22. ENHANCED ASIAN BIAS (±8 aligned / −5 counter in Asian hours) v7.00 ---
   if(g_AsianBiasActive) {
      MqlDateTime _adt22; TimeToStruct(TimeCurrent(), _adt22);
      bool inAsian22 = (_adt22.hour >= AsianStartHour && _adt22.hour < AsianEndHour);
      if(inAsian22) {
         if(g_AsianBiasDir == tradeDir) { conf += 8.0; g_ConfBreakdown += " AsianBias:+8"; }
         else                           { conf -= 5.0; g_ConfBreakdown += " AsianBias:-5"; }
      }
   }
   // --- 23. ZONE CONFLUENCE DENSITY (ZCP >= 70% adds +5) v7.00 ---
   if(UseZoneConfluence && g_ZoneConfluencePct >= 70.0) {
      conf += 5.0;
      g_ConfBreakdown += " ZCP:+5";
   }
   prevConf = conf;

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
         " BollRm:", g_BollRoomLabel,
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
      // HA-based invalidation: lowest Low of the last 2 closed HA candles
      // A bullish entry is invalidated when price closes below either HA low
      double _haO1b, _haH1b, _haL1b, _haC1b;
      double _haO2b, _haH2b, _haL2b, _haC2b;
      CalcHA(1, _haO1b, _haH1b, _haL1b, _haC1b);
      CalcHA(2, _haO2b, _haH2b, _haL2b, _haC2b);
      if(_haL1b > 0 && _haL1b < entry) levels[cnt++] = _haL1b;
      if(_haL2b > 0 && _haL2b < entry) levels[cnt++] = _haL2b;
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
      // HA-based invalidation: highest High of the last 2 closed HA candles
      // A bearish entry is invalidated when price closes above either HA high
      double _haO1s, _haH1s, _haL1s, _haC1s;
      double _haO2s, _haH2s, _haL2s, _haC2s;
      CalcHA(1, _haO1s, _haH1s, _haL1s, _haC1s);
      CalcHA(2, _haO2s, _haH2s, _haL2s, _haC2s);
      if(_haH1s > entry) levels[cnt++] = _haH1s;
      if(_haH2s > entry) levels[cnt++] = _haH2s;
   }

   // Find the NEAREST invalidation level (smallest distance from entry)
   double bestDist = 99999;
   double pipValue = _Point * 10;
   double minSLdist = MinSL_USD / 10.0;  // convert USD/0.01lot to price distance
   double maxSLdist = MaxSL_USD / 10.0;

   // === PRIMARY SL: outermost edge of the last 1-2 clean HA candles ===
   // A clean candle is one that is directional (matches trade) and is not a doji.
   // For buys  : SL = lowest HA Low  among clean bars 1 & 2 (the further from entry wins)
   // For sells : SL = highest HA High among clean bars 1 & 2
   // This gives the tightest structurally-valid SL — the smoothed HA already prices in
   // noise, so its outermost edge IS the real invalidation point.
   double _haO1p, _haH1p, _haL1p, _haC1p;
   double _haO2p, _haH2p, _haL2p, _haC2p;
   CalcHA(1, _haO1p, _haH1p, _haL1p, _haC1p);
   CalcHA(2, _haO2p, _haH2p, _haL2p, _haC2p);
   bool _bar1Clean = (!IsHADoji(1) && HADir(1) == tradeDir);
   bool _bar2Clean = (!IsHADoji(2) && HADir(2) == tradeDir);
   double _haPrimaryDist = 0;
   if(tradeDir == 1 && _bar1Clean) {
      double _haEdge = _haL1p;
      if(_bar2Clean && _haL2p < _haEdge) _haEdge = _haL2p;  // furthest low wins
      _haPrimaryDist = MathAbs(entry - _haEdge) + 1.0 * pipValue;  // +1 pip buffer
   } else if(tradeDir == -1 && _bar1Clean) {
      double _haEdge = _haH1p;
      if(_bar2Clean && _haH2p > _haEdge) _haEdge = _haH2p;  // furthest high wins
      _haPrimaryDist = MathAbs(entry - _haEdge) + 1.0 * pipValue;  // +1 pip buffer
   }
   if(_haPrimaryDist > 0)
      bestDist = _haPrimaryDist;   // HA edge is the primary SL

   // === FALLBACK: structural levels (only if HA gave no valid primary) ===
   if(bestDist >= 99000) {
      for(int i = 0; i < cnt; i++) {
         double dist = MathAbs(entry - levels[i]);
         if(dist < minSLdist * 0.5) continue;  // too close, skip
         if(dist < bestDist) bestDist = dist;
      }
   }

   // === STRUCTURAL LEVEL AS TIGHTER CHECK ===
   // Even when HA gave a primary SL, if a structural level sits closer to entry
   // (providing tighter protection), prefer it — smaller SL = better R:R.
   for(int i = 0; i < cnt; i++) {
      double dist = MathAbs(entry - levels[i]) + 1.0 * pipValue;
      if(dist < minSLdist * 0.5) continue;
      if(dist < bestDist) bestDist = dist;  // structural level improves SL
   }

   // If no level found at all, use ATR-based fallback
   if(bestDist >= 99000) {
      double atrDist = (g_ATR > 0) ? g_ATR * 1.5 : 20 * pipValue;
      bestDist = atrDist;
   }

   // Convert price distance to USD per 0.01 lot
   // For EURUSD: 1 pip = $0.10 per 0.01 lot
   double slPips = bestDist / pipValue;
   double slUSD  = slPips * 0.10;   // $0.10 per pip per 0.01 lot

   // Clamp to user limits
   slUSD = MathMax(MinSL_USD, MathMin(MaxSL_USD, slUSD));

   // === TP ADJUSTMENT (volume/momentum context — applied to TP only, not SL) ===
   // SL is fixed by HA structure; do NOT inflate it with multipliers (defeats tight entry).
   // TP is allowed to scale: when institutional volume is high or momentum is strong,
   // let the winner run a little further while keeping SL anchored to HA edge.
   double tpMult = 1.0;
   if(g_VolumeState == "LOW")            tpMult *= 0.85;  // choppy: conservative TP
   else if(g_VolumeState == "HIGH")      tpMult *= 1.10;  // strong flow: let it run
   else if(g_VolumeState == "ABOVE_AVG") tpMult *= 1.05;

   double _atrPips = (g_ATR > 0) ? (g_ATR / _Point / 10.0) : 10.0;
   double _avgBarRng = 0;
   for(int m = 1; m <= 3; m++)
      _avgBarRng += iHigh(_Symbol, PERIOD_M15, m) - iLow(_Symbol, PERIOD_M15, m);
   _avgBarRng /= 3.0;
   double _momRatio = (g_ATR > 0) ? _avgBarRng / g_ATR : 1.0;
   if(_momRatio >= 1.5 && g_VolumeState != "LOW") tpMult *= 1.05;  // strong momentum bonus

   double adjSL = slUSD;                       // SL = HA-structural edge, no multiplier
   double adjTP = slUSD * RRRatio * tpMult;   // TP scales with SL × R:R × context

   // Re-clamp SL to [MinSL, MaxSL] — HA edge might land below floor or above hard cap
   adjSL = MathMax(MinSL_USD, MathMin(MaxSL_USD, adjSL));
   adjTP = MathMax(adjSL * 1.0, adjTP);   // TP floor = 1:1 R:R
   adjTP = MathMin(adjTP, MaxTP_USD);      // hard cap — statistically achievable targets

   // v7.00: SLBufferPips — add extra breathing room past the structural SL
   // This prevents the SL being hit by normal noise just beyond the HA edge.
   // TP is NOT adjusted (keeps R:R conservative on the risk side).
   if(SLBufferPips > 0) {
      double bufferUSD = SLBufferPips * 0.10;   // $0.10 per pip per 0.01 lot
      adjSL += bufferUSD;
      // Allow buffer to push slightly past MaxSL (user chose the buffer intentionally)
      adjSL = MathMin(adjSL, MaxSL_USD + bufferUSD);
   }

   // Store globally
   g_DynamicSL_USD = adjSL;
   g_DynamicTP_USD = adjTP;

   Print("STRUCTURAL SL: $", DoubleToString(adjSL, 2), "/0.01lot",
         " (", DoubleToString(adjSL / 0.10, 1), " pips)",
         " TP: $", DoubleToString(adjTP, 2),
         " R:R=1:", DoubleToString(adjTP / adjSL, 1),
         " [haPrimary=", DoubleToString(_haPrimaryDist / pipValue, 1), "pip",
         " base=$", DoubleToString(slUSD, 2),
         " tpMult=", DoubleToString(tpMult, 2),
         " Vol=", g_VolumeState,
         " ATR=", DoubleToString(_atrPips, 1), "pip",
         " Mom=", DoubleToString(_momRatio, 2), "]");

   return adjSL;
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
      if(IsHADoji(i)) break;          // doji interrupts the chain regardless of direction
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
//| ZONE APPROACH PRIMER (ZAP) v7.00                                |
//| Scans all institutional zones each bar. When price is within    |
//| ZAPProximityPips, arms the bot's directional bias BEFORE HA.    |
//| The first qualifying HA candle then fires INCOMING directly.    |
//| Also detects liquidity sweeps past zone boundaries (fakeouts).  |
//+------------------------------------------------------------------+
void DetectZoneApproach()
{
   if(!UseZAP) { g_ZAPActive = false; g_ZAPFakeout = false; g_ZoneConfluencePct = 0; return; }

   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double prox = ZAPProximityPips * _Point * 10.0;

   int    buyScore = 0, sellScore = 0;
   string buyZones = "",  sellZones = "";

   // CI Low (statistical support) → BUY; CI High (resistance) → SELL
   if(g_CILow  > 0 && bid <= g_CILow  + prox && bid >= g_CILow  - prox * 0.5) { buyScore++;  buyZones  += "CIL "; }
   if(g_CIHigh > 0 && bid >= g_CIHigh - prox && bid <= g_CIHigh + prox * 0.5) { sellScore++; sellZones += "CIH "; }

   // H1 Order Blocks
   for(int _i = 0; _i < g_BullOBCount; _i++) {
      if(!g_BullOBs[_i].mitigated && g_BullOBs[_i].high > 0 &&
         bid >= g_BullOBs[_i].low - prox && bid <= g_BullOBs[_i].high + prox)
         { buyScore++; buyZones += "H1BullOB "; break; }
   }
   for(int _i = 0; _i < g_BearOBCount; _i++) {
      if(!g_BearOBs[_i].mitigated && g_BearOBs[_i].high > 0 &&
         bid >= g_BearOBs[_i].low - prox && bid <= g_BearOBs[_i].high + prox)
         { sellScore++; sellZones += "H1BearOB "; break; }
   }

   // H4 Order Blocks (macro, weighted +2)
   if(g_NearH4BullOB) { buyScore += 2;  buyZones  += "H4BullOB "; }
   if(g_NearH4BearOB) { sellScore += 2; sellZones += "H4BearOB "; }

   // H1 + H4 Fair Value Gaps
   if(g_NearBullFVG)   { buyScore++;  buyZones  += "H1FVG "; }
   if(g_NearBearFVG)   { sellScore++; sellZones += "H1FVG "; }
   if(g_NearBullH4FVG) { buyScore++;  buyZones  += "H4FVG "; }
   if(g_NearBearH4FVG) { sellScore++; sellZones += "H4FVG "; }

   // Horizontal Price Levels
   if(UseHPL) {
      if(g_HPLSupportBlock) { buyScore++;  buyZones  += "HPL-Supp "; }
      if(g_HPLResistBlock)  { sellScore++; sellZones += "HPL-Res "; }
   }

   // Murray Math octave levels (0/8,1/8 = strong support; 7/8,8/8 = strong resistance)
   if(UseMurrayChannels) {
      for(int _mi = 0; _mi <= 8; _mi++) {
         if(g_Murray[_mi] <= 0) continue;
         if(MathAbs(bid - g_Murray[_mi]) <= prox) {
            if(_mi <= 1) { buyScore++;  buyZones  += "M" + IntegerToString(_mi) + "/8 "; }
            if(_mi >= 7) { sellScore++; sellZones += "M" + IntegerToString(_mi) + "/8 "; }
         }
      }
   }

   // Daily Pivot support/resistance
   if(UseDailyPivot) {
      if(g_PivotS1 > 0 && MathAbs(bid - g_PivotS1) <= prox) { buyScore++;  buyZones  += "S1 "; }
      if(g_PivotS2 > 0 && MathAbs(bid - g_PivotS2) <= prox) { buyScore++;  buyZones  += "S2 "; }
      if(g_PivotR1 > 0 && MathAbs(bid - g_PivotR1) <= prox) { sellScore++; sellZones += "R1 "; }
      if(g_PivotR2 > 0 && MathAbs(bid - g_PivotR2) <= prox) { sellScore++; sellZones += "R2 "; }
   }

   // Weekly / 3-Day S/R
   if(UseWeeklySR) {
      if(g_PrevWeekLow  > 0 && MathAbs(bid - g_PrevWeekLow)  <= prox) { buyScore++;  buyZones  += "WkL "; }
      if(g_PrevWeekHigh > 0 && MathAbs(bid - g_PrevWeekHigh) <= prox) { sellScore++; sellZones += "WkH "; }
      if(g_ThreeDayLow  > 0 && MathAbs(bid - g_ThreeDayLow)  <= prox) { buyScore++;  buyZones  += "3dL "; }
      if(g_ThreeDayHigh > 0 && MathAbs(bid - g_ThreeDayHigh) <= prox) { sellScore++; sellZones += "3dH "; }
   }

   // Fibonacci levels (61.8/76.4 = deep support → BUY; 23.6/38.2 = resistance → SELL)
   if(g_Fib382 > 0) {
      if(MathAbs(bid - g_Fib618) <= prox) { buyScore++;  buyZones  += "F61.8 "; }
      if(MathAbs(bid - g_Fib764) <= prox) { buyScore++;  buyZones  += "F76.4 "; }
      if(MathAbs(bid - g_Fib236) <= prox) { sellScore++; sellZones += "F23.6 "; }
      if(MathAbs(bid - g_Fib382) <= prox) { sellScore++; sellZones += "F38.2 "; }
   }

   // Zone confluence percentage
   int topScore = MathMax(buyScore, sellScore);
   g_ZoneConfluencePct = MathMin(topScore * 100.0 / 12.0, 100.0);

   // Determine ZAP direction (ties resolved via macro structure)
   int newDir = 0;
   if(buyScore > sellScore && buyScore >= ZAPMinScore)        newDir =  1;
   else if(sellScore > buyScore && sellScore >= ZAPMinScore)  newDir = -1;
   else if(buyScore == sellScore && buyScore >= ZAPMinScore) {
      if(g_MacroStructLabel == "BULLISH")      newDir =  1;
      else if(g_MacroStructLabel == "BEARISH") newDir = -1;
      if(newDir != 0) Print("[ZAP] Tie-break via MacroStr=", g_MacroStructLabel);
   }

   // Fakeout/sweep detection — spike past zone boundary = liquidity sweep
   if(g_ZAPActive && g_ZAPDir != 0 && !g_ZAPFakeout) {
      double sweepDist = ZAPFakeoutPips * _Point * 10.0;
      bool   fo = false;
      if(g_ZAPDir == 1) {
         if(g_CILow         > 0 && bid < g_CILow         - sweepDist) { fo = true; g_ZAPZonePrice = g_CILow; }
         if(!fo && g_HPLSupportLow > 0 && bid < g_HPLSupportLow - sweepDist) { fo = true; g_ZAPZonePrice = g_HPLSupportLow; }
         if(!fo && g_PivotS1 > 0 && bid < g_PivotS1 - sweepDist)           { fo = true; g_ZAPZonePrice = g_PivotS1; }
      } else {
         if(g_CIHigh        > 0 && bid > g_CIHigh        + sweepDist) { fo = true; g_ZAPZonePrice = g_CIHigh; }
         if(!fo && g_HPLResistHigh > 0 && bid > g_HPLResistHigh + sweepDist) { fo = true; g_ZAPZonePrice = g_HPLResistHigh; }
         if(!fo && g_PivotR1 > 0 && bid > g_PivotR1 + sweepDist)           { fo = true; g_ZAPZonePrice = g_PivotR1; }
      }
      if(fo) {
         g_ZAPFakeout = true;
         Print("[ZAP FAKEOUT] Liquidity sweep @ ", DoubleToString(bid, 5),
               " past zone=", DoubleToString(g_ZAPZonePrice, 5),
               " dir=", (g_ZAPDir==1 ? "BUY(swept below support)" : "SELL(swept above resist)"),
               " — next reversal candle = DIRECT INCOMING (NB suppression bypassed)");
      }
   }

   // Update ZAP state
   if(newDir != 0) {
      string newLbl  = (newDir == 1) ? buyZones  : sellZones;
      int    newScr  = (newDir == 1) ? buyScore  : sellScore;
      if(StringLen(newLbl) > 0) StringTrimRight(newLbl);
      if(!g_ZAPActive || g_ZAPDir != newDir) {
         g_ZAPActive    = true;
         g_ZAPDir       = newDir;
         g_ZAPStartTime = TimeCurrent();
         g_ZAPFakeout   = false;
         Print("[ZAP ARMED] dir=", (newDir==1?"BUY":"SELL"),
               " score=", newScr, " zones=[", newLbl, "]",
               " ZCP=", DoubleToString(g_ZoneConfluencePct, 0), "%");
      }
      g_ZAPScore = newScr;
      g_ZAPLabel = newLbl;
   } else if(g_ZAPActive) {
      int barsSince = (g_ZAPStartTime > 0)
                      ? (int)((TimeCurrent() - g_ZAPStartTime) / PeriodSeconds(PERIOD_M15))
                      : ZAPMaxBars;
      if(barsSince >= ZAPMaxBars) {
         Print("[ZAP EXPIRED] ", barsSince, " bars without zone contact — resetting");
         g_ZAPActive = false; g_ZAPDir = 0; g_ZAPScore = 0;
         g_ZAPLabel = ""; g_ZAPFakeout = false; g_ZAPStartTime = 0; g_ZoneConfluencePct = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| ENHANCED ASIAN SESSION BIAS TRACKER v7.00                       |
//| After the observe window, measures net pip move from g_AsianOpen |
//| Once >= AsianBiasMovePips in a direction, sets g_AsianBiasDir.  |
//| Resets at London open. Aligned signals earn +8 confidence pts.  |
//+------------------------------------------------------------------+
void ComputeAsianBias()
{
   if(!AsianBiasEnabled) { g_AsianBiasActive = false; return; }

   MqlDateTime _adt; TimeToStruct(TimeCurrent(), _adt);
   bool inAsian = (_adt.hour >= AsianStartHour && _adt.hour < AsianEndHour);

   if(!inAsian) {
      if(g_AsianBiasActive) {
         Print("[ASIAN BIAS] London open — resetting Asian bias (was ",
               (g_AsianBiasDir==1?"BULL":"BEAR"), ")");
         g_AsianBiasActive = false; g_AsianBiasDir = 0; g_AsianBiasLabel = "";
      }
      return;
   }
   if(g_AsianBarCount <= AsianObserveBars || g_AsianOpen <= 0) return;

   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double movePips = (bid - g_AsianOpen) / _Point / 10.0;

   if(movePips >= AsianBiasMovePips) {
      if(!g_AsianBiasActive || g_AsianBiasDir != 1) {
         g_AsianBiasActive = true; g_AsianBiasDir = 1;
         Print("[ASIAN BIAS] BULL established: +", DoubleToString(movePips, 1),
               "pip from Asian open=", DoubleToString(g_AsianOpen, 5),
               " — aligned BUY signals earn +8 conf pts");
      }
      g_AsianBiasLabel = "BULL BIAS +" + DoubleToString(movePips, 1) + "pip";
   } else if(movePips <= -AsianBiasMovePips) {
      if(!g_AsianBiasActive || g_AsianBiasDir != -1) {
         g_AsianBiasActive = true; g_AsianBiasDir = -1;
         Print("[ASIAN BIAS] BEAR established: ", DoubleToString(movePips, 1),
               "pip from Asian open=", DoubleToString(g_AsianOpen, 5),
               " — aligned SELL signals earn +8 conf pts");
      }
      g_AsianBiasLabel = "BEAR BIAS " + DoubleToString(movePips, 1) + "pip";
   } else {
      if(!g_AsianBiasActive) { g_AsianBiasDir = 0; g_AsianBiasLabel = ""; }
   }
}

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
         Print("[MACRO TREND RIDE] Blocked: MTF+Vol both diverged (score=", score, "/15)");
         return;
      }
   }

   g_MacroTrendRide  = true;
   g_MacroTrendDir   = bosDir;
   g_MacroTrendScore = score;
   Print("[MACRO TREND RIDE] Armed: ", g_MacroStructLabel, " BOS",
         " HAConsec=", g_HAConsecCount,
         " Score=", score, "/15",
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
//| trend trade should be allowed (CONTEXT_AWARE mode). Returns 0-15|
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

   // 14: Bollinger band headroom — price has room to move in trade direction
   if(g_BollingerUpper1 > 0 && g_BollingerLower1 > 0) {
      double bt = 2.0 * _Point * 10;
      if((tradeDir == 1  && p < g_BollingerUpper1 - bt) ||
         (tradeDir == -1 && p > g_BollingerLower1 + bt))
         score++;
   }

   return score;   // max 15 (was 14, +1 for Bollinger headroom)
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

   // 11 — Established Asian Bias confirmed and aligned with trade direction.
   // When price has already moved AsianBiasMovePips in the trade direction this session,
   // that is real directional evidence — not noise — and earns one override vote.
   if(g_AsianBiasActive && g_AsianBiasDir == tradeDir) { score++; factors += "AsianBias "; }

   reason = "score=" + IntegerToString(score) + "/" + IntegerToString(BollOverrideMinScore)
            + " [" + factors + "]";
   return (score >= BollOverrideMinScore);
}

//+------------------------------------------------------------------+
//| HA KEY-LEVEL CROSSING TRACKER                                    |
//| Counts consecutive clean (non-doji) HA bars since price last     |
//| crossed a key S/R or Fibonacci level.  Levels within 20 pips     |
//| of each other are deduplicated so the counter is not triggered   |
//| by cluster-noise.  Updated every bar from EvaluateHAPattern().  |
//+------------------------------------------------------------------+
void UpdateHALevelConsec(int dir1)
{
   const double MIN_GAP = 20.0 * _Point * 10.0;   // 20 pips = 2 USD / 0.01 lot

   // ---- Collect candidate key levels ----
   double candidates[50];
   string candLbls[50];
   int    nCand = 0;

   if(g_PivotPP      > 0) { candidates[nCand]=g_PivotPP;      candLbls[nCand++]="PP";  }
   if(g_PivotR1      > 0) { candidates[nCand]=g_PivotR1;      candLbls[nCand++]="R1";  }
   if(g_PivotR2      > 0) { candidates[nCand]=g_PivotR2;      candLbls[nCand++]="R2";  }
   if(g_PivotS1      > 0) { candidates[nCand]=g_PivotS1;      candLbls[nCand++]="S1";  }
   if(g_PivotS2      > 0) { candidates[nCand]=g_PivotS2;      candLbls[nCand++]="S2";  }
   if(g_Fib236       > 0) { candidates[nCand]=g_Fib236;       candLbls[nCand++]="F23"; }
   if(g_Fib382       > 0) { candidates[nCand]=g_Fib382;       candLbls[nCand++]="F38"; }
   if(g_Fib500       > 0) { candidates[nCand]=g_Fib500;       candLbls[nCand++]="F50"; }
   if(g_Fib618       > 0) { candidates[nCand]=g_Fib618;       candLbls[nCand++]="F61"; }
   if(g_Fib764       > 0) { candidates[nCand]=g_Fib764;       candLbls[nCand++]="F76"; }
   if(g_SwingHigh1   > 0) { candidates[nCand]=g_SwingHigh1;   candLbls[nCand++]="SH1"; }
   if(g_SwingLow1    > 0) { candidates[nCand]=g_SwingLow1;    candLbls[nCand++]="SL1"; }
   if(g_CIHigh       > 0) { candidates[nCand]=g_CIHigh;       candLbls[nCand++]="CI-H";}
   if(g_CILow        > 0) { candidates[nCand]=g_CILow;        candLbls[nCand++]="CI-L";}
   if(g_PrevWeekHigh > 0) { candidates[nCand]=g_PrevWeekHigh; candLbls[nCand++]="WkH"; }
   if(g_PrevWeekLow  > 0) { candidates[nCand]=g_PrevWeekLow;  candLbls[nCand++]="WkL"; }
   if(g_ThreeDayHigh > 0) { candidates[nCand]=g_ThreeDayHigh; candLbls[nCand++]="3dH"; }
   if(g_ThreeDayLow  > 0) { candidates[nCand]=g_ThreeDayLow;  candLbls[nCand++]="3dL"; }
   for(int mi = 0; mi <= 8; mi++) {
      if(g_Murray[mi] > 0) { candidates[nCand]=g_Murray[mi]; candLbls[nCand++]="M"+IntegerToString(mi); }
   }

   // ---- Deduplicate: keep only levels >= MIN_GAP apart ----
   double lvls[50];
   string lbls[50];
   int    nLvl = 0;
   for(int ci = 0; ci < nCand && nLvl < 50; ci++) {
      bool far = true;
      for(int k = 0; k < nLvl; k++) {
         if(MathAbs(lvls[k] - candidates[ci]) < MIN_GAP) { far = false; break; }
      }
      if(far) { lvls[nLvl] = candidates[ci]; lbls[nLvl] = candLbls[ci]; nLvl++; }
   }

   // ---- Check whether bar1's HA close crossed any level (bar2 close on opposite side) ----
   double haO1, haH1, haL1, haC1;
   double haO2, haH2, haL2, haC2;
   CalcHA(1, haO1, haH1, haL1, haC1);
   CalcHA(2, haO2, haH2, haL2, haC2);
   const double tol = 1.5 * _Point * 10.0;  // 1.5-pip crossing tolerance

   bool   crossed = false;
   for(int li = 0; li < nLvl && !crossed; li++) {
      double lp = lvls[li];
      if((haC2 < lp - tol && haC1 > lp + tol) ||
         (haC2 > lp + tol && haC1 < lp - tol)) {
         crossed              = true;
         g_KeyLevelCrossLabel = lbls[li] + "@" + DoubleToString(lp, 5);
      }
   }

   // ---- Update the counter ----
   if(crossed) {
      // Level just crossed: start a fresh count if bar1 is a clean directional candle
      g_HAConsecSinceKeyLevel = (!IsHADoji(1) && dir1 != 0) ? 1 : 0;
   } else if(dir1 != 0 && !IsHADoji(1)) {
      g_HAConsecSinceKeyLevel++;   // clean same-direction bar: extend the run
   } else {
      g_HAConsecSinceKeyLevel = 0; // doji or direction change: reset
   }
}

void EvaluateHAPattern()
{
   // bar 1 = most recently closed bar
   // bar 2 = the one before that

   int dir1 = HADir(1);  // most recent closed
   int dir2 = HADir(2);  // prior closed
   g_HADirFlip = (dir1 != 0 && dir2 != 0 && dir1 != dir2); // true = first HA candle after reversal

   bool bl1 = IsBottomless(1);
   bool bl2 = IsBottomless(2);
   bool tl1 = IsTopless(1);
   bool tl2 = IsTopless(2);

   // Count consecutive same-color candles ending at bar 1
   // (CountConsecutive now stops at a doji even if it's technically directional)
   g_HAConsecCount = CountConsecutive(1, dir1);

   // Update key-level crossing tracker (separate from chain consec; uses 20-pip level spacing)
   UpdateHALevelConsec(dir1);

   // === DOJI INVALIDATION ===
   // A HA doji (haClose ≈ haOpen) OR a near-doji (body < 25% of range) signals
   // indecision and invalidates any running setup.
   if(dir1 == 0 || IsHADoji(1)) {
      if(g_HABullSetup || g_HABearSetup) {
         Print("[DOJI] HA doji at bar1 — invalidating ",
               (g_HABullSetup ? "BUY" : "SELL"),
               " setup. Counter reset to WAITING.");
      }
      g_HABullSetup       = false;
      g_HABearSetup       = false;
      g_ConfirmCandleOpen = 0;
      g_BoldTier          = "NORMAL";
      g_ZonePending       = false;
      g_ZoneContextUsed   = false;
      g_Signal            = "WAITING";
      g_PreflightBullOK   = false;
      g_PreflightBearOK   = false;
      g_PreflightBlocker  = "";
      g_HAQualityLabel    = "DOJI";
      g_HAQualityScore    = 0;
      g_HAQualityTotal    = 0;
      g_ConfirmPure       = false;
      g_HAConsecSinceKeyLevel = 0;  // doji breaks the key-level chain too
      return;
   }

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
            g_HABullSetup        = true;
            g_Signal             = "PREPARING BUY";
            g_ConfidenceStatic   = CalcConfidence(1, g_ZoneLabel, false, IsSideways(), g_NearLevel);
            g_ConfidenceArmedBar = iTime(_Symbol, PERIOD_M15, 0);
            Print("[STARTUP RECOVERY] Re-armed BUY setup from bar ", ri,
                  " (bottomless bull). Consec=", g_HAConsecCount, "/", MaxConsecCandles,
                  " Conf=", DoubleToString(g_ConfidenceStatic, 1), "%");
            break;
         }
         if(dir1 == -1 && IsTopless(ri)) {
            g_HABearSetup        = true;
            g_Signal             = "PREPARING SELL";
            g_ConfidenceStatic   = CalcConfidence(-1, g_ZoneLabel, false, IsSideways(), g_NearLevel);
            g_ConfidenceArmedBar = iTime(_Symbol, PERIOD_M15, 0);
            Print("[STARTUP RECOVERY] Re-armed SELL setup from bar ", ri,
                  " (topless bear). Consec=", g_HAConsecCount, "/", MaxConsecCandles,
                  " Conf=", DoubleToString(g_ConfidenceStatic, 1), "%");
            break;
         }
      }
   }

   // === BUY SETUP STATE MACHINE ===
   // Step 1: bottomless bull → arm the setup (only if NOT already armed)
   // A 2nd/3rd consecutive bottomless candle falls to Step 2 as confirmation.
   if(bl1 && dir1 == 1 && !g_HABullSetup) {
      // --- SPIKE CANDLE FILTER v7.00 ---
      // A single long impulse candle (range > SpikeATRMult × ATR) is often a news/stop-hunt
      // spike, typically followed by a reversal or consolidation that eats the SL.
      // Skip the setup arm; reset the counter so the NEXT two candles form a fresh read.
      if(InvalidateSpikeCandles && g_ATR > 0) {
         double _haOS, _haHS, _haLS, _haCS;
         CalcHA(1, _haOS, _haHS, _haLS, _haCS);
         double _spikeRange = _haHS - _haLS;
         if(_spikeRange > SpikeATRMult * g_ATR) {
            Print("[SPIKE BUY] Bar1 HA range ", DoubleToString(_spikeRange/_Point/10.0,1),
                  "pip > ", DoubleToString(SpikeATRMult,1), "×ATR=",
                  DoubleToString(SpikeATRMult*g_ATR/_Point/10.0,1),
                  "pip — SPIKE invalidated, counter reset, awaiting 2 clean candles");
            g_HAConsecCount = 0;
            g_Signal        = "WAITING";
            return;
         }
      }
      g_HABullSetup        = true;
      g_HABearSetup        = false;
      g_ConfirmCandleOpen  = 0;
      g_BoldTier           = "NORMAL";   // fresh arm — reset tier
      g_BoldRejectConsec   = 0;           // new setup — clear throttle
      g_BollOverridden     = false;
      g_BollOverrideReason = "";
      g_ZonePending        = false;
      g_ZoneContextUsed    = false;
      // Flip fast-entry: if bar2 was bearish (momentum flip), the first bottomless bull
      // candle is sufficient confirmation — skip PREPARING and go straight to BUY INCOMING.
      // NB co-driver: if NB strongly agrees, also skip PREPARING.
      // NB suppression: only veto when NB is MAJORITY-DOWN (>50%) AND P(UP)<NBMinPosterior
      // AND this is NOT a flip (flips are the strongest HA signals — never NB-suppressed).
      // v7.00: ZAP fakeout bypass — if we swept support and reversed, NB suppression is lifted
      bool zapFastBuy = UseZAP && ZAPFastTrack && g_ZAPActive && g_ZAPDir == 1 && g_ZAPScore >= ZAPMinScore;
      if(UseNBBrain && g_HaNB_Trained && !g_HADirFlip && !g_ZAPFakeout
         && g_NBSellProb > 50.0 && g_NBBuyProb < NBMinPosterior) {
         g_HABullSetup = false;   // undo — NB majority-DOWN vetoes this BUY setup (ZAP fakeout exempted)
         g_Signal      = "WAITING";
         Print("[NB] BUY suppressed: P(UP)=", DoubleToString(g_NBBuyProb,1),
               "% < ", DoubleToString(NBMinPosterior,0), "% | P(DOWN)=", DoubleToString(g_NBSellProb,1),
               "% (majority-DOWN, not a flip)");
      } else {
         bool goDirectBuy = g_HADirFlip || zapFastBuy || (UseNBBrain && g_HaNB_Trained && g_NBBuyProb >= NBHighThreshold);
         if(goDirectBuy) {
            g_Signal            = "BUY INCOMING";
            g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 1);
         } else {
            g_Signal            = "PREPARING BUY";
         }
         g_PrepStartTime      = TimeCurrent();
         // v6.38: pre-cache confidence immediately at arm time so preflight has live score
         g_ConfidenceStatic   = CalcConfidence(1, g_ZoneLabel, false, IsSideways(), g_NearLevel);
         g_ConfidenceArmedBar = iTime(_Symbol, PERIOD_M15, 0);
         if(goDirectBuy)
            Print("DIRECT BUY INCOMING: ", (g_HADirFlip ? "bear->bull flip" : "NB high confidence"),
                  " P(UP)=", DoubleToString(g_NBBuyProb,1), "%",
                  " Consec=", g_HAConsecCount, " Conf=", DoubleToString(g_ConfidenceStatic, 1), "%");
         else
            Print("PREPARING BUY: bottomless bull candle (bar1).",
                  " P(UP)=", DoubleToString(g_NBBuyProb,1), "%",
                  " Consec=", g_HAConsecCount, "/", MaxConsecCandles,
                  " Zone=", g_ZoneLabel, " Conf=", DoubleToString(g_ConfidenceStatic, 1), "%");
      }
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
         // === REAL CANDLE ALIGNMENT GATE (v6.29) ===
         // HA says bullish — verify real candles (OHLC) on bars 1 & 2 are also bullish.
         // If both real candles are bearish, the HA signal is just a smoothing artifact — stay PREPARING.
         bool realCandleOK = true;
         if(bollOK) {
            double _rcB1 = iClose(_Symbol, PERIOD_M15, 1);
            double _roB1 = iOpen (_Symbol, PERIOD_M15, 1);
            double _rcB2 = iClose(_Symbol, PERIOD_M15, 2);
            double _roB2 = iOpen (_Symbol, PERIOD_M15, 2);
            bool _realBull1 = (_rcB1 > _roB1);
            bool _realBull2 = (_rcB2 > _roB2);
            g_RealCandleAligned = (_realBull1 && _realBull2);
            if(!_realBull1 && !_realBull2) {
               // Both real candles bearish while HA is bullish — block promotion
               realCandleOK = false;
               Print("PREPARING BUY: Real candle MISALIGNED — HA bullish but BOTH real candles bearish",
                     " bar1=", DoubleToString(_rcB1-_roB1,5), " bar2=", DoubleToString(_rcB2-_roB2,5),
                     " — waiting for real alignment.");
            } else if(!_realBull1 || !_realBull2) {
               // One real candle conflicts — hold in PREPARING (don't reset chain; single pullback candle is normal)
               g_ConfirmCandleOpen  = 0;
               realCandleOK         = false;
               g_Signal             = "PREPARING BUY";
               g_SignalPendingReason = "real-MIXED bar1=" + (_realBull1?"BULL":"BEAR")
                                       + " bar2=" + (_realBull2?"BULL":"BEAR")
                                       + " — awaiting real alignment";
               Print("BUY: Real candle MIXED — bar1=", (_realBull1?"BULL":"BEAR"),
                     " bar2=", (_realBull2?"BULL":"BEAR"),
                     " — staying PREPARING (chain preserved, consec=", g_HAConsecCount, ")");
            }
         }
         if(bollOK && realCandleOK) {
            if(g_ConfirmCandleOpen == 0)
               g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 1);
            g_Signal             = "BUY INCOMING";
            g_SignalPendingReason = "";  // clean confirm — clear any stale reason
            if(bollOverrideApplied)
               Print("BUY INCOMING [BOLL OVERRIDE]: entering despite Boll midline — ", g_BollOverrideReason);
         } else {
            g_Signal            = "PREPARING BUY";
            g_ConfirmCandleOpen = 0;
            if(!bollOK) {
               g_SignalPendingReason = "";  // Bollinger block — clear MIXED reason
               Print("PREPARING BUY: Bollinger gate BLOCKING",
                     (isNarrow ? " [NARROW band=" + DoubleToString(bandWidthPips,1) + "pip]" : ""),
                     " HA_H1=", DoubleToString(haH1b, 5),
                     " BodyMid1=", DoubleToString(bodyMid1, 5),
                     " BollMid=", DoubleToString(g_BollingerMid1, 5),
                     " BollUpper=", DoubleToString(g_BollingerUpper1, 5),
                     isNarrow ? " (need HA high >= BollMid)" : " (need body <= BollMid)",
                     " | Override-check: ", g_BollOverrideReason);
            }
            // Note: realCandleOK=false already printed its own diagnostic above
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
      // --- SPIKE CANDLE FILTER v7.00 ---
      if(InvalidateSpikeCandles && g_ATR > 0) {
         double _haOSs, _haHSs, _haLSs, _haCss;
         CalcHA(1, _haOSs, _haHSs, _haLSs, _haCss);
         double _spikeRangeS = _haHSs - _haLSs;
         if(_spikeRangeS > SpikeATRMult * g_ATR) {
            Print("[SPIKE SELL] Bar1 HA range ", DoubleToString(_spikeRangeS/_Point/10.0,1),
                  "pip > ", DoubleToString(SpikeATRMult,1), "×ATR=",
                  DoubleToString(SpikeATRMult*g_ATR/_Point/10.0,1),
                  "pip — SPIKE invalidated, counter reset, awaiting 2 clean candles");
            g_HAConsecCount = 0;
            g_Signal        = "WAITING";
            return;
         }
      }
      g_HABearSetup        = true;
      g_HABullSetup        = false;
      g_ConfirmCandleOpen  = 0;
      g_BoldTier           = "NORMAL";   // fresh arm — reset tier
      g_BoldRejectConsec   = 0;           // new setup — clear throttle
      g_BollOverridden     = false;
      g_BollOverrideReason = "";
      g_ZonePending        = false;
      g_ZoneContextUsed    = false;
      // Flip fast-entry: if bar2 was bullish (momentum flip), the first topless bear
      // candle is sufficient confirmation — skip PREPARING and go straight to SELL INCOMING.
      // NB co-driver: if NB strongly agrees, also skip PREPARING.
      // NB suppression: only veto when NB is MAJORITY-UP (>50%) AND P(DOWN)<NBMinPosterior
      // AND this is NOT a flip (flips are the strongest HA signals — never NB-suppressed).
      // v7.00: ZAP fakeout bypass — if we swept resistance and reversed, NB suppression is lifted
      bool zapFastSell = UseZAP && ZAPFastTrack && g_ZAPActive && g_ZAPDir == -1 && g_ZAPScore >= ZAPMinScore;
      if(UseNBBrain && g_HaNB_Trained && !g_HADirFlip && !g_ZAPFakeout
         && g_NBBuyProb > 50.0 && g_NBSellProb < NBMinPosterior) {
         g_HABearSetup = false;   // undo — NB majority-UP vetoes this SELL setup (ZAP fakeout exempted)
         g_Signal      = "WAITING";
         Print("[NB] SELL suppressed: P(DOWN)=", DoubleToString(g_NBSellProb,1),
               "% < ", DoubleToString(NBMinPosterior,0), "% | P(UP)=", DoubleToString(g_NBBuyProb,1),
               "% (majority-UP, not a flip)");
      } else {
         bool goDirectSell = g_HADirFlip || zapFastSell || (UseNBBrain && g_HaNB_Trained && g_NBSellProb >= NBHighThreshold);
         if(goDirectSell) {
            g_Signal            = "SELL INCOMING";
            g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 1);
         } else {
            g_Signal            = "PREPARING SELL";
         }
         g_PrepStartTime      = TimeCurrent();
         // v6.38: pre-cache confidence immediately at arm time so preflight has live score
         g_ConfidenceStatic   = CalcConfidence(-1, g_ZoneLabel, false, IsSideways(), g_NearLevel);
         g_ConfidenceArmedBar = iTime(_Symbol, PERIOD_M15, 0);
         if(goDirectSell)
            Print("DIRECT SELL INCOMING: ", (g_HADirFlip ? "bull->bear flip" : "NB high confidence"),
                  " P(DOWN)=", DoubleToString(g_NBSellProb,1), "%",
                  " Consec=", g_HAConsecCount, " Conf=", DoubleToString(g_ConfidenceStatic, 1), "%");
         else
            Print("PREPARING SELL: topless bear candle (bar1).",
                  " P(DOWN)=", DoubleToString(g_NBSellProb,1), "%",
                  " Consec=", g_HAConsecCount, "/", MaxConsecCandles,
                  " Zone=", g_ZoneLabel, " Conf=", DoubleToString(g_ConfidenceStatic, 1), "%");
      }
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
         // === REAL CANDLE ALIGNMENT GATE — SELL (v6.29) ===
         // HA says bearish — verify real candles (OHLC) on bars 1 & 2 are also bearish.
         // If both real candles are bullish, the HA signal is just a smoothing artifact.
         bool realCandleOKS = true;
         if(bollOK) {
            double _rcS1 = iClose(_Symbol, PERIOD_M15, 1);
            double _roS1 = iOpen (_Symbol, PERIOD_M15, 1);
            double _rcS2 = iClose(_Symbol, PERIOD_M15, 2);
            double _roS2 = iOpen (_Symbol, PERIOD_M15, 2);
            bool _realBear1 = (_rcS1 < _roS1);
            bool _realBear2 = (_rcS2 < _roS2);
            g_RealCandleAligned = (_realBear1 && _realBear2);
            if(!_realBear1 && !_realBear2) {
               // Both real candles bullish while HA is bearish — block promotion
               realCandleOKS = false;
               Print("PREPARING SELL: Real candle MISALIGNED — HA bearish but BOTH real candles bullish",
                     " bar1=", DoubleToString(_rcS1-_roS1,5), " bar2=", DoubleToString(_rcS2-_roS2,5),
                     " — waiting for real alignment.");
            } else if(!_realBear1 || !_realBear2) {
               // One real candle conflicts — hold in PREPARING (don't reset chain; single pullback candle is normal)
               g_ConfirmCandleOpen  = 0;
               realCandleOKS        = false;
               g_Signal             = "PREPARING SELL";
               g_SignalPendingReason = "real-MIXED bar1=" + (_realBear1?"BEAR":"BULL")
                                       + " bar2=" + (_realBear2?"BEAR":"BULL")
                                       + " — awaiting real alignment";
               Print("SELL: Real candle MIXED — bar1=", (_realBear1?"BEAR":"BULL"),
                     " bar2=", (_realBear2?"BEAR":"BULL"),
                     " — staying PREPARING (chain preserved, consec=", g_HAConsecCount, ")");
            }
         }
         if(bollOK && realCandleOKS) {
            if(g_ConfirmCandleOpen == 0)
               g_ConfirmCandleOpen = iTime(_Symbol, PERIOD_M15, 1);
            g_Signal             = "SELL INCOMING";
            g_SignalPendingReason = "";  // clean confirm — clear any stale reason
            if(bollOverrideAppliedS)
               Print("SELL INCOMING [BOLL OVERRIDE]: entering despite Boll midline — ", g_BollOverrideReason);
         } else {
            g_Signal            = "PREPARING SELL";
            g_ConfirmCandleOpen = 0;
            if(!bollOK) {
               g_SignalPendingReason = "";  // Bollinger block — clear MIXED reason
               Print("PREPARING SELL: Bollinger gate BLOCKING",
                     (isNarrow ? " [NARROW band=" + DoubleToString(bandWidthPips,1) + "pip]" : ""),
                     " HA_L1=", DoubleToString(haL1s, 5),
                     " BodyMid1=", DoubleToString(bodyMid1s, 5),
                     " BollMid=", DoubleToString(g_BollingerMid1, 5),
                     " BollLower=", DoubleToString(g_BollingerLower1, 5),
                     isNarrow ? " (need HA low <= BollMid)" : " (need body >= BollMid)",
                     " | Override-check: ", g_BollOverrideReason);
            }
            // Note: realCandleOKS=false already printed its own diagnostic above
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
      g_HABearSetup        = false;
      g_ConfirmCandleOpen  = 0;
      g_BoldTier           = "NORMAL";
      g_ZonePending        = false;
      g_ZoneContextUsed    = false;
      g_Signal             = "WAITING";
      g_ConfidenceStatic   = 0; g_ConfidenceArmedBar = 0;  // v6.38: stale cache
      g_PreflightBearOK    = false;   // bear setup died
      g_PreflightBlocker   = "";
   }
   else if(dir1 == -1 && g_HABullSetup) {
      g_HABullSetup        = false;
      g_ConfirmCandleOpen  = 0;
      g_BoldTier           = "NORMAL";
      g_ZonePending        = false;
      g_ZoneContextUsed    = false;
      g_Signal             = "WAITING";
      g_ConfidenceStatic   = 0; g_ConfidenceArmedBar = 0;  // v6.38: stale cache
      g_PreflightBullOK    = false;   // bull setup died
      g_PreflightBlocker   = "";
   }

   // === HA ALIGNMENT QUALITY — computed after state machine resolves ===
   // Checks how many of the bars in the active consecutive chain are "pure":
   //  Bull chain: bottomless (haOpen == haLow, no lower shadow) = strong signal
   //  Bear chain: topless   (haOpen == haHigh, no upper shadow) = strong signal
   // A candle with haOpen > haLow (bull) or haOpen < haHigh (bear) carries an
   // opposite wick and is considered IMPURE — momentum may be weakening.
   {
      int chainDir = (g_Signal == "BUY INCOMING" || g_Signal == "PREPARING BUY")  ?  1 :
                     (g_Signal == "SELL INCOMING" || g_Signal == "PREPARING SELL") ? -1 : 0;
      if(chainDir == 0) {
         g_HAQualityLabel = "—";
         g_HAQualityScore = 0;
         g_HAQualityTotal = 0;
         g_ConfirmPure    = false;
      } else {
         int checkBars = MathMin(g_HAConsecCount, 4);
         int pureCount = 0;
         for(int qi = 1; qi <= checkBars; qi++) {
            double qO, qH, qL, qC;
            CalcHA(qi, qO, qH, qL, qC);
            bool pure = (chainDir == 1)
                        ? (MathAbs(qL - qO) <= _Point * 3)   // bull: no lower shadow
                        : (MathAbs(qH - qO) <= _Point * 3);  // bear: no upper shadow
            if(pure) pureCount++;
         }
         g_HAQualityScore = pureCount;
         g_HAQualityTotal = checkBars;
         // Confirming bar (bar1) purity — key quality indicator
         {
            double cO, cH, cL, cC;
            CalcHA(1, cO, cH, cL, cC);
            g_ConfirmPure = (chainDir == 1)
                            ? (MathAbs(cL - cO) <= _Point * 3)
                            : (MathAbs(cH - cO) <= _Point * 3);
         }
         if(checkBars == 0) {
            g_HAQualityLabel = "—";
         } else {
            int pct = (pureCount * 100) / checkBars;
            if(pct >= 75)      g_HAQualityLabel = "PURE";
            else if(pct >= 50) g_HAQualityLabel = "MIXED";
            else               g_HAQualityLabel = "IMPURE";
         }
      }
   }

   // === PREPARING EXPIRY — if Bollinger hasn't confirmed after PrepMaxBars, abandon setup ===
   if((g_Signal == "PREPARING BUY" || g_Signal == "PREPARING SELL") && PrepMaxBars > 0 && g_PrepStartTime > 0) {
      int barsSinceArm = Bars(_Symbol, PERIOD_M15, g_PrepStartTime, TimeCurrent());
      if(barsSinceArm >= PrepMaxBars) {
         Print("[PREPARING EXPIRED] ", g_Signal, " timed out after ", barsSinceArm,
               " bars (max=", PrepMaxBars, ") — Bollinger never confirmed. Resetting to WAITING.");
         g_Signal             = "WAITING";
         g_ConfidenceStatic   = 0; g_ConfidenceArmedBar = 0;  // v6.38: stale cache
         g_HABullSetup        = false;
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
      // v6.37: per-session slot check for preflight
      if(hpDailyOK && OneTradePerSession) {
         MqlDateTime _pfSdt; TimeToStruct(TimeCurrent(), _pfSdt);
         bool _pfAsian  = (_pfSdt.hour >= AsianStartHour   && _pfSdt.hour < AsianEndHour);
         bool _pfLondon = (_pfSdt.hour >= LondonStartHour  && _pfSdt.hour < LondonEndHour);
         bool _pfNY     = (_pfSdt.hour >= NewYorkStartHour && _pfSdt.hour < NewYorkEndHour);
         if(_pfAsian  && g_AsianTradeCount  >= 1) hpDailyOK = false;
         if(_pfLondon && g_LondonTradeCount >= 1) hpDailyOK = false;
         if(_pfNY     && g_NYTradeCount     >= 1) hpDailyOK = false;
      }
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
      // v6.29: Volume state + real candle alignment in diagnostic
      confirmed += " | Vol=" + g_VolumeState + "(x" + DoubleToString(g_VolRatio,2) + ")";
      confirmed += " | RealCdl=" + (g_RealCandleAligned ? "ALIGNED" : "MIXED/MISS");
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
      // v6.29: Volume and candle alignment   v6.32: all-session observe + fake-out watch
      bool hpVolOK     = !(UseVolumeAnalysis && g_VolumeState == "DEAD");  // v6.36: only DEAD blocks; LOW is penalty
      bool hpSessObsOK = true;
      string hpSessObsBlocker = "";
      {
         MqlDateTime _pfAdt; TimeToStruct(TimeCurrent(), _pfAdt);
         bool _pfInAsian  = (_pfAdt.hour >= AsianStartHour   && _pfAdt.hour < AsianEndHour);
         bool _pfInLondon = (_pfAdt.hour >= LondonStartHour  && _pfAdt.hour < LondonEndHour);
         bool _pfInNY     = (_pfAdt.hour >= NewYorkStartHour && _pfAdt.hour < NewYorkEndHour);
         if(_pfInAsian  && AsianObserveBars  > 0 && g_AsianBarCount  <= AsianObserveBars) {
            hpSessObsOK = false;
            hpSessObsBlocker = "AsianObs "  + IntegerToString(g_AsianBarCount)  + "/" + IntegerToString(AsianObserveBars);
         } else if(_pfInLondon && LondonObserveBars > 0 && g_LondonBarCount <= LondonObserveBars) {
            hpSessObsOK = false;
            hpSessObsBlocker = "LondonObs " + IntegerToString(g_LondonBarCount) + "/" + IntegerToString(LondonObserveBars);
         } else if(_pfInNY && NYObserveBars > 0 && g_NYBarCount <= NYObserveBars) {
            hpSessObsOK = false;
            hpSessObsBlocker = "NYObs "     + IntegerToString(g_NYBarCount)     + "/" + IntegerToString(NYObserveBars);
         }
         if(hpSessObsOK && g_SessionFakeoutWatch && g_FakeoutDir != 0 && g_FakeoutDir == (isBuy ? 1 : -1)) {
            // If the Asian Bias is established and aligned with this trade direction, a MEDIUM
            // fakeout watch is overruled: the price has already moved the required pip distance
            // in this direction — it is a confirmed Asian trend, not a trap.
            // A HIGH-confidence fakeout (strong multi-session agreement) still blocks regardless.
            bool _asianBiasOverrules = AsianBiasEnabled && g_AsianBiasActive
                                       && g_AsianBiasDir == (isBuy ? 1 : -1)
                                       && g_FakeoutConfidence != "HIGH";
            if(_asianBiasOverrules) {
               hpSessObsBlocker = "";  // allowed — Asian Bias confirmed; MEDIUM fakeout watch suspended
               Print("[FAKEOUT OVERRIDE] Asian Bias confirmed (", g_AsianBiasLabel, ") overrules MEDIUM fakeout watch");
            } else {
               hpSessObsOK = false;
               hpSessObsBlocker = "FakeoutWatch[" + g_FakeoutConfidence + "]: " + g_InterSessContext;
            }
         }
      }
      // v6.34: MA200 macro block preflight check (declared here so nextGates can reference them)
      // v6.35: also factors in fake-jump guard and pending state
      // v6.38: CHoCH exemption suppressed when BOTH MA50 and MA20 haven't crossed MA200 —
      //        neither MA confirming the move means the CHoCH itself was caused by the same false spike.
      bool _fkBothBelowMA200 = g_MA20 > 0 && g_MA20 < g_MA200 && g_MA50 < g_MA200;
      bool _fkBothAboveMA200 = g_MA20 > 0 && g_MA20 > g_MA200 && g_MA50 > g_MA200;
      bool _fakeJumpBlockBuy  = UseMAFilter && MA200FakeJumpBlock && g_MA200FakeJumpUp && isBuy
                                && !(!_fkBothBelowMA200 && ((g_CHoCHActive && g_CHoCHDir==1) || (g_MacroCHoCH && g_MacroCHoCHDir==1)));
      bool _fakeJumpBlockSell = UseMAFilter && MA200FakeJumpBlock && g_MA200FakeJumpDn && !isBuy
                                && !(!_fkBothAboveMA200 && ((g_CHoCHActive && g_CHoCHDir==-1) || (g_MacroCHoCH && g_MacroCHoCHDir==-1)));
      bool hpMAOK = !_fakeJumpBlockBuy && !_fakeJumpBlockSell &&
                    (!UseMAFilter || !MA200MacroHardBlock || g_MA200 <= 0 ||
                     (isBuy ? (g_AboveMA200 || g_MA200CrossUp ||
                               (g_CHoCHActive && g_CHoCHDir == 1) || (g_MacroCHoCH && g_MacroCHoCHDir == 1)
                               || (g_PendingMA200Ticket != 0 && g_PendingMA200Dir == 1))
                            : (!g_AboveMA200 || g_MA200CrossDn ||
                               (g_CHoCHActive && g_CHoCHDir == -1) || (g_MacroCHoCH && g_MacroCHoCHDir == -1)
                               || (g_PendingMA200Ticket != 0 && g_PendingMA200Dir == -1))));
      bool hpMA50OK = !UseMAFilter || !MA5020EntryRequired || g_MA50 <= 0 ||
                      (isBuy ? (g_AboveMA50 || g_MA50Touch || g_MA50CrossUp)
                             : (!g_AboveMA50 || g_MA50Touch || g_MA50CrossDn));
      bool hpExtCapOK = !UseDailyExtCap || DailyExtCapPct <= 0 ||
                        (isBuy ? (g_DailyExtUpPct   <= DailyExtCapPct)
                               : (g_DailyExtDownPct <= DailyExtCapPct)) ||
                        // Key-level override: cap ignored when a level was broken with room ahead
                        (CheckLevelBreakBars(isBuy ? 1 : -1) <= MaxConsecCandles * 2 &&
                         FindNextTargetLevel(SymbolInfoDouble(_Symbol, SYMBOL_BID), isBuy ? 1 : -1) > 0);
      nextGates += "\n  " + (hpVolOK     ? "✓" : "✗") + " Vol=" + g_VolumeState + "(x" + DoubleToString(g_VolRatio,2) + ")";
      nextGates += " | RealCdlAlign=" + (g_RealCandleAligned ? "ALIGNED" : "mixed/miss");
      nextGates += " | " + (hpSessObsOK  ? "✓" : "✗") + " SessObs=" + (hpSessObsOK ? "OK" : hpSessObsBlocker);
      if(g_SessionFakeoutWatch)
         nextGates += " [" + g_FakeoutConfidence + " TRAP: " + g_InterSessContext + "]";
      else if(g_InterSessContext != "")
         nextGates += " [InterSess: " + g_InterSessContext + "]";
      // v6.34: MA and daily ext cap status in preflight
      nextGates += "\n  " + (hpMAOK    ? "✓" : "✗") + " MA200=" + (g_MAStatusLabel != "" ? g_MAStatusLabel : "not ready");
      nextGates += " | " + (hpMA50OK  ? "✓" : "✗") + " MA50touch=" + (g_MA50Touch ? "YES" : "no") + " cross=" + (g_MA50CrossUp ? "UP" : g_MA50CrossDn ? "DN" : "no");
      nextGates += " | " + (hpExtCapOK ? "✓" : "✗") + " DayExt D:" + DoubleToString(g_DailyExtDownPct,0) + "% U:" + DoubleToString(g_DailyExtUpPct,0) + "% (cap=" + DoubleToString(DailyExtCapPct,0) + "%%)";

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
                            !macroBOSBlockPF && !g_TradeOpen && hpVolOK && hpSessObsOK &&
                            hpMAOK && hpMA50OK && hpExtCapOK;
      if(isBuy)  g_PreflightBullOK = allDownGatesOK;
      else       g_PreflightBearOK = allDownGatesOK;

      if(!allDownGatesOK) {
         if(!hpVolOK)          g_PreflightBlocker = "DEAD volume (ratio=" + DoubleToString(g_VolRatio,2) + ")";
         else if(!hpSessObsOK) g_PreflightBlocker = hpSessObsBlocker;
         else if(!hpTimeOK)         g_PreflightBlocker = "NoEntryAfter=" + IntegerToString(NoEntryAfterHour) + ":00";
         else if(!hpCooldownOK) g_PreflightBlocker = cooldownInfo;
         else if(!hpDailyOK)    g_PreflightBlocker = "DailyTrades=" + IntegerToString(g_DailyTradeCount) + "/" + IntegerToString(MaxDailyTrades);
         else if(!hpDailyLossOK)g_PreflightBlocker = "DailyLoss=$" + DoubleToString(g_DailyPnL,2);
         else if(!hpForeignOK)  g_PreflightBlocker = "ForeignTrade open";
         else if(!hpZoneOK)     g_PreflightBlocker = "Zone=" + g_ZoneLabel;
         else if(!hpBiasOK)     g_PreflightBlocker = "Bias=" + IntegerToString(g_TotalBias);
         else if(macroBOSBlockPF)g_PreflightBlocker = "MacroBOS=" + g_MacroStructLabel;
         else if(!hpMAOK)       g_PreflightBlocker = (_fakeJumpBlockBuy || _fakeJumpBlockSell)
                                                       ? "MA200 fake-jump (" + g_MAStatusLabel + ") — await MA50 catch-up"
                                                       : "MA200 macro block (" + g_MAStatusLabel + ")";
         else if(!hpMA50OK)     g_PreflightBlocker = "MA50 not touched (" + g_MAStatusLabel + ") dist>" + DoubleToString(MA50TouchPips,1) + "pip";
         else if(!hpExtCapOK)   g_PreflightBlocker = "DayExt cap " + DoubleToString(isBuy?g_DailyExtUpPct:g_DailyExtDownPct,1) + "% (max=" + DoubleToString(DailyExtCapPct,1) + "%)";
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
//+------------------------------------------------------------------+
//| SESSION GATE v7.00                                               |
//| Returns true when the current broker time is inside the session  |
//| mode selected by the user. Only NEW trade ENTRIES are gated here.|
//| Open trades always continue (closed at SL/TP or EOD).           |
//+------------------------------------------------------------------+
bool IsInAllowedSession()
{
   if(SessionMode == 0) return true;   // All sessions — no restriction
   MqlDateTime _sgDt; TimeToStruct(TimeCurrent(), _sgDt);
   int h = _sgDt.hour;
   bool _inAsian  = (h >= AsianStartHour  && h < AsianEndHour);
   bool _inLondon = (h >= LondonStartHour && h < LondonEndHour);
   switch(SessionMode) {
      case 1: return _inAsian;                     // Asian only
      case 2: return _inLondon;                    // London only
      case 3: return (_inAsian || _inLondon);      // Asian + London
   }
   return true;
}

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
      // Standard: live body mid on the correct side of midline  (v6.36: +2 pip tolerance)
      double bollTol = 2.0 * _Point * 10;
      if(tradeDir ==  1) return (bodyMid <= g_BollingerMid1 + bollTol);
      else               return (bodyMid >= g_BollingerMid1 - bollTol);
   }
}

//+------------------------------------------------------------------+
//| ENTRY LOGIC v3                                                    |
//| Handles: trend trades, midrange caution, mean reversion          |
//+------------------------------------------------------------------+
void TryEntry()
{
   if(g_TradeOpen) return;

   // v7.00: SESSION MODE GATE — block new entries outside the user-selected session(s)
   if(SessionMode != 0 && !IsInAllowedSession()) {
      static datetime _sessBlockBar = 0;
      if(iTime(_Symbol, PERIOD_M15, 0) != _sessBlockBar) {
         MqlDateTime _sbDt; TimeToStruct(TimeCurrent(), _sbDt);
         string _modeName[] = {"All","Asian","London","Asian+London"};
         Print("[SESSION GATE] New entries blocked — hour=", _sbDt.hour,
               " mode=", _modeName[MathMin(SessionMode,3)],
               " (open trades continue unaffected)");
         _sessBlockBar = iTime(_Symbol, PERIOD_M15, 0);
      }
      return;
   }

   // v6.36: equity drawdown protection
   if(MaxDrawdownPct > 0 && g_PeakEquity > 0) {
      double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      double ddPct = (g_PeakEquity - curEquity) / g_PeakEquity * 100.0;
      if(ddPct > MaxDrawdownPct) {
         static datetime lastDDPrint = 0;
         if(TimeCurrent() - lastDDPrint > 300) {  // print every 5 min max
            Print("[DRAWDOWN BLOCK] Equity DD=", DoubleToString(ddPct,1), "% > max ",
                  DoubleToString(MaxDrawdownPct,1), "% — entries paused");
            lastDDPrint = TimeCurrent();
         }
         return;
      }
   }

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
   // === PER-SESSION TRADE LIMIT (v6.37) ===
   if(OneTradePerSession) {
      MqlDateTime _sdt; TimeToStruct(TimeCurrent(), _sdt);
      bool _inAsian  = (_sdt.hour >= AsianStartHour   && _sdt.hour < AsianEndHour);
      bool _inLondon = (_sdt.hour >= LondonStartHour  && _sdt.hour < LondonEndHour);
      bool _inNY     = (_sdt.hour >= NewYorkStartHour && _sdt.hour < NewYorkEndHour);
      string _sesName = _inAsian ? "Asian" : _inLondon ? "London" : _inNY ? "NY" : "";
      int    _sesCnt  = _inAsian ? g_AsianTradeCount : _inLondon ? g_LondonTradeCount : _inNY ? g_NYTradeCount : 0;
      if(_sesName != "" && _sesCnt >= 1) {
         if(_canPrintBlock) {
            Print("[ENTRY WAIT] ", _sesName, " session slot already used (1/1) | Signal=", g_Signal);
            g_LastBlockPrintBar = _blockBar;
         }
         return;
      }
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
      // Fresh NB retrain: model now has bars formed during the grace window
      if(UseNBBrain) {
         BuildAndTrainNBBrain();
         CalcNBLiveProbs();
         Print("[NB] Grace-end retrain complete — P(UP)=", DoubleToString(g_NBBuyProb,1),
               "% P(DN)=", DoubleToString(g_NBSellProb,1), "% samples=", g_HaNB_SampleCount);
      }
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
            g_Signal             = "WAITING";
            g_ConfidenceStatic   = 0; g_ConfidenceArmedBar = 0;  // v6.38: stale cache
            g_HABullSetup        = false;
            g_HABearSetup        = false;
         }
         return;
      }
   }

   // === NEWS NO-TRADE ZONE (v6.39) ===
   // Block new entries when a HIGH-impact EUR or USD event is imminent.
   if(ShowCalendar && CalendarNoTradeMins > 0 && g_NewsNoTrade) {
      string _evInfo = "";
      for(int _ni = 0; _ni < g_CalEventCount; _ni++) {
         if(g_CalEvents[_ni].importance == 3) {
            int _nSecs = (int)(g_CalEvents[_ni].time - TimeCurrent());
            if(_nSecs >= 0 && _nSecs <= CalendarNoTradeMins * 60) {
               _evInfo = g_CalEvents[_ni].currency + " " + g_CalEvents[_ni].name +
                         " in " + IntegerToString(_nSecs / 60) + "min";
               break;
            }
         }
      }
      string _newsMsg = "[NEWS BLOCK] Entry paused -- HIGH impact imminent: " + _evInfo;
      if(_newsMsg != g_LastBlockReason) { Print(_newsMsg); g_LastBlockReason = _newsMsg; }
      return;
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
      g_Signal = "WAITING"; g_ConfidenceStatic = 0; g_ConfidenceArmedBar = 0;  // v6.38
      g_HABullSetup = false; g_HABearSetup = false;
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

   // === HPL HORIZONTAL PRICE LEVEL BLOCK ===
   // Block trend entries when price is sitting AT or inside an unbroken horizontal
   // rejection zone. Mean-reversion entries AT the HPL are intentional (the whole
   // point of MRV is to fade the level), so isMeanRev is exempt.
   if(UseHPL && tradeDir != 0 && !isMeanRev) {
      if(tradeDir == 1 && HPLBlockBuysAtResist && g_HPLResistBlock) {
         string _hplMsg = "[HPL BLOCK] BUY blocked — RESIST HPL @" +
                          DoubleToString(g_HPLResistLow * 1.0, _Digits) + "-" +
                          DoubleToString(g_HPLResistHigh * 1.0, _Digits) +
                          " — wait for clean close above zone";
         if(_hplMsg != g_LastBlockReason) { Print(_hplMsg); g_LastBlockReason = _hplMsg; }
         return;
      }
      if(tradeDir == -1 && HPLBlockSellsAtSupport && g_HPLSupportBlock) {
         string _hplMsg = "[HPL BLOCK] SELL blocked — SUPPORT HPL @" +
                          DoubleToString(g_HPLSupportLow * 1.0, _Digits) + "-" +
                          DoubleToString(g_HPLSupportHigh * 1.0, _Digits) +
                          " — wait for clean close below zone";
         if(_hplMsg != g_LastBlockReason) { Print(_hplMsg); g_LastBlockReason = _hplMsg; }
         return;
      }
   }

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
                            " zone [CONTEXT score=" + IntegerToString(ctxScore) + "/15, need " +
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
                               " bars, score=" + IntegerToString(ctxScore) + "/15)";
                  if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
                  return;
               }

            } else if(approachLvl != "" && atLvl == "") {
               // ── Price approaching (but not yet at) a key level — defer entry ──────────
               g_ZonePending          = true;
               g_ZonePendingLevel     = approachLvl;
               g_ZonePendingDir       = tradeDir;
               g_ZonePendingStartTime = TimeCurrent();
               Print("ZONE PENDING SET: ", zone, " zone, score=", ctxScore, "/15",
                     " — approaching ", approachLvl, " within ",
                     DoubleToString(ZonePendingPips, 1),
                     " pips; waiting for breakout + momentum before entry");
               return;

            } else {
               // ── No Fib barrier ahead, or price already at/past level — CAUTION entry ──
               string ctx = "score=" + IntegerToString(ctxScore) + "/15"
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
// === VOLUME LOW HARD BLOCK (v6.29) ===
   // LOW volume (ratio <= 0.5) = ranging/dwindling/tap-in zones — unreliable for trending entries.
   // Block all new entries when volume is dead to avoid getting chopped in a directionless market.
   if(UseVolumeAnalysis && g_VolumeState == "LOW") {
      string _br = (tradeDir == 1 ? "BUY" : "SELL") + " blocked: LOW volume (ratio="
                   + DoubleToString(g_VolRatio, 2) + ") — ranging/dwindling market, no entries";
      if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
      return;
   }

   // === SESSION OBSERVATION DELAY + FAKE-OUT REBOUND GATE (v6.32) ===
   // The first N M15 bars of each session open are observe-only — map the tone before entering.
   // Asian: 00:00–end  London: 08:00–end  NY: 13:00–end (NY starts mid-London, tracked independently).
   // After the observe window: if price moved AGAINST macro structure during those bars, the move
   // is treated as a potential fake-out.  Block trades in the fake-out direction until price rebounces.
   {
      MqlDateTime _sOdt; TimeToStruct(TimeCurrent(), _sOdt);
      bool _inAsianNow  = (_sOdt.hour >= AsianStartHour   && _sOdt.hour < AsianEndHour);
      bool _inLondonNow = (_sOdt.hour >= LondonStartHour  && _sOdt.hour < LondonEndHour);
      bool _inNYNow     = (_sOdt.hour >= NewYorkStartHour && _sOdt.hour < NewYorkEndHour);
      // Asian observe window
      if(_inAsianNow && AsianObserveBars > 0 && g_AsianBarCount <= AsianObserveBars) {
         string _br = (tradeDir == 1 ? "BUY" : "SELL") + " blocked: Asian observe (bar "
                      + IntegerToString(g_AsianBarCount) + "/" + IntegerToString(AsianObserveBars)
                      + ") — watching market before entering";
         if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
         return;
      }
      // London observe window
      if(_inLondonNow && LondonObserveBars > 0 && g_LondonBarCount <= LondonObserveBars) {
         string _br = (tradeDir == 1 ? "BUY" : "SELL") + " blocked: London observe (bar "
                      + IntegerToString(g_LondonBarCount) + "/" + IntegerToString(LondonObserveBars)
                      + ") — watching market before entering";
         if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
         return;
      }
      // NY observe window, independent of London overlap (starts at 13:00)
      if(_inNYNow && NYObserveBars > 0 && g_NYBarCount <= NYObserveBars) {
         string _br = (tradeDir == 1 ? "BUY" : "SELL") + " blocked: NY observe (bar "
                      + IntegerToString(g_NYBarCount) + "/" + IntegerToString(NYObserveBars)
                      + ") — watching market before entering";
         if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
         return;
      }
   }
   // Fake-out rebound gate: block trades in the trap direction; allow the rebound direction.
   // g_FakeoutConfidence=HIGH means prevSess + macro both agree the observe move was a trap.
   if(g_SessionFakeoutWatch && g_FakeoutDir != 0) {
      if(tradeDir == g_FakeoutDir) {
         string _br = (tradeDir == 1 ? "BUY" : "SELL") + " blocked: SessOpen "
                      + g_FakeoutConfidence + " TRAP — " + g_InterSessContext + " — await rebound";
         if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
         return;
      }
      // Trade direction opposes the trap (= the rebound we were waiting for) — allow and clear
      Print("[FAKEOUT REBOUND ENTRY] ", (tradeDir == 1 ? "BUY" : "SELL"),
            " ↑↓ confirmed rebound from ", g_FakeoutConfidence, " trap | ", g_InterSessContext);
      g_SessionFakeoutWatch = false;
      g_FakeoutDir          = 0;
      g_FakeoutExpiry       = 0;
      g_FakeoutConfidence   = "";
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

   // === H1 CHoCH DIRECTIONAL BLOCK ===
   // CHoCH signals the END of the previous trend direction. A trade in the pre-CHoCH
   // direction (against the reversal) must be blocked — CHoCH is active evidence that
   // the structure has changed, regardless of whether a BOS is also active.
   //
   //  CHoCHDir = -1 (bearish reversal) → block BUY  (pre-CHoCH direction was up)
   //  CHoCHDir = +1 (bullish reversal) → block SELL (pre-CHoCH direction was down)
   //
   // Exemptions:
   //  • isMeanRev: explicit counter-trend bounce at range extreme — own logic
   //  • MacroCHoCH in the trade direction: higher-TF reversal overrides H1 CHoCH
   //  • isMacroTrend: MacroBOS structural ride already gated separately above
   if(UseSwingStructure && g_CHoCHActive && g_CHoCHDir != 0 && !isMeanRev && !isMacroTrend) {
      bool tradeAgainstCHoCH = (tradeDir == -g_CHoCHDir);
      if(tradeAgainstCHoCH) {
         bool _macroExempt = (g_MacroCHoCH && g_MacroCHoCHDir == tradeDir);
         if(!_macroExempt) {
            string _br = "TRADE BLOCKED: H1 CHoCH=" + (g_CHoCHDir > 0 ? "Bull" : "Bear") +
                         " — refusing " + (tradeDir == 1 ? "BUY" : "SELL") +
                         " in pre-CHoCH direction (reversal underway)";
            if(_br != g_LastBlockReason) {
               Print(_br, " | CHoCHTime:", TimeToString(g_CHoCHTime, TIME_MINUTES),
                     " StructNow:", g_StructureLabel);
               g_LastBlockReason = _br;
            }
            return;
         }
         Print("[CHoCH-MACRO EXEMPT] H1 CHoCH(dir=", g_CHoCHDir, ") would block ",
               (tradeDir==1?"BUY":"SELL"), " but MacroCHoCH(dir=", g_MacroCHoCHDir, ") overrides");
      }
   }

   // === MA FAKE-JUMP GUARD (v6.35) ===
   // Price has crossed MA200 but MA50 has not followed — common false BOS.
   // The move typically reverses back towards MA50 before any genuine continuation.
   // Block trades that would chase the fake jump; allow trades in the reversion direction.
   if(UseMAFilter && MA200FakeJumpBlock && g_MA200 > 0 && g_MA50 > 0) {
      // FakeJumpUp: price above MA200, MA50 still below → expect reversal DOWN to MA50
      if(g_MA200FakeJumpUp && tradeDir == 1) {
         // v6.38: CHoCH exemption only applies when MA50 has crossed MA200 (softer lag case).
         // When BOTH MA50 and MA20 are still below MA200, the CHoCH was likely triggered by
         // the same false price spike — it is not a genuine structural reversal. Block hard.
         bool _bothBehind  = (g_MA20 > 0 && g_MA20 < g_MA200);  // MA50<MA200 already guaranteed by FakeJumpUp
         bool _chochExempt = !_bothBehind &&
                             ((g_CHoCHActive && g_CHoCHDir == 1) || (g_MacroCHoCH && g_MacroCHoCHDir == 1));
         if(!_chochExempt) {
            string _br = "BUY blocked: MA200 fake-jump — price above MA200 but MA50="
                         + DoubleToString(g_MA50,5)
                         + (_bothBehind ? " AND MA20=" + DoubleToString(g_MA20,5) + " both below" : " still below")
                         + " MA200=" + DoubleToString(g_MA200,5) + " | " + g_MAStatusLabel;
            if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
            return;
         }
      }
      // FakeJumpDn: price below MA200, MA50 still above → expect reversal UP to MA50
      if(g_MA200FakeJumpDn && tradeDir == -1) {
         bool _bothBehind  = (g_MA20 > 0 && g_MA20 > g_MA200);  // MA50>MA200 already guaranteed by FakeJumpDn
         bool _chochExempt = !_bothBehind &&
                             ((g_CHoCHActive && g_CHoCHDir == -1) || (g_MacroCHoCH && g_MacroCHoCHDir == -1));
         if(!_chochExempt) {
            string _br = "SELL blocked: MA200 fake-jump — price below MA200 but MA50="
                         + DoubleToString(g_MA50,5)
                         + (_bothBehind ? " AND MA20=" + DoubleToString(g_MA20,5) + " both above" : " still above")
                         + " MA200=" + DoubleToString(g_MA200,5) + " | " + g_MAStatusLabel;
            if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
            return;
         }
      }
   }

   // === MA200 MACRO GATE — PENDING ORDER or HARD BLOCK (v6.34/v6.35) ===
   // When signals are valid but price has not yet crossed MA200:
   //   If MA200MacroHardBlock = true AND MA200PendingPips > 0 AND no pending already open:
   //     → Place a BuyStop / SellStop at MA200 ± buffer so the trade fires only on a real cross.
   //   If pending already exists in the same direction: let it stand (managed by ManageMA200Pending).
   //   CHoCH in the trade direction always exempts the gate entirely (reversal confirmed — enter now).
   if(UseMAFilter && MA200MacroHardBlock && g_MA200 > 0) {
      bool ma200BlockBuy  = (tradeDir ==  1 && !g_AboveMA200 && !g_MA200CrossUp);
      bool ma200BlockSell = (tradeDir == -1 &&  g_AboveMA200 && !g_MA200CrossDn);
      if(ma200BlockBuy || ma200BlockSell) {
         bool _chochExempt = (g_CHoCHActive && g_CHoCHDir == tradeDir) ||
                             (g_MacroCHoCH  && g_MacroCHoCHDir == tradeDir);
         if(_chochExempt) {
            Print("[MA200 CHoCH EXEMPT] trade proceeds despite MA200 block | ", g_MAStatusLabel);
         } else if(MA200PendingPips > 0 && !g_TradeOpen
                   && (g_PendingMA200Ticket == 0 || g_PendingMA200Dir != tradeDir)) {
            // --- Place pending order at MA200 ± buffer ---
            double pipSize  = _Point * ((int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) % 2 == 1 ? 10 : 1);
            double bufDist  = MA200PendingPips * pipSize;
            double pendEntry = (tradeDir == 1) ? NormalizeDouble(g_MA200 + bufDist, _Digits)
                                               : NormalizeDouble(g_MA200 - bufDist, _Digits);
            // SL / TP in price distance — reuse USDtoPoints with current lot
            double _slUSD   = g_DynamicSL_USD * (lot / 0.01);
            double _tpUSD   = g_DynamicTP_USD * (lot / 0.01);
            double _slDist  = USDtoPoints(_slUSD, lot);
            double _tpDist  = USDtoPoints(_tpUSD, lot);
            double _minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
            if(_slDist < _minStop + _Point * 5) _slDist = _minStop + _Point * 5;
            if(_tpDist < _minStop + _Point * 5) _tpDist = _minStop + _Point * 5;
            double pendSL  = (tradeDir == 1) ? NormalizeDouble(pendEntry - _slDist, _Digits)
                                             : NormalizeDouble(pendEntry + _slDist, _Digits);
            double pendTP  = (tradeDir == 1) ? NormalizeDouble(pendEntry + _tpDist, _Digits)
                                             : NormalizeDouble(pendEntry - _tpDist, _Digits);
            string pendTag = (tradeDir == 1 ? "PEND_BS_MA200" : "PEND_SS_MA200")
                             + "_SL" + DoubleToString(g_DynamicSL_USD,2)
                             + "_TP" + DoubleToString(g_DynamicTP_USD,2);
            // Cancel any existing opposite-direction pending first
            if(g_PendingMA200Ticket != 0) {
               trade.OrderDelete(g_PendingMA200Ticket);
               g_PendingMA200Ticket = 0; g_PendingMA200Dir = 0; g_PendingMA200Bar = 0;
            }
            bool _pOK = (tradeDir == 1)
                        ? trade.BuyStop (lot, pendEntry, _Symbol, pendSL, pendTP, ORDER_TIME_GTC, 0, pendTag)
                        : trade.SellStop(lot, pendEntry, _Symbol, pendSL, pendTP, ORDER_TIME_GTC, 0, pendTag);
            if(_pOK) {
               g_PendingMA200Ticket = (int)trade.ResultOrder();
               g_PendingMA200Dir    = tradeDir;
               g_PendingMA200Bar    = iTime(_Symbol, PERIOD_M15, 0);
               g_PendingMA200Entry  = pendEntry;
               g_LastBlockReason    = "";
               Print("[MA200 PENDING] ", (tradeDir==1?"BuyStop":"SellStop"),
                     " @", DoubleToString(pendEntry,5),
                     " SL=", DoubleToString(pendSL,5), " TP=", DoubleToString(pendTP,5),
                     " (MA200=", DoubleToString(g_MA200,5), " +buf=", DoubleToString(MA200PendingPips,1), "pip)"
                     " | ", g_MAStatusLabel);
            } else {
               Print("[MA200 PENDING] Failed to place order: ", trade.ResultComment());
            }
            return;  // do not continue to market order placement
         } else {
            // Pending already exists in this direction, or PendingPips=0 (hard block mode)
            string _br = (tradeDir==1?"BUY":"SELL") + " blocked: MA200="
                         + DoubleToString(g_MA200,5) + " price "
                         + (g_AboveMA200 ? "above" : "below")
                         + " MA200 macro block"
                         + (g_PendingMA200Ticket != 0 ? " (pending #" + IntegerToString(g_PendingMA200Ticket) + " active)" : "")
                         + " | " + g_MAStatusLabel;
            if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
            return;
         }
      }
   }

   // === MA50/20 TOUCH GATE (v6.34 — advisory only) ===
   if(UseMAFilter && MA5020EntryRequired && g_MA50 > 0) {
      bool ma50OK = (tradeDir ==  1) ? (g_AboveMA50 || g_MA50Touch || g_MA50CrossUp)
                                     : (!g_AboveMA50 || g_MA50Touch || g_MA50CrossDn);
      if(!ma50OK) {
         string _br = (tradeDir==1?"BUY":"SELL") + " [MA50 CAUTION] not yet touched/crossed ("
                      + g_MAStatusLabel + ") — proceeding (advisory only)";
         if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
      }
      if(g_MA20Touch)
         Print("[MA20 BONUS] touching MA20 — extra entry quality | ", g_MAStatusLabel);
   }

   // === DAILY EXTENSION CAP (v6.34) ===
   // Standard rule: block when price has moved > DailyExtCapPct of D1 ATR from today's open.
   // Key-level override: if price recently BROKE a key S/R or Fib level in the trade direction
   // AND a further key level exists ahead (room to run), the cap is lifted with a caution note.
   // Rationale: price breaking R1 with room to R2 is continuation, not chasing.
   if(UseDailyExtCap && DailyExtCapPct > 0) {
      bool extBlockSell = (tradeDir == -1 && g_DailyExtDownPct > DailyExtCapPct);
      bool extBlockBuy  = (tradeDir ==  1 && g_DailyExtUpPct   > DailyExtCapPct);
      if(extBlockSell || extBlockBuy) {
         double _extPct = extBlockSell ? g_DailyExtDownPct : g_DailyExtUpPct;
         // Check if a key level was broken recently in the trade direction
         int    _brkBars   = CheckLevelBreakBars(tradeDir);
         bool   _lvlBroken = (_brkBars <= MaxConsecCandles * 2 && g_LevelBreakLabel != "");
         // Check whether a further key level exists ahead (room between current price and next level)
         double _nextLvl   = FindNextTargetLevel(price, tradeDir);
         double _roomPips  = (_nextLvl > 0) ? MathAbs(_nextLvl - price) / _Point / 10.0 : 0;
         bool   _roomAhead = (_roomPips >= 10.0);  // at least 10 pips to next level
         if(_lvlBroken && _roomAhead) {
            string _brOver = (tradeDir==1?"BUY":"SELL") + " DailyExt "
                             + DoubleToString(_extPct,1) + "% > cap="
                             + DoubleToString(DailyExtCapPct,1) + "% — OVERRIDDEN: level "
                             + g_LevelBreakLabel + " broken " + IntegerToString(_brkBars) + "b ago"
                             + ", room to " + DoubleToString(_nextLvl,5)
                             + " (" + DoubleToString(_roomPips,1) + " pips) — proceeding cautiously";
            if(_brOver != g_LastBlockReason) { Print(_brOver); g_LastBlockReason = _brOver; }
            // fall through — trade is allowed
         } else {
            string _br = (tradeDir==1?"BUY":"SELL") + " blocked: DailyExt "
                         + DoubleToString(_extPct,1) + "% of D1ATR (cap="
                         + DoubleToString(DailyExtCapPct,1) + "%) "
                         + (!_lvlBroken ? "— no key level broken in trade dir" : "— no room to next level (" + DoubleToString(_roomPips,1) + "pip)");
            if(_br != g_LastBlockReason) { Print(_br); g_LastBlockReason = _br; }
            return;
         }
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
   // v6.38: Use the confidence pre-cached at signal arm time as the stable baseline.
   // Three factors can shift meaningfully tick-to-tick:
   //   Room:    price may have moved closer to range boundary since arm
   //   KeyHour: we may have crossed into a key-hour window since arm
   //   BollRm:  live bid vs Bollinger band can flip each bar
   // Everything else (structure, volume, OB, FVG, MTF, session, bias, ATR) is
   // already baked into g_ConfidenceStatic and does not change until next bar.
   bool isMidContext = (zone == "MID_ZONE" || isSideways);
   double confidence;
   datetime armedBar = iTime(_Symbol, PERIOD_M15, 0);
   if(g_ConfidenceStatic > 0 && isTrendSignal) {
      // Start from the static baseline — avoids full 19-factor recompute on every tick
      confidence = g_ConfidenceStatic;
      // Delta 1: range room (changes as price moves)
      double roomDelta = 0;
      if(g_RangeHigh > 0 && g_RangeLow > 0) {
         double _bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double _room = (tradeDir == 1) ? (g_RangeHigh - _bid) : (_bid - g_RangeLow);
         double _rPips = _room / _Point / 10.0;
         double _rNow  = (_rPips >= 40.0) ? 10.0 : (_rPips >= 25.0) ? 7.0 : (_rPips >= 15.0) ? 4.0 : 1.0;
         // Compare to what was already baked in at arm time (factor 6 used same scale)
         double _rArm  = 0;  // static already includes the arm-time room score
         // We only apply net change if room shrank significantly (price ran away from us)
         if(_rPips < 15.0 && g_ConfidenceArmedBar != armedBar) roomDelta = _rNow - 7.0; // assume was >=25
      }
      // Delta 2: key-hour proximity (we may have entered a key-hour window since arm)
      double keyDelta = 0;
      if(KeyHourBonusEnabled) {
         MqlDateTime _kdt; TimeToStruct(TimeCurrent(), _kdt);
         int _min = _kdt.min;
         int _kHrs[] = {0, 3, 4, 7, 8, 12, 13, 17, 21};
         int _kDist = 99;
         for(int _ki = 0; _ki < 9; _ki++) {
            if(_kdt.hour == _kHrs[_ki]) _kDist = MathMin(_kDist, _min);
            if((_kdt.hour+1)%24 == _kHrs[_ki]) _kDist = MathMin(_kDist, 60-_min);
         }
         double _kBonus = (_kDist <= 15) ? KeyHourBonusPts : (_kDist <= 30) ? KeyHourBonusPts*0.5 : 0;
         // Static had key-hour bonus at arm time; we only add the difference if it grew
         keyDelta = 0;  // conservative: do not double-count; static already has it
      }
      confidence = MathMax(0, MathMin(100, confidence + roomDelta + keyDelta));
      g_Confidence = confidence;  // update global so dashboard stays accurate
   } else {
      // MeanRev / MacroTrend / no cached baseline — full compute
      confidence = CalcConfidence(tradeDir, zone, isMeanRev, isSideways, g_NearLevel);
   }

   // === CONFIDENCE GATE — reject low-probability setups ===
   // v7.00: ZAP zone confluence density lowers the effective threshold dynamically
   double effectiveMinConf = MinConfidence;
   if(UseZAP && UseZoneConfluence && g_ZoneConfluencePct >= 70.0)
      effectiveMinConf = MathMax(MinConfidence - 10.0, MinConfidence * 0.80);
   else if(UseZAP && g_ZAPActive && g_ZAPDir == tradeDir && g_ZAPScore >= ZAPMinScore)
      effectiveMinConf = MathMax(MinConfidence - 5.0, MinConfidence * 0.88);

   // v7.00: QUICK ENTRY — ZAP + Asian Bias perfectly aligned = drop gate to AsianZAPMinConf.
   // Asian bias signals are historically clean and follow through for 1-3 USD per 0.01 lot.
   // This ensures the bot does NOT miss well-confirmed Asian-session setups due to slow trackers.
   bool _quickCombo = QuickEntryEnabled && g_AsianBiasActive && g_AsianBiasDir == tradeDir
                      && g_ZAPActive && g_ZAPDir == tradeDir && g_ZAPScore >= ZAPMinScore;
   if(_quickCombo) {
      effectiveMinConf = MathMin(effectiveMinConf, AsianZAPMinConf);
      Print("[QUICK ENTRY] ZAP+AsianBias aligned — gate lowered to AsianZAPMinConf=",
            DoubleToString(AsianZAPMinConf,0), "% (conf=", DoubleToString(confidence,1), "%)");
   }

   // v7.00: 3-4 AM BONUS — signals in this window are continuation/flip patterns in Asian
   // session, typically giving a clean trend before London open. Add confidence bonus.
   if(AM34BonusEnabled && AM34BonusPts > 0) {
      MqlDateTime _amDt; TimeToStruct(TimeCurrent(), _amDt);
      if(_amDt.hour >= 3 && _amDt.hour < 4) {
         confidence += AM34BonusPts;
         confidence  = MathMin(confidence, 100.0);
         Print("[3-4AM BONUS] +", DoubleToString(AM34BonusPts,0),
               " conf pts (Asian momentum window) → new conf=", DoubleToString(confidence,1), "%");
      }
   }

   if(confidence < effectiveMinConf) {
      Print("ENTRY REJECTED: confidence ", DoubleToString(confidence, 1),
            "% < effective min ", DoubleToString(effectiveMinConf, 1), "%",
            (effectiveMinConf < MinConfidence ? " (ZAP/ZCP discount applied)" : ""));
      return;
   }

   // === NB BRAIN — entry audit log ===
   // NB posteriors are computed every bar and have already co-driven signal arming
   // in EvaluateHAPattern. Log current NB values at entry time for audit only.
   if(UseNBBrain && g_HaNB_Trained) {
      Print("[NB] Entry P(UP)=", DoubleToString(g_NBBuyProb,1),
            "% P(DOWN)=", DoubleToString(g_NBSellProb,1),
            "% P(NTRL)=", DoubleToString(g_NBPosteriorHold,1),
            "% | dir=", tradeDir, " pred=", g_NBPredDir);
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
      if(targetUSD > baseTpUSD && targetUSD <= MaxTP_USD) {
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
         boldTP = MathMin(boldTP, MaxTP_USD);     // cap at MaxTP_USD — achievable target
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
   if(isMeanRev && MRV_SLScale > 0 && MRV_TPScale > 0) {
      // v6.36: Mean reversion uses tighter SL/TP — short bounce within range
      double mrvSL = g_DynamicSL_USD * MRV_SLScale;
      double mrvTP = baseTpUSD * MRV_TPScale;
      mrvSL = MathMax(mrvSL, MinSL_USD);  // respect minimum SL
      mrvTP = MathMax(mrvTP, mrvSL * 1.0); // at least 1:1 R:R
      Print("[MRV SL/TP] SL: $", DoubleToString(g_DynamicSL_USD,2), " -> $", DoubleToString(mrvSL,2),
            " TP: $", DoubleToString(baseTpUSD,2), " -> $", DoubleToString(mrvTP,2));
      g_DynamicSL_USD = mrvSL;
      baseTpUSD = mrvTP;
      g_DynamicTP_USD = baseTpUSD;
   }
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
            " Score=", g_MacroTrendScore, "/15");
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
   // v6.36: spread filter — block when spread is too wide (news, illiquid)
   if(MaxSpreadPips > 0) {
      long   spreadPts  = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      double spreadPips = (double)spreadPts / 10.0;  // 5-digit broker: 1 pip = 10 points
      if(spreadPips > MaxSpreadPips) {
         string _brS = "SPREAD BLOCKED: " + DoubleToString(spreadPips,1) + " > " + DoubleToString(MaxSpreadPips,1) + " pips";
         if(_brS != g_LastBlockReason) { Print(_brS); g_LastBlockReason = _brS; }
         return;
      }
   }
   g_LastBlockReason = "";   // block cleared — trade is actually firing
   bool ok = false;
   if(tradeDir == 1) {
      double sl = UseSL ? NormalizeDouble(ask - slDist, _Digits) : 0;   // v7.00: UseSL=false → no broker SL
      double tp = NormalizeDouble(ask + tpDist, _Digits);
      Print("Attempting ", tag, " | Conf:", DoubleToString(confidence,1), "% Zone:", zone,
            " Lot:", lot, " Ask:", ask, " SL:", (UseSL ? DoubleToString(sl,_Digits) : "NONE (EOD)"),
            " TP:", tp, " SL$:", DoubleToString(g_DynamicSL_USD,2), " TP$:", DoubleToString(baseTpUSD,2));
      ok = trade.Buy(lot, _Symbol, ask, sl, tp, tag);
   } else {
      double sl = UseSL ? NormalizeDouble(bid + slDist, _Digits) : 0;   // v7.00: UseSL=false → no broker SL
      double tp = NormalizeDouble(bid - tpDist, _Digits);
      Print("Attempting ", tag, " | Conf:", DoubleToString(confidence,1), "% Zone:", zone,
            " Lot:", lot, " Bid:", bid, " SL:", (UseSL ? DoubleToString(sl,_Digits) : "NONE (EOD)"),
            " TP:", tp, " SL$:", DoubleToString(g_DynamicSL_USD,2), " TP$:", DoubleToString(baseTpUSD,2));
      ok = trade.Sell(lot, _Symbol, bid, sl, tp, tag);
   }

   if(ok) {
      SetScaledThresholds(lot);
      g_TradeOpen     = true;
      g_ZAPActive     = false;  // v7.00: trade placed — reset ZAP primer
      g_ZAPFakeout    = false;
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
      g_ConfidenceStatic   = 0; g_ConfidenceArmedBar = 0;  // v6.38: trade open — cache obsolete
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
      // v6.37: increment per-session slot
      if(OneTradePerSession) {
         MqlDateTime _odt; TimeToStruct(TimeCurrent(), _odt);
         bool _oAsian  = (_odt.hour >= AsianStartHour   && _odt.hour < AsianEndHour);
         bool _oLondon = (_odt.hour >= LondonStartHour  && _odt.hour < LondonEndHour);
         bool _oNY     = (_odt.hour >= NewYorkStartHour && _odt.hour < NewYorkEndHour);
         if(_oAsian)       { g_AsianTradeCount++;  Print("[SESSION] Asian slot used  (1/1)"); }
         else if(_oLondon) { g_LondonTradeCount++; Print("[SESSION] London slot used (1/1)"); }
         else if(_oNY)     { g_NYTradeCount++;     Print("[SESSION] NY slot used     (1/1)"); }
      }
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
   g_ConfidenceStatic   = 0; g_ConfidenceArmedBar = 0;  // v6.38: trade closed — reset cache
   g_EntryStructLabel = "";
   g_EntryMacroLabel  = "";
   g_EarlyLockEngaged = false;
   g_StructShiftCount = 0;
   g_LastMgmtAction   = "";
   g_ComebackLabel    = "";
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

   // === COMEBACK POTENTIAL ASSESSMENT (always updated when trade is open) ===
   // Evaluates how likely a losing trade is to recover, based on structure.
   // Also used by the smart-loss-exit system below.
   bool lse_structWith    = false;
   bool lse_structAgainst = false;
   bool lse_macroAligned  = (g_TradeDir == 1 && g_MacroStructLabel == "BULLISH") ||
                            (g_TradeDir == -1 && g_MacroStructLabel == "BEARISH");
   bool lse_macroCHoCH    = (g_MacroCHoCH && g_MacroCHoCHDir != 0 && g_MacroCHoCHDir != g_TradeDir);
   bool lse_h1CHoCHAgainst = (g_CHoCHActive && g_CHoCHDir != 0 && g_CHoCHDir != g_TradeDir);

   if(g_BOSActive) {
      if((g_TradeDir == 1 && g_StructureLabel == "BULLISH") ||
         (g_TradeDir == -1 && g_StructureLabel == "BEARISH"))
         lse_structWith = true;
      if((g_TradeDir == 1 && g_StructureLabel == "BEARISH") ||
         (g_TradeDir == -1 && g_StructureLabel == "BULLISH"))
         lse_structAgainst = true;
   }

   // M15 short-term momentum: are recent bars moving with or against the trade?
   double m15Close1 = iClose(_Symbol, PERIOD_M15, 1);
   double m15Close3 = iClose(_Symbol, PERIOD_M15, 3);
   int    m15Dir    = (m15Close1 > m15Close3) ? 1 : (m15Close1 < m15Close3) ? -1 : 0;
   bool   m15With   = (m15Dir == g_TradeDir);
   bool   m15Against = (m15Dir != 0 && m15Dir != g_TradeDir);

   // Score: +points for support, -points for opposition
   int comebackScore = 0;
   if(lse_structWith)       comebackScore += 3;   // H1 BOS with trade
   if(lse_macroAligned)     comebackScore += 2;   // H4 macro aligned
   if(m15With)              comebackScore += 1;   // M15 short-term momentum with trade
   if(lse_structAgainst)    comebackScore -= 3;   // H1 BOS against
   if(lse_h1CHoCHAgainst)   comebackScore -= 2;   // H1 CHoCH against
   if(lse_macroCHoCH)       comebackScore -= 3;   // H4 macro CHoCH against
   if(m15Against)           comebackScore -= 1;   // M15 momentum against
   if(g_StructShiftCount >= 2) comebackScore -= 1; // multiple shifts = unstable

   // Label for dashboard
   if(profit < 0) {
      if(comebackScore >= 3)       g_ComebackLabel = "HIGH";
      else if(comebackScore >= 0)  g_ComebackLabel = "MODERATE";
      else                         g_ComebackLabel = "LOW";
   } else {
      g_ComebackLabel = "";  // only show when in loss
   }

   // === SMART LOSS EXIT — structure-informed early loss cutting ===
   // When the trade is in loss AND structure has definitively shifted against,
   // close early instead of waiting for full SL. This is NOT panic — it requires
   // confirmed structural evidence (H1 CHoCH or BOS against + macro confirmation).
   // LossStructExit: 0=OFF, 1=modes 3/4/5 only, 2=all modes
   bool lseApplies = (LossStructExit == 2) ||
                     (LossStructExit == 1 && (mode == 3 || mode == 4 || mode == 5));

   if(lseApplies && profit < 0 && g_OpenBarCount >= 4) {
      // Require strong evidence: comeback score deep negative + multiple confirming signals
      // This is conservative — NOT panic-closing on tiny dips
      bool structConfirmedAgainst = lse_structAgainst || lse_h1CHoCHAgainst;
      bool multipleEvidence = (lse_structAgainst && lse_macroCHoCH) ||
                              (lse_h1CHoCHAgainst && lse_macroCHoCH) ||
                              (lse_h1CHoCHAgainst && m15Against && g_StructShiftCount >= 2);

      // Only cut if: struct confirmed against + macro confirms + trade has been losing for 6+ bars
      // AND loss has exceeded 30% of SL (not a tiny dip)
      double lossThreshold = -(g_ScaledSLUSD * 0.30);
      if(structConfirmedAgainst && multipleEvidence && profit < lossThreshold && g_OpenBarCount >= 6) {
         g_LastMgmtAction = "SMART_LOSS_EXIT";
         Print("[SMART_LOSS] Structure shifted against trade with multi-TF confirmation",
               " | profit=$", DoubleToString(profit, 2),
               " | comeback=", g_ComebackLabel,
               " | H1:", (lse_structAgainst ? "BOS_AGT" : ""), (lse_h1CHoCHAgainst ? "+CHoCH_AGT" : ""),
               " | Macro:", (lse_macroCHoCH ? "CHoCH_AGT" : lse_macroAligned ? "ALIGNED" : "NEUTRAL"),
               " | M15:", (m15Against ? "AGAINST" : m15With ? "WITH" : "FLAT"),
               " | Shifts:", g_StructShiftCount);
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
      // Entries travel $1-2+ per 0.01 lot. Give them room to mature.
      // Dwindling/trail only activates AFTER profit has reached $1.00 per 0.01 lot.
      // Structure exits remain but require meaningful profit first.
      //
      // Graduated protection with three tiers:
      //   Tier 1: Early protection at max(35% TP, $1.00/0.01lot) — patient floor
      //   Tier 2: Standard lock at LockPct of TP with structure-adjusted trail
      //   Tier 3: Extended run when profit > TP and structure supports it

      double minFloorUSD  = 1.00 * scale;                                       // $1.00 per 0.01 lot floor
      double earlyLockUSD = MathMax(g_DynamicTP_USD * 0.35 * scale, minFloorUSD); // Tier 1: at least $1.00
      double stdLockUSD   = g_ScaledLockUSD;                                      // Tier 2: standard LockPct
      double tpUSD        = g_ScaledTPUSD;                                        // full TP for reference

      // --- Structural assessment (reuse shared lse_ variables) ---
      bool structWith    = lse_structWith;
      bool structAgainst = lse_structAgainst;
      bool macroAligned  = lse_macroAligned;
      bool macroCHoCHAgainst = lse_macroCHoCH;

      // --- Tier 1: Early protection (only after $1.00+ floor) ---
      if(!g_EarlyLockEngaged && profit >= earlyLockUSD) {
         g_EarlyLockEngaged = true;
         g_LastMgmtAction = "ADAPT_EARLY@" + DoubleToString(profit,2);
         Print("[ADAPTIVE] TIER1 EARLY LOCK at $", DoubleToString(profit,2),
               " (floor=$", DoubleToString(earlyLockUSD,2), ")");
      }
      // --- Tier 2: Standard lock ---
      if(!g_ProfitLocked && profit >= stdLockUSD) {
         g_ProfitLocked = true;
         g_LastMgmtAction = "ADAPT_LOCK@" + DoubleToString(profit,2);
         Print("[ADAPTIVE] TIER2 STANDARD LOCK at $", DoubleToString(profit,2));
      }

      // --- Calculate adaptive trail width ---
      // Only meaningful after early lock is engaged (profit >= $1.00+ floor).
      // Before that, let the trade breathe — no trail at all.
      double adaptiveTrail;
      if(macroCHoCHAgainst)                    adaptiveTrail = g_DynamicTP_USD * 0.15 * scale;
      else if(structAgainst)                   adaptiveTrail = g_DynamicTP_USD * 0.18 * scale;
      else if(profit >= tpUSD && structWith)   adaptiveTrail = g_DynamicTP_USD * 0.50 * scale;
      else if(structWith && macroAligned)       adaptiveTrail = g_DynamicTP_USD * 0.45 * scale;
      else if(structWith)                      adaptiveTrail = g_DynamicTP_USD * 0.35 * scale;
      else                                     adaptiveTrail = g_DynamicTP_USD * 0.30 * scale;

      // --- Dwindling detection (only after peak >= $1.00 per 0.01 lot) ---
      // Entries travel $1-2+, so we only consider dwindling AFTER that range.
      bool dwindling = false;
      if(g_EarlyLockEngaged && g_PeakProfit >= minFloorUSD && profit > 0) {
         // Profit fell below 45% of peak for 14+ bars = stalled
         if(g_BarsSincePeak >= 14 && profit < g_PeakProfit * 0.45) {
            dwindling = true;
         }
         // Extended dwindling: 24+ bars and below 65% of peak
         if(g_BarsSincePeak >= 24 && profit < g_PeakProfit * 0.65) {
            dwindling = true;
         }
      }

      // --- Structure-accelerated exit (only after meaningful profit) ---
      // Only fires if we HAD $1.00+ profit — don't urgently exit a trade that never ran
      bool structUrgent = structAgainst && g_EarlyLockEngaged &&
                          g_PeakProfit >= minFloorUSD && profit < g_PeakProfit * 0.55;

      // --- Execute dwindling or structure-urgent exit ---
      if(dwindling || structUrgent) {
         string reason = dwindling ? "DWINDLING" : "STRUCT_URGENT";
         g_LastMgmtAction = reason;
         Print("[ADAPTIVE] ", reason, " EXIT: peak=$", DoubleToString(g_PeakProfit,2),
               " now=$", DoubleToString(profit,2),
               " bars_since_peak=", g_BarsSincePeak,
               " struct:", (structWith ? "WITH" : structAgainst ? "AGAINST" : "NEUTRAL"),
               " macro:", (macroAligned ? "ALIGNED" : macroCHoCHAgainst ? "CHoCH_AGAINST" : "---"));
         trade.PositionClose(posInfo.Ticket());
         ResetTradeGlobals(profit);
         return;
      }

      // --- Trailing close (ONLY after early lock — let trades grow to $1.00+ first) ---
      if(g_EarlyLockEngaged && profit < g_PeakProfit - adaptiveTrail && profit > 0) {
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

      // --- Time decay: very long holds with modest profit ---
      // After 40 bars (10 hours), if profit is still tiny → accept stall
      if(g_OpenBarCount >= 40 && profit > 0 && !g_EarlyLockEngaged) {
         double minAcceptable = 0.50 * scale;   // at least $0.50 per 0.01 lot after 10h
         if(profit < minAcceptable) {
            g_LastMgmtAction = "TIME_DECAY_STALL";
            Print("[ADAPTIVE] TIME DECAY: ", g_OpenBarCount, " bars, profit=$",
                  DoubleToString(profit,2), " below min acceptable $",
                  DoubleToString(minAcceptable,2), " --- closing stalled trade");
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

      // --- Structural assessment (reuse shared lse_ variables) ---
      bool crStructWith    = lse_structWith;
      bool crStructAgainst = lse_structAgainst;
      bool crMacroAligned  = lse_macroAligned;
      bool crMacroCHoCH    = lse_macroCHoCH;

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
         // Floor: $1.00 per 0.01 lot — entries travel $1-2+, don't cut early.
         double crMinFloor  = 1.00 * scale;
         double crMomLock   = MathMax(g_DynamicTP_USD * 0.50 * scale, crMinFloor);
         double crBaseTrail = g_DynamicTP_USD * 0.30 * scale;
         double crWideTrail = g_DynamicTP_USD * 0.45 * scale;
         double crTightTrail= g_DynamicTP_USD * 0.18 * scale;

         double crTrail = crBaseTrail;
         if(crStructWith && crMacroAligned)        crTrail = crWideTrail;
         else if(crStructAgainst || crMacroCHoCH)  crTrail = crTightTrail;

         // Lock (at least $1.00 per 0.01 lot)
         if(!g_ProfitLocked && profit >= crMomLock) {
            g_ProfitLocked = true;
            g_LastMgmtAction = "CR_MOM_LOCK@" + DoubleToString(profit, 2);
            Print("[CHRONO] MOMENTUM LOCK at $", DoubleToString(profit, 2), " @H", ch);
         }

         // Trail (only after lock — which is $1.00+ floor)
         if(g_ProfitLocked && profit < g_PeakProfit - crTrail && profit > 0) {
            g_LastMgmtAction = "CR_MOM_TRAIL";
            Print("[CHRONO] MOMENTUM TRAIL: peak=$", DoubleToString(g_PeakProfit, 2),
                  " now=$", DoubleToString(profit, 2), " trail=$", DoubleToString(crTrail, 2));
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }

         // Dwindling: only after peak >= $1.00 floor, 12+ bars stalled
         if(g_ProfitLocked && g_PeakProfit >= crMinFloor && g_BarsSincePeak >= 12 && profit < g_PeakProfit * 0.50 && profit > 0) {
            g_LastMgmtAction = "CR_MOM_DWINDLE";
            Print("[CHRONO] MOMENTUM DWINDLE: peak=$", DoubleToString(g_PeakProfit, 2),
                  " now=$", DoubleToString(profit, 2), " stalled ", g_BarsSincePeak, " bars in overlap");
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }

      // ===================================================
      //  RIDE sub-mode: ADAPTIVE (mid/late Asian, London, NY)
      // ===================================================
      } else {
         // Full adaptive logic: graduated tiers, dwindling, structure exits.
         // Same $1.00/0.01 lot floor as standalone ADAPTIVE mode.
         double crMinFloor  = 1.00 * scale;
         double crEarlyLock = MathMax(g_DynamicTP_USD * 0.35 * scale, crMinFloor);
         double crStdLock   = g_ScaledLockUSD;
         double crTP        = g_ScaledTPUSD;

         // Tier 1: early protect (at least $1.00 per 0.01 lot)
         if(!g_EarlyLockEngaged && profit >= crEarlyLock) {
            g_EarlyLockEngaged = true;
            g_LastMgmtAction = "CR_ADAPT_EARLY@" + DoubleToString(profit, 2);
            Print("[CHRONO] ADAPTIVE EARLY LOCK at $", DoubleToString(profit, 2),
                  " (floor=$", DoubleToString(crEarlyLock, 2), ") @H", ch);
         }
         // Tier 2: standard lock
         if(!g_ProfitLocked && profit >= crStdLock) {
            g_ProfitLocked = true;
            g_LastMgmtAction = "CR_ADAPT_LOCK@" + DoubleToString(profit, 2);
            Print("[CHRONO] ADAPTIVE LOCK at $", DoubleToString(profit, 2));
         }

         // Adaptive trail (structure-informed, wider buffers to avoid early cuts)
         double crAdaptTrail;
         if(crMacroCHoCH)                            crAdaptTrail = g_DynamicTP_USD * 0.15 * scale;
         else if(crStructAgainst)                    crAdaptTrail = g_DynamicTP_USD * 0.18 * scale;
         else if(profit >= crTP && crStructWith)     crAdaptTrail = g_DynamicTP_USD * 0.50 * scale;
         else if(crStructWith && crMacroAligned)     crAdaptTrail = g_DynamicTP_USD * 0.45 * scale;
         else if(crStructWith)                       crAdaptTrail = g_DynamicTP_USD * 0.35 * scale;
         else                                        crAdaptTrail = g_DynamicTP_USD * 0.30 * scale;

         // Dwindling detection (only after peak >= $1.00 per 0.01 lot)
         bool crDwindling = false;
         if(g_EarlyLockEngaged && g_PeakProfit >= crMinFloor && profit > 0) {
            if(g_BarsSincePeak >= 14 && profit < g_PeakProfit * 0.45)
               crDwindling = true;
            if(g_BarsSincePeak >= 24 && profit < g_PeakProfit * 0.65)
               crDwindling = true;
         }

         // Structure-urgent exit (only after meaningful profit)
         bool crStructUrgent = crStructAgainst && g_EarlyLockEngaged &&
                               g_PeakProfit >= crMinFloor && profit < g_PeakProfit * 0.55;

         if(crDwindling || crStructUrgent) {
            string rsn = crDwindling ? "CR_DWINDLE" : "CR_STRUCT_URGENT";
            g_LastMgmtAction = rsn;
            Print("[CHRONO] ", rsn, ": peak=$", DoubleToString(g_PeakProfit, 2),
                  " now=$", DoubleToString(profit, 2), " @H", ch);
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }

         // Trailing close (only after early lock — $1.00+ floor)
         if(g_EarlyLockEngaged && profit < g_PeakProfit - crAdaptTrail && profit > 0) {
            g_LastMgmtAction = "CR_ADAPT_TRAIL";
            Print("[CHRONO] ADAPTIVE TRAIL: peak=$", DoubleToString(g_PeakProfit, 2),
                  " now=$", DoubleToString(profit, 2), " trail=$", DoubleToString(crAdaptTrail, 2));
            trade.PositionClose(posInfo.Ticket());
            ResetTradeGlobals(profit);
            return;
         }

         // Time decay: 40+ bars without early lock → stalled
         if(g_OpenBarCount >= 40 && profit > 0 && !g_EarlyLockEngaged) {
            double minAccept = 0.50 * scale;
            if(profit < minAccept) {
               g_LastMgmtAction = "CR_TIME_DECAY";
               Print("[CHRONO] TIME DECAY after ", g_OpenBarCount, " bars, profit=$",
                     DoubleToString(profit, 2), " below $", DoubleToString(minAccept, 2), " @H", ch);
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
//| ECONOMIC CALENDAR — look up currency from country_id            |
//+------------------------------------------------------------------+
string CalGetCurrency(ulong country_id)
{
   for(int i = 0; i < g_CalCountryCount; i++)
      if(g_CalCountries[i].id == country_id) return g_CalCountries[i].currency;
   return "";
}

//+------------------------------------------------------------------+
//| Fetch & cache upcoming EUR/USD economic events (called via timer)|
//+------------------------------------------------------------------+
void FetchCalendarEvents()
{
   if(!ShowCalendar) return;
   g_CalEventCount = 0;
   g_NewsNoTrade   = false;

   // Lazy-load country metadata once
   if(!g_CalCountriesLoaded) {
      g_CalCountryCount    = CalendarCountries(g_CalCountries);
      g_CalCountriesLoaded = (g_CalCountryCount > 0);
   }
   if(g_CalCountryCount <= 0) return;

   datetime now = TimeCurrent();
   datetime toT = now + (datetime)(CalendarLookAheadH * 3600);

   MqlCalendarValue vals[];
   int total = CalendarValueHistory(vals, now, toT);
   if(total <= 0) return;

   // Collect qualifying events into temp arrays (max 32 candidates)
   datetime tmpTime[32]; string tmpCur[32], tmpName[32]; int tmpImp[32]; ulong tmpEid[32];
   int found = 0;

   for(int i = 0; i < total && found < 32; i++) {
      if(vals[i].time < now) continue;
      MqlCalendarEvent ev;
      if(!CalendarEventById(vals[i].event_id, ev)) continue;
      if(ev.importance == CALENDAR_IMPORTANCE_NONE) continue;
      string cur = CalGetCurrency(ev.country_id);
      if(cur != "EUR" && cur != "USD") continue;
      int imp = (ev.importance == CALENDAR_IMPORTANCE_HIGH)     ? 3 :
                (ev.importance == CALENDAR_IMPORTANCE_MODERATE) ? 2 : 1;
      if(imp < CalendarMinImpact) continue;
      // De-duplicate by event_id
      bool dup = false;
      for(int d = 0; d < found; d++) { if(tmpEid[d] == ev.id) { dup = true; break; } }
      if(dup) continue;
      tmpTime[found] = vals[i].time; tmpCur[found] = cur;
      tmpName[found] = ev.name;      tmpImp[found] = imp; tmpEid[found] = ev.id;
      found++;
   }

   // Insertion sort — soonest first
   for(int i = 1; i < found; i++) {
      datetime kt = tmpTime[i]; string kc = tmpCur[i], kn = tmpName[i];
      int ki = tmpImp[i]; ulong ke = tmpEid[i]; int j = i - 1;
      while(j >= 0 && tmpTime[j] > kt) {
         tmpTime[j+1] = tmpTime[j]; tmpCur[j+1]  = tmpCur[j];
         tmpName[j+1] = tmpName[j]; tmpImp[j+1]  = tmpImp[j]; tmpEid[j+1] = tmpEid[j]; j--;
      }
      tmpTime[j+1] = kt; tmpCur[j+1] = kc; tmpName[j+1] = kn; tmpImp[j+1] = ki; tmpEid[j+1] = ke;
   }

   int cap = MathMin(found, MathMin(CalendarMaxEvents, 4));
   g_CalEventCount = cap;
   for(int i = 0; i < cap; i++) {
      g_CalEvents[i].time       = tmpTime[i];
      g_CalEvents[i].currency   = tmpCur[i];
      g_CalEvents[i].name       = tmpName[i];
      g_CalEvents[i].importance = tmpImp[i];
   }

   // No-trade flag: any HIGH impact event within the guard window
   if(CalendarNoTradeMins > 0) {
      for(int i = 0; i < g_CalEventCount; i++) {
         if(g_CalEvents[i].importance == 3) {
            int sAway = (int)(g_CalEvents[i].time - now);
            if(sAway >= 0 && sAway <= CalendarNoTradeMins * 60) { g_NewsNoTrade = true; break; }
         }
      }
   }

   // --- Recent released events (look-back window) ---
   g_CalPastCount = 0;
   g_CalNewsScore = 0;
   if(CalendarLookBackH > 0) {
      datetime fromT = now - (datetime)(CalendarLookBackH * 3600);
      MqlCalendarValue pvals[];
      int ptotal = CalendarValueHistory(pvals, fromT, now);

      datetime pTm[32]; string pCr[32], pNm[32];
      int pIp[32], pIa[32]; double pAc[32], pFc[32]; ulong pEd[32];
      int pfound = 0;

      for(int i = 0; i < ptotal && pfound < 32; i++) {
         if(pvals[i].actual_value == LONG_MIN) continue; // not yet released
         MqlCalendarEvent pev;
         if(!CalendarEventById(pvals[i].event_id, pev)) continue;
         if(pev.importance == CALENDAR_IMPORTANCE_NONE)   continue;
         string pcur = CalGetCurrency(pev.country_id);
         if(pcur != "EUR" && pcur != "USD") continue;
         int pimp = (pev.importance == CALENDAR_IMPORTANCE_HIGH)     ? 3 :
                    (pev.importance == CALENDAR_IMPORTANCE_MODERATE) ? 2 : 1;
         if(pimp < CalendarMinImpact) continue;
         // De-duplicate by event_id
         bool pdup = false;
         for(int d = 0; d < pfound; d++) { if(pEd[d] == pev.id) { pdup = true; break; } }
         if(pdup) continue;
         // Determine EUR/USD directional impact from release
         int eImpact = 0;
         if(pcur == "EUR") {
            if(pvals[i].impact_type == CALENDAR_IMPACT_POSITIVE)     eImpact = +1;
            else if(pvals[i].impact_type == CALENDAR_IMPACT_NEGATIVE) eImpact = -1;
         } else { // USD: USD strength inverts EURUSD direction
            if(pvals[i].impact_type == CALENDAR_IMPACT_POSITIVE)     eImpact = -1;
            else if(pvals[i].impact_type == CALENDAR_IMPACT_NEGATIVE) eImpact = +1;
         }
         double pAcV = (pvals[i].actual_value   == LONG_MIN) ? DBL_MAX : (double)pvals[i].actual_value   / 1000000.0;
         double pFcV = (pvals[i].forecast_value == LONG_MIN) ? DBL_MAX : (double)pvals[i].forecast_value / 1000000.0;
         pTm[pfound] = pvals[i].time; pCr[pfound] = pcur; pNm[pfound] = pev.name;
         pIp[pfound] = pimp; pIa[pfound] = eImpact;
         pAc[pfound] = pAcV; pFc[pfound] = pFcV; pEd[pfound] = pev.id;
         pfound++;
      }
      // Sort descending by time (most recent first)
      for(int i = 1; i < pfound; i++) {
         datetime kt = pTm[i]; string kc = pCr[i], kn = pNm[i];
         int ki = pIp[i], kia = pIa[i]; double ka = pAc[i], kf = pFc[i]; ulong ke = pEd[i]; int j = i-1;
         while(j >= 0 && pTm[j] < kt) {
            pTm[j+1]=pTm[j]; pCr[j+1]=pCr[j]; pNm[j+1]=pNm[j];
            pIp[j+1]=pIp[j]; pIa[j+1]=pIa[j]; pAc[j+1]=pAc[j]; pFc[j+1]=pFc[j]; pEd[j+1]=pEd[j]; j--;
         }
         pTm[j+1]=kt; pCr[j+1]=kc; pNm[j+1]=kn;
         pIp[j+1]=ki; pIa[j+1]=kia; pAc[j+1]=ka; pFc[j+1]=kf; pEd[j+1]=ke;
      }
      int pcap = MathMin(pfound, 4);
      g_CalPastCount = pcap;
      for(int i = 0; i < pcap; i++) {
         g_CalPastEvents[i].time       = pTm[i];
         g_CalPastEvents[i].currency   = pCr[i];
         g_CalPastEvents[i].name       = pNm[i];
         g_CalPastEvents[i].importance = pIp[i];
         g_CalPastEvents[i].impact     = pIa[i];
         g_CalPastEvents[i].actual     = pAc[i];
         g_CalPastEvents[i].forecast   = pFc[i];
         // Contribute to net score weighted by importance
         int w = (pIp[i] == 3) ? 2 : (pIp[i] == 2) ? 1 : 0;
         g_CalNewsScore += pIa[i] * w;
      }
      if(g_CalNewsScore >  10) g_CalNewsScore =  10;
      if(g_CalNewsScore < -10) g_CalNewsScore = -10;
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

   // Confidence inline with signal (compact: conf% only; full SL/TP/RR stays near OB/FVG section)
   {
      bool _sigActive = (g_Signal != "WAITING");
      if(_sigActive) {
         color  _cClr = (g_Confidence >= 80) ? clrGold :
                        (g_Confidence >= MinConfidence) ? clrLime :
                        (g_Confidence > 0) ? clrOrange : clrSilver;
         DashLine("02_conf_inline", "          Conf: " + DoubleToString(g_Confidence,0) + "%",
                  cx, cy, row, lh, corner, _cClr, 8); row++;
      } else {
         DashLine("02_conf_inline", "", cx, cy, row, lh, corner, clrGray, 7); row++;
      }
   }

   // NB Brain posterior — always visible when enabled; font 9 for easy reading at a glance
   {
      if(UseNBBrain) {
         string _nbStr;
         color  _nbClr;
         if(!g_HaNB_Trained) {
            _nbStr = "  [NB BRAIN] training...";
            _nbClr = clrSilver;
         } else {
            string _nbDir = (g_NBPredDir == 1) ? "  [^UP]" : (g_NBPredDir == -1) ? "  [vDN]" : "";
            _nbStr = "  [NB]  BUY=" + DoubleToString(g_NBBuyProb,0)
                   + "%  SELL=" + DoubleToString(g_NBSellProb,0)
                   + "%  NTRL=" + DoubleToString(g_NBPosteriorHold,0) + "%"
                   + _nbDir + (g_HADirFlip ? "  [FLIP]" : "");
            _nbClr = (g_NBPredDir ==  1) ? clrLime
                   : (g_NBPredDir == -1) ? clrOrangeRed
                   : clrSilver;
         }
         DashLine("02_nb_inline", _nbStr, cx, cy, row, lh, corner, _nbClr, 9); row++;
      } else {
         DashLine("02_nb_inline", "", cx, cy, row, lh, corner, clrGray, 7); row++;
      }
   }

   // Signal reason sub-line (shown when HA reset but structure still supports trade)
   {
      bool _showReason = (g_SignalPendingReason != "" &&
                          (g_Signal == "PREPARING BUY" || g_Signal == "PREPARING SELL"));
      if(_showReason) {
         DashLine("02_sigreason", "          Why: " + g_SignalPendingReason,
                  cx, cy, row, lh, corner, clrOrange, 7); row++;
      } else {
         DashLine("02_sigreason", "", cx, cy, row, lh, corner, clrGray, 7); row++;
      }
   }

   // Scan-paused indicator when bot has an open trade
   if(PauseScanInTrade && g_TradeOpen) {
      DashLine("02_pause", "          [SCAN PAUSED — managing trade]",          cx, cy, row, lh, corner, clrOrange,     8); row++;
   } else {
      DashLine("02_pause", "",                                                  cx, cy, row, lh, corner, clrGray,       8); row++;
   }

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
   string bollRmTag = (g_BollRoomLabel != "") ? (" Boll:" + g_BollRoomLabel) : "";
   DashLine("04b_zone",  "Zone    : " + g_ZoneLabel + " [" + g_ZoneHardness + "]" + bollRmTag,   cx, cy, row, lh, corner, zoneClr,       9); row++;
   bool sw = IsSideways();
   DashLine("04c_sw",    "Sideways: " + (sw ? "YES (tight lock)" : "No"),       cx, cy, row, lh, corner, sw?clrOrange:clrGray, 9); row++;

   // HPL horizontal price level block status
   if(UseHPL && g_HPLCount > 0) {
      bool   hplAnyBlock  = g_HPLResistBlock || g_HPLSupportBlock;
      string hplText      = "HPL     : ";
      color  hplClr       = clrGray;
      if(g_HPLResistBlock && g_HPLSupportBlock) {
         hplText += "TRAPPED (" +
                    DoubleToString(g_HPLSupportHigh, _Digits) + " - " +
                    DoubleToString(g_HPLResistLow,   _Digits) + ")";
         hplClr   = clrOrangeRed;
      } else if(g_HPLResistBlock) {
         hplText += "RESIST @" +
                    DoubleToString(g_HPLResistLow,  _Digits) + "-" +
                    DoubleToString(g_HPLResistHigh, _Digits) + " [BUY BLOCKED]";
         hplClr   = clrOrangeRed;
      } else if(g_HPLSupportBlock) {
         hplText += "SUPPORT @" +
                    DoubleToString(g_HPLSupportLow,  _Digits) + "-" +
                    DoubleToString(g_HPLSupportHigh, _Digits) + " [SELL BLOCKED]";
         hplClr   = clrTomato;
      } else {
         // Show brief zone count
         int rCnt = 0, sCnt = 0;
         for(int _hz = 0; _hz < g_HPLCount; _hz++) {
            if(!g_HPLZones[_hz].broken) {
               if(g_HPLZones[_hz].dir ==  1) rCnt++;
               else                           sCnt++;
            }
         }
         hplText += IntegerToString(rCnt) + "R/" + IntegerToString(sCnt) + "S zones (clear)";
         hplClr   = clrSilver;
      }
      DashLine("04d_hpl", hplText, cx, cy, row, lh, corner, hplClr, 9); row++;
   }

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
   // --- ZAP / ZCP / Asian Bias rows (v7.00) ---
   if(UseZAP) {
      color  zapClr = g_ZAPActive ? (g_ZAPDir == 1 ? clrLime : clrTomato) : clrGray;
      string zapStr = g_ZAPActive
                      ? StringFormat("%s sc=%d [%s]%s", (g_ZAPDir==1?"BUY":"SELL"),
                                     g_ZAPScore, g_ZAPLabel, (g_ZAPFakeout?" FAKEOUT!":""))
                      : "IDLE";
      DashLine("10z_zap",   "ZAP     : " + zapStr,                              cx, cy, row, lh, corner, zapClr,        9); row++;
   }
   if(UseZoneConfluence && g_ZAPActive) {
      color zcpClr = (g_ZoneConfluencePct >= 70.0) ? clrGold : clrSilver;
      DashLine("10z_zcp",   "ZCP     : " + DoubleToString(g_ZoneConfluencePct, 0) + "%",
                                                                                 cx, cy, row, lh, corner, zcpClr,        9); row++;
   }
   if(AsianBiasEnabled) {
      color  abClr = g_AsianBiasActive ? (g_AsianBiasDir == 1 ? clrLime : clrTomato) : clrGray;
      string abStr = g_AsianBiasActive ? g_AsianBiasLabel : "IDLE";
      DashLine("10z_asian", "AsianBias: " + abStr,                               cx, cy, row, lh, corner, abClr,        9); row++;
   }
   // Session mode + SL mode + quick entry indicator (v7.00)
   {
      string _smNames[] = {"ALL","ASIAN","LONDON","ASIAN+LON"};
      string _sessStr = _smNames[MathMin(SessionMode, 3)];
      bool   _inAllowed = IsInAllowedSession();
      color  _sessClr = _inAllowed ? clrLime : clrDimGray;
      string _slStr   = UseSL ? ("SL=" + DoubleToString(SLBufferPips,0) + "pip buf") : ("NO-SL EOD@" + IntegerToString(EODCloseHour) + "h");
      DashLine("10z_sess",  "Session : " + _sessStr + " (" + (_inAllowed?"OPEN":"CLOSED") + ") | " + _slStr,
                                                                                 cx, cy, row, lh, corner, _sessClr,     8); row++;
      if(QuickEntryEnabled) {
         bool _qcActive = g_AsianBiasActive && g_ZAPActive && (g_AsianBiasDir == g_ZAPDir);
         color _qcClr   = _qcActive ? clrGold : clrDimGray;
         string _qcStr  = _qcActive ? StringFormat("ARMED dir=%s gate=%.0f%%",
                                                    (g_ZAPDir==1?"BUY":"SELL"), AsianZAPMinConf) : "IDLE";
         DashLine("10z_qe",  "QuickEnt: " + _qcStr,                             cx, cy, row, lh, corner, _qcClr,       8); row++;
      }
   }
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
                            " ARMED  Score=" + IntegerToString(g_MacroTrendScore) + "/15"
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

   // --- Confidence Score (SL/TP/RR detail block -- conf% also shown inline near signal above) ---
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

   // HA Alignment Quality row
   {
      string qualDetail = (g_HAQualityTotal > 0)
                          ? IntegerToString(g_HAQualityScore) + "/" + IntegerToString(g_HAQualityTotal) + " pure"
                          : "—";
      string confirmTag  = (g_HAQualityTotal > 0)
                           ? (g_ConfirmPure ? "  confirm:CLEAN" : "  confirm:IMPURE")
                           : "";
      color qualClr = (g_HAQualityLabel == "PURE")   ? clrLime :
                      (g_HAQualityLabel == "MIXED")  ? clrYellow :
                      (g_HAQualityLabel == "IMPURE") ? clrTomato :
                      (g_HAQualityLabel == "DOJI")   ? clrOrange : clrDimGray;
      DashLine("13b_haqual", "HA Qual : " + g_HAQualityLabel + " (" + qualDetail + ")" + confirmTag,
               cx, cy, row, lh, corner, qualClr, 9); row++;
   }

   // Session Observe / Fake-out row (v6.32)
   {
      MqlDateTime _dashDt; TimeToStruct(TimeCurrent(), _dashDt);
      bool _dInAsian  = (_dashDt.hour >= AsianStartHour   && _dashDt.hour < AsianEndHour);
      bool _dInLondon = (_dashDt.hour >= LondonStartHour  && _dashDt.hour < LondonEndHour);
      bool _dInNY     = (_dashDt.hour >= NewYorkStartHour && _dashDt.hour < NewYorkEndHour);
      string sessObsStr = "—";
      color  sessObsClr = clrDimGray;
      int    sessBarN   = 0, sessObsMax = 0;
      string sessSuffix = "";
      if(_dInNY     && NYObserveBars     > 0) { sessBarN = g_NYBarCount;     sessObsMax = NYObserveBars;     sessSuffix = " NY"; }
      else if(_dInLondon && LondonObserveBars > 0) { sessBarN = g_LondonBarCount; sessObsMax = LondonObserveBars; sessSuffix = " Lon"; }
      else if(_dInAsian  && AsianObserveBars  > 0) { sessBarN = g_AsianBarCount;  sessObsMax = AsianObserveBars;  sessSuffix = " Asi"; }
      if(sessObsMax > 0) {
         if(sessBarN <= sessObsMax) {
            sessObsStr = "OBSERVE" + sessSuffix + " " + IntegerToString(sessBarN) + "/" + IntegerToString(sessObsMax);
            sessObsClr = clrOrange;
         } else {
            sessObsStr = "FREE" + sessSuffix + " (bar " + IntegerToString(sessBarN) + ")";
            sessObsClr = clrLime;
         }
      }
      if(g_SessionFakeoutWatch)
         sessObsStr += "  " + g_FakeoutConfidence + " TRAP" + (g_FakeoutDir > 0 ? "↑" : "↓");
      color sessObsClrFinal = g_SessionFakeoutWatch
                              ? (g_FakeoutConfidence == "HIGH" ? clrRed : clrOrangeRed)
                              : sessObsClr;
      DashLine("13c_sessobs", "SessObs : " + sessObsStr, cx, cy, row, lh, corner, sessObsClrFinal, 9); row++;
      if(g_InterSessContext != "") {
         color isClr = g_SessionFakeoutWatch
                       ? (g_FakeoutConfidence == "HIGH" ? clrRed : clrOrangeRed) : clrDimGray;
         DashLine("13d_isess", "InterSess: " + g_InterSessContext, cx, cy, row, lh, corner, isClr, 8); row++;
      }
   }
   // v6.34: MA status row
   if(UseMAFilter && g_MAStatusLabel != "") {
      bool allAbove = g_AboveMA200 && g_AboveMA50 && g_AboveMA20;
      bool allBelow = !g_AboveMA200 && !g_AboveMA50 && !g_AboveMA20;
      bool fakeJump = g_MA200FakeJumpUp || g_MA200FakeJumpDn;
      color maClr = fakeJump ? clrOrange : allAbove ? clrLime : allBelow ? clrTomato : clrYellow;
      DashLine("14_ma", "MA15   : " + g_MAStatusLabel, cx, cy, row, lh, corner, maClr, 9); row++;
      // v6.35: Pending MA200 order row
      if(g_PendingMA200Ticket != 0) {
         int barsOld = (int)iBarShift(_Symbol, PERIOD_M15, g_PendingMA200Bar, false);
         string pendStr = (g_PendingMA200Dir==1?"BuyStop":"SellStop")
                          + " @" + DoubleToString(g_PendingMA200Entry,5)
                          + "  (" + IntegerToString(barsOld) + "/" + IntegerToString(MA200PendingMaxBars) + " bars)";
         DashLine("14_mapend", "MA200 Pend: " + pendStr, cx, cy, row, lh, corner, clrAqua, 9); row++;
      }
   }
   // v6.34: Daily extension cap row
   if(UseDailyExtCap) {
      bool _extBlocked = (g_DailyExtDownPct > DailyExtCapPct || g_DailyExtUpPct > DailyExtCapPct);
      bool _extWarn    = (!_extBlocked && (g_DailyExtDownPct > DailyExtCapPct * 0.7 || g_DailyExtUpPct > DailyExtCapPct * 0.7));
      color extClr = _extBlocked ? clrRed : _extWarn ? clrOrange : clrDimGray;
      string extStr = "D:" + DoubleToString(g_DailyExtDownPct,0) + "% U:"
                      + DoubleToString(g_DailyExtUpPct,0) + "% cap="
                      + DoubleToString(DailyExtCapPct,0) + "%";
      if(_extBlocked) extStr += " BLOCKED";
      DashLine("14b_ext", "DayExt : " + extStr, cx, cy, row, lh, corner, extClr, 9); row++;
   }
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

   // --- NB Brain posteriors (always shown when UseNBBrain is enabled) ---
   if(UseNBBrain) {
      string _nbR_str;
      color  _nbR_clr;
      if(!g_HaNB_Trained) {
         _nbR_str = "[NB Brain] training...";
         _nbR_clr = clrSilver;
      } else {
         string _dir = (g_NBPredDir == 1) ? " ^UP" : (g_NBPredDir == -1) ? " vDN" : " ~NTR";
         _nbR_str = "NB Brain:" + _dir
                  + "  UP="   + DoubleToString(g_NBBuyProb,       1) + "%"
                  + "  DN="   + DoubleToString(g_NBSellProb,      1) + "%"
                  + "  NTRL=" + DoubleToString(g_NBPosteriorHold, 1) + "%";
         _nbR_clr = (g_NBPredDir ==  1) ? clrLime
                  : (g_NBPredDir == -1) ? clrOrangeRed
                  : clrSilver;
      }
      DashLine("R_nb_priors", _nbR_str, rx, cy, rowR, lh, corner, _nbR_clr, 9); rowR++;
   } else {
      DashLine("R_nb_priors", "", rx, cy, rowR, lh, corner, clrGray, 8); rowR++;
   }
   rowR++;

   // --- Trade Status (ALL rows ALWAYS rendered — prevents label overlap) ---
   {
      // Fetch live entry price + net P&L from the position for display
      double _botEntry = 0, _botNetPnL = 0;
      if(g_TradeOpen) {
         for(int _pi = PositionsTotal() - 1; _pi >= 0; _pi--) {
            if(!posInfo.SelectByIndex(_pi)) continue;
            if(posInfo.Symbol() != _Symbol || posInfo.Magic() != 202502) continue;
            _botEntry  = posInfo.PriceOpen();
            _botNetPnL = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
            break;
         }
      }

      // Row 1: Direction + lots + entry + floating P&L (most important info on first line)
      if(g_TradeOpen) {
         string _bDir    = (g_TradeDir == 1) ? "[BUY] " : "[SELL]";
         color  _bDirClr = (g_TradeDir == 1) ? clrLime  : clrTomato;
         string _bPnL    = (_botNetPnL >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(_botNetPnL), 2);
         string _bEntry  = (_botEntry > 0) ? "  @" + DoubleToString(_botEntry, _Digits) : "";
         DashLine("R_trade",
                  _bDir + " " + DoubleToString(g_CurrentLot, 2) + "L" + _bEntry + "  Net:" + _bPnL,
                  rx, cy, rowR, lh, corner, _bDirClr, 9);
      } else {
         DashLine("R_trade", "Trade   : NONE", rx, cy, rowR, lh, corner, clrGray, 9);
      }
      rowR++;

      // Row 2: Mode + management strategy
      if(g_TradeOpen) {
         string modeStr = g_IsMeanRev ? "MEAN REV" : (g_IsNearMid ? "MID-validated" : "TREND");
         color  modeClr = g_IsMeanRev ? clrGold : (g_IsNearMid ? clrOrange : clrLime);
         DashLine("R_mode", "Mode    : " + modeStr + " | " + g_TradeMgmtModeName, rx, cy, rowR, lh, corner, modeClr, 9);
      } else {
         DashLine("R_mode", "Mode    : --- | " + g_TradeMgmtModeName, rx, cy, rowR, lh, corner, clrDimGray, 9);
      }
      rowR++;

      // Row 3: Confidence + SL/TP USD risk + RR ratio
      if(g_TradeOpen) {
         double _rr = (g_ScaledSLUSD > 0) ? g_ScaledTPUSD / g_ScaledSLUSD : 0;
         string confLbl = "Conf " + DoubleToString(g_Confidence, 0) + "%";
         color  cClr = (g_Confidence >= 80) ? clrGold : (g_Confidence >= 65) ? clrCyan : clrSilver;
         DashLine("R_sltp", confLbl +
                  "  SL:$" + DoubleToString(g_ScaledSLUSD, 2) +
                  "  TP:$" + DoubleToString(g_ScaledTPUSD, 2) +
                  "  RR:" + DoubleToString(_rr, 1),
                  rx, cy, rowR, lh, corner, cClr, 8);
      } else {
         DashLine("R_sltp", "Conf/SL/TP: ---", rx, cy, rowR, lh, corner, clrDimGray, 8);
      }
      rowR++;

      // Row 4: Lock thresholds
      if(g_TradeOpen) {
         DashLine("R_lktr", "LkTrig:$" + DoubleToString(g_ScaledLockUSD, 2) +
                  "  TrailTrig:$" + DoubleToString(g_ScaledTrailUSD, 2),
                  rx, cy, rowR, lh, corner, clrAqua, 8);
      } else {
         DashLine("R_lktr", "Lock/Tr : ---", rx, cy, rowR, lh, corner, clrDimGray, 8);
      }
      rowR++;

      // Row 5: Confluence level
      if(g_TradeOpen && g_NearLevel != "") {
         DashLine("R_cnfl", "Cnfl    : " + g_NearLevel, rx, cy, rowR, lh, corner, clrGold, 9);
      } else {
         DashLine("R_cnfl", "Cnfl    : ---", rx, cy, rowR, lh, corner, clrDimGray, 9);
      }
      rowR++;

      // Row 6: Hold bars + peak/trough/shifts (merged from separate hold+track rows)
      if(g_TradeOpen) {
         color  _holdClr = (g_BarsSincePeak > 10) ? clrOrange :
                           (g_PeakProfit > g_ScaledLockUSD) ? clrLime : clrWhite;
         DashLine("R_hold",
                  "Hold:" + IntegerToString(g_OpenBarCount) + "/" + IntegerToString(MaxHoldBars) +
                  "  SincePk:" + IntegerToString(g_BarsSincePeak) +
                  "  Pk:$" + DoubleToString(g_PeakProfit, 2) +
                  "  Lo:$" + DoubleToString(g_TroughProfit, 2),
                  rx, cy, rowR, lh, corner, _holdClr, 8);
      } else {
         DashLine("R_hold", "Hold    : ---", rx, cy, rowR, lh, corner, clrDimGray, 8);
      }
      rowR++;

      // Row 7: Hard loss cap
      if(g_TradeOpen) {
         double hardLoss = MaxLossUSD * g_CurrentLot / 0.01;
         DashLine("R_cap", "MaxLoss : -$" + DoubleToString(hardLoss, 2) + " cap",
                  rx, cy, rowR, lh, corner, clrTomato, 9);
      } else {
         DashLine("R_cap", "MaxLoss : ---", rx, cy, rowR, lh, corner, clrDimGray, 9);
      }
      rowR++;

      // Row 8: Lock status + struct shifts
      if(g_TradeOpen) {
         string lockStr = g_ProfitLocked
                          ? "LOCKED  peak:$" + DoubleToString(g_PeakProfit, 2)
                          : (g_EarlyLockEngaged ? "EARLY_LK" : "Watching") +
                            "  lock@$" + DoubleToString(g_ScaledLockUSD, 2);
         lockStr += "  Sh:" + IntegerToString(g_StructShiftCount);
         color  lColor = g_ProfitLocked ? clrLime : g_EarlyLockEngaged ? clrYellow : clrOrange;
         DashLine("R_lock", "Lock    : " + lockStr, rx, cy, rowR, lh, corner, lColor, 9);
      } else {
         DashLine("R_lock", "Lock    : ---", rx, cy, rowR, lh, corner, clrDimGray, 9);
      }
      rowR++;

      // Row 9: HPL stagnation alert for bot trade (repurposed track row)
      if(g_TradeOpen && g_TradeDir != 0 && UseHPL && g_HPLCount > 0) {
         string _hplWarnStr = "";  color _hplWarnClr = clrDimGray;
         double _bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         for(int _hz = 0; _hz < g_HPLCount; _hz++) {
            if(g_HPLZones[_hz].broken) continue;
            double _hzMid = (g_HPLZones[_hz].high + g_HPLZones[_hz].low) / 2.0;
            bool _opposing = (g_TradeDir == 1 && g_HPLZones[_hz].dir == 1) ||
                             (g_TradeDir == -1 && g_HPLZones[_hz].dir == -1);
            if(!_opposing) continue;
            // Zone directly ahead (within 8 pips of current price in trade direction)
            bool _near = (g_TradeDir == 1 && _hzMid > _bid && (_hzMid - _bid) < 80 * _Point * 10.0) ||
                         (g_TradeDir == -1 && _hzMid < _bid && (_bid - _hzMid) < 80 * _Point * 10.0);
            if(_near || (g_TradeDir == 1 && g_HPLResistBlock) || (g_TradeDir == -1 && g_HPLSupportBlock)) {
               _hplWarnStr = ">> HPL " + (g_HPLZones[_hz].dir == 1 ? "RESIST" : "SUPPORT") +
                             " @" + DoubleToString(g_HPLZones[_hz].low, _Digits) +
                             " (" + IntegerToString(g_HPLZones[_hz].touches) + "t) — hold cautiously";
               _hplWarnClr = (_near && (g_HPLResistBlock || g_HPLSupportBlock)) ? clrOrangeRed : clrOrange;
               break;
            }
         }
         DashLine("R_track", _hplWarnStr, rx, cy, rowR, lh, corner, _hplWarnClr, 8);
      } else {
         DashLine("R_track", "", rx, cy, rowR, lh, corner, clrDimGray, 8);
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

      // --- Comeback Potential (only shown when trade is in loss) ---
      if(g_TradeOpen && g_ComebackLabel != "") {
         color cbClr = clrYellow;
         if(g_ComebackLabel == "HIGH")         cbClr = clrLime;
         else if(g_ComebackLabel == "LOW")     cbClr = clrTomato;
         DashLine("R_comeback", "Comeback: " + g_ComebackLabel, rx, cy, rowR, lh, corner, cbClr, 8);
      } else {
         DashLine("R_comeback", "", rx, cy, rowR, lh, corner, clrGray, 8);
      }
      rowR++;
   }
   rowR++;

   // --- Manual Trades Panel ---
   // Header shows count and total lots on one line; individual trades below
   {
      string mtHdrStr;
      color  mtHdrClr;
      if(g_ManualTradeCount > 0) {
         mtHdrStr = "--- MANUAL (" + IntegerToString(g_ManualTradeCount) + " | " +
                    DoubleToString(g_ForeignLotsSymbol, 2) + "L) ---";
         mtHdrClr = clrOrangeRed;
      } else if(g_ForeignCountTotal > 0) {
         mtHdrStr = "--- MANUAL (other pairs: " + IntegerToString(g_ForeignCountTotal) + ") ---";
         mtHdrClr = clrSilver;
      } else {
         mtHdrStr = "--- MANUAL TRADES ---";
         mtHdrClr = clrSilver;
      }
      DashLine("R_mthdr", mtHdrStr, rx, cy, rowR, lh, corner, mtHdrClr, 8); rowR++;
   }

   // Up to 2 trades shown in full; 3rd+ summarised
   int mtShow = MathMin(g_ManualTradeCount, 2);
   for(int _mi = 0; _mi < 2; _mi++) {   // always render 2 trade blocks to hold slot positions
      string pfx = "R_mt" + IntegerToString(_mi);
      if(_mi < mtShow) {
         ManualTradeInfo mt = g_ManualTrades[_mi];
         double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double pipSz  = _Point * 10.0;
         double slPips = (mt.sl > 0) ? MathAbs(mt.openPrice - mt.sl)   / pipSz : 0;
         double tpPips = (mt.tp > 0) ? MathAbs(mt.tp        - mt.openPrice) / pipSz : 0;
         double rr     = (slPips > 0.1 && tpPips > 0.1) ? tpPips / slPips : 0;
         int    conf   = ManualTradeConf(mt.dir);
         string dirLbl = (mt.dir == 1) ? "[BUY] " : "[SELL]";
         color  dirClr = (mt.dir == 1) ? clrLime  : clrTomato;
         string srcLbl = mt.isManual ? "" : " EA:" + IntegerToString((int)mt.magic);
         string pnlLbl = (mt.pnl >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(mt.pnl), 2);
         color  pnlClr = (mt.pnl >= 0) ? clrLime : clrTomato;

         // --- Row 1: Direction | Lots | Entry | Net P&L ---
         string r1 = dirLbl + " " + DoubleToString(mt.lots, 2) + "L" + srcLbl +
                     "  @" + DoubleToString(mt.openPrice, _Digits) +
                     "  Net:" + pnlLbl;
         DashLine(pfx + "_h", r1, rx, cy, rowR, lh, corner, dirClr, 9); rowR++;

         // --- Row 2: SL/TP details or NO SL warning ---
         string r2;  color r2Clr;
         if(mt.sl == 0 && mt.tp == 0) {
            r2    = "!! NO SL & NO TP — risk fully unmanaged";
            r2Clr = clrRed;
         } else if(mt.sl == 0) {
            double tpP = tpPips;
            r2    = "!! NO SL  TP:" + DoubleToString(mt.tp, _Digits) +
                    "(" + DoubleToString(tpP, 1) + "p)  Suggest SL:" +
                    DoubleToString(mt.dir == 1
                                   ? mt.openPrice - 1.5 * g_ATR
                                   : mt.openPrice + 1.5 * g_ATR, _Digits);
            r2Clr = clrOrangeRed;
         } else if(mt.tp == 0) {
            r2    = "SL:" + DoubleToString(mt.sl, _Digits) +
                    "(" + DoubleToString(slPips, 1) + "p)  !! NO TP — add target";
            r2Clr = clrOrange;
         } else {
            string rrStr = DoubleToString(rr, 2) + ":1";
            color  rrClr = (rr >= 1.5) ? clrLime : (rr >= 1.0) ? clrGold : clrTomato;
            r2    = "SL:" + DoubleToString(mt.sl, _Digits) + "(" + DoubleToString(slPips,1) + "p)" +
                    "  TP:" + DoubleToString(mt.tp, _Digits) + "(" + DoubleToString(tpPips,1) + "p)" +
                    "  RR:" + rrStr;
            r2Clr = (rr < 1.0) ? clrOrangeRed : rrClr;
         }
         DashLine(pfx + "_sl", r2, rx, cy, rowR, lh, corner, r2Clr, 8); rowR++;

         // --- Row 3: Structural confidence + factor tags ---
         string h4Tag  = (g_MacroStructLabel == "BULLISH") ? "[H4+]" : (g_MacroStructLabel == "BEARISH") ? "[H4-]" : "[H4~]";
         string h1Tag  = (g_StructureLabel   == "BULLISH") ? "[H1+]" : (g_StructureLabel   == "BEARISH") ? "[H1-]" : "[H1~]";
         string fvgTag = (mt.dir == 1 && g_NearBullFVG) ? "[FVG]" : (mt.dir == -1 && g_NearBearFVG) ? "[FVG]" : "     ";
         string obTag  = (mt.dir == 1 && g_BullOB_High > 0) ? "[OB]" : (mt.dir == -1 && g_BearOB_High > 0) ? "[OB]" : "    ";
         // Flip tags to opposing colour if they work against the trade direction
         color confClr = (conf >= 65) ? clrCyan : (conf >= 45) ? clrSilver : clrTomato;
         DashLine(pfx + "_st",
                  h4Tag + h1Tag + fvgTag + obTag + " Conf:" + IntegerToString(conf) + "% at TP",
                  rx, cy, rowR, lh, corner, confClr, 8); rowR++;

         // --- Row 4: Contextual warnings (HPL, poor RR, bad conf) ---
         string warnStr = "";  color warnClr = clrGray;
         // HPL stagnation zone between price and TP
         if(mt.dir == 1 && mt.tp > 0) {
            for(int _hz = 0; _hz < g_HPLCount; _hz++) {
               if(g_HPLZones[_hz].broken) continue;
               if(g_HPLZones[_hz].dir == 1) {       // resistance
                  double zMid = (g_HPLZones[_hz].high + g_HPLZones[_hz].low) / 2.0;
                  if(zMid > bid && zMid < mt.tp) {   // between now and TP
                     warnStr = ">> RESIST HPL @" + DoubleToString(g_HPLZones[_hz].low, _Digits) +
                               "-" + DoubleToString(g_HPLZones[_hz].high, _Digits) +
                               " (" + IntegerToString(g_HPLZones[_hz].touches) + "t) before TP — early exit";
                     warnClr = clrOrange;
                     break;
                  }
                  if(g_HPLResistBlock) {             // currently inside resist zone
                     warnStr = ">> Price in RESIST HPL — stagnation risk, consider close";
                     warnClr = clrOrangeRed;
                     break;
                  }
               }
            }
         } else if(mt.dir == -1 && mt.tp > 0) {
            for(int _hz = 0; _hz < g_HPLCount; _hz++) {
               if(g_HPLZones[_hz].broken) continue;
               if(g_HPLZones[_hz].dir == -1) {      // support
                  double zMid = (g_HPLZones[_hz].high + g_HPLZones[_hz].low) / 2.0;
                  if(zMid < bid && zMid > mt.tp) {   // between now and TP (for sell, TP < bid)
                     warnStr = ">> SUPPORT HPL @" + DoubleToString(g_HPLZones[_hz].low, _Digits) +
                               "-" + DoubleToString(g_HPLZones[_hz].high, _Digits) +
                               " (" + IntegerToString(g_HPLZones[_hz].touches) + "t) before TP — early exit";
                     warnClr = clrOrange;
                     break;
                  }
                  if(g_HPLSupportBlock) {
                     warnStr = ">> Price in SUPPORT HPL — stagnation risk, consider close";
                     warnClr = clrOrangeRed;
                     break;
                  }
               }
            }
         }
         // Poor RR warning (supersedes HPL warn if rr even worse)
         if(warnStr == "" && mt.sl > 0 && mt.tp > 0 && rr < 1.0) {
            warnStr = ">> POOR RR (" + DoubleToString(rr, 2) + ":1) — SL > reward, reposition";
            warnClr = clrOrangeRed;
         }
         // Structural opposition warning
         if(warnStr == "" && conf < 35) {
            warnStr = ">> Structure OPPOSING this trade (" + IntegerToString(conf) + "%)";
            warnClr = clrTomato;
         }
         DashLine(pfx + "_w", warnStr, rx, cy, rowR, lh, corner, warnClr, 8); rowR++;
      } else {
         // Empty slot — always render to hold row positions (avoids stale label overlap)
         DashLine(pfx + "_h",  "", rx, cy, rowR, lh, corner, clrDimGray, 9); rowR++;
         DashLine(pfx + "_sl", "", rx, cy, rowR, lh, corner, clrDimGray, 8); rowR++;
         DashLine(pfx + "_st", "", rx, cy, rowR, lh, corner, clrDimGray, 8); rowR++;
         DashLine(pfx + "_w",  "", rx, cy, rowR, lh, corner, clrDimGray, 8); rowR++;
      }
   }
   // If there are > 2 trades, show a compact summary for the rest
   if(g_ManualTradeCount > 2) {
      string xtraStr = "  +" + IntegerToString(g_ManualTradeCount - 2) + " more: ";
      for(int _mx = 2; _mx < g_ManualTradeCount; _mx++) {
         xtraStr += (g_ManualTrades[_mx].dir == 1 ? "BUY " : "SELL ") +
                    DoubleToString(g_ManualTrades[_mx].lots, 2) + "L  ";
      }
      DashLine("R_mtxtra", xtraStr, rx, cy, rowR, lh, corner, clrGray, 7); rowR++;
   } else {
      DashLine("R_mtxtra", "", rx, cy, rowR, lh, corner, clrDimGray, 7); rowR++;
   }
   // No same-symbol trades — write "none" into the first slot high-water row and keep a blank placeholder
   DashLine("R_mtnone", (g_ManualTradeCount == 0) ? " none (no manual trades on " + _Symbol + ")" : "",
            rx, cy, rowR, lh, corner, clrGray, 8); rowR++;

   // Bot paused warning at bottom of section
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
      // Combined totals across bot + manual
      double _totalPnL = g_DailyPnL + g_DailyManualPnL;
      int    _totalW   = g_DailyWins + g_DailyManualWins;
      int    _totalL   = g_DailyLosses + g_DailyManualLosses;
      int    _totalN   = g_DailyTradeCount + g_DailyManualCount;
      color  _totClr   = _totalPnL > 0 ? clrLime : _totalPnL < 0 ? clrRed : clrGray;
      DashLine("R_dstat_tot",
               "All   : W:" + IntegerToString(_totalW) +
               " L:" + IntegerToString(_totalL) +
               " P&L:$" + DoubleToString(_totalPnL, 2) +
               " (" + IntegerToString(_totalN) + " trades)",
               rx, cy, rowR, lh, corner, _totClr, 9); rowR++;

      // Bot sub-row
      color _botClr = g_DailyPnL > 0 ? clrLime : g_DailyPnL < 0 ? clrTomato : clrGray;
      DashLine("R_dstat_bot",
               "  Bot : W:" + IntegerToString(g_DailyWins) +
               " L:" + IntegerToString(g_DailyLosses) +
               " $" + DoubleToString(g_DailyPnL, 2) +
               " (" + IntegerToString(g_DailyTradeCount) + "/" +
               (MaxDailyTrades > 0 ? IntegerToString(MaxDailyTrades) : "inf") + ")",
               rx, cy, rowR, lh, corner, _botClr, 8); rowR++;

      // Manual sub-row
      color _manClr = g_DailyManualPnL > 0 ? clrLime : g_DailyManualPnL < 0 ? clrTomato : clrSilver;
      DashLine("R_dstat_man",
               "  Man : W:" + IntegerToString(g_DailyManualWins) +
               " L:" + IntegerToString(g_DailyManualLosses) +
               " $" + DoubleToString(g_DailyManualPnL, 2) +
               " (" + IntegerToString(g_DailyManualCount) + " closed)",
               rx, cy, rowR, lh, corner, _manClr, 8); rowR++;
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

   // --- Economic Calendar (v6.39) ---
   if(ShowCalendar) {
      // === RECENT NEWS (released events with actual data) ===
      if(CalendarLookBackH > 0) {
         string _nsHdr = "--- RECENT NEWS ---";
         if(g_CalNewsScore > 0)       _nsHdr = _nsHdr + " [+" + IntegerToString(g_CalNewsScore) + " BULL]";
         else if(g_CalNewsScore < 0)  _nsHdr = _nsHdr + " [" + IntegerToString(g_CalNewsScore) + " BEAR]";
         else                         _nsHdr = _nsHdr + " [neutral]";
         DashLine("R_pnhdr", _nsHdr, rx, cy, rowR, lh, corner, clrSilver, 8); rowR++;

         for(int _pi = 0; _pi < 3; _pi++) {
            string _psuf = "R_pnev" + IntegerToString(_pi);
            if(_pi < g_CalPastCount) {
               CalPastEvent _pev = g_CalPastEvents[_pi];
               // Time ago
               int _ago = (int)(TimeCurrent() - _pev.time);
               string _tAgo;
               if(_ago < 3600) _tAgo = IntegerToString(_ago / 60) + "m";
               else            _tAgo = IntegerToString(_ago / 3600) + "h";
               while(StringLen(_tAgo) < 4) _tAgo = _tAgo + " "; // pad
               // Importance stars
               string _pimp = (_pev.importance == 3) ? "!!!" : (_pev.importance == 2) ? "!! " : "!  ";
               // EUR/USD direction tag
               string _itag;
               color  _iclr;
               if(_pev.impact == +1)      { _itag = "[+]"; _iclr = clrLime;   }
               else if(_pev.impact == -1) { _itag = "[-]"; _iclr = clrTomato; }
               else                       { _itag = "[~]"; _iclr = clrGray;   }
               // Actual & forecast
               string _acts = "";
               if(_pev.actual != DBL_MAX) {
                  _acts = " A:" + DoubleToString(_pev.actual, 2);
                  if(_pev.forecast != DBL_MAX)
                     _acts = _acts + " F:" + DoubleToString(_pev.forecast, 2);
               }
               // Name (truncated)
               string _nm = _pev.name;
               if(StringLen(_nm) > 16) _nm = StringSubstr(_nm, 0, 15) + "~";
               DashLine(_psuf,
                        _pimp + " " + _pev.currency + " " + _tAgo + " " + _nm + _acts + " " + _itag,
                        rx, cy, rowR, lh, corner, _iclr, 8); rowR++;
            } else {
               DashLine(_psuf, "", rx, cy, rowR, lh, corner, clrGray, 7); rowR++;
            }
         }
         rowR++; // spacer
      }

      DashLine("R_calhdr", "--- NEXT EVENTS ---", rx, cy, rowR, lh, corner, clrSilver, 8); rowR++;

      // Determine macro+micro structural alignment for context labelling
      bool _calMacBull = (g_MacroStructLabel == "BULLISH");
      bool _calMacBear = (g_MacroStructLabel == "BEARISH");
      bool _calH1Bull  = (g_StructureLabel   == "BULLISH");
      bool _calH1Bear  = (g_StructureLabel   == "BEARISH");
      bool _calBothBull = (_calMacBull && _calH1Bull);
      bool _calBothBear = (_calMacBear && _calH1Bear);

      // Always render 3 fixed rows so panel height is stable
      for(int _ri = 0; _ri < 3; _ri++) {
         string _lsuf = "R_cal" + IntegerToString(_ri);
         if(_ri < g_CalEventCount) {
            CalEvent _ev  = g_CalEvents[_ri];
            int _secsA    = (int)(_ev.time - TimeCurrent());
            string _tStr;
            if(_secsA <= 0)        _tStr = "NOW";
            else if(_secsA < 3600) _tStr = IntegerToString(_secsA / 60) + "m  ";
            else { MqlDateTime _edx; TimeToStruct(_ev.time, _edx);
                   _tStr = StringFormat("%02d:%02d", _edx.hour, _edx.min); }
            string _imp = (_ev.importance == 3) ? "!!!" : (_ev.importance == 2) ? "!! " : "!  ";
            string _nm  = _ev.name;
            if(StringLen(_nm) > 19) _nm = StringSubstr(_nm, 0, 18) + "~";
            // Structural alignment tag: EUR+ = EURUSD UP, USD+ = EURUSD DOWN
            string _tag = "";
            if(_ev.importance >= 2) {
               bool _eurUp = (_ev.currency == "EUR"); // EUR positive -> pair rises
               if(_calBothBull)      _tag = _eurUp ? " [+]" : " [-]";
               else if(_calBothBear) _tag = _eurUp ? " [-]" : " [+]";
               else if(_calMacBull || _calH1Bull || _calMacBear || _calH1Bear) _tag = " [~]";
            }
            // Urgency colour: red=imminent HIGH, orange=upcoming HIGH, gold=later HIGH, yellow=MOD
            color _ec = clrDimGray;
            if(_ev.importance == 3) {
               if(_secsA >= 0 && _secsA <= CalendarNoTradeMins * 60) _ec = clrRed;
               else if(_secsA < 7200) _ec = clrOrange;
               else _ec = clrGold;
            } else if(_ev.importance == 2) { _ec = clrYellow; }
            DashLine(_lsuf, _imp + " " + _ev.currency + " " + _tStr + " " + _nm + _tag,
                     rx, cy, rowR, lh, corner, _ec, 8); rowR++;
         } else {
            DashLine(_lsuf, "", rx, cy, rowR, lh, corner, clrGray, 7); rowR++;
         }
      }
      // No-trade warning banner
      if(g_NewsNoTrade) {
         DashLine("R_calwarn", " !! NO-TRADE - HIGH IMPACT IMMINENT !!",
                  rx, cy, rowR, lh, corner, clrRed, 9); rowR++;
      } else {
         DashLine("R_calwarn", "", rx, cy, rowR, lh, corner, clrGray, 7); rowR++;
      }
      // Legend: [+]=aligns with bias  [-]=opposes  [~]=partial/mixed
      DashLine("R_calleg", "  [+]align [-]oppose [~]mixed | !! = moderate  !!! = high",
               rx, cy, rowR, lh, corner, clrDimGray, 7); rowR++;
   }

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