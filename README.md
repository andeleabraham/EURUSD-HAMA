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
