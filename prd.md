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

- No account risk management beyond a pattern-anchored stop (§3) and fixed lot size.
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

**Two-phase timing.** Detection and entry happen on different bars, and the design must keep them separate because *the entry price does not exist when the pattern is detected*. Bar `t` closes; the scanner runs; but entry is the open of bar `t+1`, which has not printed yet. Everything derived from entry — `risk`, `target`, the risk-sanity bounds — is therefore uncomputable at detection time.

Signals are consequently **staged, not opened**:

| Phase | Data it may touch | What happens |
| --- | --- | --- |
| **Detect** | bars `t` and earlier | Patterns scanned, votes computed, `PendingSignal` built. No trade parameters computed. No cell touched. |
| **Instantiate** | + bar `t+1`'s open | `entry` known → `risk`, `target`, gap check, risk bounds evaluated **once per signal**. Survivors fan out to their cells. |

**Both phases run inside the same new-bar callback, and `PendingSignal` is not persistent state.** In MQL5 the new-bar condition is detected on the first tick of bar `t+1` — at which moment bar `t` is closed *and* bar `t+1`'s open has already printed. So the handler scans the just-closed bar, then immediately instantiates using the current bar's open. The two phases are a strict ordering constraint on what data each step may read, not a queue that survives across callbacks; implementing one as durable state would be wasted machinery. `PendingSignal` is a local array within the handler.

**Successful reversal.** The outcome measure. A trade is a success when, within its hold window, price reaches the take-profit before touching the stop.

The stop is anchored to the **pattern's own extreme**, not to a fixed distance from entry. A candlestick reversal is invalidated when price violates the low (bullish) or high (bearish) that defined it, and a fixed 1-ATR stop would sit *inside* the range of any pattern larger than 1 ATR — guaranteeing that an ordinary retest closes the trade. Since the ATR context filter selects *for* large patterns (§5), a fixed stop would systematically handicap exactly the trades that filter admits, confounding the on/off comparison in §8.

```
pattern_extreme = lowest low  of the pattern's bars   (bullish)
                = highest high of the pattern's bars  (bearish)

entry  = open of bar t+1                               (known only at phase 2)
stop   = pattern_extreme ∓ (StopBufferATR × ATR(t))    (default 0.25)
risk   = |entry − stop|                                 (the R unit, in price)
target = entry ± (RewardRatio × risk)                   (default 1.5)
```

**Gap check.** Because entry is the *next* bar's open, a weekend or news gap can print it outside the trade's own levels. Two cases, both rejected as `rejected_gap`:

- Entry gaps **through the stop** — the trade is invalidated before it begins, and `risk` would be nonsensically large.
- Entry gaps **past the target** — the trade would register an instant win on its entry bar, recording a full `+RewardRatio` for a move the signal never predicted.

Formally: reject unless `entry` lies strictly between `stop` and `target`. Without this the second case quietly inflates every cell that fires near a session boundary.

**Risk sanity bounds.** Because `risk` is data-derived it can degenerate, and it is a denominator. A signal is rejected unless `MinRiskATR × ATR(t) ≤ risk ≤ MaxRiskATR × ATR(t)` (defaults 0.25 / 3.0), counted once as `rejected_risk_bounds`. `risk` depends only on entry, `pattern_extreme` and ATR — all cell-independent — so this test, like the gap check, is evaluated **once per signal at instantiation, before fan-out**, never per cell. Testing it inside `OpenVirtual` would count a single rejection 384 times in the §8 tallies.

A gapped entry that survives both checks still resolves under the pessimistic tie-break: if its entry bar spans both stop and target, it is FAILED.

**Hold window scales with risk.** A fixed bar count cannot serve a variable stop distance. A pattern with a 3-ATR stop has its target `1.5 × 3 = 4.5` ATR away and needs a far larger move than a 0.5-ATR-stop trade — given equal bars, the wide-stop trade times out far more often. Because `MinPatternATR` selects *for* large patterns in the filter-on arm, a fixed window would reintroduce exactly the confound the pattern-anchored stop was adopted to remove, this time through the timeout channel. The window is therefore proportional to the distance the trade must travel:

```
hold_bars = clamp( round( HoldBarsPerATR × RewardRatio × risk / ATR(t) ),
                   HoldBarsMin, HoldBarsMax )        (defaults 13, 8, 60)
```

At `risk = 1 ATR` and `RewardRatio = 1.5` this yields 20 bars, matching the previous fixed default. Timeout rate is still reported per ATR-filter arm (§8) so any residual distortion stays visible.

**Cost.** `InpCostPoints` (spread + commission, in points) is charged once per trade, on **every** outcome including timeouts:

```
cost_price = InpCostPoints × _Point
r_multiple = (dir × (exit_price − entry) − cost_price) / risk       where dir = +1 bull, −1 bear
```

- **CONFIRMED** — target hit first. `exit_price = target`, so `r ≈ +RewardRatio` less cost.
- **FAILED** — stop hit first. `exit_price = stop`, so `r ≈ −1.0` less cost.
- **TIMEOUT** — neither within `hold_bars`. `exit_price = close of the final bar held`.

`bars_held` counts the entry bar as **1**: a trade entered at the open of `t+1` and resolved inside that same bar has `bars_held = 1`, and a trade with `hold_bars = 20` is force-exited at the close of bar `t+20`. The live arm uses the identical convention, so M7's reconciliation is exact rather than off by one.

If both stop and target fall inside the same bar's range, resolve pessimistically (stop first). This is a deliberate bias toward under-stating results.

**Concurrency — cells never skip signals.** Every cell takes **every** signal it admits, including while it already holds one or more open trades. This is unconditional, not configurable.

The alternative — one open trade per cell, dropping the rest — is tempting because it mirrors real trading and yields independent samples, but it silently destroys the headline metric. Cells become busy at *different* times because they admit different signals, so each cell ends up scored on a different subsample:

> Bar 100, an unconfirmed hammer. The control cell (mask 0) admits it and is occupied until bar 120. Bar 105, another hammer, this one confirmed by all four oscillators. The control is busy → dropped. Mask 15 was idle → admits it.

Mask 15 is now credited with a signal the control never saw, so `lift_vs_control` stops comparing like with like. The bias is systematic rather than random: the busy gate preferentially drops *clustered* signals, and signals cluster in exactly the extended-momentum conditions the study is about. It also breaks the subset-nesting property §11 depends on — under a busy gate, mask 15's admitted set is no longer contained in mask 3's.

The cost of always-admit is that trades within a cell overlap and their outcomes are correlated, so `samples` overstates the independent information available. That is a *statistics* problem with known remedies, and §8 applies one; a biased control arm has no remedy at all. There is consequently **no busy gate and no `InpAllowConcurrent` input** — an earlier draft kept the flag "for diagnostics", but the gated code path was removed, leaving a switch nothing read. Concurrency is unconditional.

**End of data.** Virtual trades still open when the run ends are resolved as TIMEOUT at the final bar's close, flagged `truncated = true` in the trade log, and **excluded** from `CellStats` — they had less than their own `hold_bars` to resolve, so counting them biases the tail of the sample.

**Sample.** One admitted signal in one cell. Two counts are tracked and must not be conflated:

- `samples` — all admitted signals that produced a resolved, non-truncated trade. Denominator for `expectancy_r`.
- `n_resolved` = `confirmed + failed` — trades that hit stop or target. Denominator for `hit_rate`.
- `overlap_ratio` — the cell's mean concurrency *while it holds anything at all*.
- `n_eff`, `n_resolved_eff` — the overlap-adjusted counts the confidence arithmetic in §8 uses.

Because trades within a cell run concurrently, they share bars and their outcomes are correlated, so raw counts overstate the independent information available:

```
active_bars   = count of DISTINCT bar indices covered by at least one of the cell's trades
overlap_ratio = sum(bars_held over the cell's trades) / max(1, active_bars)

n_eff          = samples     / overlap_ratio
n_resolved_eff = n_resolved  / overlap_ratio
```

Three details carry the weight here, each of which an earlier draft got wrong:

- **The numerator sums `bars_held`, the realised duration — never `hold_bars`, the cap.** Most trades resolve well before their limit, so summing caps would inflate the ratio and drive `n_eff` far below the truth, making every cell look weaker than the data supports.
- **The denominator counts distinct *covered* bars, not the span from first entry to last exit.** A cell with forty overlapping trades in one year and silence for two more would, on a span denominator, report `overlap_ratio ≈ 1` — full independence for the most clustered cell in the grid, exactly backwards. Counting only bars where a trade was actually open makes the measure immune to idle stretches.
- **Bar *indices*, not timestamps.** `CellStats` tracks integer bar indices; the count of bars between two `datetime` values is not recoverable across weekends, holidays and session gaps.

A cell whose trades never overlap has `overlap_ratio = 1` and `n_eff = samples`; one running three deep on average has `n_eff ≈ samples/3`. This remains a crude first-order correction — a block bootstrap over the trade sequence is the rigorous version, and is future work — but it beats assuming independence outright.

**Eligibility uses the adjusted counts,** since the floors exist to guarantee sufficient *information*, and raw counts no longer measure that:

```
Eligible = (n_eff >= MinSamples)  AND  (n_resolved_eff >= MinResolved)      (defaults 30, 20)
```

Gating on raw `samples` while scoring on `n_eff` would admit a cell with 30 samples at overlap depth 6 — thirty observations by the floor's reckoning, five by the score's. The second gate additionally stops a cell of 30 samples with 28 timeouts from reporting a "95% confidence bound" resting on two resolved trades.

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

`PatternCount = 12`. Note that patterns are not mutually exclusive — a hammer, a bullish engulfing and a tweezer bottom can all fire on the same bar, and bullish and bearish patterns can both fire. Each is dispatched independently to the cells carrying *its own* `PatternId`, so simultaneous detections never compete: a cell is `(pattern, subset, atr_filter)` and admits one pattern by construction. No tie-break exists or is needed anywhere in the design, including `LiveExecutor` (§6.1.1).

---

## 5. Indicator layer

Five indicators. ATR is structural (never a directional vote); the other four are the momentum voters. Note that ATR is **not** the risk unit — since §3 the R unit is `risk`, the pattern-anchored stop distance. ATR supplies the stop *buffer*, the normalizer for pattern thresholds, the regime filter, and the hold-window scale.

| Slot | Indicator | Default params | Vote rule |
| --- | --- | --- | --- |
| — | **ATR** | 14 | No vote. Supplies stop buffer, threshold normalizer, context filter, hold-window scale. |
| `IND_RSI` | **RSI** | 14 | `+1` if RSI ≤ 30 (`LEVEL`) or crossed up through 30 within 2 bars (`CROSS`); `−1` mirrored at 70; else `0`. |
| `IND_MACD` | **MACD** | 12/26/9 | `+1` if histogram turned up from a negative trough within 2 bars (`TURN`), or main crossed above signal (`CROSS`); `−1` mirrored; else `0`. |
| `IND_STOCH` | **Stochastic** | 14/3/3 | `+1` if `%K ≤ 20` and `%K` crossed above `%D` within 2 bars (`CROSS`); `−1` mirrored at 80; else `0`. |
| `IND_CCI` | **CCI** | 20 | `+1` if CCI ≤ −100 (`LEVEL`) or crossed up through −100 within 2 bars (`CROSS`); `−1` mirrored at +100; else `0`. |

Every rule is a two-bar rule: a cross is only visible against the indicator's prior values. The clause that fired is recorded per indicator as a `VoteReason` (`NONE`, `LEVEL`, `CROSS`, `TURN`) and logged (§7) — without it a vote cannot be audited after the fact, since the CSV row for bar `t` alone cannot show what happened at `t−1`.

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
  PHASE 1 — close of bar t
                       ┌──────────────────────┐
   new closed bar ───► │  PatternScanner      │──► Signal{pattern, dir, extreme}
                       └──────────────────────┘
                       ┌──────────────────────┐
                   ───►│  IndicatorHub        │──► VoteVector{votes, reasons}
                       └──────────────────────┘        + AtrContext{atr, passes_filter}
                                  │
                                  ▼
                       ┌──────────────────────┐
                       │  PendingQueue        │  entry price does not exist yet —
                       │                      │  hold, compute nothing
                       └──────────────────────┘
                                  │
  PHASE 2 — open of bar t+1       ▼
                       ┌──────────────────────┐
                       │  SignalInstantiator  │  entry known → risk, target,
                       │                      │  risk-bound check ONCE per signal
                       └──────────────────────┘
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

The live arm exists solely to validate the simulator, so it mirrors a single cell fixed before the run (`InpLiveCellId`, default −1 = disabled). A cell *is* `(pattern, subset, atr_filter)`, so exactly one pattern can fire into it and no cross-pattern tie-break is possible — an earlier draft described one, which was incoherent.

The real constraint is different: the mirrored cell may open concurrent trades (§3), and a real account can hold only one position per symbol per direction. `LiveExecutor` therefore mirrors only trades that begin while the cell is flat, and logs the rest as `live_skipped`. The M7 reconciliation runs against that subset, not the whole cell. The live arm proves the simulator's arithmetic; it is not a second estimate of the cell's performance.

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
enum VoteReason { VR_NONE=0, VR_LEVEL, VR_CROSS, VR_TURN };   // which clause fired, for audit

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
   int        vote[4];          // indexed by IND_RSI…IND_CCI, each -1/0/+1
   VoteReason reason[4];        // which clause produced that vote
   int  ConfirmCount(Direction d, int subset_mask) const;
   bool Admits(Direction d, int subset_mask, ConfirmMode mode) const;
};

// Phase 1 output. Carries NO trade parameters — entry is unknown until phase 2.
// Lives in a local array inside the new-bar handler, never as persistent state (§3).
struct PendingSignal {
   Signal     sig;
   VoteVector votes;
};

struct VirtualTrade {
   int       cell_id;
   datetime  entry_time;
   double    entry, stop, target, risk;
   double    risk_atr;          // risk / ATR(t) — ties the two unit systems together
   Direction dir;
   int       bars_held;         // entry bar counts as 1
   int       hold_bars;         // this trade's risk-scaled limit, see §3
   double    mfe_r,   mae_r;    // excursions in R  (primary — commensurate with r_multiple)
   double    mfe_atr, mae_atr;  // excursions in ATR (secondary — comparable across cells)
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
   double sum_mfe_r,   sum_mae_r;
   double sum_mfe_atr, sum_mae_atr;

   // --- overlap tracking (§3). Realised durations over distinct covered bars.
   long   sum_bars_held;           // numerator   — NOT sum of hold_bars caps
   int    active_bars;             // denominator — distinct bar indices with >=1 open trade
                                   // maintained by MarchOpenTrades: ++ on any bar the cell
                                   // holds anything, so idle stretches never dilute it

   int    NResolved()      const;  // confirmed + failed
   double OverlapRatio()   const;  // sum_bars_held / max(1, active_bars)
   double NEff()           const;  // samples    / OverlapRatio()
   double NResolvedEff()   const;  // NResolved() / OverlapRatio()
   bool   Eligible()       const;  // NEff() >= MinSamples && NResolvedEff() >= MinResolved
   double HitRate()        const;  // confirmed / NResolved()      0 if NResolved()==0
   double Expectancy()     const;  // sum_r / samples
   double StdevR()         const;  // NaN if samples < 2 — guard the (n-1) divisor
   double WilsonLower()    const;  // 95% one-sided bound on HitRate() over NResolvedEff()
   double ProfitFactor()   const;  // gross_win / gross_loss;  undefined if gross_loss==0
   double Score()          const;  // ranking key, see §8
};
```

Undefined metrics (`StdevR` below 2 samples, `ProfitFactor` with no losses, `Score` for an
ineligible cell) are written to CSV as an **empty field**, never as a sentinel. `DBL_MAX`
serialises as `1.797693e+308` and silently becomes a real number to every downstream
consumer; sort order inside the EA uses the sentinel, the file does not.

```cpp
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

// Both run in one new-bar handler, in this order (§3). PendingSignal[] is a local.
// --- Phase 1: may read bar t and earlier only. No trade parameters exist yet.
void  StageSignal(const Signal &sig, const VoteVector &votes, PendingSignal &pending[]);

// --- Phase 2: may additionally read bar t+1's open, which has already printed.
//     Computes risk/target, applies the gap check and risk bounds ONCE, then fans out.
void  InstantiatePending(PendingSignal &pending[], const double bar_open, const double atr);
bool  PassesGapCheck(const double entry, const double stop, const double target);
int   HoldBarsFor(const double risk, const double atr);   // risk-scaled, clamped

// ComboEngine.mqh
// stride 32 = 16 subsets x 2 atr states; PatternIndex() maps enum 1..12 -> 0..11
#define CELL_COUNT (PATTERN_COUNT * 32)      // 12 * 32 = 384
int   CellId(const PatternId p, const int subset_mask, const bool atr_on)
      { return PatternIndex(p) * 32 + subset_mask * 2 + (atr_on ? 1 : 0); }
void  DispatchSignal(const Signal &sig, const VoteVector &votes);   // fan-out to CELL_COUNT

// VirtualBook.mqh
// No busy gate: every admitted signal opens a trade, concurrent or not (§3).
void  OpenVirtual(const int cell_id, const VirtualTrade &proto);
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

**`signals_<symbol>_<tf>_<runid>.csv`** — one row per signal, written after phase-2 instantiation and before cell admission, so it carries both the detection context and the resulting trade parameters:

```
bar_time, entry_time, symbol, tf, pattern, dir, bar_count,
atr, atr_sma50, pattern_range_atr, pattern_extreme, entry, risk, risk_atr, hold_bars,
rsi, macd_main, macd_signal, macd_hist, stoch_k, stoch_d, cci,
vote_rsi, vote_macd, vote_stoch, vote_cci,
reason_rsi, reason_macd, reason_stoch, reason_cci,
atr_filter_pass, prior_trend_pass, gap_pass, risk_bounds_pass, admitted_cell_count
```

Auditability needs two things, and an earlier draft supplied only one. Logging the extra *series* (`%D`, MACD main and signal) was necessary but not sufficient, because every rule in §5 is a **two-bar** rule — a cross is invisible in a single row no matter how many series it carries. The `reason_*` columns close that gap by recording which clause fired (`LEVEL`, `CROSS`, `TURN`, `NONE`), so a reviewer can see *why* a vote was cast without reconstructing the indicator history.

For full offline recomputation, `InpLogIndicatorHistory` adds `_t1`/`_t2` columns for all seven series. It is off by default because it nearly triples the file for a check most runs never need.

Note the row carries both `bar_time` (detection, bar `t`) and `entry_time` (instantiation, bar `t+1`), along with the trade parameters that only exist after phase 2. Signals rejected by the gap check or the risk bounds are still logged, with the corresponding `*_pass = 0` and `admitted_cell_count = 0` — the rejected population is itself a finding, and §8.5 tallies it.

**`trades_<symbol>_<tf>_<runid>.csv`** — one row per virtual trade:

```
cell_id, pattern, subset_mask, subset_label, atr_filter,
entry_time, exit_time, dir, entry, stop, target, exit_price, risk, risk_atr,
bars_held, hold_bars, outcome, r_multiple,
mfe_r, mae_r, mfe_atr, mae_atr, truncated
```

Excursions are logged in **both** unit systems. `risk` is pattern-derived and ranges from 0.25 to 3.0 ATR, so an R and an ATR are no longer the same distance: `mfe_atr` beside `r_multiple` invites a comparison that does not hold. `mfe_r` is the commensurate one and the primary; `mfe_atr` is retained because it is comparable *across* cells with different stop distances. `risk_atr` is the conversion factor between them and is logged on every row.

`subset_label` is human-readable (`"RSI+MACD"`, `"NONE"`, `"RSI+MACD+STOCH+CCI"`) so the output is analysable without decoding bitmasks. `truncated` rows are written for completeness but excluded from `CellStats` (§3).

---

## 8. Reporting and ranking

At `OnDeinit`, `TallyEngine` writes **`ranking_<symbol>_<tf>_<runid>.csv`** and prints the top 20 to the tester journal.

Per-cell metrics:

| Metric | Definition | Denominator |
| --- | --- | --- |
| `samples` | Resolved, non-truncated trades | — |
| `n_resolved` | `confirmed + failed` (timeouts excluded) | — |
| `overlap_ratio` | Mean concurrency while the cell holds anything (§3) | — |
| `n_eff` / `n_resolved_eff` | Overlap-adjusted counts, `samples`/`n_resolved` ÷ `overlap_ratio` | — |
| `timeout_rate` | `timeout / samples` — reported per ATR-filter arm | `samples` |
| `hit_rate` | `confirmed / n_resolved` | `n_resolved` |
| `wilson_lb` | 95% one-sided Wilson lower bound on `hit_rate` | `n_resolved_eff` |
| `expectancy_r` | Mean R-multiple per trade, net of cost | `samples` |
| `stdev_r` | Std. dev. of R | `samples` |
| `profit_factor` | `gross_win / gross_loss` | — |
| `avg_mfe_r` / `avg_mae_r` | Mean excursion in R (primary) | `samples` |
| `avg_mfe_atr` / `avg_mae_atr` | Mean excursion in ATR (cross-cell comparable) | `samples` |
| `lift_vs_control` | `expectancy_r` minus the same pattern's empty-subset expectancy, at the same `atr_filter` state | — |

**Denominators are not interchangeable.** `hit_rate` and its Wilson bound are computed over `n_resolved`; expectancy and its dispersion over `samples`. Feeding `samples` into a Wilson bound built from `confirmed` would report a confidence interval whose stated sample size includes trades that never resolved to a win or a loss — the `MinResolved` gate in §3 exists for the same reason.

**Ranking key.** The obvious key — `wilson_lb × expectancy_r` — is broken, and instructively so. It multiplies an always-positive bound by a signed quantity, so among losing cells the ordering **inverts**: with the default payoff, expectancy is `≈ 2.5p − 1`, which turns negative below a 40% hit rate, and past that point a *better* Wilson bound produces a *more* negative product. Concretely, a cell at `p=0.30` (expectancy −0.25R, `wilson_lb` 0.22) scores −0.055 while a cell at `p=0.10` (expectancy −0.75R, `wilson_lb` 0.055) scores −0.041 and ranks **above** it, despite losing three times as much per trade. Since most reversal cells will sit below 40%, that scrambles the majority of the grid.

The key is instead a one-sided lower confidence bound on expectancy itself — monotone in performance across the whole range, dimensionally coherent (R-multiples throughout), and still penalising thin samples through the `√n` term:

```
Score = expectancy_r − 1.645 × stdev_r / sqrt(n_eff)     if Eligible()
Score = −DBL_MAX  (written to CSV as empty)               otherwise
```

**The divisor is `n_eff`, not `samples`.** Since §3 removed the busy gate, a cell's trades overlap and their outcomes are correlated, so `√samples` would understate the standard error and flatter exactly the busiest cells — the ones whose signals cluster. `n_eff` discounts by the average overlap depth.

`wilson_lb` takes the same correction through `n_resolved_eff`. Note the two adjusted counts are *parallel*, not interchangeable: `n_eff` scales the all-trades population, `n_resolved_eff` the stop-or-target population, and each divides by the same `overlap_ratio`. An earlier draft capped `n_eff` at `n_resolved`, mixing the two populations into a figure that described neither.

`wilson_lb` is retained as a reported diagnostic — it is the right tool for a proportion — but it is no longer the sort key.

`lift_vs_control` is the answer to the actual research question — it isolates what the indicator combination contributed over the bare pattern. A cell with high expectancy but near-zero lift means the pattern was doing the work and the indicators were decoration. Lift is always taken against the control at the *same* `atr_filter` state, so it measures the indicators alone rather than the indicators plus the filter.

**Degenerate-by-construction metrics.** Wins land near `+RewardRatio` and losses near `−1.0` by design, so `profit_factor` is close to `RewardRatio × confirmed/failed` — largely a restatement of `hit_rate`. Only cost and timeout exits give it independent content. It is reported for continuity but should not be treated as a second opinion; `stdev_r` is similarly driven mostly by the timeout mix.

**Required report sections:**
1. Top 20 eligible cells by `Score`.
2. Per-pattern summary: best subset, its lift, control expectancy.
3. Per-indicator marginal contribution: **sample-weighted** mean lift across subsets containing that indicator vs. those without. Weighting is required because subsets differ in sample count by orders of magnitude, and the "without" group must **exclude the empty control**, whose lift is 0 by definition and would drag that arm toward zero mechanically.
4. ATR-filter comparison: aggregate expectancy with filter on vs. off, **reported alongside `timeout_rate` and mean `risk_atr` for each arm**. The filter selects for large patterns, which take wider stops and more distant targets; the risk-scaled hold window (§3) is meant to neutralise that, and these two columns are how you check whether it did.
5. Rejected-signal counts by reason (`no_trend`, `atr_context`, `no_confirmation`, `gap`, `risk_bounds`). Each is counted **once per signal**, not once per cell.
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
input double           InpHoldBarsPerATR   = 13.0;  // hold window scales with target distance
input int              InpHoldBarsMin      = 8;
input int              InpHoldBarsMax      = 60;
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
input int              InpMinSamples       = 30;     // eligibility floor on n_eff
input int              InpMinResolved      = 20;     // eligibility floor on n_resolved_eff
input bool             InpLogIndicatorHistory = false; // adds _t1/_t2 columns for full vote replay
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
| M3.5 | Two-phase staging | A signal detected at bar `t` produces a trade whose `entry` equals bar `t+1`'s open, verified on 20 cases; phase 1 provably reads no bar later than `t`; a synthetic gap entry beyond stop and one beyond target are both rejected as `gap` |
| M4 | `VirtualBook` single-cell | One cell's simulated P&L reconciles with a hand-computed ledger over 50 trades, cost included; `bars_held` counts the entry bar as 1; risk-bound rejections fire on synthetic edge cases and are counted once, not 384 times |
| M5 | `ComboEngine` full 384-cell fan-out | `CellId` round-trips for all 384 combinations with no collision and no index outside `[0, 383]`; the control cell's sample count equals the raw pattern count that passed the risk bounds |
| M6 | `CsvLogger` + `Tally` + ranking | Report generated; `lift_vs_control` computed; ranking stable across two identical runs; a synthetic all-losing cell set ranks in strictly increasing order of expectancy; undefined metrics serialise as empty fields, never `1.79e308` |
| M6.1 | `overlap_ratio` correctness | Non-overlapping synthetic cell → `overlap_ratio == 1`, `n_eff == samples`; a cell of N trades each open for the same B bars, all simultaneous → `overlap_ratio == N`; a cell clustered in one period then idle for twice as long reports the **same** ratio as the cluster alone (idle bars must not dilute it) |
| M7 | `LiveExecutor` (optional arm) | With `InpLiveCellId` pinned, real tester trades match the cell's **flat-entry** virtual trades 1:1 on entry time, exit time and R; concurrent ones appear as `live_skipped` |

---

## 11. Risks and known limitations

- **In-sample overfitting.** 384 cells searched over one dataset will produce a top performer by chance alone. Mitigation: the `MinSamples`/`MinResolved` floors, a ranking key that is itself a lower confidence bound, and `lift_vs_control` as the honest metric. Real mitigation is out-of-sample validation, which v1 does not do.
- **Multiple-comparisons problem.** With 384 cells at α=0.05, ~19 cells look "significant" purely by luck. Treat the ranking as a shortlist to re-test, never as a result.
- **The 384 cells are not 384 independent tests.** The subsets are strictly nested — every signal admitted by `RSI+MACD+STOCH+CCI` is also admitted by `RSI+MACD`, which is also admitted by the control — so cells share most of their trades and their results are strongly correlated. The effective number of independent comparisons is far below 384, which means the ~19-by-luck figure above is conservative in the *opposite* direction from the usual worry: the family-wise error is smaller than a naive Bonferroni assumes, but the apparent diversity of the leaderboard is largely illusory. Expect the top 20 to be near-duplicates of one another. **This containment holds only because §3 admits every signal into every qualifying cell.** A one-trade-per-cell gate would break it — a restrictive cell, idle more often, could take signals a permissive cell was too busy to see — which is the second reason concurrency defaults on.
- **Trades within a cell overlap, so samples are not independent either.** `n_eff` (§3) discounts for this at first order, but the correction is crude: it assumes overlap is the only dependence, when consecutive reversal signals in the same regime are correlated whether or not their trades overlap. A block bootstrap over the trade sequence is the honest version and is not in v1. Read every confidence figure as optimistic.
- **Pattern detection is subjective.** Threshold choices (body/wick ratios) materially change detection counts. Thresholds are ATR-normalized inputs so their sensitivity can be measured.
- **Correlated voters.** RSI, Stochastic, and CCI are all oscillators and will frequently agree; a large subset is not four independent opinions. The per-indicator marginal report in §8 partially exposes this.
- **Single symbol/timeframe.** No claim of generality until run across several.
- **No safety measures by design.** Per the brief, this rig has no equity guard, no error recovery, no live-trading protections. It must not be pointed at a funded account.

---

## 12. Open questions

1. Timeframe of record for the first run — H1 assumed, but M15 gives more samples and D1 gives cleaner reversals.
2. Should `ConfirmMode` become a 5th grid dimension rather than a global input? Note from §5.1 that it only changes behaviour for 5 of the 16 subsets — so the cheap version is to expand *only* the triples and the quad under `MAJORITY`, adding 60 cells (`12 × 5`) instead of doubling to 768.
3. Should divergence-based votes (price/oscillator divergence) be added as separate voters, or as a mode of the existing ones?
4. Is a fixed `RewardRatio` target the right success definition, or should success be exit-free — "MFE ≥ 1R before MAE ≥ 1R"? The exit-free version would also restore independent content to `profit_factor` and `stdev_r`, which are near-degenerate under fixed targets (§8). Note it must be stated in **R**, not ATR: since §3 the two are different distances, and an ATR-denominated success test would silently vary in strictness with pattern size.
5. Now that the stop is anchored to the pattern extreme, `risk` varies with pattern size, so an R is not a constant fraction of account equity. Fixed-lot sizing therefore makes cells with larger patterns carry more currency risk per trade. Harmless for R-based ranking, but the live arm's equity curve will not match the virtual R curve — should `LiveExecutor` size per trade as `risk_currency = constant`?

---

*Appendix: if the eventual research target is broader than MT5 (multi-symbol, walk-forward, notebook analysis), the same architecture ports directly to Python — `PatternScanner`/`IndicatorHub`/`ComboEngine`/`VirtualBook` become vectorised passes over a DataFrame, and the CSV schemas in §7 stay identical.*
