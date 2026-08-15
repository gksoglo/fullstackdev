//+------------------------------------------------------------------+
//| test_core_math.cpp — verifies the language-independent arithmetic  |
//| of ReversalLab against the acceptance criteria in prd.md.          |
//|                                                                    |
//| Compiles the REAL headers via mql5_shim.h. Covers M5 (cell algebra) |
//| and M6.1 (overlap ratio), plus the ranking-key inversion and the    |
//| gap/hold-window rules that earlier drafts got wrong.                |
//|                                                                    |
//|   g++ -std=c++17 -Wall -Wextra -o /tmp/rl_tests tests/test_core_math.cpp
//+------------------------------------------------------------------+
#include "mql5_shim.h"
#include "../MQL5/Include/ReversalLab/Types.mqh"
#include "../MQL5/Include/ReversalLab/Config.mqh"
#include "../MQL5/Include/ReversalLab/Stats/Stats.mqh"
#include "../MQL5/Include/ReversalLab/Signal/ComboEngine.mqh"

#include <cstdio>
#include <vector>
#include <set>
#include <string>

static int g_failures = 0;
static int g_checks   = 0;

static void Check(bool cond, const std::string &what)
{
   g_checks++;
   if(!cond) { g_failures++; std::printf("  FAIL  %s\n", what.c_str()); }
}

static void CheckNear(double got, double want, double tol, const std::string &what)
{
   g_checks++;
   if(std::fabs(got - want) > tol)
   {
      g_failures++;
      std::printf("  FAIL  %s  (got %.6f, want %.6f)\n", what.c_str(), got, want);
   }
}

static void Section(const char *name) { std::printf("\n== %s\n", name); }

//--------------------------------------------------------------------
// M5 — cell algebra. The bug this pins: PAT_NONE=0 puts the patterns at
// enum 1..12, so indexing on the raw enum reaches 415 against 384 slots
// while leaving 0..31 dead.
//--------------------------------------------------------------------
static void TestCellAlgebra()
{
   Section("M5 cell algebra");

   std::set<int> seen;
   int min_id = 1 << 30, max_id = -1;

   for(int p = 1; p <= PATTERN_COUNT; ++p)
      for(int mask = 0; mask < SUBSET_COUNT; ++mask)
         for(int atr = 0; atr < 2; ++atr)
         {
            const PatternId pid = (PatternId)p;
            const int id = CellId(pid, mask, atr == 1);

            Check(seen.insert(id).second, "cell id is unique");
            if(id < min_id) min_id = id;
            if(id > max_id) max_id = id;

            Check(CellPatternIndex(id) == p - 1, "decode pattern index");
            Check(CellSubsetMask(id)   == mask,  "decode subset mask");
            Check(CellAtrOn(id)        == (atr == 1), "decode atr flag");
         }

   Check((int)seen.size() == CELL_COUNT, "all 384 cells enumerated");
   Check(min_id == 0,               "lowest cell id is 0 (slot 0 not wasted)");
   Check(max_id == CELL_COUNT - 1,  "highest cell id is 383 (no overflow)");

   // The raw-enum bug, asserted explicitly so a regression is obvious.
   const int naive_max = PATTERN_COUNT * CELL_STRIDE + (SUBSET_COUNT - 1) * 2 + 1;
   Check(naive_max == 415, "raw-enum indexing would reach 415");
   Check(PatternIndex(PAT_TWEEZER_TOP) == 11, "last pattern maps to index 11");
   Check(PatternFromIndex(0) == PAT_ENGULF_BULL, "index 0 maps back to first pattern");
}

//--------------------------------------------------------------------
// Subset admission, including the PRD claim that ALL and MAJORITY differ
// for exactly 5 of the 16 subsets (the four triples and the quad).
//--------------------------------------------------------------------
static void TestAdmission()
{
   Section("subset admission");

   VoteVector v; v.Clear();
   Check(v.Admits(DIR_BULL, 0, CONFIRM_ALL), "empty subset always admits (control)");

   // Only RSI confirms bullish.
   v.vote[IND_RSI] = 1;
   Check( v.Admits(DIR_BULL, 1 << IND_RSI,  CONFIRM_ALL), "single confirming indicator admits");
   Check(!v.Admits(DIR_BULL, 1 << IND_MACD, CONFIRM_ALL), "single silent indicator rejects");
   Check(!v.Admits(DIR_BULL, (1 << IND_RSI) | (1 << IND_MACD), CONFIRM_ALL),
         "ALL rejects when one of two is silent");
   Check(!v.Admits(DIR_BEAR, 1 << IND_RSI, CONFIRM_ALL), "bullish vote does not confirm a bearish signal");

   // A neutral vote never confirms.
   v.Clear();
   Check(!v.Admits(DIR_BULL, 1 << IND_CCI, CONFIRM_ALL), "neutral vote does not confirm");

   // Count subsets where ALL and MAJORITY can diverge.
   int divergent = 0;
   for(int mask = 0; mask < SUBSET_COUNT; ++mask)
   {
      const int size = SubsetSize(mask);
      bool differs = false;
      // Enumerate every pattern of confirmations for this subset.
      for(int bits = 0; bits < (1 << IND_COUNT) && !differs; ++bits)
      {
         VoteVector t; t.Clear();
         for(int i = 0; i < IND_COUNT; ++i)
            if((bits & (1 << i)) != 0) t.vote[i] = 1;
         if(t.Admits(DIR_BULL, mask, CONFIRM_ALL) != t.Admits(DIR_BULL, mask, CONFIRM_MAJORITY))
            differs = true;
      }
      if(differs) { divergent++; Check(size >= 3, "divergence only for subsets of size >= 3"); }
   }
   Check(divergent == 5, "ALL vs MAJORITY differ for exactly 5 of 16 subsets");
}

//--------------------------------------------------------------------
// M6.1 — overlap ratio. Three cases, each pinning a way the earlier
// formula was wrong.
//--------------------------------------------------------------------
static VirtualTrade MakeTrade(int entry_bar, int bars_held, double r, Outcome o)
{
   VirtualTrade t; t.Clear();
   t.entry_bar  = entry_bar;
   t.bars_held  = bars_held;
   t.hold_bars  = 60;              // deliberately far above bars_held:
   t.r_multiple = r;               // summing the CAP instead of the realised
   t.outcome    = o;               // duration is the bug being guarded against
   t.risk       = 1.0;
   return t;
}

// active_bars is maintained by VirtualBook as trades march; here we compute
// it directly from the trades' bar coverage, which is the same definition.
static int CoveredBars(const std::vector<VirtualTrade> &ts)
{
   std::set<int> bars;
   for(const auto &t : ts)
      for(int b = 0; b < t.bars_held; ++b)
         bars.insert(t.entry_bar + b);
   return (int)bars.size();
}

static CellStats BuildCell(const std::vector<VirtualTrade> &ts)
{
   CellStats c; c.Clear();
   for(const auto &t : ts) c.Record(t);
   c.active_bars = CoveredBars(ts);
   return c;
}

static void TestOverlapRatio()
{
   Section("M6.1 overlap ratio");

   // (a) Non-overlapping: 10 trades of 5 bars, spaced 10 bars apart.
   {
      std::vector<VirtualTrade> ts;
      for(int i = 0; i < 10; ++i) ts.push_back(MakeTrade(i * 10, 5, 0.5, OUT_CONFIRMED));
      CellStats c = BuildCell(ts);
      CheckNear(c.OverlapRatio(), 1.0, 1e-9, "non-overlapping cell has ratio 1");
      CheckNear(c.NEff(), (double)c.samples, 1e-9, "non-overlapping n_eff == samples");
   }

   // (b) N simultaneous trades of equal length -> ratio == N.
   {
      const int N = 4, B = 12;
      std::vector<VirtualTrade> ts;
      for(int i = 0; i < N; ++i) ts.push_back(MakeTrade(100, B, -1.0, OUT_FAILED));
      CellStats c = BuildCell(ts);
      CheckNear(c.OverlapRatio(), (double)N, 1e-9, "N simultaneous trades give ratio N");
      CheckNear(c.NEff(), (double)N / (double)N, 1e-9, "n_eff collapses to 1 when all overlap");
   }

   // (c) The regression that matters: a cluster followed by a long idle
   //     stretch must report the SAME ratio as the cluster alone. A span
   //     denominator would dilute it toward 1 — reporting near-independence
   //     for the most clustered cell in the grid.
   {
      std::vector<VirtualTrade> cluster;
      for(int i = 0; i < 6; ++i) cluster.push_back(MakeTrade(50 + i, 20, 0.2, OUT_CONFIRMED));
      CellStats c1 = BuildCell(cluster);

      std::vector<VirtualTrade> plus_idle = cluster;
      plus_idle.push_back(MakeTrade(5000, 20, 0.2, OUT_CONFIRMED));   // far later, alone
      CellStats c2 = BuildCell(plus_idle);

      CheckNear(c1.OverlapRatio(), 4.8, 1e-9, "clustered cell reports true concurrency");

      // Adding one non-overlapping trade genuinely lowers mean concurrency
      // (4.8 -> 3.11); that is correct. What must NOT happen is a collapse
      // toward 1.0, which is what a span denominator produces: the same
      // trades over a 4970-bar span give 0.028, clamped to 1.0, reporting
      // near-total independence for the most clustered cell in the grid.
      CheckNear(c2.OverlapRatio(), 140.0 / 45.0, 1e-9, "idle gap dilutes only by its own bars");
      Check(c2.OverlapRatio() > 3.0, "idle gap does not collapse the ratio toward 1");

      const int    span      = (5000 + 20) - 50;
      const double span_based = 140.0 / (double)span;
      Check(span_based < 0.05, "the REJECTED span denominator would have collapsed");
   }

   // (d) Numerator uses realised duration, not the cap. hold_bars is 60 on
   //     every synthetic trade above; if the sum used it, a 10-trade cell of
   //     5-bar trades would report ratio 12 instead of 1.
   {
      std::vector<VirtualTrade> ts;
      for(int i = 0; i < 10; ++i) ts.push_back(MakeTrade(i * 10, 5, 0.5, OUT_CONFIRMED));
      CellStats c = BuildCell(ts);
      Check(c.sum_bars_held == 50, "numerator sums bars_held (50), not hold_bars (600)");
   }
}

//--------------------------------------------------------------------
// Ranking key. The inversion this guards: wilson_lb * expectancy_r ranks
// a cell losing 0.75R per trade ABOVE one losing 0.25R.
//--------------------------------------------------------------------
static CellStats LosingCell(int n, double hit_rate, double reward)
{
   CellStats c; c.Clear();
   const int wins = (int)MathRound(n * hit_rate);
   for(int i = 0; i < n; ++i)
   {
      VirtualTrade t = MakeTrade(i * 100, 5,
                                 (i < wins) ? reward : -1.0,
                                 (i < wins) ? OUT_CONFIRMED : OUT_FAILED);
      c.Record(t);
   }
   c.active_bars = n * 5;             // non-overlapping
   return c;
}

static void TestRankingKey()
{
   Section("ranking key");

   CellStats a = LosingCell(100, 0.30, 1.5);   // expectancy -0.25R
   CellStats b = LosingCell(100, 0.10, 1.5);   // expectancy -0.75R

   CheckNear(a.Expectancy(), -0.25, 0.02, "cell A expectancy ~ -0.25R");
   CheckNear(b.Expectancy(), -0.75, 0.02, "cell B expectancy ~ -0.75R");

   // The broken key, computed explicitly to document the inversion.
   const double broken_a = a.WilsonLower() * a.Expectancy();
   const double broken_b = b.WilsonLower() * b.Expectancy();
   Check(broken_b > broken_a, "the REJECTED key does invert (B outranks A)");

   // The shipped key must order them correctly.
   const double sa = a.Score(30, 20);
   const double sb = b.Score(30, 20);
   Check(sa > sb, "shipped Score ranks the better-expectancy cell higher");

   // Monotonicity across a losing sweep — the M6 acceptance criterion.
   double prev = -1e18;
   bool monotone = true;
   for(int pct = 5; pct <= 35; pct += 5)
   {
      CellStats c = LosingCell(200, pct / 100.0, 1.5);
      const double s = c.Score(30, 20);
      if(s <= prev) monotone = false;
      prev = s;
   }
   Check(monotone, "all-losing sweep ranks in strictly increasing expectancy order");

   // Ineligible cells sort to the bottom.
   CellStats thin = LosingCell(4, 0.5, 1.5);
   Check(!thin.Eligible(30, 20), "thin cell is ineligible");
   Check(thin.Score(30, 20) < sb, "ineligible cell sorts below every eligible one");
}

//--------------------------------------------------------------------
// Eligibility must read the ADJUSTED counts, not the raw ones.
//--------------------------------------------------------------------
static void TestEligibility()
{
   Section("eligibility floors");

   // 30 samples, but all mutually overlapping -> n_eff ~ 1.
   std::vector<VirtualTrade> ts;
   for(int i = 0; i < 30; ++i) ts.push_back(MakeTrade(100, 20, 0.5, OUT_CONFIRMED));
   CellStats c = BuildCell(ts);

   Check(c.samples == 30, "raw sample count clears the floor");
   Check(c.NEff() < 2.0,  "n_eff collapses under total overlap");
   Check(!c.Eligible(30, 20), "eligibility rejects on n_eff despite 30 raw samples");

   // Same 30 samples, spread out -> eligible.
   std::vector<VirtualTrade> spread;
   for(int i = 0; i < 30; ++i) spread.push_back(MakeTrade(i * 50, 20, 0.5, OUT_CONFIRMED));
   CellStats d = BuildCell(spread);
   Check(d.Eligible(30, 20), "same count, non-overlapping, is eligible");
}

//--------------------------------------------------------------------
// Wilson bound sanity.
//--------------------------------------------------------------------
static void TestWilson()
{
   Section("wilson bound");

   Check(WilsonLowerBound(0.5, 0.0, RL_Z_95_ONE_SIDED) == 0.0, "n=0 yields 0, not NaN");
   Check(WilsonLowerBound(0.0, 50.0, RL_Z_95_ONE_SIDED) >= 0.0, "p=0 stays in range");
   Check(WilsonLowerBound(1.0, 50.0, RL_Z_95_ONE_SIDED) <= 1.0, "p=1 stays in range");
   Check(WilsonLowerBound(0.5, 1000.0, RL_Z_95_ONE_SIDED) >
         WilsonLowerBound(0.5, 10.0,   RL_Z_95_ONE_SIDED),
         "bound tightens toward p as n grows");
   Check(WilsonLowerBound(0.5, 100.0, RL_Z_95_ONE_SIDED) < 0.5,
         "lower bound sits below the point estimate");
}

//--------------------------------------------------------------------
// Gap check and hold-window scaling.
//--------------------------------------------------------------------
static void TestTradeConstruction()
{
   Section("gap check and hold window");

   RLConfig cfg; cfg.SetDefaults();

   // Long: stop below, target above.
   Check( PassesGapCheck(100.0,  99.0, 101.5), "normal long entry passes");
   Check(!PassesGapCheck( 98.5,  99.0, 101.5), "long entry gapped through the stop rejects");
   Check(!PassesGapCheck(102.0,  99.0, 101.5), "long entry gapped past the target rejects");
   // Short: stop above, target below.
   Check( PassesGapCheck(100.0, 101.0,  98.5), "normal short entry passes");
   Check(!PassesGapCheck(101.5, 101.0,  98.5), "short entry gapped through the stop rejects");
   Check(!PassesGapCheck( 98.0, 101.0,  98.5), "short entry gapped past the target rejects");
   Check(!PassesGapCheck( 99.0,  99.0, 101.5), "entry exactly at the stop rejects");

   // Hold window: risk = 1 ATR at RR 1.5 reproduces the old fixed default of 20.
   Check(HoldBarsFor(1.0, 1.0, cfg) == 20, "risk=1ATR, RR=1.5 gives 20 bars");
   Check(HoldBarsFor(0.1, 1.0, cfg) == cfg.hold_bars_min, "tight stop clamps to the min");
   Check(HoldBarsFor(2.0, 1.0, cfg) > HoldBarsFor(1.0, 1.0, cfg),
         "hold window grows with target distance");

   // At the widest risk the bounds permit (3.0 ATR) the window is 59 bars —
   // just under the 60 cap. The upper clamp therefore never binds under the
   // default configuration; it only engages if max_risk_atr or
   // hold_bars_per_atr is raised. Pinned so a defaults change is visible.
   Check(HoldBarsFor(cfg.max_risk_atr, 1.0, cfg) == 59, "widest permitted risk gives 59 bars");
   Check(HoldBarsFor(cfg.max_risk_atr, 1.0, cfg) < cfg.hold_bars_max,
         "upper clamp is slack at the default risk ceiling");
   Check(HoldBarsFor(5.0, 1.0, cfg) == cfg.hold_bars_max,
         "upper clamp engages beyond the risk ceiling");

   // Risk bounds.
   Check( PassesRiskBounds(1.0,  1.0, cfg), "1 ATR risk is in bounds");
   Check(!PassesRiskBounds(0.10, 1.0, cfg), "sub-minimum risk rejects");
   Check(!PassesRiskBounds(5.0,  1.0, cfg), "above-maximum risk rejects");

   // Full construction, long.
   {
      Signal s; s.Clear();
      s.dir = DIR_BULL; s.atr = 1.0; s.pattern_extreme = 99.0; s.bar_index = 10;
      VirtualTrade t;
      Check(BuildTrade(s, 100.0, cfg, t) == REJ_NONE, "long trade builds");
      CheckNear(t.stop,   98.75, 1e-9, "stop = extreme - 0.25 ATR");
      CheckNear(t.risk,    1.25, 1e-9, "risk = |entry - stop|");
      CheckNear(t.target, 101.875, 1e-9, "target = entry + 1.5 x risk");
      Check(t.entry_bar == 11, "entry bar is the bar after detection");
   }

   // Full construction, short — mirrored.
   {
      Signal s; s.Clear();
      s.dir = DIR_BEAR; s.atr = 1.0; s.pattern_extreme = 101.0; s.bar_index = 10;
      VirtualTrade t;
      Check(BuildTrade(s, 100.0, cfg, t) == REJ_NONE, "short trade builds");
      CheckNear(t.stop,   101.25, 1e-9, "short stop sits above the extreme");
      CheckNear(t.risk,     1.25, 1e-9, "short risk matches");
      CheckNear(t.target, 98.125, 1e-9, "short target sits below entry");
   }

   // A pattern so large the stop breaches the risk ceiling.
   {
      Signal s; s.Clear();
      s.dir = DIR_BULL; s.atr = 1.0; s.pattern_extreme = 90.0;
      VirtualTrade t;
      Check(BuildTrade(s, 100.0, cfg, t) == REJ_RISK_BOUNDS, "oversized pattern rejected on risk");
   }
}

//--------------------------------------------------------------------
// Cost is charged on every outcome, timeouts included.
//--------------------------------------------------------------------
static void TestRMultiple()
{
   Section("r-multiple and cost");

   VirtualTrade t; t.Clear();
   t.dir = DIR_BULL; t.entry = 100.0; t.risk = 1.0; t.exit_price = 101.5;
   CheckNear(RMultiple(t, 0.0), 1.5, 1e-9, "clean win is +1.5R");
   CheckNear(RMultiple(t, 0.1), 1.4, 1e-9, "cost reduces a win");

   t.exit_price = 99.0;
   CheckNear(RMultiple(t, 0.0), -1.0, 1e-9, "clean loss is -1.0R");
   CheckNear(RMultiple(t, 0.1), -1.1, 1e-9, "cost deepens a loss");

   t.dir = DIR_BEAR; t.exit_price = 98.5;
   CheckNear(RMultiple(t, 0.0), 1.5, 1e-9, "short win is +1.5R");

   t.exit_price = 100.3;                       // timeout, small adverse drift
   CheckNear(RMultiple(t, 0.1), -0.4, 1e-9, "cost is charged on timeouts too");
}

//--------------------------------------------------------------------
static void TestConfigValidation()
{
   Section("config validation");

   RLConfig c; c.SetDefaults();
   Check(ValidateConfig(c) == CFG_OK, "defaults validate");
   Check(c.warmup_bars >= c.RequiredWarmup(), "default warmup covers the indicators");

   RLConfig bad = c; bad.warmup_bars = 10;
   Check(ValidateConfig(bad) == CFG_BAD_WARMUP, "short warmup is rejected");

   bad = c; bad.max_risk_atr = 0.1;
   Check(ValidateConfig(bad) == CFG_BAD_RISK_BOUNDS, "inverted risk bounds rejected");

   bad = c; bad.atr_regime_high = 0.5;
   Check(ValidateConfig(bad) == CFG_BAD_REGIME_BAND, "inverted regime band rejected");

   bad = c; bad.live_cell_id = CELL_COUNT;
   Check(ValidateConfig(bad) == CFG_BAD_LIVE_CELL, "out-of-range live cell rejected");

   bad = c; bad.live_cell_id = CELL_COUNT - 1;
   Check(ValidateConfig(bad) == CFG_OK, "last valid cell id accepted");

   bad = c; bad.min_resolved = 999;
   Check(ValidateConfig(bad) == CFG_BAD_ELIGIBILITY, "min_resolved above min_samples rejected");
}

//--------------------------------------------------------------------
int main()
{
   std::printf("ReversalLab core math\n");

   TestCellAlgebra();
   TestAdmission();
   TestOverlapRatio();
   TestRankingKey();
   TestEligibility();
   TestWilson();
   TestTradeConstruction();
   TestRMultiple();
   TestConfigValidation();

   std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
   return g_failures == 0 ? 0 : 1;
}
