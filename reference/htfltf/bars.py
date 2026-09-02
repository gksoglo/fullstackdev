"""Bar series types shared by the reference implementation.

Per PRD §10.4 all structural detection and indicator computation runs on Bid-based
OHLC, using completed bars only. Nothing in this module ever sees a forming bar:
a `Series` is by construction a list of closed bars, oldest first.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence


@dataclass(frozen=True)
class Bar:
    """One completed OHLC bar. `time` is the bar's OPEN timestamp, epoch seconds.

    Session validity is evaluated on the CLOSE timestamp (§18.1), which is
    `time + period_seconds`; the open timestamp is stored because that is what MT5
    keys bars by, and deriving close from it keeps the two unambiguous.
    """

    time: int
    open: float
    high: float
    low: float
    close: float

    def __post_init__(self) -> None:
        if not (self.low <= self.open <= self.high):
            raise ValueError(f"bar at {self.time}: open {self.open} outside [{self.low}, {self.high}]")
        if not (self.low <= self.close <= self.high):
            raise ValueError(f"bar at {self.time}: close {self.close} outside [{self.low}, {self.high}]")

    @property
    def upper_shadow(self) -> float:
        """§16.4 — the shadow a long trade trails from."""
        return self.high - max(self.open, self.close)

    @property
    def lower_shadow(self) -> float:
        """§16.4 — the shadow a short trade trails from."""
        return min(self.open, self.close) - self.low


# Oldest-first sequence of completed bars.
#
# Note on indexing: the PRD writes formulas MT5-style, with Close[0] the MOST RECENT
# completed bar and Close[N] N bars older. This module stores bars oldest-first
# (Python-natural, so slicing and enumeration read normally) and converts at the
# boundary. Every public function documents which convention its arguments use.
Series = Sequence[Bar]


def closes(series: Series) -> list[float]:
    return [b.close for b in series]


def ohlc(
    times: Sequence[int],
    o: Sequence[float],
    h: Sequence[float],
    l: Sequence[float],
    c: Sequence[float],
) -> list[Bar]:
    """Build a series from parallel arrays. Convenience for tests and CSV loading."""
    if not (len(times) == len(o) == len(h) == len(l) == len(c)):
        raise ValueError("ohlc(): all arrays must be the same length")
    return [Bar(t, oo, hh, ll, cc) for t, oo, hh, ll, cc in zip(times, o, h, l, c)]


def from_closes(cl: Sequence[float], start: int = 0, step: int = 60) -> list[Bar]:
    """Build a degenerate series where O=H=L=C. Used by ER/ROC tests, which read
    closes only, and by the §39 test #15 flat-window fixture."""
    return [Bar(start + i * step, v, v, v, v) for i, v in enumerate(cl)]
