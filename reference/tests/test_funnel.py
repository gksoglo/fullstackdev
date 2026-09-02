"""The Signal Funnel Counter and the §36.1 bar-processed-once guard.

The funnel is the roadmap's single most important diagnostic — it is what turns
"zero trades, cause unknown" into "location_reject consumed 100% of candidates". Its
own correctness therefore needs tests: a miscounting funnel sends every future
investigation to the wrong gate.
"""

import pytest

from htfltf.barguard import BarGuard
from htfltf.funnel import Funnel, Gate


# ------------------------------------------------------------------------- funnel


def test_gate_enum_order_matches_the_normative_pipeline_order():
    """§22.2 is the single normative ordering (v0.7, finding M-1). The enum order is
    the print order and the attribution order, so it must track §22.2 exactly."""
    assert [g.value for g in Gate] == [
        "position_open",
        "same_bar_close",
        "session",
        "spread",
        "daily_risk",
        "cooldown",
        "structure",
        "regime",
        "setup_not_found",
        "location",
        "bos_not_found",
        "break_distance",
        "momentum",
        "position_size",
        "execution",
    ]


def test_counts_bars_rejects_and_entries():
    f = Funnel()
    for _ in range(10):
        f.bar()
    f.reject(Gate.SESSION)
    f.reject(Gate.SESSION)
    f.reject(Gate.LOCATION)
    f.entry(is_long=True)
    f.entry(is_long=False)

    assert f.bars_evaluated == 10
    assert f.rejects[Gate.SESSION] == 2
    assert f.rejects[Gate.LOCATION] == 1
    assert f.entries_taken == 2
    assert f.entries_long == 1
    assert f.entries_short == 1


def test_report_lists_every_gate_and_the_direction_split():
    """Every gate must appear in the printed funnel. A gate that increments but is
    never printed is worse than no counter: the run looks accounted for while the
    missing line is exactly where the candidates went."""
    from htfltf.funnel import _LABELS

    f = Funnel()
    f.bar()
    f.entry(is_long=True)
    report = f.report()

    assert len(_LABELS) == len(Gate), "every Gate needs a printed label"
    for gate in Gate:
        assert _LABELS[gate] in report, f"{gate.value} is missing from the funnel report"

    assert "Bars evaluated" in report
    assert "Entries taken" in report
    assert "of which LONG" in report
    assert "of which SHORT" in report
    assert "Abandonment (§10.5) by condition" in report


def test_reject_and_entry_totals_account_for_every_evaluated_bar():
    """The funnel is only trustworthy if it is exhaustive: each evaluated bar must
    land in exactly one bucket, or a gate can eat candidates without showing up."""
    f = Funnel()
    plan = [
        (Gate.SESSION, 30),
        (Gate.REGIME, 45),
        (Gate.LOCATION, 20),
    ]
    for gate, count in plan:
        for _ in range(count):
            f.bar()
            f.reject(gate)
    for _ in range(5):
        f.bar()
        f.entry(is_long=True)

    assert sum(f.rejects.values()) + f.entries_taken == f.bars_evaluated == 100


def test_abandonment_breakdown_tracks_conditions_a_to_d():
    """Roadmap Stage 5 needs the split: a dominant C means MaxRetracementBars is too
    tight, a dominant B means the structural reference is going stale unusually often."""
    f = Funnel()
    f.abandonment("A")
    f.abandonment("C")
    f.abandonment("C")
    assert f.abandonments == {"A": 1, "B": 0, "C": 2, "D": 0}


def test_unknown_abandonment_condition_is_rejected():
    """A typo'd condition letter would silently vanish from the breakdown that Stage 5
    reads to decide what to tune."""
    with pytest.raises(ValueError):
        Funnel().abandonment("E")


# ------------------------------------------- automated Definition-of-Done warnings


def test_zero_entries_warning_names_the_largest_consuming_gate():
    """The funnel's whole reason for existing: point at the gate, don't just report
    the zero."""
    f = Funnel()
    for _ in range(100):
        f.bar()
    for _ in range(90):
        f.reject(Gate.LOCATION)
    for _ in range(10):
        f.reject(Gate.SPREAD)

    warnings = f.warnings()
    assert any("zero entries" in w for w in warnings)
    assert any("Location reject" in w for w in warnings)


def test_long_only_entries_raise_the_direction_signing_warning():
    """Regression guard for finding B-1 at the run level. A healthy total with zero
    SHORT entries is the bug's signature; an undifferentiated total hides it."""
    f = Funnel()
    for _ in range(100):
        f.bar()
    for _ in range(20):
        f.entry(is_long=True)

    warnings = f.warnings()
    assert any("zero SHORT entries" in w for w in warnings)
    assert any("§12.1" in w for w in warnings)


def test_short_only_entries_raise_the_mirror_warning():
    f = Funnel()
    for _ in range(100):
        f.bar()
    for _ in range(20):
        f.entry(is_long=False)
    assert any("zero LONG entries" in w for w in f.warnings())


def test_a_balanced_run_raises_no_warnings():
    f = Funnel()
    for _ in range(1000):
        f.bar()
    for _ in range(400):
        f.reject(Gate.REGIME)
    for _ in range(300):
        f.reject(Gate.BOS_NOT_FOUND)
    for _ in range(30):
        f.entry(is_long=True)
    for _ in range(25):
        f.entry(is_long=False)
    for cond in ("A", "B", "C", "D"):
        f.abandonment(cond)
    assert f.warnings() == []


def test_a_dominant_abandonment_condition_is_flagged():
    f = Funnel()
    f.bar()
    f.entry(is_long=True)
    f.entry(is_long=False)
    for _ in range(95):
        f.abandonment("C")
    for _ in range(5):
        f.abandonment("A")
    assert any("condition C" in w for w in f.warnings())


def test_an_unrun_pipeline_is_reported_as_such():
    """Zero bars means the §36.1 guard never fired — a different problem from a gate
    eating candidates, and one a naive "zero entries" message would misattribute."""
    assert any("no bars evaluated" in w for w in Funnel().warnings())


# ------------------------------------------------------------- §36.1 bar guard


def test_bar_is_processed_exactly_once_however_many_ticks_arrive():
    guard = BarGuard()
    assert guard.should_process("EURUSD", "M5", 1000) is True
    for _ in range(50):
        assert guard.should_process("EURUSD", "M5", 1000) is False
    assert guard.should_process("EURUSD", "M5", 1300) is True
    assert guard.bars_processed == 2
    assert guard.ticks_seen == 52


def test_older_bars_do_not_reprocess():
    """A history refresh or a reconnect can replay older bars; re-firing the pipeline
    on them would duplicate entries and break reproducibility."""
    guard = BarGuard()
    assert guard.should_process("EURUSD", "M5", 2000) is True
    assert guard.should_process("EURUSD", "M5", 1700) is False
    assert guard.last_processed("EURUSD", "M5") == 2000


def test_guard_is_tracked_per_symbol_and_timeframe():
    """§36.1 keys on symbol+timeframe: the HTF and LTF series advance independently,
    and one must never suppress the other."""
    guard = BarGuard()
    assert guard.should_process("EURUSD", "M5", 1000) is True
    assert guard.should_process("EURUSD", "H1", 1000) is True
    assert guard.should_process("GBPUSD", "M5", 1000) is True
    assert guard.should_process("EURUSD", "M5", 1000) is False


def test_ticks_per_bar_is_the_stage_0_diagnostic():
    """Roadmap Stage 0 DoD: the ratio should be large (many ticks per bar), and the
    bar logic must fire exactly once per bar."""
    guard = BarGuard()
    for bar_time in (1000, 1300, 1600):
        for _ in range(10):
            guard.should_process("EURUSD", "M5", bar_time)
    assert guard.bars_processed == 3
    assert guard.ticks_per_bar == pytest.approx(10.0)


def test_ticks_per_bar_is_zero_before_any_bar_is_processed():
    assert BarGuard().ticks_per_bar == 0.0
