# Implementation Roadmap — HTF/LTF Trend-Continuation EA

**Companion to:** [`prd.md`](prd.md) (v0.7)
**Purpose:** break the PRD into independently buildable, testable, and optimizable stages.
No stage begins until the previous stage has passed its Definition of Done.

**Design principle behind this roadmap:** the original build attempt produced zero trades
across multiple backtests with no way to isolate the cause, because the full pipeline was
assembled before any single piece was individually verified. Every stage below therefore
ships with its own diagnostic output — visual chart markers, counters, or logs — so that
if a stage produces implausible results (zero, or far too many), the problem is visible at
that stage, not buried under 15 downstream gates.

> **v0.7 note.** The PRD review found two defects that would each have reproduced the
> original zero-trade failure on their own: momentum classification rejecting ~100% of
> short entries (B-1), and a position-size formula that does not yield lots (B-2). Both are
> fixed in PRD v0.7. Stage 7 and Stage 8 below now carry explicit regression checks for
> them, because both are exactly the "wrong-but-plausible" class of bug that a funnel
> counter alone shows as a number without explaining.

---

## Cross-cutting rule: the Signal Funnel Counter

From Stage 4 onward, every gate in the pipeline increments either `PASS` or
`REJECT_<gate_name>`. Each rejected bar is attributed to the **first** gate that rejects
it, in PRD §22.2's normative order. At the end of every backtest run, print the full
funnel:

```
Bars evaluated:                XX,XXX
Position open (managed):        X,XXX
Same-bar close (§22.3):            XX
Session reject:                 X,XXX
Spread reject:                    XXX
Daily-risk reject:                 XX
Cooldown reject:                  XXX
Structure reject (not BULLISH/BEARISH):  X,XXX
Regime reject (CHOPPY):         X,XXX
Setup not found:                X,XXX
Location reject:                  XXX
BOS not found:                  X,XXX
Break-distance reject:             XX
Momentum reject (NEGATIVE):        XX
Position-size reject:               X
Execution/slippage reject:          X
Entries taken:                      N
   of which LONG:                   N
   of which SHORT:                  N
```

This single artifact is the direct fix for "cause couldn't be pinned down" — if
`Entries taken = 0`, the funnel tells you exactly which gate is eating 100% of candidates,
instead of forcing a guess. Build this counter in Stage 4 and never remove it, even in the
final version.

**Two lines changed in v0.7.** The order now matches PRD §22.2 exactly (v0.6's §23 gave a
different gate order, so the funnel's attribution depended on which section you
implemented — M-1). And `Entries taken` is broken down by direction: a healthy total with
zero SHORT entries is the exact signature of the B-1 momentum bug, and an undifferentiated
total hides it completely.

---

## Stage 0 — Foundation: Math Primitives & Infrastructure

**PRD sections:** §37 (ATR), §12.4 (ROC), §7.1 (ER), §10.4 (price series), §36.1
(bar-processed-once guard), §38 (parameter validation)

**What to build**

- Wilder ATR function (LTF and HTF, independently configurable periods)
- ROC function (close-to-close percent, configurable period)
- ER function (close-price based, **including the zero-denominator rule**, §7.1)
- Bar-processed-once guard (per symbol+timeframe)
- Parameter validation / fail-fast startup checks (all cases in §38, including the 12
  added in v0.7)
- Consistent price-series access — Bid-based OHLC for signals, Ask/Bid for execution (§10.4)

No trading logic yet. This stage produces numbers, not trades.

**Definition of Done**

- ATR/ROC/ER values computed by the EA match independently-calculated reference values
  (e.g. from Python/Excel on the same historical data) to within floating-point tolerance,
  for at least 20 spot-checked bars.
- Startup validation rejects every invalid-input case in §38 with a specific logged reason
  naming the parameter and its value (test by deliberately misconfiguring each parameter
  one at a time). Validation reports every failure, not just the first.
- **New (v0.7):** ER over a constant close series returns `0.0` and classifies `CHOPPY` —
  no `inf`, no `nan` (§39 test #15).
- **New (v0.7):** ATR, ROC and ER each return an explicit "insufficient data" result rather
  than a partial-window value when fewer than the required bars are available.
- Bar-processed-once guard verified: log a counter of `OnTick` calls vs. `OnBar` (new-bar)
  events over a test run — the ratio should be large (many ticks per bar) and the bar logic
  must fire exactly once per bar.

**Diagnostic output:** a debug panel or log printing current ATR/ROC/ER values every N
bars, so they can be eyeballed against a live chart.

**Why this stage first:** every later stage's buffers, thresholds and gates depend on these
three functions. A silent error here (ATR using simple MA instead of Wilder, or ROC using
points instead of percent) would produce wrong-but-plausible-looking numbers everywhere
downstream — exactly the kind of bug that's undiagnosable once the full pipeline is running.

---

## Stage 1 — Swing Detection

**PRD sections:** §4.1 (confirmed swing + tie-breaking), §4.2–4.3 (confirmed vs. developing
structure)

**What to build**

- Swing high/low detection with `SwingConfirmationBars = K`
- Tie-breaking rule (equal highs/lows never qualify)
- Confirmed-structure storage (append-only, never retroactively modified)

**Definition of Done**

- Plot detected swing highs/lows as chart markers over a multi-month historical window.
  Manually compare against visual chart reading for at least 3 sample regions (trending,
  ranging, choppy) — markers should match what a human would circle as swing points.
- Synthetic equal-high test case (§39 test #1) passes: neither tied bar is marked a pivot.
- Count swings per week over the test window — should be a plausible, nonzero, roughly
  stable number. A sudden count of zero for an extended period, or an absurdly high count,
  both indicate a bug.
- Verify a pivot is only emitted at bar `i + K`, never at bar `i` (non-repainting, §4.1).

**Diagnostic output:** swing count per week/month, printed or charted, plus the visual
markers above.

**Parameters introduced:** `SwingConfirmationBars` (K) — fixed structural parameter, not
part of the calibration budget (§28.2), but sanity-test 2–3 values (K = 2, 3, 5) to confirm
behaviour scales sensibly before locking it in.

---

## Stage 2 — HTF Structure State & Protected Levels

**PRD sections:** §5 (STRUCTURE_STATE), §5.4 (structural break buffer), §6 (protected
structure), §4.4 (HTF/LTF freeze)

**What to build**

- Protected low/high identification and replacement logic (§6.1/6.2)
- `STRUCTURE_STATE` machine (BULLISH/BEARISH/NEUTRAL) with buffer-based invalidation
- `Structural_Break_Buffer` per §5.4 — **new in v0.7**; v0.6 used this buffer in §5.2/§5.3
  without ever giving it a formula, so an implementer had to invent one (B-5)
- HTF/LTF freeze mechanism (§4.4) — even though there's no LTF logic yet, build and test
  the freeze/snapshot mechanism now, since Stage 5+ depends on it. Freeze the *whole*
  snapshot (`STRUCTURE_STATE`, `REGIME_STATE`, protected levels, `HTF_ATR`, ER, ADX), not
  just the state enum

**Definition of Done**

- Colour-code the HTF chart background by `STRUCTURE_STATE` (green = BULLISH, red =
  BEARISH, gray = NEUTRAL) over the full historical test window. Visually verify: BULLISH
  regions correspond to periods a human would call uptrends, and transitions happen at
  plausible structural break points — not on every minor swing.
- Log `STRUCTURE_STATE` transition count over the test window. **This is the single
  highest-risk stage for the "zero trades" failure mode:** if `STRUCTURE_STATE` is stuck at
  NEUTRAL for the entire window (an off-by-one in protected-level replacement, or an
  inverted invalidation comparison), nothing downstream will ever produce a trade, and this
  stage's visual check is what catches it — not a debugging session three stages later.
- HTF/LTF freeze synthetic test (§39 test #3): construct a case where an HTF candle
  completes mid-LTF-bar, verify the LTF pipeline uses the pre-completion snapshot until the
  correct subsequent LTF bar.

**Diagnostic output:** coloured chart overlay + transition log + % of test window spent in
each state — flag immediately if NEUTRAL is > 90% or 0%.

**Parameters introduced:** `Structural_Break_ATR_Multiplier`, `Structural_MinimumPoints` —
sanity-test at a small default (e.g. 0.1 × HTF ATR) before any real optimization. Both are
fixed-default parameters (§28.2), not part of the calibration budget.

---

## Stage 3 — Regime Detection

**PRD sections:** §7.1–7.2 (ER, ADX, REGIME_STATE), §7.4 (ER calibration procedure)

**What to build**

- ER-based `REGIME_STATE` classification (STRONG/ACCEPTABLE/CHOPPY)
- ADX tie-breaker for the ambiguous ER band — note `AMBIGUOUS` is a *band*, not a fourth
  enum value (§7.2, M-7); `REGIME_STATE` has exactly three values

**Definition of Done**

- Plot ER as a sub-chart indicator alongside `REGIME_STATE` colour-coding, over the same
  test window as Stage 2.
- Log % of time in each `REGIME_STATE`. **Second highest-risk stage for zero trades:** if
  `ER_LOW`/`ER_HIGH` defaults are wrong (e.g. copied from a different instrument's typical
  ER range), `REGIME_STATE` could sit at CHOPPY almost permanently, silently blocking every
  trade regardless of how correct Stage 2's structure detection is.
- Cross-check: for periods Stage 2 marked as clean BULLISH/BEARISH trends, `REGIME_STATE`
  should skew toward STRONG/ACCEPTABLE, not CHOPPY. If trending periods show CHOPPY, the ER
  calculation or thresholds are likely wrong.

**Diagnostic output:** ER sub-chart + `REGIME_STATE` % breakdown + cross-tabulation against
Stage 2's `STRUCTURE_STATE` regions.

**Parameters introduced (first of the calibration budget, §28.2):** `ER_LOW`, `ER_HIGH` —
run the decile-bucket calibration procedure now, on real historical data, rather than
guessing defaults. The procedure is written out in PRD §7.4 (v0.6 referenced it as
"§7 background" but never described it — E-5). `ADX_THRESHOLD` and `ADX_Period` — fixed
reasonable defaults (20, 14) initially; both are fixed-default parameters, not calibrated.

---

## Stage 4 — Combined Permission Gate + Funnel Counter

**PRD sections:** §7.3 (combined permission), §22.2 (normative pipeline order)

**What to build**

- LONG permitted / SHORT permitted boolean per bar, combining Stage 2 + Stage 3 output
- The Signal Funnel Counter (see top of document) — build it now, even though most
  downstream gates don't exist yet. Starting it here means every subsequent stage adds its
  own line to an already-working counter, rather than bolting on logging at the end. Order
  the gates per §22.2, which is normative

**Definition of Done**

- Count bars where LONG is permitted, SHORT is permitted, neither — over the test window.
  Both counts should be nonzero and roughly balanced over a window spanning both up and
  down markets. A single-direction market is fine to skew this, but a multi-year window
  showing zero SHORT-permitted bars indicates a bug, not a bullish market.
- Funnel counter's `structure_reject` and `regime_reject` tallies match Stage 2/3's
  independently-computed % breakdowns — cross-check the funnel against the earlier stages'
  own diagnostics; they must agree.

**Diagnostic output:** funnel counter (partial — only a few lines populated so far),
LONG/SHORT permitted bar counts.

---

## Stage 5 — LTF Setup Detection, Location, Abandonment

**PRD sections:** §9 (location filter, now numbered 9.1–9.3), §9.5 (protected-level
freeze), §10.1–10.4 (setup definition), §10.5 (retracement abandonment)

**What to build**

- Retracement / setup-low(high) detection
- Location filter (normalized distance to frozen protected level, §9.3)
- Full abandonment logic (§10.5 conditions A–D), including the **deliberate unbuffered
  level** in condition A — do not "harmonise" it with §5.2's buffered test (M-5)

**Definition of Done**

- Mark setup-low/high formations on the LTF chart as they occur, alongside the frozen HTF
  protected level they're measured against. Spot-check 10–15 instances visually.
- Funnel counter now populates `setup_not_found` and `location_reject`.
- Log abandonment events broken down by condition (A: structural invalidation, B: new
  high/low before BOS, C: timeout, D: HTF state change). This breakdown matters: if C
  dominates, `MaxRetracementBars` is likely too tight; if B dominates, the structural-high
  reference is being invalidated unusually often, worth a closer look before tuning
  thresholds.
- Verify: setups passing location should be meaningfully fewer than setups detected, but
  not near-zero. If `location_reject` consumes nearly 100% of setups, `LocationThreshold`
  is almost certainly the culprit — very plausibly the exact failure mode in the original
  zero-trade run, since a threshold parameter with an untested default can single-handedly
  zero out the funnel here.

**Diagnostic output:** funnel counter (fuller now), abandonment-by-condition breakdown,
visual setup markers.

**Parameters introduced:** `LocationThreshold` — sanity-test at a deliberately loose value
first (2–3× a guessed reasonable value) to confirm the pipeline produces some passing
setups end-to-end, before tightening. `MaxRetracementBars` — same approach, start loose.
Both are calibrated parameters (§28.2, Group B).

---

## Stage 6 — BOS Detection

**PRD sections:** §11.1–11.4 (BOS definition, break distance, BOS ID)

**What to build**

- BOS close/break-distance check, with all six conditions from §11.1 / §11.2 — v0.7 writes
  these out; v0.6 deferred them to "§11 in prior versions", a circular reference (M-6)
- `BOS_ID` generation and uniqueness enforcement

**Definition of Done**

- Mark confirmed BOS events on the LTF chart; visually spot-check 10–15 against manual
  chart reading — do these look like genuine structural breaks to a human eye?
- Funnel counter populates `bos_not_found` and `break_distance_reject`.
- Synthetic repeated-BOS test (§39 test #8): verify a second break of the same structural
  level does not generate a duplicate `BOS_ID`/trade opportunity.
- Cross-check: BOS count should be meaningfully smaller than location-passing setup count
  (not every setup breaks out), but again — not near-zero. If it is,
  `BOS_ATR_Multiplier` (via `BOS_Break_Distance`) is the prime suspect.

**Diagnostic output:** funnel counter, visual BOS markers, `BOS_ID` collision log (should
show zero collisions/duplicates).

**Parameters introduced:** `BOS_ATR_Multiplier` (calibrated, Group B), `BOS_MinimumPoints`
(fixed — note this is now distinct from `SL_MinimumPoints`, B-4). Same loose-first sanity
approach as Stage 5.

---

## Stage 7 — Momentum Classification

**PRD sections:** §12.1–12.4 (direction-signed ROC momentum tiers)

**What to build**

- ROC calculation at each BOS event (§12.4)
- **`Directional_ROC` = `+ROC` for longs, `−ROC` for shorts (§12.1)** — then STRONG /
  WEAK / NEGATIVE classification against that, not against raw signed ROC

**Definition of Done**

- For every BOS event from Stage 6, log raw `ROC`, `Directional_ROC` and the resulting
  tier. Plot the distribution (histogram) of `Directional_ROC` at BOS events across the
  test window.
- Funnel counter populates `momentum_reject`.
- **Short-side regression check (v0.7, §39 test #13):** split the tier distribution by
  direction. LONG and SHORT tier splits should look broadly similar. If SHORT is ~100%
  NEGATIVE while LONG looks healthy, the direction-signing in §12.1 has been dropped —
  this is precisely defect B-1, which zeroed the entire short side of the funnel in v0.6
  with no symptom other than a `momentum_reject` number that looked merely "high".
- Sanity check the three-way split isn't wildly skewed to REJECT in either direction — if
  nearly every BOS is classified NEGATIVE, `ROC_NEGATIVE_THRESHOLD` is very likely set on
  the wrong side of zero or otherwise misconfigured.

**Diagnostic output:** funnel counter, `Directional_ROC` histogram at BOS events, tier
distribution (% STRONG/WEAK/NEGATIVE) **split by LONG/SHORT**.

**Parameters introduced:** `ROC_STRONG_THRESHOLD` (calibrated, Group B),
`ROC_NEGATIVE_THRESHOLD` and `ROC_Period` (fixed defaults). Loose-first sanity pass.

---

## Stage 8 — Entry Execution, Stop Loss, Position Sizing

**PRD sections:** §13 (SL), §14 (execution), §15 (position size), §36.2 (broker
stop-distance)

**What to build**

- SL calculation from setup low/high (§13), using `SL_MinimumPoints` — distinct from
  `BOS_MinimumPoints` (B-4)
- **Position sizing with full tick conversion (§15)** — `Account_Risk / |Entry − SL|` is
  *not* a lot count; convert through `TickSize`/`TickValue`, normalise to `LotStep`, clamp
  to min/max, and **reject** rather than round up when below min lot (B-2)
- Broker minimum stop-distance handling (widen-or-reject per §36.2), with position size
  recomputed against the widened stop
- Order submission with slippage tolerance

**Definition of Done**

- First stage where actual trade entries appear in the backtest report. The funnel's
  `Entries taken` line should now be nonzero — the milestone the entire staged approach has
  been building toward. If it's still zero, the funnel counter from Stages 4–7 shows exactly
  which upstream gate is responsible, rather than requiring a fresh investigation.
- **Both LONG and SHORT entry counts nonzero** over a window spanning both market
  directions (v0.7 — the end-to-end guard for B-1; Stage 7's tier split is the unit-level
  guard).
- Verify a sample of 10–15 entries by hand: correct direction, SL at the expected
  setup-low/high-minus-buffer price, position size producing the expected account risk %
  given the SL distance.
- **Risk-units regression check (v0.7, §39 test #14):** on a symbol where
  `TickValue / TickSize != 1`, verify that a full stop-out loses the configured risk
  percent within tolerance. This is the check that catches B-2 — the v0.6 formula produces
  a plausible-looking lot number that is wrong by a constant factor, which a visual entry
  review will not reveal.
- Synthetic broker-stop-distance test (§39 test #5): verify widen/reject behaviour on an
  artificially tight ATR-derived SL, and that sizing follows the widened stop.

**Diagnostic output:** full funnel counter (all entry-side gates populated), first-pass
trade log (entries only, no exit logic yet — close all test positions on a fixed N-bar
timeout purely for this stage's testing purposes).

---

## Stage 9 — Exit Architecture

**PRD sections:** §16.1–16.6 (active stop, trailing, breakeven, opposing BOS,
failed-breakout, regime decay), §25 (management sequencing)

Build and test each exit mechanism independently before combining them.

- **9a. Active stop + initial SL only** (no trailing/breakeven/BOS exit yet). Verify
  positions close correctly at the initial SL in a controlled backtest slice.
- **9b. Failed-breakout exit (§16.5a) in isolation.** Construct or find synthetic
  historical cases of genuine failed breakouts; verify the exit fires, is logged as
  `failed_breakout`, and fires only before trailing activation.
- **9c. Opposing BOS exit (§16.5) in isolation**, added alongside 9b. Synthetic same-bar
  priority test (§39 test #6): construct a case where both would fire on one candle, verify
  failed-breakout wins and the opposing-BOS check is skipped that bar.
- **9d. Breakeven + trailing (§16.2–16.4), added last.** Verify: the stop never widens (log
  any attempted against-trade movement as a hard error — it should never occur); trailing
  activates only after `MFE_R >= TrailingActivationR`; breakeven activates only after
  `MFE_R >= BreakevenActivationR` (v0.7 defines this rule — v0.6 used the parameter without
  ever stating when breakeven armed, M-3); the breakeven buffer sits on the correct (losing)
  side of entry.

**Definition of Done (full Stage 9)**

- Full exit-reason breakdown in the trade log (`initial_stop` / `breakeven_stop` /
  `trailing_stop` / `opposing_bos` / `failed_breakout`) shows a plausible distribution —
  not 100% any single reason.
- Management sequencing (§25's exact order: detect exits → update MFE → breakeven →
  trailing → ratchet) verified against a few hand-traced examples.
- "Stops never widen" invariant verified with zero violations across the full test window,
  against the three-term ratchet in §16.1 (v0.7 — v0.6's §16.1 listed only two terms and
  silently dropped the breakeven candidate, M-2).
- **`MFE_R` denominator check (v0.7, §39 test #16):** verify `MFE_R` uses the frozen initial
  stop distance and does not drift as `ACTIVE_STOP` ratchets — otherwise both activation
  thresholds move during the trade and activation timing stops being reproducible.

**Diagnostic output:** exit-reason distribution, stop-never-widens violation log (must be
empty), MFE distribution at exit.

**Parameters introduced:** `TrailingActivationR` (calibrated, Group C);
`BreakevenActivationR`, `Breakeven_Buffer`, `TrailShadowMultiplier`, `TrailATRMultiplier`,
`ShadowLookbackBars` (fixed defaults — `ShadowLookbackBars` is new in v0.7, since
`Average_LTF_Shadow` had no definition at all in v0.6, B-6).

---

## Stage 10 — Account-Level Risk & Filters

**PRD sections:** §17 (daily loss, consecutive losses, cooldown), §18 (session, incl. the
now-written-out §18.1), §19 (spread), §20 (news)

Build and test independently, each with its own before/after trade-count comparison.

- **Session filter:** verify all trade timestamps fall within configured windows; DST
  transition spot-check; boundary-candle behaviour follows §18.1 (bar CLOSE timestamp,
  `[start, end)` windows).
- **Spread filter:** verify rejections are logged and correlate with known high-spread
  periods (rollover, news), and that the check runs at order submission, not bar close (§19).
- **Daily loss / consecutive-loss limits:** synthetic test forcing a losing streak; verify
  cooldown activates.
- **Cooldown release condition** (§17.3, §39 test #7): verify release does NOT occur on a
  same-level retest, only on a genuinely new structural reference.
- **News filter** (if enabled): verify against a known historical high-impact news
  timestamp; log filter state on every run (§20).

**Definition of Done**

- Each filter's before/after trade-count delta is logged individually (e.g. "spread filter
  removed 47 of 312 candidate entries") — this makes each filter's real-world impact
  visible and debuggable in isolation, rather than only seeing the final combined count.
- Cooldown synthetic test passes.

**Diagnostic output:** per-filter rejection counts, cooldown activation/release log.

---

## Stage 11 — Full Pipeline Integration & Logging

**PRD sections:** §22 (event evaluation model, full pipeline), §23–24 (entry algorithms),
§26 (trade logging with versioning)

**What to build**

- Assemble all prior stages into the full §22.2 pipeline, **in the exact §22.2 order** —
  which is now the single normative order; v0.6's §23 gave a conflicting one (M-1)
- Full trade logging schema (§26), including `PRD_Version`, `EA_Build`, `Parameter_Hash`,
  and both raw `ROC` and `Directional_ROC`
- Same-bar close-then-reentry guard (§22.3, §39 test #11)

**Definition of Done**

- Run a full backtest over the complete test window. The funnel counter should now be fully
  populated end-to-end, and its gate order should match §22.2 line for line.
- Spot-check 20+ full trade records against manual chart review — entry, SL, exit reason,
  all independently verifiable by eye.
- §39 test #11 (same-bar re-entry) passes.
- Parameter hash confirmed to change when any input parameter changes (sanity check on the
  hashing itself).

**Diagnostic output:** complete funnel counter, complete trade log, parameter-hash check.

---

## Stage 12 — Calibration & Backtesting Protocol

**PRD sections:** §28 (backtesting protocol), §28.1 (stability testing), §28.2 (calibration
budget), §28.3 (staged group optimization)

Only begin once Stage 11 is fully passing — calibrating a pipeline that hasn't been
individually verified stage-by-stage is exactly how the original zero-trade failure became
undiagnosable.

**Groups, with each parameter marked calibrated or fixed (v0.7 — reconciles the "6-7
calibrated" budget against the group lists, which named 13+ parameters, M-8):**

| Group | Parameter | Class |
|---|---|---|
| A — Structure/Regime | `ER_LOW` | **Calibrated** |
| A | `ER_HIGH` | **Calibrated** |
| A | `ADX_THRESHOLD`, `ADX_Period` | Fixed |
| A | `Structural_Break_ATR_Multiplier`, `Structural_MinimumPoints` | Fixed |
| B — Entry | `LocationThreshold` | **Calibrated** |
| B | `BOS_ATR_Multiplier` | **Calibrated** |
| B | `ROC_STRONG_THRESHOLD` | **Calibrated** |
| B | `MaxRetracementBars` | **Calibrated** |
| B | `ROC_NEGATIVE_THRESHOLD`, `ROC_Period`, `BOS_MinimumPoints` | Fixed |
| C — Exit | `TrailingActivationR` | **Calibrated** |
| C | `BreakevenActivationR`, `Breakeven_Buffer` | Fixed |
| C | `TrailShadowMultiplier`, `TrailATRMultiplier`, `ShadowLookbackBars` | Fixed |
| C | `SL_ATR_Multiplier`, `SL_MinimumPoints` | Fixed |
| D — Risk | risk percents, `MAX_DAILY_LOSS`, `MAX_CONSECUTIVE_LOSSES` | Fixed |

Seven calibrated parameters, matching PRD §28.2. Fixed parameters get a sanity-tested
default and are deliberately not swept — that restraint is what keeps the parameter budget
honest.

- Optimize sequentially by group (§28.3), freezing each group's winners before starting the
  next, and each time checking the funnel counter didn't collapse to near-zero entries as a
  side effect of the new values. A group that improves in-sample expectancy while
  collapsing the funnel is rejected regardless of its score.
- Parameter stability testing (§28.1): for each calibrated parameter, sweep a small
  neighbourhood, not just the optimum — confirm a stable plateau, not an isolated spike.
- Data segmentation (§28): in-sample fitting → validation check → held-out out-of-sample
  confirmation → walk-forward.

**Definition of Done:** positive out-of-sample expectancy, stable parameter neighbourhoods,
≥ 100 trades in the out-of-sample window before trusting the result.

---

## Stage 13 — Unit Test Suite & Forward Testing

**PRD sections:** §39 (full unit test checklist), §33 (definition of completion)

- Run the complete §39 test list end-to-end — **all 16 tests** (12 from v0.6 plus the four
  v0.7 regression guards: short-side momentum, position-size units, ER flat window, `MFE_R`
  denominator), not just the ones already covered incidentally in earlier stages.
- Verify every item in §33's Definition of Completion, including item 11 (both LONG and
  SHORT entry counts nonzero).
- Demo/forward test before any real capital, per PRD §34.

---

## Summary Table

Rebuilt in v0.7 — v0.6's version had the Stage 4 row's two right-hand columns merged, and
answered *"first real trades appear?"* with `(managing)` for Stages 9–13, which answers a
different question than the column asks (E-7).

| Stage | Focus | Trades appear? | Highest zero-trade risk factor |
|---|---|---|---|
| 0 | Math primitives | No | Wrong ATR/ROC/ER formula silently poisons everything downstream |
| 1 | Swing detection | No | Wrong K, or a tie-break bug, produces no usable pivots |
| 2 | Structure state | No | `STRUCTURE_STATE` stuck at NEUTRAL — highest risk in the whole build |
| 3 | Regime | No | `REGIME_STATE` stuck at CHOPPY from bad ER thresholds — second highest |
| 4 | Combined gate + funnel | No | Gate order diverging from §22.2, making funnel attribution meaningless |
| 5 | Setup + location | No | `LocationThreshold` too tight |
| 6 | BOS | No | `BOS_ATR_Multiplier` too high |
| 7 | Momentum | No | Direction-signing dropped → ~100% of shorts rejected (B-1) |
| 8 | Entry / SL / sizing | **Yes** | Broker constraint rejection, or sizing missing tick conversion (B-2) |
| 9 | Exits | Yes (refining) | Exit sequencing bug, or a stop-widens violation |
| 10 | Risk / filters | Yes (refining) | Overly aggressive filter defaults |
| 11 | Full integration | Yes (refining) | Pipeline ordering error only visible when assembled |
| 12 | Calibration | Yes (refining) | Overfitting to a single parameter point |
| 13 | Unit tests / forward | Yes (refining) | Edge cases not caught by historical data alone |

---

## Build Status

**Code written is not a stage passed.** A stage is passed only when every item in its
Definition of Done has been checked against real historical data in the MT5 tester. Until
then the status is "in progress", however complete the code looks.

| Stage | Status | Artifacts |
|---|---|---|
| 0 | **In progress — DoD not passed** | `mql5/Include/HTFLTF/{Indicators,Params,BarGuard,Funnel}.mqh`, `reference/htfltf/{indicators,params,barguard,funnel}.py` |
| 1 | **In progress — DoD not passed** | `mql5/Include/HTFLTF/Swings.mqh`, `reference/htfltf/swings.py` |
| 2–13 | Not started | — |

Stage 0 and Stage 1 are built twice: once in MQL5 for the EA, and once in Python as the
independent reference implementation that Stage 0's DoD explicitly calls for ("match
independently-calculated reference values… from Python/Excel"). `mql5/Experts/HTFLTF_Stage01.mq5`
is the diagnostic harness that exercises both stages; it places no orders.

### What has been verified

| Check | Evidence |
|---|---|
| MQL5 compiles clean | MetaEditor: 0 errors, 0 warnings |
| ATR/ER match values hand-computed from §37 / §7.1 | `tests/test_indicators.py` |
| MQL5 and Python agree, series indexing included | `tests/test_mql5_parity.py` — 200 randomized series per function, exact |
| §38 rejects every invalid input, naming the parameter (§39 #12) | `tests/test_params.py` — Python side |
| Equal highs/lows disqualify both tied bars (§39 #1) | `tests/test_swings.py` |
| ER flat window → 0, no `inf`/`nan` (§39 #15) | `tests/test_indicators.py`, both implementations |
| Short-side momentum classifies STRONG (§39 #13) | `tests/test_indicators.py` |
| Funnel attributes each bar to exactly one gate | `tests/test_funnel.py` |

### What is still outstanding

Everything below needs the MT5 tester and real historical data. These are the DoD items
that actually close the gate:

**Stage 0**

- ATR/ROC/ER match the reference on ≥ 20 spot-checked bars of real historical data. The
  tests above prove the two implementations agree with each other and with hand-computed
  formulas; they do not prove either is right on live market data.
- Tick/bar ratio observed over a real run — the bar logic firing exactly once per bar
  cannot be confirmed without ticks.
- §38 validation exercised in MetaEditor by misconfiguring each parameter in turn. The
  MQL5 check list has compiled but has never executed.
- ATR/ROC/ER diagnostic output eyeballed against a live chart.

**Stage 1**

- Pivot markers plotted over a multi-month window and compared against manual chart
  reading in three regions: trending, ranging, choppy.
- Swings-per-week count confirmed plausible, nonzero and roughly stable.
- Sanity-test K ∈ {2, 3, 5} to confirm behaviour scales sensibly before locking K in.

Only when those are done does Stage 2 begin.
