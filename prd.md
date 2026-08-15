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
7. Optionally mirror **one fixed, user-nominated cell** into real tester orders, to prove the virtual book matches the tester's own accounting.

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

**Successful reversal.** The outcome measure. A trade is a success when, within `HoldBars` bars of entry, price reaches the take-profit before touching the stop.

The stop is anchored to the **pattern's own extreme**, not to a fixed distance from entry. A candlestick reversal is invalidated when price violates the low (bullish) or high (bearish) that defined it, and a fixed 1-ATR stop would sit *inside* the range of any pattern larger than 1 ATR — guaranteeing that an ordinary retest closes the trade. Since the ATR context filter selects *for* large patterns (§5), a fixed stop would systematically handicap exactly the trades that filter admits, confounding the on/off comparison in §8.

```
pattern_extreme = lowest low  of the pattern's bars   (bullish)
                = highest high of the pattern's bars  (bearish)

entry  = open of bar t+1
stop   = pattern_extreme ∓ (StopBufferATR × ATR(t))   (default 0.25)
risk   = |entry − stop|                                (the R unit, in price)
target = entry ± (RewardRatio × risk)                  (default 1.5)
```

**Risk sanity bounds.** Because `risk` is now data-derived it can degenerate, and it is a denominator. A signal is rejected outright unless `MinRiskATR × ATR(t) ≤ risk ≤ MaxRiskATR × ATR(t)` (defaults 0.25 / 3.0), counted as `rejected_risk_bounds`. This prevents both divide-by-near-zero and absurdly wide stops from a single outsized pattern bar.

**Cost.** `InpCostPoints` (spread + commission, in points) is charged once per trade, on **every** outcome including timeouts:

```
cost_price = InpCostPoints × _Point
r_multiple = (dir × (exit_price − entry) − cost_price) / risk       where dir = +1 bull, −1 bear
```

- **CONFIRMED** — target hit first. `exit_price = target`, so `r ≈ +RewardRatio` less cost.
- **FAILED** — stop hit first. `exit_price = stop`, so `r ≈ −1.0` less cost.
- **TIMEOUT** — neither within `HoldBars` (default 20). `exit_price = close of the final bar held`.

If both stop and target fall inside the same bar's range, resolve pessimistically (stop first). This is a deliberate bias toward under-stating results.

**Concurrency.** By default a cell holds **at most one open virtual trade**. A signal arriving while that cell is occupied — same direction or opposite — is dropped and counted as `rejected_cell_busy`. Set `InpAllowConcurrent = true` to stack instead, which raises sample counts but makes outcomes within a cell strongly correlated (overlapping trades share bars), inflating apparent significance. The default is off because the correlated case violates the independence the ranking statistics assume.

**End of data.** Virtual trades still open when the run ends are resolved as TIMEOUT at the final bar's close, flagged `truncated = true` in the trade log, and **excluded** from `CellStats` — they had less than `HoldBars` to resolve, so counting them biases the tail of the sample.

**Sample.** One admitted signal in one cell. Two counts are tracked and must not be conflated:

- `samples` — all admitted signals that produced a resolved trade. Denominator for `expectancy_r`.
- `n_resolved` = `confirmed + failed` — trades that hit stop or target. Denominator for `hit_rate` and for the Wilson bound.

A cell is eligible for ranking only when `samples ≥ MinSamples` (default 30) **and** `n_resolved ≥ MinResolved` (default 20). The second gate exists because a cell can accumulate 30 samples of which 28 are timeouts, leaving a "95% confidence bound" computed on n=2.

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

**Prior-trend precondition.** A reversal pattern is only meaningful against a prior move. Every detector requires the preceding `TrendLookback` bars (default 5) to have net-moved ≥ `MinPriorMoveATR × ATR` (default 1.0) *against* the pattern's direction — down for a bullish pattern, up for a bearish one. Signals failing this are discarded before cell evaluation and counted as `rejected_no_trend`.

**The lookback window ends at the bar before the pattern's *first* bar, not before bar `t`.** For a 3-bar morning star ending at `t`, the window is `t−8 … t−3`, never `t−5 … t−1` — the latter would place two of the pattern's own bars inside the trend measurement, partly measuring the pattern against itself. `HasPriorTrend()` therefore takes the pattern's bar count, not just its end shift.

`PatternCount = 12`. Note that patterns are not mutually exclusive — a hammer, a bullish engulfing and a tweezer bottom can all fire on the same bar, and bullish and bearish patterns can both fire. Each is dispatched independently to its own cells; only `LiveExecutor` (§6) needs a tie-break.

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

**Both conditions belong exclusively to this toggled filter.** `MinPatternATR` is *not* a pattern-detector gate: with `atr_filter = off` the cell sees noise-sized patterns too. That is the entire point of the off-arm — it is a true no-ATR-context control, and mixing the size test into the detector would leave the two arms differing only by the regime band. The detectors' own body/wick ratios remain ATR-normalized (§4); that is shape, not size.

**Warmup.** No signal is evaluated until `WarmupBars` (default 100) closed bars are available. The binding constraint is the regime band, which needs `SMA(ATR,50)` over `ATR(14)` ≈ 64 bars; MACD needs 26+9. Without this the first ~70 bars produce votes computed from partially-filled buffers and tally them as real. `OnInit` validates that `WarmupBars` exceeds the requirement implied by the configured periods and fails loudly if not.

`MomentumIndicatorCount = 4` → `SubsetCount = 2^4 = 16` (bitmask `0b0000`…`0b1111`, `0` = control).

### 5.1 The 16 subsets

Bit assignment: `bit0 = RSI`, `bit1 = MACD`, `bit2 = STOCH`, `bit3 = CCI`. The `subset_label` column is what `CsvLogger` writes, so output is readable without decoding masks.

| Mask | Bits | `subset_label` | Size |
| --- | --- | --- | --- |
| 0 | `0000` | `NONE` (control) | 0 |
| 1 | `0001` | `RSI` | 1 |
| 2 | `0010` | `MACD` | 1 |
| 3 | `0011` | `RSI+MACD` | 2 |
| 4 | `0100` | `STOCH` | 1 |
| 5 | `0101` | `RSI+STOCH` | 2 |
| 6 | `0110` | `MACD+STOCH` | 2 |
| 7 | `0111` | `RSI+MACD+STOCH` | 3 |
| 8 | `1000` | `CCI` | 1 |
| 9 | `1001` | `RSI+CCI` | 2 |
| 10 | `1010` | `MACD+CCI` | 2 |
| 11 | `1011` | `RSI+MACD+CCI` | 3 |
| 12 | `1100` | `STOCH+CCI` | 2 |
| 13 | `1101` | `RSI+STOCH+CCI` | 3 |
| 14 | `1110` | `MACD+STOCH+CCI` | 3 |
| 15 | `1111` | `RSI+MACD+STOCH+CCI` | 4 |

Composition: 1 empty + 4 singles + 6 pairs + 4 triples + 1 quad.

**Mask 0 is the control arm** — it admits every signal passing the pattern gate, with no momentum confirmation. It is the baseline `lift_vs_control` (§8) is measured against.

**Note on `ConfirmMode`:** majority means *more than half*, so a single indicator needs 1 of 1 and a pair needs 2 of 2 — identical to `CONFIRM_ALL`. The two modes only diverge on the four triples (2 of 3) and the quad (3 of 4), i.e. 5 of 16 subsets. Doubling the whole grid to gain 5 distinct configurations is poor value; see open question 2.

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
                       │  LiveExecutor        │  mirror ONE fixed cell
                       │                      │  (InpLiveCellId) into real orders
                       └──────────────────────┘
```

### 6.1.1 Why the live arm follows a fixed cell, not the leader

An earlier draft had `LiveExecutor` follow "the currently top-ranked cell." That is unimplementable and unsound in two separate ways:

- **It cannot reconcile.** The leader changes as statistics accumulate. A cell that becomes champion at bar 5,000 already has 40 virtual trades behind it that the real book never took, so a 1:1 comparison against the virtual ledger is impossible by construction.
- **It is look-ahead if resolved the other way.** Selecting the champion from the *final* ranking and replaying it uses the run's own outcome to choose the strategy — the live equity curve would then be a foregone conclusion, not evidence.

The live arm exists solely to validate the simulator, so it mirrors a single cell fixed before the run (`InpLiveCellId`, default −1 = disabled). If two patterns in that cell fire on the same bar, or a bullish and bearish cell both fire, the executor takes the first by `PatternId` order and logs the skipped one — the virtual books are unaffected.

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

// Patterns occupy enum values 1..12 because PAT_NONE owns 0. Every array index
// MUST go through PatternIndex() — indexing on the raw enum overflows by one
// pattern's worth of stride (see CellId below).
#define PATTERN_COUNT 12
int PatternIndex(const PatternId p) { return (int)p - 1; }   // 0..11

struct Signal {
   datetime  bar_time;
   PatternId pattern;
   Direction dir;
   int       bar_count;        // bars spanned, for the prior-trend window offset
   double    atr;              // ATR(t), the normalizer
   double    pattern_range;    // high-low of the pattern, raw price
   double    pattern_extreme;  // low (bull) / high (bear) — the stop anchor
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
   double    r_multiple;        // net of cost, see §3
   bool      truncated;         // still open at end of data -> excluded from stats
};

struct CellStats {                 // one per cell, CELL_COUNT of these
   int    cell_id;
   int    samples;                 // resolved, non-truncated trades   -> expectancy
   int    confirmed, failed, timeout;
   double sum_r, sum_r_sq;         // for expectancy + stdev
   double gross_win, gross_loss;   // gross_loss stored as a POSITIVE magnitude
   double sum_mfe_atr, sum_mae_atr;

   int    NResolved()    const;    // confirmed + failed  -> hit_rate, Wilson
   bool   Eligible()     const;    // samples >= MinSamples && NResolved() >= MinResolved
   double HitRate()      const;    // confirmed / NResolved()      0 if NResolved()==0
   double Expectancy()   const;    // sum_r / samples
   double StdevR()       const;    // from sum_r, sum_r_sq, samples
   double WilsonLower()  const;    // 95% one-sided bound on HitRate() over NResolved()
   double ProfitFactor() const;    // gross_win / gross_loss;  DBL_MAX if gross_loss==0
   double Score()        const;    // ranking key, see §8
};
```

### 6.4 Key function signatures

```cpp
// PatternScanner.mqh
bool  ScanBar(const int shift, const double atr, Signal &out[]);
// window ends before the pattern's FIRST bar: shift + bar_count .. + TrendLookback
bool  HasPriorTrend(const int shift, const int bar_count,
                    const Direction reversal_dir, const double atr);

// IndicatorHub.mqh
bool  InitHandles(const string symbol, const ENUM_TIMEFRAMES tf);
bool  ReadBar(const int shift, VoteVector &votes, double &atr, bool &atr_ctx_ok);

// ComboEngine.mqh
// stride 32 = 16 subsets x 2 atr states; PatternIndex() maps enum 1..12 -> 0..11
#define CELL_COUNT (PATTERN_COUNT * 32)      // 12 * 32 = 384
int   CellId(const PatternId p, const int subset_mask, const bool atr_on)
      { return PatternIndex(p) * 32 + subset_mask * 2 + (atr_on ? 1 : 0); }
void  DispatchSignal(const Signal &sig, const VoteVector &votes);   // fan-out to CELL_COUNT

// VirtualBook.mqh
bool  IsCellBusy(const int cell_id);           // concurrency gate, see §3
bool  OpenVirtual(const int cell_id, const Signal &sig);  // false if busy or risk out of bounds
void  MarchOpenTrades(const MqlRates &bar);    // resolve stops/targets/timeouts
void  CloseAllAtEnd();                         // mark remaining open trades truncated

// Tally.mqh
void  Record(const VirtualTrade &t);           // ignores t.truncated == true
void  WriteRanking(const string path);
```

`CellId` is the one place the enum-to-index conversion happens. With `PAT_NONE = 0` the twelve patterns occupy enum values 1–12, so indexing on the raw enum yields a maximum of `12*32 + 15*2 + 1 = 415` against a 384-slot array — an out-of-range write — while leaving slots 0–31 permanently unused. `OnInit` asserts `CellId(last_pattern, 15, true) == CELL_COUNT - 1`.

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
bar_time, symbol, tf, pattern, dir, bar_count, atr, pattern_range_atr, pattern_extreme,
rsi, macd_main, macd_signal, macd_hist, stoch_k, stoch_d, cci, atr_sma50,
vote_rsi, vote_macd, vote_stoch, vote_cci,
atr_filter_pass, prior_trend_pass, risk_bounds_pass, admitted_cell_count
```

Every input to every vote rule is logged, not just the headline value. The rules in §5 read `%D` as well as `%K`, and the MACD main and signal lines as well as the histogram, so logging only `stoch_k` and `macd_hist` would make a vote impossible to recompute offline. For a rig whose output is a statistical claim, each row must be independently auditable.

**`trades_<symbol>_<tf>_<runid>.csv`** — one row per virtual trade:

```
cell_id, pattern, subset_mask, subset_label, atr_filter,
entry_time, exit_time, dir, entry, stop, target, exit_price, risk, risk_atr,
bars_held, outcome, r_multiple, mfe_atr, mae_atr, truncated
```

`subset_label` is human-readable (`"RSI+MACD"`, `"NONE"`, `"RSI+MACD+STOCH+CCI"`) so the output is analysable without decoding bitmasks. `truncated` rows are written for completeness but excluded from `CellStats` (§3).

---

## 8. Reporting and ranking

At `OnDeinit`, `TallyEngine` writes **`ranking_<symbol>_<tf>_<runid>.csv`** and prints the top 20 to the tester journal.

Per-cell metrics:

| Metric | Definition | Denominator |
| --- | --- | --- |
| `samples` | Resolved, non-truncated trades | — |
| `n_resolved` | `confirmed + failed` (timeouts excluded) | — |
| `hit_rate` | `confirmed / n_resolved` | `n_resolved` |
| `wilson_lb` | 95% one-sided Wilson lower bound on `hit_rate` | `n_resolved` |
| `expectancy_r` | Mean R-multiple per trade, net of cost | `samples` |
| `stdev_r` | Std. dev. of R | `samples` |
| `profit_factor` | `gross_win / gross_loss` | — |
| `avg_mfe_atr` / `avg_mae_atr` | Mean favourable / adverse excursion | `samples` |
| `lift_vs_control` | `expectancy_r` minus the same pattern's empty-subset expectancy, at the same `atr_filter` state | — |

**Denominators are not interchangeable.** `hit_rate` and its Wilson bound are computed over `n_resolved`; expectancy and its dispersion over `samples`. Feeding `samples` into a Wilson bound built from `confirmed` would report a confidence interval whose stated sample size includes trades that never resolved to a win or a loss — the `MinResolved` gate in §3 exists for the same reason.

**Ranking key.** The obvious key — `wilson_lb × expectancy_r` — is broken, and instructively so. It multiplies an always-positive bound by a signed quantity, so among losing cells the ordering **inverts**: with the default payoff, expectancy is `≈ 2.5p − 1`, which turns negative below a 40% hit rate, and past that point a *better* Wilson bound produces a *more* negative product. Concretely, a cell at `p=0.30` (expectancy −0.25R, `wilson_lb` 0.22) scores −0.055 while a cell at `p=0.10` (expectancy −0.75R, `wilson_lb` 0.055) scores −0.041 and ranks **above** it, despite losing three times as much per trade. Since most reversal cells will sit below 40%, that scrambles the majority of the grid.

The key is instead a one-sided lower confidence bound on expectancy itself — monotone in performance across the whole range, dimensionally coherent (R-multiples throughout), and still penalising thin samples through the `√n` term:

```
Score = expectancy_r − 1.645 × stdev_r / sqrt(samples)     if Eligible()
Score = −DBL_MAX                                            otherwise
```

`wilson_lb` is retained as a reported diagnostic — it is the right tool for a proportion — but it is no longer the sort key.

`lift_vs_control` is the answer to the actual research question — it isolates what the indicator combination contributed over the bare pattern. A cell with high expectancy but near-zero lift means the pattern was doing the work and the indicators were decoration. Lift is always taken against the control at the *same* `atr_filter` state, so it measures the indicators alone rather than the indicators plus the filter.

**Degenerate-by-construction metrics.** Wins land near `+RewardRatio` and losses near `−1.0` by design, so `profit_factor` is close to `RewardRatio × confirmed/failed` — largely a restatement of `hit_rate`. Only cost and timeout exits give it independent content. It is reported for continuity but should not be treated as a second opinion; `stdev_r` is similarly driven mostly by the timeout mix.

**Required report sections:**
1. Top 20 eligible cells by `Score`.
2. Per-pattern summary: best subset, its lift, control expectancy.
3. Per-indicator marginal contribution: **sample-weighted** mean lift across subsets containing that indicator vs. those without. Weighting is required because subsets differ in sample count by orders of magnitude, and the "without" group must **exclude the empty control**, whose lift is 0 by definition and would drag that arm toward zero mechanically.
4. ATR-filter comparison: aggregate expectancy with filter on vs. off.
5. Rejected-signal counts by reason (`no_trend`, `atr_context`, `no_confirmation`, `risk_bounds`, `cell_busy`).
6. **Cells with no data.** Any cell that never fired, or fired but stayed ineligible, is listed separately with its raw admitted count. `RSI+MACD+STOCH+CCI` under `CONFIRM_ALL` requires all four oscillators at extremes simultaneously and will plausibly never reach 30 samples — "never fired" and "fired and showed no edge" are different findings and must not both render as a blank row.

---

## 9. Inputs

```cpp
// --- Universe
input ENUM_TIMEFRAMES  InpTimeframe        = PERIOD_H1;
input datetime         InpStartDate        = D'2020.01.01';

// --- Trade model
input double           InpStopBufferATR    = 0.25;  // stop = pattern extreme -/+ this x ATR
input double           InpRewardRatio      = 1.5;
input int              InpHoldBars         = 20;
input double           InpMinRiskATR       = 0.25;  // reject signal if risk below this
input double           InpMaxRiskATR       = 3.0;   // ... or above this
input double           InpCostPoints       = 0.0;   // flat spread+commission, charged per trade

// --- Pattern gates
input int              InpTrendLookback    = 5;
input double           InpMinPriorMoveATR  = 1.0;
input double           InpTweezerTolATR    = 0.10;

// --- Indicators / ATR context filter
input int              InpAtrPeriod        = 14;
input double           InpMinPatternATR    = 0.8;   // part of the TOGGLED filter, not a detector gate
input int              InpRsiPeriod        = 14;
input int              InpMacdFast=12, InpMacdSlow=26, InpMacdSignal=9;
input int              InpStochK=14, InpStochD=3, InpStochSlow=3;
input int              InpCciPeriod        = 20;
input double           InpAtrRegimeLow     = 0.7;
input double           InpAtrRegimeHigh    = 1.8;

// --- Engine
input ConfirmMode      InpConfirmMode      = CONFIRM_ALL;
input int              InpWarmupBars       = 100;    // validated against indicator periods
input int              InpMinSamples       = 30;     // eligibility: resolved trades
input int              InpMinResolved      = 20;     // eligibility: confirmed+failed only
input bool             InpAllowConcurrent  = false;  // stack trades per cell (see §3)
input int              InpLiveCellId       = -1;     // -1 = no real orders; else mirror this ONE cell
input double           InpLots             = 0.10;
input string           InpRunId            = "run001";
```

`InpTimeframe` is authoritative: indicator handles, `CopyRates`, and the new-bar check all use it, never the chart's `_Period`. `InpStartDate` marks the first bar eligible to *signal*; warmup bars are loaded before it, so the tester range must extend earlier or `OnInit` fails.

---

## 10. Milestones

| # | Deliverable | Acceptance |
| --- | --- | --- |
| M1 | Skeleton compiles: types, config, empty modules, EA lifecycle | Zero compile errors/warnings; runs a tester pass doing nothing |
| M2 | `IndicatorHub` + `Voters` | Vote vector printed per bar matches manual chart reading on 20 spot-checked bars |
| M3 | `PatternScanner` + 12 detectors | Detections match visual chart inspection on a 200-bar sample; prior-trend window verified to start before the pattern's first bar |
| M4 | `VirtualBook` single-cell | One cell's simulated P&L reconciles with a hand-computed ledger over 50 trades, cost included; risk-bound rejections fire on synthetic edge cases |
| M5 | `ComboEngine` full 384-cell fan-out | `CellId` round-trips for all 384 combinations with no collision and no index outside `[0, 383]`; with `InpAllowConcurrent=true` the control cell's sample count equals the raw pattern count |
| M6 | `CsvLogger` + `Tally` + ranking | Report generated; `lift_vs_control` computed; ranking stable across two identical runs; a synthetic all-losing cell set ranks in strictly increasing order of expectancy |
| M7 | `LiveExecutor` (optional arm) | With `InpLiveCellId` pinned, real tester trades match that cell's virtual trades 1:1 on entry time, exit time and R |

---

## 11. Risks and known limitations

- **In-sample overfitting.** 384 cells searched over one dataset will produce a top performer by chance alone. Mitigation: the `MinSamples`/`MinResolved` floors, a ranking key that is itself a lower confidence bound, and `lift_vs_control` as the honest metric. Real mitigation is out-of-sample validation, which v1 does not do.
- **Multiple-comparisons problem.** With 384 cells at α=0.05, ~19 cells look "significant" purely by luck. Treat the ranking as a shortlist to re-test, never as a result.
- **The 384 cells are not 384 independent tests.** The subsets are nested — every signal admitted by `RSI+MACD+STOCH+CCI` is also admitted by `RSI+MACD`, which is also admitted by the control — so cells share most of their trades and their results are strongly correlated. The effective number of independent comparisons is far below 384, which means the ~19-by-luck figure above is conservative in the *opposite* direction from the usual worry: the family-wise error is smaller than a naive Bonferroni assumes, but the apparent diversity of the leaderboard is largely illusory. Expect the top 20 to be near-duplicates of one another.
- **Pattern detection is subjective.** Threshold choices (body/wick ratios) materially change detection counts. Thresholds are ATR-normalized inputs so their sensitivity can be measured.
- **Correlated voters.** RSI, Stochastic, and CCI are all oscillators and will frequently agree; a large subset is not four independent opinions. The per-indicator marginal report in §8 partially exposes this.
- **Single symbol/timeframe.** No claim of generality until run across several.
- **No safety measures by design.** Per the brief, this rig has no equity guard, no error recovery, no live-trading protections. It must not be pointed at a funded account.

---

## 12. Open questions

1. Timeframe of record for the first run — H1 assumed, but M15 gives more samples and D1 gives cleaner reversals.
2. Should `ConfirmMode` become a 5th grid dimension rather than a global input? Note from §5.1 that it only changes behaviour for 5 of the 16 subsets — so the cheap version is to expand *only* the triples and the quad under `MAJORITY`, adding 60 cells (`12 × 5`) instead of doubling to 768.
3. Should divergence-based votes (price/oscillator divergence) be added as separate voters, or as a mode of the existing ones?
4. Is a fixed `RewardRatio` target the right success definition, or should success be "MFE ≥ 1 ATR before MAE ≥ 1 ATR" independent of an exit rule? The exit-free version would also restore independent content to `profit_factor` and `stdev_r`, which are near-degenerate under fixed targets (§8).
5. Now that the stop is anchored to the pattern extreme, `risk` varies with pattern size, so an R is not a constant fraction of account equity. Fixed-lot sizing therefore makes cells with larger patterns carry more currency risk per trade. Harmless for R-based ranking, but the live arm's equity curve will not match the virtual R curve — should `LiveExecutor` size per trade as `risk_currency = constant`?

---

*Appendix: if the eventual research target is broader than MT5 (multi-symbol, walk-forward, notebook analysis), the same architecture ports directly to Python — `PatternScanner`/`IndicatorHub`/`ComboEngine`/`VirtualBook` become vectorised passes over a DataFrame, and the CSV schemas in §7 stay identical.*
