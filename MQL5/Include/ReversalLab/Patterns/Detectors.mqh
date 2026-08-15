//+------------------------------------------------------------------+
//| Detectors.mqh — the twelve reversal-pattern detectors (M3).        |
//|                                                                    |
//| Each is a pure function of a BarWindow: w.b[0] is the pattern's     |
//| last bar (bar t, closed), w.b[1] the one before it. No detector     |
//| reads the chart, so none can touch the forming bar, and all twelve  |
//| are driven directly by the off-platform tests.                      |
//|                                                                    |
//| DETECTORS TEST SHAPE, NOT SIZE. The minimum-size gate               |
//| (MinPatternATR) belongs to the toggled ATR context filter — putting |
//| it here would apply it to both arms and collapse the filter-off     |
//| control (PRD §5). ATR appears below only where a scale is genuinely |
//| needed to say "this body is negligible"; everything else is a ratio.|
//+------------------------------------------------------------------+
#ifndef RL_DETECTORS_MQH
#define RL_DETECTORS_MQH

#include "../Types.mqh"
#include "../Config.mqh"

//--- A body too small to treat as directional (doji-ish).
bool IsSmallBody(const MqlRates &r, const double atr, const RLConfig &cfg)
  {
   return BarBody(r) <= cfg.small_body_atr * atr;
  }

//--- A body large enough to anchor a two-bar pattern.
bool IsRealBody(const MqlRates &r, const double atr, const RLConfig &cfg)
  {
   return BarBody(r) > cfg.small_body_atr * atr;
  }

//+------------------------------------------------------------------+
//| Engulfing — a real body that swallows the prior body whole.        |
//+------------------------------------------------------------------+
Direction DetectEngulfBull(const BarWindow &w, const double atr, const RLConfig &cfg)
  {
   if(w.count < 2) return DIR_NONE;
   if(!BarIsDown(w.b[1]) || !BarIsUp(w.b[0]))          return DIR_NONE;
   if(!IsRealBody(w.b[0], atr, cfg))                   return DIR_NONE;
   if(!(w.b[0].open <= w.b[1].close))                  return DIR_NONE;
   if(!(w.b[0].close >= w.b[1].open))                  return DIR_NONE;
   //--- Strictly larger, else two equal bodies qualify as engulfing.
   if(!(BarBody(w.b[0]) > BarBody(w.b[1])))            return DIR_NONE;
   return DIR_BULL;
  }

Direction DetectEngulfBear(const BarWindow &w, const double atr, const RLConfig &cfg)
  {
   if(w.count < 2) return DIR_NONE;
   if(!BarIsUp(w.b[1]) || !BarIsDown(w.b[0]))          return DIR_NONE;
   if(!IsRealBody(w.b[0], atr, cfg))                   return DIR_NONE;
   if(!(w.b[0].open >= w.b[1].close))                  return DIR_NONE;
   if(!(w.b[0].close <= w.b[1].open))                  return DIR_NONE;
   if(!(BarBody(w.b[0]) > BarBody(w.b[1])))            return DIR_NONE;
   return DIR_BEAR;
  }

//+------------------------------------------------------------------+
//| Hammer / shooting star — one long wick, a small body pushed to the |
//| opposite end, and almost nothing on the other side.                |
//+------------------------------------------------------------------+
Direction DetectHammer(const BarWindow &w, const double atr, const RLConfig &cfg)
  {
   //--- atr is not otherwise needed here: this shape is entirely ratios.
   //--- The guard keeps the dispatcher's signature uniform and rejects a
   //--- degenerate ATR the way the body-based detectors do implicitly.
   if(w.count < 1 || atr <= 0.0) return DIR_NONE;
   const double range = BarRange(w.b[0]);
   if(range <= 0.0) return DIR_NONE;
   const double body  = BarBody(w.b[0]);
   const double lower = BarLowerWick(w.b[0]);
   const double upper = BarUpperWick(w.b[0]);
   if(!(lower >= cfg.wick_body_ratio * body))          return DIR_NONE;
   if(!(upper <= cfg.opp_wick_max_ratio * range))      return DIR_NONE;
   //--- A bar with no body at all is a doji, not a hammer, unless the
   //--- long lower wick still dominates the range.
   if(!(lower > range * 0.5))                          return DIR_NONE;
   return DIR_BULL;
  }

Direction DetectShootStar(const BarWindow &w, const double atr, const RLConfig &cfg)
  {
   if(w.count < 1 || atr <= 0.0) return DIR_NONE;      // see DetectHammer
   const double range = BarRange(w.b[0]);
   if(range <= 0.0) return DIR_NONE;
   const double body  = BarBody(w.b[0]);
   const double upper = BarUpperWick(w.b[0]);
   const double lower = BarLowerWick(w.b[0]);
   if(!(upper >= cfg.wick_body_ratio * body))          return DIR_NONE;
   if(!(lower <= cfg.opp_wick_max_ratio * range))      return DIR_NONE;
   if(!(upper > range * 0.5))                          return DIR_NONE;
   return DIR_BEAR;
  }

//+------------------------------------------------------------------+
//| Morning / evening star — impulse, indecision, rejection.           |
//| b[2] carries the trend, b[1] stalls, b[0] closes back through the  |
//| midpoint of b[2]'s body.                                           |
//+------------------------------------------------------------------+
Direction DetectMorningStar(const BarWindow &w, const double atr, const RLConfig &cfg)
  {
   if(w.count < 3) return DIR_NONE;
   if(!BarIsDown(w.b[2]) || !IsRealBody(w.b[2], atr, cfg)) return DIR_NONE;
   if(!(BarBody(w.b[1]) <= cfg.star_body_ratio * BarBody(w.b[2]))) return DIR_NONE;
   if(!BarIsUp(w.b[0]))                                return DIR_NONE;
   if(!(w.b[0].close > BarBodyMid(w.b[2])))            return DIR_NONE;
   //--- The star must sit below the first bar's body, else this is just
   //--- a pullback inside the same range.
   if(!(MathMax(w.b[1].open, w.b[1].close) < w.b[2].open)) return DIR_NONE;
   return DIR_BULL;
  }

Direction DetectEveningStar(const BarWindow &w, const double atr, const RLConfig &cfg)
  {
   if(w.count < 3) return DIR_NONE;
   if(!BarIsUp(w.b[2]) || !IsRealBody(w.b[2], atr, cfg)) return DIR_NONE;
   if(!(BarBody(w.b[1]) <= cfg.star_body_ratio * BarBody(w.b[2]))) return DIR_NONE;
   if(!BarIsDown(w.b[0]))                              return DIR_NONE;
   if(!(w.b[0].close < BarBodyMid(w.b[2])))            return DIR_NONE;
   if(!(MathMin(w.b[1].open, w.b[1].close) > w.b[2].open)) return DIR_NONE;
   return DIR_BEAR;
  }

//+------------------------------------------------------------------+
//| Piercing / dark cloud — opens beyond the prior extreme, then closes|
//| back past the midpoint of the prior body WITHOUT engulfing it.     |
//| The non-engulf clause keeps these disjoint from the engulfing pair.|
//+------------------------------------------------------------------+
Direction DetectPiercing(const BarWindow &w, const double atr, const RLConfig &cfg)
  {
   if(w.count < 2) return DIR_NONE;
   if(!BarIsDown(w.b[1]) || !IsRealBody(w.b[1], atr, cfg)) return DIR_NONE;
   if(!BarIsUp(w.b[0]))                                return DIR_NONE;
   if(!(w.b[0].open < w.b[1].close))                   return DIR_NONE;
   if(!(w.b[0].close > BarBodyMid(w.b[1])))            return DIR_NONE;
   if(!(w.b[0].close < w.b[1].open))                   return DIR_NONE;   // not an engulf
   return DIR_BULL;
  }

Direction DetectDarkCloud(const BarWindow &w, const double atr, const RLConfig &cfg)
  {
   if(w.count < 2) return DIR_NONE;
   if(!BarIsUp(w.b[1]) || !IsRealBody(w.b[1], atr, cfg)) return DIR_NONE;
   if(!BarIsDown(w.b[0]))                              return DIR_NONE;
   if(!(w.b[0].open > w.b[1].close))                   return DIR_NONE;
   if(!(w.b[0].close < BarBodyMid(w.b[1])))            return DIR_NONE;
   if(!(w.b[0].close > w.b[1].open))                   return DIR_NONE;   // not an engulf
   return DIR_BEAR;
  }

//+------------------------------------------------------------------+
//| Harami — the inverse of engulfing: a large body followed by a      |
//| small one contained entirely within it.                            |
//+------------------------------------------------------------------+
Direction DetectHaramiBull(const BarWindow &w, const double atr, const RLConfig &cfg)
  {
   if(w.count < 2) return DIR_NONE;
   if(!BarIsDown(w.b[1]) || !IsRealBody(w.b[1], atr, cfg)) return DIR_NONE;
   if(!BarIsUp(w.b[0]))                                return DIR_NONE;
   if(!(w.b[0].open > w.b[1].close))                   return DIR_NONE;
   if(!(w.b[0].close < w.b[1].open))                   return DIR_NONE;
   if(!(BarBody(w.b[0]) < BarBody(w.b[1])))            return DIR_NONE;
   return DIR_BULL;
  }

Direction DetectHaramiBear(const BarWindow &w, const double atr, const RLConfig &cfg)
  {
   if(w.count < 2) return DIR_NONE;
   if(!BarIsUp(w.b[1]) || !IsRealBody(w.b[1], atr, cfg)) return DIR_NONE;
   if(!BarIsDown(w.b[0]))                              return DIR_NONE;
   if(!(w.b[0].open < w.b[1].close))                   return DIR_NONE;
   if(!(w.b[0].close > w.b[1].open))                   return DIR_NONE;
   if(!(BarBody(w.b[0]) < BarBody(w.b[1])))            return DIR_NONE;
   return DIR_BEAR;
  }

//+------------------------------------------------------------------+
//| Tweezers — two bars rejecting the same level, with the second      |
//| turning against the first.                                         |
//+------------------------------------------------------------------+
Direction DetectTweezerBot(const BarWindow &w, const double atr, const RLConfig &cfg)
  {
   if(w.count < 2) return DIR_NONE;
   if(!BarIsDown(w.b[1]) || !BarIsUp(w.b[0]))          return DIR_NONE;
   if(!(MathAbs(w.b[0].low - w.b[1].low) <= cfg.tweezer_tol_atr * atr)) return DIR_NONE;
   return DIR_BULL;
  }

Direction DetectTweezerTop(const BarWindow &w, const double atr, const RLConfig &cfg)
  {
   if(w.count < 2) return DIR_NONE;
   if(!BarIsUp(w.b[1]) || !BarIsDown(w.b[0]))          return DIR_NONE;
   if(!(MathAbs(w.b[0].high - w.b[1].high) <= cfg.tweezer_tol_atr * atr)) return DIR_NONE;
   return DIR_BEAR;
  }

//+------------------------------------------------------------------+
Direction RunDetector(const PatternId p, const BarWindow &w,
                      const double atr, const RLConfig &cfg)
  {
   switch(p)
     {
      case PAT_ENGULF_BULL: return DetectEngulfBull (w, atr, cfg);
      case PAT_ENGULF_BEAR: return DetectEngulfBear (w, atr, cfg);
      case PAT_HAMMER:      return DetectHammer     (w, atr, cfg);
      case PAT_SHOOTSTAR:   return DetectShootStar  (w, atr, cfg);
      case PAT_MORNINGSTAR: return DetectMorningStar(w, atr, cfg);
      case PAT_EVENINGSTAR: return DetectEveningStar(w, atr, cfg);
      case PAT_PIERCING:    return DetectPiercing   (w, atr, cfg);
      case PAT_DARKCLOUD:   return DetectDarkCloud  (w, atr, cfg);
      case PAT_HARAMI_BULL: return DetectHaramiBull (w, atr, cfg);
      case PAT_HARAMI_BEAR: return DetectHaramiBear (w, atr, cfg);
      case PAT_TWEEZER_BOT: return DetectTweezerBot (w, atr, cfg);
      case PAT_TWEEZER_TOP: return DetectTweezerTop (w, atr, cfg);
      default:              return DIR_NONE;
     }
  }

//--- Bars each pattern spans. Drives the prior-trend window offset, so it
//--- must stay in step with the detectors above.
int PatternBarCount(const PatternId p)
  {
   switch(p)
     {
      case PAT_HAMMER:
      case PAT_SHOOTSTAR:    return 1;
      case PAT_MORNINGSTAR:
      case PAT_EVENINGSTAR:  return 3;
      default:               return 2;
     }
  }

//+------------------------------------------------------------------+
//| Prior-trend precondition.                                          |
//|                                                                    |
//| The window ends before the pattern's FIRST bar. For a 3-bar star   |
//| ending at t that is t-3 .. t-7, never t-1 .. t-5 — the latter puts |
//| two of the pattern's own bars inside the trend measurement, partly |
//| measuring the pattern against itself (PRD §4).                     |
//+------------------------------------------------------------------+
bool HasPriorTrend(const BarWindow &w, const int bar_count,
                   const Direction reversal_dir, const double atr,
                   const RLConfig &cfg)
  {
   if(atr <= 0.0 || reversal_dir == DIR_NONE)
      return false;

   const int newest = bar_count;                        // first bar before the pattern
   const int oldest = newest + cfg.trend_lookback - 1;
   if(oldest >= w.count)
      return false;

   const double move     = w.b[newest].close - w.b[oldest].close;
   const double required = cfg.min_prior_move_atr * atr;

   //--- The prior move must run AGAINST the pattern's direction.
   if(reversal_dir == DIR_BULL)
      return move <= -required;
   return move >= required;
  }

#endif // RL_DETECTORS_MQH
