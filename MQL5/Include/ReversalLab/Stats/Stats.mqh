//+------------------------------------------------------------------+
//| Stats.mqh — per-cell aggregates and the confidence arithmetic.     |
//|                                                                    |
//| MQL5/C++ common subset: compiled by tests/test_core_math.cpp.       |
//+------------------------------------------------------------------+
#ifndef RL_STATS_MQH
#define RL_STATS_MQH

#include "../Types.mqh"

#define RL_Z_95_ONE_SIDED 1.645

//+------------------------------------------------------------------+
//| One-sided lower Wilson bound on a proportion.                      |
//|                                                                    |
//| `n` is a double because it carries the overlap adjustment          |
//| (n_resolved_eff) and is therefore not an integer count. The Wilson  |
//| interval is well defined for non-integer n.                        |
//+------------------------------------------------------------------+
double WilsonLowerBound(const double p, const double n, const double z)
  {
   if(n <= 0.0)
      return 0.0;
   const double z2     = z * z;
   const double denom  = 1.0 + z2 / n;
   const double centre = p + z2 / (2.0 * n);
   double       inner  = p * (1.0 - p) / n + z2 / (4.0 * n * n);
   if(inner < 0.0)
      inner = 0.0;
   const double margin = z * MathSqrt(inner);
   double lower = (centre - margin) / denom;
   if(lower < 0.0) lower = 0.0;
   if(lower > 1.0) lower = 1.0;
   return lower;
  }

//+------------------------------------------------------------------+
//| CellStats — running aggregates for one cell.                       |
//|                                                                    |
//| Overlap tracking is the subtle part. Trades within a cell run       |
//| concurrently (PRD §3 admits every signal), so raw counts overstate  |
//| the independent information available. Two invariants matter:       |
//|                                                                    |
//|   * the numerator sums bars_held, the REALISED duration, never      |
//|     hold_bars, the cap — most trades resolve early, so summing caps |
//|     would inflate overlap and understate every cell;                |
//|   * the denominator counts distinct bars actually covered, never    |
//|     the span from first entry to last exit — otherwise a cell that  |
//|     is busy for a year then idle for two reports near-independence, |
//|     which is backwards for the most clustered cell in the grid.     |
//+------------------------------------------------------------------+
struct CellStats
  {
   int    cell_id;
   int    samples;                  // resolved, non-truncated trades
   int    confirmed, failed, timeout;
   double sum_r, sum_r_sq;
   double gross_win, gross_loss;    // gross_loss kept as a POSITIVE magnitude
   double sum_mfe_r,   sum_mae_r;
   double sum_mfe_atr, sum_mae_atr;
   double sum_risk_atr;             // mean risk_atr exposes the ATR-arm confound
   long   sum_bars_held;            // numerator of overlap_ratio
   int    active_bars;              // distinct bars with >= 1 open trade
   int    admitted;                 // signals admitted, incl. those still open

   void Clear()
     {
      cell_id = -1; samples = 0; confirmed = 0; failed = 0; timeout = 0;
      sum_r = 0.0; sum_r_sq = 0.0; gross_win = 0.0; gross_loss = 0.0;
      sum_mfe_r = 0.0; sum_mae_r = 0.0; sum_mfe_atr = 0.0; sum_mae_atr = 0.0;
      sum_risk_atr = 0.0;
      sum_bars_held = 0; active_bars = 0; admitted = 0;
     }

   int NResolved() const { return confirmed + failed; }

   //--- Mean concurrency WHILE THE CELL HOLDS ANYTHING. Idle stretches
   //--- cannot dilute it because they never increment active_bars.
   double OverlapRatio() const
     {
      if(active_bars <= 0 || sum_bars_held <= 0)
         return 1.0;
      const double r = (double)sum_bars_held / (double)active_bars;
      return (r < 1.0) ? 1.0 : r;      // defensive: cannot be sub-unity
     }

   double NEff()         const { return (double)samples     / OverlapRatio(); }
   double NResolvedEff() const { return (double)NResolved() / OverlapRatio(); }

   //--- Floors apply to the ADJUSTED counts. Gating on raw samples while
   //--- scoring on n_eff would admit a cell of 30 samples at overlap depth
   //--- 6 — thirty observations by the floor, five by the score.
   bool Eligible(const int min_samples, const int min_resolved) const
     {
      if(samples < 2)
         return false;                  // StdevR needs an (n-1) divisor
      return NEff() >= (double)min_samples && NResolvedEff() >= (double)min_resolved;
     }

   double HitRate() const
     {
      const int n = NResolved();
      return (n > 0) ? (double)confirmed / (double)n : 0.0;
     }

   double Expectancy() const
     {
      return (samples > 0) ? sum_r / (double)samples : RL_UNDEFINED;
     }

   double StdevR() const
     {
      if(samples < 2)
         return RL_UNDEFINED;
      const double n    = (double)samples;
      const double mean = sum_r / n;
      double var = (sum_r_sq - n * mean * mean) / (n - 1.0);
      if(var < 0.0) var = 0.0;          // catastrophic-cancellation guard
      return MathSqrt(var);
     }

   double WilsonLower() const
     {
      return WilsonLowerBound(HitRate(), NResolvedEff(), RL_Z_95_ONE_SIDED);
     }

   double ProfitFactor() const
     {
      return (gross_loss > 0.0) ? gross_win / gross_loss : RL_UNDEFINED;
     }

   //--- Ranking key: a one-sided lower confidence bound on expectancy.
   //---
   //--- NOT wilson_lb * expectancy_r. That multiplies an always-positive
   //--- bound by a signed quantity, so among losing cells the order
   //--- inverts: expectancy is ~2.5p-1 under the default payoff, and below
   //--- p=0.4 a BETTER Wilson bound yields a MORE negative product. Most
   //--- reversal cells sit below 0.4, so it scrambles the bulk of the grid.
   //---
   //--- The divisor is n_eff, not samples: overlapping trades share bars,
   //--- so sqrt(samples) would understate the standard error and flatter
   //--- exactly the busiest cells.
   double Score(const int min_samples, const int min_resolved) const
     {
      if(!Eligible(min_samples, min_resolved))
         return -RL_UNDEFINED;
      const double sd = StdevR();
      if(sd == RL_UNDEFINED)
         return -RL_UNDEFINED;
      return Expectancy() - RL_Z_95_ONE_SIDED * sd / MathSqrt(NEff());
     }

   double AvgMfeR()   const { return (samples > 0) ? sum_mfe_r   / samples : RL_UNDEFINED; }
   double AvgMaeR()   const { return (samples > 0) ? sum_mae_r   / samples : RL_UNDEFINED; }
   double AvgMfeAtr() const { return (samples > 0) ? sum_mfe_atr / samples : RL_UNDEFINED; }
   double AvgMaeAtr() const { return (samples > 0) ? sum_mae_atr / samples : RL_UNDEFINED; }
   double TimeoutRate() const { return (samples > 0) ? (double)timeout / samples : 0.0; }
   double AvgRiskAtr()  const { return (samples > 0) ? sum_risk_atr / samples : RL_UNDEFINED; }

   void Record(const VirtualTrade &t)
     {
      if(t.truncated)                  // excluded: had less than its own
         return;                       // hold_bars to resolve (PRD §3)
      samples++;
      sum_r    += t.r_multiple;
      sum_r_sq += t.r_multiple * t.r_multiple;
      if(t.r_multiple >= 0.0) gross_win  += t.r_multiple;
      else                    gross_loss += -t.r_multiple;

      if(t.outcome == OUT_CONFIRMED)    confirmed++;
      else if(t.outcome == OUT_FAILED)  failed++;
      else                              timeout++;

      sum_mfe_r   += t.mfe_r;   sum_mae_r   += t.mae_r;
      sum_mfe_atr += t.mfe_atr; sum_mae_atr += t.mae_atr;
      sum_risk_atr += t.risk_atr;
      sum_bars_held += (long)t.bars_held;
     }
  };

#endif // RL_STATS_MQH
