//+------------------------------------------------------------------+
//| CsvLogger.mqh — buffered signal and trade logs.                    |
//+------------------------------------------------------------------+
#ifndef RL_CSVLOGGER_MQH
#define RL_CSVLOGGER_MQH

#include "../Types.mqh"
#include "../Config.mqh"
#include "../Labels.mqh"

class CCsvLogger
  {
private:
   int    m_fh_signals;
   int    m_fh_trades;
   string m_dir;

   string TimeStr(const datetime t) const
     {
      return (t == 0) ? "" : TimeToString(t, TIME_DATE | TIME_MINUTES | TIME_SECONDS);
     }

public:
   CCsvLogger() : m_fh_signals(INVALID_HANDLE), m_fh_trades(INVALID_HANDLE) {}

   bool Init(const string symbol, const string tf_name, const string run_id)
     {
      m_dir = "ReversalLab";
      const string sig_path = StringFormat("%s\\signals_%s_%s_%s.csv",
                                           m_dir, symbol, tf_name, run_id);
      const string trd_path = StringFormat("%s\\trades_%s_%s_%s.csv",
                                           m_dir, symbol, tf_name, run_id);

      m_fh_signals = FileOpen(sig_path, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
      m_fh_trades  = FileOpen(trd_path, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
      if(m_fh_signals == INVALID_HANDLE || m_fh_trades == INVALID_HANDLE)
        {
         PrintFormat("ReversalLab: cannot open logs (error %d)", GetLastError());
         return false;
        }

      //--- Signal row: written AFTER phase-2 instantiation and before cell
      //--- admission, so it carries both the detection context and the
      //--- resulting trade parameters. reason_* makes a vote auditable from
      //--- one row: every rule is a two-bar rule, so the levels alone cannot
      //--- show what happened at t-1.
      FileWrite(m_fh_signals,
                "bar_time", "entry_time", "symbol", "tf", "pattern", "dir", "bar_count",
                "atr", "atr_sma50", "pattern_range_atr", "pattern_extreme",
                "entry", "risk", "risk_atr", "hold_bars",
                "rsi", "macd_main", "macd_signal", "macd_hist",
                "stoch_k", "stoch_d", "cci",
                "vote_rsi", "vote_macd", "vote_stoch", "vote_cci",
                "reason_rsi", "reason_macd", "reason_stoch", "reason_cci",
                "atr_filter_pass", "prior_trend_pass", "gap_pass",
                "risk_bounds_pass", "admitted_cell_count");

      //--- Excursions in BOTH unit systems: risk is pattern-derived and
      //--- spans 0.25-3.0 ATR, so an R and an ATR are different distances.
      //--- risk_atr on every row is the conversion factor.
      FileWrite(m_fh_trades,
                "cell_id", "pattern", "subset_mask", "subset_label", "atr_filter",
                "entry_time", "exit_time", "dir",
                "entry", "stop", "target", "exit_price", "risk", "risk_atr",
                "bars_held", "hold_bars", "outcome", "r_multiple",
                "mfe_r", "mae_r", "mfe_atr", "mae_atr", "truncated");
      return true;
     }

   void WriteSignal(const string symbol, const string tf_name,
                    const Signal &s, const VoteVector &v,
                    const datetime entry_time, const double entry,
                    const double risk, const double risk_atr, const int hold_bars,
                    const double macd_main, const double macd_signal,
                    const double stoch_d,
                    const bool prior_trend_pass, const bool gap_pass,
                    const bool risk_bounds_pass, const int admitted_count)
     {
      if(m_fh_signals == INVALID_HANDLE)
         return;
      FileWrite(m_fh_signals,
                TimeStr(s.bar_time), TimeStr(entry_time), symbol, tf_name,
                PatternName(s.pattern), IntegerToString((int)s.dir),
                IntegerToString(s.bar_count),
                FmtNum(s.atr), FmtNum(s.atr_sma),
                FmtNum(s.atr > 0.0 ? s.pattern_range / s.atr : RL_UNDEFINED, 3),
                FmtNum(s.pattern_extreme),
                FmtNum(entry), FmtNum(risk), FmtNum(risk_atr, 3),
                IntegerToString(hold_bars),
                FmtNum(v.value[IND_RSI], 3), FmtNum(macd_main), FmtNum(macd_signal),
                FmtNum(v.value[IND_MACD]), FmtNum(v.value[IND_STOCH], 3),
                FmtNum(stoch_d, 3), FmtNum(v.value[IND_CCI], 3),
                IntegerToString(v.vote[IND_RSI]),   IntegerToString(v.vote[IND_MACD]),
                IntegerToString(v.vote[IND_STOCH]), IntegerToString(v.vote[IND_CCI]),
                VoteReasonName(v.reason[IND_RSI]),   VoteReasonName(v.reason[IND_MACD]),
                VoteReasonName(v.reason[IND_STOCH]), VoteReasonName(v.reason[IND_CCI]),
                s.atr_filter_pass ? "1" : "0",
                prior_trend_pass  ? "1" : "0",
                gap_pass          ? "1" : "0",
                risk_bounds_pass  ? "1" : "0",
                IntegerToString(admitted_count));
     }

   void WriteTrade(const VirtualTrade &t)
     {
      if(m_fh_trades == INVALID_HANDLE)
         return;
      const int mask = CellSubsetMask(t.cell_id);
      FileWrite(m_fh_trades,
                IntegerToString(t.cell_id),
                PatternName(PatternFromIndex(CellPatternIndex(t.cell_id))),
                IntegerToString(mask), SubsetLabel(mask),
                CellAtrOn(t.cell_id) ? "1" : "0",
                TimeStr(t.entry_time), TimeStr(t.exit_time),
                IntegerToString((int)t.dir),
                FmtNum(t.entry), FmtNum(t.stop), FmtNum(t.target),
                FmtNum(t.exit_price), FmtNum(t.risk), FmtNum(t.risk_atr, 3),
                IntegerToString(t.bars_held), IntegerToString(t.hold_bars),
                OutcomeName(t.outcome), FmtNum(t.r_multiple, 4),
                FmtNum(t.mfe_r, 3), FmtNum(t.mae_r, 3),
                FmtNum(t.mfe_atr, 3), FmtNum(t.mae_atr, 3),
                t.truncated ? "1" : "0");
     }

   void Deinit()
     {
      if(m_fh_signals != INVALID_HANDLE) { FileClose(m_fh_signals); m_fh_signals = INVALID_HANDLE; }
      if(m_fh_trades  != INVALID_HANDLE) { FileClose(m_fh_trades);  m_fh_trades  = INVALID_HANDLE; }
     }
  };

#endif // RL_CSVLOGGER_MQH
