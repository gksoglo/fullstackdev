//+------------------------------------------------------------------+
//| Types.mqh — enums, POD structs and the cell-index algebra.        |
//|                                                                   |
//| Deliberately restricted to the MQL5/C++ common subset (no string, |
//| no MQL-only builtins) so tests/test_core_math.cpp can compile the |
//| real header against a shim instead of a transcription of it.      |
//| String mapping lives in Labels.mqh.                               |
//+------------------------------------------------------------------+
#ifndef RL_TYPES_MQH
#define RL_TYPES_MQH

//--- Undefined-metric sentinel. Never serialised: CsvLogger writes an
//--- empty field instead, so downstream consumers cannot mistake it for
//--- a real number (PRD §6.3).
#define RL_UNDEFINED  DBL_MAX

#define PATTERN_COUNT 12
#define SUBSET_COUNT  16                       // 2^4 momentum indicators
#define CELL_STRIDE   (SUBSET_COUNT * 2)       // subsets x {atr off, atr on}
#define CELL_COUNT    (PATTERN_COUNT * CELL_STRIDE)   // 384

//--- Indicator slots. These are ALSO the bit positions in subset_mask
//--- (bit0 = RSI ... bit3 = CCI), so vote[] indices and mask bits agree.
#define IND_RSI    0
#define IND_MACD   1
#define IND_STOCH  2
#define IND_CCI    3
#define IND_COUNT  4

enum PatternId
  {
   PAT_NONE = 0,               // reserved: keeps 0 as "no pattern"
   PAT_ENGULF_BULL,            // 1
   PAT_ENGULF_BEAR,
   PAT_HAMMER,
   PAT_SHOOTSTAR,
   PAT_MORNINGSTAR,
   PAT_EVENINGSTAR,
   PAT_PIERCING,
   PAT_DARKCLOUD,
   PAT_HARAMI_BULL,
   PAT_HARAMI_BEAR,
   PAT_TWEEZER_BOT,
   PAT_TWEEZER_TOP             // 12
  };

enum Direction   { DIR_BEAR = -1, DIR_NONE = 0, DIR_BULL = 1 };
enum Outcome     { OUT_OPEN = 0, OUT_CONFIRMED, OUT_FAILED, OUT_TIMEOUT };
enum ConfirmMode { CONFIRM_ALL = 0, CONFIRM_MAJORITY };

//--- Which clause produced a vote. Logged per indicator so a vote can be
//--- audited from one CSV row: every rule in PRD §5 is a two-bar rule, and
//--- a single row cannot otherwise show what happened at t-1.
enum VoteReason  { VR_NONE = 0, VR_LEVEL, VR_CROSS, VR_TURN };

//--- Why a signal never reached any cell. Counted ONCE per signal.
enum RejectReason
  {
   REJ_NONE = 0,
   REJ_NO_TREND,
   REJ_GAP,
   REJ_RISK_BOUNDS
  };

//+------------------------------------------------------------------+
//| Cell-index algebra.                                               |
//|                                                                   |
//| PAT_NONE owns 0, so the twelve patterns occupy enum values 1..12. |
//| Indexing an array on the raw enum reaches 12*32+31 = 415 against  |
//| 384 slots while leaving 0..31 dead. PatternIndex() is the only    |
//| conversion point; nothing else may cast a PatternId to an index.  |
//+------------------------------------------------------------------+
int PatternIndex(const PatternId p) { return (int)p - 1; }              // 0..11
PatternId PatternFromIndex(const int i) { return (PatternId)(i + 1); }

int CellId(const PatternId p, const int subset_mask, const bool atr_on)
  {
   return PatternIndex(p) * CELL_STRIDE + subset_mask * 2 + (atr_on ? 1 : 0);
  }

int  CellPatternIndex(const int cell_id) { return cell_id / CELL_STRIDE; }
int  CellSubsetMask  (const int cell_id) { return (cell_id % CELL_STRIDE) / 2; }
bool CellAtrOn       (const int cell_id) { return (cell_id % 2) == 1; }

int SubsetSize(const int mask)
  {
   int n = 0;
   for(int i = 0; i < IND_COUNT; i++)
      if((mask & (1 << i)) != 0)
         n++;
   return n;
  }

//+------------------------------------------------------------------+
//| Signal — phase 1 output (PRD §3).                                 |
//| Carries NO trade parameters: entry is the open of bar t+1, which  |
//| has not been read at detection time.                              |
//+------------------------------------------------------------------+
struct Signal
  {
   datetime  bar_time;         // close time of bar t
   int       bar_index;        // monotonic index of bar t, for overlap tracking
   PatternId pattern;
   Direction dir;
   int       bar_count;        // bars the pattern spans (1..3)
   double    atr;              // ATR(t)
   double    atr_sma;          // SMA(ATR,50), for the regime band
   double    pattern_range;    // high-low across the pattern, raw price
   double    pattern_extreme;  // low (bull) / high (bear) — the stop anchor
   bool      atr_filter_pass;  // verdict of the toggled ATR context filter

   void Clear()
     {
      bar_time = 0; bar_index = 0; pattern = PAT_NONE; dir = DIR_NONE;
      bar_count = 0; atr = 0.0; atr_sma = 0.0; pattern_range = 0.0;
      pattern_extreme = 0.0; atr_filter_pass = false;
     }
  };

//+------------------------------------------------------------------+
//| VoteVector — one momentum reading per indicator slot.             |
//+------------------------------------------------------------------+
struct VoteVector
  {
   int        vote[IND_COUNT];     // -1 / 0 / +1
   VoteReason reason[IND_COUNT];
   double     value[IND_COUNT];    // headline level, for the signal log

   void Clear()
     {
      for(int i = 0; i < IND_COUNT; i++)
        { vote[i] = 0; reason[i] = VR_NONE; value[i] = 0.0; }
     }

   //--- How many indicators IN THIS SUBSET agree with the signal's direction.
   int ConfirmCount(const Direction d, const int subset_mask) const
     {
      int n = 0;
      for(int i = 0; i < IND_COUNT; i++)
         if((subset_mask & (1 << i)) != 0 && vote[i] == (int)d && d != DIR_NONE)
            n++;
      return n;
     }

   //--- Admission. The empty subset is the control arm and always admits.
   //--- MAJORITY means strictly more than half, so ties reject; note this
   //--- differs from ALL only for the four triples and the quad.
   bool Admits(const Direction d, const int subset_mask, const ConfirmMode mode) const
     {
      const int size = SubsetSize(subset_mask);
      if(size == 0)
         return true;
      const int hits = ConfirmCount(d, subset_mask);
      if(mode == CONFIRM_ALL)
         return hits == size;
      return (hits * 2) > size;
     }
  };

//+------------------------------------------------------------------+
//| PendingSignal — phase 1 -> phase 2 hand-off.                      |
//| Lives in a local array inside the new-bar handler. NOT persistent |
//| state: both phases run in the same callback (PRD §3).             |
//+------------------------------------------------------------------+
struct PendingSignal
  {
   Signal     sig;
   VoteVector votes;
  };

//+------------------------------------------------------------------+
//| VirtualTrade — one simulated position in one cell.                |
//+------------------------------------------------------------------+
struct VirtualTrade
  {
   int       cell_id;
   datetime  entry_time;
   datetime  exit_time;
   int       entry_bar;         // monotonic bar index of the entry bar
   double    entry, stop, target, exit_price;
   double    risk;              // |entry - stop| — the R unit, in price
   double    atr;               // ATR(t) at detection
   double    risk_atr;          // risk / atr — converts between the two unit systems
   Direction dir;
   int       bars_held;         // entry bar counts as 1
   int       hold_bars;         // this trade's risk-scaled limit
   double    mfe_r,   mae_r;    // excursions in R   (primary)
   double    mfe_atr, mae_atr;  // excursions in ATR (cross-cell comparable)
   Outcome   outcome;
   double    r_multiple;        // net of cost
   bool      truncated;         // open at end of data -> logged, excluded from stats

   void Clear()
     {
      cell_id = -1; entry_time = 0; exit_time = 0; entry_bar = 0;
      entry = 0.0; stop = 0.0; target = 0.0; exit_price = 0.0;
      risk = 0.0; atr = 0.0; risk_atr = 0.0; dir = DIR_NONE;
      bars_held = 0; hold_bars = 0;
      mfe_r = 0.0; mae_r = 0.0; mfe_atr = 0.0; mae_atr = 0.0;
      outcome = OUT_OPEN; r_multiple = 0.0; truncated = false;
     }
  };

#endif // RL_TYPES_MQH
