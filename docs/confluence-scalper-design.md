# Confluence Scalper — Design Document

## 1. Goal

Most single-signal scalping indicators (a lone RSI, a lone MA cross, a lone
Bollinger touch) win at roughly a coin-flip rate on their own because each
one is only measuring one dimension of price behavior. Historically-durable
scalping edges come from **stacking uncorrelated confirmations** so that a
trade is only taken when several independent, historically-profitable
scalping techniques agree at the same moment:

- Trend-following (moving-average ribbons, VWAP)
- Momentum/mean-reversion timing (RSI, Stochastic RSI, MACD histogram)
- Volatility breakout (Bollinger/Keltner "squeeze" release — the core of the
  classic TTM Squeeze and most breakout-scalping systems)
- Volume/order-flow confirmation (volume spikes, candle-body pressure, a
  cumulative-delta proxy)
- Liquidity & price-action zones (session highs/lows, pivots, prior-day
  high/low, engulfing/pin-bar rejection at those zones)
- Session/time-of-day filtering (only trade during high-liquidity windows)

No single component is novel — each is a well-documented, independently
profitable scalping technique. The design's contribution is the **scoring
and gating layer** that only fires a signal when enough of them line up,
which historically raises win rate and expectancy versus any one technique
alone by cutting the false positives each method produces in isolation.

## 2. Architecture

```
                 ┌─────────────────────────┐
 Price/Volume →  │  Component Detectors     │
                 │  (7 independent modules) │
                 └───────────┬─────────────┘
                              │ each emits: bull_vote, bear_vote, weight
                              ▼
                 ┌─────────────────────────┐
                 │  Confluence Scorer       │  score = Σ(vote × weight) / Σweight × 100
                 └───────────┬─────────────┘
                              │
                              ▼
                 ┌─────────────────────────┐
                 │  Signal Gate             │  requires: score ≥ threshold
                 │                          │            + a timing trigger (crossover,
                 │                          │              not just persistent state)
                 │                          │            + session filter passes
                 └───────────┬─────────────┘
                              │
                              ▼
                 ┌─────────────────────────┐
                 │  Risk Overlay            │  ATR stop, R:R targets,
                 │                          │  max-risk/day, cooldown after loss
                 └─────────────────────────┘
```

## 3. Components and their weights

| # | Component | Historically-known strategy it's drawn from | Bull condition | Weight |
|---|---|---|---|---|
| 1 | EMA ribbon (9/21/50) alignment | Trend-following MA-ribbon scalping | 9 > 21 > 50, price > 9 | 20 |
| 2 | VWAP position | Institutional VWAP scalping | close > session VWAP | 15 |
| 3 | Stochastic RSI cross | Fast mean-reversion timing | %K crosses above %D from oversold (<20) | 15 |
| 4 | MACD histogram slope | Momentum-confirmation scalping | histogram rising and > 0 or turning up from below 0 | 10 |
| 5 | BB/KC squeeze release | TTM Squeeze breakout scalping | Bollinger Bands were inside Keltner Channel (squeeze) and price breaks out with rising BB width | 15 |
| 6 | Volume/pressure confirmation | Volume-spike / order-flow scalping | volume > 1.5× its 20-bar average AND candle closes in top third of its range (buy pressure) | 15 |
| 7 | Liquidity-zone price action | Support/resistance + rejection-candle scalping | price is within an ATR-scaled distance of a pivot low / prior session low / round number AND a bullish rejection candle (pin bar or engulfing) forms | 10 |

Mirror each row for the bear case (inverse conditions). Weights sum to 100
so the score is directly a 0–100 confluence percentage. Weights are
starting values meant to be re-optimized per instrument/timeframe during
the validation phase (Section 6) — they are exposed as inputs in the
implementation, not hard-coded constants.

## 4. Signal gating logic

A raw score crossing a threshold is not itself a tradeable event — it can
stay elevated for many bars. To avoid signal spam, a signal only fires on
the **bar where**:

1. `score >= entry_threshold` (default 70 for a standard signal, 85 for a
   "strong" signal), **and**
2. a timing trigger occurs on that same bar — the Stochastic RSI cross, the
   squeeze-release breakout candle, or price crossing the fast EMA — so the
   signal marks the moment of alignment, not every bar alignment persists,
   and
3. the session filter passes (see Section 5), and
4. no opposite-direction signal fired within the cooldown window (default 5
   bars), to prevent whipsaw flip-flopping in choppy conditions.

Output states: **Strong Buy / Buy / Neutral / Sell / Strong Sell**, plus a
separate **Exit** signal emitted when the score for the open position's
direction drops below 40 or momentum (RSI/MACD) diverges against the
position — this closes trades on deterioration rather than waiting for a
fixed target only.

## 5. Session/time filter

Scalping win rates historically degrade sharply outside high-liquidity
hours (thin books → wider spreads → more noise). The indicator restricts
signals to configurable high-liquidity windows, defaulting to:

- London session: 07:00–10:00 UTC
- New York/London overlap: 12:00–15:00 UTC

Signals occurring outside these windows are suppressed by default (toggle
available for 24h markets like crypto, where this filter can be relaxed or
replaced with a rolling-volume-percentile filter instead of fixed hours).

## 6. Risk management overlay

The indicator is a signal generator, not an execution system — but it
publishes the risk parameters every historically-successful scalping
system relies on so they're visible on the chart, not left to guesswork:

- **Stop loss**: `entry ± 1.2 × ATR(14)`, placed beyond the triggering
  liquidity zone/swing point rather than an arbitrary distance.
- **Take profit**: two targets at 1.5R and 2.5R, with the first partial
  exit at 1.5R to lock in gains (a common scalping practice that improves
  expectancy under high trade frequency).
- **Max risk per trade**: configurable, default 0.5–1% of account equity.
- **Daily loss limit / cooldown**: trading halts for the session after a
  configurable number of consecutive stopped-out trades (default 3), to
  prevent revenge-trading through a bad regime.

## 7. Validation plan (required before live use)

1. **Backtest** across ≥3 instruments and ≥2 timeframes (e.g., 1m/5m) over
   at least 2 years of data, including at least one high-volatility and one
   low-volatility regime.
2. **Walk-forward optimization** of the component weights and thresholds —
   optimize on a rolling in-sample window, validate out-of-sample, to avoid
   curve-fitting to one historical period.
3. **Metrics tracked**: win rate, profit factor, expectancy per trade, max
   drawdown, average trade duration, signal frequency, and score-vs-outcome
   correlation (to confirm higher-score signals actually win more often —
   if they don't, the weights need retuning).
4. **Paper trade** for a minimum sample size (≥100 signals) before
   committing real capital, then scale in with reduced size for another
   ≥100 trades before full sizing.

## 8. Reference implementation

`indicators/confluence_scalper.pine` — a TradingView Pine Script v5
**strategy** (not a plain indicator) implementing all seven components, the
scoring/gating logic, real bracket orders (stop + two take-profit legs),
an on-chart confluence table, and alert conditions for Strong Buy / Buy /
Strong Sell / Sell.

Because it is a `strategy()` script, TradingView's Strategy Tester reports
real win rate, profit factor, average win/loss, and max drawdown from
actual filled orders — not from a persistent-state proxy. A second on-chart
table computes the breakdowns Strategy Tester doesn't give you natively:
TP1 vs TP2 vs stop-loss hit rate, long vs short win rate, and P/L by
session (London / NY overlap / other), by replaying `strategy.closedtrades`
and matching each closed trade back to the direction/session recorded at
its entry.

Key configurable behaviors, added after an initial indicator-only draft was
reviewed and found to only *look* like a signal generator with backtestable
claims attached, without actually producing any of them:

- **Signal Evaluation** (Closed Bar / Intrabar) — Closed Bar avoids
  repainting by only evaluating signals on a confirmed bar.
- **Require price-action confirmation** — forces at least the volume or
  liquidity-zone component to agree, so a signal can't clear the score
  threshold on trend/momentum/squeeze alone.
- **Same-direction vs opposite-direction cooldowns** — kept separate so
  clustered same-direction signals from one sustained move aren't
  miscounted as independent trades.
- **Fast triggers toggle** — off by default, because using the Stoch-RSI
  cross or squeeze release as *both* the timing trigger and a scored
  component double-counts that evidence; documented in-line rather than
  silently left in.
- **Timezone-aware sessions** — London/NY windows are defined against IANA
  timezones so they stay aligned through DST rather than drifting against
  fixed UTC offsets.

## 9. Round-2 fixes (from a second review pass)

A second review of the strategy conversion caught issues in how it measured
itself, not just in the trading logic:

- **Intrabar mode was a dead toggle.** `calc_on_every_tick` was left `false`,
  so TradingView only recalculated the script at bar close regardless of
  the "Evaluate on" setting. Now `calc_on_every_tick = true` at the
  strategy level, so Intrabar mode actually recalculates every tick. Note
  this makes Intrabar mode a forward/live-testing option, not an
  equivalent historical backtest mode — historical bars can't fully
  reproduce realtime tick sequencing. Closed Bar mode is unaffected, since
  it's still gated to the bar-close tick regardless.
- **SL/TP were computed from the signal bar's close, not the actual fill.**
  A market order fills on the next available price the broker emulator
  sees, not the signal candle's close, so the original R-multiples drifted
  from what was configured. ATR is now captured at signal time but the
  stop/target prices are computed from `strategy.position_avg_price` once
  the fill is confirmed.
- **The TP1/TP2/SL stats table couldn't actually tell a stop-out from a
  target hit.** Both exit legs shared a stop price under the same order
  IDs ("TP1"/"TP2"), and no exit order was ever named "SL" — so
  `exit_id == "SL"` never matched anything and stop-outs were silently
  counted as target hits. Fixed using `comment_profit`/`comment_loss` on
  each `strategy.exit()` call and reading `strategy.closedtrades.exit_comment()`
  instead of `exit_id()`.
- **A deeper version of the same bug**: because TP1 and TP2 are separate
  `strategy.exit()` calls, a single logical trade produces *two* rows in
  `strategy.closedtrades` (one per leg) — so index-matching entries 1:1
  against closed-trade rows (the original approach) was wrong regardless of
  the id/comment issue. Fixed by attributing every newly-closed row
  incrementally to whichever entry is currently open, rather than assuming
  a fixed row count per entry.
- **"Max Drawdown" was actually current drawdown-from-peak** — it read 0%
  right after any new equity high, understating a strategy that dropped
  20% and later recovered. Now tracks a running maximum across the whole
  test.
- **No slippage was modeled**, only commission. Added a slippage (ticks)
  input on the strategy declaration.
- **The London/NY-overlap session tag was structured as if the two windows
  could coincide**; given the configured local-time windows they can't, so
  the compound case was dead logic. Simplified to two mutually exclusive
  tags.

## 10. This is not the same strategy as the first draft — test both

Hardening the indicator-only draft into a strategy also changed what it
trades, not just how it's measured: the default timing trigger narrowed
from "EMA cross OR Stoch cross OR squeeze release" to EMA-cross-only
(`useFastTriggers = false`), and `requireConfirmation = true` now demands
zone or volume support that the original never required. Both are
defensible tightening, but treat this as a new strategy to validate, not a
transparent instrumentation of the old one — run both configurations and
compare rather than assuming the tightened version is better:

| Input | Baseline (reproduces the original concept) | Experimental (hardened defaults) |
|---|---|---|
| Entry Score Threshold | 70 | 70 |
| Require price-action confirmation | OFF | ON |
| Allow Stoch/squeeze as timing triggers | ON | OFF |
| Same-direction cooldown | 0 | 3 |
| Opposite-direction cooldown | 5 | 5 |
| Signal Evaluation | Closed Bar | Closed Bar |

## 11. Known limitations / what's still unverified

- The script has not been compiled or run in TradingView's Pine Editor —
  syntax and runtime behavior (especially the paired-`strategy.exit`
  bracket pattern for TP1/TP2 sharing one stop, and whether
  `strategy.close()`'s `comment` argument surfaces through
  `exit_comment()` the way the Confluence/Other bucket assumes) should be
  verified there before trusting any output.
- No backtest has been run. Nothing in this document or the code is
  evidence the strategy is profitable — that can only come from running it
  per the validation plan in Section 7, across multiple instruments,
  timeframes, and regimes, with walk-forward re-optimization of the
  component weights, and with the baseline-vs-experimental comparison in
  Section 10 run before trusting that the hardening actually helped.
- The by-entry P&L attribution assumes `pyramiding = 0` (one open position
  at a time), so every closed-trade row can be unambiguously attributed to
  "whichever entry is currently open." If pyramiding is ever enabled, this
  would need per-trade IDs instead of the current single `currentEntryIdx`.
