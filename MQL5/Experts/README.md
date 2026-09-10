# SMC Tradable-Order-Block EA

A professional MetaTrader 5 Expert Advisor (`SMC_TradableOrderBlock_EA.mq5`) that automates the
**"Tradable vs Non-Tradable Order Blocks"** Smart Money Concepts strategy: multi-timeframe Order Block
detection, the 6 tradability rules, entry, and trade management.

## v2.00 — architecture change

v1 approximated the PDF's higher-timeframe context with a single H4 EMA "bias" filter. That was a
different, weaker idea than what the PDF actually describes — a real **Higher-Timeframe Order Block →
Confirmation-Timeframe Order Block → Entry-Timeframe Order Block** hierarchy — and calling the EA a
"100%" implementation while substituting one for the other was a fair criticism. v2 replaces it: the
detection/validation pipeline is now a class (`COBTimeframeEngine`), instantiated three times (HTF,
Confirmation, Entry). An entry-timeframe OB is only valid if its price zone nests/overlaps a still-active,
valid, same-direction OB on the confirmation timeframe — which itself was only marked valid because *its*
zone nested/overlapped a still-active, valid, same-direction OB on the HTF. That's a genuine transitively-
enforced chain, not three independent filters.

## Strategy rules implemented

**Order Block [OB]**
- Bullish Order Block (BuOB): the last down (bearish) candle at/near Support before an impulsive move up.
- Bearish Order Block (BeOB): the last up (bullish) candle at/near Resistance before an impulsive move down.
- Detected independently on all three timeframes (HTF / Confirmation / Entry).

**Risk-Entry pricing ("wicky" hint)**
| OB type | Not wicky | Wicky |
|---|---|---|
| BuOB | Buy Limit @ candle **High**, SL @ candle **Low** | Buy Limit @ candle **Open**, SL @ candle **Low** |
| BeOB | Sell Limit @ candle **Low**, SL @ candle **High** | Sell Limit @ candle **Open**, SL @ candle **High** |

A candle is "wicky" when the wick on the entry side exceeds `InpWickyRatioThreshold` (default 33%) of
the candle's total range.

**A tradable Entry-timeframe OB must pass every enabled rule:**

1. OB is at/near Support/Resistance.
2. OB is at/near a Flip Zone (a level that previously acted as the opposite S/R type).
3. OB breaks Market Structure (BMS) — enforced by construction.
4. **Imbalance/Liquidity-Void.** The PDF: *"Imbalance is created by 2-3 or more Extended Range Candles
   [ERC]. ERC candle often closes at 80% of the candle range."* This is now implemented literally:
   `IsERC()` flags a candle as an ERC when it closes within `InpERCCloseRatio` (default 80%) of its own
   range in the impulse direction, and `FindERCImbalance()` looks for a run of `InpMinERCCount` (default
   2) *consecutive* ERCs — that run's near edge is the imbalance level. A classic 3-candle Fair Value Gap
   is accepted only as an optional fallback (`InpAllowFVGAsImbalance`), since a single huge displacement
   candle is a valid but different form of "insufficient trading." Either way the imbalance must sit at
   least `InpImbalanceMultiplier` (2×) the OB's risk distance from entry, and the impulse leg must reach
   at least `InpRiskRewardMultiplier` (3×) that distance (used as TP1).
5. **The OB must take out a prior opposing Order Block that was ITSELF valid/tradable** — an opposing OB
   that never passed these rules isn't treated as genuine liquidity worth removing (this was previously
   missing: any recorded opposing OB counted, valid or not).
6. A Bearish OB must sit above, and a Bullish OB below, any Significant Support/Resistance (SSR) level
   that would otherwise obstruct the move to target (a level touched ≥ `InpSSR_MinTouches` times).
7. **HTF confluence** (`InpUseHTFConfluence`): the entry OB's zone must nest/overlap (within
   `InpConfluenceATRMult` × the parent timeframe's ATR) a still-active valid OB on the Confirmation
   timeframe (`InpConfirmationPeriod`, default H1), which itself required the same against the HTF
   (`InpHTFPeriod`, default H4). This is the actual PDF hierarchy — not a moving-average bias filter.

Non-tradable OBs are tracked and can be drawn in a muted color for transparency, but are **never** traded.
Two things remain documented, honest approximations of a discretionary source concept rather than an
exact mechanical replica — flagged as such in the code, not hidden:
- **Rule 6** (`SSRObstructs()`): "no major S/R obstruction between entry and target."
- **Rule 7's overlap tolerance** (`FindAlignedOB()`): "nesting" between timeframes is judged by an
  ATR-scaled zone overlap, since the PDF doesn't give an exact geometric nesting test.

## Intelligent / professional additions on top of the raw strategy

- **Margin-aware position sizing.** A purely pip-risk-based lot size can demand far more margin than the
  account has when an Order Block's stop is very tight (small price-risk ≠ small margin requirement).
  `InpFilterTinyStops`/`InpMinStopPoints` reject unrealistically tight OBs outright, and `CapLotByMargin()`
  additionally caps every order to `InpMaxMarginUsagePercent` of free margin via `OrderCalcMargin()`,
  scaling the lot down (or skipping the trade if even the minimum lot won't fit).
- **Two-target management** — TP1 (3R) triggers a partial close + move to break-even; the runner is then
  ATR-trailed toward TP2 (6R by default), all handled automatically per position via raw ticket-targeted
  `OrderSend()` requests (safe under both netting and hedging accounting — see comments above
  `ModifyPositionByTicket()`/`ClosePartialByTicket()`).
- **Daily loss kill-switch, max concurrent trades, max trades/day, spread filter, session filter.**
- **Pending-order lifecycle management** — auto-expiry, and automatic cancellation of an opposite-side
  pending order the moment a fresh opposite Break of Structure invalidates it.
- **On-chart dashboard, per-timeframe OB visualization (HTF=orange, Confirmation=blue, Entry=green/red),
  SSR levels, alerts & push notifications.**
- Historical context (structure, OBs, SSR levels) is rebuilt independently per timeframe on `OnInit`, so
  the EA has full multi-timeframe context immediately rather than needing to "warm up" live.

## Installation

1. Copy `SMC_TradableOrderBlock_EA.mq5` into your terminal's `MQL5/Experts/` folder
   (in MetaTrader 5: *File → Open Data Folder → MQL5 → Experts*).
2. Restart MetaTrader 5 or right-click **Expert Advisors** in the Navigator and choose **Refresh**.
3. Compile it in MetaEditor (F7) — no external includes beyond the standard `<Trade/Trade.mqh>` are
   required.
4. Drag it onto the ENTRY timeframe chart you want to trade (e.g. M15), enable **Algo Trading**, and set
   `InpHTFPeriod`/`InpConfirmationPeriod` so `HTF > Confirmation > chart period` (e.g. H4 → H1 → M15).
   Review the remaining grouped inputs: General, Structure & OB Detection, Tradable-OB Filters,
   Imbalance/Liquidity-Void, Multi-Timeframe Confluence, Risk Management, Trade Management, Session
   Filter, Visualization & Alerts.

## Notes & disclaimer

Trading forex, commodities, and synthetic indices carries risk. Backtest and forward-test on a demo
account before risking real capital, and size positions according to your own risk tolerance. Because a
tradable OB now has to satisfy structure, location, displacement, liquidity-removal, room-to-target,
*and* a 3-timeframe confluence chain simultaneously, expect materially fewer signals than v1 — that is
the intended tradeoff for fidelity to the source strategy, not a bug.
