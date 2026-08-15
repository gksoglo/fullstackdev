//+------------------------------------------------------------------+
//|                                                    ReversalLab.mq5 |
//|  Research harness: candlestick reversal patterns scored against    |
//|  momentum-indicator confirmation. See prd.md.                      |
//|                                                                    |
//|  RESEARCH ONLY. No equity guard, no error recovery, no live-account |
//|  protections. Do not point this at a funded account.                |
//+------------------------------------------------------------------+
#property copyright "ReversalLab"
#property version   "0.1"
#property description "M1 skeleton: lifecycle, two-phase staging and the 384-cell fan-out."

#include <ReversalLab/Types.mqh>
#include <ReversalLab/Config.mqh>
#include <ReversalLab/Labels.mqh>
#include <ReversalLab/Patterns/PatternScanner.mqh>
#include <ReversalLab/Indicators/IndicatorHub.mqh>
#include <ReversalLab/Signal/ComboEngine.mqh>
#include <ReversalLab/Trade/VirtualBook.mqh>
#include <ReversalLab/Trade/LiveExecutor.mqh>
#include <ReversalLab/Stats/Tally.mqh>
#include <ReversalLab/Log/CsvLogger.mqh>

//--- Universe
input ENUM_TIMEFRAMES  InpTimeframe        = PERIOD_H1;
input datetime         InpStartDate        = D'2020.01.01';

//--- Trade model
input double           InpStopBufferATR    = 0.25;
input double           InpRewardRatio      = 1.5;
input double           InpHoldBarsPerATR   = 13.0;
input int              InpHoldBarsMin      = 8;
input int              InpHoldBarsMax      = 60;
input double           InpMinRiskATR       = 0.25;
input double           InpMaxRiskATR       = 3.0;
input double           InpCostPoints       = 0.0;

//--- Pattern gates
input int              InpTrendLookback    = 5;
input double           InpMinPriorMoveATR  = 1.0;
input double           InpTweezerTolATR    = 0.10;

//--- Detector shape thresholds (subjective by nature — sweep them)
input double           InpSmallBodyATR     = 0.10;
input double           InpWickBodyRatio    = 2.0;
input double           InpOppWickMaxRatio  = 0.30;
input double           InpStarBodyRatio    = 0.50;

//--- Vote thresholds
input double           InpRsiOversold      = 30.0;
input double           InpRsiOverbought    = 70.0;
input double           InpStochOversold    = 20.0;
input double           InpStochOverbought  = 80.0;
input double           InpCciThreshold     = 100.0;

//--- Indicators / ATR context filter
input int              InpAtrPeriod        = 14;
input double           InpMinPatternATR    = 0.8;   // TOGGLED filter, not a detector gate
input int              InpRsiPeriod        = 14;
input int              InpMacdFast         = 12;
input int              InpMacdSlow         = 26;
input int              InpMacdSignal       = 9;
input int              InpStochK           = 14;
input int              InpStochD           = 3;
input int              InpStochSlow        = 3;
input int              InpCciPeriod        = 20;
input int              InpAtrSmaPeriod     = 50;
input double           InpAtrRegimeLow     = 0.7;
input double           InpAtrRegimeHigh    = 1.8;

//--- Engine
input ConfirmMode      InpConfirmMode      = CONFIRM_ALL;
input int              InpWarmupBars       = 100;
input int              InpMinSamples       = 30;    // floor on n_eff
input int              InpMinResolved      = 20;    // floor on n_resolved_eff
input int              InpLiveCellId       = -1;    // -1 = no real orders
input double           InpLots             = 0.10;
input bool             InpLogIndicatorHistory = false;
input string           InpRunId            = "run001";

//--- State
RLConfig       g_cfg;
CIndicatorHub  g_hub;
CVirtualBook   g_book;
CTally         g_tally;
CCsvLogger     g_log;
CLiveExecutor  g_live;

datetime       g_last_bar_time = 0;
int            g_bar_index     = 0;      // monotonic, drives overlap tracking
int            g_bars_seen     = 0;
string         g_tf_name;

//--- Prototypes. MQL5 resolves same-file calls regardless of order, but
//--- declaring them keeps the file order-independent and lets the
//--- off-platform syntax check (tests/syntax_check.sh) parse it too.
void OnNewBar();
void InstantiateOne(const Signal &sig, const VoteVector &votes,
                    const double entry, const datetime entry_tm);

//+------------------------------------------------------------------+
string ConfigErrorText(const ConfigError e)
  {
   switch(e)
     {
      case CFG_BAD_REWARD:      return "reward ratio must be positive";
      case CFG_BAD_RISK_BOUNDS: return "risk bounds inverted or non-positive";
      case CFG_BAD_HOLD_BARS:   return "hold-bar bounds inverted or non-positive";
      case CFG_BAD_REGIME_BAND: return "ATR regime band inverted";
      case CFG_BAD_WARMUP:      return "warmup shorter than the indicators require";
      case CFG_BAD_ELIGIBILITY: return "eligibility floors inconsistent";
      case CFG_BAD_LIVE_CELL:   return "live cell id out of range";
      case CFG_BAD_PERIODS:     return "indicator periods invalid";
      case CFG_BAD_SHAPE:       return "detector or vote thresholds invalid";
      case CFG_WINDOW_TOO_SMALL: return "trend lookback exceeds the bar window";
      default:                  return "ok";
     }
  }

void LoadConfig()
  {
   g_cfg.SetDefaults();
   g_cfg.stop_buffer_atr   = InpStopBufferATR;
   g_cfg.reward_ratio      = InpRewardRatio;
   g_cfg.hold_bars_per_atr = InpHoldBarsPerATR;
   g_cfg.hold_bars_min     = InpHoldBarsMin;
   g_cfg.hold_bars_max     = InpHoldBarsMax;
   g_cfg.min_risk_atr      = InpMinRiskATR;
   g_cfg.max_risk_atr      = InpMaxRiskATR;
   g_cfg.cost_points       = InpCostPoints;

   g_cfg.trend_lookback     = InpTrendLookback;
   g_cfg.min_prior_move_atr = InpMinPriorMoveATR;
   g_cfg.tweezer_tol_atr    = InpTweezerTolATR;

   g_cfg.small_body_atr     = InpSmallBodyATR;
   g_cfg.wick_body_ratio    = InpWickBodyRatio;
   g_cfg.opp_wick_max_ratio = InpOppWickMaxRatio;
   g_cfg.star_body_ratio    = InpStarBodyRatio;

   g_cfg.rsi_oversold       = InpRsiOversold;
   g_cfg.rsi_overbought     = InpRsiOverbought;
   g_cfg.stoch_oversold     = InpStochOversold;
   g_cfg.stoch_overbought   = InpStochOverbought;
   g_cfg.cci_threshold      = InpCciThreshold;

   g_cfg.atr_period      = InpAtrPeriod;
   g_cfg.min_pattern_atr = InpMinPatternATR;
   g_cfg.rsi_period      = InpRsiPeriod;
   g_cfg.macd_fast       = InpMacdFast;
   g_cfg.macd_slow       = InpMacdSlow;
   g_cfg.macd_signal     = InpMacdSignal;
   g_cfg.stoch_k         = InpStochK;
   g_cfg.stoch_d         = InpStochD;
   g_cfg.stoch_slow      = InpStochSlow;
   g_cfg.cci_period      = InpCciPeriod;
   g_cfg.atr_sma_period  = InpAtrSmaPeriod;
   g_cfg.atr_regime_low  = InpAtrRegimeLow;
   g_cfg.atr_regime_high = InpAtrRegimeHigh;

   g_cfg.confirm_mode          = InpConfirmMode;
   g_cfg.warmup_bars           = InpWarmupBars;
   g_cfg.min_samples           = InpMinSamples;
   g_cfg.min_resolved          = InpMinResolved;
   g_cfg.live_cell_id          = InpLiveCellId;
   g_cfg.lots                  = InpLots;
   g_cfg.log_indicator_history = InpLogIndicatorHistory;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   LoadConfig();

   const ConfigError err = ValidateConfig(g_cfg);
   if(err != CFG_OK)
     {
      PrintFormat("ReversalLab: invalid configuration - %s", ConfigErrorText(err));
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- The cell algebra is load-bearing: PAT_NONE owns enum 0, so the
   //--- twelve patterns sit at 1..12 and a raw-enum index would run past
   //--- the array. Assert the mapping rather than trust it.
   if(CellId(PAT_ENGULF_BULL, 0, false) != 0 ||
      CellId(PAT_TWEEZER_TOP, SUBSET_COUNT - 1, true) != CELL_COUNT - 1)
     {
      Print("ReversalLab: cell id algebra failed its self-check");
      return INIT_FAILED;
     }

   g_tf_name = EnumToString(InpTimeframe);

   if(!g_hub.Init(_Symbol, InpTimeframe, g_cfg))
     {
      Print("ReversalLab: indicator handles failed to initialise");
      return INIT_FAILED;
     }

   g_book.Init(g_cfg, _Point);
   g_tally.Init(g_cfg);
   g_live.Init(g_cfg);

   if(!g_log.Init(_Symbol, g_tf_name, InpRunId))
      return INIT_FAILED;

   PrintFormat("ReversalLab ready: %d cells, warmup %d bars (needs %d)",
               CELL_COUNT, g_cfg.warmup_bars, g_cfg.RequiredWarmup());
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- Trades still open are truncated: logged, excluded from the tally.
   VirtualTrade leftovers[];
   g_book.CloseAllAtEnd(iClose(_Symbol, InpTimeframe, 1),
                        iTime(_Symbol, InpTimeframe, 1), leftovers);
   for(int i = 0; i < ArraySize(leftovers); i++)
      g_log.WriteTrade(leftovers[i]);

   const string rank_path = StringFormat("ReversalLab\\ranking_%s_%s_%s.csv",
                                         _Symbol, g_tf_name, InpRunId);
   g_tally.WriteRanking(rank_path);
   g_tally.PrintSummary(20);
   g_live.OnDeinit();

   g_log.Deinit();
   g_hub.Deinit();
  }

//+------------------------------------------------------------------+
//| Everything runs on the first tick of a new bar. At that instant    |
//| bar t is closed AND bar t+1's open has printed, which is why the   |
//| two phases below are sequential steps in one handler rather than a |
//| queue that survives across callbacks.                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   const datetime bt = iTime(_Symbol, InpTimeframe, 0);
   if(bt == 0 || bt == g_last_bar_time)
      return;
   g_last_bar_time = bt;
   g_bar_index++;
   g_bars_seen++;

   OnNewBar();
  }

void OnNewBar()
  {
   //--- 1. March open trades against bar t, which has just completed.
   //---    Done before staging so a trade never resolves on the bar it
   //---    was created from.
   MqlRates closed_bar[];
   if(CopyRates(_Symbol, InpTimeframe, 1, 1, closed_bar) == 1)
     {
      VirtualTrade resolved[];
      g_book.MarchOpenTrades(closed_bar[0], g_bar_index, resolved);

      for(int c = 0; c < CELL_COUNT; c++)
         if(g_book.CellWasActive(c))
            g_tally.NoteActiveBar(c);

      for(int i = 0; i < ArraySize(resolved); i++)
        {
         g_tally.Record(resolved[i]);
         g_log.WriteTrade(resolved[i]);
        }
     }

   if(g_bars_seen < g_cfg.warmup_bars)
      return;
   if(iTime(_Symbol, InpTimeframe, 1) < InpStartDate)
      return;

   //--- PHASE 1 — detect. Reads bar t (shift 1) and earlier via the bar
   //--- window; shift 0 is structurally out of reach.
   double atr = 0.0, atr_sma = 0.0;
   if(!g_hub.ReadAtr(1, atr, atr_sma))
      return;

   VoteVector votes;
   if(!g_hub.ReadVotes(1, votes))
      return;

   BarWindow win;
   if(!FillBarWindow(_Symbol, InpTimeframe, 1, RequiredWindow(g_cfg), win))
      return;

   Signal staged[];
   int rejected_no_trend = 0;
   const int n = ScanWindow(win, iTime(_Symbol, InpTimeframe, 1), g_bar_index,
                            atr, atr_sma, g_cfg, staged, rejected_no_trend);
   for(int r = 0; r < rejected_no_trend; r++)
      g_tally.NoteRejected(REJ_NO_TREND);
   if(n <= 0)
      return;

   //--- PHASE 2 — instantiate. Entry is bar t+1's open, available now.
   const double entry      = iOpen(_Symbol, InpTimeframe, 0);
   const datetime entry_tm = iTime(_Symbol, InpTimeframe, 0);

   for(int i = 0; i < n; i++)
      InstantiateOne(staged[i], votes, entry, entry_tm);
  }

//+------------------------------------------------------------------+
//| One staged signal: build the trade once, then fan out to its cells. |
//|                                                                    |
//| The gap and risk-bound tests are cell-independent, so they run here |
//| exactly once. Running them inside the fan-out would count a single  |
//| rejection 384 times in the report.                                  |
//+------------------------------------------------------------------+
void InstantiateOne(const Signal &sig, const VoteVector &votes,
                    const double entry, const datetime entry_tm)
  {
   VirtualTrade proto;
   const RejectReason rej = BuildTrade(sig, entry, g_cfg, proto);

   if(rej != REJ_NONE)
     {
      g_tally.NoteRejected(rej);
      g_log.WriteSignal(_Symbol, g_tf_name, sig, votes, entry_tm, entry,
                        0.0, 0.0, 0,
                        g_hub.LastMacdMain(), g_hub.LastMacdSignal(), g_hub.LastStochD(),
                        true, rej != REJ_GAP, rej != REJ_RISK_BOUNDS, 0);
      return;
     }

   proto.entry_time = entry_tm;

   //--- Fan out. A cell admits when its subset confirms and its ATR-filter
   //--- state matches the signal's. The empty subset is the control arm and
   //--- always admits, which is what lift_vs_control is measured against.
   int admitted = 0;
   for(int mask = 0; mask < SUBSET_COUNT; mask++)
     {
      if(!votes.Admits(sig.dir, mask, g_cfg.confirm_mode))
         continue;

      for(int a = 0; a < 2; a++)
        {
         const bool atr_on = (a == 1);
         if(atr_on && !sig.atr_filter_pass)
            continue;

         const int cell = CellId(sig.pattern, mask, atr_on);
         g_book.OpenVirtual(cell, proto);
         g_tally.NoteAdmitted(cell);
         g_live.OnCellTrade(cell, proto);
         admitted++;
        }
     }

   if(admitted == 0)
      g_tally.NoteNoConfirmation();

   g_log.WriteSignal(_Symbol, g_tf_name, sig, votes, entry_tm, entry,
                     proto.risk, proto.risk_atr, proto.hold_bars,
                     g_hub.LastMacdMain(), g_hub.LastMacdSignal(), g_hub.LastStochD(),
                     true, true, true, admitted);
  }
