# Product Requirements Document — HTF/LTF Trend-Continuation EA

**Status:** Draft v0.7 — deterministic implementation specification
**Platform:** MetaTrader 5 / MQL5
**Companion:** [`roadmap.md`](roadmap.md) · **Review trail:** [`review/v0.6-findings.md`](review/v0.6-findings.md)

**Design objective (unchanged):** two independent implementations of this specification,
given the same market data and parameters, must produce the same structural
interpretation and the same trades.

---

## Changelog from v0.6

v0.7 is a correctness pass over v0.6. No new strategy behaviour is introduced; every
change either fixes a defect, removes an ambiguity, or writes out something v0.6
referenced but never defined. Full analysis in [`review/v0.6-findings.md`](review/v0.6-findings.md).

**Blocking fixes**

- **Momentum is now direction-aware (§12.1, B-1).** v0.6 classified short setups on raw
  signed ROC, so a healthy bearish impulse scored `NEGATIVE → REJECT`. All tiers now
  compare `Directional_ROC` (`+ROC` long, `−ROC` short).
- **Position sizing corrected (§15, B-2).** v0.6's `Account_Risk / |Entry − SL|` does not
  yield lots. Now converts through tick size and tick value, then normalises to broker
  lot constraints, with an explicit reject when the result is below min lot.
- **ER zero-denominator defined (§7.1, B-3).** A flat window divided by zero. `ER = 0`
  (→ `CHOPPY`) on a zero denominator; data-sufficiency precondition stated.
- **Buffer floors split (§35, B-4).** v0.6 shared one `MinimumPoints` across BOS and SL
  buffers while §35 forbade exactly that. Now `BOS_MinimumPoints`, `SL_MinimumPoints`,
  `Structural_MinimumPoints`.
- **`Structural_Break_Buffer` given a formula (§5.4, B-5).** Used by §5.2/§5.3 in v0.6 but
  defined nowhere; new `Structural_Break_ATR_Multiplier` parameter, validated in §38.
- **`Average_LTF_Shadow` defined (§16.4, B-6).** Side, lookback and completed-bars-only
  rule now specified; new `ShadowLookbackBars` parameter.

**Material fixes**

- Pipeline order unified — §22.2 is normative, §23/§24 and the roadmap funnel follow it (M-1).
- §16.1 active stop restated as the three-term ratchet, matching §25.6 (M-2).
- Breakeven activation rule and `BreakevenActivationR` defined (§16.3, M-3).
- `MFE_R` defined against the frozen initial stop distance (§16.2a, M-4).
- §10.5.A unbuffered-level asymmetry made explicit and justified (M-5).
- §11.1/§11.2 BOS conditions written out; `StructuralLow` defined (M-6).
- §7.2 `AMBIGUOUS` clarified as an ER band, not a fourth enum value (M-7).
- Calibration budget reconciled with Group A–D lists (§28, M-8).
- Signal price series pinned to Bid-based OHLC (§10.4, M-9).
- §38 validation extended with 12 missing checks (M-10).

**Editorial fixes**

- §9.1–9.3 and §12.1–12.3 numbered (were referenced but unnumbered).
- §17.1 unfinished editorial text removed; §34 self-reference removed.
- §18.1, §28.1, §28.3 and §7.4 written out (were "unchanged from v0.5" dangling refs).
- §29 v1 scope written out explicitly.
- §32 replaced with a complete parameter table.

---

## 1. Purpose

Automated trading system based on: HTF market structure, market regime detection, LTF
Break of Structure (BOS), directional location filtering, momentum classification, and
structural risk management. A deterministic HTF/LTF intraday trend-continuation EA.

## 2. Core Strategy Architecture

```
STRUCTURE  → Direction     (BULLISH / BEARISH / NEUTRAL)
REGIME     → Tradeability  (STRONG / ACCEPTABLE / CHOPPY)
LOCATION   → Setup context
BOS        → Entry trigger
MOMENTUM   → Trade quality / position risk
```

## 3. Timeframe Model

HTF → direction. LTF → entry structure / BOS. Fixed combination per backtest run
(e.g. HTF=H1, LTF=M5).

**Constraint (new in v0.7, M-10):** the HTF period in minutes must be strictly greater
than the LTF period in minutes, and should be an exact integer multiple of it. Validated
at startup per §38; an inverted or non-integer pair makes the §4.4 freeze meaningless.

---

## 4. Market Structure Data Model

### 4.1 Confirmed swing (non-repainting, tie-breaking defined)

```
Swing high at bar i: High[i] > High of K bars before AND High[i] > High of K bars after
Swing low  at bar i: Low[i]  < Low  of K bars before AND Low[i]  < Low  of K bars after
```

**TIE-BREAKING RULE — strict inequality only.** If `High[i]` equals any compared high in
the K-bar window on either side (or `Low[i]` equals any compared low), bar `i` does NOT
qualify as a swing pivot — neither bar in a tie qualifies under the "earliest wins" or
"latest wins" alternative framings. The pivot search simply continues to later bars until
a bar exists with strictly greater (or strictly lesser) values than all K bars on both
sides.

```
Example:  100, 102, 102, 99 → neither of the two 102 bars qualifies as a swing high;
                              the algorithm continues scanning forward.
```

Usable only after K future bars have closed. `SwingConfirmationBars = K`.

A pivot at bar `i` is therefore **confirmed at the close of bar `i + K`**, and carries
that confirmation timestamp for all downstream sequencing decisions.

### 4.2 Confirmed structure

Used for HTF direction, structural/BOS reference levels, and location filtering. Storage
is append-only. Never modified retroactively.

### 4.3 Developing structure

Retracement / setup / candidate BOS only. Never rewrites confirmed structure.

### 4.4 HTF/LTF synchronization

`HTF_STATE` (§5) is FROZEN for the entire duration of a given LTF bar's evaluation. The
frozen value is captured at the OPEN of that LTF bar — i.e. the `HTF_STATE` value as of
the most recently completed HTF candle at that moment.

If an HTF candle completes DURING the formation of the current LTF bar, `HTF_STATE` is
NOT updated until the LTF bar that begins after that HTF candle's close. The LTF pipeline
(§22.2) always evaluates against the frozen snapshot, never a value that could change
mid-bar.

This guarantees two implementations processing the same historical data will use the
identical `HTF_STATE` value for every LTF bar evaluation, regardless of internal update
timing.

The frozen snapshot covers `STRUCTURE_STATE`, `REGIME_STATE`, `Protected_Low`,
`Protected_High`, `HTF_ATR`, `ER` and `ADX` — every HTF-derived value the LTF pipeline
reads. Freezing only some of them would reintroduce exactly the mid-bar inconsistency
this section exists to prevent.

---

## 5. HTF Structure State

### 5.1 States

```
STRUCTURE_STATE ∈ { BULLISH, BEARISH, NEUTRAL }
```

### 5.2 Bullish structure

Invalidation: `HTF_Close < Protected_Low − Structural_Break_Buffer`

### 5.3 Bearish structure

Invalidation: `HTF_Close > Protected_High + Structural_Break_Buffer`

### 5.4 Structural break buffer (new in v0.7 — fixes B-5)

```
Structural_Break_Buffer = max(Structural_MinimumPoints,
                              HTF_ATR × Structural_Break_ATR_Multiplier)
```

`HTF_ATR` per §37, computed on completed HTF candles only, read from the §4.4 frozen
snapshot. Both parameters are validated at startup per §38 and are distinct from the BOS
and SL buffer parameters per §35.

### 5.5 Neutral structure

No valid directional protected structure, or structure just invalidated, or insufficient
data (fewer than `2K + 1` completed HTF candles, so no pivot can yet be confirmed). No
trades permitted.

`HTF_STATE` updates only on completed HTF candles, per §4.4.

---

## 6. Protected Structure Definition

### 6.1 Bullish protected low

The confirmed swing low preceding the impulse to the current valid structural high.
Replaced only when all three hold:

1. A new confirmed swing low exists (§4.1).
2. Price subsequently creates a new valid structural high.
3. The new structure confirms the swing belongs to the active bullish impulse sequence —
   i.e. the new swing low is strictly higher than the outgoing `Protected_Low`, and its
   confirmation timestamp is strictly earlier than the new structural high's.

### 6.2 Bearish protected high

Mirror of §6.1: new confirmed swing high strictly lower than the outgoing
`Protected_High`, confirmed strictly before the new structural low.

---

## 7. Market Regime

### 7.1 Efficiency Ratio

ER uses CLOSE PRICES only (not median or typical price):

```
ER = |Close[0] − Close[N]| / Σ(i=1 to N) |Close[i-1] − Close[i]|
```

where `N = ER_Lookback`, computed on the HTF, using completed HTF candles only.
`Close[0]` is the most recently completed HTF candle.

**Zero-denominator rule (new in v0.7 — fixes B-3).** If the denominator is exactly zero
(every close in the window identical), `ER = 0.0`, which classifies as `CHOPPY` per §7.2.
No division is performed. This is the correct reading — a window with no movement at all
has no directional efficiency — and it prevents `inf`/`nan` propagating silently into
`REGIME_STATE`.

**Data sufficiency.** ER requires `N + 1` completed HTF candles. Before that,
`REGIME_STATE = CHOPPY` (insufficient data), logged as such. A partial sum is never used.

### 7.2 Regime states

`REGIME_STATE ∈ { STRONG, ACCEPTABLE, CHOPPY }` — exactly three values.

ER falls into one of three **bands**; the middle band is *ambiguous* and is resolved by
ADX. `AMBIGUOUS` is a band name, not a state value:

| ER band | Condition | Resulting `REGIME_STATE` |
|---|---|---|
| High | `ER >= ER_HIGH` | `STRONG` |
| Ambiguous | `ER_LOW <= ER < ER_HIGH` | `ACCEPTABLE` if `ADX >= ADX_THRESHOLD`, else `CHOPPY` |
| Low | `ER < ER_LOW` | `CHOPPY` |

Bands are exhaustive and mutually exclusive given §38's `ER_HIGH > ER_LOW` check. ADX is
computed on the HTF with `ADX_Period`, completed candles only, and is part of the §4.4
frozen snapshot.

### 7.3 Combined permission

```
LONG  permitted: STRUCTURE_STATE = BULLISH AND REGIME_STATE ∈ {STRONG, ACCEPTABLE}
SHORT permitted: STRUCTURE_STATE = BEARISH AND REGIME_STATE ∈ {STRONG, ACCEPTABLE}
```

`REGIME_STATE`, like `STRUCTURE_STATE`, is computed on HTF closes and subject to the same
freeze rule (§4.4).

### 7.4 ER threshold calibration procedure (written out in v0.7 — fixes E-5)

`ER_LOW` and `ER_HIGH` are instrument-specific and must not be carried across symbols.
The decile-bucket procedure, referenced but never described in v0.6:

1. Compute ER over the full in-sample window on the target symbol and HTF, one value per
   completed HTF candle.
2. Sort the ER values and split into deciles.
3. For each decile, measure the forward `M`-candle absolute HTF close-to-close move,
   normalised by `HTF_ATR` at the decile's candle (`M = ER_Lookback` is the default).
4. `ER_HIGH` starts at the lower edge of the lowest decile whose mean normalised forward
   move is materially above the all-sample mean; `ER_LOW` starts at the upper edge of the
   highest decile whose mean is materially below it.
5. Both are then swept as part of Stage 12 Group A (§28.3) with stability testing (§28.1).

The point is to start from the instrument's own ER distribution rather than a guessed
default — per the roadmap, wrong ER thresholds are the second-highest zero-trade risk in
the build.

---

## 8. Version 1 Strategy Type: Pullback Continuation Only

Breakout Continuation is excluded from v1 and deferred.

---

## 9. Directional Location Filter

### 9.1 Relevant level

```
Long:  relevant level = HTF Protected Low
Short: relevant level = HTF Protected High
```

### 9.2 Distance

```
Distance = |LTF_Setup_Reference_Price − Relevant_HTF_Protected_Level|
```

### 9.3 Normalized distance and validity

```
NormalizedDistance = Distance / HTF_ATR
Valid when NormalizedDistance <= LocationThreshold
```

`HTF_ATR` per §37, from the §4.4 frozen snapshot. This is the subsection §37 refers to as
"normalization (§9.3)".

### 9.4 Evaluation timing

Location uses the LTF setup low/high as reference — not BOS price.

### 9.5 Protected-level freeze at setup formation

The HTF protected level is frozen at the moment the LTF retracement begins forming the
setup low/high, and remains frozen until BOS fires or the setup is abandoned (§10.5).

---

## 10. LTF Setup Definition

### 10.1 Long setup

Requires: `STRUCTURE_STATE = BULLISH` (frozen per §4.4), `REGIME_STATE != CHOPPY`, price
retraced, and an LTF setup low established within `LocationThreshold` of the frozen HTF
protected low (§9.5).

```
setup_low = lowest price reached during the current LTF retracement, before the
            bullish BOS occurs. Provisional/unstable until BOS fires — not a stable
            diagnostic value before then.
```

### 10.2 Short setup

Mirror: `STRUCTURE_STATE = BEARISH`, `REGIME_STATE != CHOPPY`, price retraced, LTF
`setup_high` (highest price reached during the current retracement) established within
`LocationThreshold` of the frozen HTF protected high.

### 10.3 Reference unification

The setup low (long) / setup high (short) unifies the BOS reference and the SL anchor.

### 10.4 Price series definition (clarified in v0.7 — fixes M-9)

All structural detection and all indicator computation (swings, structure, ATR, ROC, ER,
ADX, shadows) use **Bid-based OHLC** — the standard MT5 chart series — for both HTF and
LTF, and use completed bars only.

Execution uses Ask (long) / Bid (short) per §14. Spread is accounted for explicitly by
the §19 filter and the §21 execution model, never by mixing series.

### 10.5 Retracement abandonment — deterministic conditions

An in-progress setup (retracement not yet resulting in a valid BOS) is discarded — the
setup low/high is cleared, the frozen protected level (§9.5) is released, and the pipeline
returns to waiting for a fresh retracement — when any one of the following occurs:

**A. STRUCTURAL INVALIDATION.** A confirmed LTF close occurs beyond the frozen protected
level itself — price closes below the frozen protected low for a long setup, or above the
frozen protected high for a short setup. The retracement has gone deep enough to
invalidate the very structure the setup depends on.

> *Buffer asymmetry, deliberate (v0.7, M-5):* this test uses the **unbuffered** level,
> whereas HTF structure invalidation (§5.2/§5.3) uses `Structural_Break_Buffer`. The
> asymmetry is intentional and must not be "harmonised" by an implementer. A setup is
> cheap to abandon and re-form, so it resets on the tighter, faster test; HTF structure is
> expensive to flip and gets the buffered, slower test. There is consequently a live window
> in which a setup is abandoned while `STRUCTURE_STATE` is still `BULLISH` — that is
> correct and expected.

**B. NEW HIGH BEFORE BOS (long) / NEW LOW BEFORE BOS (short).** A confirmed LTF swing high
forms ABOVE the current structural high (the level the setup is waiting to break) before a
valid BOS has fired. The "structural high" reference itself is stale — the setup is
abandoned, and structure detection restarts fresh from the new confirmed high as the next
candidate structural reference. Mirror for shorts against the structural low.

**C. TIMEOUT.** The retracement has persisted for more than `MaxRetracementBars`
(configurable, LTF bars) without producing a valid BOS. Counted from
`ACTIVE_SETUP_START_BAR` (§22.1), inclusive of the setup-low bar.

**D. HTF_STATE CHANGE.** `HTF_STATE` (per the frozen snapshot in effect, §4.4) changes
away from the direction the setup requires — e.g. moves to `NEUTRAL` or `BEARISH` while a
long setup is in progress. Evaluated only at LTF bar boundaries, consistent with the
freeze rule.

Equal-low / equal-high formations during a retracement (multiple bars at the same price
extreme) do NOT by themselves trigger abandonment — they are handled purely by the swing
tie-breaking rule (§4.1), which already prevents any of the tied bars from qualifying as a
new pivot.

Abandonment is a pipeline reset only. It does not close any open position — a setup being
abandoned pre-BOS means no position exists yet, by definition.

---

## 11. BOS Definition

### 11.1 Bullish BOS (conditions written out in v0.7 — fixes M-6)

A bullish BOS fires on a completed LTF bar when **all** of the following hold:

1. `LTF_Close > StructuralHigh + BOS_Break_Distance`
2. A valid long setup exists per §10.1 — `setup_low` established, location valid (§9.3).
3. The setup has not been abandoned on this bar per §10.5 (abandonment is evaluated
   first; see the §22.2 pipeline order).
4. `setup_low` has not been broken since it formed — no completed LTF close below
   `setup_low` between the setup-low bar and the break candle.
5. The break candle is strictly after the setup-low bar (a single bar cannot be both).
6. `BOS_ID` (§11.4) differs from `LAST_TRADED_BOS_ID`.

`StructuralHigh` is the most recent confirmed LTF swing high (§4.1) that precedes the
current retracement — the level the pullback is expected to break to continue the trend.

### 11.2 Bearish BOS

Mirror, written out rather than implied:

1. `LTF_Close < StructuralLow − BOS_Break_Distance`
2. A valid short setup exists per §10.2 — `setup_high` established, location valid.
3. The setup has not been abandoned on this bar per §10.5.
4. `setup_high` has not been broken since it formed.
5. The break candle is strictly after the setup-high bar.
6. `BOS_ID != LAST_TRADED_BOS_ID`.

`StructuralLow` is the most recent confirmed LTF swing low preceding the current
retracement. (v0.6 used this identifier in §16.5a without ever defining it.)

### 11.3 BOS break distance

```
BOS_Break_Distance = max(BOS_MinimumPoints, LTF_ATR × BOS_ATR_Multiplier)
```

`LTF_ATR` per §37. `BOS_MinimumPoints` is distinct from `SL_MinimumPoints` and
`Structural_MinimumPoints` per §35.

### 11.4 BOS identification

```
BOS_ID = Symbol + Timeframe + ReferenceLevelTimestamp + BreakCandleTimestamp
```

`LAST_TRADED_BOS_ID` is stored persistently. The same BOS event cannot generate multiple
trades.

---

## 12. Momentum Classification

### 12.1 Direction-signed classification (corrected in v0.7 — fixes B-1)

Momentum is classified on a **direction-signed** value, so that a threshold means the same
thing for both trade directions:

```
Directional_ROC = +ROC   for a long setup
Directional_ROC = −ROC   for a short setup
```

```
STRONG:   Directional_ROC >= ROC_STRONG_THRESHOLD
WEAK:     ROC_NEGATIVE_THRESHOLD < Directional_ROC < ROC_STRONG_THRESHOLD
NEGATIVE: Directional_ROC <= ROC_NEGATIVE_THRESHOLD
```

> *Why this changed:* v0.6 compared raw signed `ROC` against these thresholds. A short
> setup entering a healthy bearish impulse produces a large negative `ROC` and was
> therefore classified `NEGATIVE → REJECT` — the stronger the move in the trade's
> favour, the more certain the rejection. Symmetrically, a short entering into a rally
> scored `STRONG` and received the larger risk allocation. The bug rejects ~100% of short
> entries with no external symptom beyond a `momentum_reject` funnel line, which is
> exactly the "wrong-but-plausible" failure mode the staged roadmap exists to catch.

Bands are exhaustive and mutually exclusive given §38's
`ROC_STRONG_THRESHOLD > ROC_NEGATIVE_THRESHOLD` check.

### 12.2 Confidence and risk mapping

```
STRONG   → HIGH_CONFIDENCE → risk = HighConfidenceRiskPercent
WEAK     → LOW_CONFIDENCE  → risk = LowConfidenceRiskPercent
NEGATIVE → REJECT
```

### 12.3 Threshold assignment

`ROC_NEGATIVE_THRESHOLD` must be explicitly assigned before coding (§32). It is normally
a small negative percent — momentum flat-to-slightly-against the trade direction — and is
compared against `Directional_ROC`, so the same value applies to both directions.

### 12.4 ROC formula

ROC is a CLOSE-TO-CLOSE PERCENT return, computed on the LTF:

```
ROC = (Close[0] − Close[ROC_Period]) / Close[ROC_Period] × 100
```

`Close[0]` = most recently completed LTF candle's close. `ROC_Period` = configurable
number of completed LTF bars back. Requires `ROC_Period + 1` completed LTF bars; before
that, momentum is unavailable and the entry is rejected as `momentum_reject`
(insufficient data), logged as such.

Not log return, not a points-based (absolute price) measure — percent return specifically,
so the same threshold values remain meaningful across instruments with different price
scales.

---

## 13. Stop Loss

```
Long:  Initial_SL = Setup_Low  − SL_Buffer
Short: Initial_SL = Setup_High + SL_Buffer

SL_Buffer = max(SL_MinimumPoints, LTF_ATR × SL_ATR_Multiplier)
```

`SL_MinimumPoints` is distinct from `BOS_MinimumPoints` per §35. Broker minimum stop
distance is applied afterwards per §36.2.

---

## 14. Entry Execution

Signal price: completed LTF candle close (Bid series, §10.4). Long fills at Ask, short at
Bid. `MaximumSlippage` configurable; excess deviation → reject order and count
`REJECT_slippage`.

---

## 15. Position Size (corrected in v0.7 — fixes B-2)

```
Account_Risk       = Account_Equity × RiskPercent / 100      (account currency)
StopDistancePrice  = |Entry − Initial_SL|                    (price units)
StopDistanceTicks  = StopDistancePrice / SYMBOL_TRADE_TICK_SIZE
RiskPerLot         = StopDistanceTicks × SYMBOL_TRADE_TICK_VALUE   (account currency per lot)
RawLots            = Account_Risk / RiskPerLot
Lots               = floor(RawLots / LotStep) × LotStep
```

then clamped and validated against broker constraints:

- `Lots > SYMBOL_VOLUME_MAX` → clamp to `SYMBOL_VOLUME_MAX` (logged; the trade carries
  less than the configured risk, which is safe).
- `Lots < SYMBOL_VOLUME_MIN` → **reject the trade**, count `REJECT_position_size`.
  Never round up to min lot — that silently over-risks the account, which is the one
  direction of error this spec does not tolerate.
- `RiskPerLot <= 0` (zero tick value, zero stop distance, or missing symbol info) →
  reject the trade and log the offending symbol property. Never divide.

> *Why this changed:* v0.6's `Account_Risk / |Entry − Initial_SL|` divides currency by a
> price difference and yields "currency per price unit", not lots. It is only accidentally
> correct where `TickValue / TickSize` happens to equal 1. On FX, metals and indices it is
> wrong by a large constant factor in either direction.

---

## 16. Exit Architecture

### 16.1 Active stop (corrected in v0.7 — fixes M-2)

```
Long:  ACTIVE_STOP = max(Initial_Stop, Breakeven_Stop, Trailing_Stop)
Short: ACTIVE_STOP = min(Initial_Stop, Breakeven_Stop, Trailing_Stop)
```

Candidates that have not yet armed are excluded from the comparison, not treated as zero.
The stop never widens — this is an invariant, and any attempted move against the trade is
logged as a hard error (roadmap Stage 9d). Matches the §25 step 6 ratchet exactly.

### 16.2 Trailing stop activation

Trailing arms the first time `MFE_R >= TrailingActivationR` (e.g. `+1R`). Before
activation, the trailing candidate does not exist and `ACTIVE_STOP` is decided by the
initial and breakeven candidates only. Activation is one-way — once armed, trailing stays
armed for the life of the position.

### 16.2a MFE in R (defined in v0.7 — fixes M-4)

```
Long:  MFE_R = (HighestPriceSinceEntry − Entry_Price) / (Entry_Price − Initial_Stop)
Short: MFE_R = (Entry_Price − LowestPriceSinceEntry) / (Initial_Stop − Entry_Price)
```

The denominator is the **initial** stop distance, captured at entry and frozen for the
life of the position. It must not track `ACTIVE_STOP` — if it did, R would inflate as the
stop ratchets and both activation thresholds would drift, making activation timing
implementation-dependent.

`HighestPriceSinceEntry` / `LowestPriceSinceEntry` are updated from completed-bar
high/low only, in §25 step 2.

### 16.3 Breakeven logic (activation defined in v0.7 — fixes M-3)

Breakeven arms the first time `MFE_R >= BreakevenActivationR`. Once armed:

```
Long candidate stop  = Entry_Price − Breakeven_Buffer
Short candidate stop = Entry_Price + Breakeven_Buffer
```

The buffer sits on the losing side of entry, which avoids a spread-noise stop-out at exact
breakeven. Activation is one-way. `Breakeven_Buffer` is a configured point value.

If both breakeven and trailing are enabled, `ACTIVE_STOP` is the most protective of
`{initial_stop, breakeven_stop, trailing_stop}` per §16.1.

### 16.4 Trailing stop formula (`Average_LTF_Shadow` defined in v0.7 — fixes B-6)

```
TrailDistance = max(Average_LTF_Shadow × TrailShadowMultiplier,
                    LTF_ATR × TrailATRMultiplier)

Long:  Trailing_Stop = HighestPriceSinceEntry − TrailDistance
Short: Trailing_Stop = LowestPriceSinceEntry  + TrailDistance
```

`Average_LTF_Shadow` is the arithmetic mean, over the last `ShadowLookbackBars`
**completed** LTF bars, of the shadow on the side the trade is trailing from:

```
Long  (trailing from highs): upper shadow = High − max(Open, Close)
Short (trailing from lows):  lower shadow = min(Open, Close) − Low
```

The still-forming bar is never included, consistent with §37. Ratchet only.

### 16.5 Opposing BOS exit

A full opposing BOS on a completed LTF candle → close. Event-based, independent of the
active stop.

### 16.5a Failed-breakout exit (priority over opposing BOS on the same bar)

Applies only before trailing has activated (§16.2).

```
Long:  Close < StructuralHigh (the broken level) → close immediately.
Short: Close > StructuralLow  (the broken level) → close immediately.
```

`StructuralHigh` / `StructuralLow` per §11.1 / §11.2 — the level the entry BOS broke,
frozen at entry.

**SAME-BAR PRIORITY:** if both the failed-breakout condition and a full opposing-BOS
condition would independently trigger on the same completed LTF candle, the
FAILED-BREAKOUT EXIT TAKES PRIORITY and is the one recorded. The opposing-BOS check is not
evaluated at all on a bar where the failed-breakout exit has already fired — the
evaluation order in §25 enforces this, and a resulting exit short-circuits the remaining
checks for that bar. This guarantees a single, unambiguous `exit_reason` per trade even
when multiple conditions would technically qualify simultaneously.

### 16.6 Regime decay

Not a forced exit in v1. `CHOPPY` blocks new entries only.

---

## 17. Account-Level Risk Controls

### 17.1 Maximum daily loss

Exceeded → no new trades until the next trading day. The day boundary is defined in §36.4.

### 17.2 Maximum consecutive losses

Exceeded → `COOLDOWN_STATE = ACTIVE`.

### 17.3 Cooldown exit condition

Trading resumes only after ALL of:

1. A new structural setup forms.
2. A new setup low/high exists.
3. A new structural REFERENCE LEVEL — the price level itself, not just the break-candle
   timestamp — differs from the losing trade's.
4. A new BOS event occurs against that new reference level.
5. `BOS_ID != LAST_TRADED_BOS_ID`.

Condition 5 is implied by 3 and 4 but is retained as an explicit, cheap backstop against a
subtly wrong reference-level comparison.

### 17.4 Position limits

Max 1 open position per symbol (v1).

---

## 18. Session Filter

Timezone-aware (`Asia/Tokyo`, `Europe/London`, `America/New_York`), converted to broker
server time with automatic DST handling.

### 18.1 Session evaluation timing (written out in v0.7 — fixes E-5)

Session validity is evaluated on the **completed bar's CLOSE timestamp**, never its open
timestamp. A bar that opens inside a session window but closes outside it is rejected; a
bar that opens outside and closes inside is accepted. This single rule removes the
boundary-candle ambiguity, and is what §39 test #4 verifies.

Windows are configured in the session's own timezone as `[start, end)` — start inclusive,
end exclusive — and converted to broker server time per bar, so DST shifts are handled
without reconfiguration.

---

## 19. Spread Filter

```
Reject if Spread > MaximumAllowedSpread
Reject if NormalizedSpread = Spread / LTF_ATR > MaximumNormalizedSpread
```

Both are evaluated at the moment of order submission, not at bar close, since spread can
widen between the two (§39 test #9).

---

## 20. News Filter

MT5 Economic Calendar (live). In backtest: OFF unless historical news data is loaded.
The filter's state (on/off/unavailable) is logged on every run so a backtest can never be
silently compared against a live run with different news behaviour.

---

## 21. Execution Model

Must account for spread, commission, slippage, and broker execution mode. No
zero-slippage backtest assumptions.

---

## 22. Event Evaluation Model

### 22.1 Persistent state

```
STRUCTURE_STATE (frozen per §4.4), REGIME_STATE, POSITION_STATE, COOLDOWN_STATE,
LAST_TRADED_BOS_ID, ACTIVE_SETUP_FROZEN_LEVEL,
ACTIVE_SETUP_START_BAR                (supports §10.5.C timeout tracking),
ACTIVE_SETUP_STRUCTURAL_HIGH_OR_LOW   (supports §10.5.B check),
LAST_PROCESSED_BAR_TIME               (§36.1 bar-processed-once guard),
ENTRY_INITIAL_STOP_DISTANCE           (frozen at entry, §16.2a MFE_R denominator),
TRAILING_ARMED, BREAKEVEN_ARMED       (one-way activation flags, §16.2/§16.3)
```

### 22.2 Evaluation pipeline (per completed LTF bar) — **normative order**

This is the single normative ordering. §23, §24, §31 and the roadmap's funnel counter all
follow it exactly; where v0.6's §23 disagreed, §23 was wrong (M-1).

```
 0a. Position already open?          → manage per §25, then STOP
 0b. Position closed this bar (§22.3)? → STOP
  1. Session check (bar close timestamp, §18.1)
  2. Spread check (§19)
  3. Daily risk check (§17.1)
  4. Cooldown check (reference-level comparison, §17.3)
  5. Read frozen HTF_STATE snapshot for this bar (§4.4)
  6. HTF structure check (against frozen snapshot)
  7. HTF regime check (against frozen snapshot)
  8. Retracement abandonment check (§10.5) — if abandoned, clear setup state and
     continue to step 9 as if no setup were in progress
  9. LTF setup detection (§9.5 — freeze protected level if new setup)
 10. Location validation (§9.3)
 11. BOS detection (§11.1/§11.2)
 12. BOS break distance validation (§11.3)
 13. Momentum classification (Directional_ROC per §12.1/§12.4)
 14. Position risk determination (§12.2)
 15. Entry validation (§14, §15, §36.2)
 16. Execute trade
```

Each gate that rejects increments exactly one funnel counter, attributed to the **first**
gate that rejects the bar (roadmap, cross-cutting rule).

### 22.3 Same-bar close-then-reentry rule

If an open position is closed during trade management (§25) on a given completed bar, the
entry pipeline does not also evaluate on that same bar.

---

## 23. Long Entry Algorithm

Follows §22.2 exactly (reordered in v0.7 — fixes M-1).

```
ON NEW COMPLETED LTF BAR:
  IF position already open:                      STOP (manage per §25)
  IF this bar just closed a position (§22.3):     STOP
  IF session invalid (§18.1):                     STOP
  IF spread invalid (§19):                        STOP
  IF daily risk limit reached (§17.1):            STOP
  IF cooldown active (§17.3):                     STOP

  Snapshot frozen HTF_STATE for this bar (§4.4).
  IF frozen STRUCTURE_STATE != BULLISH:           STOP
  IF frozen REGIME_STATE == CHOPPY:               STOP

  Check retracement abandonment (§10.5); if abandoned, clear setup.
  Detect/continue valid LTF pullback.
  Identify LTF setup low; freeze protected level if new setup (§9.5).
  Calculate distance(setup_low, frozen HTF_protected_low) (§9.2).
  IF location invalid (§9.3):                     STOP

  Detect bullish BOS (§11.1).
  IF BOS invalid:                                 STOP
  IF BOS break distance invalid (§11.3):          STOP

  Classify Directional_ROC momentum (§12.1, §12.4).
  IF momentum == NEGATIVE:                        STOP

  Determine confidence tier → risk % (§12.2).
  Calculate structural stop (§13).
  Calculate position size (§15); IF below min lot: STOP.
  Validate execution conditions (§14, §36.2).
  Submit market buy order.
  Store BOS_ID; freeze ENTRY_INITIAL_STOP_DISTANCE and StructuralHigh.
```

## 24. Short Entry Algorithm

Mirror of §23, with these non-obvious mirrors stated explicitly rather than left to the
reader:

- `STRUCTURE_STATE` must be `BEARISH`; relevant level is the frozen HTF protected high.
- Setup reference is `setup_high`; BOS is bearish per §11.2 against `StructuralLow`.
- Momentum uses `Directional_ROC = −ROC` (§12.1) — **not** a sign-flipped threshold pair.
- `Initial_SL = Setup_High + SL_Buffer` (§13); fills at Bid (§14).

---

## 25. Trade Management Algorithm

For every open position, each completed bar, IN THIS ORDER:

```
1. Detect exits:
   a. Failed-breakout exit check (§16.5a) — evaluated first.
      If it fires: record exit_reason = failed_breakout, close position,
      SKIP remaining exit checks for this bar (priority rule, §16.5a).
   b. If not closed: active stop check (§16.1) — if price has crossed
      ACTIVE_STOP, close, record exit_reason accordingly
      (initial_stop / breakeven_stop / trailing_stop, by which candidate
      is currently the active one).
   c. If not closed: opposing BOS check (§16.5) — if a full opposing BOS
      confirmed this bar, close, record exit_reason = opposing_bos.
2. If position still open, update MFE using this bar's high/low (§16.2a).
3. Check breakeven activation (§16.3) — if MFE_R crosses BreakevenActivationR
   for the first time, arm breakeven and compute its candidate stop.
4. Check trailing activation (§16.2) — if MFE_R crosses TrailingActivationR
   for the first time, mark trailing as active.
5. If trailing active, compute new trailing stop candidate (§16.4).
6. Ratchet: ACTIVE_STOP = most protective of {initial, breakeven candidate,
   trailing candidate} — never move against the trade.
```

If an exit occurred in step 1, mark this bar per §22.3 and skip steps 2–6 (position no
longer open).

> *Ordering rationale (made explicit in v0.7):* exits are detected against the **previous**
> bar's `ACTIVE_STOP`, before MFE is updated with this bar's high/low. This is intentional.
> Evaluating in the other order would require knowing whether the bar's extreme occurred
> before or after the stop was touched — intrabar path information that a bar-close model
> does not have, and the single largest source of two implementations disagreeing on
> trailing exits.

---

## 26. Trade Logging

```
PRD_Version, EA_Build, Parameter_Hash (hash of the full active parameter set at time
of trade; enables regression testing across versions),
Trade ID, BOS ID, Symbol, HTF, LTF, Entry Timestamp, Exit Timestamp,
HTF Structure State (frozen value used), HTF ER, HTF ADX,
HTF Protected Level (frozen value used), LTF Setup Low/High,
Normalized Location Distance, Structural Reference,
BOS Break Distance, ROC (raw signed, §12.4), Directional_ROC (§12.1), Momentum State,
Confidence Tier, Spread, Entry Price, Initial Stop, Initial Stop Distance,
Trailing Stop, Exit Price,
Exit Reason (initial_stop / breakeven_stop / trailing_stop / opposing_bos /
             failed_breakout),
Position Size, Risk Percent, Realized R, Realized P/L, MAE, MFE, MFE_R,
Session, News Filter State,
Abandonment_Events_This_Setup (count — how many times §10.5 reset the setup before
this trade's eventual BOS; useful for tuning MaxRetracementBars and diagnosing choppy
pre-entry conditions)
```

Both raw `ROC` and `Directional_ROC` are logged (v0.7): the raw value is what a human
reads off a chart, the directional value is what the classifier actually used, and having
both makes a §12.1 regression immediately visible.

---

## 27. Performance Metrics

Expectancy (in R), AvgWin R, AvgLoss R, Profit Factor, Max Drawdown, Recovery Factor,
Sharpe/risk-adjusted metric, Consecutive Losses, Trade Frequency, MAE, MFE. Trade
frequency is informational only. Failed-breakout exits are tracked as their own category.

---

## 28. Backtesting Protocol

Stages: Development/In-Sample → Validation → Out-of-Sample → Walk-Forward → Forward
Testing.

### 28.1 Parameter stability testing (written out in v0.7 — fixes E-5)

For each calibrated parameter, sweep a neighbourhood around the optimum — at minimum
±2 steps at the sweep's own granularity — and require a **plateau**, not a spike:
neighbouring values must retain positive expectancy, and the optimum must not exceed its
neighbours' mean by more than roughly one standard deviation of the neighbourhood. An
isolated peak is treated as an overfit artifact and the parameter is set to the centre of
the nearest stable plateau instead.

### 28.2 Calibration budget (reconciled in v0.7 — fixes M-8)

Two disjoint classes:

**Calibrated (7) — swept, and subject to §28.1 stability testing:**
`ER_LOW`, `ER_HIGH`, `LocationThreshold`, `BOS_ATR_Multiplier`,
`ROC_STRONG_THRESHOLD`, `TrailingActivationR`, `MaxRetracementBars`.

**Fixed default (sanity-tested, deliberately not optimized):** everything else in §32 —
`SwingConfirmationBars`, ATR/ADX/ER/ROC periods, `ADX_THRESHOLD`, all `*_MinimumPoints`,
`Structural_Break_ATR_Multiplier`, `SL_ATR_Multiplier`, `TrailShadowMultiplier`,
`TrailATRMultiplier`, `ShadowLookbackBars`, `BreakevenActivationR`, `Breakeven_Buffer`,
risk percents, and all account-level limits.

v0.6 said "~6-7 calibrated" while the roadmap's Group A–D lists named 13+ parameters to
optimize. The split above is the reconciliation: Groups A–D remain the *sequencing* of
work, but only the seven parameters above are swept.

### 28.3 Staged group optimization (written out in v0.7 — fixes E-5)

Optimize sequentially by group, never jointly: **A** structure/regime → **B** entry →
**C** exit → **D** risk. After each group, freeze its winners before starting the next,
and re-check the funnel counter for a collapse toward zero entries as a side effect. A
group that improves in-sample expectancy while collapsing the funnel is rejected
regardless of its score.

`MaxRetracementBars` (§10.5.C) is classified under Group B (Entry).

---

## 29. Version 1 Scope (written out in v0.7 — fixes E-6)

**In scope:** pullback continuation only (§8); one symbol, one fixed HTF/LTF pair per run
(§3); max one open position per symbol (§17.4); market orders only (§14); the exit set in
§16.1–16.5a; account-level controls in §17; session, spread and news filters (§18–§20);
full logging in §26.

**Out of scope, deferred:** breakout continuation (§8); multi-symbol and portfolio-level
risk; pending/limit order entry; partial closes, scale-ins and pyramiding; regime-decay
forced exits (§16.6); adaptive or auto-tuned parameters.

Retracement abandonment (§10.5) and HTF/LTF sync (§4.4) are **core v1 mechanics, not
deferred features** — without them the spec is not actually deterministic.

---

## 30. Final Design Principles

1. Structure determines direction.
2. Regime determines tradeability.
3. Location determines contextual relevance (frozen at setup formation).
4. BOS determines the entry event.
5. Momentum determines trade quality/sizing — measured in the trade's own direction.
6. Risk is determined before entry.
7. Stops are structural.
8. Stops never widen.
9. The same BOS cannot generate multiple trades.
10. A failed breakout is invalidated immediately, not held at full risk.
11. HTF state is frozen per LTF bar — it cannot change mid-evaluation.
12. Every ambiguous condition (ties, simultaneous exits, abandonment) resolves to exactly
    one deterministic outcome.
13. New complexity requires statistical justification.
14. Parameter stability is more important than historical peak performance.
15. Out-of-sample performance is more important than in-sample optimization.

---

## 31. Final Strategy Flow

```
COMPLETED LTF BAR
  → Position open? YES → manage (§25: failed-breakout → active stop → opposing BOS
                                 → MFE → breakeven → trailing → ratchet)
  → Position just closed this bar? YES → STOP (no re-entry this bar)
  → Session / spread / daily risk / cooldown valid? NO → STOP
  → Snapshot frozen HTF_STATE (§4.4); structure + regime valid? NO → STOP
  → Retracement abandonment check (§10.5); reset if needed
  → Valid LTF pullback + location (frozen level)? NO → WAIT
  → Valid BOS + break distance? NO → WAIT / REJECT
  → Momentum (Directional_ROC, §12.1): STRONG → full risk | WEAK → reduced
                                        | NEGATIVE → REJECT
  → Calculate stop → position size → validate execution → ENTER TRADE
```

Gate order matches §22.2 (v0.7 — fixes M-1).

---

## 32. Parameter Table — Implementation Readiness Requirement

Every parameter below must be individually assigned before coding. Replaces v0.6's
"all prior parameters, plus…" note, which never resolved to a complete list.

| Parameter | § | Class | Notes |
|---|---|---|---|
| `HTF`, `LTF` | 3 | Fixed | HTF minutes > LTF minutes, integer multiple |
| `SwingConfirmationBars` (K) | 4.1 | Fixed | Sanity-test K ∈ {2,3,5} |
| `Structural_Break_ATR_Multiplier` | 5.4 | Fixed | **New in v0.7 (B-5)** |
| `Structural_MinimumPoints` | 5.4, 35 | Fixed | **New in v0.7 (B-4)** |
| `HTF_ATR_Period` | 37 | Fixed | Wilder |
| `LTF_ATR_Period` | 37 | Fixed | Wilder; independent of HTF |
| `ER_Lookback` (N) | 7.1 | Fixed | ≥ 2 |
| `ER_LOW`, `ER_HIGH` | 7.2 | **Calibrated** | Per-instrument, §7.4 procedure |
| `ADX_Period` | 7.2 | Fixed | |
| `ADX_THRESHOLD` | 7.2 | Fixed | Default 20 |
| `LocationThreshold` | 9.3 | **Calibrated** | Start loose (roadmap Stage 5) |
| `MaxRetracementBars` | 10.5.C | **Calibrated** | Group B |
| `BOS_ATR_Multiplier` | 11.3 | **Calibrated** | Group B |
| `BOS_MinimumPoints` | 11.3, 35 | Fixed | **Renamed in v0.7 (B-4)** |
| `ROC_Period` | 12.4 | Fixed | |
| `ROC_STRONG_THRESHOLD` | 12.1 | **Calibrated** | vs `Directional_ROC` |
| `ROC_NEGATIVE_THRESHOLD` | 12.1, 12.3 | Fixed | Small negative; vs `Directional_ROC` |
| `SL_ATR_Multiplier` | 13 | Fixed | |
| `SL_MinimumPoints` | 13, 35 | Fixed | **Renamed in v0.7 (B-4)** |
| `MaximumSlippage` | 14 | Fixed | |
| `HighConfidenceRiskPercent` | 12.2 | Fixed | ≤ risk ceiling (§38) |
| `LowConfidenceRiskPercent` | 12.2 | Fixed | ≤ `HighConfidenceRiskPercent` |
| `TrailingActivationR` | 16.2 | **Calibrated** | Group C |
| `BreakevenActivationR` | 16.3 | Fixed | **Defined in v0.7 (M-3)** |
| `Breakeven_Buffer` | 16.3 | Fixed | Points, losing side |
| `TrailShadowMultiplier` | 16.4 | Fixed | |
| `TrailATRMultiplier` | 16.4 | Fixed | |
| `ShadowLookbackBars` | 16.4 | Fixed | **New in v0.7 (B-6)** |
| `MAX_DAILY_LOSS` | 17.1 | Fixed | |
| `MAX_CONSECUTIVE_LOSSES` | 17.2 | Fixed | |
| Session windows + timezone | 18 | Fixed | `[start, end)` |
| `MaximumAllowedSpread` | 19 | Fixed | |
| `MaximumNormalizedSpread` | 19 | Fixed | |
| `BrokerStopDistanceMode` | 36.2 | Fixed | `WIDEN` \| `REJECT` |

---

## 33. Definition of Completion (v1)

1. Every stage in [`roadmap.md`](roadmap.md) has passed its own Definition of Done.
2. The full §39 test list passes.
3. The signal funnel counter is fully populated end-to-end and internally consistent with
   each stage's independent diagnostics.
4. Out-of-sample expectancy is positive over ≥ 100 out-of-sample trades.
5. Every calibrated parameter sits on a stable plateau per §28.1.
6. "Stops never widen" shows zero violations over the full test window.
7. Parameter hash changes whenever any input parameter changes.
8. Exit-reason distribution is plausible — not ~100% any single reason.
9. Demo/forward test completed before any real capital (§34).
10. `PRD_Version`, `EA_Build` and `Parameter_Hash` appear on every trade record.
11. Both LONG and SHORT permitted-bar counts and entry counts are nonzero over a window
    spanning both up and down markets (v0.7 — this is the direct regression guard for B-1).
12. Swing tie-breaking (§4.1) verified against a synthetic equal-high/equal-low test case.
13. HTF/LTF freeze (§4.4) verified against a synthetic case where an HTF candle completes
    mid-LTF-bar.
14. Retracement abandonment (§10.5) verified against all four conditions (A–D)
    independently in synthetic test data.
15. Same-bar failed-breakout/opposing-BOS priority (§16.5a) verified against a synthetic
    case where both would independently fire.
16. Parameter validation (§38) verified to reject every listed invalid-input case at
    startup.

---

## 34. Recommended Next Step

Implement in this order: §4 (structure/BOS/setup-low chain, including tie-breaking and HTF
freeze) → §10.5 (abandonment) → §9 (location/freeze) → §37/§38 (ATR/ROC/ER math + startup
validation) → §16 (exit architecture including failed-breakout priority) → §25/§26
(management sequencing + logging). Then the first calibration pass.

A live/demo shadow test is the required final check before real capital.

The staged breakdown of this ordering, with per-stage Definitions of Done, is
[`roadmap.md`](roadmap.md).

---

## 35. Buffer Parameter Disambiguation

| Buffer | Scale | Floor | Multiplier | Used by |
|---|---|---|---|---|
| `Structural_Break_Buffer` | HTF_ATR | `Structural_MinimumPoints` | `Structural_Break_ATR_Multiplier` | §5.2 / §5.3 HTF invalidation |
| `BOS_Break_Distance` | LTF_ATR | `BOS_MinimumPoints` | `BOS_ATR_Multiplier` | §11.3 BOS trigger |
| `SL_Buffer` | LTF_ATR | `SL_MinimumPoints` | `SL_ATR_Multiplier` | §13 stop-loss placement |

**Never share a parameter or calculation between these three, despite the identical
formula shape.** v0.6 violated its own rule by sharing a single `MinimumPoints` across the
BOS and SL buffers; v0.7 splits it into the three floors above (B-4).

---

## 36. MQL5 Execution Guards

### 36.1 Bar-processed-once guard

Store the last fully-processed bar timestamp per symbol+timeframe
(`LAST_PROCESSED_BAR_TIME`, §22.1); skip pipeline evaluation unless the current bar is
strictly newer.

### 36.2 Broker minimum stop distance

Check `SYMBOL_TRADE_STOPS_LEVEL`. If the ATR-derived SL is closer than allowed, either
widen to the broker minimum (logged) or reject the trade — an explicit configurable
choice, `BrokerStopDistanceMode`. Widening changes the risk denominator, so position size
(§15) must be recomputed against the widened stop, not the original.

### 36.3 Gap/slippage acknowledgment

`ACTIVE_STOP` is a price level, not a guaranteed fill. Gaps can exceed the configured
risk %. This is documented, not mitigated, in v1.

### 36.4 Daily-loss day boundary

Broker server 00:00 rollover, used consistently across all daily-boundary logic.

---

## 37. ATR Specification

All ATR values in this specification (`LTF_ATR`, `HTF_ATR`) use **Wilder's smoothing
method** — the standard MT5 `iATR` calculation — not a simple moving average of True
Range.

```
TR[i]  = max(High[i] − Low[i],
             |High[i] − Close[i−1]|,
             |Low[i]  − Close[i−1]|)

ATR[p]     = mean(TR[1..p])                        (seed: simple mean of first p TRs)
ATR[i]     = (ATR[i−1] × (p − 1) + TR[i]) / p      (Wilder recursion thereafter)
```

ATR period is independently configurable per use (`LTF_ATR_Period`, `HTF_ATR_Period`) —
they are NOT required to share a period value even though both use Wilder's method.

ATR is computed using COMPLETED bars only. The current, still-forming bar's range is never
included in any ATR value used for a buffer (§35) or a normalization (§9.3, §19) in this
spec. ATR requires `p + 1` completed bars (the first TR needs a previous close); before
that ATR is unavailable and every gate depending on it rejects with an explicit
insufficient-data reason.

---

## 38. Parameter Validation / Fail-Fast Startup Checks

The EA must validate all configured parameters at startup (`OnInit`) and refuse to run
(return `INIT_PARAMETERS_INCORRECT` or equivalent) if any of the following hold, rather
than exhibiting undefined behaviour at runtime:

**Carried from v0.6:**

- Any ATR multiplier (`BOS_ATR_Multiplier`, `SL_ATR_Multiplier`, `TrailATRMultiplier`,
  `TrailShadowMultiplier`) `<= 0`
- `LocationThreshold <= 0`
- `ER_HIGH <= ER_LOW`
- `ROC_STRONG_THRESHOLD <= ROC_NEGATIVE_THRESHOLD`
- `SwingConfirmationBars < 1`
- `MaxRetracementBars < 1`
- Any configured risk percent (`HighConfidenceRiskPercent`, `LowConfidenceRiskPercent`)
  `<= 0` or `>` a sane account-risk ceiling (e.g. 5%) — treated as a likely input error,
  not a valid aggressive setting
- `LowConfidenceRiskPercent > HighConfidenceRiskPercent` (inverted tiers)
- Invalid or unrecognized session configuration (unknown timezone identifier,
  `start >= end` within a single session window)
- `MaximumSlippage < 0`
- `TrailingActivationR < 0`, or `BreakevenActivationR < 0` when breakeven is enabled
- `MAX_DAILY_LOSS <= 0` or `MAX_CONSECUTIVE_LOSSES <= 0`

**Added in v0.7 (M-10, B-4, B-5, B-6):**

- `HTF` period in minutes `<=` `LTF` period in minutes, or not an integer multiple of it (§3)
- `ER_Lookback < 2` (§7.1 — the sum is empty at `N < 1` and degenerate at `N = 1`)
- `ROC_Period < 1` (§12.4)
- `LTF_ATR_Period < 1` or `HTF_ATR_Period < 1` (§37)
- `ADX_Period < 1` or `ADX_THRESHOLD < 0` (§7.2)
- `Structural_Break_ATR_Multiplier <= 0` (§5.4)
- `ShadowLookbackBars < 1` (§16.4)
- `MaximumAllowedSpread <= 0` or `MaximumNormalizedSpread <= 0` (§19)
- Any of `BOS_MinimumPoints`, `SL_MinimumPoints`, `Structural_MinimumPoints` `< 0` (§35)
- `Breakeven_Buffer < 0` (§16.3)
- `BrokerStopDistanceMode` not one of `WIDEN` / `REJECT` (§36.2)

All validation failures must be logged with the **specific parameter name and the value
that failed**, not a generic startup error — this is what makes the fail-fast behaviour
actually diagnosable rather than merely preventing a bad run. Validation reports *every*
failing parameter, not just the first, so a misconfigured setup is fixed in one pass.

---

## 39. Deterministic Unit Test Checklist

Regression test set, to be built alongside implementation, not deferred to after.

1. **Equal highs / equal lows** — verify neither tied bar qualifies as a swing pivot (§4.1).
2. **Weekend gap** — verify `ACTIVE_STOP` behaviour and realized-R logging when a gap fills
   beyond the stop (§36.3).
3. **HTF rollover during an in-progress LTF setup** — verify `HTF_STATE` freeze holds until
   the correct LTF bar (§4.4).
4. **Session boundary candle** — verify session validity uses bar CLOSE timestamp, not open
   (§18.1).
5. **Broker stop-distance adjustment** — verify SL widening/rejection behaviour on a
   synthetic quiet-candle case, and that position size is recomputed against the widened
   stop (§36.2, §15).
6. **Simultaneous exit conditions** — verify failed-breakout takes priority over opposing
   BOS on the same bar (§16.5a).
7. **Cooldown release** — verify cooldown does NOT release on a retest of the same
   structural reference level, only a genuinely new one (§17.3).
8. **Repeated BOS at the same structural level** — verify `BOS_ID` uniqueness correctly
   blocks a second trade (§11.4).
9. **Spread spike** — verify entry rejection when `NormalizedSpread` exceeds threshold at
   the moment of order submission (§19).
10. **Retracement abandonment** — verify each of conditions A–D (§10.5) independently
    resets setup state without affecting an unrelated open position, if one exists.
11. **Same-bar close-then-reentry** — verify no new entry is evaluated on a bar where a
    position was just closed (§22.3).
12. **Parameter validation** — verify every case in §38 is rejected at startup with a
    specific, identifiable log message.

**Added in v0.7:**

13. **Short-side momentum** — a synthetic bearish impulse at a short BOS must classify
    `STRONG`, not `NEGATIVE` (§12.1). Direct regression guard for B-1; without it, the bug
    is invisible in any long-only test set.
14. **Position size units** — on a synthetic symbol where `TickValue / TickSize != 1`,
    verify realized risk on a stop-out equals the configured risk percent within tolerance,
    and that a sub-min-lot result rejects rather than rounds up (§15). Regression guard for B-2.
15. **ER flat window** — a constant close series must yield `ER = 0 → CHOPPY`, with no
    `inf`/`nan` reaching `REGIME_STATE` (§7.1). Regression guard for B-3.
16. **MFE_R denominator** — verify `MFE_R` is computed against the frozen initial stop
    distance and does not drift as `ACTIVE_STOP` ratchets (§16.2a).
