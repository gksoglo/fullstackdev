//+------------------------------------------------------------------+
//| Swings.mqh — Stage 1 confirmed swing detection                    |
//| PRD v0.7 §4.1 (confirmed swing + tie-breaking), §4.2 (confirmed   |
//| structure, append-only)                                           |
//|                                                                   |
//| The tie-breaking rule is the whole point of this file. Equal highs |
//| and equal lows never qualify as pivots — not "earliest wins", not  |
//| "latest wins", neither bar. Two implementations picking different  |
//| tie-break conventions produce different pivots, different          |
//| protected levels and different trades from identical data, which   |
//| is exactly what the determinism objective forbids.                 |
//+------------------------------------------------------------------+
#property strict

#define HTFLTF_PIVOT_HIGH 1
#define HTFLTF_PIVOT_LOW  2

//+------------------------------------------------------------------+
//| A confirmed swing pivot.                                          |
//|                                                                   |
//| bar_index / bar_time / price locate the pivot bar itself.          |
//| confirmed_index is bar_index + K — the bar at whose close the      |
//| pivot becomes usable (§4.1). Downstream sequencing (protected      |
//| level replacement §6.1, abandonment condition B §10.5) must order  |
//| by confirmed_index, never bar_index, or it uses knowledge that did |
//| not exist yet at that point in the backtest.                       |
//+------------------------------------------------------------------+
struct HTFLTFPivot
{
   int      kind;             // HTFLTF_PIVOT_HIGH | HTFLTF_PIVOT_LOW
   int      bar_index;        // series index of the pivot bar
   datetime bar_time;
   double   price;
   int      confirmed_index;  // bar_index + K
};

//+------------------------------------------------------------------+
//| §4.1 swing high: strict inequality against all K bars on BOTH      |
//| sides. A single equal high anywhere in either window disqualifies  |
//| bar i outright — that is the tie-breaking rule, and the >= below   |
//| is where it lives.                                                 |
//|                                                                   |
//| Series-indexed: index 0 is the newest bar, so "before" and "after" |
//| in time are higher and lower indices respectively. The test is     |
//| symmetric, so the window is simply i-K .. i+K.                     |
//+------------------------------------------------------------------+
bool HTFLTF_IsSwingHigh(const double &high[], const int i, const int k)
{
   int n = ArraySize(high);
   if(i - k < 0 || i + k >= n)
      return false;                       // needs K bars on both sides

   double pivot = high[i];
   for(int j = i - k; j <= i + k; j++)
   {
      if(j == i)
         continue;
      if(high[j] >= pivot)                // >= : equality disqualifies (§4.1)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| §4.1 swing low. Mirror: <= disqualifies.                          |
//+------------------------------------------------------------------+
bool HTFLTF_IsSwingLow(const double &low[], const int i, const int k)
{
   int n = ArraySize(low);
   if(i - k < 0 || i + k >= n)
      return false;

   double pivot = low[i];
   for(int j = i - k; j <= i + k; j++)
   {
      if(j == i)
         continue;
      if(low[j] <= pivot)                 // <= : equality disqualifies (§4.1)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Classify one bar. A bar can be neither; it can never be both,      |
//| since being both would require it to be strictly above AND         |
//| strictly below its own neighbours.                                 |
//|                                                                   |
//| Returns 0 when the bar is not a pivot.                             |
//+------------------------------------------------------------------+
int HTFLTF_ClassifyPivot(const double &high[], const double &low[], const int i, const int k)
{
   if(HTFLTF_IsSwingHigh(high, i, k))
      return HTFLTF_PIVOT_HIGH;
   if(HTFLTF_IsSwingLow(low, i, k))
      return HTFLTF_PIVOT_LOW;
   return 0;
}

//+------------------------------------------------------------------+
//| Detect the pivot that has just become confirmed, if any.          |
//|                                                                   |
//| Called once per completed bar. Index 0 is the bar that just        |
//| closed, so the bar whose K-bar forward window has only now filled  |
//| is at index K. Checking only that bar — rather than rescanning     |
//| history — is what makes detection non-repainting: a pivot is       |
//| emitted exactly once, at the moment §4.1 says it becomes usable.   |
//+------------------------------------------------------------------+
bool HTFLTF_DetectNewPivot(const double &high[], const double &low[], const datetime &time[],
                           const int k, HTFLTFPivot &pivot_out)
{
   if(k < 1)
      return false;
   if(ArraySize(high) < 2 * k + 1)
      return false;

   int i = k;                             // the bar whose forward window just filled
   int kind = HTFLTF_ClassifyPivot(high, low, i, k);
   if(kind == 0)
      return false;

   pivot_out.kind = kind;
   pivot_out.bar_index = i;
   pivot_out.bar_time = time[i];
   pivot_out.price = (kind == HTFLTF_PIVOT_HIGH) ? high[i] : low[i];
   pivot_out.confirmed_index = 0;         // confirmed as of the bar that just closed
   return true;
}

//+------------------------------------------------------------------+
//| §4.2 confirmed structure — append-only.                           |
//|                                                                   |
//| "Never modified retroactively" is enforced here rather than left   |
//| to convention: Append rejects any pivot not strictly later than    |
//| the last stored one, so a caller that tries to rewrite history     |
//| fails loudly instead of quietly changing the backtest.             |
//+------------------------------------------------------------------+
class CHTFLTFStructure
{
private:
   HTFLTFPivot m_pivots[];

public:
   bool Append(const HTFLTFPivot &pivot)
   {
      int n = ArraySize(m_pivots);
      if(n > 0 && pivot.bar_time <= m_pivots[n - 1].bar_time)
      {
         PrintFormat("HTFLTF: rejected retroactive pivot at %s (last stored %s) — "
                     "confirmed structure is append-only (§4.2)",
                     TimeToString(pivot.bar_time), TimeToString(m_pivots[n - 1].bar_time));
         return false;
      }
      ArrayResize(m_pivots, n + 1);
      m_pivots[n] = pivot;
      return true;
   }

   int Count() const { return ArraySize(m_pivots); }

   //--- Most recent pivot of `kind`, or false if none exists.
   bool Last(const int kind, HTFLTFPivot &out) const
   {
      for(int i = ArraySize(m_pivots) - 1; i >= 0; i--)
      {
         if(m_pivots[i].kind == kind)
         {
            out = m_pivots[i];
            return true;
         }
      }
      return false;
   }

   //--- Most recent pivot of `kind` already confirmed at or before `as_of`.
   //--- This is the accessor the pipeline must use: reading Last() during a
   //--- backtest would let the strategy see a pivot K bars before it was
   //--- actually confirmed — lookahead bias that inflates every backtest metric
   //--- and vanishes in live trading.
   bool LastConfirmedBy(const int kind, const datetime as_of, HTFLTFPivot &out) const
   {
      for(int i = ArraySize(m_pivots) - 1; i >= 0; i--)
      {
         if(m_pivots[i].kind == kind && m_pivots[i].bar_time <= as_of)
         {
            out = m_pivots[i];
            return true;
         }
      }
      return false;
   }
};
