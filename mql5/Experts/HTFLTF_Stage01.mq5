//+------------------------------------------------------------------+
//| HTFLTF_Stage01.mq5                                                |
//| HTF/LTF Trend-Continuation EA — Stages 0 and 1 only               |
//|                                                                   |
//| This is NOT a trading EA. It places no orders and holds no        |
//| positions. It exists to satisfy the Definitions of Done for        |
//| roadmap Stage 0 (math primitives, parameter validation, bar guard) |
//| and Stage 1 (swing detection), which is what "no stage begins      |
//| until the previous stage has passed its DoD" requires.             |
//|                                                                   |
//| What it produces:                                                  |
//|   * §38 fail-fast validation at OnInit, one line per failure       |
//|   * ATR / ROC / ER printed every DiagnosticEveryNBars, for         |
//|     eyeball comparison against the chart and spot-checking against |
//|     reference/htfltf/indicators.py                                 |
//|   * swing pivots drawn as chart objects, plus a pivot count, for   |
//|     the Stage 1 visual check                                       |
//|   * §36.1 tick/bar ratio at shutdown                               |
//|                                                                   |
//| PRD v0.7. See docs/roadmap.md for what Stage 2 adds next.          |
//+------------------------------------------------------------------+
#property copyright "HTF/LTF Trend-Continuation EA"
#property version   "0.1"
#property strict

#include <HTFLTF/Params.mqh>
#include <HTFLTF/Indicators.mqh>
#include <HTFLTF/Swings.mqh>
#include <HTFLTF/BarGuard.mqh>
#include <HTFLTF/Funnel.mqh>

//--- §3 timeframes
input ENUM_TIMEFRAMES InpHTF                        = PERIOD_H1;
input ENUM_TIMEFRAMES InpLTF                        = PERIOD_M5;
//--- §4.1
input int    InpSwingConfirmationBars               = 3;
//--- §5.4
input double InpStructuralBreakATRMultiplier        = 0.1;
input double InpStructuralMinimumPoints             = 0.0;
//--- §37
input int    InpHTFATRPeriod                        = 14;
input int    InpLTFATRPeriod                        = 14;
//--- §7
input int    InpERLookback                          = 10;
input double InpERLow                               = 0.25;
input double InpERHigh                              = 0.55;
input int    InpADXPeriod                           = 14;
input double InpADXThreshold                        = 20.0;
//--- §9.3
input double InpLocationThreshold                   = 1.5;
//--- §10.5.C
input int    InpMaxRetracementBars                  = 30;
//--- §11.3
input double InpBOSATRMultiplier                    = 0.25;
input double InpBOSMinimumPoints                    = 0.0;
//--- §12
input int    InpROCPeriod                           = 5;
input double InpROCStrongThreshold                  = 0.05;
input double InpROCNegativeThreshold                = -0.05;
//--- §13
input double InpSLATRMultiplier                     = 0.5;
input double InpSLMinimumPoints                     = 0.0;
//--- §14
input double InpMaximumSlippage                     = 10.0;
//--- §12.2
input double InpHighConfidenceRiskPercent           = 1.0;
input double InpLowConfidenceRiskPercent            = 0.5;
//--- §16
input double InpTrailingActivationR                 = 1.0;
input bool   InpBreakevenEnabled                    = true;
input double InpBreakevenActivationR                = 0.5;
input double InpBreakevenBuffer                     = 0.0;
input double InpTrailShadowMultiplier               = 1.5;
input double InpTrailATRMultiplier                  = 1.0;
input int    InpShadowLookbackBars                  = 10;
//--- §17
input double InpMaxDailyLoss                        = 3.0;
input int    InpMaxConsecutiveLosses                = 3;
//--- §19
input double InpMaximumAllowedSpread                = 20.0;
input double InpMaximumNormalizedSpread             = 0.2;
//--- §36.2
input ENUM_HTFLTF_STOP_MODE InpBrokerStopDistanceMode = HTFLTF_STOP_REJECT;
//--- diagnostics
input int    InpDiagnosticEveryNBars                = 20;
input bool   InpDrawPivots                          = true;

HTFLTFParams      g_params;
CHTFLTFBarGuard   g_guard;
CHTFLTFStructure  g_structure;
CHTFLTFFunnel     g_funnel;

long   g_pivot_highs = 0;
long   g_pivot_lows  = 0;
long   g_diag_counter = 0;

const string PIVOT_PREFIX = "HTFLTF_PIVOT_";

//+------------------------------------------------------------------+
int PeriodMinutes(const ENUM_TIMEFRAMES tf) { return (int)PeriodSeconds(tf) / 60; }

//+------------------------------------------------------------------+
void FillParams()
{
   g_params.htf_minutes                     = PeriodMinutes(InpHTF);
   g_params.ltf_minutes                     = PeriodMinutes(InpLTF);
   g_params.swing_confirmation_bars         = InpSwingConfirmationBars;
   g_params.structural_break_atr_multiplier = InpStructuralBreakATRMultiplier;
   g_params.structural_minimum_points       = InpStructuralMinimumPoints;
   g_params.htf_atr_period                  = InpHTFATRPeriod;
   g_params.ltf_atr_period                  = InpLTFATRPeriod;
   g_params.er_lookback                     = InpERLookback;
   g_params.er_low                          = InpERLow;
   g_params.er_high                         = InpERHigh;
   g_params.adx_period                      = InpADXPeriod;
   g_params.adx_threshold                   = InpADXThreshold;
   g_params.location_threshold              = InpLocationThreshold;
   g_params.max_retracement_bars            = InpMaxRetracementBars;
   g_params.bos_atr_multiplier              = InpBOSATRMultiplier;
   g_params.bos_minimum_points              = InpBOSMinimumPoints;
   g_params.roc_period                      = InpROCPeriod;
   g_params.roc_strong_threshold            = InpROCStrongThreshold;
   g_params.roc_negative_threshold          = InpROCNegativeThreshold;
   g_params.sl_atr_multiplier               = InpSLATRMultiplier;
   g_params.sl_minimum_points               = InpSLMinimumPoints;
   g_params.maximum_slippage                = InpMaximumSlippage;
   g_params.high_confidence_risk_percent    = InpHighConfidenceRiskPercent;
   g_params.low_confidence_risk_percent     = InpLowConfidenceRiskPercent;
   g_params.trailing_activation_r           = InpTrailingActivationR;
   g_params.breakeven_enabled               = InpBreakevenEnabled;
   g_params.breakeven_activation_r          = InpBreakevenActivationR;
   g_params.breakeven_buffer                = InpBreakevenBuffer;
   g_params.trail_shadow_multiplier         = InpTrailShadowMultiplier;
   g_params.trail_atr_multiplier            = InpTrailATRMultiplier;
   g_params.shadow_lookback_bars            = InpShadowLookbackBars;
   g_params.max_daily_loss                  = InpMaxDailyLoss;
   g_params.max_consecutive_losses          = InpMaxConsecutiveLosses;
   g_params.maximum_allowed_spread          = InpMaximumAllowedSpread;
   g_params.maximum_normalized_spread       = InpMaximumNormalizedSpread;
   g_params.broker_stop_distance_mode       = InpBrokerStopDistanceMode;
}

//+------------------------------------------------------------------+
//| §38: refuse to run on any invalid parameter, having logged each   |
//| failure with its own name and value.                              |
//+------------------------------------------------------------------+
int OnInit()
{
   FillParams();
   if(HTFLTF_ValidateParams(g_params) > 0)
      return INIT_PARAMETERS_INCORRECT;

   PrintFormat("HTFLTF Stage 0/1 harness started — %s HTF=%s LTF=%s K=%d",
               _Symbol, EnumToString(InpHTF), EnumToString(InpLTF),
               g_params.swing_confirmation_bars);
   Print("This build places no orders. See docs/roadmap.md — trades appear at Stage 8.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PrintFormat("HTFLTF §36.1 bar guard: %d ticks over %d bars (%.1f ticks/bar) — "
               "the ratio should be large and the bar logic must fire exactly once per bar",
               g_guard.TicksSeen(), g_guard.BarsProcessed(), g_guard.TicksPerBar());
   PrintFormat("HTFLTF Stage 1: %d swing highs, %d swing lows confirmed (%d stored)",
               g_pivot_highs, g_pivot_lows, g_structure.Count());
   g_funnel.PrintReport();

   if(InpDrawPivots)
      ObjectsDeleteAll(0, PIVOT_PREFIX);
}

//+------------------------------------------------------------------+
//| §36.1: everything below runs exactly once per completed LTF bar.   |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime bar_time = iTime(_Symbol, InpLTF, 0);
   if(bar_time == 0)
      return;
   if(!g_guard.ShouldProcess(bar_time))
      return;

   g_funnel.Bar();
   ProcessCompletedBar();
}

//+------------------------------------------------------------------+
void ProcessCompletedBar()
{
   int k = g_params.swing_confirmation_bars;

   // Bar 0 is still forming, so every window starts at shift 1. §37 and §10.4 both
   // exclude the forming bar from all structural and indicator computation.
   int needed = MathMax(2 * k + 1,
                MathMax(g_params.ltf_atr_period + 1,
                MathMax(g_params.roc_period + 1, g_params.shadow_lookback_bars)));

   double o[], h[], l[], c[];
   datetime t[];
   ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);
   ArraySetAsSeries(t, true);

   if(CopyOpen(_Symbol, InpLTF, 1, needed, o) < needed) return;
   if(CopyHigh(_Symbol, InpLTF, 1, needed, h) < needed) return;
   if(CopyLow(_Symbol, InpLTF, 1, needed, l) < needed) return;
   if(CopyClose(_Symbol, InpLTF, 1, needed, c) < needed) return;
   if(CopyTime(_Symbol, InpLTF, 1, needed, t) < needed) return;

   //--- Stage 1: detect the pivot that has just become confirmed, if any.
   HTFLTFPivot pivot;
   if(HTFLTF_DetectNewPivot(h, l, t, k, pivot))
   {
      if(g_structure.Append(pivot))
      {
         if(pivot.kind == HTFLTF_PIVOT_HIGH) g_pivot_highs++;
         else                                g_pivot_lows++;
         if(InpDrawPivots)
            DrawPivot(pivot);
      }
   }

   //--- Stage 0 diagnostics: ATR / ROC / ER every N bars, for eyeball comparison
   //--- against the chart and spot-checking against the Python reference.
   g_diag_counter++;
   if(InpDiagnosticEveryNBars > 0 && (g_diag_counter % InpDiagnosticEveryNBars) == 0)
      PrintDiagnostics(o, h, l, c);
}

//+------------------------------------------------------------------+
void PrintDiagnostics(const double &o[], const double &h[], const double &l[], const double &c[])
{
   string line = StringFormat("HTFLTF diag %s", TimeToString(iTime(_Symbol, InpLTF, 1)));

   double ltf_atr;
   if(HTFLTF_WilderATR(h, l, c, g_params.ltf_atr_period, ltf_atr))
      line += StringFormat(" | LTF_ATR(%d)=%.*f", g_params.ltf_atr_period, _Digits, ltf_atr);
   else
      line += " | LTF_ATR=insufficient data";

   double roc;
   if(HTFLTF_ROC(c, g_params.roc_period, roc))
      line += StringFormat(" | ROC(%d)=%.4f%% (long-signed %.4f, short-signed %.4f)",
                           g_params.roc_period, roc,
                           HTFLTF_DirectionalROC(roc, true),
                           HTFLTF_DirectionalROC(roc, false));
   else
      line += " | ROC=insufficient data";

   double shadow;
   if(HTFLTF_AverageShadow(o, h, l, c, g_params.shadow_lookback_bars, true, shadow))
      line += StringFormat(" | AvgUpperShadow(%d)=%.*f", g_params.shadow_lookback_bars, _Digits, shadow);

   Print(line);

   //--- ER and ATR on the HTF (§7.1, §37) — completed HTF candles only.
   int htf_needed = MathMax(g_params.er_lookback + 1, g_params.htf_atr_period + 1);
   double hh[], hl[], hc[];
   ArraySetAsSeries(hh, true); ArraySetAsSeries(hl, true); ArraySetAsSeries(hc, true);
   if(CopyHigh(_Symbol, InpHTF, 1, htf_needed, hh) < htf_needed) return;
   if(CopyLow(_Symbol, InpHTF, 1, htf_needed, hl) < htf_needed) return;
   if(CopyClose(_Symbol, InpHTF, 1, htf_needed, hc) < htf_needed) return;

   string htf_line = "HTFLTF diag HTF";
   double er;
   if(HTFLTF_EfficiencyRatio(hc, g_params.er_lookback, er))
   {
      // §7.2 bands. A flat window gives ER=0 -> CHOPPY rather than nan (§7.1, B-3).
      string regime = (er >= g_params.er_high) ? "STRONG"
                    : (er <  g_params.er_low)  ? "CHOPPY"
                                               : "AMBIGUOUS(band; ADX decides)";
      htf_line += StringFormat(" | ER(%d)=%.4f -> %s", g_params.er_lookback, er, regime);
   }
   else
      htf_line += " | ER=insufficient data";

   double htf_atr;
   if(HTFLTF_WilderATR(hh, hl, hc, g_params.htf_atr_period, htf_atr))
   {
      htf_line += StringFormat(" | HTF_ATR(%d)=%.*f", g_params.htf_atr_period, _Digits, htf_atr);
      // §5.4 — the buffer v0.6 used but never defined (review finding B-5).
      double buf = MathMax(g_params.structural_minimum_points * _Point,
                           htf_atr * g_params.structural_break_atr_multiplier);
      htf_line += StringFormat(" | StructuralBreakBuffer=%.*f", _Digits, buf);
   }

   Print(htf_line);
}

//+------------------------------------------------------------------+
//| Stage 1 visual check: mark pivots so they can be compared against  |
//| what a human would circle as swing points.                         |
//+------------------------------------------------------------------+
void DrawPivot(const HTFLTFPivot &pivot)
{
   bool is_high = (pivot.kind == HTFLTF_PIVOT_HIGH);
   string name = PIVOT_PREFIX + (is_high ? "H_" : "L_") + IntegerToString((long)pivot.bar_time);

   if(!ObjectCreate(0, name, OBJ_ARROW, 0, pivot.bar_time, pivot.price))
      return;
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, is_high ? 218 : 217);
   ObjectSetInteger(0, name, OBJPROP_COLOR, is_high ? clrTomato : clrDodgerBlue);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}
