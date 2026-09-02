//+------------------------------------------------------------------+
//| BarGuard.mqh — §36.1 bar-processed-once guard                     |
//|                                                                   |
//| The pipeline must evaluate a completed bar exactly once, however   |
//| many ticks arrive. Without this the same bar can produce several   |
//| entry evaluations, and a backtest stops being reproducible against |
//| a different tick model.                                            |
//+------------------------------------------------------------------+
#property strict

class CHTFLTFBarGuard
{
private:
   datetime m_last;        // last fully-processed bar time
   long     m_ticks;       // diagnostic: OnTick calls seen
   long     m_bars;        // diagnostic: bars actually processed

public:
   CHTFLTFBarGuard() { m_last = 0; m_ticks = 0; m_bars = 0; }

   //--- True exactly once per strictly-newer bar.
   //--- A bar time equal to or older than the last processed one is skipped:
   //--- equal covers repeated ticks within the bar, older covers a history
   //--- refresh or a reconnect replaying bars, which must not re-fire the
   //--- pipeline and duplicate entries.
   bool ShouldProcess(const datetime bar_time)
   {
      m_ticks++;
      if(m_last != 0 && bar_time <= m_last)
         return false;
      m_last = bar_time;
      m_bars++;
      return true;
   }

   datetime LastProcessed() const { return m_last; }
   long     TicksSeen()     const { return m_ticks; }
   long     BarsProcessed() const { return m_bars; }

   //--- Roadmap Stage 0 DoD: this ratio should be large (many ticks per bar),
   //--- and the bar logic must fire exactly once per bar.
   double TicksPerBar() const
   {
      if(m_bars == 0)
         return 0.0;
      return (double)m_ticks / (double)m_bars;
   }
};
