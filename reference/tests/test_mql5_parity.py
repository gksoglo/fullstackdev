"""Parity between the MQL5 EA and this Python reference.

The PRD's central objective is that "two independent implementations of this
specification... produce the same structural interpretation and the same trades".
This repository has exactly two such implementations, so that objective is testable
directly rather than only assertable.

The MQL5 functions use SERIES indexing (index 0 = newest bar) while the reference
uses oldest-first ordering. That difference is where an off-by-one hides: an ATR
recursion that runs backwards through time, or an ER window shifted by one bar,
produces plausible numbers that are wrong everywhere downstream. The ports below
transcribe the loop structure of `mql5/Include/HTFLTF/Indicators.mqh` verbatim,
series indexing included, so the two are compared as written rather than as intended.

Keep these ports in step with the .mqh file. A parity test that has silently drifted
from the code it mirrors is worse than none.
"""

import random

import pytest

from htfltf.bars import Bar, from_closes
from htfltf.indicators import (
    average_shadow,
    efficiency_ratio,
    roc,
    wilder_atr,
)


# --------------------------------------------------------------------------------
# Verbatim ports of mql5/Include/HTFLTF/Indicators.mqh — series-indexed, [0] = newest
# --------------------------------------------------------------------------------


def mql_true_range(high, low, prev_close):
    return max(high - low, abs(high - prev_close), abs(low - prev_close))


def mql_wilder_atr(high, low, close, period):
    n = len(close)
    if period < 1 or n < period + 1:
        return None
    tr_count = n - 1
    total = 0.0
    for k in range(period):                      # seed on the OLDEST `period` TRs
        i = tr_count - 1 - k
        total += mql_true_range(high[i], low[i], close[i + 1])
    atr = total / period
    for i in range(tr_count - 1 - period, -1, -1):   # forward in time = descending index
        atr = (atr * (period - 1) + mql_true_range(high[i], low[i], close[i + 1])) / period
    return atr


def mql_roc(close, period):
    if period < 1 or len(close) < period + 1:
        return None
    past = close[period]
    if past == 0.0:
        return None
    return (close[0] - past) / past * 100.0


def mql_efficiency_ratio(close, lookback):
    if lookback < 2 or len(close) < lookback + 1:
        return None
    net = abs(close[0] - close[lookback])
    path = sum(abs(close[i] - close[i + 1]) for i in range(lookback))
    if path == 0.0:
        return 0.0
    return net / path


def mql_average_shadow(o, h, l, c, lookback, is_long):
    if lookback < 1 or len(c) < lookback:
        return None
    total = 0.0
    for i in range(lookback):
        body_top = max(o[i], c[i])
        body_bottom = min(o[i], c[i])
        total += (h[i] - body_top) if is_long else (body_bottom - l[i])
    return total / lookback


# --------------------------------------------------------------------------------


def as_series(bars):
    """Oldest-first bars -> the four MT5 series arrays, newest first."""
    rev = list(reversed(bars))
    return (
        [b.open for b in rev],
        [b.high for b in rev],
        [b.low for b in rev],
        [b.close for b in rev],
    )


def random_bars(rng, n):
    bars, px = [], 100.0
    for i in range(n):
        px += rng.uniform(-1.5, 1.5)
        o = px + rng.uniform(-0.3, 0.3)
        c = px + rng.uniform(-0.3, 0.3)
        h = max(o, c) + rng.uniform(0.0, 0.9)
        low = min(o, c) - rng.uniform(0.0, 0.9)
        bars.append(Bar(i * 60, o, h, low, c))
    return bars


# Fixed seed: parity failures must be reproducible, not a different case every run.
TRIALS = 200
SEED = 20260902


def test_atr_parity_over_randomized_series():
    rng = random.Random(SEED)
    for _ in range(TRIALS):
        bars = random_bars(rng, rng.randint(25, 90))
        _, h, l, c = as_series(bars)
        period = rng.randint(2, 14)
        assert mql_wilder_atr(h, l, c, period) == pytest.approx(
            wilder_atr(bars, period), abs=1e-12
        )


def test_roc_parity_over_randomized_series():
    rng = random.Random(SEED)
    for _ in range(TRIALS):
        bars = random_bars(rng, rng.randint(25, 90))
        _, _, _, c = as_series(bars)
        period = rng.randint(1, 14)
        assert mql_roc(c, period) == pytest.approx(roc(bars, period), abs=1e-12)


def test_er_parity_over_randomized_series():
    rng = random.Random(SEED)
    for _ in range(TRIALS):
        bars = random_bars(rng, rng.randint(25, 90))
        _, _, _, c = as_series(bars)
        lookback = rng.randint(2, 15)
        assert mql_efficiency_ratio(c, lookback) == pytest.approx(
            efficiency_ratio(bars, lookback), abs=1e-12
        )


def test_average_shadow_parity_over_randomized_series():
    rng = random.Random(SEED)
    for _ in range(TRIALS):
        bars = random_bars(rng, rng.randint(25, 90))
        o, h, l, c = as_series(bars)
        lookback = rng.randint(1, 15)
        for is_long in (True, False):
            assert mql_average_shadow(o, h, l, c, lookback, is_long) == pytest.approx(
                average_shadow(bars, lookback, is_long), abs=1e-12
            )


def test_atr_parity_on_the_hand_computed_case():
    """The same worked example as test_indicators, through the MQL5 loop structure.
    A randomized test can pass while both implementations share one wrong formula;
    this one is anchored to a value computed by hand from §37."""
    bars = [
        Bar(0, 10.0, 11.0, 9.0, 11.0),
        Bar(60, 11.0, 12.0, 10.0, 11.0),
        Bar(120, 11.5, 14.0, 11.0, 13.0),
        Bar(180, 13.5, 15.0, 13.0, 14.0),
        Bar(240, 12.5, 16.0, 12.0, 13.0),
        Bar(300, 15.5, 17.0, 15.0, 16.0),
    ]
    _, h, l, c = as_series(bars)
    assert mql_wilder_atr(h, l, c, 3) == pytest.approx(88.0 / 27.0)


def test_er_flat_window_parity():
    """§39 test #15 through the MQL5 path — the zero-denominator guard must exist on
    both sides, or the EA diverges from the reference on exactly the input that used
    to produce nan (finding B-3)."""
    flat = from_closes([100.0] * 20)
    _, _, _, c = as_series(flat)
    assert mql_efficiency_ratio(c, 10) == 0.0
    assert efficiency_ratio(flat, 10) == 0.0


def test_insufficient_data_boundaries_agree():
    """Both sides must become available on the SAME bar. If one needs period+1 and
    the other period, they disagree for exactly one bar at the start of every run —
    and on that bar the EA trades against a value the reference never produced."""
    rng = random.Random(SEED)
    bars = random_bars(rng, 40)
    for period in (2, 5, 14):
        for n in range(period - 1, period + 3):
            window = bars[:n]
            _, h, l, c = as_series(window)
            mql_available = mql_wilder_atr(h, l, c, period) is not None
            py_available = n >= period + 1
            assert mql_available == py_available, (
                f"ATR availability disagrees at n={n}, period={period}"
            )
