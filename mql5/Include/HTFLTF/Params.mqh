//+------------------------------------------------------------------+
//| Params.mqh — §32 parameter set and §38 fail-fast startup checks    |
//|                                                                   |
//| Two rules from §38 shape this file:                               |
//|   * every failure names the specific parameter AND the value that  |
//|     failed, never a generic "bad configuration" — that is what     |
//|     makes fail-fast diagnosable rather than merely safe; and       |
//|   * validation reports EVERY failing parameter, not just the       |
//|     first, so a misconfigured setup is fixed in one pass instead   |
//|     of one restart per typo.                                       |
//|                                                                   |
//| Mirrors reference/htfltf/params.py. The two check lists must stay  |
//| in step — reference/tests/test_params.py is the executable form of |
//| §39 test #12.                                                      |
//+------------------------------------------------------------------+
#property strict

//--- §38: risk percents above this are treated as a likely input error,
//--- not a valid aggressive setting.
#define HTFLTF_RISK_CEILING_PERCENT 5.0

enum ENUM_HTFLTF_STOP_MODE
{
   HTFLTF_STOP_WIDEN,   // §36.2: widen to the broker minimum, log it, resize
   HTFLTF_STOP_REJECT   // §36.2: reject the trade
};

//+------------------------------------------------------------------+
//| §32 parameter set. Defaults are sanity-test starting points per    |
//| the roadmap's "loose first" guidance, NOT calibrated values —      |
//| §28.2 lists the seven parameters that get swept, and none of these |
//| defaults is a result.                                             |
//+------------------------------------------------------------------+
struct HTFLTFParams
{
   //--- §3 timeframes
   int    htf_minutes;
   int    ltf_minutes;
   //--- §4.1
   int    swing_confirmation_bars;
   //--- §5.4 structural break buffer
   double structural_break_atr_multiplier;
   double structural_minimum_points;
   //--- §37 ATR
   int    htf_atr_period;
   int    ltf_atr_period;
   //--- §7 regime
   int    er_lookback;
   double er_low;
   double er_high;
   int    adx_period;
   double adx_threshold;
   //--- §9.3
   double location_threshold;
   //--- §10.5.C
   int    max_retracement_bars;
   //--- §11.3
   double bos_atr_multiplier;
   double bos_minimum_points;
   //--- §12 (thresholds compare against Directional_ROC, §12.1)
   int    roc_period;
   double roc_strong_threshold;
   double roc_negative_threshold;
   //--- §13
   double sl_atr_multiplier;
   double sl_minimum_points;
   //--- §14
   double maximum_slippage;
   //--- §12.2
   double high_confidence_risk_percent;
   double low_confidence_risk_percent;
   //--- §16
   double trailing_activation_r;
   bool   breakeven_enabled;
   double breakeven_activation_r;
   double breakeven_buffer;
   double trail_shadow_multiplier;
   double trail_atr_multiplier;
   int    shadow_lookback_bars;
   //--- §17
   double max_daily_loss;
   int    max_consecutive_losses;
   //--- §19
   double maximum_allowed_spread;
   double maximum_normalized_spread;
   //--- §36.2
   ENUM_HTFLTF_STOP_MODE broker_stop_distance_mode;
};

//+------------------------------------------------------------------+
//| §38 validation. Returns the number of failures; 0 means the EA may |
//| start. Every failure is printed with its parameter name and value  |
//| before returning, so OnInit can simply return                      |
//| INIT_PARAMETERS_INCORRECT when the count is non-zero.              |
//+------------------------------------------------------------------+
int HTFLTF_ValidateParams(const HTFLTFParams &p)
{
   int failures = 0;

   //--- §3 timeframe model (added v0.7, review finding M-10).
   //--- ltf_minutes is checked first: it is the divisor of the multiple test
   //--- below, so an invalid LTF must short-circuit that test rather than
   //--- reach a division by zero.
   if(p.ltf_minutes < 1)
   {
      PrintFormat("HTFLTF §38: ltf_minutes=%d — must be >= 1", p.ltf_minutes);
      failures++;
   }
   else if(p.htf_minutes <= p.ltf_minutes)
   {
      PrintFormat("HTFLTF §38: htf_minutes=%d — must be strictly higher than "
                  "ltf_minutes=%d; an inverted pair makes the §4.4 freeze meaningless",
                  p.htf_minutes, p.ltf_minutes);
      failures++;
   }
   else if(p.htf_minutes % p.ltf_minutes != 0)
   {
      PrintFormat("HTFLTF §38: htf_minutes=%d — must be an integer multiple of "
                  "ltf_minutes=%d", p.htf_minutes, p.ltf_minutes);
      failures++;
   }

   //--- §4.1
   if(p.swing_confirmation_bars < 1)
   {
      PrintFormat("HTFLTF §38: swing_confirmation_bars=%d — must be >= 1",
                  p.swing_confirmation_bars);
      failures++;
   }

   //--- §35 ATR multipliers: every one must be strictly positive.
   //--- structural_break_atr_multiplier is new in v0.7 (finding B-5): v0.6 used
   //--- Structural_Break_Buffer in §5.2/§5.3 with no multiplier parameter at all,
   //--- so it had no validation either.
   if(p.bos_atr_multiplier <= 0.0)
   { PrintFormat("HTFLTF §38: bos_atr_multiplier=%.6f — must be > 0", p.bos_atr_multiplier); failures++; }
   if(p.sl_atr_multiplier <= 0.0)
   { PrintFormat("HTFLTF §38: sl_atr_multiplier=%.6f — must be > 0", p.sl_atr_multiplier); failures++; }
   if(p.trail_atr_multiplier <= 0.0)
   { PrintFormat("HTFLTF §38: trail_atr_multiplier=%.6f — must be > 0", p.trail_atr_multiplier); failures++; }
   if(p.trail_shadow_multiplier <= 0.0)
   { PrintFormat("HTFLTF §38: trail_shadow_multiplier=%.6f — must be > 0", p.trail_shadow_multiplier); failures++; }
   if(p.structural_break_atr_multiplier <= 0.0)
   { PrintFormat("HTFLTF §38: structural_break_atr_multiplier=%.6f — must be > 0", p.structural_break_atr_multiplier); failures++; }

   //--- §35 buffer floors: three distinct parameters (v0.7, finding B-4).
   //--- v0.6 shared one MinimumPoints across the BOS and SL buffers while §35
   //--- forbade exactly that.
   if(p.bos_minimum_points < 0.0)
   { PrintFormat("HTFLTF §38: bos_minimum_points=%.6f — must be >= 0", p.bos_minimum_points); failures++; }
   if(p.sl_minimum_points < 0.0)
   { PrintFormat("HTFLTF §38: sl_minimum_points=%.6f — must be >= 0", p.sl_minimum_points); failures++; }
   if(p.structural_minimum_points < 0.0)
   { PrintFormat("HTFLTF §38: structural_minimum_points=%.6f — must be >= 0", p.structural_minimum_points); failures++; }

   //--- §37 ATR periods (v0.7, finding M-10)
   if(p.htf_atr_period < 1)
   { PrintFormat("HTFLTF §38: htf_atr_period=%d — must be >= 1", p.htf_atr_period); failures++; }
   if(p.ltf_atr_period < 1)
   { PrintFormat("HTFLTF §38: ltf_atr_period=%d — must be >= 1", p.ltf_atr_period); failures++; }

   //--- §7 regime
   if(p.er_high <= p.er_low)
   {
      PrintFormat("HTFLTF §38: er_high=%.6f — must be > er_low=%.6f; equal or "
                  "inverted thresholds leave the ambiguous band undefined",
                  p.er_high, p.er_low);
      failures++;
   }
   if(p.er_lookback < 2)
   {
      // v0.7, finding M-10: the §7.1 path sum is empty at N<1 and degenerate at N=1
      PrintFormat("HTFLTF §38: er_lookback=%d — must be >= 2; the §7.1 path sum is "
                  "degenerate below 2", p.er_lookback);
      failures++;
   }
   if(p.adx_period < 1)
   { PrintFormat("HTFLTF §38: adx_period=%d — must be >= 1", p.adx_period); failures++; }
   if(p.adx_threshold < 0.0)
   { PrintFormat("HTFLTF §38: adx_threshold=%.6f — must be >= 0", p.adx_threshold); failures++; }

   //--- §9.3
   if(p.location_threshold <= 0.0)
   { PrintFormat("HTFLTF §38: location_threshold=%.6f — must be > 0", p.location_threshold); failures++; }

   //--- §10.5.C
   if(p.max_retracement_bars < 1)
   { PrintFormat("HTFLTF §38: max_retracement_bars=%d — must be >= 1", p.max_retracement_bars); failures++; }

   //--- §12
   if(p.roc_strong_threshold <= p.roc_negative_threshold)
   {
      PrintFormat("HTFLTF §38: roc_strong_threshold=%.6f — must be > "
                  "roc_negative_threshold=%.6f; otherwise the WEAK band is empty or inverted",
                  p.roc_strong_threshold, p.roc_negative_threshold);
      failures++;
   }
   if(p.roc_period < 1)
   { PrintFormat("HTFLTF §38: roc_period=%d — must be >= 1", p.roc_period); failures++; }

   //--- §12.2 risk tiers
   if(p.high_confidence_risk_percent <= 0.0)
   { PrintFormat("HTFLTF §38: high_confidence_risk_percent=%.6f — must be > 0", p.high_confidence_risk_percent); failures++; }
   else if(p.high_confidence_risk_percent > HTFLTF_RISK_CEILING_PERCENT)
   {
      PrintFormat("HTFLTF §38: high_confidence_risk_percent=%.6f — exceeds the %.1f%% "
                  "account-risk ceiling; treated as a likely input error, not a valid "
                  "aggressive setting", p.high_confidence_risk_percent, HTFLTF_RISK_CEILING_PERCENT);
      failures++;
   }
   if(p.low_confidence_risk_percent <= 0.0)
   { PrintFormat("HTFLTF §38: low_confidence_risk_percent=%.6f — must be > 0", p.low_confidence_risk_percent); failures++; }
   else if(p.low_confidence_risk_percent > HTFLTF_RISK_CEILING_PERCENT)
   {
      PrintFormat("HTFLTF §38: low_confidence_risk_percent=%.6f — exceeds the %.1f%% "
                  "account-risk ceiling", p.low_confidence_risk_percent, HTFLTF_RISK_CEILING_PERCENT);
      failures++;
   }
   if(p.low_confidence_risk_percent > p.high_confidence_risk_percent)
   {
      PrintFormat("HTFLTF §38: low_confidence_risk_percent=%.6f — inverted tiers: must "
                  "be <= high_confidence_risk_percent=%.6f",
                  p.low_confidence_risk_percent, p.high_confidence_risk_percent);
      failures++;
   }

   //--- §14
   if(p.maximum_slippage < 0.0)
   { PrintFormat("HTFLTF §38: maximum_slippage=%.6f — must be >= 0", p.maximum_slippage); failures++; }

   //--- §16
   if(p.trailing_activation_r < 0.0)
   { PrintFormat("HTFLTF §38: trailing_activation_r=%.6f — must be >= 0", p.trailing_activation_r); failures++; }
   if(p.breakeven_enabled)
   {
      if(p.breakeven_activation_r < 0.0)
      {
         PrintFormat("HTFLTF §38: breakeven_activation_r=%.6f — must be >= 0 when "
                     "breakeven is enabled", p.breakeven_activation_r);
         failures++;
      }
      if(p.breakeven_buffer < 0.0)
      {
         PrintFormat("HTFLTF §38: breakeven_buffer=%.6f — must be >= 0; the buffer sits "
                     "on the losing side of entry (§16.3)", p.breakeven_buffer);
         failures++;
      }
   }
   if(p.shadow_lookback_bars < 1)
   {
      // v0.7, finding B-6: Average_LTF_Shadow had no lookback defined at all in v0.6
      PrintFormat("HTFLTF §38: shadow_lookback_bars=%d — must be >= 1", p.shadow_lookback_bars);
      failures++;
   }

   //--- §17
   if(p.max_daily_loss <= 0.0)
   { PrintFormat("HTFLTF §38: max_daily_loss=%.6f — must be > 0", p.max_daily_loss); failures++; }
   if(p.max_consecutive_losses <= 0)
   { PrintFormat("HTFLTF §38: max_consecutive_losses=%d — must be > 0", p.max_consecutive_losses); failures++; }

   //--- §19 (v0.7, finding M-10)
   if(p.maximum_allowed_spread <= 0.0)
   { PrintFormat("HTFLTF §38: maximum_allowed_spread=%.6f — must be > 0", p.maximum_allowed_spread); failures++; }
   if(p.maximum_normalized_spread <= 0.0)
   { PrintFormat("HTFLTF §38: maximum_normalized_spread=%.6f — must be > 0", p.maximum_normalized_spread); failures++; }

   //--- Session windows are validated by the caller against the configured
   //--- timezone table (§18.1); the check belongs with the session module, which
   //--- arrives in Stage 10.

   if(failures > 0)
      PrintFormat("HTFLTF §38: parameter validation FAILED (%d problem(s)) — refusing to start",
                  failures);
   else
      Print("HTFLTF §38: parameter validation OK");

   return failures;
}
