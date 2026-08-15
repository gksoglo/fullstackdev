//+------------------------------------------------------------------+
//| Voters.mqh — reduce each momentum indicator to -1 / 0 / +1.        |
//|                                                                    |
//| M1 SKELETON: every voter returns 0 / VR_NONE. Bodies land in M2.    |
//|                                                                    |
//| Every rule is a TWO-BAR rule — a cross is only visible against the  |
//| prior value — which is why each voter takes a 3-element window      |
//| (`v[0]` = bar t, `v[1]` = t-1, `v[2]` = t-2) and why the clause     |
//| that fired is returned as a VoteReason. A single CSV row cannot     |
//| otherwise show what happened at t-1, and without that a vote is not |
//| auditable after the fact (PRD §5, §7).                              |
//+------------------------------------------------------------------+
#ifndef RL_VOTERS_MQH
#define RL_VOTERS_MQH

#include "../Types.mqh"
#include "../Config.mqh"

//--- Did `series` cross `level` upward within the window? (t-2 -> t)
bool CrossedUp(const double &series[], const double level)
  {
   return (series[1] <= level && series[0] > level)
       || (series[2] <= level && series[1] > level);
  }

bool CrossedDown(const double &series[], const double level)
  {
   return (series[1] >= level && series[0] < level)
       || (series[2] >= level && series[1] < level);
  }

//+------------------------------------------------------------------+
//| RSI: +1 at or below 30 (LEVEL) or crossing up through 30 (CROSS).  |
//+------------------------------------------------------------------+
int VoteRsi(const double &rsi[], const RLConfig &cfg, VoteReason &reason)
  {
   reason = VR_NONE;
   return 0;                                                     // TODO(M2)
  }

//+------------------------------------------------------------------+
//| MACD: +1 when the histogram turns up from a negative trough (TURN) |
//| or main crosses above signal (CROSS).                              |
//+------------------------------------------------------------------+
int VoteMacd(const double &main[], const double &signal[], const double &hist[],
             const RLConfig &cfg, VoteReason &reason)
  {
   reason = VR_NONE;
   return 0;                                                     // TODO(M2)
  }

//+------------------------------------------------------------------+
//| Stochastic: +1 when %K is oversold AND crosses above %D (CROSS).   |
//+------------------------------------------------------------------+
int VoteStoch(const double &k[], const double &d[],
              const RLConfig &cfg, VoteReason &reason)
  {
   reason = VR_NONE;
   return 0;                                                     // TODO(M2)
  }

//+------------------------------------------------------------------+
//| CCI: +1 at or below -100 (LEVEL) or crossing up through it (CROSS).|
//+------------------------------------------------------------------+
int VoteCci(const double &cci[], const RLConfig &cfg, VoteReason &reason)
  {
   reason = VR_NONE;
   return 0;                                                     // TODO(M2)
  }

#endif // RL_VOTERS_MQH
