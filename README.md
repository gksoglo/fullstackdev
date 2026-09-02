# HTF/LTF Trend-Continuation EA

A deterministic MetaTrader 5 / MQL5 expert advisor built from an explicit specification:
HTF market structure sets direction, regime detection sets tradeability, an LTF Break of
Structure triggers entry, and risk is structural.

The governing constraint, from the PRD itself:

> Two independent implementations of this specification, given the same market data and
> parameters, must produce the same structural interpretation and the same trades.

That is why this repository carries the spec, the EA, and a second implementation used to
check the first.

## Documents

| Document | What it is |
|---|---|
| [`docs/prd.md`](docs/prd.md) | The specification, **v0.7** |
| [`docs/roadmap.md`](docs/roadmap.md) | 14 stages, each with its own Definition of Done and diagnostics |
| [`docs/review/v0.6-findings.md`](docs/review/v0.6-findings.md) | Review of v0.6: 23 findings, and what each fix changed |

## Current state

Roadmap **Stages 0 and 1 are implemented**; Stages 2–13 are not started. The EA places no
orders yet — by design. Trades first appear at Stage 8, after the structure, regime,
setup, BOS and momentum layers have each been verified on their own.

| | |
|---|---|
| `mql5/Include/HTFLTF/` | Stage 0/1 primitives: indicators, swings, parameter validation, bar guard, funnel counter |
| `mql5/Experts/HTFLTF_Stage01.mq5` | Diagnostic harness — validates parameters, prints ATR/ROC/ER, draws pivots. No trading logic |
| `reference/` | Python reference implementation + 120 tests. See [`reference/README.md`](reference/README.md) |

```bash
cd reference && python3 -m pytest -q
```

## Why the staged build

The first attempt at this system produced zero trades across multiple backtests with no
way to isolate the cause: the whole pipeline was assembled before any single piece had
been verified. Every stage in the roadmap therefore ships its own diagnostic — chart
markers, counters, logs — and from Stage 4 the **Signal Funnel Counter** attributes every
rejected bar to the first gate that rejected it. When entries are zero, the funnel names
the gate instead of leaving it to a guess.

The v0.6 review found two defects that would each have reproduced that failure on their
own: momentum classification rejected essentially every short entry, and the position-size
formula did not yield lots. Both are fixed in v0.7, and both now have named regression
guards in the roadmap and the test suite.
