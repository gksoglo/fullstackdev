//+------------------------------------------------------------------+
//| Indicators.mqh — Stage 0 math primitives                          |
//| PRD v0.7 §37 (ATR), §12.4 (ROC), §12.1 (Directional_ROC),         |
//|          §7.1 (ER), §16.4 (Average_LTF_Shadow)                    |
//|                                                                   |
//| Every function refuses to produce a value from a partial window.   |
//| §37 and §7.1 both require an explicit insufficient-data result     |
//| rather than a partial sum: a silently-partial ATR or ER is the     |
//| "wrong-but-plausible number" failure that roadmap Stage 0 exists   |
//| to prevent.                                                       |
//|                                                                   |
//| Validated against reference/htfltf/indicators.py, per the Stage 0  |
//| Definition of Done.                                               |
//+------------------------------------------------------------------+
#property strict

// All series arguments below are MT5-indexed: index 0 is the MOST RECENT bar.
// Callers MUST pass series copied with ArraySetAsSeries(arr, true) and MUST NOT
// include the still-forming bar — §37 excludes it from every ATR used for a buffer
// (§35) or a normalization (§9.3, §19).

//+------------------------------------------------------------------+
//| §37 True Range. Needs the previous bar's close, which is why ATR   |
//| requires period+1 bars rather than period.                        |
//+------------------------------------------------------------------+
double HTFLTF_TrueRange(const double high, const double low, const double prev_close)
{
   double a = high - low;
   double b = MathAbs(high - prev_close);
   double c = MathAbs(low - prev_close);
   return MathMax(a, MathMax(b, c));
}

//+------------------------------------------------------------------+
//| §37 Wilder ATR — the standard MT5 iATR calculation.                |
//|                                                                   |
//| NOT a simple moving average of True Range. A simple MA reacts      |
//| roughly twice as fast, so every ATR-scaled buffer in §35 would be  |
//| systematically mis-sized in a way that still looks plausible on a  |
//| chart. This is implemented explicitly rather than delegated to     |
//| iATR so the EA's value is verifiable against the Python reference  |
//| bar for bar, which is what Stage 0's DoD asks for.                 |
//|                                                                   |
//| Returns false and leaves atr_out untouched on insufficient data.   |
//+------------------------------------------------------------------+
bool HTFLTF_WilderATR(const double &high[], const double &low[], const double &close[],
                      const int period, double &atr_out)
{
   if(period < 1)
      return false;

   int n = ArraySize(close);
   if(n < period + 1 || ArraySize(high) < n || ArraySize(low) < n)
      return false;

   // Series are newest-first; walk oldest-first so the recursion runs forward in time.
   // TR is defined for bars 0 .. n-2 (each needs the close of the bar before it,
   // which in series indexing is the HIGHER index).
   int tr_count = n - 1;

   // Seed: simple mean of the OLDEST `period` true ranges.
   double sum = 0.0;
   for(int k = 0; k < period; k++)
   {
      int i = tr_count - 1 - k;            // oldest TR first
      sum += HTFLTF_TrueRange(high[i], low[i], close[i + 1]);
   }
   double atr = sum / period;

   // Wilder recursion over the remaining, more recent true ranges.
   for(int i = tr_count - 1 - period; i >= 0; i--)
   {
      double tr = HTFLTF_TrueRange(high[i], low[i], close[i + 1]);
      atr = (atr * (period - 1) + tr) / period;
   }

   atr_out = atr;
   return true;
}

//+------------------------------------------------------------------+
//| §12.4 Rate of Change — close-to-close PERCENT return on the LTF.   |
//|                                                                   |
//|   ROC = (Close[0] - Close[period]) / Close[period] * 100          |
//|                                                                   |
//| Percent, not log return and not a points difference, so one        |
//| threshold value stays meaningful across instruments with different |
//| price scales.                                                      |
//|                                                                   |
//| Returns the RAW SIGNED value. Callers MUST apply the direction     |
//| signing in §12.1 before comparing against thresholds — see         |
//| HTFLTF_DirectionalROC.                                            |
//+------------------------------------------------------------------+
bool HTFLTF_ROC(const double &close[], const int period, double &roc_out)
{
   if(period < 1)
      return false;
   if(ArraySize(close) < period + 1)
      return false;

   double past = close[period];
   if(past == 0.0)
      return false;                        // percent return undefined; never divide

   roc_out = (close[0] - past) / past * 100.0;
   return true;
}

//+------------------------------------------------------------------+
//| §12.1 Direction-signed ROC.                                       |
//|                                                                   |
//| Long setups use +ROC, short setups use -ROC, so                    |
//| ROC_STRONG_THRESHOLD and ROC_NEGATIVE_THRESHOLD mean "momentum     |
//| with the trade" and "momentum against the trade" in BOTH           |
//| directions.                                                        |
//|                                                                   |
//| PRD v0.6 omitted this step and classified shorts on raw signed     |
//| ROC. A healthy bearish impulse therefore scored NEGATIVE -> REJECT |
//| — the stronger the move in the trade's favour, the more certain    |
//| the rejection — while a short entering a rally scored STRONG and   |
//| received the LARGER risk allocation. Review finding B-1; it        |
//| rejected essentially every short entry with no symptom beyond a    |
//| momentum_reject count that merely looked high.                     |
//+------------------------------------------------------------------+
double HTFLTF_DirectionalROC(const double raw_roc, const bool is_long)
{
   return is_long ? raw_roc : -raw_roc;
}

//+------------------------------------------------------------------+
//| §7.1 Efficiency Ratio, CLOSE prices only (not median, not typical).|
//|                                                                   |
//|   ER = |Close[0] - Close[N]| / sum(i=1..N) |Close[i-1] - Close[i]| |
//|                                                                   |
//| Zero-denominator rule: a window whose closes are all identical has |
//| a denominator of exactly 0. ER is then 0.0, which classifies       |
//| CHOPPY — the correct reading of "no movement at all".              |
//|                                                                   |
//| v0.6 divided unconditionally, producing inf/nan. nan compares      |
//| false against BOTH ER_HIGH and ER_LOW, so the symbol silently      |
//| landed in the ambiguous band with the regime decided entirely by   |
//| ADX and nothing in the log saying why. Review finding B-3.         |
//+------------------------------------------------------------------+
bool HTFLTF_EfficiencyRatio(const double &close[], const int lookback, double &er_out)
{
   if(lookback < 2)                        // §38 rejects this at startup too
      return false;
   if(ArraySize(close) < lookback + 1)
      return false;

   double net = MathAbs(close[0] - close[lookback]);

   double path = 0.0;
   for(int i = 0; i < lookback; i++)
      path += MathAbs(close[i] - close[i + 1]);

   if(path == 0.0)
   {
      er_out = 0.0;                        // flat window -> CHOPPY, never a division
      return true;
   }

   er_out = net / path;
   return true;
}

//+------------------------------------------------------------------+
//| §16.4 Average_LTF_Shadow — mean shadow on the side the trade       |
//| trails from, over the last `lookback` COMPLETED LTF bars.          |
//|                                                                   |
//|   long  (trails from highs): upper = High - max(Open, Close)      |
//|   short (trails from lows):  lower = min(Open, Close) - Low       |
//|                                                                   |
//| v0.6 used this term in the trailing formula without defining the   |
//| side, the lookback, the timeframe, or the completed-bars rule —    |
//| four free choices, each changing every trailing exit price.        |
//| Review finding B-6.                                                |
//+------------------------------------------------------------------+
bool HTFLTF_AverageShadow(const double &open[], const double &high[],
                          const double &low[], const double &close[],
                          const int lookback, const bool is_long, double &avg_out)
{
   if(lookback < 1)
      return false;

   int n = ArraySize(close);
   if(n < lookback || ArraySize(open) < lookback ||
      ArraySize(high) < lookback || ArraySize(low) < lookback)
      return false;

   double total = 0.0;
   for(int i = 0; i < lookback; i++)
   {
      double body_top = MathMax(open[i], close[i]);
      double body_bottom = MathMin(open[i], close[i]);
      total += is_long ? (high[i] - body_top) : (body_bottom - low[i]);
   }

   avg_out = total / lookback;
   return true;
}
