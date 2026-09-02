"""Stage 1: confirmed swing detection (§4.1) and append-only structure (§4.2).

Includes §39 test #1 — the equal-high/equal-low case, which is the whole reason the
tie-breaking rule exists.
"""

import pytest

from htfltf.bars import Bar, ohlc
from htfltf.swings import (
    ConfirmedStructure,
    Pivot,
    PivotKind,
    detect_swings,
    swings_per_period,
)


def bars_from_hl(highs, lows):
    """Build a series from high/low pairs; open/close are placed inside the range so
    only the extremes matter, which is all §4.1 looks at."""
    times = [i * 60 for i in range(len(highs))]
    mids = [(h + l) / 2 for h, l in zip(highs, lows)]
    return ohlc(times, mids, list(highs), list(lows), mids)


# ------------------------------------------------------------ basic pivot detection


def test_detects_a_clean_swing_high():
    #                       0    1    2*   3    4
    highs = [10.0, 11.0, 15.0, 11.5, 10.5]
    lows = [9.0, 10.0, 14.0, 10.5, 9.5]
    pivots = detect_swings(bars_from_hl(highs, lows), k=2)
    highs_found = [p for p in pivots if p.kind is PivotKind.HIGH]
    assert len(highs_found) == 1
    assert highs_found[0].index == 2
    assert highs_found[0].price == pytest.approx(15.0)


def test_detects_a_clean_swing_low():
    highs = [15.0, 14.0, 10.0, 14.5, 15.5]
    lows = [14.0, 13.0, 5.0, 13.5, 14.5]
    pivots = detect_swings(bars_from_hl(highs, lows), k=2)
    lows_found = [p for p in pivots if p.kind is PivotKind.LOW]
    assert len(lows_found) == 1
    assert lows_found[0].index == 2
    assert lows_found[0].price == pytest.approx(5.0)


def test_no_pivot_within_k_bars_of_either_edge():
    """A pivot needs K bars on BOTH sides, so the first and last K bars can never
    qualify however extreme they are. This is also what makes detection
    non-repainting (§4.1)."""
    highs = [100.0, 1.0, 1.0, 1.0, 1.0, 100.0]
    lows = [99.0, 0.5, 0.5, 0.5, 0.5, 99.0]
    pivots = detect_swings(bars_from_hl(highs, lows), k=2)
    assert all(2 <= p.index <= 3 for p in pivots)


def test_confirmation_index_is_k_bars_after_the_pivot():
    """§4.1: usable only after K future bars have closed. Downstream sequencing must
    order by confirmed_index or it uses knowledge it did not yet have."""
    highs = [10.0, 11.0, 15.0, 11.5, 10.5]
    lows = [9.0, 10.0, 14.0, 10.5, 9.5]
    pivot = detect_swings(bars_from_hl(highs, lows), k=2)[0]
    assert pivot.confirmed_index == pivot.index + 2


# ------------------------------------------------- §39 test #1 — tie-breaking rule


def test_equal_highs_disqualify_both_tied_bars():
    """§4.1 TIE-BREAKING RULE, using the PRD's own worked example: 100, 102, 102, 99.

    Neither 102 qualifies. Not "earliest wins", not "latest wins" — the pivot search
    simply continues. Two implementations picking different tie-break conventions
    would produce different pivots from identical data, which is exactly what the
    determinism objective forbids.
    """
    highs = [100.0, 102.0, 102.0, 99.0, 98.0]
    lows = [h - 1 for h in highs]
    pivots = detect_swings(bars_from_hl(highs, lows), k=1)
    tied = [p for p in pivots if p.kind is PivotKind.HIGH and p.index in (1, 2)]
    assert tied == [], "neither bar in an equal-high tie may qualify as a swing high"


def test_equal_lows_disqualify_both_tied_bars():
    lows = [100.0, 98.0, 98.0, 101.0, 102.0]
    highs = [l + 1 for l in lows]
    pivots = detect_swings(bars_from_hl(highs, lows), k=1)
    tied = [p for p in pivots if p.kind is PivotKind.LOW and p.index in (1, 2)]
    assert tied == []


def test_a_single_equal_high_anywhere_in_the_window_disqualifies():
    """Equality on either side, at any distance within K, is disqualifying — not only
    equality with an immediate neighbour."""
    #        0     1      2*     3      4
    highs = [12.0, 10.0, 12.0, 10.5, 11.0]  # bar 2 ties with bar 0, two bars back
    lows = [h - 1 for h in highs]
    pivots = detect_swings(bars_from_hl(highs, lows), k=2)
    assert not any(p.kind is PivotKind.HIGH and p.index == 2 for p in pivots)


def test_search_continues_past_a_tie_to_a_strictly_greater_bar():
    """§4.1: "the algorithm continues scanning forward" — a tie must not abort
    detection, only skip the tied bars."""
    #        0     1      2      3      4*     5      6
    highs = [10.0, 12.0, 12.0, 11.0, 20.0, 11.5, 10.0]
    lows = [h - 1 for h in highs]
    pivots = detect_swings(bars_from_hl(highs, lows), k=2)
    found = [p.index for p in pivots if p.kind is PivotKind.HIGH]
    assert 4 in found, "the strictly-greater bar after a tie must still be found"
    assert 1 not in found and 2 not in found


def test_a_flat_series_yields_no_pivots_at_all():
    """Every bar ties with every other, so nothing qualifies. The degenerate case the
    tie-breaking rule implies, stated as a test so it cannot regress into "everything
    is a pivot"."""
    highs = [100.0] * 20
    lows = [99.0] * 20
    assert detect_swings(bars_from_hl(highs, lows), k=3) == []


# ---------------------------------------------------------------------- parameters


def test_larger_k_is_more_selective():
    """Raising K can only remove pivots, never add them: the K=5 window contains the
    K=2 window, so every K=5 pivot is also a K=2 pivot."""
    highs = [10, 12, 11, 15, 13, 11, 14, 20, 16, 13, 12, 18, 14, 11, 10, 9, 13, 11, 10, 8]
    lows = [h - 2 for h in highs]
    series = bars_from_hl([float(h) for h in highs], [float(l) for l in lows])
    k2 = {(p.kind, p.index) for p in detect_swings(series, k=2)}
    k5 = {(p.kind, p.index) for p in detect_swings(series, k=5)}
    assert k5 <= k2
    assert len(k5) < len(k2)


def test_detect_swings_rejects_non_positive_k():
    series = bars_from_hl([10.0] * 5, [9.0] * 5)
    with pytest.raises(ValueError):
        detect_swings(series, k=0)


def test_a_bar_is_never_both_a_high_and_a_low():
    """Being both would require the bar to be strictly above and strictly below its
    own neighbours. Asserted over a varied series so the elif in detect_swings is not
    load-bearing by accident."""
    highs = [10, 12, 11, 15, 13, 11, 14, 20, 16, 13, 12, 18, 14, 11, 10]
    lows = [h - 2 for h in highs]
    pivots = detect_swings(bars_from_hl([float(h) for h in highs], [float(l) for l in lows]), k=2)
    indices = [p.index for p in pivots]
    assert len(indices) == len(set(indices))


# --------------------------------------------------------- confirmed structure §4.2


def test_confirmed_structure_is_append_only():
    """§4.2: "never modified retroactively". Enforced rather than assumed, so a
    caller that tries to rewrite history fails loudly instead of quietly changing the
    backtest."""
    store = ConfirmedStructure()
    store.append(Pivot(PivotKind.HIGH, 10, 600, 15.0, 12))
    with pytest.raises(ValueError, match="append-only"):
        store.append(Pivot(PivotKind.LOW, 5, 300, 9.0, 7))
    with pytest.raises(ValueError, match="append-only"):
        store.append(Pivot(PivotKind.LOW, 10, 600, 9.0, 12))


def test_last_returns_the_most_recent_pivot_of_each_kind():
    store = ConfirmedStructure()
    store.extend([
        Pivot(PivotKind.HIGH, 1, 60, 15.0, 3),
        Pivot(PivotKind.LOW, 4, 240, 9.0, 6),
        Pivot(PivotKind.HIGH, 7, 420, 17.0, 9),
    ])
    assert store.last(PivotKind.HIGH).index == 7
    assert store.last(PivotKind.LOW).index == 4
    assert len(store) == 3


def test_last_confirmed_by_excludes_pivots_not_yet_confirmed():
    """Reading a pivot before its confirmation bar is lookahead bias: it inflates
    every backtest metric and vanishes in live trading. This accessor is what the
    pipeline must use."""
    store = ConfirmedStructure()
    store.extend([
        Pivot(PivotKind.HIGH, 1, 60, 15.0, 4),
        Pivot(PivotKind.HIGH, 7, 420, 17.0, 10),
    ])
    assert store.last_confirmed_by(PivotKind.HIGH, bar_index=9).index == 1
    assert store.last_confirmed_by(PivotKind.HIGH, bar_index=10).index == 7
    assert store.last_confirmed_by(PivotKind.HIGH, bar_index=3) is None


def test_last_returns_none_when_no_pivot_of_that_kind_exists():
    store = ConfirmedStructure()
    store.append(Pivot(PivotKind.HIGH, 1, 60, 15.0, 3))
    assert store.last(PivotKind.LOW) is None


# ------------------------------------------------------- Stage 1 diagnostic output


def test_swings_per_period_buckets_by_time():
    """Roadmap Stage 1 DoD: a plausible, nonzero, roughly stable count per period.
    An extended run of zeros or an absurd count both indicate a bug in K or in the
    tie-breaking."""
    highs = [10, 12, 11, 15, 13, 11, 14, 20, 16, 13, 12, 18, 14, 11, 10, 9, 13, 11, 10, 8]
    lows = [h - 2 for h in highs]
    series = bars_from_hl([float(h) for h in highs], [float(l) for l in lows])
    pivots = detect_swings(series, k=2)
    buckets = swings_per_period(pivots, series, period_seconds=600)  # 10 bars per bucket
    assert sum(buckets.values()) == len(pivots)
    assert all(count > 0 for count in buckets.values())
