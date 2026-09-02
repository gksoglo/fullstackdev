"""§36.1 bar-processed-once guard.

The pipeline must evaluate a completed bar exactly once, no matter how many ticks
arrive. Without this the same bar can produce several entry evaluations, and a
backtest stops being reproducible against a different tick model.
"""

from __future__ import annotations


class BarGuard:
    """Tracks the last fully-processed bar time per (symbol, timeframe).

    `should_process` returns True exactly once per strictly-newer bar. A bar time
    equal to or older than the last processed one is skipped — equal covers repeated
    ticks within the bar, older covers a history refresh or a reconnect replaying
    bars, which must not re-fire the pipeline.
    """

    def __init__(self) -> None:
        self._last: dict[tuple[str, str], int] = {}
        self.ticks_seen = 0
        self.bars_processed = 0

    def should_process(self, symbol: str, timeframe: str, bar_time: int) -> bool:
        self.ticks_seen += 1
        key = (symbol, timeframe)
        last = self._last.get(key)
        if last is not None and bar_time <= last:
            return False
        self._last[key] = bar_time
        self.bars_processed += 1
        return True

    def last_processed(self, symbol: str, timeframe: str) -> int | None:
        return self._last.get((symbol, timeframe))

    @property
    def ticks_per_bar(self) -> float:
        """Roadmap Stage 0 DoD: this ratio should be large (many ticks per bar)."""
        if self.bars_processed == 0:
            return 0.0
        return self.ticks_seen / self.bars_processed
