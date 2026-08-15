//+------------------------------------------------------------------+
//| PatternScanner.mqh — fills the bar window, runs every detector and  |
//| applies the prior-trend gate.                                      |
//|                                                                    |
//| Phase 1 only. The window starts at the most recent CLOSED bar, so   |
//| no detection can reach the forming bar.                             |
//+------------------------------------------------------------------+
#ifndef RL_PATTERNSCANNER_MQH
#define RL_PATTERNSCANNER_MQH

#include "../Types.mqh"
#include "../Config.mqh"
#include "Detectors.mqh"

//--- Load `count` closed bars into the window, series-ordered from `shift`
//--- (which must be >= 1). w.b[0] becomes the bar at `shift`.
bool FillBarWindow(const string sym, const ENUM_TIMEFRAMES tf,
                   const int shift, const int count, BarWindow &w)
  {
   w.count = 0;
   if(shift < 1 || count < 1 || count > RL_WINDOW_MAX)
      return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(sym, tf, shift, count, rates) != count)
      return false;

   for(int i = 0; i < count; i++)
      w.b[i] = rates[i];
   w.count = count;
   return true;
  }

//+------------------------------------------------------------------+
//| Scan the window for every pattern.                                 |
//|                                                                    |
//| Patterns are not mutually exclusive — a hammer, a bullish engulfing |
//| and a tweezer bottom can all fire on one bar, and bullish and       |
//| bearish patterns can both fire. Each is dispatched to the cells     |
//| carrying its own PatternId, so simultaneous detections never        |
//| compete and no tie-break is needed anywhere in the design.          |
//|                                                                    |
//| Returns the count written to `out`.                                 |
//+------------------------------------------------------------------+
int ScanWindow(const BarWindow &w, const datetime bar_time, const int bar_index,
               const double atr, const double atr_sma,
               const RLConfig &cfg, Signal &out[], int &rejected_no_trend)
  {
   int found = 0;
   ArrayResize(out, 0);
   if(atr <= 0.0)
      return 0;

   for(int i = 0; i < PATTERN_COUNT; i++)
     {
      const PatternId p   = PatternFromIndex(i);
      const Direction dir = RunDetector(p, w, atr, cfg);
      if(dir == DIR_NONE)
         continue;

      const int bars = PatternBarCount(p);

      if(!HasPriorTrend(w, bars, dir, atr, cfg))
        {
         rejected_no_trend++;
         continue;
        }

      Signal s;
      s.Clear();
      s.bar_time  = bar_time;
      s.bar_index = bar_index;
      s.pattern   = p;
      s.dir       = dir;
      s.bar_count = bars;
      s.atr       = atr;
      s.atr_sma   = atr_sma;

      //--- Extremes across the pattern's own bars. The low anchors a
      //--- bullish stop, the high a bearish one.
      double hi = w.b[0].high;
      double lo = w.b[0].low;
      for(int k = 1; k < bars; k++)
        {
         hi = MathMax(hi, w.b[k].high);
         lo = MathMin(lo, w.b[k].low);
        }
      s.pattern_range   = hi - lo;
      s.pattern_extreme = (dir == DIR_BULL) ? lo : hi;

      //--- ATR context filter. BOTH conditions belong to the toggled
      //--- dimension; neither is a detector gate, so the filter-off arm
      //--- remains a true no-ATR-context control.
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
