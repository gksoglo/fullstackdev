# PRD review notes — MACrossEA revisions 1.9 → 1.14

Review of the five supplied revisions (1.9, 1.11, 1.12, 1.13, 1.14) for internal
consistency and specification bugs. Line numbers refer to the version tagged in
this repo (e.g. `git show v1.14:docs/PRD-MACrossEA.md`).

Note: **document revision 1.10 was not supplied.** Its content is described in the
version-history tables of 1.11 onward, and commit `v1.11` therefore carries both
revisions. This matters for one finding below (#1).

---

## A. Specification bugs — these would produce wrong behaviour if implemented as written

### A1. `HTF_ConfirmationCandles ≥ 1` is never actually specified as a validation

**Affects: 1.11, 1.12, 1.13, 1.14 (all revisions that have the input).**

The 1.10 version-history entry states: *"Added the corresponding OnInit() validation
(HTF_ConfirmationCandles ≥ 1)."* That string appears **only in the version-history
table** — never in Section 5's `Parameter validation at OnInit()` list, in any
revision. Section 9's own normative rule says *"only the active requirements in
Sections 1–8 above are binding. This table is informational/historical only."*
By the document's own rule, the validation does not exist.

Consequence: `HTF_ConfirmationCandles = 0` (or negative) passes OnInit, and the
candle-colour loop in Module B runs zero iterations — vacuously true. Module B
silently degrades to its pre-1.10 single-confirmation form while still reporting
two confirmations. That is the exact failure mode the 1.10 revision existed to
prevent, reachable from the input dialog.

**Fix:** add to Section 5, beside `HTF_MA_Period > 0, HTF_TrendConfirm_Bars ≥ 2`:
`HTF_ConfirmationCandles ≥ 1`.

### A2. HTF `RequiredBars` omits `HTF_ConfirmationCandles`

**Affects: all five revisions.**

Section 5's data-readiness rule ends: *"for the LTF, and the equivalent for HTF
(HTF_MA_Period, HTF_TrendConfirm_Bars)."* The candle-colour window is not a term.

This is the **exact bug v1.14 fixed for the LTF and left standing on the HTF side.**
v1.14 (line 653) adds `LTF_ConfirmationCandles` to the LTF `max()` with the
reasoning *"it was reachable through the safety margin at its default of 3 but was
never a listed term, which would have failed silently at larger values."* The HTF
twin has identical exposure: masked at the defaults (3 candles vs. 5 MA bars), and
silently insufficient once `HTF_ConfirmationCandles > HTF_TrendConfirm_Bars`.

**Fix:** add `HTF_ConfirmationCandles` to the HTF term. Note the depth needed is
`HTF_ConfirmationCandles` exactly, **not** `+1` — the window starts at HTF shift 0,
so N candles span shifts 0..N−1 (this is the one place the shift-0 exception
changes an arithmetic requirement, and it is worth stating inline).

### A3. `LTF_ConfirmationCandles ≥ 1` missing from Section 5 in 1.12 and 1.13

Same pattern as A1: the 1.12 history entry claims *"Added the corresponding OnInit()
validation (`InpLTFTrendConfirmBars ≥ 2`, `InpLTFConfirmationCandles ≥ 1`)"*, but
Section 5 in both 1.12 and 1.13 lists neither. `TrendConfirm_Bars ≥ 2` is covered
under the pre-rename name; `LTF_ConfirmationCandles` is not covered at all.

**Fixed in 1.14** (line 660). Recorded here because it is the same class of defect
as A1/A2 — a history entry treated as if it were normative text — and because it
means a build made from 1.12 or 1.13 has the gap.

### A4. v1.14 §1 built-vs-specified table contradicts itself, in its normative column

v1.14 introduces the Status column and declares it normative: *"the 'Status' column
is normative, and only rows marked **Built** may be assumed present by an
implementer."* The table then reads:

| Check | Status |
|---|---|
| Momentum/oscillator filter (`Momentum_Filter = NONE`) | **Built** — the enum's NONE member serves as the toggle |
| ATR volatility filter | Specified, **unbuilt** (Module C is unbuilt) |

`Momentum_Filter` is a Module C input. If Module C is unbuilt — as the ATR row, the
document header (*"Module C remain[s] unbuilt, as in 1.3"*) and Module A's v1.4
staged-rebuild note all state — then `Momentum_Filter` is not built either. This is
the only place the newly-normative column is wrong, which makes it worth fixing
before anyone relies on the column.

**Fix:** mark the row `Specified, **unbuilt** (Module C is unbuilt)`, or split it
into "the enum is the intended toggle mechanism / not yet present."

### A5. v1.14 carries a stale "must be refactored" instruction for `ReversalDetector.mqh`

Module E, *Single canonical implementation* (line 437):

> `ReversalDetector.mqh` (carried over from the 1.2 folder) currently uses strict
> comparison on **both** sides, which is a **behavioral** divergence … it must be
> refactored onto the shared predicate **as part of this revision**.

1.13's history entry records that refactor as completed work in 1.13
(*"`ReversalDetector.mqh` refactored onto the shared predicate"*). Carried verbatim
into 1.14, the paragraph either describes work already done as still outstanding,
or implies the 1.4 fork reintroduced the divergence. Both readings are wrong, and
the second one would send someone hunting a regression that isn't there.

**Fix:** past-tense it, and keep only the forward-looking requirement (no second
implementation may exist; both callers share the fixtures).

---

## B. Cross-reference errors

| # | Issue | Affects |
|---|---|---|
| B1 | Module B's `HTF_Timeframe` row says *"see Section 7 validation rules"* — validation rules are in **Section 5**; Section 7 is Assumptions Requiring Confirmation | all five |
| B2 | Status line says *"see Section 9 (Open Questions)"* — Section 9 is **Version History**; open questions are Section 7 | 1.9, 1.11, 1.12 (fixed in 1.13) |
| B3 | Module A's `TrendConfirm_Bars` row says *"see note under input 6"* — the input table is not numbered and has no "input 6" | all five |

---

## C. Numeric inconsistencies in v1.14's evidence block

The 1.14 redesign is argued from backtest figures, and the figures do not agree
with each other across the document:

- **Total bars evaluated:** `189,141` (line 163, the monotonicity field observation)
  vs. `189,145` (line 212 twice, line 686). The percentages quoted in both places
  are derived from these totals, so they should be pinned to one number.
- **Cross count:** `3,908` (lines 33, 163, 169) vs. `3,909` (line 212).
  `185,236 + 3,909 = 189,145` is internally consistent with line 212's own
  arithmetic, which suggests 3,909/189,145 is the correct pair and the other
  figures are off by one.
- **Module A funnel:** line 33 says 3,549 of 3,908 crosses survived monotonicity;
  line 169 says step 2 rejected "~360", leaving the candle check to reject ~1,795
  and leave 1,754. `3,908 − 360 = 3,548`, not 3,549. The `~` makes this a rounding
  artefact rather than an error, but with the totals already disagreeing it is
  worth stating the exact funnel once and deriving everything else from it.

None of these change a conclusion. They matter because Section 1 explicitly asks the
reader to tune against these numbers ("Tune `TrendConfirm_Bars` against that figure").

---

## D. Design issues worth an explicit decision

### D1. The cooldown can suppress a NETTING reversal's *close* leg, contradicting its own scope rule

v1.14's Module D states as a scope decision: *"**Applies to entries only.** The
cooldown never delays, suppresses, or modifies an *exit*."*

But the reversal is reached only through Stage 2: the canonical pseudocode checks
`cooldownElapsed` and returns before `ModuleD.Execute()`, and `Execute()` is where
the close-then-open sequence lives. An active cooldown therefore suppresses the
whole reversal — including the close of the existing position.

In normal operation this is unreachable: a position can only have been opened on a
bar where the cooldown had already elapsed, and `BarsSince` only grows. It becomes
reachable for an **adopted** position — one opened before the EA started, or by a
prior run — where `LastCloseBarTime` is reconstructed from trade history at
`OnInit()` and may be recent relative to the adopted position.

Narrow, but it is a case where the EA holds a position it has decided to reverse
because a *frequency limiter* said no. Either document the exception, or move the
cooldown check inside `Execute()`'s new-entry branch so the reversal path bypasses
it the way its reopen leg already does.

### D2. Trailing-stop arithmetic mixes prices and point counts

Present in all five revisions, unchanged:

> **BUY:** candidate SL = current Bid − Trailing_Distance_Points … and
> `candidate_SL − existing_SL ≥ Trailing_Step_Points`

Both subtract or compare a point *count* against a *price*. As shorthand this is
clear enough, but the document is otherwise scrupulous about units — it defines
`PipSize` explicitly and scopes it to FX — and this is the single most common
real-world MQL5 defect. Writing `× _Point` (or `× SYMBOL_POINT`) in these two
formulas costs nothing and removes the ambiguity.

### D3. `D_COOLDOWN_HISTORY_UNAVAILABLE` will essentially never fire as specified

v1.14's restart rule: reconstruct `LastCloseBarTime` via `iBarShift(..., exact = false)`,
and *"if history is unavailable or the lookup fails, treat the cooldown as inactive …
Log `D_COOLDOWN_HISTORY_UNAVAILABLE` once."*

With `exact = false`, MT5's `iBarShift` returns the nearest bar rather than −1, so
the "lookup fails" branch is close to unreachable. The realistic failure is a
history-depth shortfall, which returns the oldest available bar and yields a very
large `BarsSince` — which also fails open, so the *behaviour* is right. But the
diagnostic that was added to make this path visible won't print.

**Fix:** trigger the log on the condition that actually occurs — the history select
returning no matching deal, or the resolved bar being older than the available
history — rather than on an `iBarShift` return value.

### D4. `Enable_LTF_CandleColor_Check` is declared twice in v1.14

Once as a row in Module A's main input table (line 133) and again in the debug-toggle
table (line 145), each with its own description and default. They currently agree.
Two declarations of one input with two independently maintained defaults is how they
stop agreeing.

---

## E. Formatting / rendering

- **Orphaned sentence in v1.14 §5.** The inserted *"v1.14 note on Module A's
  contribution"* paragraph sits between the `RequiredBars` code block and the
  sentence that completes it (*"for the LTF, and the equivalent for HTF …"*,
  line 654). The completing clause now reads as a continuation of the note.
  Move it back above the note.
- **Unbalanced bold/parenthesis constructs** of the form `**(v1.14 amendment:** …
  **)**` at v1.14 lines 239, 399, 630, 633 render with stray asterisks in most
  Markdown renderers. Use `*(v1.14 amendment: … )*` or a separate blockquote.

---

## F. Things the revision sequence got right (no action)

Recorded so a later pass doesn't "fix" them back:

- **The §1-toggle-table vs. Module-A-staged-note contradiction** (Section 1 listing
  `Enable_*` toggles that Module A simultaneously declared nonexistent in code)
  was real in 1.12 and 1.13, and 1.14 resolves it correctly with the normative
  Status column — modulo A4 above.
- **1.13's "No post-exit cooldown" exclusion** is properly reversed in 1.14 *on
  argument* rather than quietly dropped, with the reasoning ("its entire load was
  carried by the crossover being edge-triggered") stated. That is the right way to
  retire a documented decision.
- **The v1.8 "strict monotonicity is considerably more selective" claim** is
  correctly identified as wrong-in-context by 1.14 and re-measured (~9% at cross
  bars, ~63% under the state form), rather than silently deleted.
- **The as-tested configuration block** in 1.14 resolves the standing ambiguity
  about which field observations were measured on which parameters. The EMA 10/30
  angle-check observation is correctly flagged as historical.
- **`SLOT_FREE_BARS` as the cooldown denominator** is the right call; the
  `TRADEABLE_BARS` denominator really was uninterpretable with multi-hour holds.
