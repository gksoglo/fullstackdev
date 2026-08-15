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
                "profit_factor", "timeout_rate", "avg_risk_atr",
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
                   FmtNum(m_cells[i].AvgRiskAtr(), 3),
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

      PrintPerPattern();
      PrintIndicatorMarginals();
      PrintRedundancy();
      PrintAtrComparison();
      PrintNoData();
     }

   //--- §8.2 Per-pattern: the best subset, its lift, and the control it beat.
   void PerPatternBest(const int pat_idx, int &best_cell, double &best_score) const
     {
      best_cell = -1; best_score = -RL_UNDEFINED;
      for(int mask = 0; mask < SUBSET_COUNT; mask++)
         for(int a = 0; a < 2; a++)
           {
            const int c = pat_idx * CELL_STRIDE + mask * 2 + a;
            if(!m_cells[c].Eligible(m_cfg.min_samples, m_cfg.min_resolved))
               continue;
            const double s = m_cells[c].Score(m_cfg.min_samples, m_cfg.min_resolved);
            if(s > best_score) { best_score = s; best_cell = c; }
           }
     }

   void PrintPerPattern()
     {
      Print("--- per pattern: best subset vs its own control ---");
      for(int p = 0; p < PATTERN_COUNT; p++)
        {
         int best; double bs;
         PerPatternBest(p, best, bs);
         const string name = PatternName(PatternFromIndex(p));
         if(best < 0)
           {
            PrintFormat("  %-12s (no eligible cell)", name);
            continue;
           }
         const int ctrl = p * CELL_STRIDE + 0 * 2 + (CellAtrOn(best) ? 1 : 0);
         PrintFormat("  %-12s best=%-20s atr=%d n=%d E=%+.3f lift=%+.3f | control E=%+.3f n=%d",
                     name, SubsetLabel(CellSubsetMask(best)), CellAtrOn(best) ? 1 : 0,
                     m_cells[best].samples, m_cells[best].Expectancy(), Lift(best),
                     m_cells[ctrl].Expectancy(), m_cells[ctrl].samples);
        }
     }

   //--- §8.3 Per-indicator marginal contribution. Sample-WEIGHTED, because
   //--- subsets differ in sample count by orders of magnitude; and the
   //--- "without" group EXCLUDES the empty control, whose lift is 0 by
   //--- definition and would drag that arm toward zero mechanically.
   void PrintIndicatorMarginals()
     {
      Print("--- per indicator: sample-weighted mean lift, with vs without ---");
      for(int i = 0; i < IND_COUNT; i++)
        {
         double w_with = 0.0, l_with = 0.0, w_without = 0.0, l_without = 0.0;
         for(int c = 0; c < CELL_COUNT; c++)
           {
            const int mask = CellSubsetMask(c);
            if(mask == 0)                                   // control: lift == 0
               continue;
            if(!m_cells[c].Eligible(m_cfg.min_samples, m_cfg.min_resolved))
               continue;
            const double lift = Lift(c);
            if(lift == RL_UNDEFINED)
               continue;
            const double w = (double)m_cells[c].samples;
            if((mask & (1 << i)) != 0) { w_with    += w; l_with    += w * lift; }
            else                       { w_without += w; l_without += w * lift; }
           }
         const double a = (w_with    > 0.0) ? l_with    / w_with    : 0.0;
         const double b = (w_without > 0.0) ? l_without / w_without : 0.0;
         PrintFormat("  %-6s with=%+.3f (n=%.0f)  without=%+.3f (n=%.0f)  marginal=%+.3f",
                     IndicatorName(i), a, w_with, b, w_without, a - b);
        }
     }

   //--- Redundancy: how often does ADDING an indicator to a subset leave the
   //--- admitted count unchanged? A high figure means that indicator votes
   //--- whenever the others already do, so its cells are duplicates and the
   //--- leaderboard's apparent diversity is illusory.
   void PrintRedundancy()
     {
      Print("--- indicator redundancy: adding it changed nothing in N% of subsets ---");
      for(int i = 0; i < IND_COUNT; i++)
        {
         int compared = 0, unchanged = 0;
         for(int p = 0; p < PATTERN_COUNT; p++)
            for(int mask = 0; mask < SUBSET_COUNT; mask++)
              {
               if((mask & (1 << i)) != 0)
                  continue;                                  // already present
               for(int a = 0; a < 2; a++)
                 {
                  const int base = p * CELL_STRIDE + mask * 2 + a;
                  const int with = p * CELL_STRIDE + (mask | (1 << i)) * 2 + a;
                  if(m_cells[base].admitted < 10)
                     continue;                               // too thin to judge
                  compared++;
                  if(m_cells[with].admitted == m_cells[base].admitted)
                     unchanged++;
                 }
              }
         const double pct = (compared > 0) ? 100.0 * unchanged / compared : 0.0;
         PrintFormat("  %-6s %d/%d subsets unchanged (%.0f%%)",
                     IndicatorName(i), unchanged, compared, pct);
        }
     }

   //--- §8.4 ATR filter on vs off, with the two columns that reveal whether
   //--- the risk-scaled hold window actually neutralised the size confound.
   void PrintAtrComparison()
     {
      Print("--- ATR context filter: off vs on ---");
      for(int a = 0; a < 2; a++)
        {
         double w = 0.0, e = 0.0, t = 0.0, r = 0.0;
         int cells = 0;
         for(int c = 0; c < CELL_COUNT; c++)
           {
            if((CellAtrOn(c) ? 1 : 0) != a)
               continue;
            if(!m_cells[c].Eligible(m_cfg.min_samples, m_cfg.min_resolved))
               continue;
            const double n = (double)m_cells[c].samples;
            w += n;
            e += n * m_cells[c].Expectancy();
            t += n * m_cells[c].TimeoutRate();
            r += n * m_cells[c].AvgRiskAtr();
            cells++;
           }
         if(w <= 0.0)
           { PrintFormat("  atr=%d (no eligible cells)", a); continue; }
         PrintFormat("  atr=%d cells=%d n=%.0f  E=%+.3f  timeout_rate=%.3f  mean_risk_atr=%.2f",
                     a, cells, w, e / w, t / w, r / w);
        }
     }

   //--- §8.6 "Never fired" and "fired but ineligible" are different findings
   //--- and must not both render as a blank row.
   void PrintNoData()
     {
      int never = 0, thin = 0, eligible = 0;
      for(int c = 0; c < CELL_COUNT; c++)
        {
         if(m_cells[c].admitted == 0)                                    never++;
         else if(!m_cells[c].Eligible(m_cfg.min_samples, m_cfg.min_resolved)) thin++;
         else                                                            eligible++;
        }
      PrintFormat("--- coverage: %d eligible, %d fired but below the floors, %d never fired",
                  eligible, thin, never);
     }
  };

#endif // RL_TALLY_MQH
