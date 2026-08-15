//+------------------------------------------------------------------+
//| Detectors.mqh — the twelve reversal-pattern detectors.             |
//|                                                                    |
//| M1 SKELETON: every detector returns DIR_NONE. Bodies land in M3.    |
//|                                                                    |
//| Contract for M3 implementers:                                      |
//|   * `shift` is the pattern's LAST bar and is always >= 1 (closed).  |
//|   * Read no bar with a smaller shift — bar 0 is still forming, and  |
//|     touching it repaints every downstream statistic.                |
//|   * All size thresholds divide by `atr` so the library stays        |
//|     instrument-agnostic; these are shape tests, not size tests.     |
//|     The size gate (MinPatternATR) belongs to the TOGGLED ATR filter |
//|     in IndicatorHub, never here — putting it here would collapse    |
//|     the filter-off control arm (PRD §5).                            |
//|   * Return the pattern's own direction; the prior-trend gate is     |
//|     applied by PatternScanner, not by the detector.                 |
//+------------------------------------------------------------------+
#ifndef RL_DETECTORS_MQH
#define RL_DETECTORS_MQH

#include "../Types.mqh"
#include "../Config.mqh"

//--- Small helpers the detectors will share. Implemented now because they
//--- are trivial and the detectors read better against them.
double BarBody(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
  {
   return MathAbs(iClose(sym, tf, shift) - iOpen(sym, tf, shift));
  }

double BarRange(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
  {
   return iHigh(sym, tf, shift) - iLow(sym, tf, shift);
  }

double UpperWick(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
  {
   return iHigh(sym, tf, shift) - MathMax(iOpen(sym, tf, shift), iClose(sym, tf, shift));
  }

double LowerWick(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
  {
   return MathMin(iOpen(sym, tf, shift), iClose(sym, tf, shift)) - iLow(sym, tf, shift);
  }

bool IsUpBar(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
  {
   return iClose(sym, tf, shift) > iOpen(sym, tf, shift);
  }

//--- One detector per pattern, all stubbed for M1. The signature is spelled
//--- out rather than hidden behind a macro: MQL5's preprocessor is plain text
//--- substitution and a macro standing in for a parameter list is a needless
//--- portability risk in a file that twelve functions depend on.
Direction DetectEngulfBull(const string sym, const ENUM_TIMEFRAMES tf,
                           const int shift, const double atr, const RLConfig &cfg)
  { return DIR_NONE; }                                               // TODO(M3)

Direction DetectEngulfBear(const string sym, const ENUM_TIMEFRAMES tf,
                           const int shift, const double atr, const RLConfig &cfg)
  { return DIR_NONE; }                                               // TODO(M3)

Direction DetectHammer(const string sym, const ENUM_TIMEFRAMES tf,
                       const int shift, const double atr, const RLConfig &cfg)
  { return DIR_NONE; }                                               // TODO(M3)

Direction DetectShootStar(const string sym, const ENUM_TIMEFRAMES tf,
                          const int shift, const double atr, const RLConfig &cfg)
  { return DIR_NONE; }                                               // TODO(M3)

Direction DetectMorningStar(const string sym, const ENUM_TIMEFRAMES tf,
                            const int shift, const double atr, const RLConfig &cfg)
  { return DIR_NONE; }                                               // TODO(M3)

Direction DetectEveningStar(const string sym, const ENUM_TIMEFRAMES tf,
                            const int shift, const double atr, const RLConfig &cfg)
  { return DIR_NONE; }                                               // TODO(M3)

Direction DetectPiercing(const string sym, const ENUM_TIMEFRAMES tf,
                         const int shift, const double atr, const RLConfig &cfg)
  { return DIR_NONE; }                                               // TODO(M3)

Direction DetectDarkCloud(const string sym, const ENUM_TIMEFRAMES tf,
                          const int shift, const double atr, const RLConfig &cfg)
  { return DIR_NONE; }                                               // TODO(M3)

Direction DetectHaramiBull(const string sym, const ENUM_TIMEFRAMES tf,
                           const int shift, const double atr, const RLConfig &cfg)
  { return DIR_NONE; }                                               // TODO(M3)

Direction DetectHaramiBear(const string sym, const ENUM_TIMEFRAMES tf,
                           const int shift, const double atr, const RLConfig &cfg)
  { return DIR_NONE; }                                               // TODO(M3)

Direction DetectTweezerBot(const string sym, const ENUM_TIMEFRAMES tf,
                           const int shift, const double atr, const RLConfig &cfg)
  { return DIR_NONE; }                                               // TODO(M3)

Direction DetectTweezerTop(const string sym, const ENUM_TIMEFRAMES tf,
                           const int shift, const double atr, const RLConfig &cfg)
  { return DIR_NONE; }                                               // TODO(M3)

//--- Dispatch by id, plus each pattern's bar span. The span drives the
//--- prior-trend window offset, so it must stay in step with the detectors.
Direction RunDetector(const PatternId p, const string sym, const ENUM_TIMEFRAMES tf,
                      const int shift, const double atr, const RLConfig &cfg)
  {
   switch(p)
     {
      case PAT_ENGULF_BULL: return DetectEngulfBull (sym, tf, shift, atr, cfg);
      case PAT_ENGULF_BEAR: return DetectEngulfBear (sym, tf, shift, atr, cfg);
      case PAT_HAMMER:      return DetectHammer     (sym, tf, shift, atr, cfg);
      case PAT_SHOOTSTAR:   return DetectShootStar  (sym, tf, shift, atr, cfg);
      case PAT_MORNINGSTAR: return DetectMorningStar(sym, tf, shift, atr, cfg);
      case PAT_EVENINGSTAR: return DetectEveningStar(sym, tf, shift, atr, cfg);
      case PAT_PIERCING:    return DetectPiercing   (sym, tf, shift, atr, cfg);
      case PAT_DARKCLOUD:   return DetectDarkCloud  (sym, tf, shift, atr, cfg);
      case PAT_HARAMI_BULL: return DetectHaramiBull (sym, tf, shift, atr, cfg);
      case PAT_HARAMI_BEAR: return DetectHaramiBear (sym, tf, shift, atr, cfg);
      case PAT_TWEEZER_BOT: return DetectTweezerBot (sym, tf, shift, atr, cfg);
      case PAT_TWEEZER_TOP: return DetectTweezerTop (sym, tf, shift, atr, cfg);
      default:              return DIR_NONE;
     }
  }

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

#endif // RL_DETECTORS_MQH
