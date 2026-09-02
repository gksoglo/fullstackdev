"""Stage 0 math primitives: Wilder ATR (§37), ROC (§12.4), ER (§7.1), average
shadow (§16.4).

Every function here refuses to produce a value from a partial window. PRD §37 and
§7.1 both require an explicit insufficient-data result rather than a partial sum,
because a silently-partial ATR or ER is the "wrong-but-plausible number" failure the
roadmap's Stage 0 exists to prevent.
"""

from __future__ import annotations

from .bars import Bar, Series


class InsufficientData(Exception):
    """Raised when a window has fewer completed bars than the formula requires.

    Callers convert this into a funnel rejection with an explicit reason; it is never
    swallowed into a default value.
    """

    def __init__(self, what: str, needed: int, got: int) -> None:
        super().__init__(f"{what}: need {needed} completed bars, got {got}")
        self.what = what
        self.needed = needed
        self.got = got


def true_range(bar: Bar, prev_close: float) -> float:
    """§37 True Range. Requires the previous bar's close, which is why ATR needs
    period + 1 bars rather than period."""
    return max(
        bar.high - bar.low,
        abs(bar.high - prev_close),
        abs(bar.low - prev_close),
    )


def wilder_atr(series: Series, period: int) -> float:
    """§37 ATR using Wilder's smoothing — the standard MT5 iATR calculation.

    NOT a simple moving average of True Range. The distinction matters: a simple MA
    reacts about twice as fast, so every ATR-scaled buffer in the spec (§35) would be
    systematically mis-sized, in a way that still looks plausible on a chart.

    `series` is oldest-first and contains completed bars only. Returns the ATR as of
    the most recent bar.
    """
    if period < 1:
        raise ValueError(f"wilder_atr: period must be >= 1, got {period}")
    n = len(series)
    if n < period + 1:
        raise InsufficientData("ATR", period + 1, n)

    trs = [true_range(series[i], series[i - 1].close) for i in range(1, n)]

    # Seed: simple mean of the first `period` true ranges.
    atr = sum(trs[:period]) / period
    # Wilder recursion over the remainder.
    for tr in trs[period:]:
        atr = (atr * (period - 1) + tr) / period
    return atr


def wilder_atr_series(series: Series, period: int) -> list[float | None]:
    """ATR at every bar, `None` where undefined. Used by the diagnostic output that
    roadmap Stage 0 requires (ATR printed every N bars for eyeball comparison)."""
    if period < 1:
        raise ValueError(f"wilder_atr_series: period must be >= 1, got {period}")
    n = len(series)
    out: list[float | None] = [None] * n
    if n < period + 1:
        return out

    trs = [true_range(series[i], series[i - 1].close) for i in range(1, n)]
    atr = sum(trs[:period]) / period
    out[period] = atr
    for k in range(period, len(trs)):
        atr = (atr * (period - 1) + trs[k]) / period
        out[k + 1] = atr
    return out


def roc(series: Series, period: int) -> float:
    """§12.4 Rate of Change — close-to-close PERCENT return on the LTF.

        ROC = (Close[0] - Close[period]) / Close[period] * 100

    where Close[0] is the most recently completed bar (PRD indexing). Percent, not
    log return and not a points difference, so one threshold value stays meaningful
    across instruments with different price scales.

    This returns the RAW SIGNED value. Momentum classification must apply the
    direction signing in §12.1 before comparing against thresholds — see
    `directional_roc`.
    """
    if period < 1:
        raise ValueError(f"roc: period must be >= 1, got {period}")
    n = len(series)
    if n < period + 1:
        raise InsufficientData("ROC", period + 1, n)

    current = series[-1].close
    past = series[-1 - period].close
    if past == 0.0:
        raise ValueError("roc: reference close is zero; percent return undefined")
    return (current - past) / past * 100.0


def directional_roc(raw_roc: float, is_long: bool) -> float:
    """§12.1 — sign ROC into the intended trade's direction.

    Long setups use +ROC, short setups use -ROC, so `ROC_STRONG_THRESHOLD` and
    `ROC_NEGATIVE_THRESHOLD` mean "momentum with the trade" and "momentum against
    the trade" for both directions.

    PRD v0.6 omitted this step and classified shorts on raw signed ROC. A healthy
    bearish impulse therefore scored NEGATIVE -> REJECT, rejecting essentially every
    short entry, while a short entering a rally scored STRONG and got the larger risk
    allocation. See review finding B-1.
    """
    return raw_roc if is_long else -raw_roc


def efficiency_ratio(series: Series, lookback: int) -> float:
    """§7.1 Efficiency Ratio on CLOSE prices only (not median, not typical).

        ER = |Close[0] - Close[N]| / sum(i=1..N) |Close[i-1] - Close[i]|

    Zero-denominator rule (§7.1): a window whose closes are all identical has a
    denominator of exactly zero. Rather than dividing, ER is 0.0, which classifies
    CHOPPY — the correct reading of "no movement at all". PRD v0.6 divided
    unconditionally, producing inf/nan that then compared false against both ER
    thresholds and silently handed the regime decision to ADX. See finding B-3.
    """
    if lookback < 2:
        raise ValueError(f"efficiency_ratio: lookback must be >= 2, got {lookback}")
    n = len(series)
    if n < lookback + 1:
        raise InsufficientData("ER", lookback + 1, n)

    window = [b.close for b in series[-(lookback + 1):]]  # oldest .. newest
    net = abs(window[-1] - window[0])
    path = sum(abs(window[i] - window[i - 1]) for i in range(1, len(window)))

    if path == 0.0:
        return 0.0
    return net / path


def average_shadow(series: Series, lookback: int, is_long: bool) -> float:
    """§16.4 `Average_LTF_Shadow` — mean shadow on the side the trade trails from.

    Long trades trail from highs, so they use the upper shadow
    (High - max(Open, Close)); short trades use the lower shadow
    (min(Open, Close) - Low). Completed bars only.

    PRD v0.6 used this term in the trailing formula without defining the side, the
    lookback, the timeframe, or the completed-bars rule — four free choices, each of
    which changes every trailing exit price. See finding B-6.
    """
    if lookback < 1:
        raise ValueError(f"average_shadow: lookback must be >= 1, got {lookback}")
    n = len(series)
    if n < lookback:
        raise InsufficientData("average shadow", lookback, n)

    window = series[-lookback:]
    total = sum(b.upper_shadow if is_long else b.lower_shadow for b in window)
    return total / lookback
