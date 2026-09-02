# Reference implementation

The independent second implementation the PRD's determinism objective requires, and the
one roadmap **Stage 0** names explicitly in its Definition of Done — *"ATR/ROC/ER values
computed by the EA match independently-calculated reference values (e.g. from
Python/Excel on the same historical data)"*.

Pure Python, no third-party runtime dependencies. Only `pytest` is needed, and only to
run the tests.

## Running the tests

```bash
cd reference
python3 -m pip install pytest      # once
python3 -m pytest -q               # pytest.ini sets the path
```

## What is here

| Module | PRD | Roadmap stage |
|---|---|---|
| `htfltf/bars.py` | §10.4 price series | 0 |
| `htfltf/indicators.py` | §37 ATR, §12.4 ROC, §12.1 `Directional_ROC`, §7.1 ER, §16.4 shadows | 0 |
| `htfltf/params.py` | §32 parameter set, §38 validation, §26 parameter hash | 0 |
| `htfltf/barguard.py` | §36.1 bar-processed-once guard | 0 |
| `htfltf/funnel.py` | Signal Funnel Counter | 0 (used from 4) |
| `htfltf/swings.py` | §4.1 swings + tie-breaking, §4.2 confirmed structure | 1 |

Stages 2–13 are not implemented. The roadmap's rule is that no stage begins until the
previous one has passed its Definition of Done, and Stage 1's DoD includes a visual check
against a real historical chart that this environment cannot perform.

## Test suites

| File | Covers |
|---|---|
| `tests/test_indicators.py` | Stage 0 DoD; §39 tests #13 (short-side momentum) and #15 (ER flat window) |
| `tests/test_swings.py` | Stage 1 DoD; §39 test #1 (equal highs/lows) |
| `tests/test_params.py` | §39 test #12 (every §38 case rejected, with its parameter named) |
| `tests/test_funnel.py` | Funnel attribution and §36.1 guard |
| `tests/test_mql5_parity.py` | MQL5 ↔ Python agreement (see below) |

ATR and ER expectations are hand-computed from the §37 / §7.1 formulas rather than
captured from this implementation's own output — a self-captured golden value would pass
just as happily against a wrong formula.

## The parity suite

`tests/test_mql5_parity.py` transcribes the loop structure of
`mql5/Include/HTFLTF/Indicators.mqh` verbatim — **series indexing included**, where index
0 is the newest bar — and diffs it against the reference over 200 randomized series per
function plus the hand-computed cases and the insufficient-data boundaries.

That indexing difference is where an off-by-one hides. An ATR recursion that runs backwards
through time, or an ER window shifted by one bar, produces plausible numbers that are wrong
everywhere downstream, and neither implementation looks wrong on its own.

**Keep the ports in step with the `.mqh` file.** A parity test that has silently drifted
from the code it mirrors is worse than none.

## What is deliberately absent

Position sizing (§15) is not here, despite being one of the review's blocking findings
(B-2). It belongs to Stage 8, and the roadmap's own rule — no stage begins until the
previous has passed its DoD — applies to the people writing it too. The corrected formula
and its regression test (§39 test #14) are specified in `docs/prd.md` §15 and land with
Stage 8.
