//+------------------------------------------------------------------+
//| Tally.mqh — the 384 cell ledgers and the ranking report.           |
//+------------------------------------------------------------------+
#ifndef RL_TALLY_MQH
#define RL_TALLY_MQH

#include "../Types.mqh"
#include "../Config.mqh"
#include "../Labels.mqh"
#include "Stats.mqh"

class CTally
  {
private:
   CellStats m_cells[CELL_COUNT];
   RLConfig  m_cfg;
   int       m_rejected[4];        // indexed by RejectReason
   int       m_rejected_no_conf;   // signals that reached no cell at all

public:
   void Init(const RLConfig &cfg)
     {
      m_cfg = cfg;
      for(int i = 0; i < CELL_COUNT; i++)
        {
         m_cells[i].Clear();
         m_cells[i].cell_id = i;
        }
      ArrayInitialize(m_rejected, 0);
      m_rejected_no_conf = 0;
     }

   void Record(const VirtualTrade &t)
     {
      if(t.cell_id < 0 || t.cell_id >= CELL_COUNT)
         return;
      m_cells[t.cell_id].Record(t);       // ignores truncated trades itself
     }

   void NoteAdmitted(const int cell_id)
     {
      if(cell_id >= 0 && cell_id < CELL_COUNT)
         m_cells[cell_id].admitted++;
     }

   //--- Rejections are counted ONCE PER SIGNAL, never once per cell: the
   //--- gap and risk-bound tests are cell-independent, so tallying them
   //--- inside the fan-out would multiply each by 384.
   void NoteRejected(const RejectReason r) { if(r > 0 && r < 4) m_rejected[r]++; }
   void NoteNoConfirmation()               { m_rejected_no_conf++; }

   //--- active_bars is bumped for every cell that held a trade on the bar
   //--- just marched. Idle bars are never counted, which is what keeps a
   //--- clustered-then-quiet cell from reporting false independence.
   void NoteActiveBar(const int cell_id)
     {
      if(cell_id >= 0 && cell_id < CELL_COUNT)
         m_cells[cell_id].active_bars++;
     }

   //--- Copy accessor. CellStats is a struct, so GetPointer() is not
   //--- available for it in MQL5 — that is a class-only facility.
   void GetCell(const int i, CellStats &out) const { out = m_cells[i]; }

   //--- Control arm for a pattern at a given ATR-filter state: the same
   //--- pattern with the empty subset. lift is measured against this, and
   //--- always at the SAME filter state so it isolates the indicators.
   double ControlExpectancy(const int cell_id) const
     {
      const PatternId p = PatternFromIndex(CellPatternIndex(cell_id));
      const int ctrl = CellId(p, 0, CellAtrOn(cell_id));
      const double e = m_cells[ctrl].Expectancy();
      return (e == RL_UNDEFINED) ? RL_UNDEFINED : e;
     }

   double Lift(const int cell_id) const
     {
      const double e = m_cells[cell_id].Expectancy();
      const double c = ControlExpectancy(cell_id);
      if(e == RL_UNDEFINED || c == RL_UNDEFINED)
         return RL_UNDEFINED;
      return e - c;
     }

   //+---------------------------------------------------------------+
   //| Ranking CSV. Cells that never fired, and cells that fired but   |
   //| stayed ineligible, are written with an empty score and their    |
   //| admitted count intact — "never fired" and "fired, no edge" are  |
   //| different findings and must not both render as a blank row.     |
   //+---------------------------------------------------------------+
   bool WriteRanking(const string path)
     {
      const int fh = FileOpen(path, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
      if(fh == INVALID_HANDLE)
        {
         PrintFormat("ReversalLab: cannot write %s (error %d)", path, GetLastError());
         return false;
        }

      FileWrite(fh,
                "cell_id", "pattern", "subset_mask", "subset_label", "atr_filter",
                "admitted", "samples", "n_resolved", "overlap_ratio", "n_eff",
                "n_resolved_eff", "eligible", "hit_rate", "wilson_lb",
                "expectancy_r", "stdev_r", "score", "lift_vs_control",
                "profit_factor", "timeout_rate",
                "avg_mfe_r", "avg_mae_r", "avg_mfe_atr", "avg_mae_atr");

      for(int i = 0; i < CELL_COUNT; i++)
        {
         const int mask = CellSubsetMask(i);
         FileWrite(fh,
                   IntegerToString(i),
                   PatternName(PatternFromIndex(CellPatternIndex(i))),
                   IntegerToString(mask),
                   SubsetLabel(mask),
                   CellAtrOn(i) ? "1" : "0",
                   IntegerToString(m_cells[i].admitted),
                   IntegerToString(m_cells[i].samples),
                   IntegerToString(m_cells[i].NResolved()),
                   FmtNum(m_cells[i].OverlapRatio(), 3),
                   FmtNum(m_cells[i].NEff(), 2),
                   FmtNum(m_cells[i].NResolvedEff(), 2),
                   m_cells[i].Eligible(m_cfg.min_samples, m_cfg.min_resolved) ? "1" : "0",
                   FmtNum(m_cells[i].HitRate(), 4),
                   FmtNum(m_cells[i].WilsonLower(), 4),
                   FmtNum(m_cells[i].Expectancy(), 4),
                   FmtNum(m_cells[i].StdevR(), 4),
                   FmtNum(m_cells[i].Score(m_cfg.min_samples, m_cfg.min_resolved), 4),
                   FmtNum(Lift(i), 4),
                   FmtNum(m_cells[i].ProfitFactor(), 3),
                   FmtNum(m_cells[i].TimeoutRate(), 3),
                   FmtNum(m_cells[i].AvgMfeR(), 3),
                   FmtNum(m_cells[i].AvgMaeR(), 3),
                   FmtNum(m_cells[i].AvgMfeAtr(), 3),
                   FmtNum(m_cells[i].AvgMaeAtr(), 3));
        }

      FileClose(fh);
      return true;
     }

   //--- Journal summary. Top cells plus the rejection tallies.
   void PrintSummary(const int top_n = 20)
     {
      int    order[CELL_COUNT];
      double score[CELL_COUNT];
      for(int i = 0; i < CELL_COUNT; i++)
        {
         order[i] = i;
         score[i] = m_cells[i].Score(m_cfg.min_samples, m_cfg.min_resolved);
        }

      //--- Selection sort over 384 entries: run once, at OnDeinit.
      for(int i = 0; i < CELL_COUNT - 1; i++)
        {
         int best = i;
         for(int j = i + 1; j < CELL_COUNT; j++)
            if(score[order[j]] > score[order[best]])
               best = j;
         const int tmp = order[i]; order[i] = order[best]; order[best] = tmp;
        }

      Print("=== ReversalLab ranking (top ", top_n, " by score) ===");
      int shown = 0;
      for(int i = 0; i < CELL_COUNT && shown < top_n; i++)
        {
         const int c = order[i];
         if(!m_cells[c].Eligible(m_cfg.min_samples, m_cfg.min_resolved))
            break;
         PrintFormat("%2d. %-12s %-20s atr=%d  n=%d n_eff=%.1f  hit=%.3f  E=%+.3f  lift=%+.3f  score=%+.3f",
                     shown + 1,
                     PatternName(PatternFromIndex(CellPatternIndex(c))),
                     SubsetLabel(CellSubsetMask(c)),
                     CellAtrOn(c) ? 1 : 0,
                     m_cells[c].samples, m_cells[c].NEff(),
                     m_cells[c].HitRate(), m_cells[c].Expectancy(),
                     Lift(c), score[c]);
         shown++;
        }
      if(shown == 0)
         Print("  (no cell reached the eligibility floors)");

      PrintFormat("rejected: no_trend=%d gap=%d risk_bounds=%d no_confirmation=%d",
                  m_rejected[REJ_NO_TREND], m_rejected[REJ_GAP],
                  m_rejected[REJ_RISK_BOUNDS], m_rejected_no_conf);
     }
  };

#endif // RL_TALLY_MQH
