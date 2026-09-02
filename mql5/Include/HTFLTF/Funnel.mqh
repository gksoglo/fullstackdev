//+------------------------------------------------------------------+
//| Funnel.mqh — the Signal Funnel Counter                            |
//|                                                                   |
//| The roadmap's cross-cutting diagnostic and the direct fix for      |
//| "zero trades, cause couldn't be pinned down". Every evaluated bar  |
//| increments exactly one counter, attributed to the FIRST gate that  |
//| rejects it, in PRD §22.2's normative order. If entries are zero,   |
//| the funnel says which gate consumed 100% of candidates instead of  |
//| leaving it to a guess.                                             |
//|                                                                   |
//| Build it in Stage 4 and never remove it, even in the final version.|
//|                                                                   |
//| Two things here come from the v0.7 review:                         |
//|   * gate order follows §22.2, now the single normative ordering.   |
//|     v0.6's §23 listed the first six gates differently, so funnel   |
//|     attribution depended on which section you implemented (M-1);   |
//|   * entries are counted per direction. A healthy total with zero   |
//|     SHORT entries is the signature of the §12.1 direction-signing  |
//|     bug (B-1), and an undifferentiated total hides it completely.  |
//+------------------------------------------------------------------+
#property strict

//--- Gate order IS the pipeline order and the print order (§22.2).
//--- Keep them in step when adding a gate.
enum ENUM_HTFLTF_GATE
{
   HTFLTF_GATE_POSITION_OPEN = 0,   // §22.2 step 0a — managed, not rejected
   HTFLTF_GATE_SAME_BAR_CLOSE,      // step 0b (§22.3)
   HTFLTF_GATE_SESSION,             // step 1  (§18.1)
   HTFLTF_GATE_SPREAD,              // step 2  (§19)
   HTFLTF_GATE_DAILY_RISK,          // step 3  (§17.1)
   HTFLTF_GATE_COOLDOWN,            // step 4  (§17.3)
   HTFLTF_GATE_STRUCTURE,           // step 6  (§5, frozen per §4.4)
   HTFLTF_GATE_REGIME,              // step 7  (§7.2)
   HTFLTF_GATE_SETUP_NOT_FOUND,     // step 9  (§10.1/§10.2)
   HTFLTF_GATE_LOCATION,            // step 10 (§9.3)
   HTFLTF_GATE_BOS_NOT_FOUND,       // step 11 (§11.1/§11.2)
   HTFLTF_GATE_BREAK_DISTANCE,      // step 12 (§11.3)
   HTFLTF_GATE_MOMENTUM,            // step 13 (§12.1)
   HTFLTF_GATE_POSITION_SIZE,       // step 15 (§15)
   HTFLTF_GATE_EXECUTION,           // step 15 (§14, §36.2)
   HTFLTF_GATE_COUNT
};

string HTFLTF_GateLabel(const int gate)
{
   switch(gate)
   {
      case HTFLTF_GATE_POSITION_OPEN:   return "Position open (managed)";
      case HTFLTF_GATE_SAME_BAR_CLOSE:  return "Same-bar close (§22.3)";
      case HTFLTF_GATE_SESSION:         return "Session reject";
      case HTFLTF_GATE_SPREAD:          return "Spread reject";
      case HTFLTF_GATE_DAILY_RISK:      return "Daily-risk reject";
      case HTFLTF_GATE_COOLDOWN:        return "Cooldown reject";
      case HTFLTF_GATE_STRUCTURE:       return "Structure reject (not BULLISH/BEARISH)";
      case HTFLTF_GATE_REGIME:          return "Regime reject (CHOPPY)";
      case HTFLTF_GATE_SETUP_NOT_FOUND: return "Setup not found";
      case HTFLTF_GATE_LOCATION:        return "Location reject";
      case HTFLTF_GATE_BOS_NOT_FOUND:   return "BOS not found";
      case HTFLTF_GATE_BREAK_DISTANCE:  return "Break-distance reject";
      case HTFLTF_GATE_MOMENTUM:        return "Momentum reject (NEGATIVE)";
      case HTFLTF_GATE_POSITION_SIZE:   return "Position-size reject";
      case HTFLTF_GATE_EXECUTION:       return "Execution/slippage reject";
   }
   return "Unknown gate";
}

class CHTFLTFFunnel
{
private:
   long m_bars;
   long m_rejects[HTFLTF_GATE_COUNT];
   long m_entries_long;
   long m_entries_short;
   long m_abandon[4];          // §10.5 conditions A..D

public:
   CHTFLTFFunnel() { Reset(); }

   void Reset()
   {
      m_bars = 0;
      m_entries_long = 0;
      m_entries_short = 0;
      ArrayInitialize(m_rejects, 0);
      ArrayInitialize(m_abandon, 0);
   }

   void Bar()                        { m_bars++; }
   void Reject(const int gate)       { if(gate >= 0 && gate < HTFLTF_GATE_COUNT) m_rejects[gate]++; }
   void Entry(const bool is_long)    { if(is_long) m_entries_long++; else m_entries_short++; }

   //--- §10.5 abandonment breakdown, condition index 0..3 for A..D.
   //--- Roadmap Stage 5 requires this split: a dominant C means
   //--- MaxRetracementBars is too tight, a dominant B means the structural
   //--- reference is going stale unusually often.
   void Abandonment(const int condition)
   { if(condition >= 0 && condition < 4) m_abandon[condition]++; }

   long EntriesTaken() const { return m_entries_long + m_entries_short; }

   void PrintReport() const
   {
      Print("===== HTF/LTF Signal Funnel =====");
      PrintFormat("%-40s %10d", "Bars evaluated:", m_bars);
      for(int g = 0; g < HTFLTF_GATE_COUNT; g++)
         PrintFormat("%-40s %10d", HTFLTF_GateLabel(g) + ":", m_rejects[g]);
      PrintFormat("%-40s %10d", "Entries taken:", EntriesTaken());
      PrintFormat("%-40s %10d", "   of which LONG:", m_entries_long);
      PrintFormat("%-40s %10d", "   of which SHORT:", m_entries_short);
      Print("--- Abandonment (§10.5) by condition ---");
      PrintFormat("%-40s %10d", "  A structural invalidation:", m_abandon[0]);
      PrintFormat("%-40s %10d", "  B new high/low before BOS:", m_abandon[1]);
      PrintFormat("%-40s %10d", "  C timeout:", m_abandon[2]);
      PrintFormat("%-40s %10d", "  D HTF state change:", m_abandon[3]);
      PrintWarnings();
   }

   //--- Automated versions of the roadmap's "flag immediately if..." checks.
   //--- These are the assertions each stage's Definition of Done asks a human to
   //--- make by eye; running them every backtest means a regression is caught on
   //--- the run that introduced it, not at the next manual review.
   void PrintWarnings() const
   {
      if(m_bars == 0)
      {
         Print("WARNING funnel: no bars evaluated — the §36.1 bar guard may never fire");
         return;
      }

      if(EntriesTaken() == 0)
      {
         int worst = -1;
         long worst_count = 0;
         for(int g = 0; g < HTFLTF_GATE_COUNT; g++)
            if(m_rejects[g] > worst_count) { worst_count = m_rejects[g]; worst = g; }

         if(worst >= 0)
            PrintFormat("WARNING funnel: zero entries — largest consumer is %s (%d bars). "
                        "Investigate that gate first.", HTFLTF_GateLabel(worst), worst_count);
         else
            Print("WARNING funnel: zero entries and zero rejects — the pipeline is not running");
      }
      else if(m_entries_long > 0 && m_entries_short == 0)
      {
         // Direct regression guard for review finding B-1.
         Print("WARNING funnel: LONG entries present but zero SHORT entries. If the test "
               "window spans both market directions this is the signature of momentum "
               "direction-signing being dropped (§12.1) — check the Stage 7 tier split by "
               "direction before tuning anything.");
      }
      else if(m_entries_short > 0 && m_entries_long == 0)
      {
         Print("WARNING funnel: SHORT entries present but zero LONG entries — mirror of the "
               "§12.1 direction-signing check; verify against the Stage 7 tier split.");
      }

      long total_abandon = m_abandon[0] + m_abandon[1] + m_abandon[2] + m_abandon[3];
      if(total_abandon > 0)
      {
         string letters = "ABCD";
         for(int i = 0; i < 4; i++)
            if((double)m_abandon[i] / (double)total_abandon > 0.8)
               PrintFormat("WARNING funnel: §10.5 condition %s accounts for %.0f%% of "
                           "abandonments — see roadmap Stage 5 on what a dominant condition implies",
                           StringSubstr(letters, i, 1),
                           100.0 * m_abandon[i] / total_abandon);
      }
   }
};
