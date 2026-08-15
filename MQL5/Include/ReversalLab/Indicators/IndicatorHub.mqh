//+------------------------------------------------------------------+
//| IndicatorHub.mqh — handle lifecycle and buffer reads.              |
//|                                                                    |
//| Non-repainting discipline: every read uses shift >= 1. Index 0 is   |
//| the forming bar and must never enter a vote or a detection.         |
//+------------------------------------------------------------------+
#ifndef RL_INDICATORHUB_MQH
#define RL_INDICATORHUB_MQH

#include "../Types.mqh"
#include "../Config.mqh"
#include "Voters.mqh"           // also defines RL_VOTE_WINDOW

class CIndicatorHub
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   RLConfig        m_cfg;

   int             m_h_atr;
   int             m_h_atr_sma;      // SMA of the ATR handle, for the regime band
   int             m_h_rsi;
   int             m_h_macd;
   int             m_h_stoch;
   int             m_h_cci;

   //--- Secondary series cached by ReadVotes for the signal log. Declared
   //--- up here rather than after the methods that touch them: MQL5 is not
   //--- reliable about members used before their declaration point.
   double          m_last_macd_main;
   double          m_last_macd_sig;
   double          m_last_stoch_d;

   //--- Copy `count` values ending at `shift`, newest first.
   bool ReadBuf(const int handle, const int buffer, const int shift,
                const int count, double &dest[]) const
     {
      ArrayResize(dest, count);
      ArraySetAsSeries(dest, true);
      return CopyBuffer(handle, buffer, shift, count, dest) == count;
     }

   //--- Read one indicator into a 3-bar vote window.
   bool ReadSeries(const int handle, const int buffer, const int shift,
                   SeriesWindow &s) const
     {
      double tmp[];
      if(!ReadBuf(handle, buffer, shift, RL_VOTE_WINDOW, tmp))
         return false;
      s.Set(tmp[0], tmp[1], tmp[2]);
      return true;
     }

public:
   CIndicatorHub() : m_h_atr(INVALID_HANDLE), m_h_atr_sma(INVALID_HANDLE),
                     m_h_rsi(INVALID_HANDLE), m_h_macd(INVALID_HANDLE),
                     m_h_stoch(INVALID_HANDLE), m_h_cci(INVALID_HANDLE) {}

   bool Init(const string symbol, const ENUM_TIMEFRAMES tf, const RLConfig &cfg)
     {
      m_symbol = symbol;
      m_tf     = tf;
      m_cfg    = cfg;

      m_h_atr = iATR(symbol, tf, cfg.atr_period);
      if(m_h_atr == INVALID_HANDLE) return false;

      //--- SMA applied to the ATR handle rather than to price.
      m_h_atr_sma = iMA(symbol, tf, cfg.atr_sma_period, 0, MODE_SMA, m_h_atr);
      if(m_h_atr_sma == INVALID_HANDLE) return false;

      m_h_rsi = iRSI(symbol, tf, cfg.rsi_period, PRICE_CLOSE);
      if(m_h_rsi == INVALID_HANDLE) return false;

      m_h_macd = iMACD(symbol, tf, cfg.macd_fast, cfg.macd_slow,
                       cfg.macd_signal, PRICE_CLOSE);
      if(m_h_macd == INVALID_HANDLE) return false;

      m_h_stoch = iStochastic(symbol, tf, cfg.stoch_k, cfg.stoch_d,
                              cfg.stoch_slow, MODE_SMA, STO_LOWHIGH);
      if(m_h_stoch == INVALID_HANDLE) return false;

      m_h_cci = iCCI(symbol, tf, cfg.cci_period, PRICE_TYPICAL);
      if(m_h_cci == INVALID_HANDLE) return false;

      return true;
     }

   void Deinit()
     {
      if(m_h_atr     != INVALID_HANDLE) IndicatorRelease(m_h_atr);
      if(m_h_atr_sma != INVALID_HANDLE) IndicatorRelease(m_h_atr_sma);
      if(m_h_rsi     != INVALID_HANDLE) IndicatorRelease(m_h_rsi);
      if(m_h_macd    != INVALID_HANDLE) IndicatorRelease(m_h_macd);
      if(m_h_stoch   != INVALID_HANDLE) IndicatorRelease(m_h_stoch);
      if(m_h_cci     != INVALID_HANDLE) IndicatorRelease(m_h_cci);
     }

   bool ReadAtr(const int shift, double &atr, double &atr_sma) const
     {
      double a[], s[];
      if(!ReadBuf(m_h_atr,     0, shift, 1, a)) return false;
      if(!ReadBuf(m_h_atr_sma, 0, shift, 1, s)) return false;
      atr     = a[0];
      atr_sma = s[0];
      return atr > 0.0;
     }

   //--- Fill the vote vector for a closed bar. Raw levels are retained on
   //--- the vector so the signal log can carry them alongside the reasons.
   //--- Non-const: caches the secondary series the logger needs.
   bool ReadVotes(const int shift, VoteVector &v)
     {
      v.Clear();

      SeriesWindow rsi, macd_main, macd_sig, macd_hist, k, d, cci;

      if(!ReadSeries(m_h_rsi,   0,           shift, rsi))       return false;
      if(!ReadSeries(m_h_macd,  MAIN_LINE,   shift, macd_main)) return false;
      if(!ReadSeries(m_h_macd,  SIGNAL_LINE, shift, macd_sig))  return false;
      if(!ReadSeries(m_h_stoch, MAIN_LINE,   shift, k))         return false;
      if(!ReadSeries(m_h_stoch, SIGNAL_LINE, shift, d))         return false;
      if(!ReadSeries(m_h_cci,   0,           shift, cci))       return false;

      //--- MQL5's iMACD exposes main and signal; the histogram is their
      //--- difference. Materialised here so voter and log agree.
      for(int i = 0; i < RL_VOTE_WINDOW; i++)
         macd_hist.v[i] = macd_main.v[i] - macd_sig.v[i];

      v.vote[IND_RSI]   = VoteRsi  (rsi, m_cfg, v.reason[IND_RSI]);
      v.vote[IND_MACD]  = VoteMacd (macd_main, macd_sig, macd_hist, v.reason[IND_MACD]);
      v.vote[IND_STOCH] = VoteStoch(k, d, m_cfg, v.reason[IND_STOCH]);
      v.vote[IND_CCI]   = VoteCci  (cci, m_cfg, v.reason[IND_CCI]);

      v.value[IND_RSI]   = rsi.v[0];
      v.value[IND_MACD]  = macd_hist.v[0];
      v.value[IND_STOCH] = k.v[0];
      v.value[IND_CCI]   = cci.v[0];

      //--- Extra series the log needs to make a vote reproducible.
      m_last_macd_main = macd_main.v[0];
      m_last_macd_sig  = macd_sig.v[0];
      m_last_stoch_d   = d.v[0];
      return true;
     }

   //--- Secondary series from the most recent ReadVotes, for CsvLogger.
   double LastMacdMain()   const { return m_last_macd_main; }
   double LastMacdSignal() const { return m_last_macd_sig; }
   double LastStochD()     const { return m_last_stoch_d; }
  };

#endif // RL_INDICATORHUB_MQH
