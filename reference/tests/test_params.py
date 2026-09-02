"""§39 test #12 / §38: every invalid-input case must be rejected at startup with a
specific, identifiable message.

Two properties matter beyond "it rejects": the message must name the offending
parameter (§38's diagnosability requirement), and validation must report every
failure rather than stopping at the first, so a misconfigured setup is fixed in one
pass instead of one restart per typo.
"""

import dataclasses

import pytest

from htfltf.params import (
    BrokerStopDistanceMode,
    Params,
    RISK_CEILING_PERCENT,
    SessionWindow,
    format_errors,
    validate,
)


def valid() -> Params:
    return Params(sessions=[SessionWindow("Europe/London", 8 * 60, 16 * 60)])


def names(errors) -> set[str]:
    return {e.parameter for e in errors}


def test_default_parameters_are_valid():
    """The shipped defaults must start. They are sanity-test values, not calibrated
    ones (§28.2), but an EA that refuses its own defaults is unusable."""
    assert validate(valid()) == []
    assert validate(Params()) == []  # sessions may be empty (filter effectively off)


@pytest.mark.parametrize(
    "field,bad_value",
    [
        # §3 timeframe model (added v0.7, finding M-10)
        ("htf_minutes", 5),      # equal to LTF
        ("htf_minutes", 1),      # below LTF
        ("htf_minutes", 7),      # not an integer multiple of LTF=5
        ("ltf_minutes", 0),
        # §4.1
        ("swing_confirmation_bars", 0),
        # §35 ATR multipliers
        ("bos_atr_multiplier", 0.0),
        ("bos_atr_multiplier", -1.0),
        ("sl_atr_multiplier", 0.0),
        ("trail_atr_multiplier", 0.0),
        ("trail_shadow_multiplier", 0.0),
        ("structural_break_atr_multiplier", 0.0),   # added v0.7, finding B-5
        # §35 buffer floors (added v0.7, finding B-4)
        ("bos_minimum_points", -1.0),
        ("sl_minimum_points", -1.0),
        ("structural_minimum_points", -1.0),
        # §37 ATR periods (added v0.7, finding M-10)
        ("htf_atr_period", 0),
        ("ltf_atr_period", 0),
        # §7 regime
        ("er_lookback", 1),      # added v0.7: §7.1 path sum is degenerate below 2
        ("er_lookback", 0),
        ("adx_period", 0),
        ("adx_threshold", -1.0),
        # §9.3
        ("location_threshold", 0.0),
        ("location_threshold", -0.5),
        # §10.5.C
        ("max_retracement_bars", 0),
        # §12
        ("roc_period", 0),
        # §14
        ("maximum_slippage", -1.0),
        # §16
        ("trailing_activation_r", -0.1),
        ("breakeven_activation_r", -0.1),
        ("breakeven_buffer", -1.0),
        ("shadow_lookback_bars", 0),               # added v0.7, finding B-6
        # §17
        ("max_daily_loss", 0.0),
        ("max_consecutive_losses", 0),
        # §19 (added v0.7, finding M-10)
        ("maximum_allowed_spread", 0.0),
        ("maximum_normalized_spread", 0.0),
        # §12.2 risk tiers
        ("high_confidence_risk_percent", 0.0),
        ("high_confidence_risk_percent", RISK_CEILING_PERCENT + 0.1),
        ("low_confidence_risk_percent", 0.0),
    ],
)
def test_each_invalid_value_is_rejected_and_names_its_parameter(field, bad_value):
    p = dataclasses.replace(valid(), **{field: bad_value})
    errors = validate(p)
    assert errors, f"{field}={bad_value!r} should have been rejected"
    assert any(field in e.parameter for e in errors), (
        f"no error names {field}; §38 requires the specific parameter, got {names(errors)}"
    )


def test_er_thresholds_must_not_be_equal_or_inverted():
    for low, high in ((0.5, 0.5), (0.6, 0.4)):
        errors = validate(dataclasses.replace(valid(), er_low=low, er_high=high))
        assert "er_high" in names(errors)


def test_roc_thresholds_must_not_be_equal_or_inverted():
    for strong, negative in ((0.0, 0.0), (-0.5, 0.5)):
        errors = validate(
            dataclasses.replace(
                valid(), roc_strong_threshold=strong, roc_negative_threshold=negative
            )
        )
        assert "roc_strong_threshold" in names(errors)


def test_inverted_risk_tiers_are_rejected():
    """§38: LowConfidenceRiskPercent > HighConfidenceRiskPercent — a low-confidence
    trade must never carry more risk than a high-confidence one."""
    errors = validate(
        dataclasses.replace(
            valid(), high_confidence_risk_percent=0.5, low_confidence_risk_percent=1.0
        )
    )
    assert "low_confidence_risk_percent" in names(errors)


def test_risk_above_the_ceiling_is_treated_as_an_input_error():
    """§38 is explicit that this is a likely typo, not a valid aggressive setting."""
    errors = validate(
        dataclasses.replace(valid(), high_confidence_risk_percent=RISK_CEILING_PERCENT + 5)
    )
    assert any("ceiling" in e.reason for e in errors)


def test_breakeven_checks_are_skipped_when_breakeven_is_disabled():
    """§38 conditions the breakeven checks on the feature being enabled — an unused
    parameter must not block startup."""
    p = dataclasses.replace(
        valid(), breakeven_enabled=False, breakeven_activation_r=-1.0, breakeven_buffer=-1.0
    )
    assert validate(p) == []


def test_unknown_session_timezone_is_rejected():
    p = dataclasses.replace(valid(), sessions=[SessionWindow("Mars/Olympus", 60, 120)])
    errors = validate(p)
    assert any("timezone" in e.parameter for e in errors)
    assert any("unknown timezone" in e.reason for e in errors)


def test_session_window_start_must_precede_end():
    """§18.1 windows are [start, end); start >= end is empty or inverted."""
    for start, end in ((600, 600), (900, 600)):
        errors = validate(
            dataclasses.replace(valid(), sessions=[SessionWindow("Asia/Tokyo", start, end)])
        )
        assert errors and any("sessions[0]" in e.parameter for e in errors)


def test_session_window_must_fall_within_one_day():
    errors = validate(
        dataclasses.replace(valid(), sessions=[SessionWindow("Asia/Tokyo", 0, 2000)])
    )
    assert errors


def test_invalid_broker_stop_mode_is_rejected():
    p = dataclasses.replace(valid(), broker_stop_distance_mode="widen")  # string, not enum
    errors = validate(p)
    assert "broker_stop_distance_mode" in names(errors)


def test_valid_broker_stop_modes_are_accepted():
    for mode in BrokerStopDistanceMode:
        assert validate(dataclasses.replace(valid(), broker_stop_distance_mode=mode)) == []


def test_every_failing_parameter_is_reported_not_just_the_first():
    """§38: validation must report all failures, so a misconfigured setup is fixed in
    one pass rather than one restart per typo."""
    p = dataclasses.replace(
        valid(),
        location_threshold=-1.0,
        max_retracement_bars=0,
        swing_confirmation_bars=0,
        er_lookback=1,
        shadow_lookback_bars=0,
    )
    errors = validate(p)
    assert names(errors) >= {
        "location_threshold",
        "max_retracement_bars",
        "swing_confirmation_bars",
        "er_lookback",
        "shadow_lookback_bars",
    }


def test_error_messages_carry_the_offending_value():
    """"Specific, identifiable log message" (§38) means the value too — the parameter
    name alone does not tell you what was actually configured."""
    errors = validate(dataclasses.replace(valid(), location_threshold=-2.5))
    rendered = format_errors(errors)
    assert "location_threshold" in rendered
    assert "-2.5" in rendered
    assert "refusing to start" in rendered


def test_format_errors_reports_ok_when_clean():
    assert format_errors(validate(valid())) == "parameter validation: OK"


# ------------------------------------------------------ §26 parameter hash


def test_parameter_hash_changes_when_any_parameter_changes():
    """Stage 11 DoD sanity-checks the hashing itself: a hash that does not move when
    a parameter moves makes every logged trade unattributable."""
    base = valid()
    baseline = base.parameter_hash()
    for field, value in (
        ("location_threshold", 2.0),
        ("er_low", 0.3),
        ("roc_period", 7),
        ("breakeven_enabled", False),
    ):
        assert dataclasses.replace(base, **{field: value}).parameter_hash() != baseline


def test_parameter_hash_is_stable_across_identical_configurations():
    assert valid().parameter_hash() == valid().parameter_hash()
