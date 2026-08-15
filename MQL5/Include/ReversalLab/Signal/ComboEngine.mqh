//+------------------------------------------------------------------+
//| ComboEngine.mqh — trade construction and the 384-cell fan-out.     |
//|                                                                    |
//| The pure-math helpers at the top are in the MQL5/C++ common subset  |
//| and are compiled by tests/test_core_math.cpp.                       |
//+------------------------------------------------------------------+
#ifndef RL_COMBOENGINE_MQH
#define RL_COMBOENGINE_MQH

#include "../Types.mqh"
#include "../Config.mqh"

//+------------------------------------------------------------------+
//| Hold window, scaled to the distance the trade must travel.         |
//|                                                                    |
//| A fixed bar count cannot serve a variable stop. A 3-ATR stop puts   |
//| the target 1.5*3 = 4.5 ATR away and needs a far larger move than a  |
//| 0.5-ATR-stop trade; given equal bars the wide one times out more.   |
//| Since MinPatternATR selects FOR large patterns in the filter-on     |
//| arm, a fixed window would reintroduce the very confound the         |
//| pattern-anchored stop removed, through the timeout channel.         |
//+------------------------------------------------------------------+
int HoldBarsFor(const double risk, const double atr, const RLConfig &cfg)
  {
   if(atr <= 0.0)
      return cfg.hold_bars_min;
   const double raw = cfg.hold_bars_per_atr * cfg.reward_ratio * (risk / atr);
   int bars = (int)MathRound(raw);
   if(bars < cfg.hold_bars_min) bars = cfg.hold_bars_min;
   if(bars > cfg.hold_bars_max) bars = cfg.hold_bars_max;
   return bars;
  }

//+------------------------------------------------------------------+
//| Gap check. Entry is the NEXT bar's open, so a weekend or news gap  |
//| can print it outside the trade's own levels:                       |
//|                                                                    |
//|   * through the stop  -> invalidated before it begins;             |
//|   * past the target   -> an instant +RewardRatio for a move the     |
//|                          signal never predicted.                    |
//|                                                                    |
//| Both are rejected. The sign-agnostic form below is positive only    |
//| when entry lies strictly between stop and target, for either        |
//| direction.                                                          |
//+------------------------------------------------------------------+
bool PassesGapCheck(const double entry, const double stop, const double target)
  {
   return ((entry - stop) * (target - entry)) > 0.0;
  }

bool PassesRiskBounds(const double risk, const double atr, const RLConfig &cfg)
  {
   if(atr <= 0.0)
      return false;
   return (risk >= cfg.min_risk_atr * atr) && (risk <= cfg.max_risk_atr * atr);
  }

//+------------------------------------------------------------------+
//| Build the trade prototype from a staged signal plus the entry      |
//| price. Everything here is cell-independent, which is exactly why    |
//| the gap and risk-bound tests live at signal level: evaluating them  |
//| inside OpenVirtual would count one rejection 384 times.             |
//|                                                                    |
//| Returns REJ_NONE on success.                                        |
//+------------------------------------------------------------------+
RejectReason BuildTrade(const Signal &sig, const double entry,
                        const RLConfig &cfg, VirtualTrade &out)
  {
   out.Clear();

   const double sign = (sig.dir == DIR_BULL) ? 1.0 : -1.0;
   const double stop = sig.pattern_extreme - sign * cfg.stop_buffer_atr * sig.atr;
   const double risk = MathAbs(entry - stop);

   if(!PassesRiskBounds(risk, sig.atr, cfg))
      return REJ_RISK_BOUNDS;

   const double target = entry + sign * cfg.reward_ratio * risk;

   if(!PassesGapCheck(entry, stop, target))
      return REJ_GAP;

   out.entry_time = sig.bar_time;      // overwritten with t+1's time by caller
   out.entry_bar  = sig.bar_index + 1;
   out.entry      = entry;
   out.stop       = stop;
   out.target     = target;
   out.risk       = risk;
   out.atr        = sig.atr;
   out.risk_atr   = risk / sig.atr;
   out.dir        = sig.dir;
   out.hold_bars  = HoldBarsFor(risk, sig.atr, cfg);
   out.outcome    = OUT_OPEN;
   return REJ_NONE;
  }

//+------------------------------------------------------------------+
//| Realised R, net of cost. Cost is charged once per trade on EVERY    |
//| outcome, timeouts included.                                         |
//+------------------------------------------------------------------+
double RMultiple(const VirtualTrade &t, const double cost_price)
  {
   if(t.risk <= 0.0)
      return 0.0;
   const double gross = (double)(int)t.dir * (t.exit_price - t.entry);
   return (gross - cost_price) / t.risk;
  }

#endif // RL_COMBOENGINE_MQH
