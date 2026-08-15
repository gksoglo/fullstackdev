//+------------------------------------------------------------------+
//| LiveExecutor.mqh — optional real-order mirror of ONE fixed cell.   |
//|                                                                    |
//| M1 SKELETON: order placement lands in M7.                          |
//|                                                                    |
//| The arm mirrors a cell pinned before the run (InpLiveCellId), never |
//| "the current leader". Following the leader cannot reconcile — the   |
//| leader changes as statistics accumulate, so by the time a cell wins |
//| it already has virtual trades the real book never took — and taking |
//| the leader from the FINAL ranking would use the run's own outcome   |
//| to choose the strategy, which is look-ahead.                        |
//|                                                                    |
//| A cell is (pattern, subset, atr_filter), so exactly one pattern can |
//| fire into it: no cross-pattern tie-break exists or is needed. The   |
//| real constraint is that the cell may open concurrent trades while   |
//| an account holds one position per symbol per direction, so only     |
//| trades beginning while the account is flat are mirrored; the rest   |
//| are logged as live_skipped and excluded from the M7 reconciliation. |
//| The arm proves the simulator's arithmetic; it is not a second       |
//| estimate of the cell's performance.                                 |
//+------------------------------------------------------------------+
#ifndef RL_LIVEEXECUTOR_MQH
#define RL_LIVEEXECUTOR_MQH

#include "../Types.mqh"
#include "../Config.mqh"

class CLiveExecutor
  {
private:
   RLConfig m_cfg;
   int      m_cell_id;
   int      m_skipped;

public:
   CLiveExecutor() : m_cell_id(-1), m_skipped(0) {}

   void Init(const RLConfig &cfg)
     {
      m_cfg     = cfg;
      m_cell_id = cfg.live_cell_id;
      m_skipped = 0;
     }

   bool Enabled() const { return m_cell_id >= 0; }
   int  Skipped() const { return m_skipped; }

   //--- Called for every trade the pinned cell opens. Mirrors only those
   //--- starting from a flat account.
   void OnCellTrade(const int cell_id, const VirtualTrade &t)
     {
      if(!Enabled() || cell_id != m_cell_id)
         return;
      if(PositionSelect(_Symbol))          // already in the market
        {
         m_skipped++;
         return;
        }
      // TODO(M7): place the order via CTrade with t.stop / t.target,
      //           lot size m_cfg.lots, and record the ticket for the
      //           1:1 reconciliation against the virtual ledger.
     }

   void OnDeinit()
     {
      if(Enabled())
         PrintFormat("ReversalLab live arm: cell %d, %d concurrent trades skipped",
                     m_cell_id, m_skipped);
     }
  };

#endif // RL_LIVEEXECUTOR_MQH
