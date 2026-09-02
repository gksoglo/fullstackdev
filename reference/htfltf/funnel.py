"""The Signal Funnel Counter — the roadmap's cross-cutting diagnostic.

Every evaluated bar increments exactly one counter, attributed to the FIRST gate that
rejects it, in PRD §22.2's normative order. If `entries_taken` is zero, the funnel
says which gate consumed 100% of candidates instead of leaving it to a guess.

Two things here come from the v0.7 review:

  * gate order follows §22.2, which is now the single normative ordering. v0.6's §23
    listed the first six gates in a different order, so the funnel's attribution
    depended on which section the implementer followed (finding M-1); and
  * entries are counted per direction. A healthy total with zero SHORT entries is the
    exact signature of the momentum direction-signing bug (finding B-1), and an
    undifferentiated total hides it completely.
"""

from __future__ import annotations

from enum import Enum


class Gate(Enum):
    """Pipeline gates in §22.2 order. Enum order IS the pipeline order and the print
    order; keep them in step when adding a gate."""

    POSITION_OPEN = "position_open"              # §22.2 step 0a — managed, not rejected
    SAME_BAR_CLOSE = "same_bar_close"            # §22.2 step 0b (§22.3)
    SESSION = "session"                          # step 1  (§18.1)
    SPREAD = "spread"                            # step 2  (§19)
    DAILY_RISK = "daily_risk"                    # step 3  (§17.1)
    COOLDOWN = "cooldown"                        # step 4  (§17.3)
    STRUCTURE = "structure"                      # step 6  (§5, frozen per §4.4)
    REGIME = "regime"                            # step 7  (§7.2)
    SETUP_NOT_FOUND = "setup_not_found"          # step 9  (§10.1/§10.2)
    LOCATION = "location"                        # step 10 (§9.3)
    BOS_NOT_FOUND = "bos_not_found"              # step 11 (§11.1/§11.2)
    BREAK_DISTANCE = "break_distance"            # step 12 (§11.3)
    MOMENTUM = "momentum"                        # step 13 (§12.1)
    POSITION_SIZE = "position_size"              # step 15 (§15)
    EXECUTION = "execution"                      # step 15 (§14, §36.2)


# Human-readable labels for the printed funnel, in Gate order.
_LABELS: dict[Gate, str] = {
    Gate.POSITION_OPEN: "Position open (managed)",
    Gate.SAME_BAR_CLOSE: "Same-bar close (§22.3)",
    Gate.SESSION: "Session reject",
    Gate.SPREAD: "Spread reject",
    Gate.DAILY_RISK: "Daily-risk reject",
    Gate.COOLDOWN: "Cooldown reject",
    Gate.STRUCTURE: "Structure reject (not BULLISH/BEARISH)",
    Gate.REGIME: "Regime reject (CHOPPY)",
    Gate.SETUP_NOT_FOUND: "Setup not found",
    Gate.LOCATION: "Location reject",
    Gate.BOS_NOT_FOUND: "BOS not found",
    Gate.BREAK_DISTANCE: "Break-distance reject",
    Gate.MOMENTUM: "Momentum reject (NEGATIVE)",
    Gate.POSITION_SIZE: "Position-size reject",
    Gate.EXECUTION: "Execution/slippage reject",
}


class Funnel:
    """Per-run funnel counters. One instance per backtest run."""

    def __init__(self) -> None:
        self.bars_evaluated = 0
        self.rejects: dict[Gate, int] = {g: 0 for g in Gate}
        self.entries_long = 0
        self.entries_short = 0
        # §10.5 abandonment breakdown, keyed by condition letter A-D. Roadmap Stage 5
        # requires this split: C dominating means MaxRetracementBars is too tight,
        # B dominating means the structural reference is going stale unusually often.
        self.abandonments: dict[str, int] = {"A": 0, "B": 0, "C": 0, "D": 0}

    def bar(self) -> None:
        self.bars_evaluated += 1

    def reject(self, gate: Gate) -> None:
        self.rejects[gate] += 1

    def entry(self, is_long: bool) -> None:
        if is_long:
            self.entries_long += 1
        else:
            self.entries_short += 1

    def abandonment(self, condition: str) -> None:
        if condition not in self.abandonments:
            raise ValueError(f"unknown §10.5 abandonment condition {condition!r}; expected A-D")
        self.abandonments[condition] += 1

    @property
    def entries_taken(self) -> int:
        return self.entries_long + self.entries_short

    def report(self) -> str:
        width = max(len(label) for label in _LABELS.values()) + 2
        lines = [f"{'Bars evaluated:':<{width}}{self.bars_evaluated:>9,}"]
        for gate in Gate:
            lines.append(f"{_LABELS[gate] + ':':<{width}}{self.rejects[gate]:>9,}")
        lines.append(f"{'Entries taken:':<{width}}{self.entries_taken:>9,}")
        lines.append(f"{'   of which LONG:':<{width}}{self.entries_long:>9,}")
        lines.append(f"{'   of which SHORT:':<{width}}{self.entries_short:>9,}")
        lines.append("")
        lines.append("Abandonment (§10.5) by condition:")
        for cond, label in (
            ("A", "A structural invalidation"),
            ("B", "B new high/low before BOS"),
            ("C", "C timeout"),
            ("D", "D HTF state change"),
        ):
            lines.append(f"{'  ' + label + ':':<{width}}{self.abandonments[cond]:>9,}")
        return "\n".join(lines)

    def warnings(self) -> list[str]:
        """Automated versions of the roadmap's "flag immediately if…" checks.

        These are the assertions each stage's Definition of Done asks a human to make
        by eye; running them every backtest means a regression is caught on the run
        that introduced it rather than at the next manual review.
        """
        out: list[str] = []
        if self.bars_evaluated == 0:
            return ["funnel: no bars evaluated — the bar-processed-once guard (§36.1) may never fire"]

        if self.entries_taken == 0:
            worst = max(self.rejects.items(), key=lambda kv: kv[1])
            if worst[1] > 0:
                out.append(
                    f"funnel: zero entries — largest consumer is {_LABELS[worst[0]]} "
                    f"({worst[1]:,} bars). Investigate that gate first."
                )
            else:
                out.append("funnel: zero entries and zero rejects — the pipeline is not running")
        elif self.entries_long > 0 and self.entries_short == 0:
            # Direct regression guard for finding B-1.
            out.append(
                "funnel: LONG entries present but zero SHORT entries. If the test window "
                "spans both market directions this is the signature of momentum "
                "direction-signing being dropped (§12.1) — check the Stage 7 tier split "
                "by direction before tuning anything."
            )
        elif self.entries_short > 0 and self.entries_long == 0:
            out.append(
                "funnel: SHORT entries present but zero LONG entries — mirror of the "
                "§12.1 direction-signing check; verify against the Stage 7 tier split."
            )

        total_abandon = sum(self.abandonments.values())
        if total_abandon > 0:
            for cond, count in self.abandonments.items():
                if count / total_abandon > 0.8:
                    out.append(
                        f"funnel: §10.5 condition {cond} accounts for {count / total_abandon:.0%} "
                        "of abandonments — see roadmap Stage 5 on what a dominant condition implies"
                    )
        return out
