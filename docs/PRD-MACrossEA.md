# PRD: Multi-Filter Trend Expert Advisor (MQL5)

**Version:** 1.15 (Draft)
**Platform:** MetaTrader 5 / MQL5
**Status:** Draft for review — see Section 7 (Assumptions Requiring Confirmation) before implementation
**Code folder:** Autotrader/MACrossEA_1.5 (forked from Autotrader/MACrossEA_1.4, include paths renamed `MACrossEA_1.4/` → `MACrossEA_1.5/`). Carries forward Modules B, C, D and E unchanged; **replaces Module A's hard-wired trend computation with a selectable trend source behind a fixed interface (`ITrendSource`)**, adds a second source that derives direction from swing structure (higher highs / higher lows), and adds a Phase 0 shadow-evaluation diagnostic that measures both sources against each other before either is trusted. Module A's angle/separation checks and Module C remain unbuilt, as in 1.4.

**Two version axes — read this first.** This document's own revision number and the code folder it describes are different sequences, and conflating them has caused confusion. The mapping is:

| Document revision (Section 9) | Code folder | Marker used in prose |
|---|---|---|
| 1.10 | `Autotrader/MACrossEA_1.1` | "v1.1" when describing code, "v1.10" when describing this document |
| 1.12 | `Autotrader/MACrossEA_1.2` | "v1.2" / "v1.12" |
| 1.13 | `Autotrader/MACrossEA_1.3` | "v1.3" / "v1.13" |
| 1.14 | `Autotrader/MACrossEA_1.4` | "v1.4" / "v1.14" |
| **1.15 (this document)** | **`Autotrader/MACrossEA_1.5`** | **"v1.5" / "v1.15"** |

Where older prose below says "v1.9", "v1.10", "v1.12", "v1.13" or "v1.14" it is referring to *document* revisions, which is why those numbers exceed the code folder's. The EA's `OnDeinit()` summary header must print the **code folder** version (`v1.5`).

**Name note:** the EA, its file names, and its magic-number defaults remain `MACrossEA` for continuity with existing journals and tester caches, even though as of 1.14 a crossover is no longer a trade condition and as of this revision moving averages are no longer necessarily involved in the trade condition at all. The name is historical, not descriptive. The document title drops "MA Crossover" because it had become actively misleading.

**As-tested configuration (EURUSD M15, 2019-01-01 → 2026-08-13, 99% history quality).** Several field observations below are pinned to specific parameter values. The most recent full backtest of the 1.3 code — the run that motivated the 1.14 redesign — used: `FastMA_Period = 20`, `SlowMA_Period = 45`, `MA_Method = EMA`, `MA_AppliedPrice = Close`, `LTF_TrendConfirm_Bars = 3`, `LTF_ConfirmationCandles = 2`, `HTF_Timeframe = H4`, `HTF_MA_Period = 20`, `HTF_TrendConfirm_Bars = 3`, `HTF_ConfirmationCandles = 2`, `Exit_Mode = FIXED_SLTP`, `StopLoss_Points = 150`, `TakeProfit_Points = 300`, `Lot_Size = 0.10`, Module E enabled at its defaults. **These are not the defaults in the input tables below**, which remain at their original values. Any field observation citing different periods (e.g. the EMA 10/30 note under the angle check) predates this run and should be read as historical. **No backtest of the 1.4 code, and none of the structure source, exists at the time of writing** — every claim about `SWING_STRUCTURE` in this document is a design expectation, not a measurement.

## 1. Overview

This EA identifies a directional trend on a trading timeframe ("LTF"), requires a higher timeframe ("HTF") to agree, and trades in that direction. **How the LTF trend is identified is, as of this revision, a selectable component rather than a fixed rule** — see Module A. On top of that core the EA layers:

- Trend-quality confirmation on the LTF signal itself (candle-colour agreement + slope/angle + minimum MA separation).
- A higher-timeframe MA trend filter that restricts trade direction.
- A single, mutually-exclusive momentum/oscillator filter (radio-button style), plus an independent ATR volatility filter, both evaluated on the LTF that can veto a trade for exhaustion of the specific move being entered.

**What changed in v1.15, and why.** Through 1.14, Module A computed trend direction one way: the fast MA's position relative to the slow MA (`FastMA[1] > SlowMA[1]`), with both MAs required to be strictly monotonic in that direction. That computation is not wrong, but it had never been compared against any alternative, and the one measurement that exists is discouraging — over 2019–2026 on EURUSD M15 the 1.3 build's 209 trades resolved a 2:1 bracket at a 32.5% hit rate against a 33.3% breakeven, i.e. indistinguishable from a random entry with the same bracket.

The 1.14 revision diagnosed one specific defect in that result (systematic late entry: the slow MA was already trending in the cross direction on 91% of crosses) and fixed the event/level conflation behind it. It did not, and could not, establish that a moving-average pair is the right instrument for detecting a trend in the first place. Section 7 has recorded since 1.14 that **neither the edge nor the level form has been validated as carrying an edge.**

This revision does not answer that question either. It makes the question *answerable*, by three changes:

1. **Module A no longer computes trend direction.** It delegates to an `ITrendSource` selected by the `Trend_Source` input, and applies the shared filters to whatever that source returns.
2. **A second source, `SWING_STRUCTURE`, derives direction from price structure** — the sequence of confirmed swing pivots — rather than from an average of price. Higher highs and higher lows mean uptrend; lower highs and lower lows mean downtrend.
3. **Phase 0: both sources are evaluated on every bar regardless of which one has authority**, and their agreement, disagreement, and lead/lag are logged. This produces the head-to-head data that thirteen revisions of this document have assumed rather than measured.

`Trend_Source` defaults to `MA_STATE`, which is v1.14 behaviour carried forward unchanged. **This revision changes no trading behaviour at its defaults.** It adds a seam, a second implementation behind it, and the instrumentation to choose between them.

**Why swing structure specifically.** It is the definition of a trend that does not depend on a smoothing parameter: a trend is a sequence of higher highs and higher lows, and that is true regardless of what period anyone picked. It also lags less in a specific, measurable way — a confirmed pivot is knowable `S` bars after it forms (2 at the default), where an EMA(30) is averaging thirty bars of history. And the codebase already contains a rigorous, normative implementation of it: `SwingStructure.mqh` has been the canonical pivot definition since 1.13, and Module E has been ratcheting an anchor along higher lows ever since. This revision promotes machinery that already exists on the exit side to the entry side; it does not invent it.

**Primary condition vs. toggleable filters (added v1.9, redefined v1.14, re-scoped v1.15):** the LTF trend signal (Module A — the active trend source's `Direction` **and** its own `Confirmed` flag, which together are one indivisible condition) and the HTF trend gate (Module B) are the mandatory, always-active core of the strategy and cannot be disabled — together they are "the trade condition." Every other check layered on top of that core is independently toggleable at runtime.

**Built vs. specified.** The "Status" column is normative, and only rows marked **Built** may be assumed present by an implementer.

| Check | Toggle input | Default | Status |
|---|---|---|---|
| Trend source selection | `Trend_Source` | `MA_STATE` | **Built (new in v1.15)** |
| Trend-source shadow evaluation | `Trend_Diagnostic_Mode` | `SHADOW` | **Built (new in v1.15)** — diagnostic only, never affects a trade |
| LTF candle-colour agreement | `Enable_LTF_CandleColor_Check` | true | **Built (v1.14)** |
| Momentum/oscillator filter | `Momentum_Filter = NONE` | (set to NONE to disable) | Specified, **unbuilt** (Module C is unbuilt). The enum's NONE member is the intended toggle mechanism once it exists; no such input is present in code |
| ATR volatility filter | `Enable_ATR_VolatilityFilter` | true | Specified, **unbuilt** (Module C is unbuilt) |
| Regression angle-between-lines | `Enable_Angle_Check` | true | Specified, **unbuilt** (step 4 is unbuilt) |
| Minimum MA separation | `Enable_Separation_Check` | true | Specified, **unbuilt** (step 5 is unbuilt) |

Module D's account-mode handling is likewise **specified but unbuilt** and is marked as such in Module D — `Account_Mode`, `Block_On_ForeignNettingExposure`, `Netting_ReverseOnOppositeSignal`, the netting reversal sequence, `Max_Open_Positions`, and post-fill SL/TP re-derivation all describe a target design that no code folder implements.

`Enable_TrendConfirm_Check` was deleted in v1.14 and must not be implemented; its role is now internal to each trend source (`TrendReading.Confirmed`).

This lets a tester run "trend + HTF only" as a baseline, then re-enable one filter at a time and re-run, watching the veto-rate summary (Section 5/6) to see which specific filter's logic or threshold is rejecting trades unexpectedly — rather than guessing from the fully-stacked strategy.

## 2. Scope

**In scope:**

- Signal generation logic (selectable trend source — MA trend state or swing structure — plus candle-colour confirmation, regression/angle filter, MA separation filter)
- Trend-source comparison instrumentation (Phase 0 shadow evaluation, added v1.15)
- HTF directional gate
- Re-entry cooldown after a position closes (Module D, added v1.14)
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
| LTF | Lower/trading timeframe — where the fast/slow MA trend state and entries are evaluated |
| HTF | Higher timeframe — where trend direction is evaluated as a directional gate (momentum/exhaustion is checked on the LTF instead, see Module C) |
| Trend source | The pluggable component that answers "is the LTF trending, and which way" — `MA_STATE` or `SWING_STRUCTURE`, behind the `ITrendSource` interface (v1.15). Module A applies filters to its output but no longer computes direction itself |
| Shadow source | The trend source that is *not* selected, evaluated every bar for diagnostics only and never granted authority over a trade (v1.15) |
| Structure state | Direction as read from the swing sequence: two consecutive higher highs **and** two consecutive higher lows = long, mirrored for short, anything else = none (v1.15) |
| Trend state | (`MA_STATE` source only.) The fast MA's position relative to the slow MA at the signal bar: `FastMA[1] > SlowMA[1]` = long state, `FastMA[1] < SlowMA[1]` = short state, exact equality = neither. A **level**, true on every bar it holds — not an event (v1.14) |
| State episode | A maximal unbroken run of consecutive signal bars on which **Stage 1 as a whole** (Module A **and** Module B **and** Module C — see Module D's aggregation logic) passes in the same direction. Deliberately *not* defined on Module A alone: Module B blocks the large majority of bars, so a Module-A-only reading would be several times larger and would not be the quantity `STATE_EPISODES` reports or that test 6f compares against 1.3's cross count. Used only for diagnostics and testing; the engine has no notion of an episode and never stores one |
| Cross bar | *(Retired in v1.14.)* Formerly the first closed bar on which the fast MA had crossed the slow MA, and formerly the primary trade condition. A crossover is now merely the boundary between two state episodes and carries no authority. Retained in this glossary only so older prose and journals remain readable |
| Trend confirmation window | The last N MA values used to verify the MA is monotonically moving in the state direction |
| Cooldown | The `ReEntry_Cooldown_Bars` closed LTF bars following the close of an EA-owned position, during which no new entry is permitted regardless of Module A/B (Module D, v1.14) |
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

- **Module A (LTF), `SWING_STRUCTURE` source (v1.15):** reads confirmed swing pivots only, which by the `SwingStructure.mqh` contract are scanned from shift `Struct_PivotStrength + 1` and older — both sides of every confirmed pivot are therefore closed bars, and shift 0 is never read. The break-trigger variant additionally reads `Close[1]`. Same rule as Module E, and for the same reason.
- **Module A (LTF), `MA_STATE` source — trend state + MA-value confirmation (state form, v1.14):** the state is read at shift 1 alone — `FastMA[1] > SlowMA[1]` (long case; mirrored for short). Shift 1 is the signal bar. Shift 2 is **no longer read for the direction decision**; the `FastMA[2] ≤ SlowMA[2]` half of the old crossover test is deleted, not merely relaxed. `TrendConfirm_Bars = 3` means `MA[3] < MA[2] < MA[1]` (long) evaluated on both fast and slow MA — the signal bar (shift 1) is included in the count, so shift 2 and older are still read by *that* check. The net effect on required history is nil; the effect on semantics is total.
- **Module A (LTF), candle-color confirmation (v1.2, toggleable as of v1.14):** the LTF mirror of Module B's candle check, but with no shift-0 exception — `LTF_ConfirmationCandles = 3` means LTF shift 1, 2, and 3 (all closed) must all share the state's candle color.
- **Module B (HTF), MA-value confirmation:** uses the most recently completed HTF candle at the moment the LTF signal bar closes — this is HTF shift 1, never HTF shift 0, even if the HTF candle has been forming for a long time relative to the LTF. `HTF_TrendConfirm_Bars = 5` means `HTF_MA[5] < HTF_MA[4] < HTF_MA[3] < HTF_MA[2] < HTF_MA[1]` (uptrend case).
- **Module B (HTF), candle-color confirmation (v1.10):** the one shift-0 exception — `HTF_ConfirmationCandles = 3` means HTF shift 0, 1, and 2 must all share the trend's candle color, re-read fresh (including the still-live shift 0 candle) every time Module B runs.
- **Module C (LTF momentum/ATR):** evaluated on the same LTF signal bar as Module A (shift 1) — never on the live/current value. This is a hard rule: Module C must not evaluate a different bar than Module A, or the closed-bar guarantee is broken.
- **Module E (LTF structural exit, v1.13):** evaluated on that same newly-closed LTF signal bar (shift 1), once per bar, and **before** Modules A–C, so an open position is always managed on the current bar's information before a new signal on that bar is considered. Swing pivots are scanned from shift `Exit_PivotStrength + 1` and older, which guarantees both sides of every confirmed pivot are closed bars — Module E never reads shift 0, with no exception. Its HTF backstop reads HTF shift 1 and older for **both** confirmations, deliberately excluding the shift-0 developing candle that Module B's candle check includes (see Module E for why the exception does not transfer to exits). All Module E state that must survive new bars or a restart is keyed by **bar open time**, never by shift, and every time→shift conversion uses `iBarShift(..., exact = true)`.

One synchronization rule ties all three together: every signal evaluation cycle is anchored to one specific newly-closed LTF candle (shift 1). Modules A and C both read that exact candle's closed values. Module B reads whichever HTF candle was most recently completed as of that same moment (HTF shift 1). Module E evaluates on that same candle, ahead of A–C. This single rule resolves the indexing ambiguity across every module rather than defining it separately per indicator.

### Module A — LTF Trend Signal

**Design principle (v1.14, unchanged).** Module A answers exactly one question: *is the LTF currently in a trend, and in which direction?* It is a statement about the present, re-derived from scratch on every closed bar, with no memory of how the market arrived there. It deliberately does **not** answer "is this a good moment to enter" — that is Module B's job (regime agreement), Module C's job (exhaustion), and Module D's job (position count, cooldown, execution).

**What changed in v1.15.** Module A no longer computes trend direction. It selects a **trend source**, asks it for a reading, and applies the shared filters (candle colour, angle, separation) to that reading. The MA computation that *was* Module A steps 1–2 is now one source implementation among two, carried forward bit-for-bit and still the default.

The motivation is stated in Section 1 and is worth repeating in one line, because it governs how this section should be read: **no evidence exists that either source detects trends well.** The MA form has one measurement against it and none in its favour. The structure form has none at all. This section specifies both and the instrumentation to compare them; it does not claim a winner, and any future revision that adopts one must cite Section 6's item 6h to do so.

**v1.5 staged-rebuild note.** The code folder implements the `ITrendSource` seam, both sources, the shadow-evaluation diagnostic, and steps 1–3 below. The angle and separation checks (steps 4–5) and their toggles remain unbuilt, as they have since 1.2 — this section still describes the full target design for all five steps.

#### The `ITrendSource` seam (normative)

```
interface ITrendSource:
    TrendReading Evaluate(BarSource src, int signalShift)   // pure; closed-bar only
    int          RequiredBars()                             // history depth this source needs
    string       Name()                                     // journal/diagnostic label

struct TrendReading:
    int      Direction      // +1 long, -1 short, 0 = no trend
    bool     Confirmed      // the source's own internal confirmation passed
    int      RejectCode     // why, when Direction != 0 and !Confirmed (source-specific)
    datetime AsOfBarTime    // open time of the bar this reading describes
    double   EvidenceA      // source-specific, journalled verbatim (see each source)
    double   EvidenceB
```

Five contract rules, all inherited from v1.14's hard-won properties and now binding on **every** source, present and future:

1. **Stateless.** Identical inputs must produce an identical reading. A source may not remember the previous bar, latch a verdict, suppress a repeat, or hold any per-run state. Entry frequency belongs to Module D (`Max_Open_Positions`, `ReEntry_Cooldown_Bars`) and nowhere else. A source that violates this silently reintroduces the v1.13 edge-triggered behaviour under a new name.
2. **Level-triggered by default.** `Direction` is expected to be true across long unbroken runs of bars. Every consumer, counter and diagnostic in this document already assumes that.
3. **Never reads shift 0.** No exceptions on the LTF. (Module B's HTF candle check retains the one shift-0 exception in this document; it is not a trend source and is unaffected.)
4. **`Direction` and `Confirmed` are one condition.** Module A treats `Direction != 0 && Confirmed` as the primary trade condition. Neither half is separately toggleable — this is the v1.14 rule that deleted `Enable_TrendConfirm_Check`, generalized. A source that has no meaningful internal confirmation returns `Confirmed = true` whenever `Direction != 0`; it must not invent one to fill the field.
5. **Both sources are evaluated every bar** (see Phase 0 below), but only the selected one has authority. A shadow reading must never reach Module B, Module D, or any counter that gates execution.

**Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| Trend_Source (code: `InpTrendSource`, new in v1.15) | enum | MA_STATE | `MA_STATE` / `SWING_STRUCTURE`. Which source has authority. `MA_STATE` is v1.14 behaviour exactly, so the default changes no trading behaviour. |
| Trend_Diagnostic_Mode (code: `InpTrendDiagnosticMode`, new in v1.15) | enum | SHADOW | `OFF` / `SHADOW`. Under `SHADOW` the non-selected source is also evaluated every bar and logged. Diagnostic only — see Phase 0. Costs one extra evaluation per bar and no broker traffic. |

#### Logic (v1.15)

1. **Trend direction** — `reading = ActiveSource.Evaluate(signalBar)`. `reading.Direction` establishes the trade direction; if it is 0, log `A_NO_TREND` and stop. The angle check below is a magnitude gate only and never determines direction, under any source.
2. **Source confirmation** — `reading.Confirmed` must be true. If not, log the source-specific reject code (`A_TREND_CONFIRM_FAIL` for `MA_STATE`, `A_STRUCT_*` for `SWING_STRUCTURE`) and stop. Steps 1 and 2 are one condition and are never toggleable.
3. **Candle-colour confirmation** (skipped entirely if `Enable_LTF_CandleColor_Check = false`): unchanged from v1.14 — the last `LTF_ConfirmationCandles` **closed** LTF candles, shift 1 through shift `LTF_ConfirmationCandles`, must all agree in colour with `reading.Direction`. A doji breaks the run. This check is source-agnostic by design: it tests recent price agreement, which is meaningful regardless of how direction was derived.
4. **Angle-between-lines check** *(unbuilt; see below — `MA_STATE` only)*.
5. **Separation check** *(unbuilt; see below — `MA_STATE` only)*.

If all applicable checks pass → raw directional signal (LONG or SHORT) is generated and passed to Module D.

**Steps 4 and 5 are source-specific and are skipped entirely under `SWING_STRUCTURE`.** Both are defined in terms of the fast and slow MA — a regression through MA values, and the distance between two MAs — and neither has any meaning when direction did not come from those MAs. Under `SWING_STRUCTURE` they are not merely disabled but inapplicable: the EA must log `A_STEP_NOT_APPLICABLE` once at `OnInit()` if `Enable_Angle_Check` or `Enable_Separation_Check` is true while `Trend_Source = SWING_STRUCTURE`, and proceed with them skipped. It must **not** fail init — that would make the toggles' defaults incompatible with the new source for no safety benefit. The structure source's own analogue of "not too early / not too late" is `Struct_MinSwingATR`; see its own note.

#### Source 1 — `CMATrendSource` (`MA_STATE`), carried forward from v1.14

Direction and confirmation are v1.14 Module A steps 1 and 2, verbatim:

- `Direction` = +1 if `FastMA[1] > SlowMA[1]`; −1 if `FastMA[1] < SlowMA[1]`; **0 if exactly equal.** The exact-equality handling remains normative and remains without an epsilon band, for the reasons given in v1.14: it keeps the LONG and SHORT conditions exact mirrors so no bar can satisfy both, and an epsilon band would create a third, silently non-trading regime whose width is an untested parameter.
- `Confirmed` = both fast and slow MA strictly monotonic in `Direction` over `TrendConfirm_Bars` (shift 1 through shift `TrendConfirm_Bars`). Strict: a single flat or countertrend value fails the window.
- `RejectCode` = `A_TREND_CONFIRM_FAIL`. `EvidenceA` = `FastMA[1]`, `EvidenceB` = `SlowMA[1]`.

Its inputs (`FastMA_Period`, `SlowMA_Period`, `MA_Method`, `MA_AppliedPrice`, `TrendConfirm_Bars`) are unchanged and keep their v1.14 defaults and validation. **Field observation (v1.14), retained:** under the state form the monotonic run holds on roughly 63% of bars that satisfy the level test (119,352 of 189,145 over 2019–2026, either direction, before any other gate).

#### Source 2 — `CStructureTrendSource` (`SWING_STRUCTURE`), new in v1.15

**Definition.** Using the canonical predicate in `SwingStructure.mqh` with `S = Struct_PivotStrength`, collect confirmed pivots within `Struct_ScanBars` of the signal bar and take:

- `H1` = most recent confirmed swing high, `H2` = the one before it
- `L1` = most recent confirmed swing low, `L2` = the one before it

If any of the four does not exist in the window → `Direction = 0`, `RejectCode = A_STRUCT_INSUFFICIENT_PIVOTS`. This is a data condition, not a market statement, and is counted separately from "pivots exist but form no pattern" for exactly the reason `E_DATA_NOT_READY` and `E_NO_ANCHOR` are kept distinct in Module E.

**Significance.** A comparison counts only when it clears a threshold, so that a one-tick higher high does not flip the reading:

```
sigma(P)   = ATR(Struct_ATR_Period) at P's own confirmation bar     // frozen, never ATR[1]
higherHigh = (H1 - H2) >= Struct_MinSwingATR * sigma(H1)
higherLow  = (L1 - L2) >= Struct_MinSwingATR * sigma(L1)
lowerHigh  = (H2 - H1) >= Struct_MinSwingATR * sigma(H1)
lowerLow   = (L2 - L1) >= Struct_MinSwingATR * sigma(L1)
```

`sigma` is read at the **newer** pivot's confirmation bar, matching Module E's ratchet, which reads it at the candidate's own confirmation bar. The one-rule-everywhere requirement from Module E applies here without modification: **never `ATR[1]`**, in any of these positions. Using the ATR at evaluation time would make a reading depend on when it was computed, which breaks replay invariance and restart reconstruction simultaneously — the same defect, in a new place, and it would be just as invisible in an ordinary backtest.

**Direction:**

```
+1  if higherHigh AND higherLow
-1  if lowerHigh  AND lowerLow
 0  otherwise                        // includes every mixed reading
```

A mixed reading — a higher high with a lower low (expanding range), or a higher low with a lower high (contraction/coil) — is `Direction = 0` with `RejectCode = A_STRUCT_NO_PATTERN`. Both are real and common market states, and neither is a trend. Requiring *both* comparisons to agree is what makes this a trend test rather than a momentum test; requiring only one would classify an expanding range as a trend in whichever direction happened to break first.

**Confirmation.** Under the default trigger, `Confirmed = (Direction != 0)` — the pattern *is* the confirmation, exactly as MA position and MA monotonicity are jointly indivisible in `MA_STATE`. There is no second internal test, and per contract rule 4 the source must not invent one.

**Trigger mode.** `Structure_Entry_Trigger` selects what counts as tradeable:

| Value | Condition | Class |
|---|---|---|
| `STATE` (default) | the pattern above holds | level |
| `BREAK` | the pattern holds **and** `Close[1] > H1` (long) / `Close[1] < L1` (short) | edge-ish |

`STATE` is the default specifically so the Phase 1 comparison is apples-to-apples: both sources are then level-triggered, and the only difference between them is how direction is derived. `BREAK` is a *separate* experiment and must not be mixed into that comparison — it changes the trigger class as well as the source, so a difference in results could not be attributed to either. It exists because it resolves the Module A / Module E symmetry problem below, and because it is what `ReversalDetector.mqh` already implements.

**Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| Struct_PivotStrength (code: `InpStructPivotStrength`) | int | 2 | Bars required each side of a confirmed pivot. Deliberately independent of `Exit_PivotStrength` — see the note below. Higher = fewer, more significant pivots and a later reading; lower = more responsive and noisier. |
| Struct_MinSwingATR (code: `InpStructMinSwingATR`) | double | 0.5 | How far a swing must clear the previous one, in ATR multiples, for the comparison to count. This is the structure source's "not too early" knob and its only significance filter. |
| Struct_ScanBars (code: `InpStructScanBars`) | int | 100 | How far back to look for the four pivots. Must be ≥ `4 × Struct_PivotStrength + 4` (Section 5) — enough room for four pivots plus their confirmation bars. |
| Struct_ATR_Period (code: `InpStructATRPeriod`) | int | 14 | ATR period for the significance threshold. Deliberately independent of `Exit_ATR_Period`, `LTF_ATR_Period` and Module C's `ATR_Period`, consistent with every other ATR period in this document. |
| Structure_Entry_Trigger (code: `InpStructureEntryTrigger`) | enum | STATE | `STATE` / `BREAK`, per the table above. |

**Why not share parameters with Module E.** `Struct_PivotStrength` and `Exit_PivotStrength` will usually want the same value, and `Struct_MinSwingATR` and `Exit_MinSwingATR` will usually want *different* ones. Sharing either would couple the entry's sensitivity to the exit's, and the exit's thresholds have their own open question (Section 7) that would then silently move the entry. They share the *predicate* — one implementation of the pivot rule, per the single-canonical-implementation requirement — and nothing else. No validation enforces a relationship between them.

**The Module A / Module E symmetry problem — read before choosing thresholds.** Module E's design principle states that it is *deliberately not the inverse of the entry condition*. Under `MA_STATE` that held comfortably: entry was about moving averages, exit about swing structure. Under `SWING_STRUCTURE` they become near-mirrors — Module A enters while structure is intact, Module E exits when structure breaks — and the property Module E was designed around is weakened.

This is a real cost of the new source, not an oversight, and it is not resolved by this revision. Three positions, of which the spec adopts the first:

1. **Accept the symmetry, separate the thresholds.** Require `Struct_MinSwingATR > Exit_MinSwingATR` in practice (not enforced — see Section 7), so entry demands a stronger structure than the exit defends. The two mechanisms then disagree over a band rather than switching at the same point, and `ReEntry_Cooldown_Bars` covers the remainder. This is the specified default because it is the smallest change and keeps the Phase 1 comparison clean.
2. **Use `BREAK`.** Entry on a structural break (edge), exit on structural failure (level) — different trigger classes, so the mechanisms stay genuinely independent. Available now, but confounds the Phase 1 A/B, so it is a later experiment.
3. **Disable Module E under `SWING_STRUCTURE`** and manage exits with `Exit_Mode` alone. Cleanest separation, discards the exit work, and is not specified here.

What must **not** happen is adopting `SWING_STRUCTURE` without deciding which of these applies. A build where entry and exit fire on the same condition at the same threshold will re-enter every position it exits, bounded only by the cooldown, and will look like a cooldown-tuning problem rather than the design collision it is. Section 6 item 6j is the test that surfaces it.

**Caveats, stated plainly because the case for this source is theoretical.**

- **Structure lags too.** A pivot is knowable `S` bars after it forms — better than an EMA(30)'s averaging window, but not immediate, and the *pattern* needs four pivots, so a fresh trend is unreadable until two swings of each kind have completed. On a clean impulse move that can be slower than the MA reading, not faster.
- **Structure whipsaws in ranges,** alternating between higher-high and lower-high readings exactly where an MA pair oscillates around itself. `Struct_MinSwingATR` mitigates this; it does not remove it.
- **Structure is sparse.** In a slow drift with no clear pivots the source returns `Direction = 0` for long stretches and the EA simply does not trade. Whether that is prudence or a missed regime is an empirical question — `A_STRUCT_INSUFFICIENT_PIVOTS` is counted separately so it can be answered.
- **The parameter count does not drop.** `(FastMA_Period, SlowMA_Period, MA_Method, TrendConfirm_Bars)` is replaced by `(Struct_PivotStrength, Struct_MinSwingATR, Struct_ScanBars, Struct_ATR_Period)`. The claim is that these are more interpretable, not that there are fewer.
- **The entry may not be the problem at all.** The 32.5%-versus-33.3% result means the entry carried no information, but that is equally consistent with a bracket/exit mismatch. Replacing the entry a second time without measuring would repeat the pattern that produced revisions 1.9 through 1.14. That is what Phase 0 exists to prevent.

#### Phase 0 — shadow evaluation (new in v1.15)

**Purpose.** Produce the head-to-head measurement that this document has assumed since 1.0 and never made, at zero risk to trading behaviour.

**Mechanism.** When `Trend_Diagnostic_Mode = SHADOW`, every signal-bar evaluation runs **both** sources. The selected source drives the pipeline exactly as before. The shadow source's reading is recorded and discarded. The shadow reading never touches Module B, Module D, any execution counter, or any reason code that gates a trade.

This follows the pattern Module E already established for its exclusion list — *"logged as a diagnostic counter so its value can be measured before it is ever given authority to close a position."* Same discipline, applied to entries.

**Per-bar record**, written to `<Journal_Base>_trendcompare.csv`, one row per evaluated signal bar:

| Column | Meaning |
|---|---|
| `SignalBarTime` | open time of the signal bar (shift 1), not `TimeCurrent()` |
| `ActiveName`, `ActiveDir`, `ActiveConfirmed`, `ActiveReject` | the selected source's reading |
| `ShadowName`, `ShadowDir`, `ShadowConfirmed`, `ShadowReject` | the shadow source's reading |
| `Agreement` | `BOTH_LONG` / `BOTH_SHORT` / `DISAGREE` / `ACTIVE_ONLY` / `SHADOW_ONLY` / `BOTH_NONE` |
| `HTFBias` | Module B's verdict on the same bar, so agreement can be conditioned on the gate |
| `FwdReturn_N` | signed return from `Close[1]` to the close `Trend_Compare_Horizon` bars later, in ATR units, **written on a later bar** — see below |

**`FwdReturn_N` is filled in retrospectively.** The row is written when the bar closes, and its forward-return column is completed `Trend_Compare_Horizon` bars later. Implementations that cannot rewrite a CSV row in place must instead buffer rows and flush them once the horizon has elapsed, accepting that the tail of a run loses the last `Trend_Compare_Horizon` rows. **What is not acceptable is computing the forward return from bars that were not yet closed at evaluation time and presenting it as if it were known then** — the whole diagnostic is worthless if it leaks lookahead into the comparison it is meant to arbitrate.

**Summary block at `OnDeinit()`**, alongside the existing veto-rate summary:

- The **agreement matrix**: counts for each `Agreement` value, and the agreement rate overall and restricted to bars where `HTFBias != BLOCKED` (which is the only population that can trade).
- **Directional accuracy on disagreement**: of the `DISAGREE` bars, the share where each source's direction matched the sign of `FwdReturn_N`. This is the single number the Phase 1 decision should turn on, and it is meaningful *only* on disagreement — on agreement bars both sources are right or wrong together and the comparison says nothing.
- **Lead/lag**: for each episode both sources eventually agreed on, the signed bar count between the two sources first reporting that direction. A negative mean means the shadow source read the trend earlier.
- **Coverage**: `TRADEABLE_BARS` under each source in isolation, so a source that is right but silent is distinguishable from one that is right and frequent.

**Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| Trend_Compare_Horizon (code: `InpTrendCompareHorizon`) | int | 20 | Bars ahead used for `FwdReturn_N`. Uncalibrated; sweep it (Section 6 item 6i) rather than trusting one value, since a horizon shorter than the mean episode length measures noise and one much longer measures the next regime. |

**What Phase 0 cannot tell you.** Directional accuracy over a fixed horizon is not profitability: it ignores path, and a source that is directionally right but arrives after most of the move has happened will score well here and trade badly. It is a screen, not a verdict — its job is to establish whether the two sources differ *at all* in a way worth pursuing, and to fail fast if they turn out to agree on 95% of tradeable bars. If they do, the entry is not where the strategy's problem lives, and that is a genuinely valuable negative result.

**Output shape (v1.14, unchanged and now binding on every source).** Module A's output on any given bar is one of `LONG`, `SHORT`, or `NONE`, and consecutive bars will very often repeat the same non-`NONE` value. Module A itself is stateless. Implementations must not latch its output, suppress repeats, or reintroduce edge-detection anywhere in the signal path.

### Module B — HTF Trend Gate

**Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| HTF_Timeframe | enum | H4 | Higher timeframe for trend filter. Must be strictly higher than LTF_Timeframe — see Section 7 validation rules. |
| HTF_MA_Period | int | 20 | HTF MA period (independent period — only the method/applied-price are shared, see below) |
| HTF_TrendConfirm_Bars | int | 5 | Number of consecutive HTF MA values (HTF shift 1 .. shift HTF_TrendConfirm_Bars) required to establish trend — the MA-value confirmation. |
| HTF_ConfirmationCandles | int | 3 | **(v1.1)** Number of consecutive HTF candles, by candle color (Close vs. Open), required to establish trend — the price-action confirmation. Counted starting from HTF shift 0, the currently-developing candle (see Logic below) — this is deliberately not shift-1-and-older like every other check in this document. Minimum 1. |

All three MAs in this EA (LTF fast, LTF slow, and HTF) share the same MA_Method and MA_AppliedPrice (defined once in Module A) — there are no separate HTF_MA_Method/HTF_MA_AppliedPrice inputs. Only the periods differ per MA (FastMA_Period, SlowMA_Period, HTF_MA_Period).

**Unchanged in v1.15 — explicitly.** Module B is untouched by the trend-source redesign and remains MA-based, deliberately. Making the HTF gate structural at the same time as the LTF signal would confound the Phase 1 comparison: a difference in results could then be attributed to either change. Converting Module B to a structure source is a separate, later experiment, and the `ITrendSource` seam is written so that it would be a substitution rather than a rewrite. The HTF gate remains mandatory, non-toggleable, and the second half of the primary trade condition under every trend source.

**Unchanged in v1.14 — explicitly.** Module B carries over from 1.13 in full: same two required confirmations, same shift-0 exception on the candle check, same `LONG_ONLY / SHORT_ONLY / BLOCKED` output, same fixed rule that a `BLOCKED` reading vetoes trades in both directions regardless of Module A. The HTF green light remains mandatory and non-toggleable, and it remains the second half of the primary trade condition. Nothing about the Module A redesign relaxes, reweights, or bypasses it — a state signal with no HTF agreement is exactly as untradeable as a crossover with no HTF agreement was.

One consequence is worth anticipating, because it changes which module is the binding constraint. Under the crossover condition, Module A was overwhelmingly the bottleneck: 185,236 of 189,145 bars produced no signal simply because no cross occurred that bar, and the HTF gate only ever got to rule on the 3,909 that did. Under the state condition Module A will pass on a large fraction of bars, so **Module B becomes the primary limiter** — and on the as-tested configuration its bias was `BLOCKED` on 148,351 of 189,145 bars (78.4%). Expect the veto-rate summary to look completely different for that reason alone, with `B_HTF_BLOCKED` replacing `A_NO_TREND_STATE` as the dominant reason code. That is the gate working as designed, not a regression.

**Distinct role** (to keep in mind given A/B measure related things — see Section 7 note on filter correlation): Module A asks "is the LTF in a trend right now, on its own terms?" Module B asks "does the higher-timeframe regime agree with it?" These are correlated in a trending market by construction, but not redundant — Module A can pass while Module B blocks (e.g. a strong LTF pop against the HTF trend), and that's the case this filter exists to catch.

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

Both evaluated on the LTF (the same timeframe as the trend-state signal itself, LTF_Timeframe from Module A) — not the HTF.

**Design note — why momentum is checked on the LTF, not the HTF:** the trade is triggered by the trend state on the LTF, so the thing that could be "exhausted" is that specific LTF move. **(v1.14 amendment:** this argument gets stronger under a level-triggered entry, not weaker. Under the crossover form, "the move about to be traded" had barely begun at the signal bar, so an exhaustion reading was close to meaningless there. Under the state form the EA can enter at any point in a trend — including a late one — so a check for whether *this* move is already stretched is now measuring something real and is the natural guard against the late-entry pattern documented in Section 1. Module C remains unbuilt, but it moves up in priority because of this revision.**)** Checking momentum on the HTF would answer a different question (is the bigger-picture trend fading), which Module B already partially covers via its own directional gate. Evaluating RSI/MACD/Stochastic/CCI/ATR on the same timeframe as the entry signal directly measures whether this move — the one about to be traded — already looks stretched, which is a better match for "trend exhaustion at the point of entry" than a separate timeframe's reading would be. This supersedes the earlier HTF-based design.

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
| ReEntry_Cooldown_Bars (code: `InpReEntryCooldownBars`, new in v1.14) | int | 5 | Number of **closed LTF bars** that must elapse after an EA-owned position closes before a new entry is permitted. `0` disables the cooldown entirely (legal, and the control case for Section 6's sweep). See the dedicated subsection below for the counting rule, scope, and restart behaviour. |
| Account_Mode | enum | AUTO | AUTO / FORCE_NETTING / FORCE_HEDGING. AUTO reads the real account mode via `AccountInfoInteger(ACCOUNT_MARGIN_MODE)` at OnInit() and uses it. FORCE_* options are only accepted when running inside Strategy Tester (`MQLInfoInteger(MQL_TESTER) == true`); if a FORCE_* option is selected outside the tester, the EA refuses to initialize (`OnInit()` returns `INIT_FAILED`) regardless of whether it happens to match the real account mode. If FORCE_* is selected inside the tester but conflicts with the tester's reported mode, it also fails init. |
| Block_On_ForeignNettingExposure | bool | true | NETTING mode only: if a net position already exists on the symbol that does not match the EA's own Magic_Number, the EA refuses to open new positions and logs `D_FOREIGN_EXPOSURE_BLOCKED`, rather than attempting to manage or reverse exposure it didn't create. |
| Netting_ReverseOnOppositeSignal | bool | true | NETTING mode only: if a valid opposite-direction signal fires while an EA-owned position is open, close the existing position and open the new one, using the transactional sequence defined below. Reversal failure policy is named FAIL_FLAT: if the close succeeds but the reopen fails, the account is deliberately left flat rather than retried within the same tick. |
| MaxSpread_Points | int | 30 | If the current spread exceeds this at the moment of order submission, the order is vetoed (not just logged) and `D_SPREAD_EXCEEDED` is logged. |
| MaxDeviation_Points | int | 10 | Slippage tolerance passed to the order-send request (deviation parameter). Not a veto condition on its own; a rejection here surfaces as `D_ORDER_REJECTED`. |

#### Re-entry cooldown (new in v1.14)

**Why this exists.** Under the v1.13 crossover condition, the entry signal was self-limiting: a cross happens once, so a trend leg produced at most one entry and there was never a question of re-entering it. That property was never specified anywhere — it was a side effect of edge-triggering. Module A's v1.14 state condition removes the side effect while keeping the requirement, so the requirement now has to be stated outright. Without it, the sequence is: position closes on a structural exit → the trend state is still true on the very next bar (it usually is; Module E exits on structure, not on trend reversal) → the EA immediately re-enters the position it just exited. Module E and Module A would be in a direct loop, with the spread paid on every cycle.

**Rule (normative).** Let `LastCloseBarTime` be the open time of the LTF bar during which the most recent EA-owned position for this Symbol+Magic closed, for **any** reason — SL, TP, trailing stop, Module E structural exit, HTF-opposite backstop, netting reversal, or a manual/external close of an EA-owned position. On each signal bar, entry is blocked if:

```
BarsSince(LastCloseBarTime) < ReEntry_Cooldown_Bars
```

where `BarsSince` counts **closed LTF bars strictly after** the close bar. If no EA-owned position has ever closed in this run and none is found in history, the cooldown is inactive.

**The counting is stated exhaustively here because an off-by-one is the likeliest defect in the whole feature.** Let the position close during bar `N`. Bar `N` is then the signal bar of the next evaluation, so:

| Signal bar of the evaluation | `BarsSince` | Permitted when `ReEntry_Cooldown_Bars = C` |
|---|---|---|
| `N` (the close bar itself) | 0 | only if `C = 0` |
| `N + 1` | 1 | if `C ≤ 1` |
| `N + k` | `k` | if `C ≤ k` |

The general rule: **the earliest permitted entry is the evaluation whose signal bar is the `C`-th closed bar after the close bar.** So `C = 0` permits entry on the close bar's own evaluation — i.e. genuine same-bar re-entry — `C = 1` permits it one bar later, and `C = 5` permits it five bars later. Do not describe this as "the sixth bar"; counting the close bar's own evaluation as the first is the error this table exists to prevent.

**Scope decisions, each deliberate:**

- **Direction-agnostic.** The cooldown blocks entries in *both* directions, not just the direction of the closed position. A structural exit from a long, immediately followed by a short entry on the same structure, is the same whipsaw the cooldown exists to prevent — arguably a worse one. Section 7 records the direction-scoped alternative as an open question.
- **Counted in bars, not in seconds or ticks.** Everything else in Modules A–C and E is closed-bar-only; a wall-clock cooldown would be the single exception and would behave differently across timeframes and weekends for no benefit.
- **Applies to entries only.** The cooldown never delays, suppresses, or modifies an *exit*. Module E, the trailing stop, and SL/TP are entirely unaffected — a cooldown that could keep a position open would be a risk-management defect, not a frequency limiter.
- **Blocks at Execution Eligibility (Stage 2), not at signal generation.** The strategy signal is still produced, logged, and reported in SIGNAL_ONLY mode; only the order is withheld. This keeps the veto-rate diagnostic honest about how many tradeable signals the strategy actually found versus how many the cooldown suppressed, which is the whole point of measuring it.
- **Independent of `Max_Open_Positions`.** They answer different questions — "is a slot free" versus "has enough time passed since the last close" — and a position count of zero says nothing about recency. Both must pass.
- **The reopen leg of a NETTING reversal is exempt.** This is the one exemption, and without it the feature breaks the reversal mechanism outright. A reversal is a single transactional close-then-open (Module D's NETTING sequence); its close arms `LastCloseBarTime` like any other, so a cooldown applied to its own reopen would block every reversal at the last step and leave the account flat under FAIL_FLAT — silently converting reversals into exits. The reopen leg of an in-flight reversal is therefore **not** an entry for cooldown purposes and is never blocked by the cooldown that its own close just armed. Everything after that sequence completes is a normal entry and is gated normally, **including a FAIL_FLAT retry on a later bar**: once the sequence has ended flat, the next attempt is a fresh entry and the cooldown armed by the reversal's close applies to it in full. Section 7 records whether gating that retry is the right call as an open question; the exemption for the in-sequence reopen is not in question.
- **A Module E exit followed by a fresh signal on the same bar is *not* a reversal and gets no exemption.** Module E closes the position outright before Modules A–C run, so no close-then-open sequence is in flight; whatever Module A produces on that bar — same direction or opposite — is a new entry and is subject to the cooldown like any other. The practical consequence is stated plainly under Module E: at any `ReEntry_Cooldown_Bars ≥ 1`, same-bar re-entry after a structural exit cannot occur in either direction. That is the intended behaviour, and it is the entire point of the feature.

**Default rationale.** `5` is chosen so that a fresh swing pivot can confirm before re-entry is considered: Module E's default `Exit_PivotStrength = 2` requires `2 × 2 + 1 = 5` bars for a new pivot to become knowable, so a shorter cooldown would re-enter into structure the exit engine cannot yet see. This is a rationale for the default, **not** a coupling — `ReEntry_Cooldown_Bars` is an independent input, is not validated against `Exit_PivotStrength`, and remains meaningful when Module E is disabled. It is an uncalibrated starting value; see Section 7.

**Restart and adoption behaviour.** The cooldown holds no persisted state. At `OnInit()`, and whenever in-memory state is unavailable, `LastCloseBarTime` is reconstructed by scanning trade history for the most recent closed deal matching Symbol+Magic and converting its close time via `iBarShift(..., exact = false)` — `exact = false` is correct here, and is the one place in this document that differs from Module E's `exact = true` rule, because a deal's close time falls *within* a bar rather than *on* a bar boundary. If history is unavailable or the lookup fails, treat the cooldown as **inactive** rather than active: a missing history read must not silently freeze the EA out of trading for the rest of the run. Log `D_COOLDOWN_HISTORY_UNAVAILABLE` once when this path is taken.

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
4. Only after the close is confirmed, re-validate current market conditions from scratch (spread, margin, broker constraints — the same pre-fill checks as any new order) before submitting the new position in the opposite direction. Do not reuse the validation performed before step 2. **The re-entry cooldown is explicitly NOT part of this re-validation (v1.14).** Step 2 has just closed a position and therefore just armed `LastCloseBarTime` at the current bar, so re-checking the cooldown here would block the reopen every single time and strand the account flat under step 5. The reopen leg of an in-flight reversal is exempt by rule; see Module D's cooldown scope decisions. Re-validate market and broker conditions only.
5. If the (freshly-validated) open then fails, log `D_ORDER_REJECTED` and leave the account flat (FAIL_FLAT: do not retry within the same tick; retry only if a fresh signal recurs on a later signal bar). **That later retry is a fresh entry and *is* subject to the cooldown armed by step 2's close** — the exemption in step 4 covers only the reopen inside this sequence, not anything after it terminates. With the default `ReEntry_Cooldown_Bars = 5`, a failed reversal therefore leaves the account flat for at least five bars before it can re-enter, which is deliberate: a reversal that could not be completed is exactly the situation in which immediately retrying into the same conditions is least attractive.

Every stage of this sequence is logged independently, so a partial reversal (closed but didn't reopen) is always visible in the log.

**HEDGING:** independent positions in both directions are permitted, capped by Max_Open_Positions per direction (EA-owned positions only). A new signal never closes an existing opposite position automatically — each is managed independently until its own SL/TP or trailing stop.

**Aggregation logic — split into two stages:** a Strategy Signal stage, and a separate Execution Eligibility stage.

**Stage 1 — Strategy Signal** (this alone is what SIGNAL_ONLY reports):

1. Module A produces a raw directional signal on a newly closed LTF bar (the signal bar, shift 1). **As of v1.14 this may be — and typically will be — the same direction it produced on the previous bar;** Stage 1 has no notion of novelty and never suppresses a repeat.
2. Module B's HTF_Bias is LONG_ONLY or SHORT_ONLY and matches the signal direction (if HTF_Bias = BLOCKED, no signal in either direction).
3. Module C — evaluated on the same signal bar as Module A — does not veto.

If all three hold, the pipeline reaches `STRATEGY_SIGNAL_GENERATED`: the strategy would trade this direction, independent of whether the EA is currently able to execute it. Under v1.14 this state can hold on many consecutive bars, so `STRATEGY_SIGNAL_GENERATED` is a count of *tradeable bars*, not of trades — Section 5's diagnostics must report both, and the two figures should never be conflated when comparing a 1.4 run against a 1.3 one.

**Stage 2 — Execution Eligibility** (only relevant to whether an order is actually attempted; evaluated after Stage 1 passes, in both modes, but only acted on in AUTO):

4. Position count in the signal direction < Max_Open_Positions (EA-owned positions only; NETTING: effectively capped at 1 net position, and additionally subject to Block_On_ForeignNettingExposure; HEDGING: checked per direction).
5. **Re-entry cooldown has elapsed (v1.14):** `BarsSince(LastCloseBarTime) ≥ ReEntry_Cooldown_Bars`, per the rule above. Evaluated in both modes; a signal blocked only by the cooldown is still reported in SIGNAL_ONLY, logged with `D_COOLDOWN_ACTIVE`. Checked **before** order validation so that a cooldown block never consumes a broker round-trip.
6. Order validation (AUTO mode only): current spread ≤ MaxSpread_Points, and pre-fill broker constraints (lot step, margin, etc.) are satisfiable.

**Mode behavior:**

- **SIGNAL_ONLY:** logs/alerts on `STRATEGY_SIGNAL_GENERATED` unconditionally, i.e. purely from Stage 1. It additionally evaluates Stage 2's position-count check (step 4) and cooldown check (step 5) for informational purposes only — if execution would currently be blocked, it logs `EXECUTION_WOULD_BE_BLOCKED` alongside the signal, with the specific blocking reason (`D_MAX_POSITIONS` or `D_COOLDOWN_ACTIVE`) attached, but this never suppresses the signal log itself. SIGNAL_ONLY never evaluates order validation (step 6) and never submits, modifies, closes, or reverses anything, and never runs the trailing-stop logic — this applies even if a position happens to exist on the account from manual trading or a prior AUTO-mode run. **v1.14 caveat 1 — log volume:** because Stage 1 can now hold true across long runs of bars, SIGNAL_ONLY will emit substantially more log lines per unit time than it did in 1.3. This is expected; if it becomes unwieldy, throttle at the journal layer, never by reintroducing edge-detection in Module A.

  **v1.14 caveat 2 — SIGNAL_ONLY cannot simulate the cooldown, and must not be read as if it could.** The cooldown is armed by EA-owned position *closes*, and SIGNAL_ONLY never opens or closes anything. After the initial `OnInit()` reconstruction from trade history there is nothing to keep `LastCloseBarTime` current, so in a clean SIGNAL_ONLY run the cooldown is inactive for the entire run and `D_COOLDOWN_ACTIVE` is effectively unreachable. The consequence is specific and easy to get wrong: **SIGNAL_ONLY will report `EXECUTION_WOULD_BE_BLOCKED` for position-count reasons but essentially never for cooldown reasons, so its execution-eligibility reporting overstates how often AUTO would actually have traded.** Step 5 is still evaluated, and is still correct on the state it can see — it simply has no closes to see. Do not use a SIGNAL_ONLY run to estimate trade frequency, and do not treat a low `COOLDOWN_SUPPRESSED` count from one as evidence the cooldown is set too loosely. Use AUTO in the Strategy Tester for both. This is a structural limitation of alert-only mode, not a defect to be worked around by having SIGNAL_ONLY simulate fills.
- **AUTO:** requires both stages — Stage 1, then Stage 2 including order validation — to pass before submitting an order.

### Module E — LTF Structural Trade Exit (new in v1.13)

**Purpose.** Modules A–C decide whether to *open* a trade; Module E decides whether the LTF trend that justified an already-open trade has **failed**. It is deliberately not the inverse of the entry condition: requiring the entry evidence to reverse would exit only once the MA state itself flipped, which is the same lag the MA pair already suffers on entry. **(v1.14 note:** this rationale is unchanged by the Module A redesign and if anything is reinforced by it. The inverse-of-entry exit is *more* tempting under a level condition, since `FastMA[1] < SlowMA[1]` is a well-defined exit trigger in a way that "wait for the opposite crossover" never quite was — and it is still the wrong mechanism, for exactly the reason given here. MA cross-back remains on the exclusion list below, as a behaviour-free diagnostic only.**)** Instead, Module E monitors the one thing that defines a trend independently of any indicator — the swing sequence — and exits when it breaks.

For a LONG, the trade premise is a sequence of higher lows. The premise has failed when price closes below the latest *meaningful* higher low. For a SHORT, mirrored: closes above the latest meaningful lower high. That single test is the entire primary mechanism.

**v1.15 note — the symmetry problem, cross-referenced.** Under `Trend_Source = SWING_STRUCTURE` this module and Module A read the same underlying structure, and the "deliberately not the inverse of the entry condition" principle below is weakened rather than preserved. The full discussion, the three available positions, and the specified default are in Module A; nothing in Module E changes as a result. Under the default `Trend_Source = MA_STATE` the principle holds exactly as written.

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

**Single canonical implementation (requirement, not a preference).** The two predicates and the pivot collector live in exactly one place — `Include/MACrossEA_1.4/SwingStructure.mqh`, holding no indicator handles and no state — and both `ExitEngine.mqh` and `ReversalDetector.mqh` call it. No second implementation of the pivot algorithm may exist anywhere in the codebase. `ReversalDetector.mqh` (carried over from the 1.2 folder) currently uses strict comparison on **both** sides, which is a **behavioral** divergence from the definition above, not a documentation one; it must be refactored onto the shared predicate as part of this revision. Because that module is not yet wired into the running EA, the refactor carries no runtime risk at the time it is made. Both callers are covered by the same pivot unit tests (Section 6).

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

**Same-bar exit and re-entry — rewritten in v1.14, and the reasoning is now inverted.** Module E evaluates before Modules A–C on the same signal bar, so a position closed by Module E on bar N would, on the 1.13 logic, have been eligible for a new position on bar N if Module A produced a fresh crossover there. Under 1.13 that was a rare curiosity: same-direction re-entry required a fresh cross that the exit conditions made vanishingly unlikely, and the case was documented mainly for completeness.

Under v1.14 it is the **default** outcome rather than a rare one. Module A's state is still true on bar N — a structural break is not a trend reversal, and usually is not accompanied by one — so absent another mechanism the EA would re-enter the position it just exited, on the same bar, every time. That mechanism is Module D's `ReEntry_Cooldown_Bars`, which is what now governs this case; at its default of 5 the earliest re-entry is the evaluation whose signal bar is the fifth closed bar after the close bar (see Module D's counting table — the close bar's own evaluation is not counted as one of the five), and at `0` the same-bar re-entry loop is fully reproducible (Section 6, item 6d, uses it as a positive control).

**The opposite-direction case is now blocked too, and the earlier framing of it was wrong.** It is tempting to describe a same-bar exit-long-then-open-short as a "reversal" and reach for Module D's close-then-open sequence, but that sequence does not apply here: Module E has already closed the position outright before Modules A–C run, so nothing is in flight to reverse. Whatever Module A produces on that bar is a plain new entry, it is subject to the direction-agnostic cooldown, and the cooldown was armed by Module E's own close one step earlier on the same bar. **At any `ReEntry_Cooldown_Bars ≥ 1`, therefore, no entry of either direction can occur on a bar where Module E exited.** Only `ReEntry_Cooldown_Bars = 0` leaves the same-bar path live, which is precisely why Section 6 item 6d uses that setting as its positive control. Whether a genuine regime flip deserves an exemption is recorded as an open question in Section 7; as specified, it does not get one.

**Consequence for the evaluation-order rule — read this before "simplifying" it.** Module E runs before Modules A–C, and revision 1.13 offered two justifications: that an open position should be managed on the current bar's information before a new signal on that bar is considered, and that this ordering lets a same-bar exit-then-reversal follow Module D's netting sequence. **The second justification is void as of v1.14** at any non-zero cooldown, for the reason just given. The first is untouched and is sufficient on its own: managing before signalling is correct regardless of whether anything can be opened afterward, and it is what keeps Module E's decision independent of a signal computed on the same bar. Do not reorder Module E after A–C on the grounds that the reversal path is dead — the ordering was never really about the reversal.

**Post-exit cooldown — reversed in v1.14, and it now lives in Module D.** Revision 1.13 excluded a cooldown on this reasoning: *"Re-entry already requires a fresh Module A crossover (shift 2 → shift 1), which cannot re-fire on the bar that just exited. An explicit cooldown would be a second, redundant suppression mechanism."* That reasoning was sound and is now void — its entire load was carried by the crossover being edge-triggered, and step 1 is a level as of this revision. What was redundant is now the only thing standing between Module E and an immediate re-entry loop.

The cooldown is therefore **implemented, and specified in Module D as `ReEntry_Cooldown_Bars`**, not here. Placement is deliberate: it is an execution-eligibility rule about position recency, not an exit rule, and Module E must not acquire the power to suppress entries. Module E's only relationship to it is that the cooldown consumes Module E's exits as one of several close reasons, without distinguishing them from SL, TP, or a manual close.

This is the one entry from 1.13's exclusion list that v1.14 reverses on argument rather than on the evidence gate below, because the argument that justified excluding it was a statement about Module A's form and Module A's form changed. The remaining exclusions stand.

#### Deliberately excluded from this revision

Each was considered and rejected for the first implementation; the first three are logged as diagnostic counters so their value can be measured rather than assumed.

| Excluded | Reason |
|---|---|
| Fast/slow MA cross-back as a hard exit | On a chaotic LTF, a pullback deep enough to cross the MAs but too shallow to break a meaningful swing is common — it would exit trades the structural test correctly holds. Logged as `E_DIAG_MA_CROSSBACK`. **(Acknowledged tension, pre-dating v1.14 and not resolved by it:** under NETTING with `Netting_ReverseOnOppositeSignal = true`, an opposite Module A signal closes the position — and an opposite Module A signal requires the MA state to have flipped. A cross-back exit is therefore reachable through Module D's reversal path even though Module E excludes it here. The two are not equivalent: Module D additionally requires both-MA monotonicity in the new direction, candle-colour agreement, **and** a full HTF bias flip, so it fires on a genuine regime change rather than on the shallow pullback this row rejects. But the mechanisms do overlap, Module E does not own the exit in that case, and anyone reading this row as "an MA flip never closes a position" would be wrong. Under HEDGING no such path exists, since a new signal never closes an opposite position.**)** |
| Two-level structure (minor = warning, major = exit) | The same knob as `Exit_MinSwingATR` at a second resolution; the significance filter already excludes minor swings from being the anchor. Costs a second threshold whose interaction with the first cannot be tuned without substantial data. Logged as `E_DIAG_MINOR_BREAK`. |
| HTF-neutral sensitivity tiers / trailing tightening on HTF loss | `HTF_BLOCKED` already blocks new entries via Module B; making it also alter exit behavior gives one HTF state two jobs. Logged as `E_DIAG_HTF_NEUTRAL`. |
| `Exit_MinBarsInTrade` grace period | Time-based suppression with no structural meaning; blocks a genuine immediate reversal. Superseded by the entry-distance requirement in initialization. **(v1.14: still excluded, and not to be confused with Module D's new `ReEntry_Cooldown_Bars`.** This row is about a minimum hold time before an *exit* may fire, which would delay risk reduction and is rejected on that basis. The cooldown is about a minimum wait before a new *entry* may fire, which delays only opportunity. Opposite direction, opposite risk profile — adopting one says nothing about the other.**)** |
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
  RequiredBars = max(SlowMA_Period, TrendConfirm_Bars, LTF_ConfirmationCandles,
                      Regression_Bars, LTF_ATR_Period,
                      ATR_Period, ATR_Avg_Period + ATR_Contraction_Bars + 1, RSI_Period,
                      MACD_Slow + MACD_Signal, Stoch_K + Stoch_D + Stoch_Slowing, CCI_Period)
                  + safety margin (e.g. +5 bars)
  ```

  **v1.14 note on Module A's contribution.** `LTF_ConfirmationCandles` is added to the `max()` explicitly — it was reachable through the safety margin at its default of 3 but was never a listed term, which would have failed silently at larger values. The removal of the crossover test does **not** reduce this figure: step 1 previously read shift 2 and now reads only shift 1, but step 2's monotonic window already reached shift `TrendConfirm_Bars` ≥ 2, so it was never the binding term. No implementation should reduce its history requirement on account of this revision.
  for the LTF, and the equivalent for HTF (HTF_MA_Period, HTF_TrendConfirm_Bars). Refuse to evaluate signals until history covers this figure.

  **Trend-source terms (v1.15).** `RequiredBars` takes `ActiveSource.RequiredBars()` into the same `max()`, and — when `Trend_Diagnostic_Mode = SHADOW` — the shadow source's figure as well, since the shadow evaluation must not silently produce garbage readings that then contaminate the comparison. `CMATrendSource.RequiredBars()` is `max(SlowMA_Period, TrendConfirm_Bars)`; `CStructureTrendSource.RequiredBars()` is `Struct_ScanBars + Struct_PivotStrength + 2`, by the same derivation as Module E's scan window (a pivot at the far edge compares against bars a further `S` older). `BarsCalculated()` on the structure source's ATR handle must cover the same figure.

  **Module E terms (v1.13):** `RequiredBars` additionally takes `Exit_ScanBars + Exit_PivotStrength + 1` and `Exit_ATR_Period` into the same `max()`. The `+ Exit_PivotStrength + 1` is not padding: `Exit_ScanBars` is the size of the initial-anchor search window, and a pivot at its far edge compares against bars a further `S` older, so that is the true depth. The deepest ATR read is the oldest candidate's confirmation bar, `S` bars *newer* than the oldest pivot examined, so it is strictly inside the OHLC requirement and adds nothing. `BarsCalculated()` on the Module E ATR handle must cover the same figure. For an **adopted** position the requirement is measured from the entry bar instead of from the current bar — `iBarShift(EntryBarTime, exact) + Exit_ScanBars + S + 1` — and failing it yields `E_DATA_NOT_READY`, never `E_NO_ANCHOR` (see Module E).
- **Parameter validation at OnInit():** the EA must validate inputs and fail initialization (`INIT_PARAMETERS_INCORRECT`) on invalid combinations, at minimum:
  - FastMA_Period > 0, SlowMA_Period > FastMA_Period
  - **TrendConfirm_Bars ≥ 2 — unconditional as of v1.14** (it is part of the primary condition; the `Enable_TrendConfirm_Check` guard that qualified this rule through 1.13 is deleted along with the input). Regression_Bars ≥ 2 (only enforced when `Enable_Angle_Check = true`) — intentionally independent of each other; no relationship between them is enforced
  - **LTF_ConfirmationCandles ≥ 1 — only enforced when `Enable_LTF_CandleColor_Check = true`** (v1.14), matching the v1.9 conditional-validation pattern
  - **Trend source (v1.15), enforced per selected source:**
    - `MA_STATE`: FastMA_Period, SlowMA_Period and TrendConfirm_Bars as above — unchanged.
    - `SWING_STRUCTURE`: Struct_PivotStrength ≥ 1; Struct_MinSwingATR ≥ 0 (zero is legal and means "any higher high counts", the control case for item 6k); Struct_ATR_Period ≥ 1; **Struct_ScanBars ≥ 4 × Struct_PivotStrength + 4** — four pivots plus their confirmation bars is the minimum window in which a reading can exist at all, and a smaller value guarantees `A_STRUCT_INSUFFICIENT_PIVOTS` on every bar.
    - When `Trend_Diagnostic_Mode = SHADOW`, **both** sources' validations are enforced, not just the selected one's. A shadow source running on invalid parameters produces a comparison that is worse than no comparison.
    - No relationship is enforced between `Struct_*` and `Exit_*`. In particular `Struct_MinSwingATR > Exit_MinSwingATR` is recommended under `SWING_STRUCTURE` (see Module A's symmetry note) but deliberately **not** validated — it is a tuning position, not an invariant, and Section 7 records it as open.
  - **Trend_Compare_Horizon ≥ 1** (v1.15), enforced only when `Trend_Diagnostic_Mode = SHADOW`
  - **ReEntry_Cooldown_Bars ≥ 0** (v1.14; zero is legal and means no cooldown). No upper bound and no cross-validation against `Exit_PivotStrength` — see Module D for why the default's rationale is not a coupling
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
- **Logging with standardized reason codes:** `A_NO_TREND`, `A_NO_TREND_STATE`, `A_TREND_CONFIRM_FAIL`, `A_STRUCT_INSUFFICIENT_PIVOTS`, `A_STRUCT_NO_PATTERN`, `A_STEP_NOT_APPLICABLE`, `A_CANDLE_COLOR_FAIL`, `A_ANGLE_FAIL`, `A_SEPARATION_FAIL`, `B_HTF_BLOCKED`, `C_MOMENTUM_FAIL`, `C_ATR_CONTRACTION`, `D_MAX_POSITIONS`, `D_COOLDOWN_ACTIVE`, `D_COOLDOWN_HISTORY_UNAVAILABLE`, `D_ACCOUNT_MODE_MISMATCH`, `D_FOREIGN_EXPOSURE_BLOCKED`, `D_SPREAD_EXCEEDED`, `D_CLOSE_FAILED`, `D_ORDER_REJECTED`, `D_INSUFFICIENT_MARGIN`, `DATA_NOT_READY`, `EXECUTION_WOULD_BE_BLOCKED`.

  **v1.15 reason-code changes.** `A_NO_TREND` is the new source-agnostic code for `Direction == 0`; each source additionally reports a specific code so the two are distinguishable in the summary. Under `MA_STATE`, `A_NO_TREND_STATE` keeps its v1.14 meaning (exact `FastMA[1] == SlowMA[1]`, near-zero in practice). Under `SWING_STRUCTURE`, `A_STRUCT_INSUFFICIENT_PIVOTS` (fewer than four confirmed pivots in the window — a data condition) and `A_STRUCT_NO_PATTERN` (pivots exist, but the highs and lows disagree — a market condition) are kept strictly distinct, for the same reason `E_DATA_NOT_READY` and `E_NO_ANCHOR` are: only the second is a statement about the market. Merging them would hide a mis-set `Struct_ScanBars` behind what looks like an absence of trends. `A_STEP_NOT_APPLICABLE` is logged once at `OnInit()` when the angle or separation toggle is true under a source those steps cannot apply to. **Journals are not comparable across trend sources** — a 1.5 run under `SWING_STRUCTURE` shares no Module A reason-code series with a 1.4 run, and `TRADEABLE_BARS` under one source is not the same quantity as under the other.

  **v1.14 reason-code changes.** `A_NO_CROSS` is **renamed** to `A_NO_TREND_STATE` and its meaning narrows sharply: it now fires only when `FastMA[1] == SlowMA[1]` exactly, which on live FX data will be close to never — where 1.3 logged it on 185,236 of 189,145 bars, 1.4 will log it on a handful. `A_CANDLE_COLOR_FAIL` is **new**, splitting the candle-colour rejection out of the combined LTF-confirmation code that 1.2 introduced; the monotonic and candle-colour vetoes must be counted separately, because the 1.3 run showed them differing by a factor of five and a merged counter hid that. `A_TREND_CONFIRM_FAIL` correspondingly narrows to the step-2 monotonic run alone and becomes the dominant Module A veto. `D_COOLDOWN_ACTIVE` and `D_COOLDOWN_HISTORY_UNAVAILABLE` are new with the cooldown. Implementations migrating a 1.3 journal parser must treat `A_NO_CROSS` and `A_NO_TREND_STATE` as non-comparable series rather than renaming one to the other in historical data. **Module E (v1.13) adds:** `E_STRUCT_EXIT`, `E_HTF_CONFIRMED_OPPOSITE`, `E_NO_ANCHOR`, `E_DATA_NOT_READY`, `EXIT_WOULD_TRIGGER`, plus the behavior-free diagnostics `E_DIAG_MA_CROSSBACK`, `E_DIAG_MINOR_BREAK`, `E_DIAG_HTF_NEUTRAL`. Module E close failures reuse the existing `D_CLOSE_FAILED` with the triggering exit reason attached — no separate code. `E_DATA_NOT_READY` and `E_NO_ANCHOR` are never interchangeable: the first means the search could not run, the second that it ran and found nothing. Only the second is a statement about market structure.
- **Signal vs. order state distinction:** `RAW_SIGNAL → HTF_APPROVED → MOMENTUM_APPROVED (= STRATEGY_SIGNAL_GENERATED) → POSITION_ALLOWED → COOLDOWN_CLEARED → ORDER_VALIDATED (pre-fill) → ORDER_SUBMITTED → ORDER_FILLED → SLTP_VALIDATED (post-fill) → SLTP_ATTACHED`. **`COOLDOWN_CLEARED` is new in v1.14** and corresponds to Stage 2 step 5; it sits after the position-count check and before order validation, matching the aggregation logic exactly so the two descriptions cannot drift. NETTING reversal has its own branch, which **bypasses `COOLDOWN_CLEARED` on its reopen leg** per Module D's exemption: `POSITION_ALLOWED → COOLDOWN_CLEARED → CLOSE_VALIDATED → CLOSE_SUBMITTED → CLOSE_CONFIRMED / CLOSE_FAILED → OPEN_VALIDATED (fresh, no cooldown re-check) → OPEN_SUBMITTED → OPEN_FILLED / FAIL_FLAT`. The cooldown is evaluated once, at the head of the sequence, and never again inside it. **Module E has its own branch (v1.13):** `POSITION_OPEN → STRUCT_ANCHOR_SET → ANCHOR_RATCHETED (0..n) → STRUCT_EXIT_TRIGGERED → CLOSE_SUBMITTED → CLOSE_CONFIRMED / D_CLOSE_FAILED`. `D_CLOSE_FAILED` returns to `POSITION_OPEN` with state retained — the break is re-tested on the next bar, not queued. A position that never establishes an anchor stays at `POSITION_OPEN` with `E_NO_ANCHOR` logged; this is not terminal and initialization is retried each closed bar.
- **Built-in veto-rate diagnostics (added v1.9):** the EA maintains a running counter for every reason code above (per module, per bar) for the lifetime of the run, and prints a summary block at `OnDeinit()` — total LTF bars evaluated, and a pass/fail breakdown per module (A/B/C), the count of `STRATEGY_SIGNAL_GENERATED`, and orders actually attempted. When any bars are rejected by `A_ANGLE_FAIL`, the summary additionally reports the min/avg/max of the actual computed `angle_degrees` values on those rejected bars, so `MinCross_Angle_Deg` can be calibrated from the real distribution of a given symbol/timeframe rather than by trial and error. This directly implements the veto-rate analysis called for in Section 6, without requiring external tooling or log-scraping — combined with the debug toggles (Section 1, Module A), a tester can isolate exactly one filter, run a backtest, and read the summary to see whether that filter alone is over-rejecting.

  **v1.14 additions to the summary — the bar/trade distinction.** Because Stage 1 is now level-triggered, a single counter of `STRATEGY_SIGNAL_GENERATED` no longer approximates trade count and comparing it against a 1.3 run is meaningless. The summary must therefore report, separately and with these names:

  - **`TRADEABLE_BARS`** — signal bars where Stage 1 passed. Comparable across 1.4 runs only.
  - **`STATE_EPISODES`** — maximal unbroken runs of same-direction tradeable bars, counted by transition (increment when Stage 1 passes and either the previous signal bar failed Stage 1 or passed it in the opposite direction). This is the closest 1.4 analogue to 1.3's cross count, and is the figure to use when comparing the two revisions. It is a diagnostic only: nothing in the engine branches on it.
  - **`SLOT_FREE_BARS`** — tradeable bars on which the position-count check (Stage 2 step 4) also passed, i.e. bars where an order was actually possible. This is the correct denominator for the cooldown ratio below and must be reported separately; using `TRADEABLE_BARS` instead is wrong, because with `Max_Open_Positions = 1` and multi-hour holds the majority of tradeable bars have a position already open and were never candidates for an entry in the first place.
  - **`ORDERS_ATTEMPTED`** and **`COOLDOWN_SUPPRESSED`** — the latter counting bars blocked by `D_COOLDOWN_ACTIVE` (position slot free, cooldown not elapsed). The ratio of `COOLDOWN_SUPPRESSED` to **`SLOT_FREE_BARS`** — not to `TRADEABLE_BARS` — is the direct read on whether `ReEntry_Cooldown_Bars` is set sanely; a value near zero means the cooldown is inert, and a value near one means it is the strategy. Against `TRADEABLE_BARS` the ratio has a ceiling far below 1 and neither end of that scale means anything.
  - The **mean and max length, in bars, of state episodes**, which is the input needed to choose `ReEntry_Cooldown_Bars` on a principled basis rather than by sweep alone: a cooldown longer than the mean episode reduces the strategy to roughly one trade per trend leg, which is 1.13 behaviour reached by a different route, and if that is what testing prefers then the crossover form deserves reconsideration on its merits.

  The summary header must print the code-folder version (`v1.5`), and — new in v1.15 — the active trend source's `Name()` and the diagnostic mode, since `TRADEABLE_BARS` means a different thing under each source and a summary that does not say which one produced it is unreadable six months later.

- **Trend-source comparison diagnostics (added v1.15).** When `Trend_Diagnostic_Mode = SHADOW`, the summary additionally reports the agreement matrix, directional accuracy on disagreement bars, mean signed lead/lag, and per-source coverage, as specified under Module A's Phase 0 section. Two reporting rules are normative: the agreement rate must be reported **both** overall and restricted to bars where `HTFBias != BLOCKED` (only the latter population can ever trade, and on the as-tested configuration it is roughly a fifth of bars); and directional accuracy must be reported **only** over `DISAGREE` bars, because on agreement bars both sources are right or wrong together and the number would be a measure of the market rather than of the sources.
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
    // v1.15: Module A no longer computes direction — it asks the selected source.
    // Both sources are evaluated under SHADOW; only the active one has authority.
    active = TrendSources[Trend_Source].Evaluate(SignalBar)
    if Trend_Diagnostic_Mode == SHADOW:
        shadow = TrendSources[other].Evaluate(SignalBar)
        LogTrendCompare(SignalBar, active, shadow, ModuleB.PeekBias())  // diagnostic ONLY —
                                      // must not reach Module B/D or any execution counter
    A = EvaluateModuleA(SignalBar, active)   // v1.15: direction+confirmation from `active`,
                                      // then candle colour (toggleable), angle, separation.
                                      // Stateless — may return the same direction many
                                      // bars running; never dedupes its own output.
    if not A.passed:
        Log(A.reasonCode); return    // A_NO_TREND_STATE / A_TREND_CONFIRM_FAIL /
                                      // A_CANDLE_COLOR_FAIL / A_ANGLE_FAIL / A_SEPARATION_FAIL
    B = EvaluateModuleB()            // most recently completed HTF candle — unchanged in v1.14,
                                      // and now the primary limiter (see Module B)
    if not B.permits(A.direction):
        Log(B.reasonCode); return
    C = EvaluateModuleC(SignalBar)   // same signal bar as A
    if not C.passed:
        Log(C.reasonCode); return
    // --- Stage 1 complete: STRATEGY_SIGNAL_GENERATED ---
    // NOTE: under v1.14 this point is reached on runs of consecutive bars, not on
    // isolated ones. Counting trades by counting arrivals here is wrong.
    FinalSignal = A.direction
    positionAllowed = ModuleD.PositionAllowed(A.direction)    // Stage 2, step 4
    cooldownElapsed = ModuleD.CooldownElapsed()               // Stage 2, step 5 (v1.14)
    executionAllowed = positionAllowed and cooldownElapsed
    if Execution_Mode == SIGNAL_ONLY:
        if executionAllowed:
            LogAndAlert(FinalSignal)                          // signal only
        else:
            blocker = positionAllowed ? D_COOLDOWN_ACTIVE : D_MAX_POSITIONS
            LogAndAlert(FinalSignal, EXECUTION_WOULD_BE_BLOCKED, blocker)  // signal still reported
        return
    if not positionAllowed:
        Log(D_MAX_POSITIONS); return          // also covers D_FOREIGN_EXPOSURE_BLOCKED
    if not cooldownElapsed:
        Log(D_COOLDOWN_ACTIVE); return        // v1.14 — before order validation, so a
                                              // cooldown block costs no broker round-trip
    if not ModuleD.OrderValidated(A.direction):   // pre-fill checks only, see Module D
        Log(D_SPREAD_EXCEEDED / broker constraint code); return
    ModuleD.Execute(FinalSignal)  // submits order, then post-fill computes/validates/attaches SL-TP
                                  // handles account-mode-aware submission (netting reversal branch, etc.)
                                  // v1.14: the cooldown was checked ONCE, above. Execute() must NOT
                                  // re-check it internally — the netting reversal closes a position
                                  // partway through, which arms LastCloseBarTime at this very bar,
                                  // so a re-check would block the reversal's own reopen every time
                                  // and strand the account flat. See Module D, reversal step 4.
```

## 6. Testing & Validation Plan

1. Unit-level validation of each module in isolation using synthetic MA sequences, including **rising-state and falling-state** cases (v1.14 — fixtures are state sequences, not cross events; a fixture built around a single cross bar no longer exercises the condition under test) to confirm the angle-between-lines calculation produces the same magnitude-based pass/fail behavior regardless of direction, and an explicit near-perpendicular-slopes case to confirm the `1 + b_fast′×b_slow′ = 0` degenerate case is handled without a divide-by-zero.
2. Historical backtest using Dukascopy tick data, staged as: Module A only → A+B → A+B+C, to isolate the marginal effect of each filter. Additionally test A+C in isolation of B, and compare trade frequency/quality across different Momentum_Filter selections. Also isolate the angle check from the separation check (angle-only, separation-only, both). **v1.14 note on the "Module A only" stage:** with the HTF gate removed and a level-triggered condition, this stage trades on essentially every bar the two MAs are monotonic in the direction of their own ordering — expect a trade count one to two orders of magnitude above 1.3's and a correspondingly large spread bill. That is the stage behaving correctly, not a misconfiguration; its purpose is to establish the denominator every later stage is measured against, and it is not a candidate configuration. Set `ReEntry_Cooldown_Bars = 0` here too, so the stage measures Module A alone rather than Module A throttled by Module D.
3. Boundary testing at exact threshold values (MinCross_Angle_Deg at its 0/90 bounds, MinMA_Separation in both unit modes, momentum thresholds, `%K[1] = 50` for Stochastic).
4. Visual verification on chart (plot fast/slow MA, HTF MA, and mark accepted vs. vetoed signals with the blocking reason) before enabling AUTO mode live.
5. Veto-rate analysis: measure the pass rate at each stage explicitly — total bars → A pass % (`TRADEABLE_BARS`, plus `STATE_EPISODES`) → B pass % → C pass % → position-eligible % → cooldown-eligible % → orders actually sent — to surface unintended bottlenecks before tuning is attempted. Expect `B_HTF_BLOCKED` to dominate under v1.14 where `A_NO_CROSS` dominated under 1.13; that shift is the expected signature of the redesign, and its absence means step 1 was not actually converted to a level test.
6. **Isolation procedure using the debug toggles:** run the backtest with `Enable_LTF_CandleColor_Check`, `Enable_Angle_Check`, `Enable_Separation_Check` all set to `false`, `Momentum_Filter = NONE`, `Enable_ATR_VolatilityFilter = false`, and `ReEntry_Cooldown_Bars = 0` — this exercises only the mandatory primary condition (LTF trend state + both-MA monotonic + HTF gate) and should produce a *very* high trade count if the core logic and historical data are sound. Note this baseline differs in character from 1.13's: there the concern was too few trades, here it will be too many, and a baseline that produces few trades indicates a defect in the state conversion rather than an over-tight filter. Then re-enable exactly one toggle, re-run, and compare the veto-rate summary (Section 5) against the baseline. Repeat one filter at a time. A filter whose re-enabling collapses `TRADEABLE_BARS` back toward zero is either mis-implemented or configured with an unreachable threshold for the tested symbol/timeframe — cross-check its specific counter and (for the angle check) the reported min/avg/max angle values against its configured threshold before concluding which.

**Module A state-conversion test plan (added v1.14).** Items 6a–6f are specific to the crossover→state redesign and the cooldown. 6a–6c are unit tests runnable without a broker; 6d–6f require a backtest.

   **6a. Step 1 is a level, not an edge.** Feed a synthetic MA sequence in which the fast MA crosses above the slow MA once and then stays above for 50 bars, with both MAs monotonically rising throughout. Assert Module A returns LONG on **all 50** bars, not on the first alone. Then feed a sequence already in the long state at the first evaluated bar, with no cross anywhere in the available history, and assert Module A returns LONG on the very first bar — this is the case the 1.13 implementation could never produce, and it is the single most direct regression test for the redesign.

   **6b. Exact-equality and mirror symmetry.** `FastMA[1] == SlowMA[1]` bit-exactly returns NONE and logs `A_NO_TREND_STATE`; no bar in any sequence satisfies both LONG and SHORT; the LONG and SHORT paths produce identical results on a sign-flipped input sequence. Include a case where equality occurs mid-run to confirm it breaks the state cleanly rather than latching the prior direction.

   **6c. Cooldown arithmetic.** Assert against Module D's counting table directly, with the position closing during bar `N`: `ReEntry_Cooldown_Bars = 0` permits entry on the evaluation whose signal bar is `N` — the close bar's own evaluation, i.e. genuine same-bar re-entry; `= 1` blocks that evaluation and permits the one at `N + 1`; `= 5` blocks through signal bar `N + 4` and permits at `N + 5`, the fifth closed bar after the close bar. **State each expectation as a signal-bar index, never as an ordinal like "the sixth bar" — the ordinal phrasing is ambiguous about whether the close bar counts as the first, and that ambiguity is exactly how an off-by-one gets shipped.** Also assert: the cooldown blocks both directions; it never delays an exit; the reopen leg of a NETTING reversal is *not* blocked by the close that same sequence just performed, while a FAIL_FLAT retry on a later bar *is*; restart reconstruction from trade history yields the same `LastCloseBarTime` as the in-memory value (mirror of Module E's item 12); and an unavailable history read leaves the cooldown **inactive** with `D_COOLDOWN_HISTORY_UNAVAILABLE` logged once.

   **6d. Module E interaction — the loop this revision exists to prevent.** Run with Module E enabled and `ReEntry_Cooldown_Bars = 0`, and assert the pathology is reproducible: structural exits followed by same-direction re-entry within one or two bars, at elevated trade count and spread cost. Then sweep the cooldown up and confirm the pattern disappears. A build that does *not* exhibit the pathology at zero cooldown has an undocumented edge-trigger somewhere in the signal path — find it before proceeding.

   **6e. Cooldown sweep** over `ReEntry_Cooldown_Bars` ∈ {0, 2, 5, 10, 20, 50} on otherwise identical settings, reporting trade count, `COOLDOWN_SUPPRESSED`/`TRADEABLE_BARS`, mean episode length, net P/L, and give-back. The default of 5 is an uncalibrated starting value (Section 7) and this sweep is what replaces it with a measured one.

   **6f. Head-to-head against 1.3.** Same symbol, period, and shared parameters, 1.3 versus 1.4, comparing `STATE_EPISODES` against 1.3's cross count and trade count against trade count. The purpose is **not** to show 1.4 is more profitable — on the evidence in Section 1 the entry had no measurable edge in either form, and a P/L improvement from this change alone would more likely indicate a lucky parameter than a real effect. The purpose is to confirm the two builds differ in the specific, predicted way (entries earlier in trends, more entries per trend leg, HTF gate binding instead of the cross) and in no unpredicted ways.

**Trend-source test plan (added v1.15).** Items 6g–6l cover the seam, the structure source, and Phase 0. 6g–6h and 6k are unit tests runnable without a broker; 6i, 6j and 6l require a backtest.

   **6g. The seam is behaviour-preserving at the default.** Run 1.5 with `Trend_Source = MA_STATE` and `Trend_Diagnostic_Mode = OFF` against 1.4 on identical inputs, identical symbol and identical period, and assert the trade lists are **byte-identical** — same entries, same exits, same tickets in the same order. This is the single most important test in the revision: the seam is only safe if introducing it changed nothing. A difference here means the refactor altered behaviour, and no other result from this revision can be trusted until it is explained. Then repeat with `Trend_Diagnostic_Mode = SHADOW` and assert the trade list is *still* identical, proving the shadow evaluation has no side effects.

   **6h. Structure source correctness**, against synthetic pivot sequences: a clean HH/HL staircase returns +1 on every bar once four pivots exist; the mirrored sequence returns −1; an expanding range (higher high, lower low) returns 0 with `A_STRUCT_NO_PATTERN`; a coil (lower high, higher low) likewise; fewer than four pivots in the window returns 0 with `A_STRUCT_INSUFFICIENT_PIVOTS`, and the two codes are never interchanged. Include a sign-flipped input asserting the long and short paths are exact mirrors, matching test 6b's requirement for `MA_STATE`. Assert `sigma` is read at each pivot's own confirmation bar and **not** at shift 1 — the same property Module E's item 11 guards, and it fails the same way (invisibly) if got wrong.

   **6i. Phase 0 produces a usable comparison.** Run `SHADOW` over the full period and check the agreement matrix is populated, the forward-return column is filled only for bars whose horizon has elapsed, and — the assertion that matters — that **no row's `FwdReturn_N` could have been computed from bars unclosed at that row's `SignalBarTime`**. Sweep `Trend_Compare_Horizon` over {5, 10, 20, 50} and report whether the directional-accuracy conclusion is stable across horizons; if it flips, the diagnostic is measuring noise and must not be used to decide anything.

   **6j. The Module A / Module E symmetry collision.** Run `Trend_Source = SWING_STRUCTURE` with `Struct_MinSwingATR == Exit_MinSwingATR` and `ReEntry_Cooldown_Bars = 0`, and assert the pathology is reproducible: structural exits immediately followed by same-direction re-entries, at elevated trade count and spread cost. Then set `Struct_MinSwingATR > Exit_MinSwingATR` and confirm it subsides. This is the positive control for Module A's symmetry note, and it is deliberately shaped like item 6d — a build that does *not* exhibit it has a threshold or an ordering not doing what this document says.

   **6k. Structure threshold sweep** over `Struct_MinSwingATR` ∈ {0, 0.25, 0.5, 1.0} and `Struct_PivotStrength` ∈ {1, 2, 3, 5}, reporting `TRADEABLE_BARS`, `STATE_EPISODES`, `A_STRUCT_INSUFFICIENT_PIVOTS` rate, and mean episode length. `Struct_MinSwingATR = 0` is the control case: it makes any higher high count and should over-classify, proving the significance filter does something.

   **6l. Head-to-head, Phase 1.** Same symbol, period and shared parameters, `MA_STATE` versus `SWING_STRUCTURE`, both at `Structure_Entry_Trigger = STATE` so both are level-triggered and the trigger class is not a confound. Report trade count, `STATE_EPISODES`, hit rate against the bracket's breakeven, mean/median R and give-back for each. **Frame the result the way item 6f requires:** the purpose is to characterize the difference, and a P/L gap from a single configuration on a single symbol is a parameter draw, not a finding. A source is adopted on the strength of 6i's disagreement accuracy plus a 6l difference that survives out-of-sample, or it is not adopted.

**Module E test plan (added v1.13).** Items 7–17 below are specific to the structural exit. Items 8–13 are unit/property tests runnable without a broker; 7 and 14–16 require a backtest.

7. **Module E isolation:** `Enable_StructuralExit = false` (Exit_Mode alone) as baseline, then `true`, on identical entry settings — entries are unchanged between runs, so every difference is attributable to the exit. Compare win rate, mean/median R, and give-back (MFE − realized).
8. **Pivot predicate:** adjacent equal lows (exactly one pivot, at the newer bar); a monotonic run (no pivots); confirmation delay of exactly `S` bars; `pivotShift < S+1` self-rejection inside the predicate; a pivot at the exact scan-window edge; `Exit_PivotStrength = 1`; an outside bar registering as both a swing high and a swing low. Run against **both** callers (`ExitEngine`, `ReversalDetector`) from the same fixtures — the shared-predicate requirement is only meaningful if it is tested as shared.
9. **Anchor initialization:** window anchored to the entry bar, verified by initializing the same position at two very different later bars and asserting an identical anchor; a pivot confirmed *after* `EntryBarTime` correctly excluded from initialization and subsequently admitted by the ratchet; the entry-distance requirement (`Exit_MinSwingATR × σ_c`) rejecting a shallow pivot and selecting an older one; a position older than `Exit_ScanBars` bars still initializing.
10. **Ratchet:** LONG; SHORT; ATR spike at the moment of a ratchet; `Exit_MinSwingATR == Exit_StructureBufferATR` boundary; a non-qualifying candidate correctly skipped and never re-examined (`LastExaminedPivotTime` monotonic).
11. **Property test — continuous ≡ batch.** Over randomized synthetic price sequences, assert `ProtectedAnchor`, `AnchorBarTime`, and `AnchorATR` are identical at **every** bar between (a) continuous per-bar evaluation and (b) evaluation with randomized skipped blocks of 3–10 bars. This is the single highest-value test in the module: it fails for newest-first candidate selection, and it fails for any `ATR[1]` substituted where a confirmation-bar ATR belongs. Both defects are otherwise invisible in ordinary backtests.
12. **Restart reconstruction equivalence:** ratchet several times, discard in-memory state, re-adopt, assert the reconstructed anchor matches exactly; plus the insufficient-history case asserting `E_DATA_NOT_READY` and that **no** anchor is accepted.
13. **State integrity:** `E_DATA_NOT_READY` while a valid anchor is held must leave the anchor untouched and must suppress the break test, with recovery on the following bar resuming from the same anchor; `E_NO_ANCHOR` recovery when a qualifying pivot later confirms; an `iBarShift` exact-lookup failure surfacing as `E_DATA_NOT_READY` rather than silently relocating the anchor.
14. **Exit triggers and attribution:** structure break LONG; structure break SHORT; HTF confirmed opposite with no anchor present; `HTF_BLOCKED` producing no exit; and the both-true case asserting attribution to `E_STRUCT_EXIT`, not to the backstop.
15. **Execution paths:** close failure; close retry re-testing the break rather than resubmitting; price recovering so that the retry correctly sends nothing; `ClosePending` duplicate prevention; position disappearing between bar close and evaluation; SIGNAL_ONLY modifying nothing; same-bar exit followed by opposite-direction re-entry — **which as of v1.14 requires `ReEntry_Cooldown_Bars = 0` to be reachable at all, and must additionally be asserted *unreachable* at any non-zero cooldown** (see Module E's same-bar subsection; the cooldown is armed by Module E's own close earlier in the same bar).
16. **Threshold sweep** on `Exit_MinSwingATR` (0 / 0.25 / 0.5 / 1.0) and `Exit_StructureBufferATR` (0 / 0.1 / 0.2 / 0.5) over identical entries. `Exit_MinSwingATR = 0` reproduces "ratchet on every confirmed pivot" and should over-exit — it is the control case proving the significance filter does something.
17. **Multiple positions / hedging** — specified now, runnable when Module D's multi-position stage lands; `CPositionCore` is currently a single-position implementation.

**Gate on the excluded mechanisms:** no item from Module E's exclusion table is implemented until its diagnostic counter shows it fired *before* `E_STRUCT_EXIT` on a material share of trades **and** that doing so improved the outcome.

## 7. Assumptions Requiring Confirmation

- **Which trend source (v1.15, the central open question of this revision).** `MA_STATE` remains the default and `SWING_STRUCTURE` ships unvalidated. Neither has been shown to detect trends well; the MA form has one discouraging measurement against it (32.5% against a 33.3% breakeven) and the structure form has no measurement at all. This revision deliberately does **not** choose — it builds the seam, the second source, and the Phase 0 instrumentation, and defers the choice to items 6i and 6l. **Do not read the existence of `SWING_STRUCTURE` in this document as a recommendation of it.** Still open.
- **Whether the entry is the problem at all (v1.15).** The 1.3 result is equally consistent with a sound entry and a mismatched 2:1 bracket. Phase 0 can partly separate these: if the two sources agree on the overwhelming majority of tradeable bars, then entry selection is not where the strategy's performance is determined, and the next revision should target exits and position sizing instead of trend detection. That is a valuable outcome and must not be treated as a failed experiment. Still open.
- **`Struct_MinSwingATR` versus `Exit_MinSwingATR` (v1.15).** Under `SWING_STRUCTURE` the entry and the structural exit read the same structure, and the spec's position is that entry should demand more than the exit defends. That relationship is recommended, tested by item 6j, and deliberately not validated at `OnInit()`. Confirm whether it should become a hard rule once 6j has run. Still open.
- **Structure for the HTF gate (v1.15).** Module B stays MA-based in this revision to keep the Phase 1 comparison clean. If `SWING_STRUCTURE` wins on the LTF, the same question applies to the HTF gate and the seam is built to allow it. Still open, and deliberately not attempted here.
- **Entry-condition form: level vs. edge (v1.14, the central open question of that revision).** Through 1.13 the primary condition was the crossover event; as of 1.14 it is the trend state. Neither form has been validated as carrying an edge. What *is* measured is that the crossover form did not: over 2019–2026 on EURUSD M15 its 209 trades resolved a 2:1 bracket at a 32.5% hit rate against a 33.3% breakeven, which is what a random entry with the same bracket returns. The state form is adopted because the crossover's specific failure mode was diagnosable (systematic late entry — the slow MA was already trending on 91% of crosses) and because the event/level conflation was a genuine design defect regardless of profitability. **It is not adopted on evidence that it performs better, and it should not be described that way.** Section 6 item 6f exists to characterize the difference, not to declare a winner. Until that runs, treat both forms as unvalidated. Still open — and note that this assumption went unrecorded here through thirteen document revisions, which is why it now leads the list.
- **`ReEntry_Cooldown_Bars` default (v1.14)** — `5` is derived from Module E's pivot-confirmation delay at default settings (`2 × Exit_PivotStrength + 1`), not from measurement. Needs the Section 6 item 6e sweep per symbol/timeframe before going live. Also confirm the value should not simply track `Exit_PivotStrength` automatically; the current spec deliberately keeps them independent so the cooldown remains meaningful with Module E disabled, but that is a judgement call. Still open.
- **Cooldown direction scoping (v1.14)** — the cooldown currently blocks both directions after any close. The alternative is to block only the direction just closed, allowing an immediate reversal. Direction-agnostic is specified because a structural exit from a long immediately followed by a short on the same broken structure is the same whipsaw, but the opposite case — a genuine regime flip where the HTF gate has also turned — is penalized by it. Resolve from item 6e's data rather than from first principles. Still open.
- **Netting reversal behavior under a level-triggered signal (v1.14 amendment)** — confirm Netting_ReverseOnOppositeSignal should default to true. This interacts with the state condition in a way it did not with the crossover: an opposite-direction signal is now persistently true rather than momentary, so a reversal that fails and leaves the account flat (FAIL_FLAT) will see the same opposite signal again on the next bar, where under 1.13 the signal would have evaporated. **Two parts of this are now decided and are not open:** the reopen leg inside an in-flight reversal is exempt from the cooldown (without that, reversals could never complete), and a FAIL_FLAT retry on a later bar is a fresh entry that the cooldown does gate. What remains open is whether gating that retry is right — it means a failed reversal leaves the account flat for at least `ReEntry_Cooldown_Bars` while a persistently-true opposite signal is on screen, which is defensible as caution but is also the EA declining a trade it believes in. Resolve alongside the direction-scoping question below, since both turn on how a genuine regime flip should be treated. Still open.
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

**Reading this table after v1.15:** entries below describe Module A as computing trend direction from a moving-average pair, because it did, for fourteen revisions. As of 1.15 it does not — it delegates to a selected trend source, of which the MA computation is one. Those entries are retained verbatim as history and are superseded on that specific point by Module A; the MA behaviour they describe is still reachable, and still the default, as `Trend_Source = MA_STATE`.

**Reading this table after v1.14:** many entries below describe the crossover as the primary trade condition, because it was, for thirteen revisions. It is not, as of 1.14. Those entries are retained verbatim as history and are all superseded on that specific point by Module A; per the normative rule above, do not implement a crossover requirement on their authority.

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
| **1.14** | **2026-08-14** | **New document + code folder pair `Markdown/MACrossEA_1.4` + `Autotrader/MACrossEA_1.4` (forked from 1.3, include paths renamed). A redesign of Module A's primary condition — the same category as the 1.12 change, so per the versioning-granularity note it gets its own folder rather than being edited into 1.3.** **The crossover is no longer a trade condition.** Module A step 1 changes from an edge-triggered test (`FastMA[2] ≤ SlowMA[2] AND FastMA[1] > SlowMA[1]`) to a level-triggered one (`FastMA[1] > SlowMA[1]`, mirrored for short, exact equality yielding no state), evaluated fresh every closed bar and true for as long as it holds; shift 2 is no longer read for the direction decision. Module A is renamed **LTF Trend-State Signal** and its scope restated: it reports whether a trend exists now and in which direction, and nothing else. Step 2 (both-MA strict monotonicity over `TrendConfirm_Bars`) is **promoted from filter to primary condition** alongside step 1 — the two are one indivisible test, since step 1 alone is true on essentially every bar — and `Enable_TrendConfirm_Check` is consequently **deleted**, with its OnInit() validation becoming unconditional. The v1.2 candle-colour check is **promoted from a staged-rebuild note to numbered step 3** and given the new `Enable_LTF_CandleColor_Check` toggle (default true), the first of Section 1's debug toggles to exist in code; it was promoted because the 1.3 backtest showed it rejecting ~1,795 crosses to the monotonic check's ~360, i.e. the spec had buried its own dominant veto. Angle and separation renumber to steps 4–5, remain unbuilt, and each gained a note on how its meaning changes under a level condition (separation becomes the natural "not too early" knob, since at a crossover the separation is near zero by definition). **Module B is unchanged and explicitly reaffirmed** as the mandatory second half of the trade condition; a note records that it now becomes the *primary* limiter, since the cross no longer filters 97.9% of bars ahead of it. **Module D gains `ReEntry_Cooldown_Bars` (default 5, `0` disables)** — the requirement the crossover had been meeting as a side effect of being edge-triggered, now stated outright. Counted in closed LTF bars since the last EA-owned close for any reason, direction-agnostic, blocking entries only and never exits, evaluated at Stage 2 before order validation so a block costs no broker round-trip, and reconstructed at OnInit() from trade history with `iBarShift(exact = false)` — the one deliberate departure from Module E's `exact = true` rule, since a deal's close time falls within a bar rather than on a boundary — failing **open** (cooldown inactive, `D_COOLDOWN_HISTORY_UNAVAILABLE` logged once) so a missing history read cannot freeze the EA out of trading. Its default of 5 derives from Module E's `2 × Exit_PivotStrength + 1` pivot-confirmation delay as a rationale, deliberately **not** as a coupling. Reason codes: `A_NO_CROSS` → **`A_NO_TREND_STATE`** (meaning narrows to exact MA equality — from 185,236 hits in the 1.3 run to near zero), new **`A_CANDLE_COLOR_FAIL`** splitting candle-colour out of the merged 1.2 LTF-confirmation counter, `A_TREND_CONFIRM_FAIL` narrowed to the monotonic run alone, plus **`D_COOLDOWN_ACTIVE`** and **`D_COOLDOWN_HISTORY_UNAVAILABLE`**; 1.3 journals are explicitly non-comparable on the renamed series. Diagnostics gain the **bar/trade distinction** that a level-triggered signal forces: `TRADEABLE_BARS`, `STATE_EPISODES` (the 1.3-comparable figure), `ORDERS_ATTEMPTED`, `COOLDOWN_SUPPRESSED`, and mean/max episode length — with the explicit warning that a cooldown exceeding mean episode length reduces the strategy to 1.13 behaviour by another route. Added testing items 6a–6f (level-not-edge assertion including the no-cross-in-history case that 1.13 could not produce; exact-equality and mirror symmetry; cooldown arithmetic and restart reconstruction; the Module-E-loop pathology as a *positive* control at zero cooldown; the cooldown sweep; and a 1.3 head-to-head framed as characterization, not as a profitability claim). **Housekeeping carried in the same pass, from the 1.3 review:** resolved the long-standing contradiction where Section 1 listed `Enable_*` toggles that Module A's staged note simultaneously declared nonexistent, by adding a normative **Status (Built/Unbuilt)** column; added the **two-version-axes mapping table** at the head of the document (document revision *n*.1x ↔ code folder 1.x) and required the `OnDeinit()` header to print the code-folder version, fixing a stale `v1.2` string that had been carried for two revisions; added an **as-tested configuration block** so field observations pinned to obsolete parameter sets are identifiable as historical; added `LTF_ConfirmationCandles` as an explicit `RequiredBars` term (previously reachable only through the safety margin, and silently insufficient at larger values); and **corrected a v1.8-era claim** that strict monotonicity is "considerably more selective" than general trending — measured at cross bars it rejected only ~9%, because MAs converge at a cross by construction, though under the state form its selectivity is genuinely high (~63% of bars pass). Recorded four open questions, led by the one absent through thirteen revisions: **neither the edge nor the level form has been validated as carrying an edge**, the level form is adopted because the crossover's failure mode was diagnosable and the event/level conflation was a defect regardless of profitability, and it must not be described as evidence-backed until item 6f runs. **Review pass applied before implementation, resolving nine defects found in this revision's own first draft:** the cooldown broke the NETTING reversal, because the reversal's own close armed `LastCloseBarTime` mid-sequence and the reopen leg read as a blocked entry — every reversal would have closed and never reopened, silently turning reversals into exits; the reopen leg is now exempt by rule, stated at Module D's scope decisions, at reversal step 4, in the state model, and in the canonical pseudocode, with a FAIL_FLAT retry on a later bar explicitly *not* exempt. Same-bar exit-then-reversal was described as live when the cooldown makes it unreachable at any non-zero value; Module E's subsection now says so outright, and — more importantly — records that the *second* of 1.13's two justifications for running Module E before Modules A–C is thereby void, while the first (manage before signal) is untouched and sufficient, so nobody reorders the modules on the strength of a dead rationale. An off-by-one in the cooldown's own prose ("the sixth signal bar" where the formula yields the fifth) had been copied into test 6c as an assertion; both are corrected against an explicit signal-bar-index table, and ordinal phrasing is now banned in that test. `STATE_EPISODES` was defined on Module A in the glossary and on Stage 1 in the diagnostics — several-fold apart, since Module B blocks most bars — and is now Stage 1 in both. The state model gained `COOLDOWN_CLEARED`, which Stage 2 step 5 had no counterpart for. `COOLDOWN_SUPPRESSED / TRADEABLE_BARS` was uninterpretable as specified, since the denominator counted bars where a position was already open and no entry was possible; a `SLOT_FREE_BARS` counter is added as the correct denominator. Documented that **SIGNAL_ONLY structurally cannot simulate the cooldown** — it never closes positions, so nothing arms it, and its execution-eligibility reporting therefore overstates how often AUTO would have traded. Acknowledged the pre-existing tension whereby Module D's NETTING reversal reaches the MA-cross-back exit that Module E's exclusion table rejects, with the distinction (reversal additionally requires a full HTF flip) spelled out in the exclusion row. Refreshed two stale test items: item 1's fixtures are state sequences rather than cross events, and item 2's "Module A only" stage now warns that it trades one to two orders of magnitude more often than 1.3 and is a denominator, not a candidate configuration. |
| **1.15** | **2026-08-15** | **New document + code folder pair `Markdown/MACrossEA_1.5` + `Autotrader/MACrossEA_1.5` (forked from 1.4, include paths renamed). A structural refactor of Module A plus a second trend source and the instrumentation to choose between them — explicitly NOT a behaviour change at the defaults.** **Module A no longer computes trend direction.** It delegates to an `ITrendSource` selected by the new `Trend_Source` input and applies the shared filters to the returned `TrendReading`. Five contract rules bind every source, present and future: stateless, level-triggered by default, never reads shift 0, `Direction` and `Confirmed` are one indivisible condition (generalizing the v1.14 rule that deleted `Enable_TrendConfirm_Check`), and a shadow reading never reaches Module B, Module D, or any execution counter. **`CMATrendSource` (`MA_STATE`, the default) carries v1.14's computation forward bit-for-bit**, so this revision changes no trading behaviour as shipped; test 6g asserts a byte-identical trade list against 1.4 and is the gate on everything else in the revision. **`CStructureTrendSource` (`SWING_STRUCTURE`) is new**: direction from the confirmed swing sequence — two higher highs **and** two higher lows for long, mirrored for short, anything mixed (expanding range, coil) yielding no trend rather than a guess. It reuses the canonical `SwingStructure.mqh` predicate rather than re-deriving pivots, and reuses Module E's one-ATR-rule — significance is measured against the ATR of each pivot's own **confirmation bar**, never `ATR[1]`, because the alternative breaks replay invariance in exactly the way Module E documents and is just as invisible in a backtest. `A_STRUCT_INSUFFICIENT_PIVOTS` (a data condition) and `A_STRUCT_NO_PATTERN` (a market condition) are kept strictly distinct on the same reasoning that separates `E_DATA_NOT_READY` from `E_NO_ANCHOR`. `Structure_Entry_Trigger` offers `STATE` (default, level) and `BREAK` (edge-ish, `Close[1]` beyond the last swing); `STATE` is the default specifically so the head-to-head compares sources rather than trigger classes. Steps 4–5 (angle, separation) are declared **inapplicable** rather than merely disabled under `SWING_STRUCTURE`, since both are defined over MA values; the EA logs `A_STEP_NOT_APPLICABLE` once at init and proceeds rather than failing. **Phase 0 shadow evaluation** (`Trend_Diagnostic_Mode = SHADOW`, default on) evaluates both sources every bar, writes a per-bar comparison CSV, and reports an agreement matrix, directional accuracy **restricted to disagreement bars**, signed lead/lag, and per-source coverage — the head-to-head measurement this document has assumed since 1.0 and never made. The forward-return column is filled retrospectively and item 6i asserts no lookahead leaks into it. Following Module E's established discipline, the new source earns authority by measurement rather than by argument. **Module A's symmetry problem with Module E is stated rather than solved:** under `SWING_STRUCTURE` the entry and the structural exit read the same structure, weakening Module E's "deliberately not the inverse of the entry condition" principle. Three positions are set out, the spec adopts separated thresholds (`Struct_MinSwingATR > Exit_MinSwingATR`, recommended but deliberately not validated), and item 6j is the positive control that reproduces the collision at equal thresholds. **Module B is untouched and explicitly so** — converting the HTF gate at the same time would confound the comparison. Modules C, D and E are unchanged. Added `Struct_*` inputs and their validation (including `Struct_ScanBars ≥ 4 × Struct_PivotStrength + 4`, below which no reading can exist), per-source `RequiredBars()` folded into the centralized figure with the shadow source's requirement included, six testing items (6g–6l), four open questions led by "which source" and by whether the entry is the problem at all, and a Built/Unbuilt status column extended to Module D's unimplemented account-mode handling. Document title changed from "MA Crossover" to "Trend", which had been misleading since 1.14. **Carried in the same pass, from the 1.4 code review:** the `OnDeinit()` header must print `v1.5` and the active source name, since `TRADEABLE_BARS` is not the same quantity under two different sources and a summary that omits which one produced it cannot be read later. |
