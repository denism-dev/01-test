//+------------------------------------------------------------------+
//|           MasterSRConfluenceIndicator_v2_52_VolAdaptive.mq5       |
//| Master S/R indicator with clean dashboard, de-dup signals,        |
//| closed-candle confirmation, and EA-ready buffers.                  |
//|                                                                     |
//| v2.5 fixes over v2.4 CleanZones:                                   |
//|  1. All distance thresholds are ATR-scaled (with a pip floor)      |
//|     instead of fixed pip constants, so behaviour adapts to the     |
//|     instrument/timeframe's actual volatility.                      |
//|  2. Zones are persistent objects (not rebuilt from scratch every   |
//|     bar): touch weight decays over time, and a broken zone rolls   |
//|     into a role-reversed zone on the opposite side instead of      |
//|     being forgotten or silently re-validated.                      |
//|  3. Zone bounds are derived from the dispersion of the touches     |
//|     that formed them (with a floor), not a fixed half-width.       |
//|  4. Every scoring weight is an input, so it can be optimized per   |
//|     symbol/timeframe in the Strategy Tester rather than trusted    |
//|     as a hardcoded magic number.                                   |
//|  5. The trend filter normalizes momentum by ATR and applies a      |
//|     deadband, instead of reacting to raw price-difference noise.   |
//|  6. The missing-rejection-candle penalty is a configurable,        |
//|     softer default so a strong zone/trend confluence isn't vetoed  |
//|     by the absence of a single-candle wick.                        |
//|                                                                    |
//| v2.51 follow-up fixes (review of the v2.50 defaults/lifecycle):    |
//|  7. Historical load now REPLAYS decay/break/role-reversal          |
//|     bar-by-bar over the lookback window instead of bulk-seeding    |
//|     zones and validating them once against only the latest closed  |
//|     price -- a level broken 100 bars ago no longer comes back as   |
//|     "valid" just because price later drifted back inside its old   |
//|     bounds.                                                        |
//|  8. ATR multiplier defaults are recalibrated against a ~12-pip     |
//|     ATR14 M15-major reference so v2.51 reproduces roughly v2.40's  |
//|     fixed-pip behaviour under "normal" conditions, instead of      |
//|     being quietly tighter until ATR reaches ~27-29 pips. Still a   |
//|     starting point, not a backtested value -- validate per         |
//|     symbol/timeframe.                                              |
//|  9. CSV logs are per-symbol+timeframe by default, and opened with  |
//|     FILE_SHARE_WRITE, so running this on several charts at once    |
//|     (e.g. EURUSD/GBPUSD/USDJPY/USDCHF/AUDUSD/NZDUSD simultaneously) |
//|     can't collide on one shared filename (the old ERR 5004 case).  |
//+------------------------------------------------------------------+
#property strict
#property version   "2.52"
#property indicator_chart_window
#property indicator_plots   6
#property indicator_buffers 15

//--- Plot 0: Buy signal
#property indicator_label1  "BuySignal"
#property indicator_type1   DRAW_ARROW
#property indicator_width1  1

//--- Plot 1: Sell signal
#property indicator_label2  "SellSignal"
#property indicator_type2   DRAW_ARROW
#property indicator_width2  1

//--- Plot 2-5: nearest S/R boundaries
#property indicator_label3  "SupportLow"
#property indicator_type3   DRAW_NONE
#property indicator_style3  STYLE_DOT
#property indicator_width3  1

#property indicator_label4  "SupportHigh"
#property indicator_type4   DRAW_NONE
#property indicator_style4  STYLE_SOLID
#property indicator_width4  1

#property indicator_label5  "ResistanceLow"
#property indicator_type5   DRAW_NONE
#property indicator_style5  STYLE_SOLID
#property indicator_width5  1

#property indicator_label6  "ResistanceHigh"
#property indicator_type6   DRAW_NONE
#property indicator_style6  STYLE_DOT
#property indicator_width6  1

//============================== INPUTS ===============================
input int      LookbackBars                 = 250;
input int      SwingLeft                    = 3;
input int      SwingRight                   = 3;

//--- Fix #1 (v2.50) + Fix #8 (v2.51): volatility normalization. Every
//    *ATRMult input scales the threshold as a fraction of current ATR;
//    the matching *Pips input is only a floor for very low-volatility
//    symbols/timeframes so zones never collapse to (near) zero width.
//    Multipliers are calibrated so that at a ~12-pip ATR14 reading (a
//    typical M15 major) each threshold lands close to v2.40's old fixed
//    pip default (10 / 4 / 2.5 / 8 / 12 / 12 respectively) -- so v2.51
//    behaves like v2.40 under "normal" conditions and adapts away from
//    it as volatility moves. This is a calibration starting point, not
//    a backtested value: validate per symbol/timeframe before trusting it.
input int      ATRPeriod                    = 14;
input double   MergeDistanceATRMult         = 0.83;
input double   MinMergeDistancePips         = 4.0;
input double   ZoneHalfWidthATRMult         = 0.33;
input double   MinZoneHalfWidthPips         = 2.0;
input double   BreakInvalidationATRMult     = 0.21;
input double   MinBreakInvalidationPips     = 1.0;
input double   SignalNearZoneATRMult        = 0.67;
input double   MinSignalNearZonePips        = 3.0;
input double   SignalResetDistanceATRMult   = 1.00;
input double   MinSignalResetDistancePips   = 5.0;
input double   MinRoomATRMult               = 1.00;
input double   MinRoomPips                  = 6.0;

input int      MaxSupportZonesToDraw        = 3;
input int      MaxResistanceZonesToDraw     = 3;

input int      TestedMinTouches             = 2;
input int      VerifiedMinTouches           = 3;

//--- Fix #2: persistent zones — touch weight decays each bar instead of
//    treating a 250-bar-old touch identically to a fresh one, a broken
//    zone can roll into a role-reversed zone, and stale zones expire.
input double   TouchDecayPerBar             = 0.996;
input double   MinRelevantScore             = 0.5;
input bool     EnableRoleReversal           = true;
input double   ReversalScoreFactor          = 0.5;
input double   PruneAgeMultiplier           = 1.5;

input int      FastMAPeriod                 = 5;
input int      SlowMAPeriod                 = 20;
input int      MomentumPeriod               = 8;
input int      BreakoutLookback              = 20;

//--- Fix #5: trend filter normalized by ATR with a deadband so tiny
//    momentum noise near zero doesn't swing the score by a full point.
input double   TrendMAAgreeBonus            = 1.0;
input double   TrendMomentumBonus           = 1.0;
input double   MomentumATRDeadband          = 0.05;

input double   MinimumScoreToSignal         = 6.0;   // out of 10
input bool     RequireRejectionCandle       = true;
input double   RejectionWickRatio           = 1.0;

//--- Fix #4: score weights are inputs so they can be optimized per
//    symbol/timeframe instead of trusted as hardcoded constants.
input double   ScoreRangePositionBonus      = 2.0;
input double   ScoreTrendAgreeBonus         = 2.0;
input double   ScoreTrendDisagreePenalty    = -1.0;
input double   ScoreRejectionBonus          = 2.0;
//--- Fix #6: softened default (was -2.0) so absence of a rejection wick
//    doesn't by itself veto an otherwise strong confluence setup.
input double   ScoreRejectionMissingPenalty = -1.0;
input double   ScoreBreakoutBonus           = 1.0;
input double   ScoreTightRoomPenalty        = -1.0;
// Fix: ScoreTightRoomPenalty only ever nudges the score down by a point --
// a signal scoring well on trend/rejection/strength can still clear
// MinimumScoreToSignal despite a near-zero gap between support and
// resistance, where the fixed 5p/6p/8p/10p targets stop meaning "reached
// the opposite zone" and start meaning "broke through the very zone that
// justified the trade." RequireAdequateRoom makes that a hard veto instead
// of a soft penalty, using the same MinRoomDistance() threshold.
input bool     RequireAdequateRoom          = true;

input bool     ConfirmOnClosedCandle        = true;

// de-dup / setup reset
input int      MaxBarsLocked                = 12;    // safety reset after N bars

input bool     DrawZoneRectangles           = true;
input bool     DrawDashboard                = true;

input bool     EnableCSVSignalLog           = true;
input bool     LogToCommonFolder            = true;
input string   SignalLogFileName            = "MasterSR_v2_52_VolAdaptive_Signals.csv";
input bool     EnableClosedBarSnapshotLog    = true;
input string   SnapshotLogFileName           = "MasterSR_v2_52_VolAdaptive_Snapshots.csv";

//============================== BUFFERS ==============================
// EA-facing contract (v2.4 buffers 0-13 unchanged; 14 added in v2.51):
//  0 BuySignal             price or EMPTY_VALUE
//  1 SellSignal            price or EMPTY_VALUE
//  2 SupportLow
//  3 SupportHigh
//  4 ResistanceLow
//  5 ResistanceHigh
//  6 SupportStrength       0..3
//  7 ResistanceStrength    0..3
//  8 RangePosition         0..100, -1 if unavailable
//  9 TrendScore           -2..+2
// 10 BuyScore              0..10
// 11 SellScore             0..10
// 12 Decision              +1 BUY, -1 SELL, 0 WAIT
// 13 ZoneState             +1 near support, -1 near resistance, 0 neither
// 14 SignalNearZoneDistance  price units (divide by pip size for pips) --
//    the live ATR-scaled threshold ComputeScores()/ZoneState actually used
//    for "near zone" this bar. Exists so an external tracker/EA can judge
//    zone proximity against the SAME threshold the indicator used, instead
//    of guessing with its own hardcoded pip constant that drifts out of
//    sync as ATR moves.
double BuySignalBuffer[];
double SellSignalBuffer[];
double SupportLowBuffer[];
double SupportHighBuffer[];
double ResistanceLowBuffer[];
double ResistanceHighBuffer[];
double SupportStrengthBuffer[];
double ResistanceStrengthBuffer[];
double RangePositionBuffer[];
double TrendScoreBuffer[];
double BuyScoreBuffer[];
double SellScoreBuffer[];
double DecisionBuffer[];
double ZoneStateBuffer[];
double SignalNearZoneBuffer[];

//============================== TYPES ===============================
enum ENUM_MASTER_ZONE_STATE
{
   MASTER_ZONE_NONE     = 0,
   MASTER_ZONE_FRESH    = 1,
   MASTER_ZONE_TESTED   = 2,
   MASTER_ZONE_VERIFIED = 3,
   MASTER_ZONE_BROKEN   = 4,
   MASTER_ZONE_EXPIRED  = 5
};

struct MasterZone
{
   double low;
   double high;
   double center;
   int    touches;         // raw lifetime touch count, for display/logging
   double touch_score;     // time-decayed weight, drives state classification
   bool   valid;
   bool   support;
   ENUM_MASTER_ZONE_STATE state;
   datetime first_time;
   datetime last_touch;
   bool   was_reversed;    // true if this zone was created by a role-reversal flip
};

MasterZone g_supports[];
MasterZone g_resistances[];

string   g_prefix = "MSR25_";
datetime g_last_bar_time = 0;
datetime g_last_logged_bar = 0;
int      g_last_logged_dir = 0;
datetime g_last_snapshot_bar = 0;
datetime g_buy_lock_time = 0;
datetime g_sell_lock_time = 0;
// de-dup state
bool     g_buy_locked = false;
bool     g_sell_locked = false;
double   g_last_buy_zone = 0.0;
double   g_last_sell_zone = 0.0;
int      g_buy_lock_bars = 0;
int      g_sell_lock_bars = 0;

// ATR state (fix #1)
int      g_atr_handle = INVALID_HANDLE;
double   g_atr_buffer[];
double   g_atr_value = 0.0;

//============================== HELPERS ==============================
double PipSize()
{
   if(_Digits == 3 || _Digits == 5)
      return _Point * 10.0;
   return _Point;
}

// Fix #7: refreshes g_atr_value from the bar at `shift`. Called both for
// the live path (shift=1, the last closed bar) and, bar-by-bar, during
// history replay -- so every distance threshold reflects the volatility
// that was actually current at the point being processed, not today's
// ATR retroactively applied to old pivots.
void UpdateATR(const int shift)
{
   if(CopyBuffer(g_atr_handle, 0, shift, 1, g_atr_buffer) > 0)
      g_atr_value = g_atr_buffer[0];
}

//--- ATR-scaled distance helpers (fix #1). Each takes the larger of the
//    ATR-derived value and its pip floor, so behaviour degrades gracefully
//    for symbols/timeframes with very low or not-yet-available ATR.
double MergeDistance()
{
   return MathMax(MinMergeDistancePips * PipSize(), g_atr_value * MergeDistanceATRMult);
}

double MinZoneHalfWidth()
{
   return MathMax(MinZoneHalfWidthPips * PipSize(), g_atr_value * ZoneHalfWidthATRMult);
}

double BreakInvalidationDistance()
{
   return MathMax(MinBreakInvalidationPips * PipSize(), g_atr_value * BreakInvalidationATRMult);
}

double SignalNearZoneDistance()
{
   return MathMax(MinSignalNearZonePips * PipSize(), g_atr_value * SignalNearZoneATRMult);
}

double SignalResetDistance()
{
   return MathMax(MinSignalResetDistancePips * PipSize(), g_atr_value * SignalResetDistanceATRMult);
}

double MinRoomDistance()
{
   return MathMax(MinRoomPips * PipSize(), g_atr_value * MinRoomATRMult);
}

double ArrowOffset()
{
   return MathMax(1.0 * PipSize(), g_atr_value * 0.05);
}

ENUM_MASTER_ZONE_STATE StateFromScore(const double score)
{
   if(score >= VerifiedMinTouches) return MASTER_ZONE_VERIFIED;
   if(score >= TestedMinTouches)   return MASTER_ZONE_TESTED;
   return MASTER_ZONE_FRESH;
}

int StateStrength(const ENUM_MASTER_ZONE_STATE state)
{
   if(state == MASTER_ZONE_VERIFIED) return 3;
   if(state == MASTER_ZONE_TESTED)   return 2;
   if(state == MASTER_ZONE_FRESH)    return 1;
   return 0;
}

string StateName(const ENUM_MASTER_ZONE_STATE state)
{
   if(state == MASTER_ZONE_VERIFIED) return "Verified";
   if(state == MASTER_ZONE_TESTED)   return "Tested";
   if(state == MASTER_ZONE_FRESH)    return "Fresh";
   if(state == MASTER_ZONE_BROKEN)   return "Broken";
   if(state == MASTER_ZONE_EXPIRED)  return "Expired";
   return "None";
}

string ZoneLabel(const MasterZone &zone)
{
   return StateName(zone.state) + (zone.was_reversed ? " [flip]" : "");
}

bool SameZone(const double a, const double b)
{
   if(a == 0.0 || b == 0.0)
      return false;

   return MathAbs(a - b) <= MergeDistance();
}

//============================== SWINGS ===============================
bool IsSwingLow(const double &low[], const int index, const int rates_total)
{
   if(index - SwingLeft < 0) return false;
   if(index + SwingRight >= rates_total) return false;

   const double value = low[index];

   for(int k = 1; k <= SwingLeft; k++)
      if(low[index-k] <= value) return false;

   for(int k = 1; k <= SwingRight; k++)
      if(low[index+k] < value) return false;

   return true;
}

bool IsSwingHigh(const double &high[], const int index, const int rates_total)
{
   if(index - SwingLeft < 0) return false;
   if(index + SwingRight >= rates_total) return false;

   const double value = high[index];

   for(int k = 1; k <= SwingLeft; k++)
      if(high[index-k] >= value) return false;

   for(int k = 1; k <= SwingRight; k++)
      if(high[index+k] > value) return false;

   return true;
}

//============================== ZONES ================================
// Fix #2 + #3: zones are persistent (never wiped wholesale). A touch
// either merges into the nearest existing zone -- expanding its bounds to
// actually cover the touch, floored by MinZoneHalfWidth() -- or seeds a
// new zone. touch_score (not the raw touch count) drives the state, so
// callers must run DecayZones() once per bar to age it.
void RegisterTouch(MasterZone &zones[],
                   const double price,
                   const bool support,
                   const datetime touch_time)
{
   const double merge_distance = MergeDistance();
   const double min_half_width = MinZoneHalfWidth();

   const int count = ArraySize(zones);
   int best_index = -1;
   double best_distance = DBL_MAX;

   for(int i = 0; i < count; i++)
   {
      if(!zones[i].valid) continue;

      const double distance = MathAbs(zones[i].center - price);

      if(distance <= merge_distance && distance < best_distance)
      {
         best_distance = distance;
         best_index = i;
      }
   }

   if(best_index >= 0)
   {
      const double old_weight = MathMax(zones[best_index].touch_score, 0.0001);

      zones[best_index].center =
         ((zones[best_index].center * old_weight) + price) / (old_weight + 1.0);

      // Fix #3: bounds cover the true dispersion of touches, not a fixed
      // half-width blind to how far apart the merged pivots actually were.
      zones[best_index].low  = MathMin(zones[best_index].low,  price);
      zones[best_index].high = MathMax(zones[best_index].high, price);
      zones[best_index].low  = MathMin(zones[best_index].low,  zones[best_index].center - min_half_width);
      zones[best_index].high = MathMax(zones[best_index].high, zones[best_index].center + min_half_width);

      zones[best_index].touches++;
      zones[best_index].touch_score += 1.0;
      zones[best_index].valid = true;
      zones[best_index].state = StateFromScore(zones[best_index].touch_score);
      zones[best_index].last_touch = touch_time;
      return;
   }

   ArrayResize(zones, count + 1);

   zones[count].center = price;
   zones[count].low = price - min_half_width;
   zones[count].high = price + min_half_width;
   zones[count].touches = 1;
   zones[count].touch_score = 1.0;
   zones[count].valid = true;
   zones[count].support = support;
   zones[count].state = MASTER_ZONE_FRESH;
   zones[count].first_time = touch_time;
   zones[count].last_touch = touch_time;
   zones[count].was_reversed = false;
}

// Fix #2: exponential decay of touch weight, applied once per closed bar.
// A zone whose weight decays below MinRelevantScore is expired (distinct
// from Broken -- nothing invalidated it, it just aged out of relevance),
// so a 250-bar-old touch no longer counts the same as a fresh one.
void DecayZones(MasterZone &zones[])
{
   // Decay applies to every zone, including already-invalid (Broken) ones --
   // otherwise a zone that broke while still highly scored would freeze at
   // that score forever and never become eligible for PruneStaleZones().
   for(int i = 0; i < ArraySize(zones); i++)
   {
      zones[i].touch_score *= TouchDecayPerBar;

      if(!zones[i].valid)
         continue;

      zones[i].state = StateFromScore(zones[i].touch_score);

      if(zones[i].touch_score < MinRelevantScore)
      {
         zones[i].valid = false;
         zones[i].state = MASTER_ZONE_EXPIRED;
      }
   }
}

// Fix #2: instead of a full rebuild of the lookback window every bar, only
// the single newly-confirmable pivot is checked. Using index = SwingLeft+1
// (rather than SwingLeft) guarantees only already-closed bars (index >= 1)
// feed the swing test, so the zone structure never depends on the
// currently-forming bar's price.
void UpdateZonesIncremental(const double &high[],
                            const double &low[],
                            const datetime &time[],
                            const int rates_total)
{
   const int index = SwingLeft + 1;

   if(index + SwingRight >= rates_total)
      return;

   if(IsSwingLow(low, index, rates_total))
      RegisterTouch(g_supports, low[index], true, time[index]);

   if(IsSwingHigh(high, index, rates_total))
      RegisterTouch(g_resistances, high[index], false, time[index]);
}

// Fix #2: role reversal. A broken support doesn't just vanish -- classic
// S/R theory treats a decisively broken level as flipping sides, so it is
// carried into the opposite zone list with reduced credibility
// (ReversalScoreFactor) rather than being forgotten or silently
// re-validated once price drifts back inside the old bounds.
void RegisterReversedZone(MasterZone &target_zones[],
                          const MasterZone &broken_zone,
                          const datetime bar_time)
{
   RegisterTouch(target_zones, broken_zone.center, !broken_zone.support, bar_time);

   const int count = ArraySize(target_zones);

   for(int i = 0; i < count; i++)
   {
      if(target_zones[i].valid &&
         MathAbs(target_zones[i].center - broken_zone.center) <= MergeDistance() &&
         target_zones[i].touches == 1)
      {
         target_zones[i].touch_score = MathMax(broken_zone.touch_score * ReversalScoreFactor, 0.5);
         target_zones[i].state = StateFromScore(target_zones[i].touch_score);
         target_zones[i].was_reversed = true;
         break;
      }
   }
}

void InvalidateAndReverseZones(const double close_price, const datetime bar_time)
{
   const double buffer = BreakInvalidationDistance();

   for(int i = 0; i < ArraySize(g_supports); i++)
   {
      if(!g_supports[i].valid)
         continue;

      if(close_price < g_supports[i].low - buffer)
      {
         g_supports[i].valid = false;
         g_supports[i].state = MASTER_ZONE_BROKEN;

         if(EnableRoleReversal)
            RegisterReversedZone(g_resistances, g_supports[i], bar_time);
      }
   }

   for(int i = 0; i < ArraySize(g_resistances); i++)
   {
      if(!g_resistances[i].valid)
         continue;

      if(close_price > g_resistances[i].high + buffer)
      {
         g_resistances[i].valid = false;
         g_resistances[i].state = MASTER_ZONE_BROKEN;

         if(EnableRoleReversal)
            RegisterReversedZone(g_supports, g_resistances[i], bar_time);
      }
   }
}

// Bounds memory growth by dropping long-invalid zones once they're both
// old and decayed away. Currently-valid zones are never pruned here --
// they either stay relevant or expire via DecayZones() first.
void PruneStaleZones(MasterZone &zones[], const datetime current_time)
{
   const long max_age_seconds =
      (long)LookbackBars * (long)PeriodSeconds(_Period) * (long)MathMax(PruneAgeMultiplier, 1.0);

   for(int i = ArraySize(zones) - 1; i >= 0; i--)
   {
      if(zones[i].valid)
         continue;

      const bool aged_out = (current_time - zones[i].last_touch) > max_age_seconds;
      const bool decayed_out = zones[i].touch_score < MinRelevantScore;

      if(aged_out && decayed_out)
      {
         for(int k = i; k < ArraySize(zones) - 1; k++)
            zones[k] = zones[k+1];

         ArrayResize(zones, ArraySize(zones) - 1);
      }
   }
}

// Fix #7 (v2.51) + confirmation-lag fix (v2.52): one-time history load on
// prev_calculated==0, replaying the exact bar-by-bar pipeline the live path
// uses -- decay, then swing confirmation, then invalidation (with
// role-reversal) and pruning -- using the ATR that was actually current at
// each historical bar, instead of bulk-clustering every historical swing
// and validating the result once against only the latest closed price.
//
// Confirmation timing matters here and was wrong in the first version of
// this replay: UpdateZonesIncremental() only ever checks relative index
// SwingLeft+1, i.e. live operation doesn't learn that bar P was a swing
// pivot until SwingLeft MORE bars have closed after P. The loop below
// tracks that explicitly with two indices -- `now_index` (simulated
// "present", walked forward from the oldest bar down to the true present
// at 1, so every closed bar gets its own decay/invalidate/prune pass, none
// skipped at the tail) and `pivot_index = now_index + SwingLeft` (the bar
// whose swing status becomes knowable at that "present" moment) -- so a
// pivot is never merged, decayed, or eligible to break/reverse before the
// bars that actually confirm it have closed, matching live timing exactly.
void ReplayHistoryZones(const double &high[],
                        const double &low[],
                        const double &close[],
                        const datetime &time[],
                        const int rates_total)
{
   ArrayResize(g_supports, 0);
   ArrayResize(g_resistances, 0);

   const int max_pivot_index = MathMin(LookbackBars, rates_total - SwingRight - 2);
   const int start_now = max_pivot_index - SwingLeft;

   if(start_now < 1)
   {
      UpdateATR(1);
      return;
   }

   for(int now_index = start_now; now_index >= 1; now_index--)
   {
      UpdateATR(now_index);

      DecayZones(g_supports);
      DecayZones(g_resistances);

      const int pivot_index = now_index + SwingLeft;

      if(IsSwingLow(low, pivot_index, rates_total))
         RegisterTouch(g_supports, low[pivot_index], true, time[pivot_index]);

      if(IsSwingHigh(high, pivot_index, rates_total))
         RegisterTouch(g_resistances, high[pivot_index], false, time[pivot_index]);

      InvalidateAndReverseZones(close[now_index], time[now_index]);
      PruneStaleZones(g_supports, time[now_index]);
      PruneStaleZones(g_resistances, time[now_index]);
   }

   // The loop's last iteration (now_index == 1) already left g_atr_value,
   // and the zone set, exactly where the live path would leave them after
   // processing the current latest closed bar -- nothing further to do.
}

bool FindNearestSupport(const double price, MasterZone &result)
{
   bool found = false;
   double best_distance = DBL_MAX;

   for(int i = 0; i < ArraySize(g_supports); i++)
   {
      if(!g_supports[i].valid) continue;
      if(g_supports[i].high > price) continue;

      const double distance = price - g_supports[i].high;

      if(distance < best_distance)
      {
         best_distance = distance;
         result = g_supports[i];
         found = true;
      }
   }

   return found;
}

bool FindNearestResistance(const double price, MasterZone &result)
{
   bool found = false;
   double best_distance = DBL_MAX;

   for(int i = 0; i < ArraySize(g_resistances); i++)
   {
      if(!g_resistances[i].valid) continue;
      if(g_resistances[i].low < price) continue;

      const double distance = g_resistances[i].low - price;

      if(distance < best_distance)
      {
         best_distance = distance;
         result = g_resistances[i];
         found = true;
      }
   }

   return found;
}

//=========================== TREND / REJECTION =======================
double SimpleMA(const double &close[],
                const int index,
                const int period,
                const int rates_total)
{
   if(period <= 0) return EMPTY_VALUE;
   if(index + period > rates_total) return EMPTY_VALUE;

   double sum = 0.0;

   for(int k = 0; k < period; k++)
      sum += close[index+k];

   return sum / period;
}

double PriceMomentum(const double &close[],
                     const int index,
                     const int period,
                     const int rates_total)
{
   if(index + period >= rates_total)
      return 0.0;

   return close[index] - close[index+period];
}

bool BullishRejection(const double &open[],
                      const double &high[],
                      const double &low[],
                      const double &close[],
                      const int index)
{
   double body = MathAbs(close[index] - open[index]);
   if(body < _Point) body = _Point;

   const double lower_wick =
      MathMin(open[index], close[index]) - low[index];

   return (close[index] > open[index] &&
           lower_wick >= body * RejectionWickRatio);
}

bool BearishRejection(const double &open[],
                      const double &high[],
                      const double &low[],
                      const double &close[],
                      const int index)
{
   double body = MathAbs(close[index] - open[index]);
   if(body < _Point) body = _Point;

   const double upper_wick =
      high[index] - MathMax(open[index], close[index]);

   return (close[index] < open[index] &&
           upper_wick >= body * RejectionWickRatio);
}

//============================= SCORE ================================
double ClampScore(const double score)
{
   return MathMax(0.0, MathMin(10.0, score));
}

void ComputeScores(const double &open[],
                   const double &high[],
                   const double &low[],
                   const double &close[],
                   const int rates_total,
                   const int bar,
                   const MasterZone &support,
                   const bool has_support,
                   const MasterZone &resistance,
                   const bool has_resistance,
                   const double range_position,
                   const double trend_score,
                   double &buy_score,
                   double &sell_score)
{
   buy_score = 0.0;
   sell_score = 0.0;

   const double near_distance = SignalNearZoneDistance();

   const bool near_support =
      has_support && (close[bar] - support.high) <= near_distance;

   const bool near_resistance =
      has_resistance && (resistance.low - close[bar]) <= near_distance;

   if(near_support)
   {
      buy_score += StateStrength(support.state);

      if(range_position >= 0.0 && range_position <= 35.0)
         buy_score += ScoreRangePositionBonus;

      if(trend_score > 0.0)
         buy_score += ScoreTrendAgreeBonus;
      else if(trend_score < 0.0)
         buy_score += ScoreTrendDisagreePenalty;

      const bool rejection =
         BullishRejection(open, high, low, close, bar);

      if(rejection)
         buy_score += ScoreRejectionBonus;
      else if(RequireRejectionCandle)
         buy_score += ScoreRejectionMissingPenalty;
   }

   if(near_resistance)
   {
      sell_score += StateStrength(resistance.state);

      if(range_position >= 65.0)
         sell_score += ScoreRangePositionBonus;

      if(trend_score < 0.0)
         sell_score += ScoreTrendAgreeBonus;
      else if(trend_score > 0.0)
         sell_score += ScoreTrendDisagreePenalty;

      const bool rejection =
         BearishRejection(open, high, low, close, bar);

      if(rejection)
         sell_score += ScoreRejectionBonus;
      else if(RequireRejectionCandle)
         sell_score += ScoreRejectionMissingPenalty;
   }

   // breakout context
   if(bar + BreakoutLookback < rates_total)
   {
      double highest = high[bar+1];
      double lowest  = low[bar+1];

      for(int k = 2; k <= BreakoutLookback; k++)
      {
         const int index = bar + k;

         if(high[index] > highest) highest = high[index];
         if(low[index] < lowest)   lowest = low[index];
      }

      if(close[bar] > highest)
         buy_score += ScoreBreakoutBonus;

      if(close[bar] < lowest)
         sell_score += ScoreBreakoutBonus;
   }

   // Fix #1: room-to-opposite-zone penalty is now ATR-scaled too, instead
   // of a fixed 12-pip threshold that meant different things on different
   // instruments/timeframes.
   if(has_support && has_resistance && resistance.low > support.high)
   {
      const double room = resistance.low - support.high;

      if(room < MinRoomDistance())
      {
         buy_score += ScoreTightRoomPenalty;
         sell_score += ScoreTightRoomPenalty;
      }
   }

   buy_score = ClampScore(buy_score);
   sell_score = ClampScore(sell_score);
}

//============================= LOCK RESET ============================
void UpdateSignalLocks(const double live_price, const bool new_bar)
{
   const double reset_distance = SignalResetDistance();

   if(new_bar)
   {
      if(g_buy_locked)  g_buy_lock_bars++;
      if(g_sell_locked) g_sell_lock_bars++;
   }

  if(g_buy_locked)
{
   if(MathAbs(live_price - g_last_buy_zone) >= reset_distance ||
      g_buy_lock_bars >= MaxBarsLocked)
   {
      g_buy_locked = false;
      g_last_buy_zone = 0.0;
      g_buy_lock_bars = 0;
      g_buy_lock_time = 0;
   }
}

 if(g_sell_locked)
{
   if(MathAbs(live_price - g_last_sell_zone) >= reset_distance ||
      g_sell_lock_bars >= MaxBarsLocked)
   {
      g_sell_locked = false;
      g_last_sell_zone = 0.0;
      g_sell_lock_bars = 0;
      g_sell_lock_time = 0;
   }
}
}

//============================= OBJECTS ===============================
void DeleteOurObjects()
{
   const long chart_id = ChartID();
   const int total = ObjectsTotal(chart_id, -1, -1);

   for(int i = total - 1; i >= 0; i--)
   {
      const string name = ObjectName(chart_id, i, -1, -1);

      if(StringFind(name, g_prefix) == 0)
         ObjectDelete(chart_id, name);
   }
}

void DeleteZoneObjects()
{
   const long chart_id = ChartID();
   const int total = ObjectsTotal(chart_id, -1, -1);

   const string sup_prefix = g_prefix + "SUP_";
   const string res_prefix = g_prefix + "RES_";

   for(int i = total - 1; i >= 0; i--)
   {
      const string name = ObjectName(chart_id, i, -1, -1);

      if(StringFind(name, sup_prefix) == 0 ||
         StringFind(name, res_prefix) == 0)
      {
         ObjectDelete(chart_id, name);
      }
   }
}

void SortZonesByDistance(MasterZone &zones[],
                         const double price,
                         const bool support_side)
{
   const int count = ArraySize(zones);

   for(int a = 0; a < count - 1; a++)
   {
      for(int b = a + 1; b < count; b++)
      {
         double da = DBL_MAX;
         double db = DBL_MAX;

         if(zones[a].valid)
            da = support_side ?
                 MathAbs(price - zones[a].high) :
                 MathAbs(zones[a].low - price);

         if(zones[b].valid)
            db = support_side ?
                 MathAbs(price - zones[b].high) :
                 MathAbs(zones[b].low - price);

         if(db < da)
         {
            MasterZone temp = zones[a];
            zones[a] = zones[b];
            zones[b] = temp;
         }
      }
   }
}

void DrawZoneRectangle(const MasterZone &zone,
                       const string side,
                       const int index)
{
   if(!DrawZoneRectangles || !zone.valid)
      return;

   const string name =
      g_prefix + side + "_" +
      IntegerToString(index) + "_" +
      StateName(zone.state);

   const datetime end_time =
      TimeCurrent() + (datetime)(PeriodSeconds(_Period) * 24);

   if(!ObjectCreate(ChartID(),
                    name,
                    OBJ_RECTANGLE,
                    0,
                    zone.first_time,
                    zone.low,
                    end_time,
                    zone.high))
      return;

   ObjectSetInteger(ChartID(), name, OBJPROP_BACK, true);
   ObjectSetInteger(ChartID(), name, OBJPROP_FILL, false);
   ObjectSetInteger(ChartID(), name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(ChartID(), name, OBJPROP_SELECTABLE, false);

   ObjectSetString(
      ChartID(),
      name,
      OBJPROP_TOOLTIP,
      side + " | " +
      ZoneLabel(zone) +
      " | touches=" +
      IntegerToString(zone.touches) +
      " | score=" +
      DoubleToString(zone.touch_score, 2)
   );
}

void DrawNearestZones(const double price)
{
   DeleteZoneObjects();

   if(!DrawZoneRectangles)
      return;

   MasterZone s[];
   MasterZone r[];

   ArrayResize(s, ArraySize(g_supports));
   ArrayResize(r, ArraySize(g_resistances));

   for(int i = 0; i < ArraySize(g_supports); i++)
      s[i] = g_supports[i];

   for(int i = 0; i < ArraySize(g_resistances); i++)
      r[i] = g_resistances[i];

   SortZonesByDistance(s, price, true);
   SortZonesByDistance(r, price, false);

   int drawn = 0;

   for(int i = 0;
       i < ArraySize(s) && drawn < MaxSupportZonesToDraw;
       i++)
   {
      if(!s[i].valid) continue;
      if(s[i].high > price) continue;

      DrawZoneRectangle(s[i], "SUP", drawn);
      drawn++;
   }

   drawn = 0;

   for(int i = 0;
       i < ArraySize(r) && drawn < MaxResistanceZonesToDraw;
       i++)
   {
      if(!r[i].valid) continue;
      if(r[i].low < price) continue;

      DrawZoneRectangle(r[i], "RES", drawn);
      drawn++;
   }
}

//============================= DASHBOARD =============================
void DeleteDashboardObjects()
{
   const long chart_id = ChartID();
   const int total = ObjectsTotal(chart_id, -1, -1);
  const string dash_prefix = "MASTER_SR_DASH_";

   for(int i = total - 1; i >= 0; i--)
   {
      const string name = ObjectName(chart_id, i, -1, -1);
      if(StringFind(name, dash_prefix) == 0)
         ObjectDelete(chart_id, name);
   }
}

void SetDashboardLine(const int row,
                      const string text,
                      const color text_color,
                      const int font_size = 9)
{
   if(!DrawDashboard)
      return;

   const string name =
   "MASTER_SR_DASH_" + IntegerToString(row);

   if(ObjectFind(ChartID(), name) < 0)
   {
      if(!ObjectCreate(ChartID(), name, OBJ_LABEL, 0, 0, 0))
         return;

      ObjectSetInteger(ChartID(), name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(ChartID(), name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(ChartID(), name, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(ChartID(), name, OBJPROP_YDISTANCE, 12 + row * 17);
      ObjectSetInteger(ChartID(), name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(ChartID(), name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(ChartID(), name, OBJPROP_BACK, false);
      ObjectSetInteger(ChartID(), name, OBJPROP_ZORDER, 1000);
      ObjectSetString(ChartID(), name, OBJPROP_FONT, "Arial");
   }

   ObjectSetInteger(ChartID(), name, OBJPROP_FONTSIZE, font_size);
   ObjectSetInteger(ChartID(), name, OBJPROP_COLOR, text_color);
   ObjectSetString(ChartID(), name, OBJPROP_TEXT, text);
}

string LockDurationText(const datetime lock_time,
                        const int lock_bars)
{
   if(lock_time <= 0)
      return "OFF";

   int seconds = (int)(TimeCurrent() - lock_time);
   int minutes = seconds / 60;

   int hours = minutes / 60;
   int mins  = minutes % 60;

   if(hours > 0)
      return IntegerToString(hours) + "h "
           + IntegerToString(mins) + "m"
           + " | " + IntegerToString(lock_bars) + " bars";

   return IntegerToString(minutes) + "m"
        + " | " + IntegerToString(lock_bars) + " bars";
}

void DrawMasterDashboard(const string status_text,
                         const double buy_score,
                         const double sell_score,
                         const MasterZone &support,
                         const bool has_support,
                         const MasterZone &resistance,
                         const bool has_resistance,
                         const string trend_text,
                         const double trend_score,
                         const double range_position)
{
   if(!DrawDashboard)
   {
      DeleteDashboardObjects();
      return;
   }

   color status_color = clrSilver;
   if(status_text == "BUY")       status_color = clrLime;
   else if(status_text == "SELL") status_color = clrTomato;
   else if(StringFind(status_text, "LOCKED") >= 0)
      status_color = clrGold;

   SetDashboardLine(0, "MASTER S/R CONFLUENCE v2.52 VOL-ADAPTIVE", clrWhite, 10);
   SetDashboardLine(1, "STATUS: " + status_text, status_color, 10);

   SetDashboardLine(
      2,
      "BUY " + DoubleToString(buy_score, 1) + "/10"
      + "   |   SELL " + DoubleToString(sell_score, 1) + "/10"
      + "   |   NEED " + DoubleToString(MinimumScoreToSignal, 1),
      clrWhite,
      9
   );

   string support_text = "Nearest Support: none";
   if(has_support)
   {
      support_text =
         "Nearest Support: " +
         ZoneLabel(support) + " " +
         DoubleToString(support.low, _Digits) + "-" +
         DoubleToString(support.high, _Digits) +
         " | touches=" +
         IntegerToString(support.touches) +
         " | score=" +
         DoubleToString(support.touch_score, 2);
   }
   SetDashboardLine(3, support_text, clrDeepSkyBlue, 9);

   string resistance_text = "Nearest Resistance: none";
   if(has_resistance)
   {
      resistance_text =
         "Nearest Resistance: " +
         ZoneLabel(resistance) + " " +
         DoubleToString(resistance.low, _Digits) + "-" +
         DoubleToString(resistance.high, _Digits) +
         " | touches=" +
         IntegerToString(resistance.touches) +
         " | score=" +
         DoubleToString(resistance.touch_score, 2);
   }
   SetDashboardLine(4, resistance_text, clrOrangeRed, 9);

   SetDashboardLine(
      5,
      "Trend: " + trend_text +
      " (" + DoubleToString(trend_score, 1) + ")" +
      "  ATR: " + DoubleToString(g_atr_value, _Digits),
      clrWhite,
      9
   );

   string range_text = "Range position: n/a";
   if(range_position >= 0.0)
      range_text =
         "Range position: " +
         DoubleToString(range_position, 1) + "%";

   SetDashboardLine(6, range_text, clrWhite, 9);

   SetDashboardLine(
      7,
      "Signal mode: " +
      (ConfirmOnClosedCandle ?
       "CLOSED CANDLE / NON-DUPLICATE" :
       "LIVE BAR / NON-DUPLICATE"),
      clrWhite,
      9
   );

   SetDashboardLine(
   8,
   "Buy lock: " +
   (g_buy_locked ?
      LockDurationText(g_buy_lock_time, g_buy_lock_bars) :
      "OFF"),
   clrWhite,
   9
);

SetDashboardLine(
   9,
   "Sell lock: " +
   (g_sell_locked ?
      LockDurationText(g_sell_lock_time, g_sell_lock_bars) :
      "OFF"),
   clrWhite,
   9
);

ChartRedraw(ChartID());
}

void DrawWaitingDashboard(const int rates_total,
                          const int required_bars)
{
   if(!DrawDashboard)
      return;

   SetDashboardLine(0, "MASTER S/R CONFLUENCE v2.52 VOL-ADAPTIVE", clrWhite, 10);
   SetDashboardLine(1, "STATUS: WAITING FOR PRICE HISTORY", clrGold, 10);
   SetDashboardLine(
      2,
      "Bars loaded: " + IntegerToString(rates_total) +
      " / required: " + IntegerToString(required_bars),
      clrWhite,
      9
   );

  for(int row = 3; row <= 9; row++)
      SetDashboardLine(row, "", clrWhite, 9);

   ChartRedraw(ChartID());
}

//============================= CSV LOG ===============================
// Fix #9 (v2.51): logs default to one file per symbol+timeframe, and are
// opened with FILE_SHARE_WRITE. A single shared filename opened with only
// FILE_SHARE_READ is the classic multi-chart ERR_CANNOT_OPEN_FILE (5004)
// setup -- e.g. running this on EURUSD, GBPUSD, USDJPY, USDCHF, AUDUSD and
// NZDUSD simultaneously, all writing to one common Files\ log.
string BuildLogFileName(const string base_name)
{
   string base = base_name;
   const int dot = StringFind(base, ".csv");

   if(dot >= 0)
      base = StringSubstr(base, 0, dot);

   return base + "_" + _Symbol + "_" + EnumToString((ENUM_TIMEFRAMES)_Period) + ".csv";
}

int OpenSignalLog()
{
   if(!EnableCSVSignalLog)
      return INVALID_HANDLE;

   int flags =
      FILE_READ |
      FILE_WRITE |
      FILE_CSV |
      FILE_ANSI |
      FILE_SHARE_READ |
      FILE_SHARE_WRITE;

   if(LogToCommonFolder)
      flags |= FILE_COMMON;

   const int handle =
      FileOpen(BuildLogFileName(SignalLogFileName), flags, ';');

   if(handle == INVALID_HANDLE)
      return INVALID_HANDLE;

   if(FileSize(handle) == 0)
   {
      FileWrite(
         handle,
         "server_time",
         "bar_time",
         "symbol",
         "timeframe",
         "decision",
         "price",
         "buy_score",
         "sell_score",
         "support_state",
         "support_low",
         "support_high",
         "support_touches",
         "resistance_state",
         "resistance_low",
         "resistance_high",
         "resistance_touches",
         "range_position",
         "trend_score",
         "atr"
      );
   }

   FileSeek(handle, 0, SEEK_END);
   return handle;
}

void WriteSignalLog(const int direction,
                    const datetime bar_time,
                    const double price,
                    const double buy_score,
                    const double sell_score,
                    const MasterZone &support,
                    const bool has_support,
                    const MasterZone &resistance,
                    const bool has_resistance,
                    const double range_position,
                    const double trend_score)
{
   if(direction == 0)
      return;

   if(bar_time == g_last_logged_bar &&
      direction == g_last_logged_dir)
      return;

   const int handle = OpenSignalLog();

   if(handle == INVALID_HANDLE)
      return;

   FileWrite(
      handle,
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      TimeToString(bar_time, TIME_DATE|TIME_MINUTES),
      _Symbol,
      EnumToString((ENUM_TIMEFRAMES)_Period),
      direction > 0 ? "BUY" : "SELL",
      DoubleToString(price, _Digits),
      DoubleToString(buy_score, 1),
      DoubleToString(sell_score, 1),

      has_support ? ZoneLabel(support) : "",
      has_support ? DoubleToString(support.low, _Digits) : "",
      has_support ? DoubleToString(support.high, _Digits) : "",
      has_support ? IntegerToString(support.touches) : "",

      has_resistance ? ZoneLabel(resistance) : "",
      has_resistance ? DoubleToString(resistance.low, _Digits) : "",
      has_resistance ? DoubleToString(resistance.high, _Digits) : "",
      has_resistance ? IntegerToString(resistance.touches) : "",

      range_position >= 0.0 ?
         DoubleToString(range_position, 1) : "",

      DoubleToString(trend_score, 1),
      DoubleToString(g_atr_value, _Digits)
   );

   FileFlush(handle);
   FileClose(handle);

   g_last_logged_bar = bar_time;
   g_last_logged_dir = direction;
}

//=========================== SNAPSHOT LOG ============================
int OpenSnapshotLog()
{
   if(!EnableClosedBarSnapshotLog)
      return INVALID_HANDLE;

   int flags = FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE;

   if(LogToCommonFolder)
      flags |= FILE_COMMON;

   const int handle = FileOpen(BuildLogFileName(SnapshotLogFileName), flags, ';');

   if(handle == INVALID_HANDLE)
      return INVALID_HANDLE;

   if(FileSize(handle) == 0)
   {
      FileWrite(
         handle,
         "server_time","bar_time","symbol","timeframe","close",
         "buy_score","sell_score","decision",
         "support_low","support_high","support_strength",
         "resistance_low","resistance_high","resistance_strength",
         "range_position","trend_score","atr","buy_lock","sell_lock"
      );
   }

   FileSeek(handle, 0, SEEK_END);
   return handle;
}

void WriteClosedBarSnapshot(const datetime bar_time,
                            const double close_price,
                            const double buy_score,
                            const double sell_score,
                            const int decision,
                            const MasterZone &support,
                            const bool has_support,
                            const MasterZone &resistance,
                            const bool has_resistance,
                            const double range_position,
                            const double trend_score)
{
   if(!EnableClosedBarSnapshotLog || bar_time == g_last_snapshot_bar)
      return;

   const int handle = OpenSnapshotLog();
   if(handle == INVALID_HANDLE)
      return;

   FileWrite(
      handle,
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      TimeToString(bar_time, TIME_DATE|TIME_MINUTES),
      _Symbol,
      EnumToString((ENUM_TIMEFRAMES)_Period),
      DoubleToString(close_price, _Digits),
      DoubleToString(buy_score, 1),
      DoubleToString(sell_score, 1),
      IntegerToString(decision),

      has_support ? DoubleToString(support.low, _Digits) : "",
      has_support ? DoubleToString(support.high, _Digits) : "",
      has_support ? IntegerToString(StateStrength(support.state)) : "",

      has_resistance ? DoubleToString(resistance.low, _Digits) : "",
      has_resistance ? DoubleToString(resistance.high, _Digits) : "",
      has_resistance ? IntegerToString(StateStrength(resistance.state)) : "",

      range_position >= 0.0 ? DoubleToString(range_position, 1) : "",
      DoubleToString(trend_score, 1),
      DoubleToString(g_atr_value, _Digits),
      g_buy_locked ? "1" : "0",
      g_sell_locked ? "1" : "0"
   );

   FileFlush(handle);
   FileClose(handle);
   g_last_snapshot_bar = bar_time;
}

//============================= INIT =================================
int OnInit()
{
   // Remove old dashboard objects from previous versions
   ObjectsDeleteAll(ChartID(), "MSR23_");
   ObjectsDeleteAll(ChartID(), "MSR24_");
   ObjectsDeleteAll(ChartID(), "MSR25_");
   ObjectsDeleteAll(ChartID(), "MasterSR_");
   ObjectsDeleteAll(ChartID(), "MASTER_SR_DASH_");

   ChartRedraw();

   SetIndexBuffer(0, BuySignalBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, SellSignalBuffer, INDICATOR_DATA);
   SetIndexBuffer(2, SupportLowBuffer, INDICATOR_DATA);
   SetIndexBuffer(3, SupportHighBuffer, INDICATOR_DATA);
   SetIndexBuffer(4, ResistanceLowBuffer, INDICATOR_DATA);
   SetIndexBuffer(5, ResistanceHighBuffer, INDICATOR_DATA);
   SetIndexBuffer(6, SupportStrengthBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, ResistanceStrengthBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(8, RangePositionBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(9, TrendScoreBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(10, BuyScoreBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(11, SellScoreBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(12, DecisionBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(13, ZoneStateBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(14, SignalNearZoneBuffer, INDICATOR_CALCULATIONS);

   ArraySetAsSeries(BuySignalBuffer, true);
   ArraySetAsSeries(SellSignalBuffer, true);
   ArraySetAsSeries(SupportLowBuffer, true);
   ArraySetAsSeries(SupportHighBuffer, true);
   ArraySetAsSeries(ResistanceLowBuffer, true);
   ArraySetAsSeries(ResistanceHighBuffer, true);
   ArraySetAsSeries(SupportStrengthBuffer, true);
   ArraySetAsSeries(ResistanceStrengthBuffer, true);
   ArraySetAsSeries(RangePositionBuffer, true);
   ArraySetAsSeries(TrendScoreBuffer, true);
   ArraySetAsSeries(BuyScoreBuffer, true);
   ArraySetAsSeries(SellScoreBuffer, true);
   ArraySetAsSeries(DecisionBuffer, true);
   ArraySetAsSeries(ZoneStateBuffer, true);
   ArraySetAsSeries(SignalNearZoneBuffer, true);

   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   for(int p = 2; p <= 5; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetString(
      INDICATOR_SHORTNAME,
      "Master S/R Confluence v2.52 VolAdaptive"
   );

   g_atr_handle = iATR(_Symbol, _Period, ATRPeriod);

   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("MasterSR v2.5: failed to create ATR handle, error=", GetLastError());
      return INIT_FAILED;
   }

   ArraySetAsSeries(g_atr_buffer, true);

   DeleteOurObjects();

   if(!DrawDashboard)
      DeleteDashboardObjects();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);

   DeleteOurObjects();
   DeleteDashboardObjects();
   ChartRedraw();
}

//========================== MAIN CALCULATION =========================
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   const int required_bars =
      MathMax(
         LookbackBars,
         MathMax(SlowMAPeriod, ATRPeriod) + BreakoutLookback + 30
      );

   if(rates_total < required_bars)
   {
      DrawWaitingDashboard(rates_total, required_bars);
      return 0;
   }

   ArraySetAsSeries(time, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   // one-time initialization
   if(prev_calculated == 0)
   {
      ArrayInitialize(BuySignalBuffer, EMPTY_VALUE);
      ArrayInitialize(SellSignalBuffer, EMPTY_VALUE);
      ArrayInitialize(SupportLowBuffer, EMPTY_VALUE);
      ArrayInitialize(SupportHighBuffer, EMPTY_VALUE);
      ArrayInitialize(ResistanceLowBuffer, EMPTY_VALUE);
      ArrayInitialize(ResistanceHighBuffer, EMPTY_VALUE);

      ArrayInitialize(SupportStrengthBuffer, 0.0);
      ArrayInitialize(ResistanceStrengthBuffer, 0.0);
      ArrayInitialize(RangePositionBuffer, -1.0);
      ArrayInitialize(TrendScoreBuffer, 0.0);
      ArrayInitialize(BuyScoreBuffer, 0.0);
      ArrayInitialize(SellScoreBuffer, 0.0);
      ArrayInitialize(DecisionBuffer, 0.0);
      ArrayInitialize(ZoneStateBuffer, 0.0);
      ArrayInitialize(SignalNearZoneBuffer, 0.0);
   }

   const bool new_bar =
      (g_last_bar_time == 0 ||
       time[0] != g_last_bar_time);

   if(new_bar)
   {
      g_last_bar_time = time[0];

      if(prev_calculated == 0)
      {
         // Fix #7: replay the full lookback bar-by-bar (decay, break,
         // role-reversal, confirmation-lag-correct swing timing) instead
         // of bulk-seeding. Self-contained: its last iteration already
         // invalidates/prunes against the current latest closed bar, so
         // nothing further is needed here.
         ReplayHistoryZones(high, low, close, time, rates_total);
      }
      else
      {
         // ATR of the last CLOSED bar only -- never the forming bar -- so
         // all distance thresholds derived from it are stable for the bar.
         UpdateATR(1);

         DecayZones(g_supports);
         DecayZones(g_resistances);
         UpdateZonesIncremental(high, low, time, rates_total);

         InvalidateAndReverseZones(close[1], time[1]);
         PruneStaleZones(g_supports, time[1]);
         PruneStaleZones(g_resistances, time[1]);
      }

      DrawNearestZones(close[1]);

      // clear only newest slots so stale arrows can't bleed forward
      BuySignalBuffer[0] = EMPTY_VALUE;
      SellSignalBuffer[0] = EMPTY_VALUE;
      BuySignalBuffer[1] = EMPTY_VALUE;
      SellSignalBuffer[1] = EMPTY_VALUE;
   }

   UpdateSignalLocks(close[0], new_bar);

   const int bar =
      ConfirmOnClosedCandle ? 1 : 0;

   const double price = close[bar];

   MasterZone support;
   MasterZone resistance;

   const bool has_support =
      FindNearestSupport(price, support);

   const bool has_resistance =
      FindNearestResistance(price, resistance);

   SupportLowBuffer[bar] =
      has_support ? support.low : EMPTY_VALUE;

   SupportHighBuffer[bar] =
      has_support ? support.high : EMPTY_VALUE;

   ResistanceLowBuffer[bar] =
      has_resistance ? resistance.low : EMPTY_VALUE;

   ResistanceHighBuffer[bar] =
      has_resistance ? resistance.high : EMPTY_VALUE;

   SupportStrengthBuffer[bar] =
      has_support ? StateStrength(support.state) : 0.0;

   ResistanceStrengthBuffer[bar] =
      has_resistance ? StateStrength(resistance.state) : 0.0;

   double range_position = -1.0;

   if(has_support &&
      has_resistance &&
      resistance.low > support.high)
   {
      range_position =
         100.0 *
         (price - support.high) /
         (resistance.low - support.high);

      range_position =
         MathMax(
            0.0,
            MathMin(100.0, range_position)
         );
   }

   RangePositionBuffer[bar] =
      range_position;

   const double fast_ma =
      SimpleMA(close, bar, FastMAPeriod, rates_total);

   const double slow_ma =
      SimpleMA(close, bar, SlowMAPeriod, rates_total);

   const double momentum =
      PriceMomentum(close, bar, MomentumPeriod, rates_total);

   // Fix #5: momentum is normalized by ATR (instead of compared to raw 0.0,
   // which meant wildly different things on a JPY pair vs. a non-JPY pair,
   // or M1 vs. H4) and a deadband suppresses noise-level readings so the
   // trend score doesn't flip on immaterial ticks.
   const double momentum_atr =
      (g_atr_value > 0.0) ? (momentum / g_atr_value) : 0.0;

   double trend_score = 0.0;

   if(fast_ma != EMPTY_VALUE &&
      slow_ma != EMPTY_VALUE)
   {
      if(fast_ma > slow_ma)
         trend_score += TrendMAAgreeBonus;
      else if(fast_ma < slow_ma)
         trend_score -= TrendMAAgreeBonus;
   }

   if(momentum_atr > MomentumATRDeadband)
      trend_score += TrendMomentumBonus;
   else if(momentum_atr < -MomentumATRDeadband)
      trend_score -= TrendMomentumBonus;

   TrendScoreBuffer[bar] =
      trend_score;

   double buy_score = 0.0;
   double sell_score = 0.0;

   ComputeScores(
      open,
      high,
      low,
      close,
      rates_total,
      bar,
      support,
      has_support,
      resistance,
      has_resistance,
      range_position,
      trend_score,
      buy_score,
      sell_score
   );

   BuyScoreBuffer[bar] = buy_score;
   SellScoreBuffer[bar] = sell_score;

   const double near_distance =
      SignalNearZoneDistance();

   SignalNearZoneBuffer[bar] = near_distance;

   const bool near_support =
      has_support &&
      (price - support.high) <= near_distance;

   const bool near_resistance =
      has_resistance &&
      (resistance.low - price) <= near_distance;

   int zone_state = 0;

   if(near_support && !near_resistance)
      zone_state = 1;
   else if(near_resistance && !near_support)
      zone_state = -1;

   ZoneStateBuffer[bar] = zone_state;

   // default decision
   int decision = 0;

   // Hard room veto (see RequireAdequateRoom above): only evaluable when
   // both zones exist and are correctly ordered, same as the soft penalty
   // in ComputeScores(). When the gap isn't measurable, this doesn't block
   // the trade -- absence of information isn't evidence the room is bad.
   const bool room_measurable =
      has_support && has_resistance && resistance.low > support.high;

   const bool room_adequate =
      !RequireAdequateRoom ||
      !room_measurable ||
      (resistance.low - support.high) >= MinRoomDistance();

   const bool raw_buy =
      near_support &&
      buy_score >= MinimumScoreToSignal &&
      buy_score > sell_score &&
      room_adequate;

   const bool raw_sell =
      near_resistance &&
      sell_score >= MinimumScoreToSignal &&
      sell_score > buy_score &&
      room_adequate;

   bool emit_buy = false;
   bool emit_sell = false;

if(raw_buy && has_support)
{
   const bool duplicate =
      g_buy_locked &&
      SameZone(support.center, g_last_buy_zone);

   if(!duplicate)
   {
      emit_buy = true;

      g_buy_locked = true;
      g_last_buy_zone = support.center;
      g_buy_lock_bars = 0;
      g_buy_lock_time = TimeCurrent();

      g_sell_locked = false;
      g_last_sell_zone = 0.0;
      g_sell_lock_bars = 0;
      g_sell_lock_time = 0;
   }
}

   if(raw_sell && has_resistance)
{
   const bool duplicate =
      g_sell_locked &&
      SameZone(resistance.center, g_last_sell_zone);

   if(!duplicate)
   {
      emit_sell = true;

      g_sell_locked = true;
      g_last_sell_zone = resistance.center;
      g_sell_lock_bars = 0;
      g_sell_lock_time = TimeCurrent();

      g_buy_locked = false;
      g_last_buy_zone = 0.0;
      g_buy_lock_bars = 0;
      g_buy_lock_time = 0;
   }
}

   // Always clear this bar before writing a confirmed signal.
   BuySignalBuffer[bar] = EMPTY_VALUE;
   SellSignalBuffer[bar] = EMPTY_VALUE;

   if(emit_buy && !emit_sell)
   {
      BuySignalBuffer[bar] =
         low[bar] - ArrowOffset();

      decision = 1;
   }
   else if(emit_sell && !emit_buy)
   {
      SellSignalBuffer[bar] =
         high[bar] + ArrowOffset();

      decision = -1;
   }

   // no current-bar arrow when using closed-candle mode
   if(ConfirmOnClosedCandle)
   {
      BuySignalBuffer[0] = EMPTY_VALUE;
      SellSignalBuffer[0] = EMPTY_VALUE;
   }

   DecisionBuffer[bar] = decision;

   // dashboard
   string trend_text = "FLAT";
   if(trend_score >= 1.0)
      trend_text = "BULLISH";
   else if(trend_score <= -1.0)
      trend_text = "BEARISH";

   string status_text = "WAIT";

 if(decision > 0)
   status_text = "BUY";
else if(decision < 0)
   status_text = "SELL";
else if(g_buy_locked)
   status_text = "BUY LOCKED";
else if(g_sell_locked)
   status_text = "SELL LOCKED";
else
   status_text = "WAIT";

   DrawMasterDashboard(
      status_text,
      buy_score,
      sell_score,
      support,
      has_support,
      resistance,
      has_resistance,
      trend_text,
      trend_score,
      range_position
   );

   if(decision != 0)
   {
      WriteSignalLog(
         decision,
         time[bar],
         price,
         buy_score,
         sell_score,
         support,
         has_support,
         resistance,
         has_resistance,
         range_position,
         trend_score
      );
   }

   if(ConfirmOnClosedCandle && new_bar)
   {
      WriteClosedBarSnapshot(
         time[bar],
         price,
         buy_score,
         sell_score,
         decision,
         support,
         has_support,
         resistance,
         has_resistance,
         range_position,
         trend_score
      );
   }

   return rates_total;
}
//+------------------------------------------------------------------+
