# Suggested fixes — MACrossEA v1.4 code and PRD v1.14

Companion to `PRD-review-notes.md`. Each entry gives the defect, the fix, and why
that fix rather than an alternative. Code line numbers refer to the v1.4 sources
as supplied; PRD line numbers to `git show v1.14:docs/PRD-MACrossEA.md`.

Ordered by risk. C-items are code, D-items are documentation.

---

## C1 — `ClampLevel` measures the stops level from the wrong side (PositionCore.mqh:160)

MT5 evaluates an open position's SL and TP against the price that would *close*
it: **Bid for a BUY, Ask for a SELL**. `ClampLevel` uses the entry side, so it
under-measures the required distance by one spread and can approve a stop the
server rejects with `TRADE_RETCODE_INVALID_STOPS`.

```diff
   double ClampLevel(bool isBuy, double proposedLevel, bool isTP)
   {
+     m_symbolInfo.RefreshRates();
      double point      = m_symbolInfo.Point();
      int    stopsLevel = (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minDist    = stopsLevel * point;
-     double refPrice   = isBuy ? m_symbolInfo.Ask() : m_symbolInfo.Bid();
+     //--- The server checks an open position's SL/TP against the price that would
+     //--- CLOSE it — Bid for a BUY, Ask for a SELL — not against the entry side.
+     //--- Using the entry side under-measures the distance by one spread, which
+     //--- passes here and is then rejected by the broker. UpdateTrailing() and
+     //--- CanModifyNow() already use these sides; this function was the outlier.
+     double refPrice   = isBuy ? m_symbolInfo.Bid() : m_symbolInfo.Ask();
```

**Why this and not a safety pad.** Adding slack to `minDist` would mask the sign
error while making every stop wider than requested. The two other clamping sites
in the same class (`UpdateTrailing:334`, `CanModifyNow:77`) already use the
correct sides — this change makes the class internally consistent rather than
introducing a new convention.

**Test:** set a symbol with a nonzero `SYMBOL_TRADE_STOPS_LEVEL` and a spread
wider than it, request an SL exactly at the boundary, and assert the submitted
level is at least `stopsLevel` from Bid (BUY) / Ask (SELL).

---

## C2 — SL/TP clamped against a stale tick, and the journal may not match what was sent

Three price snapshots exist in one order path: `entryPriceRef` is a live
`SymbolInfoDouble` read (`MACrossEA.mq5:332`), `ClampLevel` uses whatever
`m_symbolInfo` last cached, and the send refreshes rates first
(`PositionCore.mqh:241`). On a requote retry the loop re-prices the order but
reuses SL/TP clamped against the *original* tick.

Clamp inside the retry loop, and report back what was actually submitted:

```diff
-  bool OpenPosition(bool isBuy, double lots, double slRaw, double tpRaw, string comment, uint &retcodeOut)
+  bool OpenPosition(bool isBuy, double lots, double slRaw, double tpRaw, string comment,
+                    uint &retcodeOut, double &slUsedOut, double &tpUsedOut)
   {
      retcodeOut = 0;
-     double sl = (slRaw > 0.0) ? ClampLevel(isBuy, slRaw, false) : 0.0;
-     double tp = (tpRaw > 0.0) ? ClampLevel(isBuy, tpRaw, true) : 0.0;
+     double sl = 0.0, tp = 0.0;
      double normalizedLots = NormalizeLots(lots);
      if(normalizedLots <= 0.0)
         return false;

      bool ok = false;
      for(int attempt = 1; attempt <= m_maxRetries; attempt++)
      {
         m_symbolInfo.RefreshRates();
         double price = isBuy ? m_symbolInfo.Ask() : m_symbolInfo.Bid();
+        //--- Re-clamp per attempt, against the same tick the order is priced on.
+        //--- A requote retry that reuses the previous tick's levels can submit a
+        //--- stop the server has since started rejecting.
+        sl = (slRaw > 0.0) ? ClampLevel(isBuy, slRaw, false) : 0.0;
+        tp = (tpRaw > 0.0) ? ClampLevel(isBuy, tpRaw, true)  : 0.0;
...
+     slUsedOut = sl;
+     tpUsedOut = tp;
      return ok;
   }
```

Caller (`MACrossEA.mq5:361-369`) then logs the real levels instead of its own
pre-computed copy:

```diff
+  double slUsed = 0.0, tpUsed = 0.0;
-  bool ok = g_position.OpenPosition(isBuy, InpLotSize, slRaw, tpRaw, comment, retcode);
+  bool ok = g_position.OpenPosition(isBuy, InpLotSize, slRaw, tpRaw, comment, retcode, slUsed, tpUsed);
...
-  g_journal.LogFilled(e, _Symbol, InpLTFTimeframe, (ulong)InpMagicNumber, direction, entryPriceRef, slClamped, tpClamped);
+  g_journal.LogFilled(e, _Symbol, InpLTFTimeframe, (ulong)InpMagicNumber, direction, entryPriceRef, slUsed, tpUsed);
```

The caller's own `slClamped`/`tpClamped` stay — they are what `CTradeValidator`
sanity-checks pre-fill — but they are no longer treated as a record of what was
sent. Today the two agree only because nothing refreshes rates between them,
which is an accident of call ordering, not a guarantee.

**Note this is not the PRD's post-fill sequencing** (D7). It makes the pre-fill
path self-consistent; re-deriving SL/TP from `POSITION_PRICE_OPEN` after the fill
remains unbuilt.

---

## C3 — Journal rows are stamped with `TimeCurrent()`

`Journal.mqh:80, 101, 129`. Signal rows describe shift 1 but carry the forming
bar's time, so every row is one bar off from the bar it reports. Trade rows are
worse: v1.14 added `ClosedTradeInfo.CloseTime` specifically because
`TimeCurrent()` "can land in a later bar if the detecting tick arrives after the
bar boundary" — the cooldown honours that (`MACrossEA.mq5:920`) and the CSV
discards it.

```diff
   void LogRejection(const SignalEvaluation &e, string symbol, ENUM_TIMEFRAMES period, ulong magic,
-                    string direction, ENUM_REJECT_REASON reason)
+                    string direction, ENUM_REJECT_REASON reason, datetime signalBarTime)
...
      FileWrite(m_signalFile,
-               TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), symbol, ...
+               TimeToString(signalBarTime > 0 ? signalBarTime : TimeCurrent(), TIME_DATE | TIME_SECONDS), symbol, ...
```

Same parameter on `LogFilled`. For trades:

```diff
-  void LogTradeClose(ulong ticket, string symbol, double exitPrice, string exitReason, double profit)
+  void LogTradeClose(ulong ticket, string symbol, datetime closeTime,
+                     double exitPrice, string exitReason, double profit)
...
-     FileWrite(m_tradeFile, (long)ticket, symbol, TimeToString(TimeCurrent(), ...
+     FileWrite(m_tradeFile, (long)ticket, symbol,
+               TimeToString(closeTime > 0 ? closeTime : TimeCurrent(), TIME_DATE | TIME_SECONDS), ...
```

Callers pass `iTime(_Symbol, ltf, 1)` for signal rows (already computed as
`barTime` at `MACrossEA.mq5:945`) and `closedInfo.CloseTime` for trade rows.

**Why the `> 0 ? : TimeCurrent()` fallback:** `DEAL_TIME` can come back as 0 if
the history read failed, and a wrong-but-plausible timestamp beats an epoch date
sorting to the top of the CSV.

---

## C4 — `SIGNAL_ONLY` fires a modal `Alert()` on every tradeable bar

`MACrossEA.mq5:481`. Under a level-triggered Stage 1 this is one popup per bar
across an entire run. The PRD's log-volume caveat anticipates extra log *lines*
and says to "throttle at the journal layer, never by reintroducing edge-detection
in Module A" — which is right, and this fix obeys it: the throttle lives in the
reporting branch of Module D, sees only Stage 1's already-computed verdict, and
changes no counter, no journal row, and nothing Module A does.

`g_prevStage1Dir` already holds exactly the needed state, but `TrackEpisode()`
overwrites it earlier in the function, so capture it first:

```diff
   void AttemptFire(const SignalEvaluation &e, ENUM_TIMEFRAMES ltf)
   {
      g_cntBarsEvaluated++;
      ...
+     //--- Captured BEFORE TrackEpisode overwrites it: used only to decide whether
+     //--- this bar begins a new episode, for alert throttling. Not signal
+     //--- de-duplication — every bar is still counted and journalled.
+     int prevStage1Dir = g_prevStage1Dir;
      TrackEpisode(e.Fired ? e.Direction : 0);
...
      if(InpExecutionMode == EXEC_SIGNAL_ONLY)
      {
         ...
         Print(msg);
-        Alert(msg);
+        //--- Alert only on the first bar of an episode. Print still fires every
+        //--- bar, so the log remains a complete record; the popup marks the
+        //--- transition, which is the only part a human can act on.
+        if(e.Direction != prevStage1Dir)
+           Alert(msg);
         return;
      }
```

Optionally add an `InpAlertMode` input (`ALERT_EVERY_BAR` / `ALERT_EPISODE_START`
/ `ALERT_NONE`) if per-bar popups are ever wanted back. Episode-start is the
right default.

---

## C5 — Data-readiness gate omits Module E's history requirement

`MACrossEA.mq5:931` implements neither the Module E terms nor the `+5` safety
margin Section 5 specifies. Module E self-reports `E_DATA_NOT_READY` so nothing
misbehaves, but the "one centralized figure" the PRD requires does not exist.

```diff
   int ltfBarsNeeded = MathMax(InpSlowMAPeriod + 2, MathMax(InpLTFTrendConfirmBars, InpLTFConfirmationCandles));
+  //--- prd.md Section 5 "Module E terms". This is a FLOOR, not the whole
+  //--- requirement: Module E measures depth from the ENTRY bar, which can be far
+  //--- older than ScanBars, so CExitEngine::DataReady still does its own
+  //--- entry-relative check. This term only stops signal evaluation starting
+  //--- before Module E could ever initialize an anchor.
+  if(InpEnableStructuralExit)
+     ltfBarsNeeded = MathMax(ltfBarsNeeded, InpExitScanBars + InpExitPivotStrength + 2);
+  ltfBarsNeeded += 5;   // safety margin, prd.md Section 5
   int htfBarsNeeded = MathMax(InpHTFMAPeriod + InpHTFTrendConfirmBars, InpHTFConfirmationCandles);
+  htfBarsNeeded += 5;
```

---

## C6 — Comments that contradict the code they annotate

None of these change behaviour, and all of them have already misled one review:
the PRD's stale `ReversalDetector` claim (D4) survived because the comment in
that file still asserts the divergence the code removed.

| File:line | Says | Should say |
|---|---|---|
| `ReversalDetector.mqh:172-174` | pivot needs "strictly lower highs … on **BOTH** sides" | strict on the newer side, non-strict on the older — and point at `SwingStructure.mqh` as the definition, since this function now only delegates |
| `Types.mqh:4` | "Primary trade condition: Module A step 1 crossover" | trend state; the file defines `REJECT_NO_TREND_STATE` two screens down |
| `Indicators.mqh:3` | "v1.2 mirrored confirmation" | v1.4 |
| `Indicators.mqh:166` | "must all share the crossover's direction" | the state's direction |
| `Journal.mqh:65` | `direction` is "-" (no cross at all) | no trend state (exact MA equality) |
| `SignalEngine.mqh:166` | "a position can be open while Module A sees no cross" | while Module A produces no signal |

---

## C7 — Duplicated depth formula, and one unreachable branch

`CExitEngine::RequiredDepth()` (`ExitEngine.mqh:227`) is never called;
`DataReady:82` inlines the same expression. Two copies that must agree is one
copy too many:

```diff
      if(!st.AnchorActive)
      {
         int entryShift = src.ShiftOf(st.EntryBarTime);
         if(entryShift < 0)
            return false;
-        return src.IsReady(entryShift + m_scanBars + m_pivotStrength + 2);
+        return src.IsReady(RequiredDepth(entryShift));
      }
```

`Ratchet:183`'s `if(cShift < 1) continue;` is unreachable — the loop bound
`p >= m_pivotStrength + 1` already guarantees `cShift >= 1`. Harmless; either
delete it or re-label it as an invariant assertion rather than a filter, so a
reader does not infer that unconfirmed pivots can reach that point.

---

## D1 — Add the missing `HTF_ConfirmationCandles` validation to Section 5

The rule exists only in the 1.10 version-history row, and Section 9 declares
itself non-binding. Code implements it correctly (`MACrossEA.mq5:704`); the spec
does not contain it. Add beside the existing HTF line:

```diff
   - HTF_MA_Period > 0, HTF_TrendConfirm_Bars ≥ 2
+  - HTF_ConfirmationCandles ≥ 1 (unconditional — Module B is not toggleable).
+    Zero or negative makes the candle-colour loop vacuously true, which silently
+    reduces Module B to the single-confirmation form v1.10 replaced.
```

## D2 — Add `HTF_ConfirmationCandles` to the HTF required-bars term

v1.14 fixed exactly this on the LTF side and left the HTF twin. Code is already
right (`MACrossEA.mq5:932`); only the spec is wrong.

```diff
-  for the LTF, and the equivalent for HTF (HTF_MA_Period, HTF_TrendConfirm_Bars).
+  for the LTF, and for the HTF:
+    HTFRequiredBars = max(HTF_MA_Period + HTF_TrendConfirm_Bars, HTF_ConfirmationCandles) + safety margin
+  HTF_ConfirmationCandles enters as N, **not** N+1: its window starts at HTF
+  shift 0, so N candles span shifts 0..N−1. This is the only place the shift-0
+  exception changes an arithmetic requirement.
```

While editing this bullet, move the orphaned clause "for the LTF, and the
equivalent for HTF…" back above the inserted v1.14 note (line 654) — it currently
reads as a continuation of the note rather than of the formula.

## D3 — Correct the Built/Unbuilt table's `Momentum_Filter` row

The Status column is declared normative and this is its one wrong cell.

```diff
-  | Momentum/oscillator filter | `Momentum_Filter = NONE` | … | **Built** — the enum's NONE member serves as the toggle |
+  | Momentum/oscillator filter | `Momentum_Filter = NONE` | … | Specified, **unbuilt** (Module C is unbuilt). The enum's NONE member is the intended toggle mechanism once it exists; no such input is present in v1.4. |
```

## D4 — Past-tense the `ReversalDetector` refactor

The refactor completed in 1.13. Keep the forward-looking requirement, drop the
instruction:

```diff
-  `ReversalDetector.mqh` (carried over from the 1.2 folder) currently uses strict
-  comparison on **both** sides, which is a **behavioral** divergence from the
-  definition above … it must be refactored onto the shared predicate as part of
-  this revision.
+  `ReversalDetector.mqh` previously used strict comparison on **both** sides — a
+  **behavioral** divergence, not a documentation one, silently dropping every
+  pivot where two bars shared a low. It was refactored onto the shared predicate
+  in 1.13 and calls `CollectSwings` today. The standing requirement is that no
+  second implementation of the pivot rule may be introduced anywhere.
```

## D5 — Fix the cross-references

- Module B's `HTF_Timeframe` row: "see Section 7 validation rules" → **Section 5**
  (all five revisions).
- Module A's `TrendConfirm_Bars` row: delete "see note under input 6" — the input
  table is unnumbered. Replace with "see the `Regression_Bars` row below."

## D6 — Pin the backtest figures to one set

Line 212's arithmetic is internally consistent (`185,236 + 3,909 = 189,145`), so
adopt **3,909 crosses / 189,145 bars** and restate the funnel once, deriving the
percentages from it:

```
189,145 bars → 3,909 crosses → 3,549 survive step 2 (−360) → 1,754 survive step 3 (−1,795)
```

Then correct line 163's `189,141` and lines 33/163/169's `3,908`. If 3,908 is the
true count, the totals in line 212 need the opposite correction — either way, one
number, stated once.

## D7 — Mark Module D's unbuilt parts in the Status table

The Built/Unbuilt table covers Modules A and C only, so three Module D
requirements read as normative-and-present while being entirely unimplemented:

| Item | Reality in v1.4 |
|---|---|
| `Account_Mode`, `Block_On_ForeignNettingExposure`, `Netting_ReverseOnOppositeSignal`, the reversal sequence, FAIL_FLAT | Unbuilt — `OnInit:660` rejects any non-hedging account outright |
| `Max_Open_Positions` | Unbuilt — `!g_position.IsOpen()` caps at one position **total**, not one per direction |
| Post-fill SL/TP re-derivation from `POSITION_PRICE_OPEN` | Unbuilt — computed from the decision price (`MACrossEA.mq5:328` says so) |

Worth stating explicitly that the hedging requirement currently buys nothing
behaviourally: the PRD's rationale for hedging is a simultaneous long and short,
which the one-position cap forbids. The real driver is `CPositionCore`'s
single-position tracking.

## D8 — `Magic_Number > 0`, not `≥ 0`

Code rejects zero (`MACrossEA.mq5:740`) and the code is right — magic 0 is how
the terminal marks manual trades, so an EA claiming it cannot distinguish its own
positions from a human's. Change the spec, not the code:

```diff
-  - Magic_Number ≥ 0
+  - Magic_Number > 0. Zero is the terminal's marker for manually-opened
+    positions; an EA using it cannot tell its own exposure from a human's, which
+    breaks every Symbol+Magic ownership check in this document.
```

## D9 — Document the cooldown's two-step bar resolution

The spec describes a single `iBarShift(exact = false)`. The implementation is
better and should be what is written down: `ArmCooldown` resolves the deal time
to its *containing* bar with `exact = false` and stores that bar's open time;
`CooldownElapsed` then looks that stored time up with `exact = true`, so a trimmed
or revised history surfaces as a real failure rather than silently relocating onto
a neighbouring bar. That is what makes `D_COOLDOWN_HISTORY_UNAVAILABLE` reachable
at all.

## D10 — Add the Module E row to the cooldown counting table

The normative table assumes the close lands in bar `N`, which holds for SL/TP
(intrabar) but not for Module E: it decides on bar `N` and executes on the first
tick after `N` closes, i.e. inside `N+1`. The code documents and defends this
(`MACrossEA.mq5:209-219`); the PRD does not mention it, and Module E is the exit
the cooldown was built to follow.

```
| Close type          | Close attributed to | BarsSince == 0 at |
|---------------------|---------------------|-------------------|
| SL / TP / trailing  | bar N (intrabar)    | signal bar N      |
| Module E structural | bar N+1 (first tick after N closed) | signal bar N+1 |
```

Effective cooldown after a structural exit is therefore one bar longer than after
an SL/TP hit. That is correct — both obey "the bar during which the position
closed" — but it must be stated, and test 6c should assert it.

## D11 — Resolve the cooldown-vs-reversal scope contradiction

Module D states the cooldown "never delays, suppresses, or modifies an exit", but
the reversal is reached only through Stage 2, so an active cooldown suppresses the
close leg too. Moot in v1.4 (netting is rejected), live the moment netting lands.
Pick one:

- **Preferred:** move the cooldown check into the new-entry branch of
  `Execute()`, so the reversal path bypasses it exactly as its reopen leg already
  does. Keeps the stated scope rule true.
- Or amend the scope rule to "never delays an exit **except** a reversal's close
  leg, which inherits the entry gate" — accurate, but it makes a frequency
  limiter able to hold a position the strategy wants out of.

## D12 — Editorial

- Remove the duplicate `Enable_LTF_CandleColor_Check` declaration: keep the
  debug-toggle table row, drop the Module A input-table row (or vice versa), so
  one default is maintained in one place.
- Replace `**(v1.14 amendment:** … **)**` at lines 239, 399, 630, 633 with
  `*(v1.14 amendment: … )*` — the current form renders stray asterisks.
- Tighten the trailing-stop formulas to show the unit conversion
  (`Bid − Trailing_Distance_Points × Point`), matching what the code does. The
  shorthand is the classic MQL5 defect and the document is explicit about units
  everywhere else.

---

## Suggested order of work

1. **C1** — the only defect that can cause a live order rejection. One line.
2. **C3, C4** — both affect whether a run's output can be trusted or tolerated;
   neither touches trading logic.
3. **D1, D2, D3, D4** — the spec defects that would propagate into any
   reimplementation or mislead the next review.
4. **C2, C5** — correctness hardening with no behavioural change at default
   settings.
5. **D5–D12, C6, C7** — accuracy and hygiene.

C1 and C3 are worth a regression test each; the rest are covered by reading.
