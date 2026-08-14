# PRD: Multi-Filter MA Crossover Expert Advisor (MQL5)

**Version:** 1.13 (Draft)
**Platform:** MetaTrader 5 / MQL5
**Status:** Draft for review — see Section 7 (Assumptions Requiring Confirmation) before implementation
**Code folder:** Autotrader/MACrossEA_1.3 (forked from Autotrader/MACrossEA_1.2, include paths renamed `MACrossEA_1.2/` → `MACrossEA_1.3/`). Carries forward Module A step 1 + the v1.2 LTF confirmation gate (see note under Module A) + Module B + Module D's Exit_Mode toggle, and adds **Module E** in `Include/MACrossEA_1.3/ExitEngine.mqh`, `SwingStructure.mqh`, and `BarSource.mqh`, with tests in `Scripts/TestExitEngine.mq5`. Modules A's angle/separation checks and Module C remain unbuilt, as in 1.2.

## 1. Overview

This EA generates trade signals from a fast/slow moving average (MA) crossover on a trading timeframe ("LTF"), filtered by:

- Trend-quality confirmation on the LTF crossover itself (directional consistency + slope/angle + minimum MA separation).
- A higher-timeframe ("HTF") MA trend filter that restricts trade direction.
- A single, mutually-exclusive momentum/oscillator filter (radio-button style), plus an independent ATR volatility filter, both evaluated on the LTF (the same timeframe as the crossover signal) that can veto a trade for exhaustion of the specific move being entered.

Once a position is open it is managed by two independent mechanisms: Module D's Exit_Mode (fixed SL/TP or trailing stop), and — new in v1.13 — Module E, which monitors the LTF swing structure that justified the trade and exits when that structure fails. Module E is deliberately *not* the inverse of the entry condition; see its Design principle note.

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
- Structural trade management: monitoring an open position against the LTF swing structure that justified it, and exiting when that structure fails (Module E, added v1.13)

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
| Swing pivot | A confirmed local low/high with `Exit_PivotStrength` bars on each side satisfying the normative comparison in Module E. Never revised once confirmed |
| Confirmation bar | The bar exactly `Exit_PivotStrength` bars newer than a pivot bar — the bar at which that pivot first becomes knowable (Module E) |
| Anchor | The swing low (LONG) / swing high (SHORT) a position is currently defending. Ratchets in the favorable direction only (Module E) |

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
- **Module E (LTF structural exit, v1.13):** evaluated on that same newly-closed LTF signal bar (shift 1), once per bar, and **before** Modules A–C, so an open position is always managed on the current bar's information before a new signal on that bar is considered. Swing pivots are scanned from shift `Exit_PivotStrength + 1` and older, which guarantees both sides of every confirmed pivot are closed bars — Module E never reads shift 0, with no exception. Its HTF backstop reads HTF shift 1 and older for **both** confirmations, deliberately excluding the shift-0 developing candle that Module B's candle check includes (see Module E for why the exception does not transfer to exits). All Module E state that must survive new bars or a restart is keyed by **bar open time**, never by shift, and every time→shift conversion uses `iBarShift(..., exact = true)`.

One synchronization rule ties all three together: every signal evaluation cycle is anchored to one specific newly-closed LTF candle (shift 1). Modules A and C both read that exact candle's closed values. Module B reads whichever HTF candle was most recently completed as of that same moment (HTF shift 1). Module E evaluates on that same candle, ahead of A–C. This single rule resolves the indexing ambiguity across every module rather than defining it separately per indicator.

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

### Module E — LTF Structural Trade Exit (new in v1.13)

**Purpose.** Modules A–C decide whether to *open* a trade; Module E decides whether the LTF trend that justified an already-open trade has **failed**. It is deliberately not the inverse of the entry condition: requiring the entry evidence to reverse would exit at the opposite crossover, which is the same lag the crossover already suffers on entry. Instead, Module E monitors the one thing that defines a trend independently of any indicator — the swing sequence — and exits when it breaks.

For a LONG, the trade premise is a sequence of higher lows. The premise has failed when price closes below the latest *meaningful* higher low. For a SHORT, mirrored: closes above the latest meaningful lower high. That single test is the entire primary mechanism.

**Design principle (read before adding anything to this module):** every additional exit trigger is a second way to leave a trade, and two exit mechanisms cannot be tuned independently from the same backtest — a trade exited by one is invisible to the other. Module E therefore has exactly one primary trigger and one backstop. Anything else under "Deliberately excluded" below is logged as a diagnostic counter so its value can be *measured* before it is ever given authority to close a position.

**Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| Enable_StructuralExit (code: `InpEnableStructuralExit`) | bool | true | Master toggle, same isolation philosophy as Module A's v1.9 debug toggles. When false, Module E does not evaluate at all and positions are managed solely by Exit_Mode. |
| Exit_PivotStrength (code: `InpExitPivotStrength`) | int | 2 | Bars required on each side of a swing pivot for it to be *confirmed*. Higher = fewer, more significant pivots and a later-recognized anchor; lower = more responsive and noisier. |
| Exit_MinSwingATR (code: `InpExitMinSwingATR`) | double | 0.5 | Significance threshold, in ATR multiples, used in two places: (a) a newly confirmed swing only replaces the current anchor if it is at least this far beyond it, and (b) the initial anchor must be at least this far from the entry price. This is the parameter that prevents a trivial pullback pivot from becoming the defended level. Must be ≥ `Exit_StructureBufferATR` — see Section 5 validation. |
| Exit_StructureBufferATR (code: `InpExitStructureBufferATR`) | double | 0.2 | Noise buffer on the break test: the close must exceed the anchor by this multiple of ATR before the break counts. Makes "broken" volatility-adaptive rather than a fixed point distance. |
| Exit_ScanBars (code: `InpExitScanBars`) | int | 100 | Size of the initial-anchor search window, measured **backwards from the entry bar** — see the scan-window definition below. Not measured from the current bar. |
| Exit_ATR_Period (code: `InpExitATRPeriod`) | int | 14 | ATR period used for both thresholds. **Deliberately independent** of Module A's `LTF_ATR_Period` and Module C's `ATR_Period` — the same reasoning already applied between those two. No validation enforces a relationship between them. |

#### Pivot definition (normative — this is the definition for the whole codebase)

Prior revisions left "confirmed swing" as an open implementation point. It is defined here exactly once. With `S = Exit_PivotStrength`, a **swing low at shift i** requires:

```
Low[i] <  Low[i-k]   for all k = 1..S      (newer side — strict)
Low[i] <= Low[i+k]   for all k = 1..S      (older side — non-strict)
```

A **swing high at shift i** is the mirror (`High[i] > High[i-k]`, `High[i] >= High[i+k]`).

Three consequences, all intentional:

- **Ties resolve to the newest bar.** Given adjacent bars with equal lows, only the newer satisfies the strict-newer-side test, so a flat plateau produces exactly one pivot, never zero and never two.
- **A pivot is only knowable `S` bars after it formed.** Because exactly one bar reaches shift `S+1` per new bar, **at most one swing low — and, separately, at most one swing high — confirms per bar.** A single outside bar can be both a swing high and a swing low; that is legal and harmless, since Module E only ever scans one side per position direction.
- **A confirmed pivot never changes.** Once recognized it cannot be revised by later bars, so the anchor cannot repaint.

**Implementation contract.** The predicate is exposed as `IsConfirmedSwingLow(pivotShift, S)` / `IsConfirmedSwingHigh(pivotShift, S)` and each **enforces `pivotShift ≥ S+1` internally**, returning false otherwise. Callers must not be the only guard against an out-of-range shift.

**Series access is abstracted (`BarSource.mqh`).** Module E reads price and ATR through a `CBarSource` rather than calling `iHigh`/`iLow`/`iATR` directly: `CLiveBarSource` for the terminal, `CArrayBarSource` for synthetic history. This is not decoration — Section 6 item 11 makes "continuous evaluation ≡ batch/replay evaluation" the module's primary regression guard, and that test cannot be written at all against direct series calls, because there is no way to feed the engine a controlled sequence or rewind it. `CArrayBarSource` exposes an origin cursor that hides everything newer than a chosen bar, which is what makes both replay orders expressible against one fixed history. Test harnesses must place the just-closed bar at **shift 1** (shift 0 standing in for the forming bar), matching Section 4.0 — an off-by-one here makes every test agree with itself and disagree with production.

**Single canonical implementation (requirement, not a preference).** The two predicates and the pivot collector live in exactly one place — `Include/MACrossEA_1.3/SwingStructure.mqh`, holding no indicator handles and no state — and both `ExitEngine.mqh` and `ReversalDetector.mqh` call it. No second implementation of the pivot algorithm may exist anywhere in the codebase. `ReversalDetector.mqh` (carried over from the 1.2 folder) currently uses strict comparison on **both** sides, which is a **behavioral** divergence from the definition above, not a documentation one; it must be refactored onto the shared predicate as part of this revision. Because that module is not yet wired into the running EA, the refactor carries no runtime risk at the time it is made. Both callers are covered by the same pivot unit tests (Section 6).

#### Confirmation bar and anchor ATR (normative)

A pivot at shift `p` in the current frame has its **confirmation bar at shift `p − S`** — the bar `S` positions newer than the pivot bar. At the instant of confirmation the pivot sits at shift `S+1`, so its confirmation bar is shift 1, the just-closed bar. Both the pivot bar and the confirmation bar are stored as **bar open times**; shifts are recomputed from those times on each access, never cached:

```
pivotShift        = iBarShift(symbol, LTF_Timeframe, PivotBarTime, true)   // exact
confirmationShift = pivotShift - S                                          // invariant: >= 1
sigma_c           = ATR(Exit_ATR_Period) at confirmationShift
```

`iBarShift` is called with `exact = true` and a return of `-1` is treated as `E_DATA_NOT_READY`. With `exact = false`, a broker history revision would silently relocate a stored anchor onto a neighbouring bar, leaving the anchor's price and its bar out of agreement. `confirmationShift ≥ 1` is an invariant, not an assumption — a pivot cannot be known before its confirmation bar has closed — and implementations must assert it.

**Anchor ATR — one rule, everywhere.** Every anchor carries the ATR of **its own confirmation bar** (`σ_c` above). Never `ATR[1]` at the moment of processing, and never the ATR at the time a pivot happens to be discovered. This single rule governs all three uses:

1. the **significance test** when ratcheting to that candidate,
2. the **entry-distance test** when that candidate is considered as an initial anchor,
3. the **frozen buffer** (`AnchorATR`) used by the break test for as long as that anchor stands.

Determinism follows directly: because `σ_c` depends only on the candidate and not on when it is processed, an anchor established live and the same anchor rebuilt during a replay months later carry identical values. Using `ATR[1]` in any of the three positions breaks replay invariance and restart reconstruction simultaneously.

**Why the ATR is frozen rather than re-read.** If the buffer used current ATR, a violent adverse move would expand ATR — and therefore widen its own exit buffer — exactly when the buffer should hold still. Freezing also makes the exit level a fixed known number for the life of the anchor, a precondition for the Section 7 open question on SL placement. A deliberate second consequence: swing significance is judged **permanently in the volatility regime that produced the swing**. A pivot that fails the significance test does not become eligible later merely because volatility has since fallen. That is the intended reading of "was this swing meaningful," and it is what makes the test order-independent.

#### Per-position state

Keyed by **`PositionTicket`** — not by symbol, since a hedging account can hold several positions on one symbol and the ticket is the only stable identity across them.

| Field | Set when | Purpose |
|---|---|---|
| `PositionTicket` | fill / adoption | state key |
| `Direction`, `EntryTime`, `EntryPrice` | fill / adoption | `EntryTime` is the broker fill time; `EntryPrice` is `POSITION_PRICE_OPEN` |
| `EntryBarTime` | fill / adoption | open time of the LTF bar **containing** the fill. All candidate comparisons use this, not `EntryTime` |
| `InitialAnchor` | first successful initialization | never modified afterwards; feeds the anchor-travel diagnostic |
| `ProtectedAnchor` | initialization, then each ratchet | the swing low (LONG) / high (SHORT) currently defended |
| `AnchorBarTime` | initialization, then each ratchet | open time of the anchor's pivot bar |
| `AnchorATR` | initialization, then each ratchet | `σ_c` of that anchor's confirmation bar — frozen |
| `LastExaminedPivotTime` | initialization, then each ratchet pass | newest pivot bar already tested; see the ratchet skip rule |
| `HTFEntryBias` | fill | **diagnostic/audit only — takes no part in any exit decision.** The HTF backstop compares current bias against `Direction`, never against this field |
| `AnchorActive` | see transitions | false until a qualifying anchor exists |
| `ClosePending` | close submission | guards against duplicate close requests |

#### Logic — once per newly closed LTF bar (signal bar, shift 1), for each EA-owned open position

```
for each EA-owned open position, by ticket:
    if the position is no longer open:            // e.g. SL fired between bar close and evaluation
        finalize and discard state; continue
    htfOpposite = HTF_Confirmed_Bias is the direct opposite of Direction
    if Module E data is not ready:
        log E_DATA_NOT_READY
        if htfOpposite: Close(E_HTF_CONFIRMED_OPPOSITE)
        continue                                   // anchor untouched; no init, no ratchet, no break test
    if not AnchorActive: Initialize()               // step 1
    if AnchorActive:     RatchetReplay()            // step 2
    structBreak = AnchorActive and BreakTest()      // step 3
    if   structBreak: Close(E_STRUCT_EXIT)
    elif htfOpposite: Close(E_HTF_CONFIRMED_OPPOSITE)
```

The HTF backstop is computed first because it depends on neither ATR nor pivots and must remain available when nothing else is, but it is **attributed last**. Ordering it ahead of the structural test would let it claim exits the structural test would have produced on the same bar, corrupting the very diagnostic it is scoped around (see the backstop design note below).

**1. Anchor initialization** — runs on any bar where `AnchorActive == false`, which includes the first evaluation after fill, every later bar until an anchor is found, and adoption after a restart.

The search window is anchored to the **entry bar, not to the current bar**: candidate pivot shifts run from `iBarShift(EntryBarTime)` to `iBarShift(EntryBarTime) + Exit_ScanBars`, floored at `S+1`, scanned newest → oldest. Anchoring the window to the current bar instead would make a position open longer than `Exit_ScanBars` bars impossible to initialize, and would make the same position initialize differently depending on when the search ran.

A candidate qualifies when **all** hold (LONG; mirrored for SHORT):

- `PivotBarTime < EntryBarTime` — the bar containing the fill is excluded, since its low is formed partly after entry;
- its **confirmation bar time ≤ `EntryBarTime`** — see the determinism note below;
- `c.Low < EntryPrice`;
- `EntryPrice − c.Low ≥ Exit_MinSwingATR × σ_c` — the initial anchor must be a meaningful distance from entry, the same significance idea measured against entry instead of against a prior anchor. Without it, a pivot a few ticks below the fill could become the defended level and the position would be stopped by ordinary noise. Trade-off to be aware of when tuning: on a shallow entry this pushes the anchor to an older, deeper swing, so early risk is bounded by the protective SL rather than by structure.

The first candidate satisfying all four is taken. There is **no fallback rule and no already-violated test**: if the break test fires on the same bar the anchor is established, that exit is correct — the structure was already broken and the module simply had no anchor with which to see it. (An earlier draft rejected already-violated candidates and fell back to an older swing. That rule was both self-defeating — step 2 immediately re-ratcheted to the rejected candidate, since it is newer than the fallback and clears the significance test — and wrong in the only case it could fire, which is a delayed initialization after the structure had genuinely failed.)

On success set `ProtectedAnchor`, `AnchorBarTime`, `AnchorATR = σ_c`, `InitialAnchor`, `LastExaminedPivotTime = AnchorBarTime`, `AnchorActive = true`, and log `STRUCT_ANCHOR_SET`. If no candidate qualifies, log `E_NO_ANCHOR` and leave `AnchorActive = false`.

**Determinism note — why confirmation must precede the entry bar.** "The most recent confirmed pivot" is otherwise time-dependent: a pivot formed before entry whose confirmation bar falls *after* the first evaluation is invisible at that first bar and visible fifty bars later. Continuous operation would take the older pivot and then subject the newer one to the ratchet's significance test; a late initialization would take the newer one directly and skip that test — two different anchors from identical inputs. Restricting initialization to candidates confirmed by `EntryBarTime` makes the initial anchor a pure function of (price history, entry), and routes everything confirming later through the ratchet, exactly as a continuous run does. With the default `S = 2` this still admits pivots up to two bars before the entry bar; anything later was equally invisible to a continuous run, so nothing is lost.

**2. Ratchet — chronological replay.** Process **every** confirmed pivot newer than `LastExaminedPivotTime`, in **chronological (oldest → newest)** order, each tested against the anchor as updated by its predecessors:

```
candidates = confirmed swing lows (LONG) with BarTime > LastExaminedPivotTime,
             ordered oldest -> newest, spanning LastExaminedPivotTime .. current bar
for each candidate c:
    sigma_c = ATR(Exit_ATR_Period) at shift (iBarShift(c.BarTime) - S)
    if c.Low >= ProtectedAnchor + Exit_MinSwingATR * sigma_c:
        ProtectedAnchor = c.Low
        AnchorBarTime   = c.BarTime
        AnchorATR       = sigma_c
        log ANCHOR_RATCHETED
    LastExaminedPivotTime = c.BarTime
```

SHORT mirrors: `c.High <= ProtectedAnchor − Exit_MinSwingATR × sigma_c`.

The enumeration spans `LastExaminedPivotTime` to the current bar — it is not a fixed-width window. Advancing `LastExaminedPivotTime` past *non-qualifying* candidates is safe and does not affect replay invariance: the anchor only ever moves in the favorable direction, so the threshold only rises, and `σ_c` is fixed per candidate — a candidate that failed can never later pass. In normal operation there is at most one new candidate per bar, so this reduces to a single test; the loop only does real work after missed evaluations or on adoption.

**Replay invariance is a hard requirement:** the anchor must be identical whether bars were evaluated continuously or in a batch after missed evaluations (restart, connection loss, weekend gap, tester warm-up).

*Why not "the newest qualifying pivot".* Selecting newest-first and stopping at the first qualifying candidate breaks invariance. Anchor 100, threshold 1.0, two pivots pending after a gap — A = 102 (older), C = 101.5 (newer): newest-first ratchets to 101.5, while continuous evaluation would have taken A → 102 and then rejected C (which needs ≥ 103). Chronological order reproduces the continuous result; newest-first under-protects. The per-candidate ATR must likewise be read at that candidate's own confirmation bar, or a batched replay drifts from the continuous one.

**3. Break test.** LONG exits when:

```
Close[1] < ProtectedAnchor − Exit_StructureBufferATR × AnchorATR
```

SHORT exits when `Close[1] > ProtectedAnchor + Exit_StructureBufferATR × AnchorATR`.

#### `AnchorActive` transitions

`E_NO_ANCHOR` is **not terminal**:

```
POSITION_OPEN (AnchorActive = false)
   ├── no qualifying candidate  -> log E_NO_ANCHOR, remain POSITION_OPEN, retry next closed bar
   └── candidate found          -> STRUCT_ANCHOR_SET, AnchorActive = true
```

While `AnchorActive` is false the position is protected solely by Exit_Mode (SL/TP or trailing) plus the HTF backstop.

#### `E_DATA_NOT_READY` and `E_NO_ANCHOR` are distinct states

Conflating them is how a transient data failure silently rewrites a position's protection.

| | Meaning | Effect on existing anchor | Behavior |
|---|---|---|---|
| `E_DATA_NOT_READY` | required OHLC/ATR history or `BarsCalculated` depth unavailable, or an `iBarShift` exact lookup returned −1; the search **could not run** | **Never modified, never cleared** | Skip initialization, ratchet, and break test for this bar. Retry next closed bar. |
| `E_NO_ANCHOR` | history sufficient, search **ran to completion**, no candidate qualified | n/a (no anchor exists) | Retry initialization next closed bar. Non-terminal. |

Three consequences are normative:

- **A data failure must never clear, downgrade, or re-derive a valid existing anchor.** A position that has ratcheted to a good level keeps that level through a temporary history or indicator outage.
- **The break test is skipped entirely under `E_DATA_NOT_READY`.** An unavailable or zero ATR must never be allowed to collapse the buffer to zero and manufacture a break. This subsumes the `ATR[1] ≤ 0` guard applied elsewhere in this document.
- **The HTF backstop still runs.** It depends on neither ATR nor pivots, so LTF data trouble must not disable it — that is exactly the circumstance in which it is the only protection left, and the case it was scoped for.

#### Adoption and restart reconstruction

A position with no in-memory state — adopted after a terminal restart, or opened before the EA started — is reconstructed by running initialization against `POSITION_PRICE_OPEN` / `POSITION_TIME`, then the ratchet replay across every confirmed pivot from `EntryBarTime` to the present.

**Reconstruction is deterministic and reproduces the pre-restart anchor exactly, provided identical LTF OHLC history and ATR history are available across the required depth.** Pivots and confirmation-bar ATR are pure functions of that history, so no persisted state is needed. The guarantee is conditional, and the condition must be *verified* rather than assumed — broker history depth, unsynchronized history after a reconnect, and missing bars can all yield a different anchor from a partial reconstruction. Before reconstruction is attempted:

```
requiredDepth = iBarShift(symbol, LTF, EntryBarTime, true) + Exit_ScanBars + S + 1
iBars(symbol, LTF)              >= requiredDepth
BarsCalculated(exitATRHandle)   >= requiredDepth
```

If either check fails, or the `iBarShift` lookup returns −1, the position is in **`E_DATA_NOT_READY`**, not `E_NO_ANCHOR`; reconstruction is retried each closed bar and no anchor is accepted meanwhile. A partial reconstruction must never be accepted as a valid anchor.

#### `HTF_Confirmed_Bias` — distinct from Module B's `HTF_Bias`

Same two-confirmation structure (MA-monotonic over `HTF_TrendConfirm_Bars` **and** candle colour over `HTF_ConfirmationCandles`), with one difference: the candle window runs HTF shift `1..N`, **excluding the developing candle**. Module B's shift-0 exception (Section 4.0) is correct for entries — "is the developing candle currently moving with the trend" — but must not transfer to exits, because a live candle can flip and flip back within a single HTF bar and an exit acted on that value is irreversible. Entries carry no such asymmetry: a signal missed because the developing candle flipped is simply re-evaluated next bar.

**`HTF_BLOCKED` does not trigger a Module E exit and does not alter structural-exit sensitivity.** Only a confirmed *direct opposite* bias triggers the backstop. Module B already uses BLOCKED to bar new entries; giving one HTF state two jobs is precisely what the excluded sensitivity tiers would have done.

**Design note on the backstop's expected firing rate.** A bias flip from LONG_ONLY to SHORT_ONLY requires 5 consecutive HTF MA declines plus 3 bearish closed HTF candles — on M15/H4, roughly 20 hours of HTF deterioration, by which point the LTF structure will normally have broken many times over. The backstop is expected to be nearly silent, and that is the intent: it covers the cases where the structural exit *cannot* run (no anchor, history gap, adoption not yet reconstructable). If `E_HTF_CONFIRMED_OPPOSITE` fires regularly, the structural exit is not doing its job — that is the finding to investigate, not a reason to tune the backstop. This diagnostic only holds because attribution favours the structural test when both conditions are true on the same bar.

#### Close execution, failure, and duplicate prevention

- Detection and execution are distinct: **detection price is `Close[1]`**; the market order executes at the **first available tick after the bar closes**. The EA cannot transact at the historical candle close. Both prices are logged, and diagnostics (MFE/MAE/R/give-back) report against the execution price, not the detection price.
- On trigger, if `ClosePending` is already set for that ticket, submit nothing. Otherwise submit the close and set `ClosePending`. This matters because `ManageExistingPositions()` runs every tick even though Module E evaluates once per bar, and terminal position state can lag a successful close.
- **Success** → `CLOSE_CONFIRMED`, finalize and discard the per-ticket state.
- **Failure** (requote, trade context busy, market closed, connection loss, broker rejection) → log `D_CLOSE_FAILED` with the exit reason that triggered it, clear `ClosePending`, **retain** the per-position state, and retry on the next eligible LTF evaluation. The retry re-tests the break condition from scratch — it is not a queued order. If price has recovered above the anchor by then, no close is sent. This is deliberate: the structure test is the authority, not the pending request.
- **Position already gone** (SL, TP, manual close, broker action) → finalize the state, no retry, no error.

#### Relationship to Exit_Mode, execution mode, and re-entry

**Exit_Mode (Module D).** Module E is **orthogonal** to Exit_Mode and runs under both settings. It never modifies SL or TP — it only closes at market. Whichever mechanism triggers first wins; under FIXED_SLTP the SL/TP remain exactly as submitted, and under TRAILING_STOP the tick-based trailing continues untouched. One mechanism owning the stop level and another owning the close decision keeps their backtests separable.

**SIGNAL_ONLY.** Module E evaluates and logs `EXIT_WOULD_TRIGGER` with the reason code it would have used, but never closes anything — consistent with SIGNAL_ONLY touching no positions under any circumstance.

**Same-bar exit and re-entry.** Module E evaluates before Modules A–C on the same signal bar, so a position closed by Module E on bar N **may** be followed by a new position opened on bar N if Module A produces a valid fresh crossover on that bar. This is permitted and expected: the common case is an exit-long-then-open-short reversal, which under NETTING follows Module D's existing close-then-open transactional sequence (including FAIL_FLAT). Same-direction re-entry on the same bar is not blocked either, but requires a fresh crossover that the exit conditions make vanishingly unlikely.

**No post-exit cooldown.** Re-entry already requires a fresh Module A crossover (shift 2 → shift 1), which cannot re-fire on the bar that just exited. An explicit cooldown would be a second, redundant suppression mechanism. Documented as a decision, not an omission.

#### Deliberately excluded from this revision

Each was considered and rejected for the first implementation; the first three are logged as diagnostic counters so their value can be measured rather than assumed.

| Excluded | Reason |
|---|---|
| Fast/slow MA cross-back as a hard exit | On a chaotic LTF, a pullback deep enough to cross the MAs but too shallow to break a meaningful swing is common — it would exit trades the structural test correctly holds. Logged as `E_DIAG_MA_CROSSBACK`. |
| Two-level structure (minor = warning, major = exit) | The same knob as `Exit_MinSwingATR` at a second resolution; the significance filter already excludes minor swings from being the anchor. Costs a second threshold whose interaction with the first cannot be tuned without substantial data. Logged as `E_DIAG_MINOR_BREAK`. |
| HTF-neutral sensitivity tiers / trailing tightening on HTF loss | `HTF_BLOCKED` already blocks new entries via Module B; making it also alter exit behavior gives one HTF state two jobs. Logged as `E_DIAG_HTF_NEUTRAL`. |
| `Exit_MinBarsInTrade` grace period | Time-based suppression with no structural meaning; blocks a genuine immediate reversal. Superseded by the entry-distance requirement in initialization. |
| LTF monotonicity loss / opposite-candle-count exits | Both fire on ordinary pullbacks — the noise this module exists to ignore. |
| Runtime "exit level must not loosen" invariant | Provably unnecessary; guaranteed by the `Exit_MinSwingATR ≥ Exit_StructureBufferATR` validation (Section 5). |
| Already-violated rejection / fallback to an older initial anchor | Self-defeating (the ratchet re-selected the rejected candidate on the same bar) and wrong in the only case it could fire. See initialization above. |
| Partial closes / scale-outs | Out of scope per Section 2 — positions are always closed in full. |

## 5. Non-Functional Requirements

- Signal generation vs. position management are architecturally separate: Modules A–C (signal generation) are strictly closed-bar only — no intrabar recalculation, evaluated once per newly-closed LTF candle (see dedup rule below). Module D's position management (trailing stop, in particular) is tick-based and reacts every OnTick(). Module E (structural exit) is closed-bar only like A–C, despite being position management: its decision is defined on `Close[1]`, and re-evaluating it intrabar would reintroduce exactly the noise sensitivity the module exists to avoid.
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

  **Module E terms (v1.13):** `RequiredBars` additionally takes `Exit_ScanBars + Exit_PivotStrength + 1` and `Exit_ATR_Period` into the same `max()`. The `+ Exit_PivotStrength + 1` is not padding: `Exit_ScanBars` is the size of the initial-anchor search window, and a pivot at its far edge compares against bars a further `S` older, so that is the true depth. The deepest ATR read is the oldest candidate's confirmation bar, `S` bars *newer* than the oldest pivot examined, so it is strictly inside the OHLC requirement and adds nothing. `BarsCalculated()` on the Module E ATR handle must cover the same figure. For an **adopted** position the requirement is measured from the entry bar instead of from the current bar — `iBarShift(EntryBarTime, exact) + Exit_ScanBars + S + 1` — and failing it yields `E_DATA_NOT_READY`, never `E_NO_ANCHOR` (see Module E).
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
  - **Module E (v1.13), all enforced only when `Enable_StructuralExit = true`**, matching the v1.9 conditional-validation pattern:
    - Exit_PivotStrength ≥ 1
    - Exit_MinSwingATR ≥ 0, Exit_StructureBufferATR ≥ 0 (zero is legal on both and means "no significance requirement" / "no buffer" — useful for isolation testing)
    - **Exit_MinSwingATR ≥ Exit_StructureBufferATR — hard rejection.** This single rule guarantees the effective exit level can never loosen across a ratchet, so no runtime check is needed. With `m = Exit_MinSwingATR`, `b = Exit_StructureBufferATR`, and `σ` the ATR frozen at the ratchet: the ratchet requires `A_new ≥ A_old + m·σ` and sets `AnchorATR = σ`, so `E_new = A_new − b·σ ≥ A_old + (m−b)·σ ≥ A_old ≥ A_old − b·σ_old = E_old` for any ATR spike whenever `m ≥ b` (SHORT mirrors, levels moving down). The legitimate behavioral consequence that remains: when volatility expands, the exit level advances by *less* than the anchor does.
    - Exit_ScanBars ≥ 2 × Exit_PivotStrength + 2
    - Exit_ATR_Period ≥ 1
- **Order validation before submission:** broker constraints (minimum/maximum lot, lot step, minimum stop distance, freeze level, symbol trading mode, market-closed state, filling mode, margin sufficiency) must be checked before sending any order, and rejected orders logged with the broker's returned error rather than failing silently.
- **Logging with standardized reason codes:** `A_NO_CROSS`, `A_TREND_CONFIRM_FAIL`, `A_ANGLE_FAIL`, `A_SEPARATION_FAIL`, `B_HTF_BLOCKED`, `C_MOMENTUM_FAIL`, `C_ATR_CONTRACTION`, `D_MAX_POSITIONS`, `D_ACCOUNT_MODE_MISMATCH`, `D_FOREIGN_EXPOSURE_BLOCKED`, `D_SPREAD_EXCEEDED`, `D_CLOSE_FAILED`, `D_ORDER_REJECTED`, `D_INSUFFICIENT_MARGIN`, `DATA_NOT_READY`, `EXECUTION_WOULD_BE_BLOCKED`. **Module E (v1.13) adds:** `E_STRUCT_EXIT`, `E_HTF_CONFIRMED_OPPOSITE`, `E_NO_ANCHOR`, `E_DATA_NOT_READY`, `EXIT_WOULD_TRIGGER`, plus the behavior-free diagnostics `E_DIAG_MA_CROSSBACK`, `E_DIAG_MINOR_BREAK`, `E_DIAG_HTF_NEUTRAL`. Module E close failures reuse the existing `D_CLOSE_FAILED` with the triggering exit reason attached — no separate code. `E_DATA_NOT_READY` and `E_NO_ANCHOR` are never interchangeable: the first means the search could not run, the second that it ran and found nothing. Only the second is a statement about market structure.
- **Signal vs. order state distinction:** `RAW_SIGNAL → HTF_APPROVED → MOMENTUM_APPROVED (= STRATEGY_SIGNAL_GENERATED) → POSITION_ALLOWED → ORDER_VALIDATED (pre-fill) → ORDER_SUBMITTED → ORDER_FILLED → SLTP_VALIDATED (post-fill) → SLTP_ATTACHED`. NETTING reversal has its own branch: `POSITION_ALLOWED → CLOSE_VALIDATED → CLOSE_SUBMITTED → CLOSE_CONFIRMED / CLOSE_FAILED → OPEN_VALIDATED (fresh) → OPEN_SUBMITTED → OPEN_FILLED / FAIL_FLAT`. **Module E has its own branch (v1.13):** `POSITION_OPEN → STRUCT_ANCHOR_SET → ANCHOR_RATCHETED (0..n) → STRUCT_EXIT_TRIGGERED → CLOSE_SUBMITTED → CLOSE_CONFIRMED / D_CLOSE_FAILED`. `D_CLOSE_FAILED` returns to `POSITION_OPEN` with state retained — the break is re-tested on the next bar, not queued. A position that never establishes an anchor stays at `POSITION_OPEN` with `E_NO_ANCHOR` logged; this is not terminal and initialization is retried each closed bar.
- **Built-in veto-rate diagnostics (added v1.9):** the EA maintains a running counter for every reason code above (per module, per bar) for the lifetime of the run, and prints a summary block at `OnDeinit()` — total LTF bars evaluated, and a pass/fail breakdown per module (A/B/C), the count of `STRATEGY_SIGNAL_GENERATED`, and orders actually attempted. When any bars are rejected by `A_ANGLE_FAIL`, the summary additionally reports the min/avg/max of the actual computed `angle_degrees` values on those rejected bars, so `MinCross_Angle_Deg` can be calibrated from the real distribution of a given symbol/timeframe rather than by trial and error. This directly implements the veto-rate analysis called for in Section 6, without requiring external tooling or log-scraping — combined with the debug toggles (Section 1, Module A), a tester can isolate exactly one filter, run a backtest, and read the summary to see whether that filter alone is over-rejecting.
- **Module E exit accounting (added v1.13):** the same summary reports positions closed by each of `E_STRUCT_EXIT`, `E_HTF_CONFIRMED_OPPOSITE`, SL, TP, and trailing stop; the count of positions that ran with `E_NO_ANCHOR`; counts of `D_CLOSE_FAILED` and of retries; mean/max ratchet count per position; and mean **direction-normalized** anchor travel (`(ProtectedAnchor at exit − InitialAnchor) × Direction`, so LONG and SHORT aggregate to the same sign). Each of the three diagnostic counters is reported alongside how many of those trades were subsequently closed by `E_STRUCT_EXIT` — **counting only events whose timestamp strictly precedes the structural exit's**. A diagnostic firing after the exit says nothing about whether it would have exited earlier, and counting it would manufacture support for a mechanism that did not earn it.

**Canonical engine structure (informative):**

```
OnTick():
    ManageExistingPositions()        // trailing stop logic, every tick — includes its own
                                      // broker validation per candidate SL, see Module D
    if not NewClosedLTFCandle():     // dedup via lastProcessedBarTime
        return
    SignalBar = LTF shift 1
    EvaluateModuleE(SignalBar)       // v1.13: structural exit, BEFORE signal evaluation —
                                      // may close a position that a new signal then reverses
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

**Module E test plan (added v1.13).** Items 7–17 below are specific to the structural exit. Items 8–13 are unit/property tests runnable without a broker; 7 and 14–16 require a backtest.

7. **Module E isolation:** `Enable_StructuralExit = false` (Exit_Mode alone) as baseline, then `true`, on identical entry settings — entries are unchanged between runs, so every difference is attributable to the exit. Compare win rate, mean/median R, and give-back (MFE − realized).
8. **Pivot predicate:** adjacent equal lows (exactly one pivot, at the newer bar); a monotonic run (no pivots); confirmation delay of exactly `S` bars; `pivotShift < S+1` self-rejection inside the predicate; a pivot at the exact scan-window edge; `Exit_PivotStrength = 1`; an outside bar registering as both a swing high and a swing low. Run against **both** callers (`ExitEngine`, `ReversalDetector`) from the same fixtures — the shared-predicate requirement is only meaningful if it is tested as shared.
9. **Anchor initialization:** window anchored to the entry bar, verified by initializing the same position at two very different later bars and asserting an identical anchor; a pivot confirmed *after* `EntryBarTime` correctly excluded from initialization and subsequently admitted by the ratchet; the entry-distance requirement (`Exit_MinSwingATR × σ_c`) rejecting a shallow pivot and selecting an older one; a position older than `Exit_ScanBars` bars still initializing.
10. **Ratchet:** LONG; SHORT; ATR spike at the moment of a ratchet; `Exit_MinSwingATR == Exit_StructureBufferATR` boundary; a non-qualifying candidate correctly skipped and never re-examined (`LastExaminedPivotTime` monotonic).
11. **Property test — continuous ≡ batch.** Over randomized synthetic price sequences, assert `ProtectedAnchor`, `AnchorBarTime`, and `AnchorATR` are identical at **every** bar between (a) continuous per-bar evaluation and (b) evaluation with randomized skipped blocks of 3–10 bars. This is the single highest-value test in the module: it fails for newest-first candidate selection, and it fails for any `ATR[1]` substituted where a confirmation-bar ATR belongs. Both defects are otherwise invisible in ordinary backtests.
12. **Restart reconstruction equivalence:** ratchet several times, discard in-memory state, re-adopt, assert the reconstructed anchor matches exactly; plus the insufficient-history case asserting `E_DATA_NOT_READY` and that **no** anchor is accepted.
13. **State integrity:** `E_DATA_NOT_READY` while a valid anchor is held must leave the anchor untouched and must suppress the break test, with recovery on the following bar resuming from the same anchor; `E_NO_ANCHOR` recovery when a qualifying pivot later confirms; an `iBarShift` exact-lookup failure surfacing as `E_DATA_NOT_READY` rather than silently relocating the anchor.
14. **Exit triggers and attribution:** structure break LONG; structure break SHORT; HTF confirmed opposite with no anchor present; `HTF_BLOCKED` producing no exit; and the both-true case asserting attribution to `E_STRUCT_EXIT`, not to the backstop.
15. **Execution paths:** close failure; close retry re-testing the break rather than resubmitting; price recovering so that the retry correctly sends nothing; `ClosePending` duplicate prevention; position disappearing between bar close and evaluation; SIGNAL_ONLY modifying nothing; same-bar exit followed by opposite-direction re-entry.
16. **Threshold sweep** on `Exit_MinSwingATR` (0 / 0.25 / 0.5 / 1.0) and `Exit_StructureBufferATR` (0 / 0.1 / 0.2 / 0.5) over identical entries. `Exit_MinSwingATR = 0` reproduces "ratchet on every confirmed pivot" and should over-exit — it is the control case proving the significance filter does something.
17. **Multiple positions / hedging** — specified now, runnable when Module D's multi-position stage lands; `CPositionCore` is currently a single-position implementation.

**Gate on the excluded mechanisms:** no item from Module E's exclusion table is implemented until its diagnostic counter shows it fired *before* `E_STRUCT_EXIT` on a material share of trades **and** that doing so improved the outcome.

## 7. Assumptions Requiring Confirmation

- **Netting reversal behavior** — confirm Netting_ReverseOnOppositeSignal should default to true. Still open.
- **Exit management scope** — whether the default trailing values (200/150/10 points) need per-symbol backtesting before going live. Still open.
- **Regression window length** — Regression_Bars = 3 is close to a simple two-point slope; worth backtesting 3/5/8/10. Still open.
- **CCI role** — currently directional-confirmation, not true exhaustion. Confirm acceptable, or scope a separate CCI-exhaustion mode later. Still open.
- **Foreign/manual exposure under NETTING** — Block_On_ForeignNettingExposure defaults true (block). Please confirm this is the right default vs. letting the EA manage combined exposure. Still open.
- **Spread/deviation policy** — MaxSpread_Points (default 30, hard veto) and MaxDeviation_Points (default 10). Please confirm these defaults are reasonable for target symbols, or whether spread should only be logged rather than vetoing. Still open.
- **Filter correlation across A/B/C, and within A** — documented as a testing consideration, not a code change. Worth deliberately testing filter combinations rather than assuming "more filters = better."
- **Module E execution method** — the structural exit closes at market on the closed bar. The alternative is pushing the anchor level to the broker as the position's SL, which survives a terminal disconnection but converts a close-based rule into a wick-triggered one (more shake-outs, and no longer the rule specified). The frozen `AnchorATR` makes the level a fixed number, so either is implementable. Current recommendation: keep close-at-market as primary and leave the protective SL further out as disaster cover. Still open.
- **Module E thresholds** — `Exit_MinSwingATR = 0.5` and `Exit_StructureBufferATR = 0.2` are starting values, not calibrated. Needs the Section 6 item 16 sweep per symbol/timeframe before going live. Still open.
- **Two-level structure for Module E** — whether a minor/major swing split adds value over the single significance threshold. To be decided from the `E_DIAG_MINOR_BREAK` counter after live-like backtesting, not from first principles. Still open.

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
| 1.13 | 2026-08-14 | New document + code folder pair `Markdown/MACrossEA_1.3` + `Autotrader/MACrossEA_1.3` (forked from 1.2, include paths renamed). **Built in this revision:** `SwingStructure.mqh` (canonical pivot predicate + collector, state-free), `BarSource.mqh` (`CBarSource` / `CLiveBarSource` / `CArrayBarSource` — the abstraction the replay-invariance test requires), `ExitEngine.mqh` (`CExitEngine`, pure decision logic — no broker calls, no logging), `CPositionCore::ClosePosition()`, `CIndicatorSet::HTFCandlesBullishClosed/BearishClosed` and `CSignalEngine::ComputeHTFConfirmedBias()` for the closed-candle backstop state, Module E inputs + OnInit validation + OnDeinit exit accounting in `MACrossEA.mq5`, `ReversalDetector.mqh` refactored onto the shared predicate, and `Scripts/TestExitEngine.mq5`. Execution method resolved per the Section 7 recommendation: close-at-market, Module E never touching SL/TP. Added **Module E — LTF Structural Trade Exit**: an open position is monitored against the swing structure that justified it and closed when a closed LTF bar breaks the defended swing by more than an ATR buffer. The mechanism is deliberately singular — a ratcheting anchor at the latest *significant* higher low (LONG) / lower high (SHORT), significance being `Exit_MinSwingATR × ATR` beyond the current anchor — with one backstop (`HTF_Confirmed_Bias` direct opposite) and nothing else granted authority to close. **Pivot definition made normative for the whole codebase** (strict on the newer side, non-strict on the older, so ties resolve to exactly one pivot at the newest bar; predicate enforces its own `shift ≥ S+1` precondition), with a single-canonical-implementation requirement: the predicates move to a new state-free `SwingStructure.mqh` called by both `ExitEngine.mqh` and `ReversalDetector.mqh`, resolving the latter's existing strict-both-sides **behavioral** divergence, both covered by the same fixtures. **Anchor ATR is defined by one rule everywhere** — every anchor carries the ATR of its own *confirmation bar* (shift `p − S`), used identically for the ratchet significance test, the initialization entry-distance test, and the frozen break-test buffer; `ATR[1]` in any of those positions would break replay invariance and restart reconstruction simultaneously. A deliberate consequence is that swing significance is judged permanently in the volatility regime that produced the swing. **Ratcheting is chronological replay** — every pivot newer than `LastExaminedPivotTime` processed oldest→newest, each tested against the anchor as updated by its predecessors — so the anchor is identical whether bars were evaluated continuously or in a batch after missed evaluations; newest-first "first qualifying pivot" selection does not satisfy this and under-protects. Skipping already-examined non-qualifying candidates is provably invariance-safe because the anchor only ratchets one way, so the threshold only rises. The same replay reconstructs adopted/restarted positions deterministically, reproducing all pre-restart ratchet progress with no persisted state, **conditional on** verified OHLC/ATR history depth; insufficient history yields `E_DATA_NOT_READY`, never a partial reconstruction. **Anchor initialization** is anchored to the entry bar rather than the current bar (otherwise a position older than `Exit_ScanBars` can never initialize, and the same position initializes differently depending on when the search runs); admits only candidates whose confirmation bar precedes `EntryBarTime` (otherwise the initial anchor is time-dependent, since a pivot confirming later is invisible early and visible late, skipping the significance test a continuous run would have applied); and requires the anchor to sit `Exit_MinSwingATR × σ_c` from entry. The earlier already-violated rejection/fallback rule was removed as self-defeating — the ratchet re-selected the rejected candidate on the same bar — and wrong in the only case it could fire. **Evaluation order** computes the HTF backstop first (it depends on neither ATR nor pivots, so it survives `E_DATA_NOT_READY`) but attributes last, so a bar where both conditions hold is booked to `E_STRUCT_EXIT`; ordering it otherwise would corrupt the diagnostic the backstop is scoped around. `E_DATA_NOT_READY` and `E_NO_ANCHOR` are formally distinct — the former means the search could not run, must never clear or modify a valid anchor, and suppresses the break test so a zero/unavailable ATR cannot manufacture a break; the latter is non-terminal with an explicit false→true transition. `HTF_Confirmed_Bias` excludes the shift-0 developing HTF candle that Module B's entry-side check includes, since an exit acted on a value that can flip back within the same HTF bar is irreversible; `HTF_BLOCKED` explicitly does not exit and does not alter sensitivity; `HTFEntryBias` is diagnostic-only. Per-position state is keyed by `PositionTicket`; every time→shift conversion uses `iBarShift(..., exact = true)` with `-1` treated as `E_DATA_NOT_READY`. Added close-failure handling (reusing `D_CLOSE_FAILED`, state retained, break re-tested rather than queued), a `ClosePending` duplicate guard, position-vanished finalization, and an explicit detection-price (`Close[1]`) vs. execution-price (first tick after close) distinction for diagnostics. `Exit_MinSwingATR ≥ Exit_StructureBufferATR` is a hard validation that makes the exit level provably non-loosening across a ratchet, removing any need for a runtime invariant check. Module E is orthogonal to Exit_Mode, never modifies SL/TP, closes at market only, evaluates closed-bar only, and runs before Modules A–C so same-bar exit-then-reversal follows Module D's existing netting sequence. Explicitly excluded with rationale and diagnostic counters instead: MA cross-back as a hard exit, two-level minor/major structure, HTF-neutral sensitivity tiers, `Exit_MinBarsInTrade`, monotonicity/candle-count exits, post-exit cooldown, runtime loosening check, already-violated fallback. Added corresponding OnInit() validation, required-bars terms with the `+ S + 1` derivation, reason codes, state-model branch, timestamp-ordered diagnostic pairing, direction-normalized anchor-travel accounting, three open questions, and eleven testing-plan items including a continuous-versus-batch property test over randomized synthetic sequences as the primary regression guard for replay invariance. |
