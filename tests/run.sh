#!/usr/bin/env bash
# Compiles and runs the ReversalLab core-math tests.
#
# These exercise the SHIPPED headers via mql5_shim.h rather than a
# transcription of them, so they cover the parts of the design that are
# language-independent: the cell algebra, the overlap adjustment, the
# ranking key, and trade construction.
#
# They do NOT substitute for a MetaEditor compile. Anything touching
# indicator handles, file I/O or MqlRates is verified in the terminal.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/rl_tests"

g++ -std=c++17 -Wall -Wextra -Werror -o "$OUT" tests/test_core_math.cpp
"$OUT"
