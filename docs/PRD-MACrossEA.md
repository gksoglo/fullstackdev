# PRD: Multi-Filter MA Crossover Expert Advisor (MQL5)

**Version:** 1.12 (Draft)
**Platform:** MetaTrader 5 / MQL5
**Status:** Draft for review — see Section 9 (Open Questions) before implementation
**Code folder:** Autotrader/MACrossEA_1.2 (staged modular rebuild — see Section 1 note on Stage 1 scope; this document describes the full target design, of which the staged rebuild currently implements Module A step 1 + a v1.2 LTF confirmation gate (see note under Module A) + Module B + Module D's Exit_Mode toggle — see the 1.11/1.12 Version History entries)

## 1. Overview

This EA generates trade signals from a fast/slow moving average (MA) crossover on a trading timeframe ("LTF"), filtered by:

- Trend-quality confirmation on the LTF crossover itself (directional consistency + slope/angle + minimum MA separation).
- A higher-timeframe ("HTF") MA trend filter that restricts trade direction.
- A single, mutually-exclusive momentum/oscillator filter (radio-button style), plus an independent ATR volatility filter, both evaluated on the LTF (the same timeframe as the crossover signal) that can veto a trade for exhaustion of the specific move being entered.

The EA does not trade on tick-by-tick noise — all signal evaluation happens on closed candles only (consistent with the Bollinger Band EA's processing model), to avoid repainting and intrabar false signals.

**Primary condition vs. toggleable filters (added v1.9):** the LTF crossover (Module A, step 1) and the HTF trend gate (Module B) are the mandatory, always-active core of the strategy and cannot be disabled — together they are "the trade condition." Every other check layered on top of that core is independently toggleable at runtime via an input, specifically so each one can be isolated one at a time during debugging/calibration without editing code:

| Check | Toggle input | Default |
|---|---|---|
| Trend-confirmation (strict monotonic) | `Enable_TrendConfirm_Check` | true |
| Regression angle-between-lines | `Enable_Angle_Check` | true |
| Minimum MA separation | `Enable_Separation_Check` | true |
| Momentum/oscillator filter | `Momentum_Filter = NONE` | (set to NONE to disable) |
| ATR volatility filter | `Enable_ATR_VolatilityFilter` | true |

This lets a tester run "crossover + HTF only" as a baseline, then re-enable one filter at a time and re-run, watching the veto-rate summary (Section 5/6) to see which specific filter's logic or threshold is rejecting trades unexpectedly — rather than guessing from the fully-stacked strategy.

## 2. Scope

**In scope:**

- Signal generation logic (crossover, trend confirmation, regression/angle filter, MA separation filter)
- HTF directional gate
- Single-select momentum filter + independent ATR volatility filter
- AUTO (auto-execute) and SIGNAL_ONLY (alert-only) modes
- Order management: fixed SL/TP or trailing stop (selectable), position caps per direction, magic number, netting/hedging-aware execution

**Out of scope (future PRD revisions):**

- Multi-symbol / portfolio management
- Advanced position sizing (fixed lot only in v1.0)
- Partial position closes (position is always closed/reversed/stopped in full — no partial-close logic in v1.0)

## 3. Glossary

| Term | Definition |
|---|---|
| LTF | Lower/trading timeframe — where the fast/slow MA crossover and entries are evaluated |
| HTF | Higher timeframe — where trend direction is evaluated as a directional gate (momentum/exhaustion is checked on the LTF instead, see Module C) |
| Cross bar | The first fully closed bar on which the fast MA has crossed the slow MA |
| Trend confirmation window | The last N MA values used to verify the MA is monotonically moving in the cross direction |
| Regression window | The last M closed MA values used to fit a linear regression line for slope/angle measurement |

## 4. Functional Modules

### 4.0 Bar Indexing & Synchronization Convention (applies to all modules)

All bar/shift references in this document use one fixed convention:

- Shift 0 = the current, still-forming candle (never used for signal logic).
- Shift 1 = the most recently closed candle.
- Shift 2 = the candle before that. And so on.

All signal calculations (Modules A, B, C) use shift ≥ 1 only. No module ever reads shift 0 — **with exactly one deliberate exception, added in v1.10:** Module B's HTF candle-color confirmation (HTF_ConfirmationCandles), which starts its window at HTF shift 0 by design. See Module B's Logic section for the full justification; every other check in this document, including Module B's own MA-value confirmation, still obeys the shift ≥ 1 rule without exception.

**Per-module application:**

- **Module A (LTF), crossover + MA-value confirmation:** the crossover is detected between shift 2 and shift 1 — i.e., `FastMA[2] ≤ SlowMA[2]` and `FastMA[1] > SlowMA[1]` (bullish case; mirrored for bearish). Shift 1 is the signal bar. `TrendConfirm_Bars = 3` means `MA[3] < MA[2] < MA[1]` (bullish) evaluated on both fast and slow MA — the signal bar (shift 1) is included in the count.
- **Module A (LTF), candle-color confirmation (v1.2):** the LTF mirror of Module B's candle check, but with no shift-0 exception — `LTF_ConfirmationCandles = 3` means LTF shift 1, 2, and 3 (all closed) must all share the crossover's candle color.
- **Module B (HTF), MA-value confirmation:** uses the most recently completed HTF candle at the moment the LTF signal bar closes — this is HTF shift 1, never HTF shift 0, even if the HTF candle has been forming for a long time relative to the LTF. `HTF_TrendConfirm_Bars = 5` means `HTF_MA[5] < HTF_MA[4] < HTF_MA[3] < HTF_MA[2] < HTF_MA[1]` (uptrend case).
- **Module B (HTF), candle-color confirmation (v1.10):** the one shift-0 exception — `HTF_ConfirmationCandles = 3` means HTF shift 0, 1, and 2 must all share the trend's candle color, re-read fresh (including the still-live shift 0 candle) every time Module B runs.
- **Module C (LTF momentum/ATR):** evaluated on the same LTF signal bar as Module A (shift 1) — never on the live/current value. This is a hard rule: Module C must not evaluate a different bar than Module A, or the closed-bar guarantee is broken.

One synchronization rule ties all three together: every signal evaluation cycle is anchored to one specific newly-closed LTF candle (shift 1). Modules A and C both read that exact candle's closed values. Module B reads whichever HTF candle was most recently completed as of that same moment (HTF shift 1). This single rule resolves the indexing ambiguity across every module rather than defining it separately per indicator.

### Module A — LTF Crossover Signal

**v1.2 staged-rebuild note:** the code folder implements a mirrored version of Module B's v1.1 two-confirmation pattern (Section 1) directly on Module A's own crossover direction, ahead of the rest of this section's toggle-based design landing in code. In the running EA today, `InpLTFTrendConfirmBars` (renamed from `TrendConfirm_Bars` below, to pair with `InpHTFTrendConfirmBars`) and the new `InpLTFConfirmationCandles` (see its own row below) are **both mandatory, non-toggleable** — there is no `Enable_TrendConfirm_Check` toggle in the modular rebuild's code (that toggle only ever existed in the older monolithic `MACrossEA_1` build). The angle and separation checks (steps 3–4 below), and their toggles, remain unbuilt in the staged rebuild — this section still describes the full target design for all four steps, only step 2's MA-monotonic half and the new candle-color check are implemented today, and both unconditionally.

**Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| FastMA_Period | int | 10 | Fast MA period |
| SlowMA_Period | int | 30 | Slow MA period |
| MA_Method | enum | EMA | SMA / EMA / SMMA / LWMA — shared across all three MAs (LTF fast, LTF slow, HTF) |
| MA_AppliedPrice | enum | Close | Price series used for all three MA calcs (shared) |
| LTF_Timeframe | enum | Current chart | Timeframe for crossover evaluation |
| TrendConfirm_Bars (code: `InpLTFTrendConfirmBars`, v1.2) | int | 3 | Number of consecutive closed bars (including the signal bar, shift 1) over which fast & slow MA must move monotonically in cross direction. Intentionally independent of Regression_Bars below — see note under input 6. Mandatory in the v1.2 code folder (see note above), not gated by a toggle there. |
| LTF_ConfirmationCandles (code: `InpLTFConfirmationCandles`, new in v1.2) | int | 3 | The LTF mirror of Module B's `HTF_ConfirmationCandles`: the last N **closed** LTF candles (shift 1..N) must all share the crossover's candle color — bullish (Close > Open) for a LONG cross, bearish for a SHORT cross. Unlike the HTF version, this one does **not** read shift 0 — see Module B's Logic section and Section 4.0 for why the HTF exception doesn't transfer to the LTF: the LTF's own shift-0 candle, at the instant Module A evaluates (immediately after its own signal bar just closed), has only just begun forming and carries essentially no signal, and reading it would break Module A's closed-bar-only guarantee for no corresponding benefit. Mandatory, not toggleable, same as the row above. |
| Regression_Bars | int | 3 | Number of most-recent closed MA values (shift 1 .. shift Regression_Bars) used to fit the regression lines. Intentionally independent of TrendConfirm_Bars: TrendConfirm_Bars measures directional persistence (is the MA moving the same way for N bars), while Regression_Bars measures the current convergence/divergence rate between the two MAs over its own window. They answer different questions and are not required to match — e.g. a longer TrendConfirm_Bars with a shorter Regression_Bars asks "has this been trending for a while, and is it currently accelerating apart." No validation enforces a relationship between them; this is a deliberate design choice, not an oversight. |
| MinCross_Angle_Deg | double | 15.0 | Minimum crossing-angle metric (degrees, 0–90) between the fast-MA and slow-MA regression lines — an unsigned magnitude, not compared directionally (see logic below). Note on terminology: calling this an "angle" is a useful shorthand, but strictly speaking neither the Raw nor the ATR-normalized version is a literal geometric chart angle — see Section 8 for why, and for the more precise "crossing-angle metric" framing used there. |
| Enable_ATR_AngleNormalization | bool | true | On/off toggle: when off, both regression slopes are used raw; when on (default), both are normalized by ATR before the angle-between-lines formula is applied. Default is on because raw-slope values are numerically tiny for typical FX price scales — see Section 8. |
| LTF_ATR_Period | int | 14 | ATR period on the LTF, shared by Enable_ATR_AngleNormalization and MinMA_Separation_Unit = ATR_Multiple below. Deliberately independent of Module C's ATR_Period/Enable_ATR_VolatilityFilter. If ATR[1] ≤ 0 or unavailable (e.g. insufficient history, or a symbol/feed anomaly), treat as DATA_NOT_READY and do not generate a signal — do not divide by zero or a negative value. |
| MinMA_Separation | double | 5.0 | Minimum distance between fast and slow MA at the signal bar (shift 1) |
| MinMA_Separation_Unit | enum | Points | Points / Pips / ATR_Multiple. If ATR_Multiple, required separation = `MinMA_Separation × ATR[1]` using LTF_ATR_Period (defined above) — independent of whether Module C's ATR volatility filter is enabled. Same ATR[1] ≤ 0 guard as above applies. If Pips, PipSize = 10 × SYMBOL_POINT for conventional 3- or 5-digit FX symbols, and PipSize = SYMBOL_POINT for 2- or 4-digit symbols — this unit is intended for FX symbols; for non-FX instruments (indices, metals, crypto CFDs) where "pip" isn't broker-standard, use Points or ATR_Multiple instead. |

**Debug toggle inputs (added v1.9):** independent on/off switches for logic steps 2–4 below, so each can be isolated one at a time while debugging/calibrating (see Section 1 and Section 6). Step 1 (crossover detection) is never toggleable — it is the primary trade condition together with Module B.

| Input | Type | Default | Description |
|---|---|---|---|
| Enable_TrendConfirm_Check | bool | true | When false, step 2 (directional consistency) is skipped entirely — direction still comes from step 1, but no monotonic-run requirement is enforced. |
| Enable_Angle_Check | bool | true | When false, step 3 (regression angle-between-lines) is skipped entirely — the regression is not even computed, so `Regression_Bars`, `MinCross_Angle_Deg`, and `Enable_ATR_AngleNormalization` have no effect while disabled. |
| Enable_Separation_Check | bool | true | When false, step 4 (minimum MA separation) is skipped entirely — `MinMA_Separation`/`MinMA_Separation_Unit` have no effect while disabled. |

**Logic:**

1. **Crossover detection (signal bar = shift 1):** bullish if `FastMA[2] ≤ SlowMA[2]` and `FastMA[1] > SlowMA[1]`; bearish if `FastMA[2] ≥ SlowMA[2]` and `FastMA[1] < SlowMA[1]`. This explicitly captures the bar on which the mathematical cross occurs, and establishes the trade direction — the angle check below is a magnitude gate only and does not itself determine direction. Note this is intentionally a stronger condition than "the trend is up/down" once combined with check 2 below — the fast MA must actively accelerate past the slow MA while both are still moving in the cross direction, which is a stricter (and, per the original design intent, deliberate) filter rather than a plain trend-follow test.

2. **Directional consistency check** (skipped entirely if `Enable_TrendConfirm_Check = false`): over shift 1 through shift TrendConfirm_Bars, both fast and slow MA must be strictly monotonic in the cross direction (e.g., `MA[3] < MA[2] < MA[1]` for a bullish cross with TrendConfirm_Bars = 3). If not monotonic, discard signal. This is a strict monotonic requirement — a single flat or countertrend value anywhere in the window fails it (e.g. 100, 101, 101 fails; 100, 101, 101.01 passes) — which can make this filter considerably more selective than "the MA is generally trending." That selectivity is intentional per the original design, but worth being aware of when tuning TrendConfirm_Bars.

3. **Angle-between-lines check** (skipped entirely if `Enable_Angle_Check = false` — the regression is not computed, and direction still comes solely from step 1): fit two separate linear regression lines over MA[Regression_Bars] .. MA[1] — one through the fast MA values, one through the slow MA values — giving slopes b_fast and b_slow (price/bar). If Enable_ATR_AngleNormalization = true, rescale both: `b_fast′ = b_fast / ATR[1]`, `b_slow′ = b_slow / ATR[1]` (using LTF_ATR_Period; guard against ATR[1] ≤ 0 as noted above); otherwise `b_fast′ = b_fast`, `b_slow′ = b_slow`. Compute the crossing-angle metric using the standard two-line-slope formula:

   ```
   angle_degrees = atan( | (b_fast′ − b_slow′) / (1 + b_fast′ × b_slow′) | ) × (180 / π)
   ```

   This is an unsigned magnitude by construction, bounded to 0°–90°, so there is no directional sign to compare — direction was already established in step 1. Require `angle_degrees ≥ MinCross_Angle_Deg`.

   **Degenerate case:** if `1 + b_fast′ × b_slow′ = 0` (the two lines are perpendicular in the scaled slope-space), define `angle_degrees = 90` directly rather than dividing by zero.

   **What this filter actually measures — read this before tuning it:** this is a rate-of-divergence/convergence filter between the fast and slow MA, not a raw trend-steepness filter. A fast MA rising steeply while the slow MA rises almost as steeply (e.g. b_fast=0.100, b_slow=0.091) produces a small angle despite strong absolute trend movement, while a fast MA rising gently against a nearly flat slow MA (e.g. b_fast=0.010, b_slow=0.001) can produce a larger angle despite weaker absolute movement. If the intent was "only trade when the overall trend is moving fast," this filter alone doesn't guarantee that — it guarantees the two MAs are actively separating at a meaningful rate, which is a related but distinct property. This is also why this check is somewhat correlated with the separation check (4 below): both respond to the fast/slow MA pulling apart, one measuring the current rate, the other the current distance. Worth testing in isolation (Section 6) before assuming both add independent value.

   This is a corrected reinterpretation of the original design — the angle is measured between the fast and slow MA regression lines themselves, not between one line and the horizontal axis. Extrapolate_Bars remains correctly omitted from the spec: the angle between two lines depends only on their slopes, not on where (or whether, within the fitted window) they actually intersect, so extrapolating either line further would not change this value.

   **Field observation (v1.9):** in initial backtesting (EURUSD M15, EMA 10/30, defaults), this check rejected 100% of crosses that survived step 2 — a 3-bar regression window on ATR-normalized slopes produced angle values far below the default 15° threshold. This is why `Enable_Angle_Check` exists as an isolable toggle, and why Section 6's veto-rate analysis now also tracks the actual min/avg/max angle values seen on rejected bars, so the threshold can be calibrated from real data instead of trial and error.

4. **Separation check** (skipped entirely if `Enable_Separation_Check = false`): at the signal bar, `|FastMA[1] − SlowMA[1]|` must be ≥ the required separation distance (converted per MinMA_Separation_Unit, see input table above).

If all checks pass → raw directional signal (LONG or SHORT, as established in step 1) is generated and passed to Module D.

### Module B — HTF Trend Gate

**Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| HTF_Timeframe | enum | H4 | Higher timeframe for trend filter. Must be strictly higher than LTF_Timeframe — see Section 7 validation rules. |
| HTF_MA_Period | int | 20 | HTF MA period (independent period — only the method/applied-price are shared, see below) |
| HTF_TrendConfirm_Bars | int | 5 | Number of consecutive HTF MA values (HTF shift 1 .. shift HTF_TrendConfirm_Bars) required to establish trend — the MA-value confirmation. |
| HTF_ConfirmationCandles | int | 3 | **(v1.1)** Number of consecutive HTF candles, by candle color (Close vs. Open), required to establish trend — the price-action confirmation. Counted starting from HTF shift 0, the currently-developing candle (see Logic below) — this is deliberately not shift-1-and-older like every other check in this document. Minimum 1. |

All three MAs in this EA (LTF fast, LTF slow, and HTF) share the same MA_Method and MA_AppliedPrice (defined once in Module A) — there are no separate HTF_MA_Method/HTF_MA_AppliedPrice inputs. Only the periods differ per MA (FastMA_Period, SlowMA_Period, HTF_MA_Period).

**Distinct role** (to keep in mind given A/B measure related things — see Section 7 note on filter correlation): Module A asks "is this LTF crossover strong enough on its own terms?" Module B asks "does the higher-timeframe regime agree with it?" These are correlated in a trending market by construction, but not redundant — Module A can pass while Module B blocks (e.g. a strong LTF pop against the HTF trend), and that's the case this filter exists to catch.

**Logic (v1.1 — two independent confirmations, both required):**

1. **MA-value confirmation** (unchanged from v1.0): using HTF shift 1 through shift HTF_TrendConfirm_Bars (see Section 4.0 for the synchronization rule — always the most recently completed HTF candle, never the forming one): if strictly decreasing → downtrend (`HTF_MA[5] > HTF_MA[4] > HTF_MA[3] > HTF_MA[2] > HTF_MA[1]` for the default of 5); if strictly increasing → uptrend. This is a strict monotonic regime classification, not a general "is it trending" test — a single unchanged or countertrend value anywhere in the window (e.g. 100, 101, 102, 102, 103) causes the whole window to fail.

2. **Candle-color confirmation (new, v1.1):** the last HTF_ConfirmationCandles candles, by shift, must all agree in color with the trend direction — all bullish (Close > Open) for an uptrend, all bearish (Close < Open) for a downtrend. **This window starts at shift 0, the currently-developing HTF candle, not shift 1** — e.g. HTF_ConfirmationCandles = 3 checks shift 0, 1, and 2. This is a deliberate, explicit exception to the Section 4.0 rule that "no module ever reads shift 0": the requirement is that the developing candle is *currently* moving in the trend direction, re-evaluated fresh every time Module B runs (once per newly-closed LTF bar, per the existing synchronization rule — the HTF candle's own close time is irrelevant to how often this check runs). Because the developing HTF candle isn't closed yet, its Open/Close — and therefore this check's verdict — can change between one LTF bar-close and the next even though nothing "new" has happened HTF-wise. That's expected behavior for reading a live value, not repainting: no earlier decision is ever revised, only the current bar's live evaluation reflects the live candle. A doji (Close == Open) satisfies neither Bullish nor Bearish and breaks the streak like any other disagreement.

**HTF_Bias is LONG_ONLY only if BOTH confirmations agree on uptrend; SHORT_ONLY only if BOTH agree on downtrend.** If either confirmation disagrees, is itself ambiguous, or the two confirmations disagree with each other (e.g. MA rising but candles currently red) → HTF is blocked. Fixed rule: all trades are blocked while blocked, regardless of Module A or C.

**Output:** `HTF_Bias = LONG_ONLY / SHORT_ONLY / BLOCKED`.

### Module C — Momentum / Exhaustion Filter (single-select)

Implemented as a single enumerated input so only one oscillator is ever active (equivalent to a UI radio-button group).

**Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| Momentum_Filter | enum | RSI | NONE / RSI / MACD / STOCHASTIC / CCI — single-select momentum oscillator |
| Enable_ATR_VolatilityFilter | bool | true | Independent on/off toggle — layers on top of Momentum_Filter rather than competing with it |

Both evaluated on the LTF (the same timeframe as the crossover signal itself, LTF_Timeframe from Module A) — not the HTF.

**Design note — why momentum is checked on the LTF, not the HTF:** the trade is triggered by the crossover on the LTF, so the thing that could be "exhausted" is that specific LTF move. Checking momentum on the HTF would answer a different question (is the bigger-picture trend fading), which Module B already partially covers via its own directional gate. Evaluating RSI/MACD/Stochastic/CCI/ATR on the same timeframe as the entry signal directly measures whether this move — the one about to be traded — already looks stretched, which is a better match for "trend exhaustion at the point of entry" than a separate timeframe's reading would be. This supersedes the earlier HTF-based design.

**Design note — why ATR was pulled out of the radio group:** RSI/MACD/Stochastic/CCI are all directional momentum reads (they say something about this specific direction losing steam). ATR is direction-agnostic volatility — it says something about the market's overall energy regardless of direction. Putting all five behind one radio button forces a choice between "check directional momentum" OR "check volatility contraction," when in practice you'd usually want both: e.g., RSI confirming bullish strength and ATR confirming the move isn't happening on dying volatility. Splitting them lets `Momentum_Filter = NONE` + ATR-only run as a pure volatility gate, or any oscillator + ATR run together, without giving up either check.

**Per-indicator parameters and exhaustion criteria (momentum group)**, evaluated on the Module A signal bar (LTF shift 1 — see Section 4.0):

| Indicator | Inputs | Exhaustion / low-momentum condition (blocks trade) |
|---|---|---|
| RSI | RSI_Period (14), RSI_Overbought (70), RSI_Oversold (30) | Exhaustion = overbought/oversold and turning against the signal, defined precisely as: LONG blocked if `RSI[1] ≥ RSI_Overbought` and `RSI[1] < RSI[2]` (turning down); SHORT blocked if `RSI[1] ≤ RSI_Oversold` and `RSI[1] > RSI[2]` (turning up). RSI values that are simply below/above the midline (e.g. RSI 49 for a LONG) do not block on their own — only the overbought/oversold-and-turning condition does. |
| MACD | MACD_Fast (12), MACD_Slow (26), MACD_Signal (9), MACD_Decline_Bars (2) | LONG blocked if `Hist[1] ≤ 0` (momentum never confirmed direction), or if `Hist[1] > 0` and `Hist[1] < Hist[2] < ... < Hist[MACD_Decline_Bars+1]` (positive but declining). SHORT blocked if `Hist[1] ≥ 0`, or if `Hist[1] < 0` and `Hist[1] > Hist[2] > ... > Hist[MACD_Decline_Bars+1]` (negative but rising toward zero). Fully symmetric. |
| Stochastic | Stoch_K, Stoch_D, Stoch_Slowing (5,3,3), Stoch_Overbought (80), Stoch_Oversold (20) | LONG blocked if `%K[1] < 50`, or if `%K[1] > Stoch_Overbought` and `%K[1] < %D[1]` (turning down). SHORT blocked if `%K[1] > 50`, or if `%K[1] < Stoch_Oversold` and `%K[1] > %D[1]` (turning up). The 50 midline is a fixed structural constant (the mathematical center of the 0–100 oscillator), not a configurable input — only the overbought/oversold levels are tunable. Note the boundary: `%K[1] = 50` passes both directions by this definition — intentional, not an oversight. |
| CCI | CCI_Period (14) | Re-scoped as directional confirmation, not exhaustion (see design note below): LONG blocked if `CCI[1] < 0`. SHORT blocked if `CCI[1] > 0`. (No overbought/oversold threshold is used by this default rule — a future revision could add a true CCI exhaustion mode with its own CCI_Overbought input, but that would be a separate, explicit strategy decision. No unused parameter is declared here for it, to avoid a configurable-looking input that silently has no effect on current behavior.) |

**Filter role summary** (not a functional change, just making explicit what each actually tests, since they aren't all the same kind of check):

| Filter | What it actually tests |
|---|---|
| RSI | Exhaustion only (doesn't confirm direction at all outside the overbought/oversold-and-turning zone) |
| MACD | Both direction and exhaustion (blocks outright if histogram disagrees with direction, additionally blocks if agreeing but fading) |
| Stochastic | Both direction and exhaustion (same shape as MACD) |
| CCI | Direction only (no fading/exhaustion component) |
| ATR | Volatility contraction only (direction-agnostic) |

**Caution — filter correlation, not a bug:** Module A (fast/slow MA direction), Module B (HTF direction), and the directional-confirmation filters in Module C (MACD, Stochastic, CCI) are all, to varying degrees, measuring the same underlying phenomenon — trend direction. Stacking several of them (e.g. A + B + CCI) can look like three independent confirmations when they're actually highly correlated, which can shrink trade frequency far more than expected without adding proportionate signal quality. This isn't something to "fix" in the logic — it's a reason to test filter combinations deliberately (see Section 6) rather than assume more filters is strictly better.

**Design note — CCI is directional confirmation, not exhaustion:** unlike the other three, the drafted CCI rule doesn't test for a fading move — it tests whether CCI agrees with the trade direction at all, with a hard discontinuity at zero (CCI = +1 passes, CCI = −1 blocks). This is a legitimately different kind of filter from RSI/MACD/Stochastic's fading-momentum tests. It's kept as-is here since it's still a useful filter, but it should not be mentally grouped with "exhaustion" — it answers "does momentum currently agree with this trade" rather than "is momentum running out."

**Volatility filter parameters** (independent, direction-agnostic), also evaluated on the Module A signal bar:

| Indicator | Inputs | Exhaustion / low-momentum condition (blocks trade) |
|---|---|---|
| ATR | ATR_Period (14), ATR_Avg_Period (20), ATR_Contraction_Bars (2) | Blocked if both: (a) ATR has strictly declined for ATR_Contraction_Bars consecutive closed bars, i.e. `ATR[1] < ATR[2] < ... < ATR[ATR_Contraction_Bars+1]`; and (b) `ATR[1]` is below the average of `ATR[2] .. ATR[ATR_Avg_Period+1]` — the current bar's ATR is excluded from its own reference average, so this reads as "is current volatility below its recent prior baseline" rather than a self-referential comparison. |

**Logic:** A trade is vetoed if either check fails: Momentum_Filter (if not NONE) flags exhaustion in the signal direction, or Enable_ATR_VolatilityFilter is true and ATR contraction is detected. Both NONE + filter disabled simultaneously means Module C always passes.

**All four possible configurations, spelled out explicitly** (so NONE is never mistaken for "disables all of Module C"):

| Momentum_Filter | Enable_ATR_VolatilityFilter | Resulting behavior |
|---|---|---|
| NONE | OFF | Module C always passes — no filtering at all |
| NONE | ON | ATR-only: pure volatility-contraction gate, no directional oscillator check |
| RSI / MACD / STOCHASTIC / CCI | OFF | Oscillator-only: directional/exhaustion check, no volatility check |
| RSI / MACD / STOCHASTIC / CCI | ON | Both checks applied — vetoed if either fails |

### Module D — Signal Aggregation & Execution

**Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| Execution_Mode | enum | SIGNAL_ONLY | AUTO (auto-trade) / SIGNAL_ONLY (alert/log only) |
| Lot_Size | double | 0.10 | Fixed lot size (v1.0 — no dynamic sizing) |
| Exit_Mode | enum | FIXED_SLTP | FIXED_SLTP / TRAILING_STOP — selects exit management style |
| StopLoss_Points | int | 300 | SL distance in points from entry (used when Exit_Mode = FIXED_SLTP, and as the initial SL when TRAILING_STOP) |
| TakeProfit_Points | int | 600 | TP distance in points from entry (used when Exit_Mode = FIXED_SLTP only — trailing mode has no fixed TP by default) |
| Trailing_Start_Points | int | 200 | TRAILING_STOP only: profit (in points) required before the trailing stop activates |
| Trailing_Distance_Points | int | 150 | TRAILING_STOP only: distance maintained between current price and the trailing SL once active |
| Trailing_Step_Points | int | 10 | TRAILING_STOP only: minimum favorable move (points) before the trailing SL is advanced again, to avoid excessive modify requests |
| Magic_Number | int | — | Unique EA identifier. All position counting, trailing, and reversal logic operates only on positions matching `POSITION_SYMBOL == _Symbol AND POSITION_MAGIC == Magic_Number` — manual positions or other EAs' positions on the same symbol are never counted, modified, or trailed. |
| Max_Open_Positions | int | 1 | Cap on concurrent EA-managed (Symbol+Magic-matched) positions per direction (e.g. default of 1 means up to 1 LONG and up to 1 SHORT simultaneously under HEDGING; under NETTING this is moot since only one net position ever exists). |
| Account_Mode | enum | AUTO | AUTO / FORCE_NETTING / FORCE_HEDGING. AUTO reads the real account mode via `AccountInfoInteger(ACCOUNT_MARGIN_MODE)` at OnInit() and uses it. FORCE_* options are only accepted when running inside Strategy Tester (`MQLInfoInteger(MQL_TESTER) == true`); if a FORCE_* option is selected outside the tester, the EA refuses to initialize (`OnInit()` returns `INIT_FAILED`) regardless of whether it happens to match the real account mode. If FORCE_* is selected inside the tester but conflicts with the tester's reported mode, it also fails init. |
| Block_On_ForeignNettingExposure | bool | true | NETTING mode only: if a net position already exists on the symbol that does not match the EA's own Magic_Number, the EA refuses to open new positions and logs `D_FOREIGN_EXPOSURE_BLOCKED`, rather than attempting to manage or reverse exposure it didn't create. |
| Netting_ReverseOnOppositeSignal | bool | true | NETTING mode only: if a valid opposite-direction signal fires while an EA-owned position is open, close the existing position and open the new one, using the transactional sequence defined below. Reversal failure policy is named FAIL_FLAT: if the close succeeds but the reopen fails, the account is deliberately left flat rather than retried within the same tick. |
| MaxSpread_Points | int | 30 | If the current spread exceeds this at the moment of order submission, the order is vetoed (not just logged) and `D_SPREAD_EXCEEDED` is logged. |
| MaxDeviation_Points | int | 10 | Slippage tolerance passed to the order-send request (deviation parameter). Not a veto condition on its own; a rejection here surfaces as `D_ORDER_REJECTED`. |

**Execution sequencing** (applies to both exit modes): SL/TP are defined relative to the actual filled position open price (`POSITION_PRICE_OPEN`), but broker stop-distance/freeze-level constraints can only be checked against a price that isn't known until after the fill. The pipeline therefore splits order validation into two stages rather than one:

1. **Pre-fill validation** (the `ORDER_VALIDATED` state in Section 5): checks that don't depend on the fill price — spread (MaxSpread_Points), lot size/step, margin sufficiency, symbol trading mode, market-open state.
2. Submit the market order with MaxDeviation_Points as the deviation parameter, without SL/TP attached (or, if the broker's OrderSend requires SL/TP at submission time, with provisional values computed from the decision-time price, understood to be provisional).
3. After the fill is confirmed, read back `POSITION_PRICE_OPEN`, compute the real SL/TP (StopLoss_Points/TakeProfit_Points from that actual price), validate those specific price levels against the broker's current `SYMBOL_TRADE_STOPS_LEVEL` and freeze level, and only then send a modify request to attach them.
4. If step 3's validation fails (e.g. the fill price moved enough that the computed SL/TP now violates the minimum stop distance), log `D_ORDER_REJECTED` with a distinct sub-reason and retain the position with whatever provisional/fallback stop is in place — do not leave a position with no protective stop at all. A safe fallback (e.g. clamping the SL to the nearest broker-legal distance) is preferable to none.

**FIXED_SLTP:** SL and TP are calculated from `POSITION_PRICE_OPEN` per the sequencing above, and set once (via the post-fill modify step), not adjusted afterward.

**TRAILING_STOP:** position opens with StopLoss_Points (from the actual fill price) as the initial protective SL and no TP. `Trailing_Distance_Points ≤ Trailing_Start_Points` is a hard validation rule (enforced at OnInit()). Once floating profit reaches Trailing_Start_Points (activation is inclusive: profit ≥ Trailing_Start_Points triggers activation), the EA begins trailing:

- **BUY:** candidate SL = current Bid − Trailing_Distance_Points. Apply it only if both: (a) it is higher than the existing SL (SL only ratchets in the favorable direction — it must never move backward/loosen), and (b) `candidate_SL − existing_SL ≥ Trailing_Step_Points` — the step is measured as SL movement, not raw price movement.
- **SELL:** mirror using Ask + Trailing_Distance_Points; SL only ratchets lower; step measured the same way (`existing_SL − candidate_SL ≥ Trailing_Step_Points`).

Every trailing-stop modification must itself pass broker validation before being sent — normalize the candidate SL to the symbol's tick size, and verify it satisfies the broker's current `SYMBOL_TRADE_STOPS_LEVEL` (minimum stop distance) and freeze level at the time of modification, not just at the time the original order was placed. An invalid modify request should be logged (`D_ORDER_REJECTED`) and retried on a subsequent tick rather than treated as fatal.

Trailing operates only on positions matching `POSITION_SYMBOL == _Symbol AND POSITION_MAGIC == Magic_Number`. Trailing logic runs on OnTick() (not gated to closed bars), separately from the closed-bar signal-generation logic in Modules A–C.

**Account mode behavior:**

**NETTING:** at most one net position per symbol. Before opening any new position, the EA checks Block_On_ForeignNettingExposure: if a net position exists on the symbol whose magic number doesn't match Magic_Number, the new order is refused and `D_FOREIGN_EXPOSURE_BLOCKED` is logged (default behavior). Ownership limitation: in a netting account, the position-level magic number is the only ownership signal the EA relies on — if a position's magic number matches, the EA treats the entire net position as its own. The EA does not attempt to reconstruct or partially manage mixed-origin exposure. Otherwise: a same-direction signal while an EA-owned position is already open is ignored. An opposite-direction signal triggers a reversal using this explicit sequence (reversal failure policy: FAIL_FLAT — if Netting_ReverseOnOppositeSignal = true; if false, the opposite signal is simply ignored while a position is open):

1. Detect the opposite-direction signal.
2. Submit a close request for the existing (EA-owned) position.
3. Verify via `PositionSelect()`/deal confirmation that the position no longer exists. If the close fails or times out, abort — do not attempt to open the new position, log `D_CLOSE_FAILED`, and leave the existing position in place for re-evaluation on the next signal bar.
4. Only after the close is confirmed, re-validate current market conditions from scratch (spread, margin, broker constraints — the same pre-fill checks as any new order) before submitting the new position in the opposite direction. Do not reuse the validation performed before step 2.
5. If the (freshly-validated) open then fails, log `D_ORDER_REJECTED` and leave the account flat (FAIL_FLAT: do not retry within the same tick; retry only if a fresh signal recurs on a later signal bar).

Every stage of this sequence is logged independently, so a partial reversal (closed but didn't reopen) is always visible in the log.

**HEDGING:** independent positions in both directions are permitted, capped by Max_Open_Positions per direction (EA-owned positions only). A new signal never closes an existing opposite position automatically — each is managed independently until its own SL/TP or trailing stop.

**Aggregation logic — split into two stages:** a Strategy Signal stage, and a separate Execution Eligibility stage.

**Stage 1 — Strategy Signal** (this alone is what SIGNAL_ONLY reports):

1. Module A produces a raw directional signal on a newly closed LTF bar (the signal bar, shift 1).
2. Module B's HTF_Bias is LONG_ONLY or SHORT_ONLY and matches the signal direction (if HTF_Bias = BLOCKED, no signal in either direction).
3. Module C — evaluated on the same signal bar as Module A — does not veto.

If all three hold, the pipeline reaches `STRATEGY_SIGNAL_GENERATED`: the strategy would trade this direction, independent of whether the EA is currently able to execute it.

**Stage 2 — Execution Eligibility** (only relevant to whether an order is actually attempted; evaluated after Stage 1 passes, in both modes, but only acted on in AUTO):

4. Position count in the signal direction < Max_Open_Positions (EA-owned positions only; NETTING: effectively capped at 1 net position, and additionally subject to Block_On_ForeignNettingExposure; HEDGING: checked per direction).
5. Order validation (AUTO mode only): current spread ≤ MaxSpread_Points, and pre-fill broker constraints (lot step, margin, etc.) are satisfiable.

**Mode behavior:**

- **SIGNAL_ONLY:** logs/alerts on `STRATEGY_SIGNAL_GENERATED` unconditionally, i.e. purely from Stage 1. It additionally evaluates Stage 2's position-count check (step 4) for informational purposes only — if execution would currently be blocked, it logs `EXECUTION_WOULD_BE_BLOCKED` alongside the signal, but this never suppresses the signal log itself. SIGNAL_ONLY never evaluates order validation (step 5) and never submits, modifies, closes, or reverses anything, and never runs the trailing-stop logic — this applies even if a position happens to exist on the account from manual trading or a prior AUTO-mode run.
- **AUTO:** requires both stages — Stage 1, then Stage 2 including order validation — to pass before submitting an order.

## 5. Non-Functional Requirements

- Signal generation vs. position management are architecturally separate: Modules A–C (signal generation) are strictly closed-bar only — no intrabar recalculation, evaluated once per newly-closed LTF candle (see dedup rule below). Module D's position management (trailing stop, in particular) is tick-based and reacts every OnTick().
- **Signal de-duplication:** a signal evaluation cycle (Modules A→B→C→D) executes exactly once per newly-closed LTF candle. Implementation should track `lastProcessedBarTime` (or equivalent) and skip evaluation entirely if the current candle's open time matches the last processed one, regardless of how many ticks arrive.
- Indicator handles (iMA, iRSI, iMACD, iStochastic, iCCI, iATR) used via standard MT5 API rather than manual buffer math.
- **Data readiness:** if any required indicator buffer doesn't yet have enough bars, the EA must not generate a signal and must log `DATA_NOT_READY`. Compute one centralized required-bars figure at OnInit():
  ```
  RequiredBars = max(SlowMA_Period, TrendConfirm_Bars, Regression_Bars, LTF_ATR_Period,
                      ATR_Period, ATR_Avg_Period + ATR_Contraction_Bars + 1, RSI_Period,
                      MACD_Slow + MACD_Signal, Stoch_K + Stoch_D + Stoch_Slowing, CCI_Period)
                  + safety margin (e.g. +5 bars)
  ```
  for the LTF, and the equivalent for HTF (HTF_MA_Period, HTF_TrendConfirm_Bars). Refuse to evaluate signals until history covers this figure.
- **Parameter validation at OnInit():** the EA must validate inputs and fail initialization (`INIT_PARAMETERS_INCORRECT`) on invalid combinations, at minimum:
  - FastMA_Period > 0, SlowMA_Period > FastMA_Period
  - TrendConfirm_Bars ≥ 2 (only enforced when `Enable_TrendConfirm_Check = true`), Regression_Bars ≥ 2 (only enforced when `Enable_Angle_Check = true`) — intentionally independent of each other; no relationship between them is enforced
  - 0 ≤ MinCross_Angle_Deg ≤ 90 (bounded by construction; also reject NaN/infinite values) — only enforced when `Enable_Angle_Check = true`
  - MinMA_Separation ≥ 0
  - HTF_Timeframe must be strictly higher than LTF_Timeframe — reject HTF_Timeframe ≤ LTF_Timeframe outright
  - HTF_MA_Period > 0, HTF_TrendConfirm_Bars ≥ 2
  - RSI_Period ≥ 2, 0 < RSI_Oversold < RSI_Overbought < 100
  - 0 < Stoch_Oversold < Stoch_Overbought < 100, Stoch_K ≥ 1, Stoch_D ≥ 1, Stoch_Slowing ≥ 1
  - MACD_Fast ≥ 1, MACD_Slow > MACD_Fast, MACD_Signal ≥ 1, MACD_Decline_Bars ≥ 1
  - CCI_Period ≥ 2
  - ATR_Period ≥ 1, ATR_Avg_Period ≥ 2, ATR_Avg_Period ≥ ATR_Contraction_Bars + 1
  - LTF_ATR_Period ≥ 1 (when `Enable_Angle_Check = true` and Enable_ATR_AngleNormalization = true, or when `Enable_Separation_Check = true` and MinMA_Separation_Unit = ATR_Multiple)
  - Lot_Size > 0; StopLoss_Points > 0; TakeProfit_Points > 0 (when Exit_Mode = FIXED_SLTP); Trailing_Start_Points > 0, Trailing_Distance_Points > 0, Trailing_Step_Points > 0 (when Exit_Mode = TRAILING_STOP), and Trailing_Distance_Points ≤ Trailing_Start_Points is a hard rejection
  - Account_Mode = FORCE_NETTING or FORCE_HEDGING is rejected (INIT_FAILED) unless `MQLInfoInteger(MQL_TESTER) == true`
  - MaxSpread_Points > 0, MaxDeviation_Points ≥ 0
  - Max_Open_Positions ≥ 1
  - Magic_Number ≥ 0
- **Order validation before submission:** broker constraints (minimum/maximum lot, lot step, minimum stop distance, freeze level, symbol trading mode, market-closed state, filling mode, margin sufficiency) must be checked before sending any order, and rejected orders logged with the broker's returned error rather than failing silently.
- **Logging with standardized reason codes:** `A_NO_CROSS`, `A_TREND_CONFIRM_FAIL`, `A_ANGLE_FAIL`, `A_SEPARATION_FAIL`, `B_HTF_BLOCKED`, `C_MOMENTUM_FAIL`, `C_ATR_CONTRACTION`, `D_MAX_POSITIONS`, `D_ACCOUNT_MODE_MISMATCH`, `D_FOREIGN_EXPOSURE_BLOCKED`, `D_SPREAD_EXCEEDED`, `D_CLOSE_FAILED`, `D_ORDER_REJECTED`, `D_INSUFFICIENT_MARGIN`, `DATA_NOT_READY`, `EXECUTION_WOULD_BE_BLOCKED`.
- **Signal vs. order state distinction:** `RAW_SIGNAL → HTF_APPROVED → MOMENTUM_APPROVED (= STRATEGY_SIGNAL_GENERATED) → POSITION_ALLOWED → ORDER_VALIDATED (pre-fill) → ORDER_SUBMITTED → ORDER_FILLED → SLTP_VALIDATED (post-fill) → SLTP_ATTACHED`. NETTING reversal has its own branch: `POSITION_ALLOWED → CLOSE_VALIDATED → CLOSE_SUBMITTED → CLOSE_CONFIRMED / CLOSE_FAILED → OPEN_VALIDATED (fresh) → OPEN_SUBMITTED → OPEN_FILLED / FAIL_FLAT`.
- **Built-in veto-rate diagnostics (added v1.9):** the EA maintains a running counter for every reason code above (per module, per bar) for the lifetime of the run, and prints a summary block at `OnDeinit()` — total LTF bars evaluated, and a pass/fail breakdown per module (A/B/C), the count of `STRATEGY_SIGNAL_GENERATED`, and orders actually attempted. When any bars are rejected by `A_ANGLE_FAIL`, the summary additionally reports the min/avg/max of the actual computed `angle_degrees` values on those rejected bars, so `MinCross_Angle_Deg` can be calibrated from the real distribution of a given symbol/timeframe rather than by trial and error. This directly implements the veto-rate analysis called for in Section 6, without requiring external tooling or log-scraping — combined with the debug toggles (Section 1, Module A), a tester can isolate exactly one filter, run a backtest, and read the summary to see whether that filter alone is over-rejecting.

**Canonical engine structure (informative):**

```
OnTick():
    ManageExistingPositions()        // trailing stop logic, every tick — includes its own
                                      // broker validation per candidate SL, see Module D
    if not NewClosedLTFCandle():     // dedup via lastProcessedBarTime
        return
    SignalBar = LTF shift 1
    A = EvaluateModuleA(SignalBar)   // crossover, trend confirm, angle, separation
    if not A.passed:
        Log(A.reasonCode); return
    B = EvaluateModuleB()            // most recently completed HTF candle
    if not B.permits(A.direction):
        Log(B.reasonCode); return
    C = EvaluateModuleC(SignalBar)   // same signal bar as A
    if not C.passed:
        Log(C.reasonCode); return
    // --- Stage 1 complete: STRATEGY_SIGNAL_GENERATED ---
    FinalSignal = A.direction
    executionAllowed = ModuleD.PositionAllowed(A.direction)   // Stage 2, step 4
    if Execution_Mode == SIGNAL_ONLY:
        if executionAllowed:
            LogAndAlert(FinalSignal)                          // signal only
        else:
            LogAndAlert(FinalSignal, EXECUTION_WOULD_BE_BLOCKED)  // signal still reported
        return
    if not executionAllowed:
        Log(D_MAX_POSITIONS); return          // also covers D_FOREIGN_EXPOSURE_BLOCKED
    if not ModuleD.OrderValidated(A.direction):   // pre-fill checks only, see Module D
        Log(D_SPREAD_EXCEEDED / broker constraint code); return
    ModuleD.Execute(FinalSignal)  // submits order, then post-fill computes/validates/attaches SL-TP
                                  // handles account-mode-aware submission (netting reversal branch, etc.)
```

## 6. Testing & Validation Plan

1. Unit-level validation of each module in isolation using synthetic MA sequences, including test cases for both bullish and bearish crossovers to confirm the angle-between-lines calculation produces the same magnitude-based pass/fail behavior regardless of direction, and an explicit near-perpendicular-slopes case to confirm the `1 + b_fast′×b_slow′ = 0` degenerate case is handled without a divide-by-zero.
2. Historical backtest using Dukascopy tick data, staged as: Module A only → A+B → A+B+C, to isolate the marginal effect of each filter. Additionally test A+C in isolation of B, and compare trade frequency/quality across different Momentum_Filter selections. Also isolate the angle check from the separation check (angle-only, separation-only, both).
3. Boundary testing at exact threshold values (MinCross_Angle_Deg at its 0/90 bounds, MinMA_Separation in both unit modes, momentum thresholds, `%K[1] = 50` for Stochastic).
4. Visual verification on chart (plot fast/slow MA, HTF MA, and mark accepted vs. vetoed signals with the blocking reason) before enabling AUTO mode live.
5. Veto-rate analysis: measure the pass rate at each stage explicitly — total raw crosses → A pass % → B pass % → C pass % → position-eligible % → orders actually sent — to surface unintended bottlenecks before tuning is attempted.
6. **Isolation procedure using the v1.9 debug toggles:** run the backtest with `Enable_TrendConfirm_Check`, `Enable_Angle_Check`, `Enable_Separation_Check` all set to `false`, `Momentum_Filter = NONE`, and `Enable_ATR_VolatilityFilter = false` — this exercises only the mandatory primary condition (LTF crossover + HTF gate) and should produce a healthy trade count if the core logic and historical data are sound. Then re-enable exactly one toggle, re-run, and compare the veto-rate summary (Section 5) against the baseline. Repeat one filter at a time. A filter whose re-enabling collapses `STRATEGY_SIGNAL_GENERATED` back toward zero is either mis-implemented or configured with an unreachable threshold for the tested symbol/timeframe — cross-check its specific counter and (for the angle check) the reported min/avg/max angle values against its configured threshold before concluding which.

## 7. Assumptions Requiring Confirmation

- **Netting reversal behavior** — confirm Netting_ReverseOnOppositeSignal should default to true. Still open.
- **Exit management scope** — whether the default trailing values (200/150/10 points) need per-symbol backtesting before going live. Still open.
- **Regression window length** — Regression_Bars = 3 is close to a simple two-point slope; worth backtesting 3/5/8/10. Still open.
- **CCI role** — currently directional-confirmation, not true exhaustion. Confirm acceptable, or scope a separate CCI-exhaustion mode later. Still open.
- **Foreign/manual exposure under NETTING** — Block_On_ForeignNettingExposure defaults true (block). Please confirm this is the right default vs. letting the EA manage combined exposure. Still open.
- **Spread/deviation policy** — MaxSpread_Points (default 30, hard veto) and MaxDeviation_Points (default 10). Please confirm these defaults are reasonable for target symbols, or whether spread should only be logged rather than vetoing. Still open.
- **Filter correlation across A/B/C, and within A** — documented as a testing consideration, not a code change. Worth deliberately testing filter combinations rather than assuming "more filters = better."

## 8. Appendix — Angle-Between-Lines Calculation, and the Raw/ATR Normalization Toggle

The metric is computed between the fast-MA and slow-MA regression lines themselves — not between one line and the horizontal axis. Fit two separate linear regressions over the same window (MA[Regression_Bars] .. MA[1], shift 1 through Regression_Bars), one through the fast MA values and one through the slow MA values, giving slopes b_fast and b_slow. The angle between two lines with known slopes has a standard closed form:

```
angle_degrees = atan( |(b_fast − b_slow) / (1 + b_fast × b_slow)| ) × (180 / π)
```

This value is a magnitude (bounded 0°–90°) — it describes how sharply the two lines are diverging, not which direction the market is moving. Direction (LONG/SHORT) is established separately, in Module A's crossover-detection step. This is the angle between the two regression lines, not necessarily "at their crossing" — the two fitted lines don't have to actually intersect within the observed window; the formula still produces a well-defined angle regardless, since it depends only on the two slopes, not on where or whether they meet.

**Terminology note:** this is a "crossing-angle metric," not a strict geometric angle, in either mode. `atan()` of a slope only produces a literal chart angle when the two axes (bar index and price) are already expressed in comparable units — which they never are here, in either Raw or ATR-normalized form. Raw mode implicitly treats "1 bar" and "1 price unit" as the same scale, which is an arbitrary choice with no inherent meaning. ATR normalization instead implicitly treats "1 bar" and "1 ATR of price" as the same scale — a more economically meaningful choice, but still a chosen rescaling, not a recovery of some underlying "true" angle. `MinCross_Angle_Deg` should be understood as a tuning knob, not a literal degree measurement of anything visible on the chart.

**Raw vs. ATR-normalized:**

- **Raw (toggle off):** use b_fast and b_slow as-is (price/bar) in the formula above.
- **ATR-normalized (toggle on, default):** rescale both slopes by the same reference before applying the formula — `b_fast′ = b_fast / ATR[1]`, `b_slow′ = b_slow / ATR[1]` (using LTF_ATR_Period; guard ATR[1] ≤ 0) — then compute the angle formula on the normalized slopes.

**Default:** toggle ON (ATR-normalized) — Raw mode's numbers are numerically tiny for typical FX price scales, so Raw mode requires per-symbol threshold re-tuning. Raw mode remains available for a single hand-tuned symbol/timeframe.

**Why this doesn't need a directional (signed) comparison:** under this two-line-angle design, the angle is unsigned by construction, so there's no sign to compare — the magnitude check (`angle_degrees ≥ MinCross_Angle_Deg`) applies identically regardless of whether the underlying signal is LONG or SHORT, because direction was already decided in Module A's crossover-detection step.

## 9. Version History

**Normative rule:** only the active requirements in Sections 1–8 above are binding. This table is informational/historical only. Where an entry below describes a design that was later superseded, the current section text always wins.

| Version | Date | Notes |
|---|---|---|
| 1.0 | 2026-08-12 | Initial draft PRD |
| 1.1 | 2026-08-12 | Added ATR as 5th momentum-filter option (default); added Account_Mode (NETTING/HEDGING) as an input with distinct logic per mode; switched default angle normalization to Raw slope and added Raw-vs-ATR comparison in Appendix |
| 1.2 | 2026-08-12 | Confirmed shared MA_Method as an input; split ATR out of the momentum radio group into an independent Enable_ATR_VolatilityFilter toggle; hardcoded ranging/neutral HTF to block all trades; added Exit_Mode input (FIXED_SLTP / TRAILING_STOP) with trailing-stop parameters |
| 1.3 | 2026-08-12 | Removed separate HTF_MA_Method/HTF_MA_AppliedPrice — all three MAs share one MA_Method/MA_AppliedPrice; moved Module C from HTF to LTF |
| 1.4 | 2026-08-12 | Logic-hardening revision: added bar-indexing/synchronization convention (Section 4.0); removed Extrapolate_Bars; replaced Angle_NormalizationMode enum with Enable_ATR_AngleNormalization toggle (default off/Raw); precisely defined RSI/MACD/Stochastic/ATR criteria; re-scoped CCI as directional confirmation; changed Account_Mode to default AUTO with FORCE_* for testing only; added transactional close-then-open sequence for netting reversals; defined SIGNAL_ONLY as touching no positions at all; defined trailing-stop Bid/Ask references and stop-never-loosens rule; added parameter validation, data-readiness handling, signal de-duplication, standardized logging reason codes, signal/order state model, canonical engine pseudocode |
| 1.5 | 2026-08-12 | Fixed critical bug where the angle check compared a signed angle against a positive threshold using `<`, discarding every bearish signal outright; flipped Enable_ATR_AngleNormalization default to on; added shared LTF_ATR_Period input; wrote out exact symmetric SHORT formulas for MACD and Stochastic; fixed ATR contraction filter's reference average to exclude current bar; added Block_On_ForeignNettingExposure, MaxSpread_Points, MaxDeviation_Points; enforced FORCE_NETTING/FORCE_HEDGING as tester-only at OnInit(); scoped position logic to Symbol+Magic; named FAIL_FLAT; added ORDER_VALIDATED state; documented A/B/C filter-correlation caution |
| 1.6 | 2026-08-12 | Self-review pass: corrected stale AngleATR_Period references in Appendix; declared RSI_Overbought/RSI_Oversold and Stoch_Overbought/Stoch_Oversold as explicit inputs; fixed canonical engine pseudocode/aggregation logic drift (SIGNAL_ONLY correctly returns before order validation); added open question on Regression_Bars vs TrendConfirm_Bars relationship |
| 1.7 | 2026-08-12 | Redesigned the angle check: measured between the fast-MA and slow-MA regression lines (each fit independently), not between one line and the horizontal. Uses the standard two-line-slope angle formula. Magnitude by construction, superseding the v1.5 signed-comparison fix. Resolved the "regression reference line" and "Extrapolate_Bars reinterpretation" open questions. ATR normalization toggle retained, applied to both slopes symmetrically |
| 1.8 | 2026-08-12 | Removed dead CCI_Overbought input; corrected angle terminology throughout ("crossing-angle metric," not literal geometric angle); fixed misleading "at their crossing" phrasing; added `0 ≤ MinCross_Angle_Deg ≤ 90` bound validation; documented Regression_Bars/TrendConfirm_Bars as intentionally independent; named the angle check a divergence/convergence-rate filter and noted correlation with separation check; split order validation into pre-fill and post-fill stages; required fresh re-validation for reversal reopen leg; added broker validation to every trailing-stop modification; precisely defined trailing step as SL movement; made Trailing_Distance_Points ≤ Trailing_Start_Points a hard validation; defined Pips explicitly, scoped to FX; added RSI/Stochastic threshold-ordering validation and period-floor validations; added Max_Open_Positions ≥ 1 and Magic_Number ≥ 0 validation; added ATR[1] ≤ 0 guard; clarified foreign-exposure ownership check; restructured aggregation logic into Strategy Signal / Execution Eligibility stages; expanded state model with netting-reversal branch; added centralized required-history-bars formula; added Module C 4-configuration reference table; added strict-monotonic-classification callouts; added veto-rate analysis to testing plan |
| 1.9 | 2026-08-12 | Debugging revision, driven by first live backtest producing zero trades (root cause: default `MinCross_Angle_Deg=15` with ATR-normalized 3-bar-regression slopes rejected 100% of crosses that survived trend-confirmation on EURUSD M15). Established the LTF crossover (Module A step 1) plus the HTF trend gate (Module B) as the mandatory, non-toggleable primary trade condition; added three independent debug toggles to Module A — `Enable_TrendConfirm_Check`, `Enable_Angle_Check`, `Enable_Separation_Check` — so steps 2–4 can each be isolated one at a time without editing code (Momentum_Filter=NONE and Enable_ATR_VolatilityFilter=false already served this role for Module C); made the corresponding OnInit() parameter validation conditional on each toggle (TrendConfirm_Bars/Regression_Bars/MinCross_Angle_Deg bound checks and the LTF_ATR_Period requirement now only apply when their owning check is enabled); added a built-in veto-rate diagnostic — per-module pass/fail counters plus an OnDeinit() summary printout, including min/avg/max of actual computed angle values on angle-check rejections — implementing Section 6's veto-rate analysis directly in the EA rather than requiring external log-scraping; added a corresponding isolation procedure to the testing plan (Section 6, item 6) and a field observation under the angle check documenting the initial 100%-rejection finding. |
| 1.10 | 2026-08-12 | Corresponds to code folder Autotrader/MACrossEA_1.1 (staged modular rebuild): strengthened Module B with a second, independent confirmation. Previously HTF_Bias was decided purely by MA-value monotonicity (HTF_TrendConfirm_Bars); it now additionally requires HTF candle-color agreement over the new HTF_ConfirmationCandles input, with both confirmations required to agree before HTF_Bias is anything other than BLOCKED. The candle-color window deliberately starts at HTF shift 0 (the currently-developing candle) rather than shift 1 — an explicit, called-out exception to the Section 4.0 "never read shift 0" rule, justified by the requirement being "is the developing candle *currently* moving with the trend," re-evaluated fresh on every Module B run rather than frozen at the last HTF close. Confirmed this is a live-value read, not repainting: no earlier decision is ever revised, only the current bar's evaluation can differ tick-to-tick as the live candle develops. Added the corresponding OnInit() validation (HTF_ConfirmationCandles ≥ 1) and centralized-required-bars consideration. |
| 1.11 | 2026-08-12 | Edited directly into code folder Autotrader/MACrossEA_1.1 (not a new version folder — this is an additive capability alongside the existing design, not a redesign of existing logic; see the versioning-granularity note this revision established). Implemented Module D's Exit_Mode toggle in code for the first time — previously only specified in this document, never built. `CPositionCore::UpdateTrailing()` added: tightens-only, stops-level- and freeze-level-aware, step-gated exactly as specified below (SL movement, not raw price movement), runs every tick independent of the closed-bar signal gate. `OpenTradeForSignal` now branches on InpExitMode: FIXED_SLTP submits both SL and TP as before; TRAILING_STOP submits only the initial protective SL (InpStopLossPoints) with tpRaw=0, and the pre-existing tp<=0-skips-validation path in `CTradeValidator`/`ClampLevel` already handled this correctly with one fix needed — the caller must guard `ClampLevel(isBuy, tpRaw, true)` behind `tpRaw > 0.0` itself, since ClampLevel has no zero-means-absent special case of its own and would otherwise clamp a phantom TP into a real price level. OnInit() validation now branches identically to the exit-mode logic (FIXED_SLTP requires TakeProfit_Points > 0; TRAILING_STOP requires all three Trailing_* inputs > 0 and Trailing_Distance_Points ≤ Trailing_Start_Points as a hard rejection, both already specified below but not previously enforced in code). |
| 1.12 | 2026-08-12 | New code folder Autotrader/MACrossEA_1.2 (this one is a redesign of Module A's core signal logic, not an additive feature — same category as the 1.1/1.10 Module B change, so per the versioning-granularity note it gets its own folder rather than being edited into 1.1). Mirrored Module B's v1.1 two-confirmation pattern onto Module A's crossover direction: `InpLTFTrendConfirmBars` (renamed from `TrendConfirm_Bars`, pairing with `InpHTFTrendConfirmBars`) and the new `InpLTFConfirmationCandles` are both now mandatory, non-toggleable gates on the raw crossover from step 1 — direction still comes solely from the crossover; confirmation can only veto an already-decided direction, never change it. Unlike Module B's HTF candle check, `LTFCandlesBullish`/`LTFCandlesBearish` deliberately do NOT read shift 0 — the LTF's own developing candle at Module A's evaluation instant has only just begun forming and carries no signal, unlike HTF's substantially-developed one; see Indicators.mqh and Section 4.0. `SignalEvaluation` gained a `LTFConfirmed` field and `ENUM_REJECT_REASON` gained `REJECT_LTF_NOT_CONFIRMED`, both threaded through the veto-rate diagnostic (checked before the HTF gate, so a rejection is attributed to whichever gate actually vetoed it). Added the corresponding OnInit() validation (`InpLTFTrendConfirmBars ≥ 2`, `InpLTFConfirmationCandles ≥ 1`) and folded both into the centralized LTF required-bars calculation. |
