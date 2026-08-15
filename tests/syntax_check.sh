#!/usr/bin/env bash
# Type-checks the ENTIRE ReversalLab tree, including the files the unit
# tests cannot reach (IndicatorHub, VirtualBook, Tally, CsvLogger,
# LiveExecutor and the EA itself).
#
# It transpiles the MQL5 sources (see tests/transpile.py — five mechanical
# syntax rewrites, no logic changes) and compiles each translation unit
# against tests/mql5_compat.h.
#
# WHAT THIS CATCHES: typos, unknown members, wrong argument counts and
# types, missing returns, bad enum use, unresolved names — the bulk of
# what a first MetaEditor compile would report.
#
# WHAT IT CANNOT CATCH, because C++ does not share the rule:
#   * MQL5 rejects some implicit narrowing that C++ permits
#   * `const` member-function strictness differs
#   * MQL5-specific limits (struct copy semantics, pointer rules)
#   * anything about the real iATR/iMACD/CopyBuffer contracts
#
# MetaEditor remains the authority. This is a fast pre-filter, not a
# substitute.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD="${TMPDIR:-/tmp}/rl_build"

python3 tests/transpile.py "$BUILD"

FLAGS=(-std=c++17 -fsyntax-only -x c++ -I "$BUILD/Include" -include tests/mql5_compat.h
       -Wall -Wextra -Wno-unused-parameter -Wno-unused-const-variable)

fail=0

# Each header on its own, so an error is attributed to one file.
check() {
   local f="$1" label="$2"
   if g++ "${FLAGS[@]}" "$f" 2> "$BUILD/err.txt"; then
      printf '  ok    %s\n' "$label"
   else
      printf '  FAIL  %s\n' "$label"
      sed "s|$BUILD|<build>|g" "$BUILD/err.txt"
      fail=1
   fi
}

while IFS= read -r f; do
   check "$f" "${f#$BUILD/}"
done < <(find "$BUILD/Include" -name '*.mqh' | sort)

# The EA last: it pulls in the whole tree at once.
check "$BUILD/Experts/ReversalLab/ReversalLab.mq5" "Experts/ReversalLab/ReversalLab.mq5"

if [ "$fail" -eq 0 ]; then
   echo "syntax check passed"
else
   echo "syntax check FAILED"
fi
exit "$fail"
