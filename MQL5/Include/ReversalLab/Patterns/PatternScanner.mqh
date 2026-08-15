//+------------------------------------------------------------------+
//| PatternScanner.mqh — runs the detectors and applies the prior-trend |
//| gate. Phase 1 only: may read bar `shift` and earlier, never later.  |
//+------------------------------------------------------------------+
#ifndef RL_PATTERNSCANNER_MQH
#define RL_PATTERNSCANNER_MQH

#include "../Types.mqh"
#include "../Config.mqh"
#include "Detectors.mqh"

//+------------------------------------------------------------------+
//| Prior-trend precondition.                                          |
//|                                                                    |
//| The window ends before the pattern's FIRST bar, not before bar t.  |
//| For a 3-bar morning star ending at t the window is t-8 .. t-3, and |
//| never t-5 .. t-1 — the latter puts two of the pattern's own bars   |
//| inside the trend measurement, partly measuring the pattern against |
//| itself. That is why bar_count is a parameter (PRD §4).             |
//+------------------------------------------------------------------+
bool HasPriorTrend(const string sym, const ENUM_TIMEFRAMES tf,
                   const int shift, const int bar_count,
                   const Direction reversal_dir, const double atr,
                   const RLConfig &cfg)
  {
   if(atr <= 0.0 || reversal_dir == DIR_NONE)
      return false;

   const int win_end   = shift + bar_count;                  // first bar before the pattern
   const int win_start = win_end + cfg.trend_lookback - 1;   // oldest bar in the window

   if(Bars(sym, tf) <= win_start + 1)
      return false;

   const double newest = iClose(sym, tf, win_end);
   const double oldest = iClose(sym, tf, win_start);
   const double move   = newest - oldest;

   //--- The prior move must run AGAINST the pattern's direction: down for a
   //--- bullish reversal, up for a bearish one.
   const double required = cfg.min_prior_move_atr * atr;
   if(reversal_dir == DIR_BULL)
      return move <= -required;
   return move >= required;
  }

//+------------------------------------------------------------------+
//| Scan one closed bar for every pattern.                             |
//|                                                                    |
//| Patterns are not mutually exclusive — a hammer, a bullish engulfing |
//| and a tweezer bottom can all fire on the same bar, and bullish and  |
//| bearish patterns can both fire. Each goes to the cells carrying its |
//| own PatternId, so simultaneous detections never compete and no      |
//| tie-break is needed anywhere in the design.                         |
//|                                                                    |
//| Returns the number of signals written to `out`.                     |
//+------------------------------------------------------------------+
int ScanBar(const string sym, const ENUM_TIMEFRAMES tf, const int shift,
            const int bar_index, const double atr, const double atr_sma,
            const RLConfig &cfg, Signal &out[], int &rejected_no_trend)
  {
   int found = 0;
   ArrayResize(out, 0);

   for(int i = 0; i < PATTERN_COUNT; i++)
     {
      const PatternId  p   = PatternFromIndex(i);
      const Direction  dir = RunDetector(p, sym, tf, shift, atr, cfg);
      if(dir == DIR_NONE)
         continue;

      const int bars = PatternBarCount(p);

      if(!HasPriorTrend(sym, tf, shift, bars, dir, atr, cfg))
        {
         rejected_no_trend++;
         continue;
        }

      Signal s;
      s.Clear();
      s.bar_time  = iTime(sym, tf, shift);
      s.bar_index = bar_index;
      s.pattern   = p;
      s.dir       = dir;
      s.bar_count = bars;
      s.atr       = atr;
      s.atr_sma   = atr_sma;

      //--- Extremes across the pattern's own bars. The low anchors a bullish
      //--- stop, the high a bearish one.
      double hi = iHigh(sym, tf, shift);
      double lo = iLow (sym, tf, shift);
      for(int b = 1; b < bars; b++)
        {
         hi = MathMax(hi, iHigh(sym, tf, shift + b));
         lo = MathMin(lo, iLow (sym, tf, shift + b));
        }
      s.pattern_range   = hi - lo;
      s.pattern_extreme = (dir == DIR_BULL) ? lo : hi;

      //--- ATR context filter. Both conditions belong to the TOGGLED
      //--- dimension; neither is a detector gate.
      const bool size_ok   = (s.pattern_range >= cfg.min_pattern_atr * atr);
      const bool regime_ok = (atr_sma > 0.0)
                             && (atr >= cfg.atr_regime_low  * atr_sma)
                             && (atr <= cfg.atr_regime_high * atr_sma);
      s.atr_filter_pass = (size_ok && regime_ok);

      ArrayResize(out, found + 1);
      out[found] = s;
      found++;
     }

   return found;
  }

#endif // RL_PATTERNSCANNER_MQH
