"""Stage 1: confirmed swing detection (§4.1) and append-only confirmed structure
(§4.2).

The tie-breaking rule is the whole point of this module. Equal highs and equal lows
never qualify as pivots — not "earliest wins", not "latest wins", neither bar. Two
implementations that pick different tie-break conventions produce different pivots,
different protected levels, and different trades from identical data, which is
exactly what the PRD's determinism objective forbids.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from .bars import Series


class PivotKind(Enum):
    HIGH = "high"
    LOW = "low"


@dataclass(frozen=True)
class Pivot:
    """A confirmed swing pivot.

    `index` / `time` / `price` locate the pivot bar itself. `confirmed_index` is
    `index + K` — the bar at whose close the pivot becomes usable (§4.1). Downstream
    sequencing (protected-level replacement §6.1, abandonment condition B §10.5) must
    order pivots by `confirmed_index`, not `index`, or it will use knowledge that did
    not exist yet at that point in the backtest.
    """

    kind: PivotKind
    index: int
    time: int
    price: float
    confirmed_index: int


def _is_swing_high(series: Series, i: int, k: int) -> bool:
    """Strict inequality against all K bars on BOTH sides (§4.1).

    A single equal high anywhere in either window disqualifies bar i outright.
    """
    pivot = series[i].high
    for j in range(i - k, i + k + 1):
        if j == i:
            continue
        if series[j].high >= pivot:  # >= is the tie-breaking rule: equality disqualifies
            return False
    return True


def _is_swing_low(series: Series, i: int, k: int) -> bool:
    pivot = series[i].low
    for j in range(i - k, i + k + 1):
        if j == i:
            continue
        if series[j].low <= pivot:  # <= : equality disqualifies
            return False
    return True


def detect_swings(series: Series, k: int) -> list[Pivot]:
    """All confirmed pivots in `series`, in bar order.

    `series` is oldest-first, completed bars only. A bar can be neither a swing high
    nor a swing low; it can never be both, since being both would require it to be
    strictly above and strictly below its own neighbours.

    Non-repainting: a pivot at bar i is only detectable once bars i+1..i+K have
    closed, which is why the last K bars of the series can never yield a pivot.
    """
    if k < 1:
        raise ValueError(f"detect_swings: k must be >= 1, got {k}")

    pivots: list[Pivot] = []
    n = len(series)
    # i must have K bars behind it and K bars ahead of it.
    for i in range(k, n - k):
        if _is_swing_high(series, i, k):
            pivots.append(
                Pivot(PivotKind.HIGH, i, series[i].time, series[i].high, i + k)
            )
        elif _is_swing_low(series, i, k):
            pivots.append(
                Pivot(PivotKind.LOW, i, series[i].time, series[i].low, i + k)
            )
    return pivots


class ConfirmedStructure:
    """Append-only store of confirmed pivots (§4.2).

    "Never modified retroactively" is enforced here rather than left to convention:
    `append` rejects any pivot that is not strictly later than the last one stored, so
    a caller that tries to rewrite history fails loudly instead of quietly changing
    the backtest.
    """

    def __init__(self) -> None:
        self._pivots: list[Pivot] = []

    def append(self, pivot: Pivot) -> None:
        if self._pivots:
            last = self._pivots[-1]
            if pivot.index <= last.index:
                raise ValueError(
                    "ConfirmedStructure is append-only: "
                    f"pivot at index {pivot.index} is not after last stored index {last.index}"
                )
        self._pivots.append(pivot)

    def extend(self, pivots: list[Pivot]) -> None:
        for p in pivots:
            self.append(p)

    @property
    def pivots(self) -> list[Pivot]:
        return list(self._pivots)

    def last(self, kind: PivotKind) -> Pivot | None:
        for p in reversed(self._pivots):
            if p.kind is kind:
                return p
        return None

    def last_confirmed_by(self, kind: PivotKind, bar_index: int) -> Pivot | None:
        """Most recent pivot of `kind` that was already confirmed at `bar_index`.

        This is the accessor the pipeline must use. Reading `last()` during a backtest
        would let the strategy see a pivot K bars before it was actually confirmed —
        lookahead bias that inflates every backtest metric and vanishes in live trading.
        """
        for p in reversed(self._pivots):
            if p.kind is kind and p.confirmed_index <= bar_index:
                return p
        return None

    def __len__(self) -> int:
        return len(self._pivots)


def swings_per_period(pivots: list[Pivot], series: Series, period_seconds: int) -> dict[int, int]:
    """Pivot counts bucketed by period — the Stage 1 diagnostic.

    Roadmap Stage 1 requires a plausible, nonzero, roughly stable count: an extended
    run of zeros or an absurdly high count both indicate a bug in K or in the
    tie-breaking.
    """
    if period_seconds < 1:
        raise ValueError("swings_per_period: period_seconds must be >= 1")
    buckets: dict[int, int] = {}
    for p in pivots:
        bucket = series[p.index].time // period_seconds
        buckets[bucket] = buckets.get(bucket, 0) + 1
    return buckets
