//+------------------------------------------------------------------+
//| mql5_compat.h — a stand-in for the MQL5 runtime, wide enough to    |
//| type-check the whole ReversalLab tree with a C++ compiler.         |
//|                                                                    |
//| This is NOT an emulator: the builtins below return dummy values and |
//| are never executed. Its only job is to let the compiler parse the   |
//| sources and check types, arities and member names across every      |
//| file — including the ones the unit tests cannot reach because they  |
//| touch indicator handles or file I/O.                                |
//|                                                                    |
//| It cannot catch MQL5-specific rules a C++ compiler does not share   |
//| (see tests/syntax_check.sh for the list). MetaEditor remains the    |
//| authority.                                                          |
//+------------------------------------------------------------------+
#pragma once

#include "mql5_shim.h"

#include <string>
#include <vector>
#include <algorithm>

//--- MQL5 `string` is a value type with += and comparison; std::string
//--- matches closely enough for a type check.
typedef std::string string;

//--- MQL5 dynamic arrays. The transpiler rewrites `T name[]` to this so
//--- ArrayResize/ArraySize have something with real semantics.
template<class T> using MqlArray = std::vector<T>;

//------------------------------------------------------------------
// Array builtins
//------------------------------------------------------------------
template<class T> int  ArrayResize(MqlArray<T> &a, int n) { a.resize((size_t)n); return n; }
template<class T> int  ArraySize(const MqlArray<T> &a)    { return (int)a.size(); }
template<class T, size_t N> int ArraySize(const T (&)[N]) { return (int)N; }
template<class T> bool ArraySetAsSeries(MqlArray<T> &, bool) { return true; }

template<class T, size_t N> int ArrayInitialize(T (&a)[N], T v)
  { for(size_t i = 0; i < N; ++i) a[i] = v; return (int)N; }
template<class T> int ArrayInitialize(MqlArray<T> &a, T v)
  { std::fill(a.begin(), a.end(), v); return (int)a.size(); }

//------------------------------------------------------------------
// Timeframes, price/line constants, handles
//------------------------------------------------------------------
typedef int ENUM_TIMEFRAMES;
const ENUM_TIMEFRAMES PERIOD_M15 = 15, PERIOD_H1 = 60, PERIOD_D1 = 1440;

const int INVALID_HANDLE = -1;
const int MODE_SMA = 0;
const int PRICE_CLOSE = 1, PRICE_TYPICAL = 2;
const int MAIN_LINE = 0, SIGNAL_LINE = 1;
const int STO_LOWHIGH = 0;

const int INIT_SUCCEEDED = 0, INIT_FAILED = 1, INIT_PARAMETERS_INCORRECT = 2;
const int FILE_WRITE = 1, FILE_CSV = 2, FILE_ANSI = 4;
const int TIME_DATE = 1, TIME_MINUTES = 2, TIME_SECONDS = 4;

inline string _Symbol_impl() { return "TESTSYM"; }
static const string _Symbol = "TESTSYM";
static const double _Point  = 0.00001;
static const int    _Period = PERIOD_H1;

//------------------------------------------------------------------
// Indicator + price builtins
//------------------------------------------------------------------
inline int iATR(string, ENUM_TIMEFRAMES, int) { return 1; }
inline int iMA(string, ENUM_TIMEFRAMES, int, int, int, int) { return 1; }
inline int iRSI(string, ENUM_TIMEFRAMES, int, int) { return 1; }
inline int iMACD(string, ENUM_TIMEFRAMES, int, int, int, int) { return 1; }
inline int iStochastic(string, ENUM_TIMEFRAMES, int, int, int, int, int) { return 1; }
inline int iCCI(string, ENUM_TIMEFRAMES, int, int) { return 1; }
inline bool IndicatorRelease(int) { return true; }

inline int CopyBuffer(int, int, int, int count, MqlArray<double> &dest)
  { dest.assign((size_t)count, 0.0); return count; }
inline int CopyRates(string, ENUM_TIMEFRAMES, int, int count, MqlArray<MqlRates> &dest)
  { dest.assign((size_t)count, MqlRates{}); return count; }

inline datetime iTime (string, ENUM_TIMEFRAMES, int) { return 0; }
inline double   iOpen (string, ENUM_TIMEFRAMES, int) { return 0.0; }
inline double   iHigh (string, ENUM_TIMEFRAMES, int) { return 0.0; }
inline double   iLow  (string, ENUM_TIMEFRAMES, int) { return 0.0; }
inline double   iClose(string, ENUM_TIMEFRAMES, int) { return 0.0; }
inline int      Bars  (string, ENUM_TIMEFRAMES)      { return 100000; }

//------------------------------------------------------------------
// File, print and conversion builtins
//------------------------------------------------------------------
inline int  FileOpen(string, int, char) { return 1; }
inline void FileClose(int) {}
template<class... A> void FileWrite(int, A&&...) {}

template<class... A> void Print(A&&...) {}
template<class... A> void PrintFormat(const char *, A&&...) {}
template<class... A> string StringFormat(const char *, A&&...) { return string(); }

inline int    StringLen(const string &s) { return (int)s.size(); }
inline string DoubleToString(double, int = 8) { return string(); }
inline string IntegerToString(long) { return string(); }
inline string TimeToString(datetime, int = 0) { return string(); }
template<class T> string EnumToString(T) { return string(); }

inline bool MathIsValidNumber(double v) { return std::isfinite(v); }
inline bool PositionSelect(const string &) { return false; }
inline int  GetLastError() { return 0; }
