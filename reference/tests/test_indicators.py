"""Stage 0 Definition of Done: ATR/ROC/ER must match independently-calculated
reference values, and must refuse partial windows.

The ATR and ER expectations below are hand-computed from the §37 / §7.1 formulas, not
captured from this implementation's own output — a self-captured golden value would
pass just as happily against a wrong formula.
"""

import math

import pytest

from htfltf.bars import Bar, from_closes, ohlc
from htfltf.indicators import (
    InsufficientData,
    average_shadow,
    directional_roc,
    efficiency_ratio,
    roc,
    true_range,
    wilder_atr,
    wilder_atr_series,
)


# --------------------------------------------------------------------------- ATR


def test_true_range_takes_the_largest_of_the_three_candidates():
    # Gap up: |high - prev_close| dominates the bar's own range.
    bar = Bar(0, 105.0, 108.0, 104.0, 107.0)
    assert true_range(bar, prev_close=100.0) == pytest.approx(8.0)
    # No gap: the bar's own range dominates.
    assert true_range(bar, prev_close=106.0) == pytest.approx(4.0)
    # Gap down: |low - prev_close| dominates.
    assert true_range(bar, prev_close=112.0) == pytest.approx(8.0)


def test_wilder_atr_matches_hand_computed_value():
    """Six bars, period 3. Worked through by hand from §37.

    TRs (bars 1..5), each max(H-L, |H-Cprev|, |L-Cprev|):
      bar1: H12 L10 Cprev11 -> max(2, 1, 1) = 2
      bar2: H14 L11 Cprev11 -> max(3, 3, 0) = 3
      bar3: H15 L13 Cprev13 -> max(2, 2, 0) = 2
      bar4: H16 L12 Cprev14 -> max(4, 2, 2) = 4
      bar5: H17 L15 Cprev13 -> max(2, 4, 2) = 4

    Seed = mean(2, 3, 2) = 7/3
    then  = (7/3 * 2 + 4) / 3 = (14/3 + 4) / 3 = (26/3) / 3 = 26/9
    then  = (26/9 * 2 + 4) / 3 = (52/9 + 36/9) / 3 = (88/9) / 3 = 88/27
    """
    series = ohlc(
        times=[0, 60, 120, 180, 240, 300],
        o=[10.0, 11.0, 11.5, 13.5, 12.5, 15.5],
        h=[11.0, 12.0, 14.0, 15.0, 16.0, 17.0],
        l=[9.0, 10.0, 11.0, 13.0, 12.0, 15.0],
        c=[11.0, 11.0, 13.0, 14.0, 13.0, 16.0],
    )
    assert wilder_atr(series, period=3) == pytest.approx(88.0 / 27.0)


def test_wilder_atr_differs_from_simple_moving_average_of_true_range():
    """§37 names Wilder specifically. A simple MA of TR is the classic silent
    substitution — it produces plausible numbers that mis-size every buffer in §35,
    so the two must be demonstrably different on the same data."""
    series = ohlc(
        times=list(range(0, 480, 60)),
        o=[10.0, 11.0, 11.5, 13.5, 12.5, 15.5, 14.0, 16.0],
        h=[11.0, 12.0, 14.0, 15.0, 16.0, 17.0, 16.5, 18.0],
        l=[9.0, 10.0, 11.0, 13.0, 12.0, 15.0, 13.5, 15.5],
        c=[11.0, 11.0, 13.0, 14.0, 13.0, 16.0, 15.0, 17.0],
    )
    period = 3
    trs = [true_range(series[i], series[i - 1].close) for i in range(1, len(series))]
    simple_ma = sum(trs[-period:]) / period
    assert wilder_atr(series, period) != pytest.approx(simple_ma)


def test_wilder_atr_of_a_constant_range_series_equals_that_range():
    """Wilder's recursion is a weighted mean, so a constant TR must be a fixed point.
    Catches a mis-weighted recursion that a noisy series would hide."""
    bars = [Bar(i * 60, 10.0, 12.0, 8.0, 10.0) for i in range(30)]
    assert wilder_atr(bars, period=14) == pytest.approx(4.0)


def test_wilder_atr_needs_period_plus_one_bars():
    """§37: the first TR needs a previous close, so ATR(p) requires p+1 bars."""
    bars = [Bar(i * 60, 10.0, 11.0, 9.0, 10.0) for i in range(14)]
    with pytest.raises(InsufficientData) as exc:
        wilder_atr(bars, period=14)
    assert exc.value.needed == 15
    assert exc.value.got == 14
    # One more bar and it is defined.
    bars.append(Bar(14 * 60, 10.0, 11.0, 9.0, 10.0))
    assert wilder_atr(bars, period=14) == pytest.approx(2.0)


def test_wilder_atr_rejects_non_positive_period():
    bars = [Bar(i * 60, 10.0, 11.0, 9.0, 10.0) for i in range(20)]
    with pytest.raises(ValueError):
        wilder_atr(bars, period=0)


def test_wilder_atr_series_agrees_with_the_scalar_form_at_every_bar():
    """The per-bar diagnostic and the scalar used by the gates must not drift apart."""
    bars = ohlc(
        times=list(range(0, 900, 60)),
        o=[10, 11, 11.5, 13.5, 12.5, 15.5, 14, 16, 15, 17, 16, 18, 17, 19, 18],
        h=[11, 12, 14, 15, 16, 17, 16.5, 18, 17, 18.5, 17.5, 19, 18, 20, 19],
        l=[9, 10, 11, 13, 12, 15, 13.5, 15.5, 14.5, 16.5, 15.5, 17.5, 16.5, 18.5, 17.5],
        c=[11, 11, 13, 14, 13, 16, 15, 17, 16, 18, 17, 18.5, 17.5, 19.5, 18.5],
    )
    per_bar = wilder_atr_series(bars, period=5)
    for end in range(6, len(bars) + 1):
        assert per_bar[end - 1] == pytest.approx(wilder_atr(bars[:end], period=5))


# --------------------------------------------------------------------------- ROC


def test_roc_is_a_percent_return_not_a_point_difference():
    """§12.4 — percent specifically, so one threshold works across price scales."""
    series = from_closes([100.0, 101.0, 102.0, 103.0, 110.0])
    assert roc(series, period=4) == pytest.approx(10.0)  # (110-100)/100*100


def test_roc_percent_is_scale_invariant():
    """The whole reason §12.4 mandates percent: the same proportional move on a
    differently-priced instrument must give the same ROC."""
    cheap = from_closes([1.0, 1.05, 1.10])
    dear = from_closes([10000.0, 10500.0, 11000.0])
    assert roc(cheap, period=2) == pytest.approx(roc(dear, period=2))


def test_roc_is_negative_on_a_falling_series():
    series = from_closes([100.0, 98.0, 95.0])
    assert roc(series, period=2) == pytest.approx(-5.0)


def test_roc_needs_period_plus_one_bars():
    series = from_closes([100.0, 101.0, 102.0])
    with pytest.raises(InsufficientData):
        roc(series, period=3)
    assert roc(series, period=2) == pytest.approx(2.0)


def test_roc_rejects_zero_reference_close():
    series = from_closes([0.0, 1.0, 2.0])
    with pytest.raises(ValueError):
        roc(series, period=2)


# ------------------------------------------------- §39 test #13 — B-1 regression


def test_directional_roc_signs_into_the_trades_own_direction():
    """§12.1. This is the regression guard for finding B-1.

    A bearish impulse gives a large negative raw ROC. PRD v0.6 compared that raw value
    against ROC_NEGATIVE_THRESHOLD and classified the short REJECT — the stronger the
    move in the trade's favour, the more certain the rejection.
    """
    bearish = from_closes([100.0, 98.0, 96.0, 94.0, 92.0])
    raw = roc(bearish, period=4)
    assert raw < 0  # raw ROC is negative, as a bearish impulse should be

    strong_threshold = 0.05
    negative_threshold = -0.05

    # A short setup: direction-signed, this is strong momentum WITH the trade.
    short_signed = directional_roc(raw, is_long=False)
    assert short_signed > 0
    assert short_signed >= strong_threshold, "bearish impulse must classify STRONG for a short"

    # The v0.6 behaviour, shown explicitly so the regression stays legible: comparing
    # the raw value is what rejected every healthy short.
    assert raw <= negative_threshold, "raw comparison would have classified this NEGATIVE"


def test_directional_roc_is_identity_for_longs():
    assert directional_roc(1.23, is_long=True) == pytest.approx(1.23)
    assert directional_roc(-1.23, is_long=True) == pytest.approx(-1.23)


def test_a_short_into_a_rally_classifies_negative():
    """The other half of B-1: v0.6 gave this case the LARGER risk allocation."""
    rally = from_closes([92.0, 94.0, 96.0, 98.0, 100.0])
    signed = directional_roc(roc(rally, period=4), is_long=False)
    assert signed <= -0.05, "a short entering a rally must classify NEGATIVE"


def test_long_and_short_tiers_are_symmetric_on_mirrored_data():
    """Direction-signing must make the two directions behave identically on mirrored
    price action — the property that makes one threshold pair valid for both."""
    up = from_closes([100.0, 102.0, 104.0, 106.0])
    down = from_closes([100.0, 98.0, 96.0, 94.0])
    long_signed = directional_roc(roc(up, period=3), is_long=True)
    short_signed = directional_roc(roc(down, period=3), is_long=False)
    # Not exactly equal (percent returns are asymmetric about a moving base), but the
    # same sign and the same order of magnitude — both are "momentum with the trade".
    assert long_signed > 0 and short_signed > 0
    assert long_signed == pytest.approx(short_signed, rel=0.15)


# ---------------------------------------------------------------------------- ER


def test_efficiency_ratio_is_one_on_a_perfectly_straight_move():
    """Net move equals path length when every step is in the same direction."""
    series = from_closes([100.0, 101.0, 102.0, 103.0, 104.0, 105.0])
    assert efficiency_ratio(series, lookback=5) == pytest.approx(1.0)


def test_efficiency_ratio_matches_hand_computed_value_on_a_zigzag():
    """Closes 100, 102, 101, 103, 102, 104 over lookback 5.
    net  = |104 - 100| = 4
    path = 2 + 1 + 2 + 1 + 2 = 8
    ER   = 0.5
    """
    series = from_closes([100.0, 102.0, 101.0, 103.0, 102.0, 104.0])
    assert efficiency_ratio(series, lookback=5) == pytest.approx(0.5)


def test_efficiency_ratio_is_zero_on_a_round_trip():
    """Price returns to where it started: no net progress, so no efficiency."""
    series = from_closes([100.0, 105.0, 110.0, 105.0, 100.0])
    assert efficiency_ratio(series, lookback=4) == pytest.approx(0.0)


def test_efficiency_ratio_uses_only_the_lookback_window():
    """Older bars beyond N must not leak into the calculation."""
    tail = [100.0, 102.0, 101.0, 103.0, 102.0, 104.0]
    assert efficiency_ratio(from_closes([5.0, 900.0] + tail), lookback=5) == pytest.approx(
        efficiency_ratio(from_closes(tail), lookback=5)
    )


# -------------------------------------------------- §39 test #15 — B-3 regression


def test_efficiency_ratio_of_a_flat_window_is_zero_not_nan():
    """§7.1 zero-denominator rule. Regression guard for finding B-3.

    v0.6 divided unconditionally. A constant close series makes the denominator
    exactly 0.0, giving inf or nan — and nan compares False against BOTH ER_HIGH and
    ER_LOW, so the symbol silently lands in the ambiguous band with the regime decided
    entirely by ADX, and nothing in the log says why.
    """
    flat = from_closes([100.0] * 12)
    er = efficiency_ratio(flat, lookback=10)
    assert er == 0.0
    assert not math.isnan(er)
    assert not math.isinf(er)

    # And it must classify CHOPPY for any valid threshold pair (§7.2).
    er_low, er_high = 0.25, 0.55
    assert er < er_low, "a flat window must be CHOPPY, not ambiguous"


def test_efficiency_ratio_needs_lookback_plus_one_bars():
    """§7.1 data sufficiency: N+1 closes give the N intervals the path sum needs."""
    series = from_closes([100.0] * 10)
    with pytest.raises(InsufficientData) as exc:
        efficiency_ratio(series, lookback=10)
    assert exc.value.needed == 11


def test_efficiency_ratio_rejects_degenerate_lookback():
    """§38 rejects er_lookback < 2 at startup; the function refuses it too, so a
    direct caller cannot bypass the check."""
    series = from_closes([100.0] * 20)
    for bad in (0, 1):
        with pytest.raises(ValueError):
            efficiency_ratio(series, lookback=bad)


# ------------------------------------------------------------------ shadows §16.4


def test_average_shadow_uses_the_side_the_trade_trails_from():
    """§16.4 — longs trail from highs (upper shadow), shorts from lows (lower)."""
    bars = ohlc(
        times=[0, 60, 120],
        o=[10.0, 10.0, 10.0],
        h=[13.0, 14.0, 15.0],   # upper shadows above max(O,C)=11 -> 2, 3, 4
        l=[8.0, 7.0, 6.0],      # lower shadows below min(O,C)=10 -> 2, 3, 4
        c=[11.0, 11.0, 11.0],
    )
    assert average_shadow(bars, lookback=3, is_long=True) == pytest.approx(3.0)
    assert average_shadow(bars, lookback=3, is_long=False) == pytest.approx(3.0)


def test_average_shadow_distinguishes_the_two_sides():
    """A series with big upper wicks and no lower wicks must not report them equal."""
    bars = ohlc(
        times=[0, 60],
        o=[10.0, 10.0],
        h=[20.0, 20.0],   # upper shadow 9 each
        l=[10.0, 10.0],   # lower shadow 0 each
        c=[11.0, 11.0],
    )
    assert average_shadow(bars, lookback=2, is_long=True) == pytest.approx(9.0)
    assert average_shadow(bars, lookback=2, is_long=False) == pytest.approx(0.0)


def test_average_shadow_uses_only_the_lookback_window():
    bars = ohlc(
        times=[0, 60, 120, 180],
        o=[10.0] * 4,
        h=[100.0, 12.0, 13.0, 14.0],  # first bar is a huge outlier, outside the window
        l=[10.0] * 4,
        c=[11.0] * 4,
    )
    # Last 3 upper shadows: 1, 2, 3 -> mean 2.
    assert average_shadow(bars, lookback=3, is_long=True) == pytest.approx(2.0)


def test_average_shadow_needs_lookback_bars():
    bars = ohlc(times=[0, 60], o=[10.0, 10.0], h=[12.0, 12.0], l=[9.0, 9.0], c=[11.0, 11.0])
    with pytest.raises(InsufficientData):
        average_shadow(bars, lookback=3, is_long=True)
