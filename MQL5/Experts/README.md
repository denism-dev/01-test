# SMC Tradable-Order-Block EA

A professional MetaTrader 5 Expert Advisor (`SMC_TradableOrderBlock_EA.mq5`) that automates the
**"Tradable vs Non-Tradable Order Blocks"** Smart Money Concepts strategy end-to-end: detection,
6-rule validation, entry, and trade management.

## Strategy rules implemented (from the source methodology)

**Order Block [OB]**
- Bullish Order Block (BuOB): the last down (bearish) candle at/near Support before an impulsive move up.
- Bearish Order Block (BeOB): the last up (bullish) candle at/near Resistance before an impulsive move down.

**Risk-Entry pricing ("wicky" hint)**
| OB type | Not wicky | Wicky |
|---|---|---|
| BuOB | Buy Limit @ candle **High**, SL @ candle **Low** | Buy Limit @ candle **Open**, SL @ candle **Low** |
| BeOB | Sell Limit @ candle **Low**, SL @ candle **High** | Sell Limit @ candle **Open**, SL @ candle **High** |

A candle is "wicky" when the wick on the entry side exceeds `InpWickyRatioThreshold` (default 33%) of
the candle's total range.

**A tradable OB must pass all 6 rules** (each independently toggleable, all ON by default for 100%
strategy fidelity):

1. OB is at/near Support/Resistance.
2. OB is at/near a Flip Zone (a level that previously acted as the opposite S/R type).
3. OB breaks Market Structure (BMS) — enforced by construction (an OB is only ever created off a
   confirmed structure break).
4. Imbalance (Liquidity Void / FVG) formed after the OB is at least `InpImbalanceMultiplier` (default
   2×) the OB's risk distance away from entry, **and** the impulse leg reaches at least
   `InpRiskRewardMultiplier` (default 3×) the OB's risk distance (used as TP1).
5. The OB must take out (mitigate/invalidate) a prior opposing Order Block.
6. A Bearish OB must sit above, and a Bullish OB below, any Significant Support/Resistance (SSR) level
   that would otherwise obstruct the move to target (a level touched ≥ `InpSSR_MinTouches` times).

Non-tradable OBs (failing one or more rules) are tracked and can be drawn in a muted color for full
transparency, but are **never** traded.

## Intelligent / professional additions on top of the raw strategy

- **Higher-timeframe bias filter** — only takes BuOB/BeOB setups aligned with HTF trend (EMA-based).
- **Risk-based position sizing** — lots computed from `% of balance` and the OB's own SL distance.
- **Two-target management** — TP1 (3R) triggers a partial close + move to break-even; the runner is
  then ATR-trailed toward TP2 (6R by default), all handled automatically per position.
- **Daily loss kill-switch, max concurrent trades, max trades/day, spread filter, session filter.**
- **Margin-aware position sizing** — a purely pip-risk-based lot size can demand far more margin than
  the account has when an Order Block's stop is very tight (small price-risk ≠ small margin
  requirement). `InpFilterTinyStops`/`InpMinStopPoints` reject unrealistically tight OBs outright, and
  `CapLotByMargin()` additionally caps every order to `InpMaxMarginUsagePercent` of free margin via
  `OrderCalcMargin()`, scaling the lot down (or skipping the trade if even the minimum lot won't fit)
  instead of sending an order the broker will simply reject as "not enough money".
- **Pending-order lifecycle management** — auto-expiry, and automatic cancellation of an opposite-side
  pending order the moment a fresh opposite Break of Structure invalidates it.
- **On-chart dashboard, OB/SSR visualization, alerts & push notifications.**
- Historical context (structure, OBs, SSR levels) is rebuilt on `OnInit` so the EA has full context
  immediately rather than needing to "warm up" live.

## Installation

1. Copy `SMC_TradableOrderBlock_EA.mq5` into your terminal's `MQL5/Experts/` folder
   (in MetaTrader 5: *File → Open Data Folder → MQL5 → Experts*).
2. Restart MetaTrader 5 or right-click **Expert Advisors** in the Navigator and choose **Refresh**.
3. Compile it in MetaEditor (F7) — no external includes beyond the standard `<Trade/Trade.mqh>` are
   required.
4. Drag it onto a chart, enable **Algo Trading**, and review the inputs (grouped in the UI):
   General, Structure & OB Detection, Tradable-OB Filters, HTF Bias, Risk Management, Trade
   Management, Session Filter, Visualization & Alerts.

## Notes & disclaimer

Trading forex, commodities, and synthetic indices carries risk. Backtest and forward-test on a demo
account before risking real capital, and size positions according to your own risk tolerance. Rule 6
(SSR positioning) is implemented as a documented, best-effort algorithmic approximation of the
strategy's discretionary "obstruction" concept — see the comments above `SSRObstructs()` in the source
for the exact logic.
