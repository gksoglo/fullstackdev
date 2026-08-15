# ReversalLab — MQL5 source

M1 skeleton for the research harness specified in [`../prd.md`](../prd.md).

## Install

Copy into your terminal's data folder (MetaEditor → File → Open Data Folder), preserving the layout:

```
<terminal data folder>/MQL5/Experts/ReversalLab/ReversalLab.mq5
<terminal data folder>/MQL5/Include/ReversalLab/**
```

Compile `ReversalLab.mq5` in MetaEditor, then run it in the Strategy Tester on a single symbol.

## What works at M1

| Area | State |
| --- | --- |
| EA lifecycle, config load and validation | complete |
| Cell algebra (`CellId`, 384 cells) | complete, tested |
| Two-phase staging (detect at `t`, instantiate at `t+1` open) | complete |
| Trade construction: stop, risk, target, gap check, risk bounds | complete, tested |
| Risk-scaled hold window | complete, tested |
| Virtual book: fan-out, marching, pessimistic tie-break, truncation | complete |
| Overlap tracking and the confidence arithmetic | complete, tested |
| CSV logs and the ranking report | complete |
| **Pattern detectors** | **stubbed — every one returns `DIR_NONE` (M3)** |
| **Indicator voters** | **stubbed — every one returns `0` / `VR_NONE` (M2)** |
| Live order placement | stubbed (M7) |

Because the detectors and voters are stubs, a tester pass initialises cleanly, writes headers, and produces no trades. That is the intended M1 outcome: it exercises the lifecycle without asserting anything about markets.

## Tests

```
./tests/run.sh
```

Compiles the *shipped* headers against `tests/mql5_shim.h` — a small stand-in for the MQL5 runtime — so the tests cover real code rather than a transcription. 1619 checks over the cell algebra, subset admission, overlap ratio, ranking key, eligibility floors, the Wilson bound, trade construction and config validation.

Several tests are regression guards for defects found during design review, and are written to fail loudly if the old behaviour returns:

- `CellId` must never reach 415 (raw-enum indexing overflowing the 384-slot array).
- The ranking key must not invert for losing cells — the rejected `wilson_lb × expectancy_r` form is computed alongside the shipped one to document the inversion.
- `overlap_ratio` must sum realised `bars_held`, not `hold_bars` caps, and must not collapse toward 1.0 when a busy period is followed by a long idle stretch.

**These tests do not substitute for a MetaEditor compile.** Anything touching indicator handles, `MqlRates` or file I/O is only verifiable in the terminal.

## Next

M2 (`Indicators/Voters.mqh`) and M3 (`Patterns/Detectors.mqh`) are the two stub files. Each carries its contract in a header comment — in particular, detectors must not apply size gates, which belong to the toggled ATR filter, and voters take a 3-bar window because every rule is a two-bar cross rule.
