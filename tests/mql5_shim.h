//+------------------------------------------------------------------+
//| mql5_shim.h — enough of the MQL5 runtime to compile the pure-math  |
//| ReversalLab headers with a C++ compiler.                           |
//|                                                                    |
//| This exists so the tests exercise the SHIPPED headers rather than a |
//| transcription of them. Headers that need string handling, indicator |
//| handles or file I/O are deliberately out of scope — those are       |
//| verified in MetaEditor and the Strategy Tester.                     |
//+------------------------------------------------------------------+
#pragma once

#include <cmath>
#include <cfloat>
#include <cstdint>

typedef int64_t datetime;

inline double MathSqrt(double x)  { return std::sqrt(x); }
inline double MathAbs(double x)   { return std::fabs(x); }
inline double MathRound(double x) { return std::floor(x + 0.5); }
inline double MathMax(double a, double b) { return a > b ? a : b; }
inline double MathMin(double a, double b) { return a < b ? a : b; }
