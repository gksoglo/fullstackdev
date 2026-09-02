"""Reference implementation of the HTF/LTF Trend-Continuation EA specification.

This package is the independent second implementation that PRD v0.7 §33 / roadmap
Stage 0 requires: the MQL5 EA's numbers are validated against these, on the same
historical data, to within floating-point tolerance.

Scope tracks the roadmap. Implemented: Stage 0 (math primitives, parameter
validation, funnel counter) and Stage 1 (swing detection).
"""

from .indicators import InsufficientData, wilder_atr, roc, efficiency_ratio, average_shadow
from .swings import Pivot, PivotKind, detect_swings, ConfirmedStructure
from .params import Params, ValidationError, validate
from .funnel import Funnel, Gate
from .barguard import BarGuard

__all__ = [
    "InsufficientData",
    "wilder_atr",
    "roc",
    "efficiency_ratio",
    "average_shadow",
    "Pivot",
    "PivotKind",
    "detect_swings",
    "ConfirmedStructure",
    "Params",
    "ValidationError",
    "validate",
    "Funnel",
    "Gate",
    "BarGuard",
]

PRD_VERSION = "0.7"
