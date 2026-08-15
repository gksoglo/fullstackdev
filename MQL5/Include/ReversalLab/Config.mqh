//+------------------------------------------------------------------+
//| Config.mqh — input mirror + validation.                           |
//|                                                                   |
//| The EA's `input` variables are copied here once in OnInit so that  |
//| every module takes a const reference rather than reaching for      |
//| globals, and so the pure-math paths stay testable off-platform.    |
//+------------------------------------------------------------------+
#ifndef RL_CONFIG_MQH
#define RL_CONFIG_MQH

#include "Types.mqh"

struct RLConfig
  {
   //--- Trade model
   double stop_buffer_atr;     // stop = pattern extreme -/+ this x ATR
   double reward_ratio;
   double hold_bars_per_atr;   // hold window scales with target distance
   int    hold_bars_min;
   int    hold_bars_max;
   double min_risk_atr;
   double max_risk_atr;
   double cost_points;

   //--- Pattern gates
   int    trend_lookback;
   double min_prior_move_atr;
   double tweezer_tol_atr;

   //--- Detector shape thresholds. Exposed as inputs precisely because
   //--- pattern definitions are subjective and these choices materially
   //--- change detection counts (PRD §11) — only a knob can be swept.
   double small_body_atr;      // body at/below this (x ATR) counts as "small"
   double wick_body_ratio;     // hammer / shooting-star wick vs its own body
   double opp_wick_max_ratio;  // opposite wick as a fraction of total range
   double star_body_ratio;     // star's body vs the preceding bar's body

   //--- Indicators / ATR context filter
   int    atr_period;
   double min_pattern_atr;     // part of the TOGGLED filter, not a detector gate
   int    rsi_period;
   int    macd_fast, macd_slow, macd_signal;
   int    stoch_k, stoch_d, stoch_slow;
   int    cci_period;
   int    atr_sma_period;
   double atr_regime_low;
   double atr_regime_high;

   //--- Vote thresholds. Inputs for the same reason the shape thresholds
   //--- are: they decide how often each voter speaks at all.
   double rsi_oversold, rsi_overbought;
   double stoch_oversold, stoch_overbought;
   double cci_threshold;

   //--- Engine
   ConfirmMode confirm_mode;
   int    warmup_bars;
   int    min_samples;         // floor on n_eff
   int    min_resolved;        // floor on n_resolved_eff
   int    live_cell_id;        // -1 = disabled
   double lots;
   bool   log_indicator_history;

   void SetDefaults()
     {
      stop_buffer_atr = 0.25;  reward_ratio = 1.5;
      hold_bars_per_atr = 13.0; hold_bars_min = 8; hold_bars_max = 60;
      min_risk_atr = 0.25;     max_risk_atr = 3.0;   cost_points = 0.0;

      trend_lookback = 5;      min_prior_move_atr = 1.0; tweezer_tol_atr = 0.10;
      small_body_atr = 0.10;   wick_body_ratio = 2.0;
      opp_wick_max_ratio = 0.30; star_body_ratio = 0.50;

      atr_period = 14;         min_pattern_atr = 0.8;
      rsi_period = 14;
      macd_fast = 12;          macd_slow = 26;       macd_signal = 9;
      stoch_k = 14;            stoch_d = 3;          stoch_slow = 3;
      cci_period = 20;
      atr_sma_period = 50;     atr_regime_low = 0.7; atr_regime_high = 1.8;
      rsi_oversold = 30.0;     rsi_overbought = 70.0;
      stoch_oversold = 20.0;   stoch_overbought = 80.0;
      cci_threshold = 100.0;

      confirm_mode = CONFIRM_ALL;
      warmup_bars = 100;       min_samples = 30;     min_resolved = 20;
      live_cell_id = -1;       lots = 0.10;          log_indicator_history = false;
     }

   //--- Minimum closed bars before any signal may be evaluated. The binding
   //--- constraint is the regime band: SMA(ATR,50) over ATR(14) needs ~64 bars.
   //--- Without the floor the first ~70 bars vote off partially-filled
   //--- buffers and get tallied as real (PRD §5).
   int RequiredWarmup() const
     {
      int need = atr_period + atr_sma_period;              // regime band
      int macd = macd_slow + macd_signal;
      int stoch_need = stoch_k + stoch_d + stoch_slow;
      if(macd > need)       need = macd;
      if(stoch_need > need) need = stoch_need;
      if(cci_period > need) need = cci_period;
      if(rsi_period > need) need = rsi_period;
      return need + trend_lookback + 3;                    // + deepest pattern
     }
  };

//--- Returns true when the configuration is self-consistent. `err` receives
//--- a code identifying the first failure; the EA maps it to a message and
//--- fails OnInit loudly rather than producing quietly wrong statistics.
enum ConfigError
  {
   CFG_OK = 0,
   CFG_BAD_REWARD,
   CFG_BAD_RISK_BOUNDS,
   CFG_BAD_HOLD_BARS,
   CFG_BAD_REGIME_BAND,
   CFG_BAD_WARMUP,
   CFG_BAD_ELIGIBILITY,
   CFG_BAD_LIVE_CELL,
   CFG_BAD_PERIODS,
   CFG_BAD_SHAPE,
   CFG_WINDOW_TOO_SMALL
  };

//--- Bars a detection needs: the deepest pattern (3) plus the prior-trend
//--- window, which starts AFTER the pattern's own bars.
int RequiredWindow(const RLConfig &c) { return 3 + c.trend_lookback + 1; }

ConfigError ValidateConfig(const RLConfig &c)
  {
   if(c.reward_ratio <= 0.0)                    return CFG_BAD_REWARD;
   if(c.stop_buffer_atr < 0.0)                  return CFG_BAD_RISK_BOUNDS;
   if(c.min_risk_atr <= 0.0)                    return CFG_BAD_RISK_BOUNDS;
   if(c.max_risk_atr <= c.min_risk_atr)         return CFG_BAD_RISK_BOUNDS;
   if(c.hold_bars_min < 1)                      return CFG_BAD_HOLD_BARS;
   if(c.hold_bars_max < c.hold_bars_min)        return CFG_BAD_HOLD_BARS;
   if(c.hold_bars_per_atr <= 0.0)               return CFG_BAD_HOLD_BARS;
   if(c.atr_regime_low <= 0.0)                  return CFG_BAD_REGIME_BAND;
   if(c.atr_regime_high <= c.atr_regime_low)    return CFG_BAD_REGIME_BAND;
   if(c.min_pattern_atr < 0.0)                  return CFG_BAD_REGIME_BAND;
   if(c.warmup_bars < c.RequiredWarmup())       return CFG_BAD_WARMUP;
   if(c.min_samples < 1 || c.min_resolved < 1)  return CFG_BAD_ELIGIBILITY;
   if(c.min_resolved > c.min_samples)           return CFG_BAD_ELIGIBILITY;
   if(c.live_cell_id < -1 || c.live_cell_id >= CELL_COUNT) return CFG_BAD_LIVE_CELL;
   if(c.atr_period < 1 || c.rsi_period < 1 || c.cci_period < 1) return CFG_BAD_PERIODS;
   if(c.macd_fast >= c.macd_slow)               return CFG_BAD_PERIODS;
   if(c.trend_lookback < 1)                     return CFG_BAD_PERIODS;
   if(c.small_body_atr <= 0.0)                  return CFG_BAD_SHAPE;
   if(c.wick_body_ratio <= 0.0)                 return CFG_BAD_SHAPE;
   if(c.opp_wick_max_ratio <= 0.0 || c.opp_wick_max_ratio >= 1.0) return CFG_BAD_SHAPE;
   if(c.star_body_ratio <= 0.0 || c.star_body_ratio >= 1.0)       return CFG_BAD_SHAPE;
   if(c.tweezer_tol_atr < 0.0)                  return CFG_BAD_SHAPE;
   if(c.rsi_oversold >= c.rsi_overbought)       return CFG_BAD_SHAPE;
   if(c.stoch_oversold >= c.stoch_overbought)   return CFG_BAD_SHAPE;
   if(c.cci_threshold <= 0.0)                   return CFG_BAD_SHAPE;
   if(RequiredWindow(c) > RL_WINDOW_MAX)        return CFG_WINDOW_TOO_SMALL;
   return CFG_OK;
  }

#endif // RL_CONFIG_MQH
