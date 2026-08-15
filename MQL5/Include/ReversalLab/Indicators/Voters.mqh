//+------------------------------------------------------------------+
//| Voters.mqh — reduce each momentum indicator to -1 / 0 / +1 (M2).   |
//|                                                                    |
//| Every rule is a TWO-BAR rule: a cross is only visible against the   |
//| prior value. Each voter therefore takes a 3-element series window   |
//| (v[0] = bar t, v[1] = t-1, v[2] = t-2) and returns the clause that  |
//| fired as a VoteReason. Without that reason a vote cannot be audited |
//| from a CSV row, because the row for bar t cannot show what happened |
//| at t-1 (PRD §5, §7).                                                |
//|                                                                    |
//| The window is wrapped in a struct rather than passed as a bare      |
//| array so the same declaration compiles under MQL5 (which requires   |
//| `&` on array parameters) and C++ (which does not).                  |
//+------------------------------------------------------------------+
#ifndef RL_VOTERS_MQH
#define RL_VOTERS_MQH

#include "../Types.mqh"
#include "../Config.mqh"

#define RL_VOTE_WINDOW 3

struct SeriesWindow
  {
   double v[RL_VOTE_WINDOW];        // v[0] = bar t, v[1] = t-1, v[2] = t-2

   void Set(const double a, const double b, const double c)
     { v[0] = a; v[1] = b; v[2] = c; }
  };

//--- Did the series cross `level` upward at t or at t-1?
bool CrossedUp(const SeriesWindow &s, const double level)
  {
   return (s.v[1] <= level && s.v[0] > level)
       || (s.v[2] <= level && s.v[1] > level);
  }

bool CrossedDown(const SeriesWindow &s, const double level)
  {
   return (s.v[1] >= level && s.v[0] < level)
       || (s.v[2] >= level && s.v[1] < level);
  }

//--- Did `a` cross above `b` at t or t-1? (two series, e.g. %K vs %D)
bool CrossedAbove(const SeriesWindow &a, const SeriesWindow &b)
  {
   return (a.v[1] <= b.v[1] && a.v[0] > b.v[0])
       || (a.v[2] <= b.v[2] && a.v[1] > b.v[1]);
  }

bool CrossedBelow(const SeriesWindow &a, const SeriesWindow &b)
  {
   return (a.v[1] >= b.v[1] && a.v[0] < b.v[0])
       || (a.v[2] >= b.v[2] && a.v[1] < b.v[1]);
  }

//+------------------------------------------------------------------+
//| RSI: oversold outright (LEVEL), or crossing back up out of it      |
//| (CROSS). LEVEL is tested first so a bar that is both reports the   |
//| stronger, simpler reason.                                          |
//+------------------------------------------------------------------+
int VoteRsi(const SeriesWindow &rsi, const RLConfig &cfg, VoteReason &reason)
  {
   reason = VR_NONE;
   if(rsi.v[0] <= cfg.rsi_oversold)   { reason = VR_LEVEL; return  1; }
   if(rsi.v[0] >= cfg.rsi_overbought) { reason = VR_LEVEL; return -1; }
   if(CrossedUp(rsi, cfg.rsi_oversold))     { reason = VR_CROSS; return  1; }
   if(CrossedDown(rsi, cfg.rsi_overbought)) { reason = VR_CROSS; return -1; }
   return 0;
  }

//+------------------------------------------------------------------+
//| MACD: the histogram turning up from a NEGATIVE trough (TURN), or   |
//| main crossing above signal (CROSS).                                |
//|                                                                    |
//| TURN requires the trough to sit below zero: a histogram bottoming  |
//| out above zero is a pullback within an uptrend, not a reversal      |
//| signal, and admitting it would fire this voter in exactly the       |
//| conditions the study treats as "no reversal due".                   |
//+------------------------------------------------------------------+
//--- No RLConfig parameter: unlike the other three, MACD's rule has no
//--- tunable level — zero is the only meaningful threshold for a histogram.
int VoteMacd(const SeriesWindow &main, const SeriesWindow &signal,
             const SeriesWindow &hist, VoteReason &reason)
  {
   reason = VR_NONE;

   const bool trough_up   = (hist.v[1] < 0.0) && (hist.v[1] <= hist.v[2]) && (hist.v[0] > hist.v[1]);
   const bool peak_down   = (hist.v[1] > 0.0) && (hist.v[1] >= hist.v[2]) && (hist.v[0] < hist.v[1]);
   if(trough_up) { reason = VR_TURN; return  1; }
   if(peak_down) { reason = VR_TURN; return -1; }

   if(CrossedAbove(main, signal)) { reason = VR_CROSS; return  1; }
   if(CrossedBelow(main, signal)) { reason = VR_CROSS; return -1; }
   return 0;
  }

//+------------------------------------------------------------------+
//| Stochastic: %K must be in the extreme zone AND cross %D. Both are  |
//| required, so the only reason this voter reports is CROSS.          |
//+------------------------------------------------------------------+
int VoteStoch(const SeriesWindow &k, const SeriesWindow &d,
              const RLConfig &cfg, VoteReason &reason)
  {
   reason = VR_NONE;
   if(k.v[0] <= cfg.stoch_oversold && CrossedAbove(k, d))
     { reason = VR_CROSS; return  1; }
   if(k.v[0] >= cfg.stoch_overbought && CrossedBelow(k, d))
     { reason = VR_CROSS; return -1; }
   return 0;
  }

//+------------------------------------------------------------------+
//| CCI: beyond the +/-100 band (LEVEL), or crossing back in (CROSS).  |
//+------------------------------------------------------------------+
int VoteCci(const SeriesWindow &cci, const RLConfig &cfg, VoteReason &reason)
  {
   reason = VR_NONE;
   if(cci.v[0] <= -cfg.cci_threshold) { reason = VR_LEVEL; return  1; }
   if(cci.v[0] >=  cfg.cci_threshold) { reason = VR_LEVEL; return -1; }
   if(CrossedUp(cci,   -cfg.cci_threshold)) { reason = VR_CROSS; return  1; }
   if(CrossedDown(cci,  cfg.cci_threshold)) { reason = VR_CROSS; return -1; }
   return 0;
  }

#endif // RL_VOTERS_MQH
