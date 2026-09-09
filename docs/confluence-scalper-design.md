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
indicator implementing all seven components, the scoring/gating logic, an
on-chart confluence table, plotted stop/target levels, and alert
conditions for Strong Buy / Buy / Strong Sell / Sell / Exit.
