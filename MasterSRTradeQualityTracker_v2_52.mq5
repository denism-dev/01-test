//+------------------------------------------------------------------+
//|      MasterSRTradeQualityTracker_v2_52.mq5 |
//| Trade-quality tracker for Master S/R Confluence v2.52            |
//| Tracks every confirmed signal, MFE/MAE, fixed-pip targets & R.    |
//| NEVER opens, modifies, or closes real trades.                     |
//+------------------------------------------------------------------+
#property strict
#property version   "2.52"
#property description "Non-trading v2.52 VolAdaptive trade-quality tracker. Tracks raw signal outcomes only; no old-indicator comparison and no P5G/DG management experiment."

//============================== INPUTS ===============================
// Prefer reading the indicator already attached to the chart.
input string AttachedIndicatorShortName = "Master S/R Confluence v2.52 VolAdaptive";

// Fix: iCustom fallback -- used only if no attached instance is found (see
// TryICustomIndicator / CreateIndicatorHandle below). Unlike the attached
// path, this needs no chart, so it's what makes fast/non-visual backtests
// and Strategy Tester optimization possible.
input bool   UseICustomFallback         = true;
input string IndicatorFileName          = "MasterSRConfluenceIndicator_v2_52_VolAdaptive";

// v2.52 EA-facing buffers (same 14-buffer contract as v2.4, plus the
// v2.51 SignalNearZoneDistance buffer at index 14)
input int    BuySignalBufferIndex        = 0;
input int    SellSignalBufferIndex       = 1;
input int    SupportLowBufferIndex       = 2;
input int    SupportHighBufferIndex      = 3;
input int    ResistanceLowBufferIndex    = 4;
input int    ResistanceHighBufferIndex   = 5;
input int    SupportStrengthBufferIndex  = 6;
input int    ResistanceStrengthBufferIndex=7;
input int    RangePositionBufferIndex    = 8;
input int    TrendScoreBufferIndex       = 9;
input int    BuyScoreBufferIndex         = 10;
input int    SellScoreBufferIndex        = 11;
input int    DecisionBufferIndex         = 12;
// Fix: previously near_entry_zone used a hardcoded 5.0-pip constant,
// disconnected from the indicator's own ATR-scaled near-zone threshold
// (SignalNearZoneDistance()) used internally to decide near_support/
// near_resistance for scoring and Decision. Reading it from this buffer
// keeps near_entry_zone (and everything downstream: Q, models C/D/I/K)
// in sync with what actually produced the signal, instead of a constant
// that only coincidentally matches at some reference volatility.
input int    SignalNearZoneBufferIndex   = 14;

// virtual trade rules
input double StopBufferPips              = 2.0;
input double FallbackStopPips            = 15.0;
input int    TimeoutBars                 = 12;     // 12 x M15 = 3 hours

//======================= EXPERIMENTAL FILTER LAB =====================
// IMPORTANT: rejected signals are STILL tracked so we can compare them.
// These settings classify signals only; this EA never places real trades.
input bool   EnableFilterLab              = true;
input double FilterMinSignalScore         = 6.0;
input double FilterMaxSpreadPips          = 2.0;
input double FilterMaxSpreadPctOf5p       = 40.0;
input bool   FilterRequireTrendAligned    = true;
input bool   FilterRequireNearEntryZone   = true;
input bool   FilterRequireRangeExtreme    = false;
input double FilterMaxRiskPips            = 18.0;
input bool   FilterAllowBUY               = true;
input bool   FilterAllowSELL              = true;

//======================= SESSION DIAGNOSTICS =========================
// LOGGING ONLY: these do NOT reject signals.
// Session windows are configurable UTC buckets for later analysis.
input bool   EnableSessionDiagnostics      = true;
input int    AsiaStartUTC                  = 0;
input int    AsiaEndUTC                    = 8;
input int    LondonStartUTC                = 7;
input int    LondonEndUTC                  = 16;
input int    NewYorkStartUTC               = 12;
input int    NewYorkEndUTC                 = 21;

//======================= MULTI-FILTER MODELS =========================
// All models are observational only. Every raw indicator signal is still tracked.
// A: execution-cost screen only
input double ModelA_MaxSpreadPips         = 2.0;
input double ModelA_MaxSpreadPct5p        = 40.0;

// B: cost + modeled stop/risk screen
input double ModelB_MaxSpreadPips         = 2.0;
input double ModelB_MaxRiskPips           = 18.0;

// C: original confluence idea: trend + correct entry zone
input bool   ModelC_RequireTrend           = true;
input bool   ModelC_RequireZone            = true;

// D: weighted quality model
input int    ModelD_MinQualityPoints       = 5;   // max 8
input double ModelD_MaxSpreadPips          = 2.0;
input double ModelD_MaxRiskPips            = 18.0;

// E: SELL-focused observational model
input double ModelE_MaxSpreadPips          = 2.0;
input double ModelE_MaxRiskPips            = 18.0;

// F: BUY-focused observational model (stricter)
input double ModelF_MaxSpreadPips          = 2.0;
input double ModelF_MaxRiskPips            = 18.0;
input bool   ModelF_RequireTrend           = true;

// G: session-aware model; excludes Asia/off-session but does NOT alter raw tracking
input double ModelG_MaxSpreadPips          = 2.0;
input double ModelG_MaxRiskPips            = 18.0;

//======================= LEGACY DIAGNOSTIC MODELS ====================
// H: minimum room to the opposing zone + execution guards.
input double ModelH_MinOppositeRoomPips    = 12.0;
input double ModelH_MaxSpreadPips          = 2.0;
input double ModelH_MaxRiskPips            = 18.0;

// I: SELL-only trend-aligned model. Tests whether weak counter-trend SELLs
// are the main source of poor SELL performance.
input double ModelI_MaxSpreadPips          = 2.0;
input double ModelI_MaxRiskPips            = 18.0;

// J: active-session + room model.
input double ModelJ_MinOppositeRoomPips    = 12.0;
input double ModelJ_MaxSpreadPips          = 2.0;
input double ModelJ_MaxRiskPips            = 18.0;

// K: candidate optimization combination.
// BUY: no mandatory trend alignment.
// SELL: trend alignment required.
// Both: cost/risk/room + minimum quality.
input int    ModelK_MinQualityPoints       = 5;
input double ModelK_MinOppositeRoomPips    = 12.0;
input double ModelK_MaxSpreadPips          = 2.0;
input double ModelK_MaxRiskPips            = 18.0;

// Early-progress management experiment.
// This NEVER closes the raw virtual signal. It records what would happen
// if we exited a stalled trade after N bars without at least +X pips MFE.
input int    EarlyProgressBars             = 6;
input double EarlyProgressPips             = 2.0;

//================ SOFT ENTRY CONFIRMATION MODELS ====================
// Compare three closed-candle follow-through levels side-by-side.
// BUY level  = signal_low  + fraction * signal candle range
// SELL level = signal_high - fraction * signal candle range
// L50 = soft, L75 = medium, L100 = original full-break control.
input int    Confirm_MaxBars               = 2;
input int    Confirm_TimeoutBars           = 12;
input double Confirm_L50_Fraction          = 0.50;
input double Confirm_L75_Fraction          = 0.75;
input double Confirm_L100_Fraction         = 1.00;

input string ConfirmL50FileName            = "MasterSR_ConfirmL50_v2_4_4.csv";
input string ConfirmL75FileName            = "MasterSR_ConfirmL75_v2_4_4.csv";
input string ConfirmL100FileName           = "MasterSR_ConfirmL100_v2_4_4.csv";

//==================== v2.52 MANAGEMENT LAB ==========================
// All models preserve the ORIGINAL raw v2.52 entry and structural stop.
//
// Every model:
//   - uses the original raw entry,
//   - has a fixed +5p virtual TP,
//   - keeps the original structural stop,
//   - uses the same peak-giveback reversal guard after +2p MFE.
//
// The experiment isolates ONE question:
//   How negative should a still-unproven trade be before we cut it?
//
// P5G = mandatory-stall control. At bar 5, if MFE < +2p, exit immediately.
// DG2 = from bar 5 onward, if MFE < +2p AND current P/L <= -2p, exit.
// DG4 = from bar 5 onward, if MFE < +2p AND current P/L <= -4p, exit.
// DG6 = from bar 5 onward, if MFE < +2p AND current P/L <= -6p, exit.
//
// If a DG model is still near breakeven at bar 5, it is NOT forced out.
// It keeps watching. If it later proves itself by reaching +2p MFE,
// the stall gate is permanently passed and the reversal guard takes over.
//
// This tracker is deliberately experimental and NEVER places real orders.
input double ManagementMinProgressPips      = 2.0;
input int    ManagementStartBars            = 5;
input double ManagementFixedTPPips          = 5.0;
input int    ManagementTimeoutBars          = 12;

input double DamageGate2Pips                = 2.0;
input double DamageGate4Pips                = 4.0;
input double DamageGate6Pips                = 6.0;

input double ReversalGuardGivebackPips      = 5.0;
input double ReversalGuardMaxNegativePips   = 1.5;

input string ManagementFileName             = "MasterSR_v2_52_AdaptiveStall.csv";

// data collection
input bool   EnableCSVLogging            = true;
input bool   LogToCommonFolder           = true;
input string ResultsFileName             = "MasterSR_v2_52_TradeQuality_Results.csv";
input string SignalEventsFileName        = "MasterSR_v2_52_TradeQuality_Signals.csv";
input string OptimizationFileName        = "MasterSR_v2_52_TradeQuality_Diagnostics.csv";

input bool   ShowDashboard               = true;
input int    MaxTrackedSignals           = 100;

//============================= STRUCTS ===============================
struct VirtualSignal
{
   bool     active;
   long     id;

   datetime signal_bar_time;
   datetime entry_time;
   int      direction;             // +1 BUY, -1 SELL

   double   signal_close;
   double   entry_price;
   double   spread_pips;

   double   buy_score;
   double   sell_score;

   double   support_low;
   double   support_high;
   double   resistance_low;
   double   resistance_high;
   double   support_strength;
   double   resistance_strength;
   double   range_position;
   double   trend_score;

   // Entry diagnostics for failure analysis
   double   support_distance_pips;
   double   resistance_distance_pips;
   double   spread_pct_of_5p;
   int      trend_aligned;
   int      range_extreme_fit;
   int      near_entry_zone;
   double   near_zone_threshold_pips;

   // v2.3 session diagnostics (logging only)
   datetime utc_entry_time;
   int      server_hour;
   int      utc_hour;
   int      utc_day_of_week;
   double   server_utc_offset_hours;
   string   session_label;

   // v2.2 legacy single-filter fields kept for comparison
   double   signal_score;
   int      filter_pass;
   int      filter_fail_mask;

   // v2.4 multi-filter model flags
   int      model_a;
   int      model_b;
   int      model_c;
   int      model_d;
   int      model_e;
   int      model_f;
   int      model_g;

   // v2.4.2 optimization model flags
   int      model_h;  // room
   int      model_i;  // SELL + trend
   int      model_j;  // active session + room
   int      model_k;  // candidate combo

   int      quality_points;

   // Early-progress management diagnostic
   int      early_progress_checked;
   int      early_progress_pass;
   double   early_progress_check_pl_pips;
   double   early_exit_pl_pips;

   // live/final mark-to-market diagnostics
   double   exit_price;
   double   exit_pl_pips;
   double   timeout_pl_pips;

   double   stop_price;
   double   risk_pips;

   double   tp1_price;
   double   tp15_price;
   double   tp2_price;

   double   tp5_price;
   double   tp6_price;
   double   tp8_price;
   double   tp10_price;

   int      outcome_1r;            // +1 win, -1 loss, 0 timeout/undecided
   int      outcome_15r;
   int      outcome_2r;
   int      outcome_5p;
   int      outcome_6p;
   int      outcome_8p;
   int      outcome_10p;

   datetime hit_1r_time;
   datetime hit_15r_time;
   datetime hit_2r_time;
   datetime hit_5p_time;
   datetime hit_6p_time;
   datetime hit_8p_time;
   datetime hit_10p_time;
   datetime stop_time;

   double   mfe_pips;
   double   mae_pips;

   int      bars_held;
   datetime last_counted_bar;
};

VirtualSignal g_signals[];

struct ConfirmSignal
{
   bool active;
   long source_id;
   int direction;
   datetime signal_bar_time;
   datetime created_time;

   double raw_entry_price;
   double signal_high;
   double signal_low;
   double confirm_fraction;
   double confirm_level;
   double structural_stop_price;

   int wait_bars;
   datetime last_wait_bar;

   int confirmed;
   datetime confirmation_time;
   double confirmation_entry;
   double entry_cost_pips;
   double risk_pips;

   double tp5_price;
   double tp6_price;
   double tp8_price;
   double tp10_price;

   int outcome_5p;
   int outcome_6p;
   int outcome_8p;
   int outcome_10p;

   double mfe_pips;
   double mae_pips;
   double exit_pl_pips;
   double timeout_pl_pips;

   int bars_held;
   datetime last_counted_bar;

   string session_label;
   int quality_points;
};

ConfirmSignal g_confirm_l50[];
ConfirmSignal g_confirm_l75[];
ConfirmSignal g_confirm_l100[];

int g_l50_candidates=0, g_l50_confirmed=0, g_l50_no_entry=0, g_l50_completed=0;
int g_l50_5p_wins=0, g_l50_5p_losses=0, g_l50_5p_timeouts=0;
double g_l50_entry_cost_sum=0.0;

int g_l75_candidates=0, g_l75_confirmed=0, g_l75_no_entry=0, g_l75_completed=0;
int g_l75_5p_wins=0, g_l75_5p_losses=0, g_l75_5p_timeouts=0;
double g_l75_entry_cost_sum=0.0;

int g_l100_candidates=0, g_l100_confirmed=0, g_l100_no_entry=0, g_l100_completed=0;
int g_l100_5p_wins=0, g_l100_5p_losses=0, g_l100_5p_timeouts=0;
double g_l100_entry_cost_sum=0.0;

const int MGMT_P5G = 1;
const int MGMT_DG2  = 2;
const int MGMT_DG4  = 3;
const int MGMT_DG6  = 4;

struct EarlyExitSignal
{
   bool     active;
   long     source_id;
   int      direction;
   int      model_id;

   datetime signal_bar_time;
   datetime entry_time;
   double   entry_price;
   double   structural_stop_price;
   double   tp5_price;

   int      start_bars;
   int      stall_monitor_started;
   int      progress_passed;
   double   damage_gate_pips;       // 0 = mandatory P5G control

   int      guard_armed;
   int      guard_triggered;

   double   mfe_pips;
   double   mae_pips;
   double   exit_price;
   double   exit_pl_pips;
   double   giveback_pips;

   int      bars_held;
   datetime last_counted_bar;

   string   session_label;
   int      quality_points;
   double   signal_score;
};

EarlyExitSignal g_mgmt_p5g[];
EarlyExitSignal g_mgmt_dg2[];
EarlyExitSignal g_mgmt_dg4[];
EarlyExitSignal g_mgmt_dg6[];

int g_p5g_candidates=0, g_p5g_progress_pass=0, g_p5g_stall_exits=0;
int g_p5g_guard_exits=0, g_p5g_tp5_wins=0, g_p5g_stop_losses=0;
int g_p5g_timeouts=0, g_p5g_completed=0;
double g_p5g_stall_exit_pl_sum=0.0, g_p5g_guard_exit_pl_sum=0.0;

int g_dg2_candidates=0, g_dg2_progress_pass=0, g_dg2_stall_exits=0;
int g_dg2_guard_exits=0, g_dg2_tp5_wins=0, g_dg2_stop_losses=0;
int g_dg2_timeouts=0, g_dg2_completed=0;
double g_dg2_stall_exit_pl_sum=0.0, g_dg2_guard_exit_pl_sum=0.0;

int g_dg4_candidates=0, g_dg4_progress_pass=0, g_dg4_stall_exits=0;
int g_dg4_guard_exits=0, g_dg4_tp5_wins=0, g_dg4_stop_losses=0;
int g_dg4_timeouts=0, g_dg4_completed=0;
double g_dg4_stall_exit_pl_sum=0.0, g_dg4_guard_exit_pl_sum=0.0;

int g_dg6_candidates=0, g_dg6_progress_pass=0, g_dg6_stall_exits=0;
int g_dg6_guard_exits=0, g_dg6_tp5_wins=0, g_dg6_stop_losses=0;
int g_dg6_timeouts=0, g_dg6_completed=0;
double g_dg6_stall_exit_pl_sum=0.0, g_dg6_guard_exit_pl_sum=0.0;

int      g_indicator_handle = INVALID_HANDLE;
datetime g_last_chart_bar_time = 0;
long     g_next_id = 1;

int      g_completed = 0;
int      g_1r_wins = 0;
int      g_1r_losses = 0;
int      g_15r_wins = 0;
int      g_15r_losses = 0;
int      g_2r_wins = 0;
int      g_2r_losses = 0;
int      g_5p_wins = 0;
int      g_5p_losses = 0;
int      g_6p_wins = 0;
int      g_6p_losses = 0;
int      g_8p_wins = 0;
int      g_8p_losses = 0;
int      g_10p_wins = 0;
int      g_10p_losses = 0;

int      g_filter_pass_signals = 0;
int      g_filter_reject_signals = 0;
int      g_filter_pass_completed = 0;
int      g_filter_5p_wins = 0;
int      g_filter_5p_losses = 0;
int      g_filter_5p_timeouts = 0;
int      g_filter_6p_wins = 0;
int      g_filter_6p_losses = 0;
int      g_filter_6p_timeouts = 0;
int      g_filter_8p_wins = 0;
int      g_filter_8p_losses = 0;
int      g_filter_8p_timeouts = 0;

// v2.4.2 model statistics; index 0..10 = A..K
int      g_model_signals[11];
int      g_model_completed[11];
int      g_model_5p_wins[11];
int      g_model_5p_losses[11];
int      g_model_5p_timeouts[11];

int      g_early_progress_checked = 0;
int      g_early_progress_pass = 0;
int      g_early_progress_fail = 0;
double   g_early_fail_exit_pl_sum = 0.0;

// v2.52 raw trade-quality summary
double   g_sum_mfe_pips = 0.0;
double   g_sum_mae_pips = 0.0;
double   g_sum_final_pl_pips = 0.0;
int      g_stop_exits = 0;
int      g_timeout_exits = 0;
int      g_2r_exits = 0;
int      g_zero_mfe_completed = 0;
int      g_zero_mfe_stop_exits = 0;

string   g_prefix = "MSRTQ252_";
string   g_last_processed_gv = "";

//============================= HELPERS ===============================
double PipSize()
{
   if(_Digits == 3 || _Digits == 5)
      return _Point * 10.0;

   return _Point;
}



bool HourInWindow(const int hour_value,
                  const int start_hour,
                  const int end_hour)
{
   if(start_hour == end_hour)
      return true;

   if(start_hour < end_hour)
      return (hour_value >= start_hour && hour_value < end_hour);

   // Supports windows that wrap midnight.
   return (hour_value >= start_hour || hour_value < end_hour);
}

string DayOfWeekName(const int dow)
{
   if(dow == 0) return "SUN";
   if(dow == 1) return "MON";
   if(dow == 2) return "TUE";
   if(dow == 3) return "WED";
   if(dow == 4) return "THU";
   if(dow == 5) return "FRI";
   if(dow == 6) return "SAT";
   return "UNKNOWN";
}

string SessionLabelFromUTC(const int hour_value)
{
   if(!EnableSessionDiagnostics)
      return "DISABLED";

   const bool asia =
      HourInWindow(hour_value, AsiaStartUTC, AsiaEndUTC);

   const bool london =
      HourInWindow(hour_value, LondonStartUTC, LondonEndUTC);

   const bool new_york =
      HourInWindow(hour_value, NewYorkStartUTC, NewYorkEndUTC);

   if(london && new_york)
      return "LONDON_NY_OVERLAP";

   if(asia && london)
      return "ASIA_LONDON_OVERLAP";

   if(asia)
      return "ASIA";

   if(london)
      return "LONDON";

   if(new_york)
      return "NEW_YORK";

   return "OFF_SESSION";
}

void FillSessionDiagnostics(VirtualSignal &s)
{
   MqlDateTime server_dt;
   MqlDateTime utc_dt;

   TimeToStruct(s.entry_time, server_dt);
   s.server_hour = server_dt.hour;

   // Capture the broker-server-to-UTC offset at signal creation.
   // The rounded minute precision handles brokers using half-hour offsets too.
   const datetime current_server = TimeCurrent();
   const datetime current_utc    = TimeGMT();
   const long offset_seconds     = (long)(current_server - current_utc);

   s.server_utc_offset_hours =
      ((double)offset_seconds) / 3600.0;

   s.utc_entry_time =
      s.entry_time - (datetime)offset_seconds;

   TimeToStruct(s.utc_entry_time, utc_dt);

   s.utc_hour = utc_dt.hour;
   s.utc_day_of_week = utc_dt.day_of_week;
   s.session_label = SessionLabelFromUTC(s.utc_hour);
}


string ModelName(const int index)
{
   if(index == 0)  return "A_SPREAD";
   if(index == 1)  return "B_SPREAD_RISK";
   if(index == 2)  return "C_TREND_ZONE";
   if(index == 3)  return "D_WEIGHTED";
   if(index == 4)  return "E_SELL";
   if(index == 5)  return "F_BUY";
   if(index == 6)  return "G_SESSION";
   if(index == 7)  return "H_ROOM";
   if(index == 8)  return "I_SELL_TREND";
   if(index == 9)  return "J_SESSION_ROOM";
   if(index == 10) return "K_OPT_COMBO";
   return "UNKNOWN";
}

int ModelFlag(const VirtualSignal &s, const int index)
{
   if(index == 0)  return s.model_a;
   if(index == 1)  return s.model_b;
   if(index == 2)  return s.model_c;
   if(index == 3)  return s.model_d;
   if(index == 4)  return s.model_e;
   if(index == 5)  return s.model_f;
   if(index == 6)  return s.model_g;
   if(index == 7)  return s.model_h;
   if(index == 8)  return s.model_i;
   if(index == 9)  return s.model_j;
   if(index == 10) return s.model_k;
   return 0;
}

double OppositeRoomPips(const VirtualSignal &s)
{
   // If no opposing zone is available, distance remains the tracker sentinel.
   // Treat that as open room rather than an automatic rejection.
   return (s.direction > 0) ? s.resistance_distance_pips
                            : s.support_distance_pips;
}

int CalculateQualityPoints(const VirtualSignal &s)
{
   int points = 0;

   // 2 points: direction agrees with the indicator's trend state
   if(s.trend_aligned != 0)
      points += 2;

   // 2 points: entry is close to the correct support/resistance zone
   if(s.near_entry_zone != 0)
      points += 2;

   // 1 point: signal occurs in the expected range extreme
   if(s.range_extreme_fit != 0)
      points += 1;

   // 1 point: execution cost is acceptable for a 5-pip target
   if(s.spread_pips <= ModelD_MaxSpreadPips)
      points += 1;

   // 1 point: virtual stop is not excessively wide
   if(s.risk_pips <= ModelD_MaxRiskPips)
      points += 1;

   // 1 point: stronger raw indicator score
   if(s.signal_score >= 8.0)
      points += 1;

   return points;
}

bool IsMajorActiveSession(const string session)
{
   return (session == "LONDON" ||
           session == "NEW_YORK" ||
           session == "LONDON_NY_OVERLAP");
}

void EvaluateModels(VirtualSignal &s)
{
   s.quality_points = CalculateQualityPoints(s);

   // A — spread only
   s.model_a =
      (s.spread_pips <= ModelA_MaxSpreadPips &&
       s.spread_pct_of_5p <= ModelA_MaxSpreadPct5p) ? 1 : 0;

   // B — spread + risk
   s.model_b =
      (s.spread_pips <= ModelB_MaxSpreadPips &&
       s.risk_pips <= ModelB_MaxRiskPips) ? 1 : 0;

   // C — trend + zone
   bool c_ok = true;
   if(ModelC_RequireTrend && s.trend_aligned == 0) c_ok = false;
   if(ModelC_RequireZone  && s.near_entry_zone == 0) c_ok = false;
   s.model_c = c_ok ? 1 : 0;

   // D — weighted quality score, with hard cost/risk guard
   s.model_d =
      (s.quality_points >= ModelD_MinQualityPoints &&
       s.spread_pips <= ModelD_MaxSpreadPips &&
       s.risk_pips <= ModelD_MaxRiskPips) ? 1 : 0;

   // E — original SELL-focused model
   s.model_e =
      (s.direction < 0 &&
       s.spread_pips <= ModelE_MaxSpreadPips &&
       s.risk_pips <= ModelE_MaxRiskPips) ? 1 : 0;

   // F — original BUY-focused model
   bool f_ok =
      (s.direction > 0 &&
       s.spread_pips <= ModelF_MaxSpreadPips &&
       s.risk_pips <= ModelF_MaxRiskPips);
   if(ModelF_RequireTrend && s.trend_aligned == 0)
      f_ok = false;
   s.model_f = f_ok ? 1 : 0;

   // G — original active-session model
   s.model_g =
      (IsMajorActiveSession(s.session_label) &&
       s.spread_pips <= ModelG_MaxSpreadPips &&
       s.risk_pips <= ModelG_MaxRiskPips) ? 1 : 0;

   const double room = OppositeRoomPips(s);

   // H — room + execution guards
   s.model_h =
      (room >= ModelH_MinOppositeRoomPips &&
       s.spread_pips <= ModelH_MaxSpreadPips &&
       s.risk_pips <= ModelH_MaxRiskPips) ? 1 : 0;

   // I — SELL only, but now trend alignment is mandatory
   s.model_i =
      (s.direction < 0 &&
       s.trend_aligned != 0 &&
       s.spread_pips <= ModelI_MaxSpreadPips &&
       s.risk_pips <= ModelI_MaxRiskPips) ? 1 : 0;

   // J — active London/New York session + minimum room
   s.model_j =
      (IsMajorActiveSession(s.session_label) &&
       room >= ModelJ_MinOppositeRoomPips &&
       s.spread_pips <= ModelJ_MaxSpreadPips &&
       s.risk_pips <= ModelJ_MaxRiskPips) ? 1 : 0;

   // K — candidate asymmetric combination:
   // BUY does not require trend; SELL does.
   bool k_direction_ok = true;
   if(s.direction < 0 && s.trend_aligned == 0)
      k_direction_ok = false;

   s.model_k =
      (k_direction_ok &&
       s.quality_points >= ModelK_MinQualityPoints &&
       room >= ModelK_MinOppositeRoomPips &&
       s.spread_pips <= ModelK_MaxSpreadPips &&
       s.risk_pips <= ModelK_MaxRiskPips) ? 1 : 0;

   for(int i = 0; i < 11; i++)
      if(ModelFlag(s, i) != 0)
         g_model_signals[i]++;
}

string ModelPassSummary(const VirtualSignal &s)
{
   string text = "";
   for(int i = 0; i < 11; i++)
   {
      if(i > 0) text += ",";
      text += StringSubstr("ABCDEFGHIJK", i, 1);
      text += "=";
      text += YesNo(ModelFlag(s, i));
   }
   return text;
}

string FilterReason(const int mask)
{
   if(mask == 0)
      return "PASS";

   string reason = "";

   if((mask & 1) != 0)   reason += "SCORE;";
   if((mask & 2) != 0)   reason += "SPREAD;";
   if((mask & 4) != 0)   reason += "SPREAD_PCT;";
   if((mask & 8) != 0)   reason += "TREND;";
   if((mask & 16) != 0)  reason += "ZONE;";
   if((mask & 32) != 0)  reason += "RANGE;";
   if((mask & 64) != 0)  reason += "RISK;";
   if((mask & 128) != 0) reason += "DIRECTION;";

   const int n = StringLen(reason);
   if(n > 0 && StringSubstr(reason, n - 1, 1) == ";")
      reason = StringSubstr(reason, 0, n - 1);

   return reason;
}

int EvaluateFilter(const VirtualSignal &s)
{
   if(!EnableFilterLab)
      return 0;

   int mask = 0;

   if(s.signal_score < FilterMinSignalScore)
      mask |= 1;

   if(FilterMaxSpreadPips > 0.0 &&
      s.spread_pips > FilterMaxSpreadPips)
      mask |= 2;

   if(FilterMaxSpreadPctOf5p > 0.0 &&
      s.spread_pct_of_5p > FilterMaxSpreadPctOf5p)
      mask |= 4;

   if(FilterRequireTrendAligned &&
      s.trend_aligned == 0)
      mask |= 8;

   if(FilterRequireNearEntryZone &&
      s.near_entry_zone == 0)
      mask |= 16;

   if(FilterRequireRangeExtreme &&
      s.range_extreme_fit == 0)
      mask |= 32;

   if(FilterMaxRiskPips > 0.0 &&
      s.risk_pips > FilterMaxRiskPips)
      mask |= 64;

   if((s.direction > 0 && !FilterAllowBUY) ||
      (s.direction < 0 && !FilterAllowSELL))
      mask |= 128;

   return mask;
}

bool ReadBufferValue(const int buffer,
                     const int shift,
                     double &value)
{
   if(g_indicator_handle == INVALID_HANDLE)
      return false;

   double data[1];

   ResetLastError();

   if(CopyBuffer(g_indicator_handle, buffer, shift, 1, data) != 1)
      return false;

   value = data[0];

   if(!MathIsValidNumber(value))
      return false;

   if(value == EMPTY_VALUE)
      return false;

   return true;
}

double SafeBuffer(const int buffer,
                  const int shift,
                  const double fallback)
{
   double value = fallback;

   if(ReadBufferValue(buffer, shift, value))
      return value;

   return fallback;
}

string DirectionName(const int direction)
{
   return direction > 0 ? "BUY" : "SELL";
}

string OutcomeName(const int outcome)
{
   if(outcome > 0) return "WIN";
   if(outcome < 0) return "LOSS";
   return "TIMEOUT";
}

string YesNo(const int value)
{
   return value != 0 ? "YES" : "NO";
}

int ActiveCount()
{
   int count = 0;

   for(int i = 0; i < ArraySize(g_signals); i++)
      if(g_signals[i].active)
         count++;

   return count;
}

double CurrentSpreadPips()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return 0.0;

   return (tick.ask - tick.bid) / PipSize();
}

bool HasEnoughRoomForSignal()
{
   return ArraySize(g_signals) < MaxTrackedSignals;
}

//============================== LOGGING ==============================
string SymbolCsvName(const string filename)
{
   // Keep every symbol/timeframe in its own file so v2.52 can run
   // side-by-side on many M15 charts without CSV collisions.
   string symbol = _Symbol;
   StringReplace(symbol, "/", "_");
   StringReplace(symbol, "\\", "_");
   StringReplace(symbol, ":", "_");

   string timeframe = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(timeframe, "/", "_");
   StringReplace(timeframe, "\\", "_");
   StringReplace(timeframe, ":", "_");

   const int dot = StringFind(filename, ".csv");

   if(dot >= 0)
      return StringSubstr(filename, 0, dot) + "_" + symbol + "_" + timeframe + ".csv";

   return filename + "_" + symbol + "_" + timeframe;
}

int OpenCsv(const string filename)
{
   if(!EnableCSVLogging)
      return INVALID_HANDLE;

   const string resolved_name = SymbolCsvName(filename);

   int flags =
      FILE_READ |
      FILE_WRITE |
      FILE_CSV |
      FILE_ANSI |
      FILE_SHARE_READ |
      FILE_SHARE_WRITE;

   if(LogToCommonFolder)
      flags |= FILE_COMMON;

   ResetLastError();
   const int handle = FileOpen(resolved_name, flags, ';');

   if(handle == INVALID_HANDLE)
      Print("OutcomeTracker: could not open ", resolved_name,
            " error=", GetLastError());

   return handle;
}

// Fix: uploaded CSVs from a prior run came back as the right file size but
// 100% null bytes -- correct-looking size with zero real content, which
// points at something zeroing the file AFTER MQL5 wrote it (a cloud-sync
// placeholder, e.g. OneDrive Files On-Demand, or antivirus quarantine)
// rather than a write failure in this code. This can't fix an external
// cause, but it gives a definitive signal in the Journal either way: if
// FileWrite itself ever reports 0 bytes, that IS a real bug here and this
// will say so with the error code; if it always reports success but the
// exported file is still empty, that confirms the problem is external.
void VerifyCsvWrite(const int handle, const string context, const uint bytes_written)
{
   if(bytes_written == 0)
   {
      Print("OutcomeTracker: FileWrite wrote 0 bytes for ", context,
            " -- write failed. error=", GetLastError());
      return;
   }

   Print("OutcomeTracker: ", context, " wrote ", bytes_written,
         " bytes this call, file now ", FileSize(handle), " bytes total.");
}

void LogSignalEvent(const VirtualSignal &s)
{
   const int handle = OpenCsv(SignalEventsFileName);

   if(handle == INVALID_HANDLE)
      return;

   if(FileSize(handle) == 0)
   {
      FileWrite(
         handle,
         "id","server_time","signal_bar_time","utc_entry_time",
         "server_hour","utc_hour","server_utc_offset_hours","utc_day","session",
         "symbol","timeframe","direction",
         "signal_close","entry_price","spread_pips",
         "buy_score","sell_score",
         "support_low","support_high","support_strength",
         "resistance_low","resistance_high","resistance_strength",
         "support_distance_pips","resistance_distance_pips","near_zone_threshold_pips",
         "range_position","trend_score","trend_aligned","range_extreme_fit","near_entry_zone",
         "spread_pct_of_5p","signal_score","filter_pass","filter_reason",
         "quality_points","model_A","model_B","model_C","model_D","model_E","model_F","model_G",
         "stop_price","risk_pips","tp_5p","tp_6p","tp_8p","tp_10p","tp_1r","tp_1_5r","tp_2r"
      );
   }

   FileSeek(handle, 0, SEEK_END);

   const uint bytes_written = FileWrite(
      handle,
      StringFormat("%I64d", s.id),
      TimeToString(s.entry_time, TIME_DATE|TIME_SECONDS),
      TimeToString(s.signal_bar_time, TIME_DATE|TIME_MINUTES),
      TimeToString(s.utc_entry_time, TIME_DATE|TIME_SECONDS),
      IntegerToString(s.server_hour),
      IntegerToString(s.utc_hour),
      DoubleToString(s.server_utc_offset_hours, 2),
      DayOfWeekName(s.utc_day_of_week),
      s.session_label,
      _Symbol,
      EnumToString((ENUM_TIMEFRAMES)_Period),
      DirectionName(s.direction),

      DoubleToString(s.signal_close, _Digits),
      DoubleToString(s.entry_price, _Digits),
      DoubleToString(s.spread_pips, 1),

      DoubleToString(s.buy_score, 1),
      DoubleToString(s.sell_score, 1),

      s.support_low > 0 ? DoubleToString(s.support_low, _Digits) : "",
      s.support_high > 0 ? DoubleToString(s.support_high, _Digits) : "",
      DoubleToString(s.support_strength, 0),

      s.resistance_low > 0 ? DoubleToString(s.resistance_low, _Digits) : "",
      s.resistance_high > 0 ? DoubleToString(s.resistance_high, _Digits) : "",
      DoubleToString(s.resistance_strength, 0),

      DoubleToString(s.support_distance_pips, 1),
      DoubleToString(s.resistance_distance_pips, 1),
      DoubleToString(s.near_zone_threshold_pips, 1),

      s.range_position >= 0 ? DoubleToString(s.range_position, 1) : "",
      DoubleToString(s.trend_score, 1),
      YesNo(s.trend_aligned),
      YesNo(s.range_extreme_fit),
      YesNo(s.near_entry_zone),
      DoubleToString(s.spread_pct_of_5p, 1),
      DoubleToString(s.signal_score, 1),
      YesNo(s.filter_pass),
      FilterReason(s.filter_fail_mask),
      IntegerToString(s.quality_points),
      YesNo(s.model_a),
      YesNo(s.model_b),
      YesNo(s.model_c),
      YesNo(s.model_d),
      YesNo(s.model_e),
      YesNo(s.model_f),
      YesNo(s.model_g),

      DoubleToString(s.stop_price, _Digits),
      DoubleToString(s.risk_pips, 1),
      DoubleToString(s.tp5_price, _Digits),
      DoubleToString(s.tp6_price, _Digits),
      DoubleToString(s.tp8_price, _Digits),
      DoubleToString(s.tp10_price, _Digits),
      DoubleToString(s.tp1_price, _Digits),
      DoubleToString(s.tp15_price, _Digits),
      DoubleToString(s.tp2_price, _Digits)
   );

   VerifyCsvWrite(handle, "Signals row", bytes_written);

   FileFlush(handle);
   FileClose(handle);
}

void LogCompletedResult(const VirtualSignal &s,
                        const string close_reason,
                        const datetime close_time)
{
   const int handle = OpenCsv(ResultsFileName);

   if(handle == INVALID_HANDLE)
      return;

   if(FileSize(handle) == 0)
   {
      FileWrite(
         handle,
         "id","signal_bar_time","entry_time","close_time","utc_entry_time",
         "utc_hour","utc_day","session",
         "symbol","timeframe","direction",
         "entry_price","stop_price","risk_pips","spread_pips","spread_pct_of_5p",
         "buy_score","sell_score",
         "support_low","support_high","support_strength","support_distance_pips",
         "resistance_low","resistance_high","resistance_strength","resistance_distance_pips",
         "range_position","trend_score","trend_aligned","range_extreme_fit","near_entry_zone",
         "signal_score","filter_pass","filter_reason",
         "quality_points","model_A","model_B","model_C","model_D","model_E","model_F","model_G",
         "exit_price","exit_pl_pips","timeout_pl_pips",
         "mfe_pips","mae_pips","bars_held",
         "outcome_5p","outcome_6p","outcome_8p","outcome_10p",
         "outcome_1r","outcome_1_5r","outcome_2r",
         "hit_5p_time","hit_6p_time","hit_8p_time","hit_10p_time",
         "close_reason"
      );
   }

   FileSeek(handle, 0, SEEK_END);

   const uint bytes_written = FileWrite(
      handle,
      StringFormat("%I64d", s.id),
      TimeToString(s.signal_bar_time, TIME_DATE|TIME_MINUTES),
      TimeToString(s.entry_time, TIME_DATE|TIME_SECONDS),
      TimeToString(close_time, TIME_DATE|TIME_SECONDS),
      TimeToString(s.utc_entry_time, TIME_DATE|TIME_SECONDS),
      IntegerToString(s.utc_hour),
      DayOfWeekName(s.utc_day_of_week),
      s.session_label,

      _Symbol,
      EnumToString((ENUM_TIMEFRAMES)_Period),
      DirectionName(s.direction),

      DoubleToString(s.entry_price, _Digits),
      DoubleToString(s.stop_price, _Digits),
      DoubleToString(s.risk_pips, 1),
      DoubleToString(s.spread_pips, 1),
      DoubleToString(s.spread_pct_of_5p, 1),

      DoubleToString(s.buy_score, 1),
      DoubleToString(s.sell_score, 1),

      s.support_low > 0 ? DoubleToString(s.support_low, _Digits) : "",
      s.support_high > 0 ? DoubleToString(s.support_high, _Digits) : "",
      DoubleToString(s.support_strength, 0),
      DoubleToString(s.support_distance_pips, 1),

      s.resistance_low > 0 ? DoubleToString(s.resistance_low, _Digits) : "",
      s.resistance_high > 0 ? DoubleToString(s.resistance_high, _Digits) : "",
      DoubleToString(s.resistance_strength, 0),
      DoubleToString(s.resistance_distance_pips, 1),

      s.range_position >= 0 ? DoubleToString(s.range_position, 1) : "",
      DoubleToString(s.trend_score, 1),
      YesNo(s.trend_aligned),
      YesNo(s.range_extreme_fit),
      YesNo(s.near_entry_zone),
      DoubleToString(s.signal_score, 1),
      YesNo(s.filter_pass),
      FilterReason(s.filter_fail_mask),
      IntegerToString(s.quality_points),
      YesNo(s.model_a),
      YesNo(s.model_b),
      YesNo(s.model_c),
      YesNo(s.model_d),
      YesNo(s.model_e),
      YesNo(s.model_f),
      YesNo(s.model_g),
      DoubleToString(s.exit_price, _Digits),
      DoubleToString(s.exit_pl_pips, 1),
      DoubleToString(s.timeout_pl_pips, 1),

      DoubleToString(s.mfe_pips, 1),
      DoubleToString(s.mae_pips, 1),
      IntegerToString(s.bars_held),

      OutcomeName(s.outcome_5p),
      OutcomeName(s.outcome_6p),
      OutcomeName(s.outcome_8p),
      OutcomeName(s.outcome_10p),
      OutcomeName(s.outcome_1r),
      OutcomeName(s.outcome_15r),
      OutcomeName(s.outcome_2r),

      s.hit_5p_time > 0 ? TimeToString(s.hit_5p_time, TIME_DATE|TIME_SECONDS) : "",
      s.hit_6p_time > 0 ? TimeToString(s.hit_6p_time, TIME_DATE|TIME_SECONDS) : "",
      s.hit_8p_time > 0 ? TimeToString(s.hit_8p_time, TIME_DATE|TIME_SECONDS) : "",
      s.hit_10p_time > 0 ? TimeToString(s.hit_10p_time, TIME_DATE|TIME_SECONDS) : "",

      close_reason
   );

   VerifyCsvWrite(handle, "Results row", bytes_written);

   FileFlush(handle);
   FileClose(handle);
}

//====================== DIAGNOSTIC MODEL CSV =========================
void LogOptimizationResult(const VirtualSignal &s,
                           const string close_reason,
                           const datetime close_time)
{
   const int handle = OpenCsv(OptimizationFileName);
   if(handle == INVALID_HANDLE)
      return;

   if(FileSize(handle) == 0)
   {
      FileWrite(
         handle,
         "id","entry_time","close_time","symbol","direction","session",
         "signal_score","quality_points","spread_pips","risk_pips",
         "opposite_room_pips","trend_aligned","range_fit","zone_near",
         "model_H_room","model_I_sell_trend","model_J_session_room","model_K_combo",
         "early_progress_checked","early_progress_pass","early_check_pl_pips","early_exit_pl_pips",
         "mfe_pips","mae_pips","timeout_pl_pips",
         "outcome_5p","outcome_6p","outcome_8p","outcome_10p","close_reason"
      );
   }

   FileSeek(handle,0,SEEK_END);

   const uint bytes_written = FileWrite(
      handle,
      StringFormat("%I64d",s.id),
      TimeToString(s.entry_time,TIME_DATE|TIME_SECONDS),
      TimeToString(close_time,TIME_DATE|TIME_SECONDS),
      _Symbol,
      DirectionName(s.direction),
      s.session_label,
      DoubleToString(s.signal_score,1),
      IntegerToString(s.quality_points),
      DoubleToString(s.spread_pips,1),
      DoubleToString(s.risk_pips,1),
      DoubleToString(OppositeRoomPips(s),1),
      YesNo(s.trend_aligned),
      YesNo(s.range_extreme_fit),
      YesNo(s.near_entry_zone),
      YesNo(s.model_h),
      YesNo(s.model_i),
      YesNo(s.model_j),
      YesNo(s.model_k),
      YesNo(s.early_progress_checked),
      YesNo(s.early_progress_pass),
      DoubleToString(s.early_progress_check_pl_pips,1),
      DoubleToString(s.early_exit_pl_pips,1),
      DoubleToString(s.mfe_pips,1),
      DoubleToString(s.mae_pips,1),
      DoubleToString(s.timeout_pl_pips,1),
      OutcomeName(s.outcome_5p),
      OutcomeName(s.outcome_6p),
      OutcomeName(s.outcome_8p),
      OutcomeName(s.outcome_10p),
      close_reason
   );

   VerifyCsvWrite(handle, "Diagnostics row", bytes_written);

   FileFlush(handle);
   FileClose(handle);
}

//================ SOFT CONFIRMATION MODELS ===========================
string ConfirmName(const double f)
{
   if(MathAbs(f-0.50)<0.001) return "L50";
   if(MathAbs(f-0.75)<0.001) return "L75";
   return "L100";
}

string ConfirmFileName(const double f)
{
   if(MathAbs(f-0.50)<0.001) return ConfirmL50FileName;
   if(MathAbs(f-0.75)<0.001) return ConfirmL75FileName;
   return ConfirmL100FileName;
}

void LogConfirm(const ConfirmSignal &c,const string final_state,const datetime event_time)
{
   const int handle=OpenCsv(ConfirmFileName(c.confirm_fraction));
   if(handle==INVALID_HANDLE) return;

   if(FileSize(handle)==0)
   {
      FileWrite(handle,
         "source_id","event_time","symbol","timeframe","model","direction","session",
         "signal_bar_time","signal_high","signal_low","confirm_fraction","confirm_level",
         "raw_entry","confirmed","confirmation_time","confirmation_entry","entry_cost_pips",
         "risk_pips","bars_waited","bars_held","mfe_pips","mae_pips","exit_pl_pips",
         "timeout_pl_pips","outcome_5p","outcome_6p","outcome_8p","outcome_10p",
         "quality_points","final_state");
   }

   FileSeek(handle,0,SEEK_END);
   FileWrite(handle,
      StringFormat("%I64d",c.source_id),
      TimeToString(event_time,TIME_DATE|TIME_SECONDS),
      _Symbol,
      EnumToString((ENUM_TIMEFRAMES)_Period),
      ConfirmName(c.confirm_fraction),
      DirectionName(c.direction),
      c.session_label,
      TimeToString(c.signal_bar_time,TIME_DATE|TIME_MINUTES),
      DoubleToString(c.signal_high,_Digits),
      DoubleToString(c.signal_low,_Digits),
      DoubleToString(c.confirm_fraction,2),
      DoubleToString(c.confirm_level,_Digits),
      DoubleToString(c.raw_entry_price,_Digits),
      YesNo(c.confirmed),
      c.confirmation_time>0 ? TimeToString(c.confirmation_time,TIME_DATE|TIME_SECONDS) : "",
      c.confirmation_entry>0.0 ? DoubleToString(c.confirmation_entry,_Digits) : "",
      DoubleToString(c.entry_cost_pips,1),
      DoubleToString(c.risk_pips,1),
      IntegerToString(c.wait_bars),
      IntegerToString(c.bars_held),
      DoubleToString(c.mfe_pips,1),
      DoubleToString(c.mae_pips,1),
      DoubleToString(c.exit_pl_pips,1),
      DoubleToString(c.timeout_pl_pips,1),
      OutcomeName(c.outcome_5p),
      OutcomeName(c.outcome_6p),
      OutcomeName(c.outcome_8p),
      OutcomeName(c.outcome_10p),
      IntegerToString(c.quality_points),
      final_state);
   FileFlush(handle);
   FileClose(handle);
}

void IncCandidate(const double f)
{
   if(MathAbs(f-0.50)<0.001) g_l50_candidates++;
   else if(MathAbs(f-0.75)<0.001) g_l75_candidates++;
   else g_l100_candidates++;
}

void IncConfirmed(const double f,const double cost)
{
   if(MathAbs(f-0.50)<0.001){g_l50_confirmed++; g_l50_entry_cost_sum+=cost;}
   else if(MathAbs(f-0.75)<0.001){g_l75_confirmed++; g_l75_entry_cost_sum+=cost;}
   else {g_l100_confirmed++; g_l100_entry_cost_sum+=cost;}
}

void IncNoEntry(const double f)
{
   if(MathAbs(f-0.50)<0.001) g_l50_no_entry++;
   else if(MathAbs(f-0.75)<0.001) g_l75_no_entry++;
   else g_l100_no_entry++;
}

void IncCompleted(const ConfirmSignal &c)
{
   if(MathAbs(c.confirm_fraction-0.50)<0.001)
   {
      g_l50_completed++;
      if(c.outcome_5p>0) g_l50_5p_wins++; else if(c.outcome_5p<0) g_l50_5p_losses++; else g_l50_5p_timeouts++;
   }
   else if(MathAbs(c.confirm_fraction-0.75)<0.001)
   {
      g_l75_completed++;
      if(c.outcome_5p>0) g_l75_5p_wins++; else if(c.outcome_5p<0) g_l75_5p_losses++; else g_l75_5p_timeouts++;
   }
   else
   {
      g_l100_completed++;
      if(c.outcome_5p>0) g_l100_5p_wins++; else if(c.outcome_5p<0) g_l100_5p_losses++; else g_l100_5p_timeouts++;
   }
}

void CreateConfirmCandidate(ConfirmSignal &arr[],const VirtualSignal &s,const double f)
{
   ConfirmSignal c;
   ZeroMemory(c);
   c.active=true;
   c.source_id=s.id;
   c.direction=s.direction;
   c.signal_bar_time=s.signal_bar_time;
   c.created_time=TimeCurrent();
   c.raw_entry_price=s.entry_price;
   c.signal_high=iHigh(_Symbol,_Period,1);
   c.signal_low=iLow(_Symbol,_Period,1);
   c.confirm_fraction=f;

   const double range=MathMax(_Point,c.signal_high-c.signal_low);
   c.confirm_level=(c.direction>0)
      ? c.signal_low + f*range
      : c.signal_high - f*range;

   c.structural_stop_price=s.stop_price;
   c.wait_bars=0;
   c.last_wait_bar=iTime(_Symbol,_Period,0);
   c.confirmed=0;
   c.session_label=s.session_label;
   c.quality_points=s.quality_points;

   const int n=ArraySize(arr);
   ArrayResize(arr,n+1);
   arr[n]=c;
   IncCandidate(f);
}

void CreateAllConfirmCandidates(const VirtualSignal &s)
{
   CreateConfirmCandidate(g_confirm_l50,s,Confirm_L50_Fraction);
   CreateConfirmCandidate(g_confirm_l75,s,Confirm_L75_Fraction);
   CreateConfirmCandidate(g_confirm_l100,s,Confirm_L100_Fraction);
}

void UpdateConfirmMfeMae(ConfirmSignal &c,const double liquidation_price)
{
   if(c.confirmed==0 || c.confirmation_entry<=0.0) return;
   const double pip=PipSize();
   const double favorable=(c.direction>0)
      ? (liquidation_price-c.confirmation_entry)/pip
      : (c.confirmation_entry-liquidation_price)/pip;
   const double adverse=(c.direction>0)
      ? (c.confirmation_entry-liquidation_price)/pip
      : (liquidation_price-c.confirmation_entry)/pip;
   if(favorable>c.mfe_pips) c.mfe_pips=favorable;
   if(adverse>c.mae_pips) c.mae_pips=adverse;
}

void FinalizeConfirm(ConfirmSignal &c,const string reason,const datetime event_time)
{
   if(!c.active) return;
   c.active=false;
   const string name=ConfirmName(c.confirm_fraction);

   if(c.confirmed==0)
   {
      IncNoEntry(c.confirm_fraction);
      LogConfirm(c,"NO_ENTRY_"+reason,event_time);
      Print(name," NO ENTRY #",c.source_id," ",DirectionName(c.direction),
            " | no confirmation within ",IntegerToString(Confirm_MaxBars)," bars");
      return;
   }

   IncCompleted(c);
   LogConfirm(c,reason,event_time);

   Print(name," COMPLETE #",c.source_id," ",DirectionName(c.direction),
      " | 5p=",OutcomeName(c.outcome_5p),
      " 6p=",OutcomeName(c.outcome_6p),
      " 8p=",OutcomeName(c.outcome_8p),
      " 10p=",OutcomeName(c.outcome_10p),
      " | entry=",DoubleToString(c.confirmation_entry,_Digits),
      " cost=",DoubleToString(c.entry_cost_pips,1),"p",
      " risk=",DoubleToString(c.risk_pips,1),"p",
      " MFE=",DoubleToString(c.mfe_pips,1),"p",
      " MAE=",DoubleToString(c.mae_pips,1),"p",
      " exitPL=",DoubleToString(c.exit_pl_pips,1),"p",
      " | reason=",reason);
}

void ConfirmNow(ConfirmSignal &c,const MqlTick &tick,const datetime current_bar)
{
   c.confirmed=1;
   c.confirmation_time=TimeCurrent();
   c.confirmation_entry=(c.direction>0)?tick.ask:tick.bid;
   const double pip=PipSize();

   c.entry_cost_pips=(c.direction>0)
      ? (c.confirmation_entry-c.raw_entry_price)/pip
      : (c.raw_entry_price-c.confirmation_entry)/pip;

   c.risk_pips=(c.direction>0)
      ? (c.confirmation_entry-c.structural_stop_price)/pip
      : (c.structural_stop_price-c.confirmation_entry)/pip;

   if(c.risk_pips<=0.0)
   {
      c.confirmed=0;
      FinalizeConfirm(c,"INVALID_RISK",TimeCurrent());
      return;
   }

   if(c.direction>0)
   {
      c.tp5_price=c.confirmation_entry+5.0*pip;
      c.tp6_price=c.confirmation_entry+6.0*pip;
      c.tp8_price=c.confirmation_entry+8.0*pip;
      c.tp10_price=c.confirmation_entry+10.0*pip;
   }
   else
   {
      c.tp5_price=c.confirmation_entry-5.0*pip;
      c.tp6_price=c.confirmation_entry-6.0*pip;
      c.tp8_price=c.confirmation_entry-8.0*pip;
      c.tp10_price=c.confirmation_entry-10.0*pip;
   }

   c.last_counted_bar=current_bar;
   c.bars_held=0;
   IncConfirmed(c.confirm_fraction,c.entry_cost_pips);

   Print(ConfirmName(c.confirm_fraction)," CONFIRMED #",c.source_id," ",
      DirectionName(c.direction)," after ",IntegerToString(c.wait_bars)," bar(s)",
      " | level=",DoubleToString(c.confirm_level,_Digits),
      " entry=",DoubleToString(c.confirmation_entry,_Digits),
      " cost=",DoubleToString(c.entry_cost_pips,1),"p",
      " risk=",DoubleToString(c.risk_pips,1),"p");
}

void UpdateConfirmArray(ConfirmSignal &arr[])
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;
   const datetime current_bar=iTime(_Symbol,_Period,0);

   for(int i=0;i<ArraySize(arr);i++)
   {
      if(!arr[i].active) continue;
      ConfirmSignal c=arr[i];

      if(c.confirmed==0)
      {
         if(current_bar>0 && current_bar!=c.last_wait_bar)
         {
            c.last_wait_bar=current_bar;
            c.wait_bars++;
            const double closed_price=iClose(_Symbol,_Period,1);

            const bool passed=(c.direction>0)
               ? (closed_price>=c.confirm_level)
               : (closed_price<=c.confirm_level);

            if(passed)
               ConfirmNow(c,tick,current_bar);
            else if(Confirm_MaxBars>0 && c.wait_bars>=Confirm_MaxBars)
            {
               FinalizeConfirm(c,"NO_CONFIRMATION",TimeCurrent());
               arr[i]=c;
               continue;
            }
         }

         arr[i]=c;
         continue;
      }

      const double exit_price=(c.direction>0)?tick.bid:tick.ask;
      c.exit_pl_pips=(c.direction>0)
         ? (exit_price-c.confirmation_entry)/PipSize()
         : (c.confirmation_entry-exit_price)/PipSize();

      UpdateConfirmMfeMae(c,exit_price);

      if(current_bar>0 && current_bar!=c.last_counted_bar)
      {
         c.bars_held++;
         c.last_counted_bar=current_bar;
      }

      if(c.direction>0)
      {
         if(c.outcome_5p==0 && exit_price>=c.tp5_price) c.outcome_5p=1;
         if(c.outcome_6p==0 && exit_price>=c.tp6_price) c.outcome_6p=1;
         if(c.outcome_8p==0 && exit_price>=c.tp8_price) c.outcome_8p=1;
         if(c.outcome_10p==0 && exit_price>=c.tp10_price) c.outcome_10p=1;

         if(exit_price<=c.structural_stop_price)
         {
            if(c.outcome_5p==0) c.outcome_5p=-1;
            if(c.outcome_6p==0) c.outcome_6p=-1;
            if(c.outcome_8p==0) c.outcome_8p=-1;
            if(c.outcome_10p==0) c.outcome_10p=-1;
            FinalizeConfirm(c,"STOP_HIT",TimeCurrent());
            arr[i]=c;
            continue;
         }
      }
      else
      {
         if(c.outcome_5p==0 && exit_price<=c.tp5_price) c.outcome_5p=1;
         if(c.outcome_6p==0 && exit_price<=c.tp6_price) c.outcome_6p=1;
         if(c.outcome_8p==0 && exit_price<=c.tp8_price) c.outcome_8p=1;
         if(c.outcome_10p==0 && exit_price<=c.tp10_price) c.outcome_10p=1;

         if(exit_price>=c.structural_stop_price)
         {
            if(c.outcome_5p==0) c.outcome_5p=-1;
            if(c.outcome_6p==0) c.outcome_6p=-1;
            if(c.outcome_8p==0) c.outcome_8p=-1;
            if(c.outcome_10p==0) c.outcome_10p=-1;
            FinalizeConfirm(c,"STOP_HIT",TimeCurrent());
            arr[i]=c;
            continue;
         }
      }

      if(Confirm_TimeoutBars>0 && c.bars_held>=Confirm_TimeoutBars)
      {
         c.timeout_pl_pips=c.exit_pl_pips;
         FinalizeConfirm(c,"TIMEOUT",TimeCurrent());
         arr[i]=c;
         continue;
      }

      arr[i]=c;
   }
}

void UpdateAllConfirmModels()
{
   UpdateConfirmArray(g_confirm_l50);
   UpdateConfirmArray(g_confirm_l75);
   UpdateConfirmArray(g_confirm_l100);
}

//==================== P5G / ADAPTIVE STALL MANAGEMENT ===============
string ManagementModelName(const int model_id)
{
   if(model_id == MGMT_P5G) return "P5G";
   if(model_id == MGMT_DG2) return "DG2";
   if(model_id == MGMT_DG4) return "DG4";
   return "DG6";
}

void IncrementManagementCandidate(const int model_id)
{
   if(model_id == MGMT_P5G) g_p5g_candidates++;
   else if(model_id == MGMT_DG2) g_dg2_candidates++;
   else if(model_id == MGMT_DG4) g_dg4_candidates++;
   else g_dg6_candidates++;
}

void IncrementManagementPass(const int model_id)
{
   if(model_id == MGMT_P5G) g_p5g_progress_pass++;
   else if(model_id == MGMT_DG2) g_dg2_progress_pass++;
   else if(model_id == MGMT_DG4) g_dg4_progress_pass++;
   else g_dg6_progress_pass++;
}

void IncrementManagementResult(const EarlyExitSignal &e,
                               const string reason)
{
   if(e.model_id == MGMT_P5G)
   {
      g_p5g_completed++;
      if(reason == "FIXED_TP5") g_p5g_tp5_wins++;
      else if(reason == "STOP_HIT") g_p5g_stop_losses++;
      else if(reason == "EARLY_EXIT_STALL")
      {
         g_p5g_stall_exits++;
         g_p5g_stall_exit_pl_sum += e.exit_pl_pips;
      }
      else if(reason == "REVERSAL_GUARD")
      {
         g_p5g_guard_exits++;
         g_p5g_guard_exit_pl_sum += e.exit_pl_pips;
      }
      else if(reason == "TIMEOUT") g_p5g_timeouts++;
   }
   else if(e.model_id == MGMT_DG2)
   {
      g_dg2_completed++;
      if(reason == "FIXED_TP5") g_dg2_tp5_wins++;
      else if(reason == "STOP_HIT") g_dg2_stop_losses++;
      else if(reason == "DAMAGE_STALL")
      {
         g_dg2_stall_exits++;
         g_dg2_stall_exit_pl_sum += e.exit_pl_pips;
      }
      else if(reason == "REVERSAL_GUARD")
      {
         g_dg2_guard_exits++;
         g_dg2_guard_exit_pl_sum += e.exit_pl_pips;
      }
      else if(reason == "TIMEOUT") g_dg2_timeouts++;
   }
   else if(e.model_id == MGMT_DG4)
   {
      g_dg4_completed++;
      if(reason == "FIXED_TP5") g_dg4_tp5_wins++;
      else if(reason == "STOP_HIT") g_dg4_stop_losses++;
      else if(reason == "DAMAGE_STALL")
      {
         g_dg4_stall_exits++;
         g_dg4_stall_exit_pl_sum += e.exit_pl_pips;
      }
      else if(reason == "REVERSAL_GUARD")
      {
         g_dg4_guard_exits++;
         g_dg4_guard_exit_pl_sum += e.exit_pl_pips;
      }
      else if(reason == "TIMEOUT") g_dg4_timeouts++;
   }
   else
   {
      g_dg6_completed++;
      if(reason == "FIXED_TP5") g_dg6_tp5_wins++;
      else if(reason == "STOP_HIT") g_dg6_stop_losses++;
      else if(reason == "DAMAGE_STALL")
      {
         g_dg6_stall_exits++;
         g_dg6_stall_exit_pl_sum += e.exit_pl_pips;
      }
      else if(reason == "REVERSAL_GUARD")
      {
         g_dg6_guard_exits++;
         g_dg6_guard_exit_pl_sum += e.exit_pl_pips;
      }
      else if(reason == "TIMEOUT") g_dg6_timeouts++;
   }
}

void LogManagementResult(const EarlyExitSignal &e,
                         const string reason,
                         const datetime event_time)
{
   const int handle = OpenCsv(ManagementFileName);
   if(handle == INVALID_HANDLE)
      return;

   if(FileSize(handle) == 0)
   {
      FileWrite(
         handle,
         "source_id","event_time","symbol","timeframe","model","direction","session",
         "signal_bar_time","entry_time","entry_price","structural_stop",
         "start_bars","min_progress_pips","damage_gate_pips","fixed_tp_pips",
         "stall_monitor_started","progress_passed",
         "guard_armed","guard_triggered",
         "bars_held","mfe_pips","mae_pips","giveback_pips",
         "exit_price","exit_pl_pips",
         "quality_points","signal_score","reason"
      );
   }

   FileSeek(handle,0,SEEK_END);

   FileWrite(
      handle,
      StringFormat("%I64d",e.source_id),
      TimeToString(event_time,TIME_DATE|TIME_SECONDS),
      _Symbol,
      EnumToString((ENUM_TIMEFRAMES)_Period),
      ManagementModelName(e.model_id),
      DirectionName(e.direction),
      e.session_label,
      TimeToString(e.signal_bar_time,TIME_DATE|TIME_MINUTES),
      TimeToString(e.entry_time,TIME_DATE|TIME_SECONDS),
      DoubleToString(e.entry_price,_Digits),
      DoubleToString(e.structural_stop_price,_Digits),
      IntegerToString(e.start_bars),
      DoubleToString(ManagementMinProgressPips,1),
      DoubleToString(e.damage_gate_pips,1),
      DoubleToString(ManagementFixedTPPips,1),
      YesNo(e.stall_monitor_started),
      YesNo(e.progress_passed),
      YesNo(e.guard_armed),
      YesNo(e.guard_triggered),
      IntegerToString(e.bars_held),
      DoubleToString(e.mfe_pips,1),
      DoubleToString(e.mae_pips,1),
      DoubleToString(e.giveback_pips,1),
      DoubleToString(e.exit_price,_Digits),
      DoubleToString(e.exit_pl_pips,1),
      IntegerToString(e.quality_points),
      DoubleToString(e.signal_score,1),
      reason
   );

   FileFlush(handle);
   FileClose(handle);
}

void CreateManagementCandidate(EarlyExitSignal &arr[],
                               const VirtualSignal &s,
                               const int model_id,
                               const double damage_gate_pips)
{
   EarlyExitSignal e;
   ZeroMemory(e);

   e.active = true;
   e.source_id = s.id;
   e.direction = s.direction;
   e.model_id = model_id;

   e.signal_bar_time = s.signal_bar_time;
   e.entry_time = s.entry_time;
   e.entry_price = s.entry_price;
   e.structural_stop_price = s.stop_price;

   e.tp5_price =
      e.direction > 0 ?
      e.entry_price + ManagementFixedTPPips * PipSize() :
      e.entry_price - ManagementFixedTPPips * PipSize();

   e.start_bars = ManagementStartBars;
   e.stall_monitor_started = 0;
   e.progress_passed = 0;
   e.damage_gate_pips = damage_gate_pips;

   e.guard_armed = 0;
   e.guard_triggered = 0;

   e.mfe_pips = 0.0;
   e.mae_pips = 0.0;
   e.exit_price = e.entry_price;
   e.exit_pl_pips = 0.0;
   e.giveback_pips = 0.0;

   e.bars_held = 0;
   e.last_counted_bar = iTime(_Symbol,_Period,0);

   e.session_label = s.session_label;
   e.quality_points = s.quality_points;
   e.signal_score = s.signal_score;

   const int n = ArraySize(arr);
   ArrayResize(arr,n+1);
   arr[n] = e;

   IncrementManagementCandidate(model_id);
}

void CreateAllEarlyExitCandidates(const VirtualSignal &s)
{
   // P5G is the v2.4.6 control.
   // DG2/DG4/DG6 isolate the damage threshold while keeping every
   // other management rule identical.
   CreateManagementCandidate(g_mgmt_p5g,s,MGMT_P5G,0.0);
   CreateManagementCandidate(g_mgmt_dg2,s,MGMT_DG2,DamageGate2Pips);
   CreateManagementCandidate(g_mgmt_dg4,s,MGMT_DG4,DamageGate4Pips);
   CreateManagementCandidate(g_mgmt_dg6,s,MGMT_DG6,DamageGate6Pips);
}

void UpdateManagementMfeMae(EarlyExitSignal &e,
                            const double liquidation_price)
{
   const double pip = PipSize();

   const double favorable =
      e.direction > 0 ?
      (liquidation_price-e.entry_price)/pip :
      (e.entry_price-liquidation_price)/pip;

   const double adverse =
      e.direction > 0 ?
      (e.entry_price-liquidation_price)/pip :
      (liquidation_price-e.entry_price)/pip;

   if(favorable > e.mfe_pips)
      e.mfe_pips = favorable;

   if(adverse > e.mae_pips)
      e.mae_pips = adverse;

   e.giveback_pips = e.mfe_pips - e.exit_pl_pips;
}

void FinalizeManagement(EarlyExitSignal &e,
                        const string reason,
                        const datetime event_time)
{
   if(!e.active)
      return;

   e.active = false;
   IncrementManagementResult(e,reason);
   LogManagementResult(e,reason,event_time);

   Print(
      ManagementModelName(e.model_id)," COMPLETE #",e.source_id,
      " ",DirectionName(e.direction),
      " | exit=",reason,
      " | MFE=",DoubleToString(e.mfe_pips,1),"p",
      " MAE=",DoubleToString(e.mae_pips,1),"p",
      " giveback=",DoubleToString(e.giveback_pips,1),"p",
      " exitPL=",DoubleToString(e.exit_pl_pips,1),"p",
      " bars=",IntegerToString(e.bars_held)
   );
}

void MarkProgressPassed(EarlyExitSignal &e)
{
   if(e.progress_passed != 0)
      return;

   e.progress_passed = 1;
   IncrementManagementPass(e.model_id);

   Print(
      ManagementModelName(e.model_id)," PASS #",e.source_id,
      " ",DirectionName(e.direction),
      " | MFE=",DoubleToString(e.mfe_pips,1),"p",
      " | bars=",IntegerToString(e.bars_held)
   );
}

void UpdateManagementArray(EarlyExitSignal &arr[])
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return;

   const datetime current_bar = iTime(_Symbol,_Period,0);

   for(int i=0;i<ArraySize(arr);i++)
   {
      if(!arr[i].active)
         continue;

      EarlyExitSignal e = arr[i];

      const double market_exit_price =
         e.direction > 0 ? tick.bid : tick.ask;

      e.exit_price = market_exit_price;

      e.exit_pl_pips =
         e.direction > 0 ?
         (market_exit_price-e.entry_price)/PipSize() :
         (e.entry_price-market_exit_price)/PipSize();

      UpdateManagementMfeMae(e,market_exit_price);

      if(current_bar > 0 && current_bar != e.last_counted_bar)
      {
         e.bars_held++;
         e.last_counted_bar = current_bar;
      }

      // 1) Fixed +5p TP always wins first.
      const bool tp5_hit =
         e.direction > 0 ?
         (market_exit_price >= e.tp5_price) :
         (market_exit_price <= e.tp5_price);

      if(tp5_hit)
      {
         e.exit_price = e.tp5_price;
         e.exit_pl_pips = ManagementFixedTPPips;
         e.giveback_pips = MathMax(0.0,e.mfe_pips-e.exit_pl_pips);

         FinalizeManagement(e,"FIXED_TP5",TimeCurrent());
         arr[i] = e;
         continue;
      }

      // 2) Original structural stop remains the hard fail-safe.
      const bool stop_hit =
         e.direction > 0 ?
         (market_exit_price <= e.structural_stop_price) :
         (market_exit_price >= e.structural_stop_price);

      if(stop_hit)
      {
         FinalizeManagement(e,"STOP_HIT",TimeCurrent());
         arr[i] = e;
         continue;
      }

      // 3) Once +2p MFE has been achieved, the trade has proved some
      //    favorable movement. Stall exits are permanently disabled.
      //    The peak-giveback reversal guard becomes the protection.
      if(e.mfe_pips >= ManagementMinProgressPips)
      {
         if(e.bars_held >= e.start_bars)
            MarkProgressPassed(e);

         e.guard_armed = 1;
         e.giveback_pips = e.mfe_pips - e.exit_pl_pips;

         if(e.giveback_pips >= ReversalGuardGivebackPips &&
            e.exit_pl_pips <= -ReversalGuardMaxNegativePips)
         {
            e.guard_triggered = 1;

            FinalizeManagement(e,"REVERSAL_GUARD",TimeCurrent());
            arr[i] = e;
            continue;
         }
      }

      // 4) Stall logic begins at bar 5.
      if(e.start_bars > 0 &&
         e.bars_held >= e.start_bars &&
         e.progress_passed == 0 &&
         e.mfe_pips < ManagementMinProgressPips)
      {
         if(e.stall_monitor_started == 0)
         {
            e.stall_monitor_started = 1;

            Print(
               ManagementModelName(e.model_id)," STALL WATCH #",e.source_id,
               " ",DirectionName(e.direction),
               " | MFE=",DoubleToString(e.mfe_pips,1),"p",
               " currentPL=",DoubleToString(e.exit_pl_pips,1),"p",
               " gate=",DoubleToString(e.damage_gate_pips,1),"p",
               " bars=",IntegerToString(e.bars_held)
            );
         }

         // P5G control: 0.0 gate means mandatory exit at bar 5.
         if(e.model_id == MGMT_P5G)
         {
            FinalizeManagement(e,"EARLY_EXIT_STALL",TimeCurrent());
            arr[i] = e;
            continue;
         }

         // Adaptive models do NOT exit merely because progress is slow.
         // They exit only when the trade is both unproven and materially
         // negative. This check remains active after bar 5 until either
         // +2p MFE is achieved, +5p TP is hit, stop is hit, or timeout.
         if(e.exit_pl_pips <= -e.damage_gate_pips)
         {
            FinalizeManagement(e,"DAMAGE_STALL",TimeCurrent());
            arr[i] = e;
            continue;
         }
      }

      if(ManagementTimeoutBars > 0 &&
         e.bars_held >= ManagementTimeoutBars)
      {
         FinalizeManagement(e,"TIMEOUT",TimeCurrent());
         arr[i] = e;
         continue;
      }

      arr[i] = e;
   }
}

void UpdateAllEarlyExitModels()
{
   UpdateManagementArray(g_mgmt_p5g);
   UpdateManagementArray(g_mgmt_dg2);
   UpdateManagementArray(g_mgmt_dg4);
   UpdateManagementArray(g_mgmt_dg6);
}

//=========================== SIGNAL CREATION =========================
bool GetNewConfirmedDecision(int &direction,
                             datetime &signal_bar_time)
{
   direction = 0;

   // We inspect the just-closed candle.
   double decision_value = 0.0;

   if(!ReadBufferValue(DecisionBufferIndex, 1, decision_value))
      return false;

   const int decision = (int)MathRound(decision_value);

   if(decision != 1 && decision != -1)
      return false;

   signal_bar_time = iTime(_Symbol, _Period, 1);

   if(signal_bar_time <= 0)
      return false;

   // Persistent de-dup across EA restarts.
   datetime last_processed = 0;

   if(GlobalVariableCheck(g_last_processed_gv))
      last_processed = (datetime)GlobalVariableGet(g_last_processed_gv);

   if(signal_bar_time <= last_processed)
      return false;

   direction = decision;

   GlobalVariableSet(g_last_processed_gv, (double)signal_bar_time);

   return true;
}

bool CreateVirtualSignal(const int direction,
                         const datetime signal_bar_time)
{
   if(!HasEnoughRoomForSignal())
   {
      Print("OutcomeTracker: MaxTrackedSignals reached.");
      return false;
   }

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   VirtualSignal s;
   ZeroMemory(s);

   s.active = true;
   s.id = g_next_id++;
   s.signal_bar_time = signal_bar_time;
   s.entry_time = TimeCurrent();
   s.direction = direction;

   FillSessionDiagnostics(s);

   s.signal_close = iClose(_Symbol, _Period, 1);

   // Realistic next-bar market entry:
   // BUY enters at ask, SELL enters at bid.
   s.entry_price = direction > 0 ? tick.ask : tick.bid;
   s.spread_pips = CurrentSpreadPips();

   s.buy_score =
      SafeBuffer(BuyScoreBufferIndex, 1, 0.0);

   s.sell_score =
      SafeBuffer(SellScoreBufferIndex, 1, 0.0);

   s.signal_score =
      direction > 0 ? s.buy_score : s.sell_score;

   s.support_low =
      SafeBuffer(SupportLowBufferIndex, 1, 0.0);

   s.support_high =
      SafeBuffer(SupportHighBufferIndex, 1, 0.0);

   s.resistance_low =
      SafeBuffer(ResistanceLowBufferIndex, 1, 0.0);

   s.resistance_high =
      SafeBuffer(ResistanceHighBufferIndex, 1, 0.0);

   s.support_strength =
      SafeBuffer(SupportStrengthBufferIndex, 1, 0.0);

   s.resistance_strength =
      SafeBuffer(ResistanceStrengthBufferIndex, 1, 0.0);

   s.range_position =
      SafeBuffer(RangePositionBufferIndex, 1, -1.0);

   s.trend_score =
      SafeBuffer(TrendScoreBufferIndex, 1, 0.0);

   const double pip = PipSize();

   // Distances are measured to the nearest edge of each zone.
   s.support_distance_pips = 9999.0;
   if(s.support_high > 0.0)
      s.support_distance_pips = MathAbs(s.entry_price - s.support_high) / pip;

   s.resistance_distance_pips = 9999.0;
   if(s.resistance_low > 0.0)
      s.resistance_distance_pips = MathAbs(s.resistance_low - s.entry_price) / pip;

   s.spread_pct_of_5p = (s.spread_pips / 5.0) * 100.0;

   s.trend_aligned =
      ((direction > 0 && s.trend_score > 0.0) ||
       (direction < 0 && s.trend_score < 0.0)) ? 1 : 0;

   s.range_extreme_fit =
      ((direction > 0 && s.range_position >= 0.0 && s.range_position <= 30.0) ||
       (direction < 0 && s.range_position >= 70.0)) ? 1 : 0;

   // Fix: read the indicator's own ATR-scaled near-zone threshold (buffer
   // 14, SignalNearZoneDistance() in price units) instead of a hardcoded
   // 5-pip constant, so this stays in sync with the ATR-adaptive threshold
   // the indicator actually used to decide near_support/near_resistance
   // for THIS bar -- rather than a fixed number that only coincidentally
   // matched at whatever volatility it was tuned against. Falls back to
   // 5p if the buffer is unavailable (e.g. an older indicator build).
   s.near_zone_threshold_pips =
      SafeBuffer(SignalNearZoneBufferIndex, 1, 5.0 * pip) / pip;

   // BUY should be close to support; SELL should be close to resistance.
   s.near_entry_zone =
      ((direction > 0 && s.support_distance_pips <= s.near_zone_threshold_pips) ||
       (direction < 0 && s.resistance_distance_pips <= s.near_zone_threshold_pips)) ? 1 : 0;

   if(direction > 0)
   {
      if(s.support_low > 0.0 &&
         s.support_low < s.entry_price)
      {
         s.stop_price =
            s.support_low - StopBufferPips * pip;
      }
      else
      {
         s.stop_price =
            s.entry_price - FallbackStopPips * pip;
      }

      s.risk_pips =
         (s.entry_price - s.stop_price) / pip;

      s.tp1_price =
         s.entry_price + s.risk_pips * pip;

      s.tp15_price =
         s.entry_price + 1.5 * s.risk_pips * pip;

      s.tp2_price =
         s.entry_price + 2.0 * s.risk_pips * pip;

      s.tp5_price  = s.entry_price + 5.0 * pip;
      s.tp6_price  = s.entry_price + 6.0 * pip;
      s.tp8_price  = s.entry_price + 8.0 * pip;
      s.tp10_price = s.entry_price + 10.0 * pip;
   }
   else
   {
      if(s.resistance_high > 0.0 &&
         s.resistance_high > s.entry_price)
      {
         s.stop_price =
            s.resistance_high + StopBufferPips * pip;
      }
      else
      {
         s.stop_price =
            s.entry_price + FallbackStopPips * pip;
      }

      s.risk_pips =
         (s.stop_price - s.entry_price) / pip;

      s.tp1_price =
         s.entry_price - s.risk_pips * pip;

      s.tp15_price =
         s.entry_price - 1.5 * s.risk_pips * pip;

      s.tp2_price =
         s.entry_price - 2.0 * s.risk_pips * pip;

      s.tp5_price  = s.entry_price - 5.0 * pip;
      s.tp6_price  = s.entry_price - 6.0 * pip;
      s.tp8_price  = s.entry_price - 8.0 * pip;
      s.tp10_price = s.entry_price - 10.0 * pip;
   }

   // Guard against invalid/zero stop.
   if(s.risk_pips <= 0.0)
   {
      Print("OutcomeTracker: invalid virtual risk; signal ignored.");
      return false;
   }

   s.filter_fail_mask = EvaluateFilter(s);
   s.filter_pass = (s.filter_fail_mask == 0) ? 1 : 0;

   EvaluateModels(s);

   s.exit_price = s.entry_price;
   s.exit_pl_pips = 0.0;
   s.timeout_pl_pips = 0.0;

   s.early_progress_checked = 0;
   s.early_progress_pass = 0;
   s.early_progress_check_pl_pips = 0.0;
   s.early_exit_pl_pips = 0.0;

   if(s.filter_pass != 0)
      g_filter_pass_signals++;
   else
      g_filter_reject_signals++;

   s.outcome_1r = 0;
   s.outcome_15r = 0;
   s.outcome_2r = 0;
   s.outcome_5p = 0;
   s.outcome_6p = 0;
   s.outcome_8p = 0;
   s.outcome_10p = 0;

   s.mfe_pips = 0.0;
   s.mae_pips = 0.0;

   s.bars_held = 0;
   s.last_counted_bar = iTime(_Symbol, _Period, 0);

   const int n = ArraySize(g_signals);
   ArrayResize(g_signals, n + 1);
   g_signals[n] = s;

   // Raw v2.52 quality tracking only; no P5G/DG child models.
   LogSignalEvent(s);

   Print(
      "OutcomeTracker NEW ",
      DirectionName(direction),
      " #", s.id,
      " entry=", DoubleToString(s.entry_price, _Digits),
      " risk=", DoubleToString(s.risk_pips, 1), "p",
      " 5p=", DoubleToString(s.tp5_price, _Digits),
      " 6p=", DoubleToString(s.tp6_price, _Digits),
      " 8p=", DoubleToString(s.tp8_price, _Digits),
      " 10p=", DoubleToString(s.tp10_price, _Digits),
      " 1R=", DoubleToString(s.tp1_price, _Digits),
      " 1.5R=", DoubleToString(s.tp15_price, _Digits),
      " 2R=", DoubleToString(s.tp2_price, _Digits),
      " | spr=", DoubleToString(s.spread_pips, 1), "p",
      " | Sdist=", DoubleToString(s.support_distance_pips, 1), "p",
      " Rdist=", DoubleToString(s.resistance_distance_pips, 1), "p",
      " zoneThresh=", DoubleToString(s.near_zone_threshold_pips, 1), "p",
      " | trendAlign=", YesNo(s.trend_aligned),
      " rangeFit=", YesNo(s.range_extreme_fit),
      " zoneNear=", YesNo(s.near_entry_zone),
      " | score=", DoubleToString(s.signal_score, 1),
      " FILTER=", YesNo(s.filter_pass),
      " reason=", FilterReason(s.filter_fail_mask),
      " | session=", s.session_label,
      " UTC=", IntegerToString(s.utc_hour),
      " server=", IntegerToString(s.server_hour),
      " | Q=", IntegerToString(s.quality_points),
      " | ", ModelPassSummary(s)
   );

   return true;
}

//============================ TRACKING ===============================
void UpdateMfeMae(VirtualSignal &s,
                  const double liquidation_price)
{
   const double pip = PipSize();

   double favorable = 0.0;
   double adverse = 0.0;

   if(s.direction > 0)
   {
      favorable =
         (liquidation_price - s.entry_price) / pip;

      adverse =
         (s.entry_price - liquidation_price) / pip;
   }
   else
   {
      favorable =
         (s.entry_price - liquidation_price) / pip;

      adverse =
         (liquidation_price - s.entry_price) / pip;
   }

   if(favorable > s.mfe_pips)
      s.mfe_pips = favorable;

   if(adverse > s.mae_pips)
      s.mae_pips = adverse;
}

void FinalizeSignal(VirtualSignal &s,
                    const string reason,
                    const datetime close_time)
{
   if(!s.active)
      return;

   // Any still-undecided target becomes TIMEOUT if not already won/lost.
   // 0 is intentionally logged as TIMEOUT.
   s.active = false;

   g_completed++;

   g_sum_mfe_pips += s.mfe_pips;
   g_sum_mae_pips += s.mae_pips;
   g_sum_final_pl_pips += s.exit_pl_pips;

   if(reason == "STOP_HIT") g_stop_exits++;
   else if(reason == "TIMEOUT") g_timeout_exits++;
   else if(reason == "2R_HIT") g_2r_exits++;

   if(s.mfe_pips < 0.05)
   {
      g_zero_mfe_completed++;
      if(reason == "STOP_HIT")
         g_zero_mfe_stop_exits++;
   }

   if(s.outcome_1r > 0) g_1r_wins++;
   else if(s.outcome_1r < 0) g_1r_losses++;

   if(s.outcome_15r > 0) g_15r_wins++;
   else if(s.outcome_15r < 0) g_15r_losses++;

   if(s.outcome_2r > 0) g_2r_wins++;
   else if(s.outcome_2r < 0) g_2r_losses++;
   if(s.outcome_5p > 0) g_5p_wins++; else if(s.outcome_5p < 0) g_5p_losses++;
   if(s.outcome_6p > 0) g_6p_wins++; else if(s.outcome_6p < 0) g_6p_losses++;
   if(s.outcome_8p > 0) g_8p_wins++; else if(s.outcome_8p < 0) g_8p_losses++;
   if(s.outcome_10p > 0) g_10p_wins++; else if(s.outcome_10p < 0) g_10p_losses++;

   if(s.filter_pass != 0)
   {
      g_filter_pass_completed++;

      if(s.outcome_5p > 0) g_filter_5p_wins++;
      else if(s.outcome_5p < 0) g_filter_5p_losses++;
      else g_filter_5p_timeouts++;

      if(s.outcome_6p > 0) g_filter_6p_wins++;
      else if(s.outcome_6p < 0) g_filter_6p_losses++;
      else g_filter_6p_timeouts++;

      if(s.outcome_8p > 0) g_filter_8p_wins++;
      else if(s.outcome_8p < 0) g_filter_8p_losses++;
      else g_filter_8p_timeouts++;
   }

   for(int m = 0; m < 11; m++)
   {
      if(ModelFlag(s, m) == 0)
         continue;

      g_model_completed[m]++;

      if(s.outcome_5p > 0)
         g_model_5p_wins[m]++;
      else if(s.outcome_5p < 0)
         g_model_5p_losses[m]++;
      else
         g_model_5p_timeouts[m]++;
   }

   LogCompletedResult(s, reason, close_time);
   LogOptimizationResult(s, reason, close_time);

   Print(
      "OutcomeTracker COMPLETE #", s.id,
      " ", DirectionName(s.direction),
      " | 5p=", OutcomeName(s.outcome_5p),
      " | 6p=", OutcomeName(s.outcome_6p),
      " | 8p=", OutcomeName(s.outcome_8p),
      " | 10p=", OutcomeName(s.outcome_10p),
      " | 1R=", OutcomeName(s.outcome_1r),
      " | 1.5R=", OutcomeName(s.outcome_15r),
      " | 2R=", OutcomeName(s.outcome_2r),
      " | MFE=", DoubleToString(s.mfe_pips, 1), "p",
      " | MAE=", DoubleToString(s.mae_pips, 1), "p",
      " | bars=", s.bars_held,
      " | FILTER=", YesNo(s.filter_pass),
      " reason=", FilterReason(s.filter_fail_mask),
      " | exitPL=", DoubleToString(s.exit_pl_pips, 1), "p",
      " timeoutPL=", DoubleToString(s.timeout_pl_pips, 1), "p",
      " | Q=", IntegerToString(s.quality_points),
      " | ", ModelPassSummary(s)
   );
}

void UpdateVirtualSignals()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   const datetime current_bar =
      iTime(_Symbol, _Period, 0);

   for(int i = 0; i < ArraySize(g_signals); i++)
   {
      if(!g_signals[i].active)
         continue;

      VirtualSignal s = g_signals[i];

      // For a BUY, liquidation/exit happens at bid.
      // For a SELL, liquidation/exit happens at ask.
      const double exit_price =
         s.direction > 0 ? tick.bid : tick.ask;

      s.exit_price = exit_price;
      s.exit_pl_pips =
         s.direction > 0 ?
         (exit_price - s.entry_price) / PipSize() :
         (s.entry_price - exit_price) / PipSize();

      UpdateMfeMae(s, exit_price);

      if(current_bar > 0 &&
         current_bar != s.last_counted_bar)
      {
         s.bars_held++;
         s.last_counted_bar = current_bar;
      }

      // inherited early-progress diagnostic (observational only).
      // It records a hypothetical early exit, but raw tracking continues unchanged.
      if(EarlyProgressBars > 0 &&
         s.early_progress_checked == 0 &&
         s.bars_held >= EarlyProgressBars)
      {
         s.early_progress_checked = 1;
         s.early_progress_check_pl_pips = s.exit_pl_pips;

         if(s.mfe_pips >= EarlyProgressPips)
         {
            s.early_progress_pass = 1;
            g_early_progress_pass++;
         }
         else
         {
            s.early_progress_pass = 0;
            s.early_exit_pl_pips = s.exit_pl_pips;
            g_early_progress_fail++;
            g_early_fail_exit_pl_sum += s.early_exit_pl_pips;
         }

         g_early_progress_checked++;
      }

      // Favorable targets are checked first on tick data.
      if(s.direction > 0)
      {
         if(s.outcome_5p == 0 && exit_price >= s.tp5_price) { s.outcome_5p = 1; s.hit_5p_time = TimeCurrent(); }
         if(s.outcome_6p == 0 && exit_price >= s.tp6_price) { s.outcome_6p = 1; s.hit_6p_time = TimeCurrent(); }
         if(s.outcome_8p == 0 && exit_price >= s.tp8_price) { s.outcome_8p = 1; s.hit_8p_time = TimeCurrent(); }
         if(s.outcome_10p == 0 && exit_price >= s.tp10_price) { s.outcome_10p = 1; s.hit_10p_time = TimeCurrent(); }

         if(s.outcome_1r == 0 &&
            exit_price >= s.tp1_price)
         {
            s.outcome_1r = 1;
            s.hit_1r_time = TimeCurrent();
         }

         if(s.outcome_15r == 0 &&
            exit_price >= s.tp15_price)
         {
            s.outcome_15r = 1;
            s.hit_15r_time = TimeCurrent();
         }

         if(s.outcome_2r == 0 &&
            exit_price >= s.tp2_price)
         {
            s.outcome_2r = 1;
            s.hit_2r_time = TimeCurrent();
         }

         if(exit_price <= s.stop_price)
         {
            s.stop_time = TimeCurrent();

            if(s.outcome_1r == 0)  s.outcome_1r = -1;
            if(s.outcome_15r == 0) s.outcome_15r = -1;
            if(s.outcome_2r == 0)  s.outcome_2r = -1;
            if(s.outcome_5p == 0)  s.outcome_5p = -1;
            if(s.outcome_6p == 0)  s.outcome_6p = -1;
            if(s.outcome_8p == 0)  s.outcome_8p = -1;
            if(s.outcome_10p == 0) s.outcome_10p = -1;

            FinalizeSignal(s, "STOP_HIT", TimeCurrent());
            g_signals[i] = s;
            continue;
         }
      }
      else
      {
         if(s.outcome_5p == 0 && exit_price <= s.tp5_price) { s.outcome_5p = 1; s.hit_5p_time = TimeCurrent(); }
         if(s.outcome_6p == 0 && exit_price <= s.tp6_price) { s.outcome_6p = 1; s.hit_6p_time = TimeCurrent(); }
         if(s.outcome_8p == 0 && exit_price <= s.tp8_price) { s.outcome_8p = 1; s.hit_8p_time = TimeCurrent(); }
         if(s.outcome_10p == 0 && exit_price <= s.tp10_price) { s.outcome_10p = 1; s.hit_10p_time = TimeCurrent(); }

         if(s.outcome_1r == 0 &&
            exit_price <= s.tp1_price)
         {
            s.outcome_1r = 1;
            s.hit_1r_time = TimeCurrent();
         }

         if(s.outcome_15r == 0 &&
            exit_price <= s.tp15_price)
         {
            s.outcome_15r = 1;
            s.hit_15r_time = TimeCurrent();
         }

         if(s.outcome_2r == 0 &&
            exit_price <= s.tp2_price)
         {
            s.outcome_2r = 1;
            s.hit_2r_time = TimeCurrent();
         }

         if(exit_price >= s.stop_price)
         {
            s.stop_time = TimeCurrent();

            if(s.outcome_1r == 0)  s.outcome_1r = -1;
            if(s.outcome_15r == 0) s.outcome_15r = -1;
            if(s.outcome_2r == 0)  s.outcome_2r = -1;
            if(s.outcome_5p == 0)  s.outcome_5p = -1;
            if(s.outcome_6p == 0)  s.outcome_6p = -1;
            if(s.outcome_8p == 0)  s.outcome_8p = -1;
            if(s.outcome_10p == 0) s.outcome_10p = -1;

            FinalizeSignal(s, "STOP_HIT", TimeCurrent());
            g_signals[i] = s;
            continue;
         }
      }

      // Once 2R is reached, every smaller target has necessarily won.
      if(s.outcome_2r > 0)
      {
         if(s.outcome_1r == 0)  s.outcome_1r = 1;
         if(s.outcome_15r == 0) s.outcome_15r = 1;
         if(s.outcome_5p == 0)  s.outcome_5p = 1;
         if(s.outcome_6p == 0)  s.outcome_6p = 1;
         if(s.outcome_8p == 0)  s.outcome_8p = 1;
         if(s.outcome_10p == 0) s.outcome_10p = 1;

         FinalizeSignal(s, "2R_HIT", TimeCurrent());
         g_signals[i] = s;
         continue;
      }

      if(TimeoutBars > 0 &&
         s.bars_held >= TimeoutBars)
      {
         s.timeout_pl_pips = s.exit_pl_pips;
         FinalizeSignal(s, "TIMEOUT", TimeCurrent());
         g_signals[i] = s;
         continue;
      }

      g_signals[i] = s;
   }
}

//============================ DASHBOARD ==============================
void DeleteDashboard()
{
   const string name = g_prefix + "PANEL";

   if(ObjectFind(ChartID(), name) >= 0)
      ObjectDelete(ChartID(), name);
}

void DrawDashboard()
{
   if(!ShowDashboard)
   {
      DeleteDashboard();
      return;
   }

   const string name = g_prefix + "PANEL";

   if(ObjectFind(ChartID(), name) < 0)
   {
      if(!ObjectCreate(ChartID(), name, OBJ_LABEL, 0, 0, 0))
         return;

      ObjectSetInteger(ChartID(), name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(ChartID(), name, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(ChartID(), name, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(ChartID(), name, OBJPROP_YDISTANCE, 55);
      ObjectSetInteger(ChartID(), name, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(ChartID(), name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(ChartID(), name, OBJPROP_HIDDEN, true);
      ObjectSetString(ChartID(), name, OBJPROP_FONT, "Arial");
   }

   const int t5  = MathMax(0, g_completed - g_5p_wins  - g_5p_losses);
   const int t6  = MathMax(0, g_completed - g_6p_wins  - g_6p_losses);
   const int t8  = MathMax(0, g_completed - g_8p_wins  - g_8p_losses);
   const int t10 = MathMax(0, g_completed - g_10p_wins - g_10p_losses);

   const double avg_mfe =
      g_completed > 0 ? g_sum_mfe_pips / g_completed : 0.0;

   const double avg_mae =
      g_completed > 0 ? g_sum_mae_pips / g_completed : 0.0;

   const double avg_final_pl =
      g_completed > 0 ? g_sum_final_pl_pips / g_completed : 0.0;

   const double hit5 =
      g_completed > 0 ? 100.0 * g_5p_wins / g_completed : 0.0;

   string text = "MASTER S/R v2.52 TRADE QUALITY\n";
   text += "NON-TRADING / RAW SIGNALS ONLY\n";
   text += "Active: " + IntegerToString(ActiveCount()) +
           " | Completed: " + IntegerToString(g_completed) + "\n";

   text += "5p  W:" + IntegerToString(g_5p_wins) +
           " L:" + IntegerToString(g_5p_losses) +
           " T:" + IntegerToString(t5) +
           " | hit " + DoubleToString(hit5,1) + "%\n";

   text += "6p  W:" + IntegerToString(g_6p_wins) +
           " L:" + IntegerToString(g_6p_losses) +
           " T:" + IntegerToString(t6) + "\n";

   text += "8p  W:" + IntegerToString(g_8p_wins) +
           " L:" + IntegerToString(g_8p_losses) +
           " T:" + IntegerToString(t8) + "\n";

   text += "10p W:" + IntegerToString(g_10p_wins) +
           " L:" + IntegerToString(g_10p_losses) +
           " T:" + IntegerToString(t10) + "\n";

   text += "1R W:" + IntegerToString(g_1r_wins) +
           " L:" + IntegerToString(g_1r_losses) +
           " | 1.5R W:" + IntegerToString(g_15r_wins) +
           " L:" + IntegerToString(g_15r_losses) + "\n";

   text += "2R W:" + IntegerToString(g_2r_wins) +
           " L:" + IntegerToString(g_2r_losses) + "\n";

   text += "Avg MFE:" + DoubleToString(avg_mfe,1) +
           "p | Avg MAE:" + DoubleToString(avg_mae,1) + "p\n";

   text += "Avg final P/L:" + DoubleToString(avg_final_pl,1) + "p\n";

   text += "Stops:" + IntegerToString(g_stop_exits) +
           " | Timeouts:" + IntegerToString(g_timeout_exits) +
           " | 2R closes:" + IntegerToString(g_2r_exits) + "\n";

   text += "0-MFE trades:" + IntegerToString(g_zero_mfe_completed) +
           " | 0-MFE stops:" + IntegerToString(g_zero_mfe_stop_exits) + "\n";

   text += "Diag filter P:" + IntegerToString(g_filter_pass_signals) +
           " R:" + IntegerToString(g_filter_reject_signals) + "\n";

   text += "RESEARCH ONLY / NO REAL ORDERS";

   ObjectSetString(ChartID(), name, OBJPROP_TEXT, text);
   ObjectSetInteger(ChartID(), name, OBJPROP_COLOR, clrWhite);
}

//============================= HANDLE ================================
bool TryAttachedIndicator(const string short_name)
{
   if(short_name == "")
      return false;

   ResetLastError();

   const int handle =
      ChartIndicatorGet(
         ChartID(),
         0,
         short_name
      );

   if(handle == INVALID_HANDLE)
      return false;

   g_indicator_handle = handle;

   Print(
      "OutcomeTracker v2.52: connected to ATTACHED indicator: ",
      short_name
   );

   return true;
}

// Fix: loads the indicator programmatically via iCustom() instead of
// requiring it to already be manually attached to a chart. Attempts 1-3
// above (TryAttachedIndicator) all need a chart with the indicator dropped
// on it, which is fine for a live/demo chart but means the tracker cannot
// run in fast/non-visual backtest mode, and CANNOT run under Strategy
// Tester optimization at all (optimization agents have no chart). This
// fallback unlocks both. It uses the indicator's own compiled default
// inputs (iCustom with no extra parameters after the path) -- if you need
// non-default indicator settings for a backtest, either attach it manually
// with those settings in Visual Mode (path 1-3), or change the defaults
// in the indicator's own source and recompile.
bool TryICustomIndicator(const string relative_path)
{
   if(relative_path == "")
      return false;

   ResetLastError();

   const int handle = iCustom(_Symbol, _Period, relative_path);

   if(handle == INVALID_HANDLE)
      return false;

   // The indicator may not have finished its initial history calculation
   // yet (most likely right after OnInit, especially in the tester). Don't
   // adopt the handle until it has actually produced values. iCustom reuses
   // the same underlying instance on repeat calls with identical
   // parameters, so retrying this every OnTick (via the caller) doesn't
   // create duplicate copies while it warms up.
   if(BarsCalculated(handle) <= 0)
   {
      IndicatorRelease(handle);
      return false;
   }

   g_indicator_handle = handle;

   Print(
      "OutcomeTracker v2.52: connected via iCustom fallback: ",
      relative_path
   );

   return true;
}

bool CreateIndicatorHandle()
{
   // 1) User-configurable exact short name.
   if(TryAttachedIndicator(AttachedIndicatorShortName))
      return true;

   // 2) Preferred v2.52 display name if the indicator was cosmetically renamed.
   if(AttachedIndicatorShortName != "Master S/R Confluence v2.52 VolAdaptive" &&
      TryAttachedIndicator("Master S/R Confluence v2.52 VolAdaptive"))
      return true;

   // 3) Current uploaded v2.52 source still uses this legacy short name.
   //    Keeping this fallback means the tracker works before or after the
   //    cosmetic indicator-short-name cleanup.
   if(AttachedIndicatorShortName != "Master S/R Confluence v2.5 VolAdaptive" &&
      TryAttachedIndicator("Master S/R Confluence v2.5 VolAdaptive"))
      return true;

   // 4) iCustom fallback -- works with no chart at all, so this is what
   //    makes fast-mode backtesting and Strategy Tester optimization work.
   if(UseICustomFallback &&
      TryICustomIndicator(IndicatorFileName))
      return true;

   Print(
      "OutcomeTracker v2.52: no VolAdaptive indicator found -- neither ",
      "attached to this chart nor loadable via iCustom('", IndicatorFileName, "'). ",
      "Either attach it manually, or set IndicatorFileName to its compiled ",
      ".ex5 name (include a subfolder path if it's not directly in MQL5\\Indicators\\)."
   );

   return false;
}

//============================== MT5 ==================================
int OnInit()
{
   ArrayResize(g_signals, 0);
   ArrayResize(g_mgmt_p5g, 0);
   ArrayResize(g_mgmt_dg2, 0);
   ArrayResize(g_mgmt_dg4, 0);
   ArrayResize(g_mgmt_dg6, 0);

   g_last_processed_gv =
      "MSRTQ252_LAST_" +
      _Symbol + "_" +
      IntegerToString((int)_Period);

   // Fix: do NOT create the indicator handle here. Creating an indicator
   // (especially via iCustom(), which recursively runs the target
   // indicator's own OnInit()) from inside an EA's OnInit() is a known
   // Strategy Tester problem area -- history for the symbol/indicator can
   // still be mid-sync at this exact point, and a nested OnInit failure
   // there can surface as "tester stopped because OnInit failed" for this
   // EA even though this function always returns INIT_SUCCEEDED. OnTick()
   // below already retries CreateIndicatorHandle() every tick until it
   // succeeds, so deferring to the first tick (well after history is
   // ready) is both safe and sufficient -- this call was redundant here
   // even before the iCustom fallback existed.

   Print(
      "MasterSRSignalOutcomeTracker initialized on ",
      _Symbol,
      " ",
      EnumToString((ENUM_TIMEFRAMES)_Period),
      ". TRADE QUALITY TRACKER v2.52 / NON-TRADING."
   );

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteDashboard();

   if(g_indicator_handle != INVALID_HANDLE)
      IndicatorRelease(g_indicator_handle);
}

void OnTick()
{

if(g_indicator_handle == INVALID_HANDLE)
{
   CreateIndicatorHandle();
   DrawDashboard();
   return;
}
   // Keep tracking existing raw virtual signals every tick.
   UpdateVirtualSignals();

   // Raw v2.52 trade-quality tracking only; management lab disabled.

   const datetime current_bar =
      iTime(_Symbol, _Period, 0);

   // Detect new closed-candle signal only once per new bar.
   if(current_bar > 0 &&
      current_bar != g_last_chart_bar_time)
   {
      g_last_chart_bar_time = current_bar;

      int direction = 0;
      datetime signal_bar_time = 0;

      if(GetNewConfirmedDecision(direction, signal_bar_time))
         CreateVirtualSignal(direction, signal_bar_time);
   }

   DrawDashboard();
}
//+------------------------------------------------------------------+
