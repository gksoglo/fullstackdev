"""Stage 0: the full parameter set (§32) and fail-fast startup validation (§38).

Two rules from §38 shape this module:

  * every failure names the specific parameter and the value that failed, never a
    generic "bad configuration" — that is what makes fail-fast diagnosable rather
    than merely safe; and
  * validation reports EVERY failing parameter, not just the first, so a
    misconfigured setup is fixed in one pass instead of one restart per typo.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field, asdict
from enum import Enum


class BrokerStopDistanceMode(Enum):
    """§36.2 — what to do when the ATR-derived SL is inside the broker's minimum."""

    WIDEN = "WIDEN"
    REJECT = "REJECT"


# Timezones the session filter accepts (§18). Kept as an explicit allow-list because
# §38 requires "unknown timezone identifier" to be a startup failure, and silently
# accepting an unrecognised string is precisely the undefined runtime behaviour the
# section exists to prevent.
SUPPORTED_TIMEZONES = frozenset({"Asia/Tokyo", "Europe/London", "America/New_York"})

# §38: risk percents above this are treated as a likely input error, not a valid
# aggressive setting.
RISK_CEILING_PERCENT = 5.0


@dataclass(frozen=True)
class SessionWindow:
    """A trading window in its own timezone, [start, end) per §18.1."""

    timezone: str
    start_minute: int  # minutes past local midnight, inclusive
    end_minute: int    # exclusive


@dataclass
class Params:
    """The complete §32 parameter set. Defaults are sanity-test starting points per
    the roadmap's "loose first" guidance, NOT calibrated values — §28.2 lists the
    seven parameters that get swept, and none of these defaults is a result.
    """

    # §3 timeframes, in minutes
    htf_minutes: int = 60
    ltf_minutes: int = 5

    # §4.1 swing detection
    swing_confirmation_bars: int = 3

    # §5.4 structural break buffer
    structural_break_atr_multiplier: float = 0.1
    structural_minimum_points: float = 0.0

    # §37 ATR
    htf_atr_period: int = 14
    ltf_atr_period: int = 14

    # §7 regime
    er_lookback: int = 10
    er_low: float = 0.25
    er_high: float = 0.55
    adx_period: int = 14
    adx_threshold: float = 20.0

    # §9.3 location
    location_threshold: float = 1.5

    # §10.5.C abandonment timeout
    max_retracement_bars: int = 30

    # §11.3 BOS
    bos_atr_multiplier: float = 0.25
    bos_minimum_points: float = 0.0

    # §12 momentum (compared against Directional_ROC, §12.1)
    roc_period: int = 5
    roc_strong_threshold: float = 0.05
    roc_negative_threshold: float = -0.05

    # §13 stop loss
    sl_atr_multiplier: float = 0.5
    sl_minimum_points: float = 0.0

    # §14 execution
    maximum_slippage: float = 10.0

    # §12.2 risk tiers
    high_confidence_risk_percent: float = 1.0
    low_confidence_risk_percent: float = 0.5

    # §16 exits
    trailing_activation_r: float = 1.0
    breakeven_enabled: bool = True
    breakeven_activation_r: float = 0.5
    breakeven_buffer: float = 0.0
    trail_shadow_multiplier: float = 1.5
    trail_atr_multiplier: float = 1.0
    shadow_lookback_bars: int = 10

    # §17 account-level limits
    max_daily_loss: float = 3.0
    max_consecutive_losses: int = 3

    # §18 sessions
    sessions: list[SessionWindow] = field(default_factory=list)

    # §19 spread
    maximum_allowed_spread: float = 20.0
    maximum_normalized_spread: float = 0.2

    # §36.2
    broker_stop_distance_mode: BrokerStopDistanceMode = BrokerStopDistanceMode.REJECT

    def parameter_hash(self) -> str:
        """§26 `Parameter_Hash` — stable hash of the full active parameter set.

        Written to every trade record so a regression across versions can be
        attributed to a parameter change rather than a code change. Sorted keys make
        it order-independent; any change to any field changes the digest.
        """
        payload = json.dumps(asdict(self), sort_keys=True, default=str)
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


@dataclass(frozen=True)
class ValidationError:
    """One §38 failure: which parameter, what value, and why it is invalid."""

    parameter: str
    value: object
    reason: str

    def __str__(self) -> str:
        return f"{self.parameter}={self.value!r}: {self.reason}"


def validate(p: Params) -> list[ValidationError]:
    """Run every §38 check. Returns ALL failures; empty list means the EA may start.

    The MQL5 side calls this equivalent from OnInit and returns
    INIT_PARAMETERS_INCORRECT when the list is non-empty, after logging each entry.
    """
    errors: list[ValidationError] = []

    def bad(parameter: str, value: object, reason: str) -> None:
        errors.append(ValidationError(parameter, value, reason))

    # --- §3 timeframe model (added v0.7, finding M-10) ---
    # ltf_minutes is checked first: it is the divisor of the multiple test below, so
    # an invalid LTF must short-circuit that test rather than reach a modulo by zero.
    if p.ltf_minutes < 1:
        bad("ltf_minutes", p.ltf_minutes, "must be >= 1")
    elif p.htf_minutes <= p.ltf_minutes:
        bad("htf_minutes", p.htf_minutes,
            f"HTF must be strictly higher than LTF (ltf_minutes={p.ltf_minutes}); "
            "an inverted pair makes the §4.4 freeze meaningless")
    elif p.htf_minutes % p.ltf_minutes != 0:
        bad("htf_minutes", p.htf_minutes,
            f"HTF must be an integer multiple of LTF (ltf_minutes={p.ltf_minutes})")

    # --- §4.1 swing detection ---
    if p.swing_confirmation_bars < 1:
        bad("swing_confirmation_bars", p.swing_confirmation_bars, "must be >= 1")

    # --- §35 ATR multipliers: every one must be strictly positive ---
    for name, value in (
        ("bos_atr_multiplier", p.bos_atr_multiplier),
        ("sl_atr_multiplier", p.sl_atr_multiplier),
        ("trail_atr_multiplier", p.trail_atr_multiplier),
        ("trail_shadow_multiplier", p.trail_shadow_multiplier),
        # added v0.7, finding B-5: v0.6 used Structural_Break_Buffer with no
        # multiplier parameter and therefore no validation
        ("structural_break_atr_multiplier", p.structural_break_atr_multiplier),
    ):
        if value <= 0:
            bad(name, value, "ATR multiplier must be > 0")

    # --- §35 buffer floors: three distinct parameters (added v0.7, finding B-4) ---
    for name, value in (
        ("bos_minimum_points", p.bos_minimum_points),
        ("sl_minimum_points", p.sl_minimum_points),
        ("structural_minimum_points", p.structural_minimum_points),
    ):
        if value < 0:
            bad(name, value, "buffer floor must be >= 0")

    # --- §37 ATR periods (added v0.7, finding M-10) ---
    for name, value in (("htf_atr_period", p.htf_atr_period), ("ltf_atr_period", p.ltf_atr_period)):
        if value < 1:
            bad(name, value, "ATR period must be >= 1")

    # --- §7 regime ---
    if p.er_high <= p.er_low:
        bad("er_high", p.er_high, f"must be > er_low ({p.er_low}); "
            "equal or inverted thresholds leave the ambiguous band undefined")
    if p.er_lookback < 2:
        # added v0.7, finding M-10: the §7.1 sum is empty at N<1 and degenerate at N=1
        bad("er_lookback", p.er_lookback, "must be >= 2; the §7.1 path sum is degenerate below 2")
    if p.adx_period < 1:
        bad("adx_period", p.adx_period, "must be >= 1")
    if p.adx_threshold < 0:
        bad("adx_threshold", p.adx_threshold, "must be >= 0")

    # --- §9.3 location ---
    if p.location_threshold <= 0:
        bad("location_threshold", p.location_threshold, "must be > 0")

    # --- §10.5.C ---
    if p.max_retracement_bars < 1:
        bad("max_retracement_bars", p.max_retracement_bars, "must be >= 1")

    # --- §12 momentum ---
    if p.roc_strong_threshold <= p.roc_negative_threshold:
        bad("roc_strong_threshold", p.roc_strong_threshold,
            f"must be > roc_negative_threshold ({p.roc_negative_threshold}); "
            "otherwise the WEAK band is empty or inverted")
    if p.roc_period < 1:
        bad("roc_period", p.roc_period, "must be >= 1")

    # --- §12.2 risk tiers ---
    for name, value in (
        ("high_confidence_risk_percent", p.high_confidence_risk_percent),
        ("low_confidence_risk_percent", p.low_confidence_risk_percent),
    ):
        if value <= 0:
            bad(name, value, "risk percent must be > 0")
        elif value > RISK_CEILING_PERCENT:
            bad(name, value,
                f"exceeds the {RISK_CEILING_PERCENT}% account-risk ceiling; "
                "treated as a likely input error, not a valid aggressive setting")
    if p.low_confidence_risk_percent > p.high_confidence_risk_percent:
        bad("low_confidence_risk_percent", p.low_confidence_risk_percent,
            f"inverted tiers: must be <= high_confidence_risk_percent "
            f"({p.high_confidence_risk_percent})")

    # --- §14 execution ---
    if p.maximum_slippage < 0:
        bad("maximum_slippage", p.maximum_slippage, "must be >= 0")

    # --- §16 exits ---
    if p.trailing_activation_r < 0:
        bad("trailing_activation_r", p.trailing_activation_r, "must be >= 0")
    if p.breakeven_enabled:
        if p.breakeven_activation_r < 0:
            bad("breakeven_activation_r", p.breakeven_activation_r,
                "must be >= 0 when breakeven is enabled")
        if p.breakeven_buffer < 0:
            bad("breakeven_buffer", p.breakeven_buffer,
                "must be >= 0; the buffer sits on the losing side of entry (§16.3)")
    if p.shadow_lookback_bars < 1:
        # added v0.7, finding B-6: Average_LTF_Shadow had no lookback at all in v0.6
        bad("shadow_lookback_bars", p.shadow_lookback_bars, "must be >= 1")

    # --- §17 account-level limits ---
    if p.max_daily_loss <= 0:
        bad("max_daily_loss", p.max_daily_loss, "must be > 0")
    if p.max_consecutive_losses <= 0:
        bad("max_consecutive_losses", p.max_consecutive_losses, "must be > 0")

    # --- §18 sessions ---
    for idx, window in enumerate(p.sessions):
        label = f"sessions[{idx}]"
        if window.timezone not in SUPPORTED_TIMEZONES:
            bad(f"{label}.timezone", window.timezone,
                f"unknown timezone identifier; supported: {sorted(SUPPORTED_TIMEZONES)}")
        if window.start_minute >= window.end_minute:
            bad(f"{label}", (window.start_minute, window.end_minute),
                "start must be < end within a single session window (§18.1 uses [start, end))")
        if not (0 <= window.start_minute < 1440) or not (0 < window.end_minute <= 1440):
            bad(f"{label}", (window.start_minute, window.end_minute),
                "minutes must fall within a single day [0, 1440]")

    # --- §19 spread (added v0.7, finding M-10) ---
    if p.maximum_allowed_spread <= 0:
        bad("maximum_allowed_spread", p.maximum_allowed_spread, "must be > 0")
    if p.maximum_normalized_spread <= 0:
        bad("maximum_normalized_spread", p.maximum_normalized_spread, "must be > 0")

    # --- §36.2 (added v0.7, finding M-10) ---
    if not isinstance(p.broker_stop_distance_mode, BrokerStopDistanceMode):
        bad("broker_stop_distance_mode", p.broker_stop_distance_mode,
            "must be BrokerStopDistanceMode.WIDEN or .REJECT")

    return errors


def format_errors(errors: list[ValidationError]) -> str:
    """§38's logging requirement: one line per failure, each naming its parameter."""
    if not errors:
        return "parameter validation: OK"
    lines = [f"parameter validation FAILED ({len(errors)} problem(s)) — refusing to start:"]
    lines.extend(f"  - {e}" for e in errors)
    return "\n".join(lines)
