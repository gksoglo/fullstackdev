//+------------------------------------------------------------------+
//| VirtualBook.mqh — the per-cell simulated ledgers.                  |
//|                                                                    |
//| There is no busy gate. Every cell takes every signal it admits,     |
//| including while it already holds open trades. A one-trade-per-cell  |
//| rule would make cells busy at different times and so score each on  |
//| a different subsample, biasing lift_vs_control and breaking the     |
//| subset-nesting property (PRD §3). The resulting sample correlation  |
//| is handled by the overlap adjustment in CellStats, not here.        |
//+------------------------------------------------------------------+
#ifndef RL_VIRTUALBOOK_MQH
#define RL_VIRTUALBOOK_MQH

#include "../Types.mqh"
#include "../Config.mqh"
#include "../Signal/ComboEngine.mqh"

class CVirtualBook
  {
private:
   VirtualTrade m_open[];        // all open trades across all cells
   RLConfig     m_cfg;
   double       m_cost_price;

   //--- Scratch flags: which cells held anything on the bar just marched.
   //--- Drives active_bars, the denominator of overlap_ratio.
   bool         m_touched[CELL_COUNT];

   void Remove(const int idx)
     {
      const int last = ArraySize(m_open) - 1;
      if(idx < last)
         m_open[idx] = m_open[last];
      ArrayResize(m_open, last);
     }

public:
   void Init(const RLConfig &cfg, const double point)
     {
      m_cfg        = cfg;
      m_cost_price = cfg.cost_points * point;
      ArrayResize(m_open, 0);
     }

   int OpenCount() const { return ArraySize(m_open); }

   void OpenVirtual(const int cell_id, const VirtualTrade &proto)
     {
      const int n = ArraySize(m_open);
      ArrayResize(m_open, n + 1);
      m_open[n]         = proto;
      m_open[n].cell_id = cell_id;
      m_open[n].outcome = OUT_OPEN;
     }

   //+---------------------------------------------------------------+
   //| March every open trade against one completed bar.               |
   //|                                                                 |
   //| Resolution order is pessimistic: if the bar's range spans both   |
   //| stop and target, the stop wins. That deliberately under-states   |
   //| results rather than flattering them, and it also settles the     |
   //| gapped-entry case where both levels sit inside the entry bar.    |
   //|                                                                 |
   //| Resolved trades are appended to `closed` for the caller to log   |
   //| and tally.                                                       |
   //+---------------------------------------------------------------+
   void MarchOpenTrades(const MqlRates &bar, const int bar_index,
                        VirtualTrade &closed[])
     {
      ArrayResize(closed, 0);
      ArrayInitialize(m_touched, false);

      for(int i = ArraySize(m_open) - 1; i >= 0; i--)
        {
         m_touched[m_open[i].cell_id] = true;
         m_open[i].bars_held++;              // entry bar counts as 1

         const double sign = (double)m_open[i].dir;

         //--- Excursions, tracked in both unit systems. risk is
         //--- pattern-derived and ranges 0.25-3.0 ATR, so an R and an ATR
         //--- are different distances and the two are not interchangeable.
         const double best  = (m_open[i].dir == DIR_BULL) ? bar.high : bar.low;
         const double worst = (m_open[i].dir == DIR_BULL) ? bar.low  : bar.high;
         const double fav   = sign * (best  - m_open[i].entry);
         const double adv   = sign * (m_open[i].entry - worst);

         if(fav / m_open[i].risk > m_open[i].mfe_r)
           {
            m_open[i].mfe_r   = fav / m_open[i].risk;
            m_open[i].mfe_atr = fav / m_open[i].atr;
           }
         if(adv / m_open[i].risk > m_open[i].mae_r)
           {
            m_open[i].mae_r   = adv / m_open[i].risk;
            m_open[i].mae_atr = adv / m_open[i].atr;
           }

         const bool hit_stop   = (m_open[i].dir == DIR_BULL)
                                 ? (bar.low  <= m_open[i].stop)
                                 : (bar.high >= m_open[i].stop);
         const bool hit_target = (m_open[i].dir == DIR_BULL)
                                 ? (bar.high >= m_open[i].target)
                                 : (bar.low  <= m_open[i].target);

         Outcome result = OUT_OPEN;
         if(hit_stop)                                  // pessimistic tie-break
           {
            result                = OUT_FAILED;
            m_open[i].exit_price  = m_open[i].stop;
           }
         else if(hit_target)
           {
            result                = OUT_CONFIRMED;
            m_open[i].exit_price  = m_open[i].target;
           }
         else if(m_open[i].bars_held >= m_open[i].hold_bars)
           {
            result                = OUT_TIMEOUT;
            m_open[i].exit_price  = bar.close;
           }

         if(result == OUT_OPEN)
            continue;

         m_open[i].outcome    = result;
         m_open[i].exit_time  = bar.time;
         m_open[i].r_multiple = RMultiple(m_open[i], m_cost_price);

         const int c = ArraySize(closed);
         ArrayResize(closed, c + 1);
         closed[c] = m_open[i];
         Remove(i);
        }
     }

   //--- Which cells were active on the bar just marched. The caller feeds
   //--- this into CellStats.active_bars, so idle stretches never inflate
   //--- the denominator of overlap_ratio.
   bool CellWasActive(const int cell_id) const { return m_touched[cell_id]; }

   //+---------------------------------------------------------------+
   //| End of data. Trades still open are marked truncated: they had   |
   //| less than their own hold_bars to resolve, so counting them      |
   //| would bias the tail of the sample. They are logged, then        |
   //| excluded from CellStats by CellStats::Record.                   |
   //+---------------------------------------------------------------+
   void CloseAllAtEnd(const double last_close, const datetime last_time,
                      VirtualTrade &closed[])
     {
      ArrayResize(closed, 0);
      for(int i = 0; i < ArraySize(m_open); i++)
        {
         m_open[i].outcome    = OUT_TIMEOUT;
         m_open[i].truncated  = true;
         m_open[i].exit_price = last_close;
         m_open[i].exit_time  = last_time;
         m_open[i].r_multiple = RMultiple(m_open[i], m_cost_price);
         const int c = ArraySize(closed);
         ArrayResize(closed, c + 1);
         closed[c] = m_open[i];
        }
      ArrayResize(m_open, 0);
     }
  };

#endif // RL_VIRTUALBOOK_MQH
