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
| Indicator voters (M2) | complete, tested |
| Pattern detectors (M3) | complete, tested |
| Live order placement | stubbed (M7) |

M1–M3 are in. A tester pass now detects patterns, votes, stages signals across the two phases, fans them out to the 384 cells and writes all three CSVs. What has *not* happened is a run against real bars — the numbers below are from synthetic candles, not a market.

## Tests

```
./tests/run.sh
```

Compiles the *shipped* headers against `tests/mql5_shim.h` — a small stand-in for the MQL5 runtime — so the tests cover real code rather than a transcription. 1694 checks over the cell algebra, subset admission, all twelve detectors, the prior-trend gate, all four voters, overlap ratio, ranking key, eligibility floors, the Wilson bound, trade construction and config validation.

Several tests are regression guards for defects found during design review, and are written to fail loudly if the old behaviour returns:

- `CellId` must never reach 415 (raw-enum indexing overflowing the 384-slot array).
- The ranking key must not invert for losing cells — the rejected `wilson_lb × expectancy_r` form is computed alongside the shipped one to document the inversion.
- `overlap_ratio` must sum realised `bars_held`, not `hold_bars` caps, and must not collapse toward 1.0 when a busy period is followed by a long idle stretch.

**These tests do not substitute for a MetaEditor compile.** Anything touching indicator handles, `MqlRates` or file I/O is only verifiable in the terminal.

## Next

M4–M6 are verified only against synthetic data. The open work is a real tester pass: confirm detection counts look sane on a chart (M3's acceptance is visual inspection, which no unit test substitutes for), then check that `overlap_ratio` and the timeout rates behave on real trade distributions.

`Trade/LiveExecutor.mqh` is the one remaining stub (M7).
