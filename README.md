# EURUSD HA Range — Automated Trading Bot

A fully automated Expert Advisor for MetaTrader 5, designed for the EUR/USD pair on the 15-minute chart. It combines Heiken Ashi candle pattern reading, price range structure, and a layered set of market filters to identify high-probability trade entries and manage them through to exit — without any manual intervention once attached to a chart.

---

## What it does

The bot watches the EUR/USD market around the clock and decides when conditions are good enough to place a trade. It does not trade randomly; every entry must pass through a series of checkpoints before an order is ever sent. If even one gate fails, the bot waits.

At its core, it works like this:

1. It identifies the current day's trading range — the high and low boundaries price has established.
2. It reads Heiken Ashi candles on the 15-minute chart to spot momentum building in one direction.
3. It checks a long list of market conditions before it acts.
4. Once in a trade, it manages the position automatically — locking in profit, trailing the stop, and closing if conditions deteriorate.

---

## How entries are decided

Every potential trade goes through the following checks in order. All must pass.

**Range zone** — The bot knows where price sits inside the day's range. Trend trades are only taken from the right area; counter-trend bounce trades are only taken at the extremes.

**Heiken Ashi pattern** — A sequence of clean, same-direction HA candles is required. Doji candles or mixed signals disqualify the setup.

**Bollinger Bands** — Price must be positioned relative to the Bollinger midline in the trade direction, confirming momentum is real.

**Market structure (Smart Money)** — The bot reads the underlying price structure on the 1-hour and 4-hour timeframes, identifying breaks of structure (BOS) and changes of character (CHoCH). Trades against a confirmed macro move are blocked by default.

**Moving averages (15-minute chart)** — Three exponential moving averages are tracked: the 200, 50, and 20. The 200 acts as a macro direction filter — buying below it or selling above it is blocked unless the market is showing a clear reversal signal. The 50 acts as an intraday filter — the bot requires price to be touching or crossing it before entering.

**Session observation window** — At the open of each session (Asian, London, New York), the bot watches the first hour of price action before it considers any trades. This prevents getting caught in the often misleading opening moves.

**Fake-out detection** — If during the observation window price moved strongly against the broader trend, that move is classified as a potential trap. The bot then waits for price to reverse before entering in the real direction.

**Volume** — Dead or declining volume triggers a hard block. No entries are taken in a market that is not moving with conviction.

**Daily extension cap** — If price has already moved a significant distance from the daily open (measured as a percentage of the day's average range), new trades in that direction are blocked. The market is extended; chasing it is poor practice.

**Fibonacci and pivot levels** — Key technical levels are computed from the range and the previous day's price action. Proximity to a significant level adds confidence to the setup.

**Confidence score** — Every setup is scored from 0 to 100 based on how many confluences align. A minimum score threshold must be met before an entry is placed.

**Daily limits** — A maximum number of trades per day and a maximum daily loss in dollars are enforced. Once either is hit, the bot stops trading for the rest of the day.

---

## How the trade is managed

Once in a trade, the bot does not just sit and wait for the stop or target to hit.

- **Profit lock** — Once the trade reaches 75% of the target, the stop is moved to protect most of the gain.
- **Trailing stop** — After the lock-in point, the stop follows price to capture as much of the remaining move as possible.
- **Structure exit** — If the market's underlying structure shifts against the trade (a CHoCH in the wrong direction, for example), the bot closes early rather than riding a reversal back to the stop.
- **Time limit** — If the trade has been open for 12 hours without resolving, it is closed regardless.
- **Stall detection** — If price gets stuck in the middle of the range and is going nowhere, the trade can be exited early to reclaim the margin.

Multiple trade management modes are available, ranging from a simple fixed stop-and-target approach to more dynamic modes that adapt to momentum, sentiment shifts, and time of day.

---

## Sessions tracked

- **Asian session** — 00:00 to 08:00 server time
- **London session** — 08:00 to 16:00 server time
- **New York session** — 13:00 to 21:00 server time

The London-New York overlap (13:00 to 16:00) is typically where the most significant moves occur, and the bot's filters are designed to take advantage of that.

---

## Risk management

All risk figures scale with lot size. The defaults are designed for small accounts.

| Setting | Default | What it means |
|---|---|---|
| Lot size | 0.01 | The smallest standard position size |
| Max risk per trade | 2% of balance | Only applies when auto-sizing is enabled |
| Stop loss | 15 to 25 pips | Structural, not fixed — placed behind a meaningful level |
| Reward-to-risk ratio | 1.8:1 | For every pip risked, 1.8 pips are targeted |
| Max daily loss | Configurable | Bot stops for the day once this is hit |
| Max trades per day | Configurable | Prevents overtrading on active days |

---

## Dashboard

While running, the bot displays a live panel on the chart showing:

- Current signal status and how many confirmation candles have formed
- Range zone and Bollinger status
- Market structure labels (bullish, bearish, ranging)
- Moving average positions and touch/cross flags
- Session observation progress
- Fake-out watch status and inter-session momentum context
- Daily extension percentage
- Open trade details (entry, stop, target, current profit)
- Daily trade count and profit/loss summary

---

## Requirements

- MetaTrader 5 (any broker)
- EUR/USD symbol
- 15-minute chart
- The bot file (`.mq5`) compiled and attached to the chart

It is recommended to run on a VPS or dedicated machine to ensure the bot is always connected during trading hours.

---

## Version history

| Version | Key additions |
|---|---|
| v6.30 | HA doji invalidation, M1/M5 tick alignment, HA quality tracking |
| v6.31 | Fixed stale H1 structure labels; CHoCH now actively blocks trades |
| v6.32 | Session observation window extended to 4 bars across all sessions; fake-out detection added |
| v6.33 | Inter-session momentum context; fake-outs classified as HIGH/MEDIUM/CONTINUATION/SESSION REVERSAL |
| v6.34 | M15 MA 200/50/20 filter suite; daily extension cap |
| v6.35 | MA convergence detection; fake-jump guard at MA200 crossings; MA200 boundary stop-limit pending orders |
| v6.36 | MRV (Mean Reversion) trade mode with scaled SL/TP; persistent ATR & Bollinger handles; H4 frequency gating; M1/M5 double-oppose block; peak equity drawdown watermark |
| v6.37 | Per-session trade counters (Asian / London / New York); individual session daily caps |
| v6.38 | Confidence pre-cached at signal arm bar — score is stable from PREPARING through to entry |
| v6.39 | Economic calendar integration; news no-trade zone blocks entries before and after high-impact events |
| v6.40 | Order Block (OB) detection on H1; Fair Value Gap (FVG) detection on M15 and H1; SMC confluence added to confidence scoring |
| v6.41 | HPL (Horizontal Price Level) detection — multi-touch consolidation zones block entries at untested S/R; liquidity sweep detection with confidence bonus |
| v6.42 | HARVESTER (profit-tier slasher) and CHRONO trade management modes; six-mode management suite complete |
| v6.43 | Naive Bayes probabilistic gate (9 features, Laplace-smoothed, retrained every 4 bars); momentum flip fast-entry — one clean HA candle after a direction reversal goes directly to INCOMING; NB direction-flip feature (F8) so the model learns separate win rates for flip vs standard entries |

---

## Architecture

### Overview

The bot has three parallel analytical layers that run on every tick. They do not replace each other — each layer is sensitive to a different kind of signal: pattern timing (HA), setup quality scoring (Confidence), and learned historical context (NB Brain). A trade can only fire when all three agree.

```
MARKET DATA (every tick)
        │
        ├── Price / OHLCV
        ├── M15 bars (confirmed + forming)
        ├── H1 / H4 bars
        └── Tick volume
        │
        ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    PER-BAR PROCESSING  (on new bar)                  │
│                                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌────────────────────────────┐  │
│  │  Structural  │  │  Indicator  │  │    NB BRAIN  (train step)  │  │
│  │  Detectors  │  │  Refresh    │  │                            │  │
│  │             │  │             │  │  BuildAndTrainNBBrain()     │  │
│  │  H1 Swing   │  │  ATR        │  │  ─ last 100 M15 bars       │  │
│  │  H4 Macro   │  │  Bollinger  │  │  ─ 9 features per sample   │  │
│  │  FVG / OB   │  │  MA suite   │  │  ─ label: UP / DOWN / NTRL │  │
│  │  Liq Sweep  │  │  Volume     │  │  ─ Laplace-smoothed NB     │  │
│  │  HPL zones  │  │  Fib/Pivot  │  │  ─ retrain every bar       │  │
│  └──────┬──────┘  └─────────────┘  └────────────────────────────┘  │
│         │                                                            │
│         ▼                                                            │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │             EvaluateHAPattern()                             │    │
│  │                                                             │    │
│  │  bar1 = bottomless (no lower wick) → ARM bull setup        │    │
│  │  bar1 = topless   (no upper wick)  → ARM bear setup        │    │
│  │  Consecutive HA candles + Bollinger gate → PREPARING→INCOMING│   │
│  │                                                             │    │
│  │  NB suppression: if !flip AND NB majority-DOWN → veto BUY  │    │
│  │  NB acceleration: if flip OR NB≥HighThreshold → skip PREP  │    │
│  └──────────────────────────┬──────────────────────────────────┘    │
│                             │ g_Signal = WAITING / PREPARING /       │
│                             │           BUY INCOMING / SELL INCOMING │
└─────────────────────────────┼────────────────────────────────────────┘
                              │
                    PER-TICK  │
                              ▼
        ┌─────────────────────────────────────┐
        │        CalcNBLiveProbs()            │
        │  (runs every tick after new-bar     │
        │   train; cheap: 9 lookups only)     │
        │                                     │
        │  GetNBLiveFeatures():               │
        │    F0  Zone (price vs day range)    │
        │    F1  Session (Asian/Lon/NY/Off)   │
        │    F2  HA direction (bar0+bar1 net) │
        │    F3  Volume state                 │
        │    F4  H1 Structure                 │
        │    F5  3-bar OHLC FVG               │
        │    F6  Order Block (0=none)         │
        │    F7  Liq Sweep (0=none)           │
        │    F8  Direction flip flag          │
        │                                     │
        │  → g_NBBuyProb  (P(UP)  %)          │
        │  → g_NBSellProb (P(DOWN)%)          │
        │  → g_NBPredDir  (+1 / -1 / 0)       │
        └────────────────────────────────────-┘

        ┌─────────────────────────────────────────────────────────────┐
        │  TryEntry() — the gate sequence                             │
        │                                                             │
        │  1. Hard stops (drawdown, daily loss, news, grace)          │
        │  2. Trade timing (session observe, fake-out rebound)        │
        │  3. Structural blocks (MacroBOS, H1 BOS, H1 CHoCH)         │
        │  4. Zone filter (UPPER/LOWER third with override logic)     │
        │  5. MA filter (MA200 hard block / pending; fake-jump guard) │
        │  6. Bias filter (composite of structure + session + MA)     │
        │  7. Volume hard block (LOW/DEAD state)                      │
        │                                                             │
        │  8. CalcConfidence() → score 0–100                         │
        │       - HA pattern quality         (0–15 pts)               │
        │       - Session quality            (0–10 pts)               │
        │       - Zone position              (0–10 pts)               │
        │       - Fib/Pivot confluence       (0–12 pts)               │
        │       - Bias alignment             (±5 pts)                 │
        │       - Range room                 (0–10 pts)               │
        │       - ATR volatility             (0–10 pts)               │
        │       - H1 Swing structure         (±10 pts)                │
        │       - Volume direction           (±15 pts)                │
        │       - Liquidity sweep            (±10 pts)                │
        │       - Order Block proximity      (±7 pts)                 │
        │       - FVG alignment              (±10 pts)                │
        │       - Key-hour proximity bonus   (0–8 pts)                │
        │       - Asian prev-day momentum    (0–6 pts)                │
        │       - MTF (H4+H1) alignment      (0–12 pts)               │
        │       - H4 FVG + OB zones          (±14 pts)                │
        │       - FVG H1/H4 overlap          (0–6 pts)                │
        │       - Real candle alignment      (±6 pts)                 │
        │       - Bollinger headroom         (±3 pts)                 │
        │       if score < MinConfidence → REJECT                     │
        │                                                             │
        │  9. SL/TP sizing → execute market order                     │
        └─────────────────────────────────────────────────────────────┘
```

---

### How the NB Brain and CalcConfidence relate

They answer different questions and are independently consulted:

| Layer | Question answered | When it acts |
|---|---|---|
| **CalcConfidence** | "How many confluences align right now?" | At every entry attempt — additive score across 19 fixed factors |
| **NB Brain** | "Historically, when the market looked like this, what happened next?" | At signal arm time (suppression) and every tick (dashboard / direction bias) |

**CalcConfidence** is a deterministic hand-crafted model. Each factor adds a fixed number of points. It is fast, transparent, and tunable but it has no memory — it scores each setup the same regardless of what has been winning or losing recently.

**NB Brain** learns from the last 100 bars of price action. It builds a statistical table of: given these 9 market conditions, how often did price go UP vs DOWN vs NEUTRAL over the next 2 bars? That memory adapts as market conditions shift — a session full of failed bullish setups will drive P(UP) down without any human intervention.

Neither layer controls the trade alone:
- A high-confidence score cannot override a NB majority-veto (when NB is strongly DOWN and the setup is not a flip).
- A strong NB posterior cannot cause a trade by itself — the full gate sequence in TryEntry must still pass.

---

### Decision flow: WAIT → PREPARING → INCOMING → ENTRY

```
Every bar (new M15 candle closes)
│
├── Train NB on last 100 bars (BuildAndTrainNBBrain)
│
└── EvaluateHAPattern
     │
     ├── bar1 bottomless + dir=BULL?
     │     ├── NB: !flip AND NB majority-DOWN → VETO → signal stays WAITING
     │     ├── flip OR NB ≥ HighThreshold     → DIRECT → BUY INCOMING
     │     └── otherwise                       → PREPARING BUY
     │
     ├── Already PREPARING BUY?
     │     ├── Bollinger gate fails → stay PREPARING
     │     ├── Both real candles bearish → stay PREPARING
     │     └── Bollinger OK + real candles OK → BUY INCOMING
     │
     └── Doji / opposing bar → reset to WAITING

Every tick (between bar closes)
│
├── CalcNBLiveProbs (cheap: classifies current market state)
│
├── If PREPARING + preflight green: watch forming bar
│     └── Live bar body bullish + Bollinger OK → promote → BUY INCOMING
│
└── If BUY INCOMING / SELL INCOMING → TryEntry()
      │
      ├── Hard gates (drawdown, daily loss, grace, news, session) → BLOCK or PASS
      ├── Structural gates (BOS, CHoCH, MacroBOS, MA200) → BLOCK or PASS
      ├── Zone / bias / volume gates → BLOCK or PASS
      ├── CalcConfidence → score < MinConfidence → REJECT; score ≥ min → PASS
      ├── NB audit log (probabilities recorded; no hard block at entry)
      └── SL/TP calculated → Execute market order
```

---

### Signal types and how they differ

The bot recognises three distinct entry modes, each with its own signal path:

| Mode | Trigger | NB role | Confidence gate |
|---|---|---|---|
| **Trend (HA chain)** | 2+ consecutive clean HA candles in same direction with Bollinger confirmation | Suppresses if majority-DOWN/UP (unless flip) | Full 19-factor score required |
| **Mean Reversion (MRV)** | Price at range extreme, HA reversal candle, 5-minute entry window | Not applied | Reduced SL/TP, mid-zone blocked |
| **Macro Trend Ride** | H4 BOS confirmed, H1+H4 MTF aligned, HA momentum aligned | Not applied | Score gate still applies; wider SL, structural TP target |

---

### NB feature definitions (9 features, 3 classes)

| # | Feature | Bins | Source |
|---|---|---|---|
| F0 | Range zone | 3: LOWER / MID / UPPER | Live bid vs day H/L |
| F1 | Session | 4: Asian / London / NY / Off | Server hour |
| F2 | HA direction + streak | 4: strongBear / mildBear / mildBull / strongBull | Forming bar + bar1 net direction |
| F3 | Volume state | 3: Low / Normal / High | Tick volume vs 20-bar avg |
| F4 | H1 Market structure | 3: BEARISH / NEUTRAL / BULLISH | SMA10 vs SMA30 proxy |
| F5 | 3-bar OHLC Fair Value Gap | 3: none / bullish FVG / bearish FVG | `low[0] > high[2]` etc. |
| F6 | Order Block proximity | 3: none / bull OB / bear OB | Always 0 in training (not replayable) |
| F7 | Liquidity sweep | 3: none / bull sweep / bear sweep | Always 0 in training (not replayable) |
| F8 | Direction flip | 2: no / yes | bar1 vs bar2 reversal, OR forming bar vs bar1 |

**Classes:** UP (price rises ≥ ATR×0.9 in next 2 bars) / DOWN / NEUTRAL

Training uses Laplace smoothing so no bin ever has a zero likelihood. The model retrains every bar on the most recent 100 samples, keeping it fresh without needing manual resets.
