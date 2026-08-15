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

      atr_period = 14;         min_pattern_atr = 0.8;
      rsi_period = 14;
      macd_fast = 12;          macd_slow = 26;       macd_signal = 9;
      stoch_k = 14;            stoch_d = 3;          stoch_slow = 3;
      cci_period = 20;
      atr_sma_period = 50;     atr_regime_low = 0.7; atr_regime_high = 1.8;

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
   CFG_BAD_PERIODS
  };

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
   return CFG_OK;
  }

#endif // RL_CONFIG_MQH
