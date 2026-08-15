# PRD — Reversal Lab

**A research harness for scoring candlestick reversal patterns against momentum-indicator confirmation.**

| Field | Value |
| --- | --- |
| Status | Draft v1 |
| Owner | gksoglo |
| Platform | MQL5 / MetaTrader 5 Strategy Tester |
| Purpose | Research only — not a production trading system |
| Date | 2026-08-15 |

---

## 1. Problem statement

Candlestick reversal patterns (engulfing, hammer, morning star, …) fire constantly and most of them fail. The common folklore is that a pattern becomes tradeable only when a momentum indicator agrees with it — but "which pattern, confirmed by which indicator or combination of indicators, actually produces a trend reversal" is an empirical question that is almost never answered with numbers.

Reversal Lab answers it. It detects every reversal pattern on a symbol, evaluates every combination of confirming indicators against that same signal stream, simulates a trade for each combination, and tallies which pattern × indicator-set cells produce reversals with positive expectancy.

**Core hypothesis under test:** a candlestick reversal pattern predicts a change in trend direction, and its predictive power is materially improved by momentum confirmation and ATR-based context filtering.

---

## 2. Goals / non-goals

### Goals

1. Detect a fixed library of reversal candlestick patterns on completed bars, with no repainting.
2. Compute five indicators — ATR, RSI, MACD, Stochastic, CCI — and reduce each to a directional **vote** at the moment a pattern fires.
3. Evaluate **every subset** of the four momentum indicators (16 subsets, including the empty set as a control) against every pattern, with the ATR context filter toggled on and off — a grid of *pattern × indicator-subset × ATR-filter* **cells**.
4. Simulate an independent virtual trade per cell from the same signal stream, so all cells are scored on identical data in a single pass.
5. Classify each simulated trade as *reversal confirmed*, *failed*, or *timeout*, using an explicit, ATR-normalized definition of success.
6. Log every signal and every trade outcome to CSV, then emit a ranked tally of the best pattern/indicator combinations.
7. Optionally place one real (tester) trade per bar following the currently top-ranked cell, to sanity-check that the virtual book matches reality.

### Non-goals

Explicitly out of scope for v1 — this is a test rig, and the user has accepted the absence of production safeguards:

- No account risk management beyond a fixed ATR-derived stop and fixed lot size.
- No news/session/spread filters, no slippage or commission modelling beyond a single flat cost input.
- No live-account deployment, no order-failure retry logic, no equity-protection halt.
- No machine learning, no parameter optimisation loop. The grid is enumerated, not searched.
- No multi-symbol portfolio logic. One symbol, one timeframe, one run.

> **Warning to future readers:** results from this harness are in-sample statistics on a single instrument. They are a hypothesis generator, not a trading edge. Nothing here is safe to trade without walk-forward validation.

---

## 3. Definitions

These are the load-bearing definitions. Everything downstream depends on them being fixed and unambiguous.

**Signal.** A pattern detection on bar `t`, evaluated only after bar `t` has closed. Direction is `BULLISH` (predicts reversal upward) or `BEARISH` (predicts reversal downward).

**Vote.** Each momentum indicator maps to `+1` (supports a bullish reversal), `-1` (supports a bearish reversal), or `0` (neutral / no opinion) at bar `t`. An indicator **confirms** a signal when `sign(vote) == sign(signal direction)`.

**Cell.** One testable strategy configuration: `(pattern, indicator_subset, atr_filter_on)`. A signal is admitted into a cell only if the cell's confirmation rule is satisfied.

**Confirmation rule.** Global input, one of:
- `ALL` (default) — every indicator in the subset must confirm.
- `MAJORITY` — more than half confirm, ties rejected.
The empty subset always admits (this is the pattern-alone control arm).

**Successful reversal.** The outcome measure. A trade is a success when, within `HoldBars` bars of entry, price reaches the take-profit before touching the stop:

```
entry  = open of bar t+1
risk   = StopATR × ATR(t)            (default StopATR = 1.0)
stop   = entry ∓ risk
target = entry ± (RewardRatio × risk) (default RewardRatio = 1.5)
```

- **CONFIRMED** — target hit first. Score `+RewardRatio` R.
- **FAILED** — stop hit first. Score `−1.0` R.
- **TIMEOUT** — neither within `HoldBars` (default 20). Score = `(exit − entry) / risk`, signed by direction.

If both stop and target fall inside the same bar's range, resolve pessimistically (stop first). This is a deliberate bias toward under-stating results.

**Sample.** One admitted signal in one cell. A cell needs `MinSamples` (default 30) before it is eligible for ranking.

---

## 4. Pattern library

Each detector runs on the closed bar `t` with lookback ≤ 3 bars and returns `NONE`, `BULLISH`, or `BEARISH`. All body/wick thresholds are expressed as fractions of `ATR(t)` so the library is instrument-agnostic.

| ID | Pattern | Dir | Bars | Core condition (informal) |
| --- | --- | --- | --- | --- |
| `PAT_ENGULF_BULL` | Bullish engulfing | ↑ | 2 | Down candle, then up candle whose body covers it |
| `PAT_ENGULF_BEAR` | Bearish engulfing | ↓ | 2 | Up candle, then down candle whose body covers it |
| `PAT_HAMMER` | Hammer | ↑ | 1 | Small body at top, lower wick ≥ 2× body |
| `PAT_SHOOTSTAR` | Shooting star | ↓ | 1 | Small body at bottom, upper wick ≥ 2× body |
| `PAT_MORNINGSTAR` | Morning star | ↑ | 3 | Down, small-body gap, up candle closing past midpoint |
| `PAT_EVENINGSTAR` | Evening star | ↓ | 3 | Up, small-body gap, down candle closing past midpoint |
| `PAT_PIERCING` | Piercing line | ↑ | 2 | Down candle, up candle closing above its midpoint |
| `PAT_DARKCLOUD` | Dark cloud cover | ↓ | 2 | Up candle, down candle closing below its midpoint |
| `PAT_HARAMI_BULL` | Bullish harami | ↑ | 2 | Large down body containing next small up body |
| `PAT_HARAMI_BEAR` | Bearish harami | ↓ | 2 | Large up body containing next small down body |
| `PAT_TWEEZER_BOT` | Tweezer bottom | ↑ | 2 | Two matching lows within `TweezerTolATR` |
| `PAT_TWEEZER_TOP` | Tweezer top | ↓ | 2 | Two matching highs within `TweezerTolATR` |

**Prior-trend precondition.** A reversal pattern is only meaningful against a prior move. Every detector requires the preceding `TrendLookback` bars (default 5) to have net-moved ≥ `MinPriorMoveATR × ATR` (default 1.0) *against* the pattern's direction. Signals failing this are discarded before cell evaluation and counted separately as `rejected_no_trend`.

`PatternCount = 12`.

---

## 5. Indicator layer

Five indicators. ATR is structural (sizing + context filter, never a directional vote); the other four are the momentum voters.

| Slot | Indicator | Default params | Vote rule |
| --- | --- | --- | --- |
| — | **ATR** | 14 | No vote. Supplies risk unit + context filter. |
| `IND_RSI` | **RSI** | 14 | `+1` if RSI ≤ 30 or crossed up through 30 within 2 bars; `−1` if RSI ≥ 70 or crossed down through 70; else `0`. |
| `IND_MACD` | **MACD** | 12/26/9 | `+1` if histogram turned up from a negative trough within 2 bars, or main crossed above signal; `−1` mirrored; else `0`. |
| `IND_STOCH` | **Stochastic** | 14/3/3 | `+1` if `%K ≤ 20` and `%K` crossed above `%D` within 2 bars; `−1` if `%K ≥ 80` and crossed below; else `0`. |
| `IND_CCI` | **CCI** | 20 | `+1` if CCI ≤ −100 or crossed up through −100 within 2 bars; `−1` if CCI ≥ +100 or crossed down; else `0`. |

**ATR context filter** (the toggled dimension). When on, a signal is admitted only if both hold:
- Pattern range ≥ `MinPatternATR × ATR(t)` (default 0.8) — the pattern is not noise-sized.
- `ATR(t)` within `[AtrRegimeLow, AtrRegimeHigh]` × `SMA(ATR, 50)` (defaults 0.7 / 1.8) — the market is neither dead nor in a volatility spike.

`MomentumIndicatorCount = 4` → `SubsetCount = 2^4 = 16` (bitmask `0b0000`…`0b1111`, `0` = control).

**Grid size:** `12 patterns × 16 subsets × 2 ATR states = 384 cells`.

Swap-in candidates for v2, behind the same `IIndicatorVoter` interface: Williams %R, ROC/Momentum, ADX (as a trend-strength gate rather than a voter).

---

## 6. Architecture

### 6.1 Evaluation model

The critical design decision: **one signal stream, many virtual books.** The EA does not run 384 backtests. On each closed bar it detects patterns once, computes votes once, then fans that single event out to all 384 cells. Each cell owns an independent virtual position ledger that is marched forward bar-by-bar against the same price series.

This gives an exact apples-to-apples comparison across cells in one tester pass, and keeps runtime at roughly *O(bars × open virtual positions)* rather than *O(bars × cells)*.

```
                       ┌──────────────────────┐
   new closed bar ───► │  PatternScanner      │──► Signal{pattern, dir, bar}
                       └──────────────────────┘
                       ┌──────────────────────┐
                   ───►│  IndicatorHub        │──► VoteVector{rsi, macd, stoch, cci}
                       └──────────────────────┘        + AtrContext{atr, passes_filter}
                                  │
                                  ▼
                       ┌──────────────────────┐
                       │  ComboEngine         │  for each of 384 cells:
                       │  (admission rules)   │  admitted? → open virtual trade
                       └──────────────────────┘
                                  │
                                  ▼
                       ┌──────────────────────┐
                       │  VirtualBook         │  march open trades against OHLC,
                       │  (per-cell ledger)   │  resolve CONFIRMED/FAILED/TIMEOUT
                       └──────────────────────┘
                          │                 │
                          ▼                 ▼
                    CsvLogger           TallyEngine ──► ranked report at OnDeinit
                  (signal + trade         (per-cell
                   row per event)          running stats)
                                  │
                                  ▼  (optional, off by default)
                       ┌──────────────────────┐
                       │  LiveExecutor        │  place ONE real tester order
                       │                      │  following the champion cell
                       └──────────────────────┘
```

### 6.2 File layout

```
MQL5/
├── Experts/ReversalLab/
│   └── ReversalLab.mq5              // EA entry: OnInit/OnTick/OnDeinit, inputs
└── Include/ReversalLab/
    ├── Config.mqh                   // input mirror struct, defaults, validation
    ├── Types.mqh                    // enums + core structs (below)
    ├── Patterns/
    │   ├── PatternScanner.mqh       // orchestrates detectors, prior-trend gate
    │   └── Detectors.mqh            // the 12 detector functions
    ├── Indicators/
    │   ├── IndicatorHub.mqh         // handle lifecycle, buffer reads, caching
    │   └── Voters.mqh               // vote rules per indicator
    ├── Signal/
    │   └── ComboEngine.mqh          // subset enumeration + admission logic
    ├── Trade/
    │   ├── VirtualBook.mqh          // per-cell simulated position ledger
    │   └── LiveExecutor.mqh         // optional real order placement
    ├── Stats/
    │   ├── Tally.mqh                // per-cell running aggregates
    │   └── Stats.mqh                // expectancy, Wilson bound, profit factor
    └── Log/
        └── CsvLogger.mqh            // buffered CSV writers
```

### 6.3 Core types

```cpp
enum PatternId  { PAT_NONE=0, PAT_ENGULF_BULL, /* … 12 total */ };
enum Direction  { DIR_NONE=0, DIR_BULL=1, DIR_BEAR=-1 };
enum Outcome    { OUT_OPEN=0, OUT_CONFIRMED, OUT_FAILED, OUT_TIMEOUT };
enum ConfirmMode{ CONFIRM_ALL=0, CONFIRM_MAJORITY };

struct Signal {
   datetime  bar_time;
   PatternId pattern;
   Direction dir;
   double    atr;              // ATR(t), the risk unit
   double    pattern_range;    // high-low of the pattern, raw price
   bool      atr_filter_pass;  // context filter verdict
};

struct VoteVector {
   int  vote[4];               // indexed by IND_RSI…IND_CCI, each -1/0/+1
   int  ConfirmCount(Direction d, int subset_mask) const;
   bool Admits(Direction d, int subset_mask, ConfirmMode mode) const;
};

struct VirtualTrade {
   int       cell_id;
   datetime  entry_time;
   double    entry, stop, target, risk;
   Direction dir;
   int       bars_held;
   double    mfe_atr, mae_atr;  // excursions, in ATR units
   Outcome   outcome;
   double    r_multiple;
};

struct CellStats {                 // one per cell, 384 of these
   int    cell_id;                 // = pattern*32 + subset*2 + atr_flag
   int    samples, confirmed, failed, timeout;
   double sum_r, sum_r_sq;         // for expectancy + stdev
   double gross_win, gross_loss;   // for profit factor
   double sum_mfe_atr, sum_mae_atr;
   double HitRate()      const;
   double Expectancy()   const;    // mean R per trade
   double WilsonLower()  const;    // 95% lower bound on hit rate
   double ProfitFactor() const;
   double Score()        const;    // ranking key, see §8
};
```

### 6.4 Key function signatures

```cpp
// PatternScanner.mqh
bool  ScanBar(const int shift, const double atr, Signal &out[]);
bool  HasPriorTrend(const int shift, const Direction reversal_dir, const double atr);

// IndicatorHub.mqh
bool  InitHandles(const string symbol, const ENUM_TIMEFRAMES tf);
bool  ReadBar(const int shift, VoteVector &votes, double &atr, bool &atr_ctx_ok);

// ComboEngine.mqh
int   CellId(const PatternId p, const int subset_mask, const bool atr_on);
void  DispatchSignal(const Signal &sig, const VoteVector &votes);   // fan-out to 384 cells

// VirtualBook.mqh
void  OpenVirtual(const int cell_id, const Signal &sig);
void  MarchOpenTrades(const MqlRates &bar);   // resolve stops/targets/timeouts
void  CloseAllAtEnd();                        // flush at OnDeinit

// Tally.mqh
void  Record(const VirtualTrade &t);
void  WriteRanking(const string path);
```

### 6.5 Non-repainting discipline

Non-negotiable, since every result depends on it:

- All detection and voting run on `shift ≥ 1` (closed bars only), gated by a new-bar check in `OnTick`.
- Indicator buffers are read with `CopyBuffer(handle, buf, shift, n, dest)` — never index 0.
- Entry is the **open of bar t+1**, never the close of the pattern bar.
- Intrabar stop/target resolution uses only that bar's OHLC, with the pessimistic tie-break from §3.

---

## 7. Data logging

Two CSVs in `MQL5/Files/ReversalLab/`, written buffered and flushed every `FlushEvery` rows (default 500).

**`signals_<symbol>_<tf>_<runid>.csv`** — one row per detected signal, before cell admission:

```
bar_time, symbol, tf, pattern, dir, atr, pattern_range_atr,
rsi, macd_hist, stoch_k, cci,
vote_rsi, vote_macd, vote_stoch, vote_cci,
atr_filter_pass, prior_trend_pass, admitted_cell_count
```

**`trades_<symbol>_<tf>_<runid>.csv`** — one row per resolved virtual trade:

```
cell_id, pattern, subset_mask, subset_label, atr_filter,
entry_time, exit_time, dir, entry, stop, target, exit_price,
bars_held, outcome, r_multiple, mfe_atr, mae_atr
```

`subset_label` is human-readable (`"RSI+MACD"`, `"NONE"`, `"RSI+MACD+STOCH+CCI"`) so the output is analysable without decoding bitmasks.

---

## 8. Reporting and ranking

At `OnDeinit`, `TallyEngine` writes **`ranking_<symbol>_<tf>_<runid>.csv`** and prints the top 20 to the tester journal.

Per-cell metrics:

| Metric | Definition |
| --- | --- |
| `samples` | Admitted signals |
| `hit_rate` | `confirmed / (confirmed + failed)` |
| `wilson_lb` | 95% Wilson lower bound on `hit_rate` |
| `expectancy_r` | Mean R-multiple per trade |
| `stdev_r` | Std. dev. of R |
| `profit_factor` | `gross_win / gross_loss` |
| `avg_mfe_atr` / `avg_mae_atr` | Mean favourable / adverse excursion |
| `lift_vs_control` | `expectancy_r` minus the same pattern's empty-subset expectancy |

**Ranking key.** Sorting by raw hit rate rewards small-sample noise, so the primary sort is:

```
Score = WilsonLower(hit_rate, n) × expectancy_r        for cells with n ≥ MinSamples
Score = -inf                                           for cells below MinSamples
```

`lift_vs_control` is the answer to the actual research question — it isolates what the indicator combination contributed over the bare pattern. A cell with high expectancy but near-zero lift means the pattern was doing the work and the indicators were decoration.

**Required report sections:**
1. Top 20 cells by `Score`.
2. Per-pattern summary: best subset, its lift, control expectancy.
3. Per-indicator marginal contribution: mean lift across all subsets containing that indicator vs. all subsets without it.
4. ATR-filter comparison: aggregate expectancy with filter on vs. off.
5. Rejected-signal counts by reason (`no_trend`, `atr_context`, `no_confirmation`).

---

## 9. Inputs

```cpp
// --- Universe
input ENUM_TIMEFRAMES  InpTimeframe        = PERIOD_H1;
input datetime         InpStartDate        = D'2020.01.01';

// --- Trade model
input double           InpStopATR          = 1.0;
input double           InpRewardRatio      = 1.5;
input int              InpHoldBars         = 20;
input double           InpCostPoints       = 0.0;   // flat spread+commission, in points

// --- Pattern gates
input int              InpTrendLookback    = 5;
input double           InpMinPriorMoveATR  = 1.0;
input double           InpMinPatternATR    = 0.8;
input double           InpTweezerTolATR    = 0.10;

// --- Indicators
input int              InpAtrPeriod        = 14;
input int              InpRsiPeriod        = 14;
input int              InpMacdFast=12, InpMacdSlow=26, InpMacdSignal=9;
input int              InpStochK=14, InpStochD=3, InpStochSlow=3;
input int              InpCciPeriod        = 20;
input double           InpAtrRegimeLow     = 0.7;
input double           InpAtrRegimeHigh    = 1.8;

// --- Engine
input ConfirmMode      InpConfirmMode      = CONFIRM_ALL;
input int              InpMinSamples       = 30;
input bool             InpPlaceLiveTrades  = false;  // follow champion cell in tester
input double           InpLots             = 0.10;
input string           InpRunId            = "run001";
```

---

## 10. Milestones

| # | Deliverable | Acceptance |
| --- | --- | --- |
| M1 | Skeleton compiles: types, config, empty modules, EA lifecycle | Zero compile errors/warnings; runs a tester pass doing nothing |
| M2 | `IndicatorHub` + `Voters` | Vote vector printed per bar matches manual chart reading on 20 spot-checked bars |
| M3 | `PatternScanner` + 12 detectors | Detections match visual chart inspection on a 200-bar sample; prior-trend gate rejects as expected |
| M4 | `VirtualBook` single-cell | One cell's simulated P&L reconciles with a hand-computed ledger over 50 trades |
| M5 | `ComboEngine` full 384-cell fan-out | Control cell (`subset=0, atr=off`) sample count equals raw pattern count |
| M6 | `CsvLogger` + `Tally` + ranking | Report generated; `lift_vs_control` computed; ranking stable across two identical runs |
| M7 | `LiveExecutor` (optional arm) | Real tester trades match the champion cell's virtual trades 1:1 |

---

## 11. Risks and known limitations

- **In-sample overfitting.** 384 cells searched over one dataset will produce a top performer by chance alone. Mitigation: `MinSamples` floor, Wilson lower bound, and `lift_vs_control` as the honest metric. Real mitigation is out-of-sample validation, which v1 does not do.
- **Multiple-comparisons problem.** With 384 cells at α=0.05, ~19 cells look "significant" purely by luck. Treat the ranking as a shortlist to re-test, never as a result.
- **Pattern detection is subjective.** Threshold choices (body/wick ratios) materially change detection counts. Thresholds are ATR-normalized inputs so their sensitivity can be measured.
- **Correlated voters.** RSI, Stochastic, and CCI are all oscillators and will frequently agree; a large subset is not four independent opinions. The per-indicator marginal report in §8 partially exposes this.
- **Single symbol/timeframe.** No claim of generality until run across several.
- **No safety measures by design.** Per the brief, this rig has no equity guard, no error recovery, no live-trading protections. It must not be pointed at a funded account.

---

## 12. Open questions

1. Timeframe of record for the first run — H1 assumed, but M15 gives more samples and D1 gives cleaner reversals.
2. Should `ConfirmMode` become a 5th grid dimension (768 cells) rather than a global input?
3. Should divergence-based votes (price/oscillator divergence) be added as separate voters, or as a mode of the existing ones?
4. Is a fixed `RewardRatio` target the right success definition, or should success be "MFE ≥ 1 ATR before MAE ≥ 1 ATR" independent of an exit rule?

---

*Appendix: if the eventual research target is broader than MT5 (multi-symbol, walk-forward, notebook analysis), the same architecture ports directly to Python — `PatternScanner`/`IndicatorHub`/`ComboEngine`/`VirtualBook` become vectorised passes over a DataFrame, and the CSV schemas in §7 stay identical.*
