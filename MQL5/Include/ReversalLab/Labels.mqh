//+------------------------------------------------------------------+
//| Labels.mqh — enum-to-string mapping for the CSV output.            |
//|                                                                    |
//| Kept apart from Types.mqh so that header stays inside the MQL5/C++ |
//| common subset and can be compiled by the off-platform tests.       |
//+------------------------------------------------------------------+
#ifndef RL_LABELS_MQH
#define RL_LABELS_MQH

#include "Types.mqh"

string PatternName(const PatternId p)
  {
   switch(p)
     {
      case PAT_ENGULF_BULL:  return "ENGULF_BULL";
      case PAT_ENGULF_BEAR:  return "ENGULF_BEAR";
      case PAT_HAMMER:       return "HAMMER";
      case PAT_SHOOTSTAR:    return "SHOOTSTAR";
      case PAT_MORNINGSTAR:  return "MORNINGSTAR";
      case PAT_EVENINGSTAR:  return "EVENINGSTAR";
      case PAT_PIERCING:     return "PIERCING";
      case PAT_DARKCLOUD:    return "DARKCLOUD";
      case PAT_HARAMI_BULL:  return "HARAMI_BULL";
      case PAT_HARAMI_BEAR:  return "HARAMI_BEAR";
      case PAT_TWEEZER_BOT:  return "TWEEZER_BOT";
      case PAT_TWEEZER_TOP:  return "TWEEZER_TOP";
      default:               return "NONE";
     }
  }

//--- Human-readable subset name, so output is analysable without
//--- decoding bitmasks. Order follows the bit positions: RSI+MACD+STOCH+CCI.
string SubsetLabel(const int mask)
  {
   if(mask == 0)
      return "NONE";
   string s = "";
   if((mask & (1 << IND_RSI))   != 0) s += "RSI";
   if((mask & (1 << IND_MACD))  != 0) s += (StringLen(s) > 0 ? "+MACD"  : "MACD");
   if((mask & (1 << IND_STOCH)) != 0) s += (StringLen(s) > 0 ? "+STOCH" : "STOCH");
   if((mask & (1 << IND_CCI))   != 0) s += (StringLen(s) > 0 ? "+CCI"   : "CCI");
   return s;
  }

string OutcomeName(const Outcome o)
  {
   switch(o)
     {
      case OUT_CONFIRMED: return "CONFIRMED";
      case OUT_FAILED:    return "FAILED";
      case OUT_TIMEOUT:   return "TIMEOUT";
      default:            return "OPEN";
     }
  }

string VoteReasonName(const VoteReason r)
  {
   switch(r)
     {
      case VR_LEVEL: return "LEVEL";
      case VR_CROSS: return "CROSS";
      case VR_TURN:  return "TURN";
      default:       return "NONE";
     }
  }

string RejectReasonName(const RejectReason r)
  {
   switch(r)
     {
      case REJ_NO_TREND:    return "no_trend";
      case REJ_GAP:         return "gap";
      case REJ_RISK_BOUNDS: return "risk_bounds";
      default:              return "none";
     }
  }

//--- Undefined metrics serialise as an EMPTY field, never as a sentinel:
//--- DBL_MAX prints as 1.797693e+308 and silently becomes a real number to
//--- every downstream consumer (PRD §6.3).
string FmtNum(const double v, const int digits = 6)
  {
   if(v == RL_UNDEFINED || v == -RL_UNDEFINED || !MathIsValidNumber(v))
      return "";
   return DoubleToString(v, digits);
  }

#endif // RL_LABELS_MQH
