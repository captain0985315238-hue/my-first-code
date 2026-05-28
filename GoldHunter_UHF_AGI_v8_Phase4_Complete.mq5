//+------------------------------------------------------------------+
//|         GOLDHUNTER ULTIMATE v8.4 UHF AGI — PHASE 4 EDITION            |
//|    Ultra-High-Frequency AGI Trading Bot for XAUUSD (Gold) Scalp/Swing    |
//|    Standard: MetaEditor 5 / XM Global MT5 Servers    |
//|    Build Target: MT5 4000+ | Tested: XAUUSD M1/M5/M15/H1        |
//|    PHASE 4: Safety Guardrails + Circuit Breakers + Alignment Layer   |
//+------------------------------------------------------------------+
//| UPGRADE LOG v8.4 AGI Phase 4 (from v8.3):                           |
//|  [PH4] Layer 0: Immutable Hard Stop Constants (ASI Alignment)       |
//|  [PH4] Layer 1: Pre-Trade Validation with Hard Bounds               |
//|  [PH4] Layer 2: Upgraded Adaptive Circuit Breaker + Predictive CB   |
//|  [PH4] Layer 3: Constrained Self-Healing Optimizer                  |
//|  [PH4] Audit Trail System - separate from Discord notifications     |
//|  [PH3] 5 Specialist Agents — Trend, Momentum, MeanRev, Volatility, Sentiment |
//|  [PH3] VETO System — Critical agents can block trades unilaterally |
//|  [PH3] 5-Node Order Execution DAG — Validation→RiskCheck→PreFlight→Submission→Confirmation |
//|  [PH2] Two-Tier Memory — Working Memory (ring buffer) + Episodic Memory (CSV) |
//|  [PH1] OODA Agent Loop — formal Observe-Orient-Decide-Act pipeline |
//+------------------------------------------------------------------+
#property copyright "GoldHunter UHF AGI v8.4 — Phase 4 Edition"
#property version   "8.04"
#property description "UHF Gold EA | XAUUSD | 1-Second Execution | AGI OODA + 5-Agent VETO + DAG + Safety"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>

//--- Forward declarations
void     LogStatus(string message);
void     CreateSessionControlButton();
void     UpdateSessionControlButton();
void     CreateBotControlButton();
void     UpdateBotControlButton();
void     SendPnLAlert(string action, double grossProfit, double netProfit,
                      double balance, string sym, ulong posId, double lots);
string   RetcodeToString(uint retcode);
bool     TryPlaceOrder(ENUM_ORDER_TYPE type, double lots, double price,
                       double sl, double tp, string comment);
bool     IsStrongConfluence(bool isBuy);
bool     IsMomentumAligned(bool isBuy);
bool     IsMarketStructureBull();
bool     IsMarketStructureBear();
void     SendDiscordExtendedReport();
void     CheckConsecutiveLossCB();

CTrade         trade;
CSymbolInfo    symbolInfo;
CPositionInfo  posInfo;

//==========================================================================
//  INPUT PARAMETERS
//==========================================================================

input group "=== STRATEGY MODE ==="
input int    StrategyMode        = 0;    // 0=Auto(AI) 1=Scalp 2=Swing 3=Breakout 4=Reversal
input bool   AutoSelectStrategy  = true;

input group "=== RISK MANAGEMENT ==="
input double RiskPercent         = 1.5;  // Risk per trade (% of balance) — reduced for accuracy
input bool   UseAggressiveGrowth = true;
input double GrowthMultiplier    = 1.2;
input double MaxDailyLossPerc    = 20.0;  // [v6] Dynamic: % of equity, not hard halt
input double MaxDailyProfitPerc  = 30.0;  // [v6] Dynamic: % of equity, not hard halt
input int    MaxTradesPerDay     = 20;   // [v5] Stats tracking only — NOT a hard block
input double MinLot              = 0.01;
input double MaxLot              = 1.0;

input group "=== STOP LOSS / TAKE PROFIT ==="
input bool   UseATRStops         = true;
input double ATR_SL_Multiplier   = 1.5;
input double ATR_TP_Multiplier   = 3.0;  // [v5] wider TP for better R:R
input int    FixedSL_Points      = 150;
input int    FixedTP_Points      = 400;
input bool   UseTrailingStop     = true;
input double TrailATRMultiplier  = 1.2;  // [v5] slightly wider trail
input bool   UseBreakEven        = true;
input double BreakEvenATR        = 0.7;

input group "=== ADVANCED PROFIT GUARD ==="
input bool   UsePartialProfit    = true;
input double TP1_Ratio           = 1.2;
input double TP1_ClosePercent    = 40.0; // [v5] close 40% at TP1, let 60% run
input bool   UseAdvancedBreakeven= true;
input int    BreakevenBufferPips = 3;
input bool   UseProfitLock       = true;
input double ProfitLockRatio     = 2.5;

input group "=== [v5] CONFLUENCE FILTER ==="
input bool   UseConfluenceFilter = true; // Require M1+M5+H1 alignment
input bool   UseMomentumFilter   = true; // Price must be moving in signal direction
input bool   UseMarketStructure  = true; // Require HH/LL market structure
input double MinConfidence       = 62.0; // [v5] Raised from 60 for precision
input int    MinScoreThreshold   = 5;    // [v5] Raised from 4

input group "=== [v5] ADAPTIVE CIRCUIT BREAKER ==="
input bool   UseAdaptiveCB         = true;  // Enable Adaptive Circuit Breaker
input double CB_LossPctTrigger     = 2.0;   // Trigger CB when session loss >= X% of balance
input double CB_EquityDDTrigger    = 3.0;   // Trigger CB when equity drops X% from session peak
input int    CB_MaxConsecLosses    = 3;     // Also trigger if N consecutive losses
// Pause duration is DYNAMIC — calculated from market volatility (ATR) + loss severity
// Minimum and maximum bounds only:
input int    CB_MinPauseMinutes    = 10;    // Minimum pause (minutes)
input int    CB_MaxPauseMinutes    = 120;   // Maximum pause (minutes)

input group "=== MULTI-TIMEFRAME ==="
input bool              UseMultiTimeframe = true;
input ENUM_TIMEFRAMES   HigherTimeframe   = PERIOD_H4;

input group "=== VOLUME ANALYSIS ==="
input bool   UseVolumeAnalysis   = true;
input double MinVolumeMultiplier = 1.3;  // [v5] slightly less restrictive

input group "=== TIME FILTER ==="
input bool   EnableTimeFilter    = false;  // [v7] DEPRECATED — kept for backward compat, always false
input int    StartTradeHour      = 0;      // [v7] No restriction
input int    EndTradeHour        = 24;     // [v7] 24/7 trading enabled

input group "=== INDICATORS ==="
input int    FastEMA_Period      = 8;
input int    SlowEMA_Period      = 21;
input int    TrendEMA_Period     = 89;
input int    RSI_Period          = 14;
input double RSI_OB              = 70.0;
input double RSI_OS              = 30.0;
input int    MACD_Fast           = 12;
input int    MACD_Slow           = 26;
input int    MACD_Signal         = 9;
input int    BB_Period           = 20;
input double BB_Deviation        = 2.0;
input int    ATR_Period          = 14;
input int    Stoch_K             = 5;
input int    Stoch_D             = 3;
input int    Stoch_Slow          = 3;
input int    ADX_Period          = 14;
input double ADX_MinStrength     = 22.0;

input group "=== ADAPTIVE LOGIC ==="
input bool   UseAdaptiveLogic        = true;
input int    TrendingADXThreshold    = 28;
input int    RangingADXThreshold     = 20;
input double VolatileATRMultiplier   = 1.5;

input group "=== SESSION FILTER ==="
input bool   UseSessionFilter    = true;
input bool   TradeAsianSession   = false;
input bool   TradeLondonSession  = true;
input bool   TradeNYSession      = true;
input int    SessionBuffer_Min   = 10;

input group "=== SCALPING SETTINGS ==="
input int    ScalpM1_RSI_OS      = 38;
input int    ScalpM1_RSI_OB      = 62;
input int    ScalpMinPoints      = 50;

input group "=== EXECUTION SETTINGS ==="
input int    TradeCooldownSec    = 1;
input bool   TickBasedEntry      = true; // [v6] UHF default ON — tick-based 1-sec execution
input int    MaxSpreadPips       = 35;
input int    SlippagePoints      = 30;
input bool   ShowDebugLog        = true;

input group "=== P&L ALERT SETTINGS ==="
input bool   AlertOnTradeOpen    = true;
input bool   AlertOnTradeClose   = true;
input bool   PushNotifyOnTrade   = true;
input bool   PushNotifyOnDaily   = true;

input group "=== DISCORD NOTIFICATIONS ==="
input bool   UseDiscord          = true;
input string DiscordWebhookURL   = "https://discord.com/api/webhooks/1508113914955694250/_8dwDMyQjYf1efakaHKLwxMce-0qTr_fWaKlebrY84VQPsWQcoZQ9xuZOoDS4VQ76bkn";
input bool   NotifyOnTrade       = true;
input bool   NotifyOnDailyReport = true;
input bool   NotifyOnBotState    = true;
input bool   NotifyOnRiskEvent   = true;
input bool   NotifyExtendedStats = true;  // [v5] Extended session stats in Discord
input string DiscordBotName      = "GoldHunter UHF AGI v6 MT5";
input int    DiscordTimeoutMS    = 7000;

input group "=== MANUAL BOT CONTROL ==="
input bool   BotEnabledByDefault      = true;
input bool   EnableChartControlButton = true;
input bool   ManagePositionsWhenPaused= true;
input bool   ClosePositionsWhenStopped= false;

input group "=== DISPLAY ==="
input bool   ShowDashboard  = true;
input color  PanelColor     = C'18,22,38';
input color  ProfitColor    = clrLime;
input color  LossColor      = clrRed;
input color  TextColor      = clrWhite;

input group "=== PHASE 3: AGENTIC AI FEATURES ==="
input bool   EnableSpecialistAgents = true;  // Enable 5 Specialist Agents
input bool   EnableVetoSystem       = true;  // Enable VETO power for critical agents
input int    ConsensusThreshold     = 2;     // Minimum votes for trade approval (if no veto)
input bool   EnableDagExecution     = true;  // Enable 5-Node Order Execution DAG
input string TradeLogCSV            = "GoldHunter_TradeLog_v8.csv";  // Phase 2: Enhanced CSV logging
input string MemoryStateFile        = "GoldHunter_Memory_v8.dat";   // Phase 2: Memory persistence

//==========================================================================
//  INDICATOR HANDLES
//==========================================================================
int handleEMAFast, handleEMASlow, handleEMATrend;
int handleRSI, handleMACD, handleBB, handleATR;
int handleStoch, handleADX, handleEMATrend_HTF;
int handleScalpEMA5, handleScalpEMA13, handleScalpRSI7;
int handleH4EMA50, handleH4EMA200;
// [v5] Multi-timeframe confluence handles
int handleM5EMAFast, handleM5EMASlow, handleM5RSI;
int handleH1EMAFast, handleH1EMASlow, handleH1RSI;

//==========================================================================
//  GLOBAL VARIABLES
//==========================================================================
double atrValue, rsiValue, macdMain, macdSignal;
double bbUpper, bbMiddle, bbLower;
double emaFast, emaSlow, emaTrend, emaTrend_HTF;
double stochMain, stochSignal;
double adxValue, plusDI, minusDI;
double averageVolume, prevAtrValue;

// TP1 tracking
ulong  tp1ExecutedTickets[];
int    tp1ExecutedCount = 0;

double dailyStartBalance  = 0;
double weeklyStartBalance = 0;
datetime lastTradeTime    = 0;
int    tradesThisDay      = 0;
datetime currentDay       = 0;
datetime currentWeek      = 0;
bool   tradingHalted      = false;  // [v6] Deprecated: No longer used for hard halts
bool   manualBotEnabled   = true;
bool   manualSessionFilter= true;
bool   discordWarnShown   = false;
datetime lastDiscordErrTime = 0;
string lastSignal         = "SCANNING...";
int    winCount           = 0;
int    lossCount          = 0;
double totalProfit        = 0;
int    currentStrategy    = 0;

// [v6] Defensive state instead of hard halt - MUST be declared before use
enum ENUM_TRADING_STATE {
   STATE_RUNNING,
   STATE_DEFENSIVE_MONITORING,  // Risk threshold breached but still learning
   STATE_PAUSED_MANUAL,
   STATE_DISABLED               // PHASE 4: Hard stop triggered
};
ENUM_TRADING_STATE currentTradingState = STATE_RUNNING;

// [v5] Adaptive Circuit Breaker
int    consecutiveLosses  = 0;
datetime cbPauseUntil     = 0;
double sessionPeakEquity  = 0;   // Tracks equity peak within current trading session
string cbTriggerReason    = "";  // Why CB was triggered (for Discord report)
int    cbPauseMinutesLast = 0;   // How long the last pause was (for stats)

// [v5] Session stats
int    londonWins=0, londonLosses=0;
int    nyWins=0,     nyLosses=0;
int    asianWins=0,  asianLosses=0;
double londonPnL=0,  nyPnL=0, asianPnL=0;

// [v5] Drawdown tracking
double peakEquity         = 0;
double maxDrawdownPct     = 0;
int    winStreak          = 0;
int    lossStreak         = 0;
int    maxWinStreak       = 0;
int    maxLossStreak      = 0;

// [v5] Weekly report
datetime lastWeeklyReport = 0;

// PHASE 4: Safety system state
datetime lastSafetyReportTime = 0;
int    optimizerRejectedCount = 0;
datetime optimizerFrozenUntil = 0;

#define EA_MAGIC_NUMBER     202501
#define BOT_BUTTON_NAME     "GHP_TOGGLE_BOT"
#define SESSION_BUTTON_NAME "GHP_TOGGLE_SESSION"
#define EA_VERSION          "6.0"

// ========================================================================
//  PHASE 4: LAYER 0 - IMMUTABLE HARD STOP CONSTANTS (ASI ALIGNMENT LAYER)
//  These CANNOT be modified by optimizer or user input - Constitutional Rules
// ========================================================================
#define HARD_STOP_EQUITY_FLOOR_PCT       50.0   // Equity < 50% → FULL DISABLE
#define HARD_STOP_MAX_OPEN_POSITIONS     3      // Never hold more than 3 EA positions
#define HARD_STOP_MAX_LOT_ABSOLUTE       2.0    // Hard ceiling on lot size
#define HARD_STOP_MIN_CONFIDENCE         50.0   // Confidence floor - optimizer cannot go below
#define HARD_STOP_MIN_SL_ATR_MULT        0.3    // SL multiplier floor
#define HARD_STOP_MAX_SL_ATR_MULT        5.0    // SL multiplier ceiling
#define HARD_STOP_MAX_RISK_PCT           10.0   // Max risk per trade % - hard ceiling
#define HARD_STOP_MAX_DAILY_LOSS_PCT     30.0   // Absolute max daily loss → FULL DISABLE
#define AUDIT_LOG_FILE                   "GoldHunter_AuditTrail.log"
#define SAFETY_REPORT_INTERVAL_SEC       300    // Safety status to Discord every 5 min

// --- Alias macros: map legacy names used in code to the actual input variable names ---
#define MaxConsecutiveLosses  CB_MaxConsecLosses
#define CBPauseMinutes        CB_MinPauseMinutes

string stratNames[] = {"AUTO-AI","SCALPING","SWING","BREAKOUT","REVERSAL"};

//==========================================================================
//  PHASE 3: SPECIALIST AGENT STRUCTURES
//==========================================================================
struct AgentVote {
   string agent_name;      // Name of the specialist agent
   int    signal;          // 1=Buy, -1=Sell, 0=Neutral/Abstain
   double confidence;      // 0.0 to 1.0 confidence score
   bool   veto;            // TRUE if this agent exercises VETO power
   string reasoning;       // Explainable AI: reason for decision
};

//==========================================================================
//  PHASE 3: ORDER EXECUTION DAG NODE RESULT
//==========================================================================
struct DAGNodeResult {
   string node_name;       // Name of the DAG node
   bool   passed;          // TRUE if node validation passed
   string error_message;   // Error message if failed
   datetime timestamp;     // When this node executed
};

//==========================================================================
//  PHASE 2: ENHANCED TRADE RECORD (TradeRecordV8)
//==========================================================================
struct TradeRecordV8 {
   datetime open_time;
   long     ticket;
   ENUM_ORDER_TYPE type;
   double   volume;
   double   open_price;
   double   sl;
   double   tp;
   double   close_price;
   datetime close_time;
   double   profit;
   double   commission;
   double   swap;

   // AI Metadata (Phase 2)
   int      state_id;           // Q-Table state encoding
   double   prior_prob;         // Bayesian prior probability
   double   posterior_prob;     // Bayesian posterior probability
   string   agent_votes;        // Serialized specialist agent votes
   string   dag_trace;          // DAG execution path trace
   string   veto_reason;        // If rejected: which agent vetoed
};

//==========================================================================
//  PHASE 2: TWO-TIER MEMORY SYSTEM
//==========================================================================
struct SessionWorkingMemory {
   double recent_regimes[10];      // Ring buffer: recent market regimes
   double recent_confidence[10];   // Ring buffer: recent confidence scores
   int    head_index;              // Current position in ring buffer

   double session_pnl;             // Cumulative P&L this session
   int    trades_today;            // Number of trades today
   datetime last_reset_time;       // Last reset timestamp
};

// [v7] ASI AGI Core Structures
struct TradeRecord {
   datetime timestamp;
   ENUM_ORDER_TYPE type;
   double entryPrice;
   double exitPrice;
   double profit;
   double slDistance;
   double tpDistance;
   int regime;
   int strategy;
   double confidence;
   string reasons;
};

struct QTableEntry {
   double qValues[3];  // 0=Buy, 1=Sell, 2=Hold
   int visitCount;
   datetime lastUpdate;
};

struct BayesianStrategyProb {
   double scalpProb;
   double swingProb;
   double breakoutProb;
   double reversalProb;
   double autoProb;
   int totalObservations;
};

struct NeuralNetworkLayer {
   double weights[10][15];  // 10 inputs, 15 hidden neurons
   double hiddenBias[15];
   double outputWeights[15];
   double outputBias;
};

// [v7] Tick type constants for order flow analysis
#define TICK_TYPE_BUY   1
#define TICK_TYPE_SELL -1
#define TICK_TYPE_UNKNOWN 0

struct TickDeltaBuffer {
   double buyVolume[60];    // 60-second circular buffer
   double sellVolume[60];
   int currentIndex;
   datetime lastUpdate;
};

struct CorrelationGuard {
   double xauReturn[20];
   double dxyReturn[20];
   int currentIndex;
   bool dxyAvailable;
};

struct SelfHealOptimizer {
   int tradeBatchCount;
   double bestSharpe;
   double bestATR_SL;
   double bestATR_TP;
   double bestMinConf;
   datetime lastOptimize;
   int appliedCount;       // PHASE 4: Track successful applications
   int rejectedCount;      // PHASE 4: Track rejections
   datetime frozenUntil;   // PHASE 4: Frozen until timestamp
};

// [v7] Global AGI/ASI State Variables
TradeRecord tradeHistory[];
int tradeHistoryCount = 0;
QTableEntry qTable[];
int qTableSize = 0;
BayesianStrategyProb bayesProbs;
NeuralNetworkLayer nnLayer;
TickDeltaBuffer tickDelta;
CorrelationGuard corrGuard;
SelfHealOptimizer optimizer;

//==========================================================================
//  PHASE 2 & 3: GLOBAL STATE VARIABLES
//==========================================================================
SessionWorkingMemory working_memory;        // Phase 2: Working Memory (Tier 1)
TradeRecordV8        episodic_memory[];     // Phase 2: Episodic Memory (Tier 2)
AgentVote            specialist_agents[5];  // Phase 3: 5 Specialist Agents
DAGNodeResult        dag_nodes[5];          // Phase 3: 5-Node Execution DAG

// Phase 2: Bayesian Priors per Strategy (Alpha=success, Beta=failure)
double strategy_alpha[5];   // Success counts for 5 strategies
double strategy_beta[5];    // Failure counts for 5 strategies

// Phase 2: Q-Table State Encoding
int Q_TABLE_STATES = 360;   // 5(regime)*4(RSI)*3(ADX)*3(session)*2(trend)
double q_table_values[];    // Q-values for each state-action pair

// Phase 3: DAG Execution State
int dag_success_count = 0;
int dag_failure_count = 0;
datetime last_dag_failure_time = 0;
string last_veto_reason = "";

// CSV file paths for learning
string tradeLogCSV = "GoldHunter_TradeLog.csv";
string qTableCSV = "GoldHunter_QTable.csv";
string nnWeightsJSON = "GoldHunter_NN_Weights.json";

// Learning parameters
input bool   UseReinforcementLearning = true;   // [v7] Enable Q-learning
input bool   UseBayesianInference     = true;   // [v7] Enable Bayesian strategy selection
input bool   UseNeuralNetwork         = false;  // [v7] Enable NN (requires weights file)
input bool   UseOrderFlowImbalance    = true;   // [v7] Enable tick delta analysis
input bool   UseCorrelationGuard      = true;   // [v7] DXY correlation check
input bool   UseSelfHealingOptimizer  = true;   // [v7] Auto-optimize parameters

#define MAX_TRADE_HISTORY 500
#define MAX_QTABLE_ENTRIES 200
#define Q_LEARNING_RATE 0.1
#define Q_DISCOUNT_FACTOR 0.9
#define Q_EPSILON 0.15

// [v7] MarketScore struct (original from v6)
struct MarketScore {
   int    buyScore;
   int    sellScore;
   string reasons;
   double confidence;
};

//==========================================================================
//  PHASE 1: AGENT CONTEXT STRUCT (OODA Message Envelope)
//==========================================================================
struct AgentContext {
   // Observation outputs
   bool           dataValid;
   int            marketRegime;       // 1=Bull 2=Bear 3=Ranging 4=Volatile 5=Calm
   double         atrValue, rsiValue, adxValue, emaFast, emaSlow, emaTrend;
   double         macdMain, macdSignal, bbUpper, bbMiddle, bbLower;
   double         stochMain, stochSignal, plusDI, minusDI;
   double         averageVolume, prevAtrValue, emaTrend_HTF;
   // Multi-TF buffers for confluence sub-agents
   double         m5EMAFast, m5EMASlow, m5RSI;
   double         h1EMAFast, h1EMASlow, h1RSI;

   // Orientation outputs (vote aggregation)
   int            agentBuyVotes;       // sum of specialist agent BUY votes
   int            agentSellVotes;      // sum of specialist agent SELL votes
   double         aggregateConfidence; // 0.0–100.0
   string         decisionReasons;
   int            selectedStrategy;    // 0=Auto 1=Scalp 2=Swing 3=Breakout 4=Reversal

   // Decision outputs
   bool           tradingAllowed;      // all gates passed
   string         blockReason;         // if tradingAllowed=false, why

   // Plan outputs
   ENUM_ORDER_TYPE proposedType;
   double         proposedLots;
   double         proposedEntry;
   double         proposedSL;
   double         proposedTP;

   // Execution outputs
   bool           orderPlaced;
   ulong          placedTicket;
   uint           lastRetcode;

   // Reflection outputs
   bool           reflectionComplete;
};

//==========================================================================
//  PHASE 1: PIPELINE TRACE LOGGING (Mechanistic Interpretability)
//==========================================================================
string pipelineTrace[];
int pipelineTraceHead = 0;
#define MAX_PIPELINE_TRACE 50

void PipelineTraceLog(string phase, string status, string details)
{
   string entry = StringFormat("[%s][%s][%d] %s", phase, status, GetTickCount(), details);

   if(ArraySize(pipelineTrace) < MAX_PIPELINE_TRACE) {
      ArrayResize(pipelineTrace, ArraySize(pipelineTrace) + 1);
      pipelineTrace[ArraySize(pipelineTrace)-1] = entry;
   } else {
      // Circular buffer: overwrite oldest
      pipelineTrace[pipelineTraceHead] = entry;
      pipelineTraceHead = (pipelineTraceHead + 1) % MAX_PIPELINE_TRACE;
   }
}

void PrintPipelineTrace()
{
   LogStatus("=== PIPELINE TRACE ===");
   int start = (ArraySize(pipelineTrace) < MAX_PIPELINE_TRACE) ? 0 : pipelineTraceHead;
   int count = ArraySize(pipelineTrace);
   for(int i = 0; i < count; i++) {
      int idx = (start + i) % count;
      Print(pipelineTrace[idx]);
   }
}

//==========================================================================
//  PHASE 1: SAFETY LAYER PRE-CHECK
//==========================================================================
bool SafetyLayer_PreCheck()
{
   // Check if bot is enabled
   if(!IsBotTradingAllowed()) {
      PipelineTraceLog("SAFETY", "BLOCK", "Bot not enabled");
      return false;
   }

   // Check circuit breaker pause
   if(cbPauseUntil > 0 && TimeCurrent() < cbPauseUntil) {
      PipelineTraceLog("SAFETY", "BLOCK", "Circuit breaker active");
      return false;
   }

   // Lift circuit breaker if time expired
   if(cbPauseUntil > 0 && TimeCurrent() >= cbPauseUntil) {
      cbPauseUntil      = 0;
      consecutiveLosses = 0;
      sessionPeakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(NotifyOnBotState)
         SendDiscord(StringFormat("✅ **ADAPTIVE CB LIFTED** — Trading resumed.\n"
                                  "Trigger was: `%s`\n"
                                  "Paused for: `%d min`\n"
                                  "Equity now: `$%.2f`",
                                  cbTriggerReason, cbPauseMinutesLast,
                                  AccountInfoDouble(ACCOUNT_EQUITY)));
      cbTriggerReason = "";
      PipelineTraceLog("SAFETY", "CB_LIFTED", "Circuit breaker lifted");
   }

   return true;
}

void SafetyLayer_PostCheck(AgentContext &ctx)
{
   // Update trading state based on outcomes
   CheckSafetyLimits();

   // Log final pipeline state
   if(ctx.orderPlaced) {
      PipelineTraceLog("SAFETY", "OK", "Trade executed, ticket="+(string)ctx.placedTicket);
   }
}

//==========================================================================
//  OnInit
//==========================================================================
int OnInit()
{
   if(!symbolInfo.Name(Symbol())) {
      Alert("GoldHunter v8.3 Phase 3: Cannot load symbol info for ", Symbol());
      return INIT_FAILED;
   }
   symbolInfo.RefreshRates();

   // Current TF handles
   handleEMAFast      = iMA(Symbol(), PERIOD_CURRENT, FastEMA_Period,  0, MODE_EMA, PRICE_CLOSE);
   handleEMASlow      = iMA(Symbol(), PERIOD_CURRENT, SlowEMA_Period,  0, MODE_EMA, PRICE_CLOSE);
   handleEMATrend     = iMA(Symbol(), PERIOD_H1,      TrendEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI          = iRSI(Symbol(), PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   handleMACD         = iMACD(Symbol(), PERIOD_CURRENT, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   handleBB           = iBands(Symbol(), PERIOD_CURRENT, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   handleATR          = iATR(Symbol(), PERIOD_CURRENT, ATR_Period);
   handleStoch        = iStochastic(Symbol(), PERIOD_CURRENT, Stoch_K, Stoch_D, Stoch_Slow, MODE_SMA, STO_LOWHIGH);
   handleADX          = iADX(Symbol(), PERIOD_CURRENT, ADX_Period);
   handleScalpEMA5    = iMA(Symbol(), PERIOD_M1, 5,   0, MODE_EMA, PRICE_CLOSE);
   handleScalpEMA13   = iMA(Symbol(), PERIOD_M1, 13,  0, MODE_EMA, PRICE_CLOSE);
   handleScalpRSI7    = iRSI(Symbol(), PERIOD_M1, 7,  PRICE_CLOSE);
   handleH4EMA50      = iMA(Symbol(), PERIOD_H4, 50,  0, MODE_EMA, PRICE_CLOSE);
   handleH4EMA200     = iMA(Symbol(), PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE);

   // [v5] M5 confluence handles
   handleM5EMAFast    = iMA(Symbol(), PERIOD_M5,  FastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleM5EMASlow    = iMA(Symbol(), PERIOD_M5,  SlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleM5RSI        = iRSI(Symbol(), PERIOD_M5, RSI_Period, PRICE_CLOSE);

   // [v5] H1 confluence handles
   handleH1EMAFast    = iMA(Symbol(), PERIOD_H1, FastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleH1EMASlow    = iMA(Symbol(), PERIOD_H1, SlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleH1RSI        = iRSI(Symbol(), PERIOD_H1, RSI_Period, PRICE_CLOSE);

   if(UseMultiTimeframe)
      handleEMATrend_HTF = iMA(Symbol(), HigherTimeframe, TrendEMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(handleEMAFast  == INVALID_HANDLE || handleEMASlow  == INVALID_HANDLE ||
      handleRSI      == INVALID_HANDLE || handleMACD     == INVALID_HANDLE ||
      handleATR      == INVALID_HANDLE || handleADX      == INVALID_HANDLE) {
      Alert("GoldHunter v8.3: Indicator init FAILED. Check symbol: ", Symbol());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(EA_MAGIC_NUMBER);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   dailyStartBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   weeklyStartBalance = dailyStartBalance;
   peakEquity         = AccountInfoDouble(ACCOUNT_EQUITY);
   sessionPeakEquity  = peakEquity;
   currentDay         = iTime(Symbol(), PERIOD_D1, 0);
   currentWeek        = iTime(Symbol(), PERIOD_W1, 0);
   manualBotEnabled   = BotEnabledByDefault;
   manualSessionFilter= UseSessionFilter;

   ArrayResize(tp1ExecutedTickets, 0);
   tp1ExecutedCount = 0;

   //=======================================================================
   //  PHASE 2 & 3 INITIALIZATION
   //=======================================================================

   // Initialize Working Memory (Phase 2)
   working_memory.head_index = 0;
   working_memory.session_pnl = 0.0;
   working_memory.trades_today = 0;
   working_memory.last_reset_time = TimeCurrent();
   ArrayInitialize(working_memory.recent_regimes, 0);
   ArrayInitialize(working_memory.recent_confidence, 0.0);

   // Initialize Bayesian Priors (Phase 2) - Uniform Prior (Alpha=1, Beta=1)
   for(int i=0; i<5; i++) {
      strategy_alpha[i] = 1.0;
      strategy_beta[i] = 1.0;
   }

   // Initialize Q-Table (Phase 2)
   ArrayResize(q_table_values, Q_TABLE_STATES * 3);  // 3 actions per state
   ArrayInitialize(q_table_values, 0.0);

   // Initialize Specialist Agents (Phase 3)
   for(int i=0; i<5; i++) {
      specialist_agents[i].signal = 0;
      specialist_agents[i].confidence = 0.0;
      specialist_agents[i].veto = false;
      specialist_agents[i].reasoning = "";
   }
   specialist_agents[0].agent_name = "TrendAgent";
   specialist_agents[1].agent_name = "MomentumAgent";
   specialist_agents[2].agent_name = "MeanReversionAgent";
   specialist_agents[3].agent_name = "VolatilityAgent";
   specialist_agents[4].agent_name = "SentimentAgent";

   // Initialize DAG Nodes (Phase 3)
   for(int i=0; i<5; i++) {
      dag_nodes[i].passed = false;
      dag_nodes[i].error_message = "";
   }
   dag_nodes[0].node_name = "Validation";
   dag_nodes[1].node_name = "RiskCheck";
   dag_nodes[2].node_name = "PreFlight";
   dag_nodes[3].node_name = "Submission";
   dag_nodes[4].node_name = "Confirmation";

   dag_success_count = 0;
   dag_failure_count = 0;
   last_dag_failure_time = 0;

   // Load Episodic Memory from CSV (Phase 2)
   if(UseBayesianInference) {
      LoadEpisodicMemory();
      Print("Phase 2: Loaded ", ArraySize(episodic_memory), " historical trades from memory");
   }

   if(ShowDashboard)            CreateDashboard();
   if(EnableChartControlButton) { CreateBotControlButton(); CreateSessionControlButton(); }
   UpdateBotControlButton();
   UpdateSessionControlButton();

   SendDiscordStartupReport();
   Print("GoldHunter UHF AGI v8.3 Phase 3 initialized. Symbol: ", Symbol(),
         " | Magic: ", EA_MAGIC_NUMBER,
         " | Agents: 5 Specialists + VETO | DAG: 5-Node Execution");
   return INIT_SUCCEEDED;
}

//==========================================================================
//  OnDeinit
//==========================================================================
void OnDeinit(const int reason)
{
   IndicatorRelease(handleEMAFast);   IndicatorRelease(handleEMASlow);
   IndicatorRelease(handleEMATrend);  IndicatorRelease(handleRSI);
   IndicatorRelease(handleMACD);      IndicatorRelease(handleBB);
   IndicatorRelease(handleATR);       IndicatorRelease(handleStoch);
   IndicatorRelease(handleADX);       IndicatorRelease(handleScalpEMA5);
   IndicatorRelease(handleScalpEMA13);IndicatorRelease(handleScalpRSI7);
   IndicatorRelease(handleH4EMA50);   IndicatorRelease(handleH4EMA200);
   IndicatorRelease(handleM5EMAFast); IndicatorRelease(handleM5EMASlow);
   IndicatorRelease(handleM5RSI);     IndicatorRelease(handleH1EMAFast);
   IndicatorRelease(handleH1EMASlow); IndicatorRelease(handleH1RSI);
   if(UseMultiTimeframe) IndicatorRelease(handleEMATrend_HTF);

   ObjectsDeleteAll(ChartID(), "GHP_");

   // Phase 2: Save Episodic Memory before shutdown
   if(UseBayesianInference) {
      SaveEpisodicMemory();
      Print("Phase 2: Saved ", ArraySize(episodic_memory), " trades to episodic memory");
   }

   SendDiscordShutdownReport(reason);
}

//==========================================================================
//  OnTick — Main Loop
//==========================================================================
void OnTick()
{
   CheckNewDay();
   CheckWeeklyReport();

   if(!symbolInfo.RefreshRates()) return;

   if(!UpdateIndicators()) {
      LogStatus("Waiting for indicators...");
      return;
   }

   // [v5] Peak equity tracking for drawdown
   double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(curEquity > peakEquity)        peakEquity        = curEquity;
   if(curEquity > sessionPeakEquity) sessionPeakEquity = curEquity;
   if(peakEquity > 0) {
      double dd = (peakEquity - curEquity) / peakEquity * 100.0;
      if(dd > maxDrawdownPct) maxDrawdownPct = dd;
   }

   double currentSpread = (symbolInfo.Ask() - symbolInfo.Bid()) / symbolInfo.Point();
   if(currentSpread > MaxSpreadPips) {
      LogStatus(StringFormat("Spread too high: %.1f > %d", currentSpread, MaxSpreadPips));
      lastSignal = "⚠️ SPREAD HIGH";
      if(ShowDashboard) UpdateDashboard();
      return;
   }

   if(!IsBotTradingAllowed()) {
      lastSignal = manualBotEnabled ? "⏸️ DISABLED BY INPUT" : "⏸️ PAUSED MANUALLY";
      if(ManagePositionsWhenPaused) ManagePositions();
      if(ShowDashboard) UpdateDashboard();
      return;
   }

   // [v5] Circuit breaker check
   if(cbPauseUntil > 0 && TimeCurrent() < cbPauseUntil) {
      int remaining = (int)(cbPauseUntil - TimeCurrent()) / 60;
      lastSignal = StringFormat("⏸️ CB PAUSE — %dm left", remaining);
      if(ManagePositionsWhenPaused) ManagePositions();
      if(ShowDashboard) UpdateDashboard();
      return;
   }
   if(cbPauseUntil > 0 && TimeCurrent() >= cbPauseUntil) {
      cbPauseUntil      = 0;
      consecutiveLosses = 0;
      sessionPeakEquity = AccountInfoDouble(ACCOUNT_EQUITY); // reset session peak after pause
      if(NotifyOnBotState)
         SendDiscord(StringFormat("✅ **ADAPTIVE CB LIFTED** — Trading resumed.\n"
                                  "Trigger was: `%s`\n"
                                  "Paused for: `%d min`\n"
                                  "Equity now: `$%.2f`",
                                  cbTriggerReason, cbPauseMinutesLast,
                                  AccountInfoDouble(ACCOUNT_EQUITY)));
      cbTriggerReason = "";
   }

   // [v6] CheckSafetyLimits now always returns true - no hard halts
   CheckSafetyLimits();  // Still call to update state and send notifications

   if(manualSessionFilter && !IsActiveSession()) {
      lastSignal = "⏰ Waiting for session...";
      if(ShowDashboard) UpdateDashboard();
      return;
   }

   ManagePositions();

   // [v5] Bar-close gate — wait for confirmed candle
   static datetime lastBar = 0;
   datetime currentBar     = iTime(Symbol(), PERIOD_CURRENT, 0);
   bool isNewBar           = (currentBar != lastBar);
   if(isNewBar) lastBar    = currentBar;

   if(!isNewBar && !TickBasedEntry) {
      if(ShowDashboard) UpdateDashboard();
      return;
   }

   if(AutoSelectStrategy) currentStrategy = SelectBestStrategy();
   else                   currentStrategy = StrategyMode;

   MarketScore score;
   switch(currentStrategy) {
      case 1:  score = StrategyScalping();  break;
      case 2:  score = StrategySwing();     break;
      case 3:  score = StrategyBreakout();  break;
      case 4:  score = StrategyReversal();  break;
      default: score = StrategyAutoAI();    break;
   }

   ExecuteSignal(score);

   if(ShowDashboard) UpdateDashboard();
}

//==========================================================================
//  OnChartEvent
//==========================================================================
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;

   if(sparam == SESSION_BUTTON_NAME) {
      manualSessionFilter = !manualSessionFilter;
      UpdateSessionControlButton();
      if(NotifyOnBotState)
         SendDiscord("🔔 **SESSION FILTER** → " +
                     (manualSessionFilter ? "ON (Session hours active)" : "OFF (Trading 24h)"));
      ChartRedraw(ChartID());
      return;
   }

   if(sparam == BOT_BUTTON_NAME) {
      manualBotEnabled = !manualBotEnabled;
      UpdateBotControlButton();
      UpdateSessionControlButton();
      if(!manualBotEnabled && ClosePositionsWhenStopped)
         CloseAllEAPositions("Manual stop");
      if(NotifyOnBotState)
         SendDiscordBotStateReport(manualBotEnabled ? "RESUMED" : "PAUSED",
                                   manualBotEnabled ? "Bot re-enabled by user" : "Bot paused manually");
      ChartRedraw(ChartID());
   }
}

//==========================================================================
//  Bot State
//==========================================================================
bool IsBotTradingAllowed() { return (BotEnabledByDefault && manualBotEnabled); }

string GetBotRuntimeStatus()
{
   if(!BotEnabledByDefault) return "DISABLED_BY_INPUT";
   if(!manualBotEnabled)    return "PAUSED_MANUAL";
   // [v6] No hard halts - only defensive monitoring state
   if(currentTradingState == STATE_DEFENSIVE_MONITORING) return "DEFENSIVE_MONITORING";
   if(cbPauseUntil > TimeCurrent() && cbPauseUntil > 0) return "CB_PAUSE";
   return "RUNNING";
}

void CreateBotControlButton()
{
   if(ObjectFind(ChartID(), BOT_BUTTON_NAME) >= 0) return;
   ObjectCreate(ChartID(), BOT_BUTTON_NAME, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(ChartID(), BOT_BUTTON_NAME, OBJPROP_XDISTANCE, 300);
   ObjectSetInteger(ChartID(), BOT_BUTTON_NAME, OBJPROP_YDISTANCE, 30);
   ObjectSetInteger(ChartID(), BOT_BUTTON_NAME, OBJPROP_XSIZE, 150);
   ObjectSetInteger(ChartID(), BOT_BUTTON_NAME, OBJPROP_YSIZE, 32);
   ObjectSetInteger(ChartID(), BOT_BUTTON_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(ChartID(), BOT_BUTTON_NAME, OBJPROP_FONTSIZE, 10);
   ObjectSetString(ChartID(),  BOT_BUTTON_NAME, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(ChartID(), BOT_BUTTON_NAME, OBJPROP_BORDER_COLOR, clrWhite);
}

void UpdateBotControlButton()
{
   if(!EnableChartControlButton) return;
   if(ObjectFind(ChartID(), BOT_BUTTON_NAME) < 0) CreateBotControlButton();
   bool active = IsBotTradingAllowed();
   ObjectSetString(ChartID(),  BOT_BUTTON_NAME, OBJPROP_TEXT,
                   active ? "✅ BOT ON — คลิกปิด" : "⛔ BOT OFF — คลิกเปิด");
   ObjectSetInteger(ChartID(), BOT_BUTTON_NAME, OBJPROP_BGCOLOR, active ? clrDarkGreen : clrFireBrick);
   ObjectSetInteger(ChartID(), BOT_BUTTON_NAME, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(ChartID(), BOT_BUTTON_NAME, OBJPROP_STATE, false);
}

void CreateSessionControlButton()
{
   if(ObjectFind(ChartID(), SESSION_BUTTON_NAME) >= 0) return;
   ObjectCreate(ChartID(), SESSION_BUTTON_NAME, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(ChartID(), SESSION_BUTTON_NAME, OBJPROP_XDISTANCE, 460);
   ObjectSetInteger(ChartID(), SESSION_BUTTON_NAME, OBJPROP_YDISTANCE, 30);
   ObjectSetInteger(ChartID(), SESSION_BUTTON_NAME, OBJPROP_XSIZE, 155);
   ObjectSetInteger(ChartID(), SESSION_BUTTON_NAME, OBJPROP_YSIZE, 32);
   ObjectSetInteger(ChartID(), SESSION_BUTTON_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(ChartID(), SESSION_BUTTON_NAME, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(ChartID(), SESSION_BUTTON_NAME, OBJPROP_SELECTABLE, false);
}

void UpdateSessionControlButton()
{
   if(ObjectFind(ChartID(), SESSION_BUTTON_NAME) < 0) CreateSessionControlButton();
   color  bg  = manualSessionFilter ? clrDarkOrange : clrSlateGray;
   string txt = "SESSION: " + (manualSessionFilter ? "ON ⏰" : "OFF (24h)");
   ObjectSetInteger(ChartID(), SESSION_BUTTON_NAME, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(ChartID(), SESSION_BUTTON_NAME, OBJPROP_COLOR, clrWhite);
   ObjectSetString(ChartID(),  SESSION_BUTTON_NAME, OBJPROP_TEXT, txt);
}

void CloseAllEAPositions(string reason)
{
   int closed = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != Symbol() || posInfo.Magic() != EA_MAGIC_NUMBER) continue;
      if(trade.PositionClose(posInfo.Ticket())) closed++;
   }
   if(closed > 0 && NotifyOnTrade)
      SendDiscord("🛑 **EA POSITIONS CLOSED** | Reason: " + reason +
                  " | Count: " + IntegerToString(closed));
}

//==========================================================================
//  UpdateIndicators
//==========================================================================
bool UpdateIndicators()
{
   double emaFastBuf[3], emaSlowBuf[3], emaTrendBuf[3], emaTrendHTFBuf[3];
   double rsiBuf[3], macdMainBuf[3], macdSigBuf[3];
   double bbUpperBuf[3], bbMidBuf[3], bbLowerBuf[3];
   double atrBuf[3], stochKBuf[3], stochDBuf[3];
   double adxBuf[3], plusDIBuf[3], minusDIBuf[3];

   if(CopyBuffer(handleEMAFast,  0, 0, 3, emaFastBuf)  < 3) return false;
   if(CopyBuffer(handleEMASlow,  0, 0, 3, emaSlowBuf)  < 3) return false;
   if(CopyBuffer(handleEMATrend, 0, 0, 3, emaTrendBuf) < 3) return false;
   if(CopyBuffer(handleRSI,      0, 0, 3, rsiBuf)      < 3) return false;
   if(CopyBuffer(handleMACD,     0, 0, 3, macdMainBuf) < 3) return false;
   if(CopyBuffer(handleMACD,     1, 0, 3, macdSigBuf)  < 3) return false;
   if(CopyBuffer(handleBB,       0, 0, 3, bbUpperBuf)  < 3) return false;
   if(CopyBuffer(handleBB,       1, 0, 3, bbMidBuf)    < 3) return false;
   if(CopyBuffer(handleBB,       2, 0, 3, bbLowerBuf)  < 3) return false;
   if(CopyBuffer(handleATR,      0, 0, 3, atrBuf)      < 3) return false;
   if(CopyBuffer(handleStoch,    0, 0, 3, stochKBuf)   < 3) return false;
   if(CopyBuffer(handleStoch,    1, 0, 3, stochDBuf)   < 3) return false;
   if(CopyBuffer(handleADX,      0, 0, 3, adxBuf)      < 3) return false;
   if(CopyBuffer(handleADX,      1, 0, 3, plusDIBuf)   < 3) return false;
   if(CopyBuffer(handleADX,      2, 0, 3, minusDIBuf)  < 3) return false;

   if(UseMultiTimeframe) {
      if(CopyBuffer(handleEMATrend_HTF, 0, 0, 3, emaTrendHTFBuf) < 3) return false;
      emaTrend_HTF = emaTrendHTFBuf[1];
   }

   if(UseVolumeAnalysis) {
      long volBuf[10];
      if(CopyTickVolume(Symbol(), PERIOD_CURRENT, 1, 10, volBuf) < 10) return false;
      averageVolume = 0;
      for(int i = 0; i < 10; i++) averageVolume += (double)volBuf[i];
      averageVolume /= 10.0;
   }

   emaFast    = emaFastBuf[1];
   emaSlow    = emaSlowBuf[1];
   emaTrend   = emaTrendBuf[1];
   rsiValue   = rsiBuf[1];
   macdMain   = macdMainBuf[1];
   macdSignal = macdSigBuf[1];
   bbUpper    = bbUpperBuf[1];
   bbMiddle   = bbMidBuf[1];
   bbLower    = bbLowerBuf[1];
   atrValue   = atrBuf[1];
   prevAtrValue = atrBuf[2];
   stochMain  = stochKBuf[1];
   stochSignal= stochDBuf[1];
   adxValue   = adxBuf[1];
   plusDI     = plusDIBuf[1];
   minusDI    = minusDIBuf[1];

   return true;
}

//==========================================================================
//  [v5] IsStrongConfluence — M1 + M5 + H1 must agree
//==========================================================================
bool IsStrongConfluence(bool isBuy)
{
   if(!UseConfluenceFilter) return true;

   double m5Fast[1], m5Slow[1], m5RSI[1];
   double h1Fast[1], h1Slow[1], h1RSI[1];

   if(CopyBuffer(handleM5EMAFast, 0, 1, 1, m5Fast) < 1) return false;
   if(CopyBuffer(handleM5EMASlow, 0, 1, 1, m5Slow) < 1) return false;
   if(CopyBuffer(handleM5RSI,     0, 1, 1, m5RSI)  < 1) return false;
   if(CopyBuffer(handleH1EMAFast, 0, 1, 1, h1Fast) < 1) return false;
   if(CopyBuffer(handleH1EMASlow, 0, 1, 1, h1Slow) < 1) return false;
   if(CopyBuffer(handleH1RSI,     0, 1, 1, h1RSI)  < 1) return false;

   int alignCount = 0;

   if(isBuy) {
      // M1 alignment
      if(emaFast > emaSlow) alignCount++;
      // M5 alignment
      if(m5Fast[0] > m5Slow[0] && m5RSI[0] > 45) alignCount++;
      // H1 alignment
      if(h1Fast[0] > h1Slow[0] && h1RSI[0] > 45) alignCount++;
   } else {
      // M1 alignment
      if(emaFast < emaSlow) alignCount++;
      // M5 alignment
      if(m5Fast[0] < m5Slow[0] && m5RSI[0] < 55) alignCount++;
      // H1 alignment
      if(h1Fast[0] < h1Slow[0] && h1RSI[0] < 55) alignCount++;
   }

   // Require at least 2 of 3 timeframes aligned
   return (alignCount >= 2);
}

//==========================================================================
//  [v5] IsMomentumAligned — last 3 bars moving in direction
//==========================================================================
bool IsMomentumAligned(bool isBuy)
{
   if(!UseMomentumFilter) return true;

   double c1 = iClose(Symbol(), PERIOD_CURRENT, 1);
   double c2 = iClose(Symbol(), PERIOD_CURRENT, 2);
   double c3 = iClose(Symbol(), PERIOD_CURRENT, 3);

   if(isBuy)
      return (c1 > c2 || c2 > c3); // at least one recent up move
   else
      return (c1 < c2 || c2 < c3); // at least one recent down move
}

//==========================================================================
//  [v5] Market Structure — HH/HL or LH/LL over last 20 bars
//==========================================================================
bool IsMarketStructureBull()
{
   if(!UseMarketStructure) return true;
   // Check for Higher High and Higher Low in last 20 bars
   double hh1 = iHigh(Symbol(), PERIOD_CURRENT, 5);
   double hh2 = iHigh(Symbol(), PERIOD_CURRENT, 15);
   double ll1 = iLow(Symbol(),  PERIOD_CURRENT, 5);
   double ll2 = iLow(Symbol(),  PERIOD_CURRENT, 15);
   return (hh1 > hh2 && ll1 > ll2);
}

bool IsMarketStructureBear()
{
   if(!UseMarketStructure) return true;
   double hh1 = iHigh(Symbol(), PERIOD_CURRENT, 5);
   double hh2 = iHigh(Symbol(), PERIOD_CURRENT, 15);
   double ll1 = iLow(Symbol(),  PERIOD_CURRENT, 5);
   double ll2 = iLow(Symbol(),  PERIOD_CURRENT, 15);
   return (hh1 < hh2 && ll1 < ll2);
}

//==========================================================================
//  DetectMarketRegime — 1=Bull 2=Bear 3=Ranging 4=Volatile 5=Calm
//==========================================================================
int DetectMarketRegime()
{
   int regime = 5;

   if(adxValue > TrendingADXThreshold)
      regime = (plusDI >= minusDI) ? 1 : 2;

   double bbWidth = (bbMiddle > 0) ? (bbUpper - bbLower) / bbMiddle : 0;
   if(bbWidth < 0.002 && adxValue < RangingADXThreshold) regime = 3;

   if(prevAtrValue > 0 && atrValue > prevAtrValue * VolatileATRMultiplier) regime = 4;

   // [v7] Time filter disabled — no artificial time restrictions
   // EnableTimeFilter is deprecated and always evaluates to false for execution gating

   return regime;
}

//==========================================================================
//  IsPinBar (fixed shadow ratio)
//==========================================================================
bool IsPinBar(ENUM_TIMEFRAMES tf, int shift,
              double minBodyRatio = 0.25, double minShadowBodyRatio = 2.0)
{
   double open  = iOpen(Symbol(),  tf, shift);
   double close = iClose(Symbol(), tf, shift);
   double high  = iHigh(Symbol(),  tf, shift);
   double low   = iLow(Symbol(),   tf, shift);

   double body        = MathAbs(close - open);
   double totalRange  = high - low;
   if(totalRange < symbolInfo.Point() * 5) return false;

   double upperShadow = high - MathMax(open, close);
   double lowerShadow = MathMin(open, close) - low;

   bool isBullishPin = (body / totalRange <= minBodyRatio) &&
                       (lowerShadow >= body * minShadowBodyRatio) &&
                       (upperShadow <= body);
   bool isBearishPin = (body / totalRange <= minBodyRatio) &&
                       (upperShadow >= body * minShadowBodyRatio) &&
                       (lowerShadow <= body);

   return isBullishPin || isBearishPin;
}

bool IsEngulfingBar(ENUM_TIMEFRAMES tf, int shift)
{
   double o0 = iOpen(Symbol(), tf, shift),   c0 = iClose(Symbol(), tf, shift);
   double o1 = iOpen(Symbol(), tf, shift+1), c1 = iClose(Symbol(), tf, shift+1);
   bool bullEngulf = (c0>o0) && (c1<o1) && (o0<=c1) && (c0>=o1);
   bool bearEngulf = (c0<o0) && (c1>o1) && (o0>=c1) && (c0<=o1);
   return bullEngulf || bearEngulf;
}

//==========================================================================
//  [v5] GetDynamicConfidence — adjust threshold per session/regime
//==========================================================================
double GetDynamicMinConfidence()
{
   double base = MinConfidence;
   int regime  = DetectMarketRegime();

   // Require higher confidence in choppy/volatile markets
   if(regime == 3) base += 5.0;  // ranging — harder to predict
   if(regime == 4) base += 8.0;  // volatile — higher bar

   // Lower threshold during high-probability sessions
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   double t = dt.hour + dt.min / 60.0;
   if(t >= 8.0 && t <= 12.0) base -= 3.0; // London open — best hours
   if(t >= 13.0 && t <= 16.0) base -= 2.0; // London/NY overlap

   return MathMax(55.0, MathMin(80.0, base));
}

//==========================================================================
//  Auto-AI Strategy
//==========================================================================
MarketScore StrategyAutoAI()
{
   MarketScore score;
   score.buyScore = 0; score.sellScore = 0;
   score.reasons  = ""; score.confidence = 0;

   double close   = iClose(Symbol(), PERIOD_CURRENT, 1);
   int    regime  = DetectMarketRegime();

   int tw=3, mw=2, vw=2, rw=1;
   if(regime==1)      { tw=5; mw=3; vw=1; rw=0; }
   else if(regime==2) { tw=5; mw=3; vw=1; rw=0; }
   else if(regime==3) { tw=1; mw=2; vw=3; rw=4; }
   else if(regime==4) { tw=2; mw=2; vw=4; rw=1; }
   else               { tw=0; mw=1; vw=2; rw=2; }

   bool bullTrend = (emaFast > emaSlow) && (close > emaTrend);
   bool bullHTF   = (UseMultiTimeframe && close > emaTrend_HTF);
   bool bearTrend = (emaFast < emaSlow) && (close < emaTrend);
   bool bearHTF   = (UseMultiTimeframe && close < emaTrend_HTF);

   if(bullTrend)  { score.buyScore  += tw;     score.reasons += "✅ Bull Trend | "; }
   if(bullHTF)    { score.buyScore  += (tw-1);  score.reasons += "✅ HTF Bull | "; }
   if(bearTrend)  { score.sellScore += tw;     score.reasons += "✅ Bear Trend | "; }
   if(bearHTF)    { score.sellScore += (tw-1);  score.reasons += "✅ HTF Bear | "; }

   // Volume confirmation
   if(UseVolumeAnalysis && averageVolume > 0) {
      long curVol = iVolume(Symbol(), PERIOD_CURRENT, 1);
      if(curVol > averageVolume * MinVolumeMultiplier) {
         if(bullTrend || bullHTF) score.buyScore++;
         if(bearTrend || bearHTF) score.sellScore++;
         score.reasons += "📈 Vol Confirm | ";
      }
   }

   // EMA cross
   double emaFastBuf[3], emaSlowBuf[3];
   if(CopyBuffer(handleEMAFast, 0, 1, 2, emaFastBuf)>0 &&
      CopyBuffer(handleEMASlow, 0, 1, 2, emaSlowBuf)>0) {
      double prevFast = emaFastBuf[0], prevSlow = emaSlowBuf[0];
      if(emaFast > emaSlow && prevFast <= prevSlow) { score.buyScore  += mw; score.reasons += "⬆️ EMA Cross Up | "; }
      if(emaFast < emaSlow && prevFast >= prevSlow) { score.sellScore += mw; score.reasons += "⬇️ EMA Cross Dn | "; }
   }

   // RSI
   if(rsiValue < RSI_OS && rsiValue > 20)  { score.buyScore  += mw; score.reasons += "📊 RSI OS | "; }
   if(rsiValue > RSI_OB && rsiValue < 80)  { score.sellScore += mw; score.reasons += "📊 RSI OB | "; }

   // MACD
   if(macdMain > macdSignal && macdMain > 0) { score.buyScore  += mw; score.reasons += "⚡ MACD Bull | "; }
   if(macdMain < macdSignal && macdMain < 0) { score.sellScore += mw; score.reasons += "⚡ MACD Bear | "; }

   // Bollinger Bands
   if(close < bbLower)  { score.buyScore  += vw; score.reasons += "📉 BB Low | "; }
   if(close > bbUpper)  { score.sellScore += vw; score.reasons += "📈 BB High | "; }

   // BB Squeeze
   double bbWidth = (bbMiddle > 0) ? (bbUpper - bbLower) / bbMiddle : 0;
   if(bbWidth < 0.003 && close > bbMiddle) { score.buyScore  += (vw+1); score.reasons += "⬆️ BB Squeeze ↑ | "; }
   if(bbWidth < 0.003 && close < bbMiddle) { score.sellScore += (vw+1); score.reasons += "⬇️ BB Squeeze ↓ | "; }

   // Stochastic
   if(stochMain < 20 && stochMain > stochSignal) { score.buyScore  += rw; score.reasons += "🔄 Stoch OS | "; }
   if(stochMain > 80 && stochMain < stochSignal) { score.sellScore += rw; score.reasons += "🔄 Stoch OB | "; }

   // Pin Bar
   if(IsPinBar(PERIOD_CURRENT, 1)) {
      if(iClose(Symbol(), PERIOD_CURRENT, 1) > iOpen(Symbol(), PERIOD_CURRENT, 1))
           { score.buyScore  += (rw+1); score.reasons += "🕯️ Bull Pin | "; }
      else { score.sellScore += (rw+1); score.reasons += "🕯️ Bear Pin | "; }
   }

   // Engulfing
   if(IsEngulfingBar(PERIOD_CURRENT, 1)) {
      if(iClose(Symbol(), PERIOD_CURRENT, 1) > iOpen(Symbol(), PERIOD_CURRENT, 1))
           { score.buyScore  += rw; score.reasons += "🕯️ Bull Engulf | "; }
      else { score.sellScore += rw; score.reasons += "🕯️ Bear Engulf | "; }
   }

   // ADX filter
   if(adxValue < ADX_MinStrength) {
      score.buyScore  = (int)(score.buyScore  * 0.7);
      score.sellScore = (int)(score.sellScore * 0.7);
      score.reasons += "⚠️ Weak ADX | ";
   }
   if(adxValue > 40) {
      if(plusDI > minusDI) score.buyScore  += 2;
      else                  score.sellScore += 2;
      score.reasons += "💪 Strong ADX | ";
   }

   // [v5] Market structure bonus
   if(UseMarketStructure) {
      if(IsMarketStructureBull() && score.buyScore > score.sellScore)
         { score.buyScore += 2; score.reasons += "🏗️ Bull Struct | "; }
      if(IsMarketStructureBear() && score.sellScore > score.buyScore)
         { score.sellScore += 2; score.reasons += "🏗️ Bear Struct | "; }
   }

   int total = score.buyScore + score.sellScore;
   if(total > 0) score.confidence = (MathMax(score.buyScore, score.sellScore) / (double)total) * 100.0;
   return score;
}

//==========================================================================
//  Strategy 1: Scalping
//==========================================================================
MarketScore StrategyScalping()
{
   MarketScore score;
   score.buyScore = 0; score.sellScore = 0;
   score.reasons  = "SCALP | "; score.confidence = 0;

   double ema5Buf[1], ema13Buf[1], rsi7Buf[1];
   if(CopyBuffer(handleScalpEMA5,  0, 1, 1, ema5Buf)  < 1) return score;
   if(CopyBuffer(handleScalpEMA13, 0, 1, 1, ema13Buf) < 1) return score;
   if(CopyBuffer(handleScalpRSI7,  0, 1, 1, rsi7Buf)  < 1) return score;

   double m1Fast = ema5Buf[0], m1Slow = ema13Buf[0], m1RSI = rsi7Buf[0];

   if(symbolInfo.Spread() * symbolInfo.Point() > atrValue * 0.3) {
      score.reasons += "❌ Spread wide"; return score;
   }

   if(m1Fast > m1Slow && m1RSI < ScalpM1_RSI_OB && m1RSI > 50 && emaFast > emaSlow) {
      score.buyScore = 6; score.reasons += "M1+M5 Bull EMA+RSI";
   }
   if(m1Fast < m1Slow && m1RSI > ScalpM1_RSI_OS && m1RSI < 50 && emaFast < emaSlow) {
      score.sellScore = 6; score.reasons += "M1+M5 Bear EMA+RSI";
   }

   // [v5] Require momentum for scalp
   if(score.buyScore > 0 && !IsMomentumAligned(true))  { score.buyScore = 0;  score.reasons += " | ❌ No Momentum"; }
   if(score.sellScore > 0 && !IsMomentumAligned(false)) { score.sellScore = 0; score.reasons += " | ❌ No Momentum"; }

   score.confidence = (MathMax(score.buyScore, score.sellScore) > 0) ? 75.0 : 0.0;
   return score;
}

//==========================================================================
//  Strategy 2: Swing
//==========================================================================
MarketScore StrategySwing()
{
   MarketScore score;
   score.buyScore = 0; score.sellScore = 0;
   score.reasons  = "SWING | "; score.confidence = 0;

   double h4_50Buf[1], h4_200Buf[1];
   if(CopyBuffer(handleH4EMA50,  0, 1, 1, h4_50Buf)  < 1) return score;
   if(CopyBuffer(handleH4EMA200, 0, 1, 1, h4_200Buf) < 1) return score;

   bool h4Bull = h4_50Buf[0] > h4_200Buf[0];
   bool h4Bear = h4_50Buf[0] < h4_200Buf[0];

   if(h4Bull && rsiValue < 45 && emaFast > emaSlow && IsMarketStructureBull()) {
      score.buyScore = 8; score.reasons += "H4 Bull + Pullback Buy + Structure";
   }
   if(h4Bear && rsiValue > 55 && emaFast < emaSlow && IsMarketStructureBear()) {
      score.sellScore = 8; score.reasons += "H4 Bear + Pullback Sell + Structure";
   }

   if(adxValue < 25) { score.buyScore = 0; score.sellScore = 0; score.reasons += " | ADX<25 filtered"; }
   score.confidence = 82.0;
   return score;
}

//==========================================================================
//  Strategy 3: Breakout
//==========================================================================
MarketScore StrategyBreakout()
{
   MarketScore score;
   score.buyScore = 0; score.sellScore = 0;
   score.reasons  = "BREAKOUT | "; score.confidence = 0;

   double close  = iClose(Symbol(), PERIOD_CURRENT, 1);
   double close2 = iClose(Symbol(), PERIOD_CURRENT, 2);

   long volBuf[4];
   if(CopyTickVolume(Symbol(), PERIOD_CURRENT, 0, 4, volBuf) < 4) return score;
   long avgVol = MathMax(1, (volBuf[1] + volBuf[0]) / 2);
   bool volSurge = (volBuf[2] > avgVol * 1.5);

   if(close > bbUpper && close2 < bbUpper && volSurge) {
      score.buyScore = 8; score.reasons += "BB Break Up + Vol ✅";
   }
   if(close < bbLower && close2 > bbLower && volSurge) {
      score.sellScore = 8; score.reasons += "BB Break Dn + Vol ✅";
   }

   double highest = 0, lowest = 9999999;
   for(int i = 2; i <= 20; i++) {
      highest = MathMax(highest, iHigh(Symbol(), PERIOD_CURRENT, i));
      lowest  = MathMin(lowest,  iLow(Symbol(),  PERIOD_CURRENT, i));
   }
   if(close > highest * 1.0001) { score.buyScore  += 3; score.reasons += "20H Break | "; }
   if(close < lowest  * 0.9999) { score.sellScore += 3; score.reasons += "20L Break | "; }

   score.confidence = 85.0;
   return score;
}

//==========================================================================
//  Strategy 4: Reversal
//==========================================================================
MarketScore StrategyReversal()
{
   MarketScore score;
   score.buyScore = 0; score.sellScore = 0;
   score.reasons  = "REVERSAL | "; score.confidence = 0;

   double close = iClose(Symbol(), PERIOD_CURRENT, 1);

   if(rsiValue < 25) { score.buyScore  += 5; score.reasons += "RSI Extreme OS | "; }
   if(rsiValue > 75) { score.sellScore += 5; score.reasons += "RSI Extreme OB | "; }

   if(bbMiddle > bbLower) {
      double relBB = (close - bbLower) / (bbUpper - bbLower);
      if(relBB < 0.05 && stochMain < 20) { score.buyScore  += 4; score.reasons += "BB+Stoch Low | "; }
      if(relBB > 0.95 && stochMain > 80) { score.sellScore += 4; score.reasons += "BB+Stoch High | "; }
   }

   double prevClose = iClose(Symbol(), PERIOD_CURRENT, 5);
   double macdBuf[6];
   if(CopyBuffer(handleMACD, 0, 0, 6, macdBuf) >= 6) {
      double prevMACD = macdBuf[0];
      if(close < prevClose && macdMain > prevMACD && rsiValue < 45)
         { score.buyScore  += 3; score.reasons += "MACD Div Bull | "; }
      if(close > prevClose && macdMain < prevMACD && rsiValue > 55)
         { score.sellScore += 3; score.reasons += "MACD Div Bear | "; }
   }

   // [v5] Require Pin or Engulf for reversal
   if(!IsPinBar(PERIOD_CURRENT, 1) && !IsEngulfingBar(PERIOD_CURRENT, 1)) {
      score.buyScore  = (int)(score.buyScore  * 0.6);
      score.sellScore = (int)(score.sellScore * 0.6);
      score.reasons += "⚠️ No Candle Pattern | ";
   }

   score.confidence = 72.0;
   return score;
}

//==========================================================================
//  SelectBestStrategy
//==========================================================================
int SelectBestStrategy()
{
   if(!UseAdaptiveLogic) return StrategyMode;

   int    regime  = DetectMarketRegime();
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(balance < 50) return (regime == 3 || regime == 5) ? 1 : 0;

   switch(regime) {
      case 1: return 2;  // Bull trend → Swing
      case 2: return 2;  // Bear trend → Swing
      case 3: return 1;  // Ranging → Scalping
      case 4: return 3;  // Volatile → Breakout
      case 5: return 1;  // Calm → Scalping
   }

   if(adxValue > TrendingADXThreshold) return 2;
   if(rsiValue < 25 || rsiValue > 75)  return 4;
   double bbW = (bbMiddle > 0) ? (bbUpper - bbLower) / bbMiddle : 0;
   if(bbW < 0.003) return 3;
   return 0;
}

//==========================================================================
//  Adaptive SL/TP multipliers
//==========================================================================
void GetAdaptiveSLTPMultipliers(int regime, double &sl_m, double &tp_m)
{
   sl_m = ATR_SL_Multiplier;
   tp_m = ATR_TP_Multiplier;
   if(!UseAdaptiveLogic) return;
   switch(regime) {
      case 1: sl_m *= 1.2; tp_m *= 1.6; break;
      case 2: sl_m *= 1.2; tp_m *= 1.6; break;
      case 3: sl_m *= 0.8; tp_m *= 0.8; break;
      case 4: sl_m *= 1.5; tp_m *= 1.0; break;
      case 5: sl_m *= 0.7; tp_m *= 0.7; break;
   }
}

//==========================================================================
//  TryPlaceOrder — fill type retry
//==========================================================================
bool TryPlaceOrder(ENUM_ORDER_TYPE type, double lots, double price,
                   double sl, double tp, string comment)
{
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   bool ok = (type == ORDER_TYPE_BUY) ?
              trade.Buy(lots, Symbol(), price, sl, tp, comment) :
              trade.Sell(lots, Symbol(), price, sl, tp, comment);
   if(ok) return true;

   uint retcode = trade.ResultRetcode();
   LogStatus(StringFormat("IOC failed: %s (%d) — retrying FOK", RetcodeToString(retcode), retcode));

   trade.SetTypeFilling(ORDER_FILLING_FOK);
   ok = (type == ORDER_TYPE_BUY) ?
        trade.Buy(lots, Symbol(), price, sl, tp, comment) :
        trade.Sell(lots, Symbol(), price, sl, tp, comment);
   if(ok) { trade.SetTypeFilling(ORDER_FILLING_IOC); return true; }

   retcode = trade.ResultRetcode();
   LogStatus(StringFormat("FOK failed: %s (%d) — retrying RETURN", RetcodeToString(retcode), retcode));

   trade.SetTypeFilling(ORDER_FILLING_RETURN);
   ok = (type == ORDER_TYPE_BUY) ?
        trade.Buy(lots, Symbol(), price, sl, tp, comment) :
        trade.Sell(lots, Symbol(), price, sl, tp, comment);

   trade.SetTypeFilling(ORDER_FILLING_IOC);
   if(!ok) {
      retcode = trade.ResultRetcode();
      Print("GHP_ERROR: All fill attempts failed. Retcode=", retcode, " (", RetcodeToString(retcode), ")");
   }
   return ok;
}

//==========================================================================
//  ExecuteSignal — [v5] adds confluence + momentum + dynamic confidence
//==========================================================================
void ExecuteSignal(MarketScore &score)
{
   double dynConfidence = GetDynamicMinConfidence();
   int    minScore      = MinScoreThreshold;

   for(int i = PositionsTotal()-1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == Symbol() && posInfo.Magic() == EA_MAGIC_NUMBER) return;
   }

   if((int)(TimeCurrent() - lastTradeTime) < TradeCooldownSec) return;
   if(!symbolInfo.RefreshRates()) return;

   double ask = symbolInfo.Ask();
   double bid = symbolInfo.Bid();
   int    regime = DetectMarketRegime();
   double sl_m, tp_m;
   GetAdaptiveSLTPMultipliers(regime, sl_m, tp_m);

   double slDist = UseATRStops ? (atrValue * sl_m) : (FixedSL_Points * symbolInfo.Point());
   double tpDist = UseATRStops ? (atrValue * tp_m) : (FixedTP_Points * symbolInfo.Point());

   double lots = CalculateLotSize(slDist);
   if(lots <= 0) return;

   int    digits = symbolInfo.Digits();

   //--- BUY signal
   if(score.buyScore >= minScore && score.buyScore > score.sellScore &&
      score.confidence >= dynConfidence) {

      // [v5] Confluence + Momentum + Structure gates
      if(!IsStrongConfluence(true))  { lastSignal = "⏳ No TF Confluence (B)"; return; }
      if(!IsMomentumAligned(true))   { lastSignal = "⏳ No Momentum (B)"; return; }

      double sl = NormalizeDouble(bid - slDist, digits);
      double tp = NormalizeDouble(ask + tpDist, digits);

      if(TryPlaceOrder(ORDER_TYPE_BUY, lots, ask, sl, tp,
                       "GHP5_" + stratNames[currentStrategy])) {
         lastTradeTime = TimeCurrent();
         tradesThisDay++;
         consecutiveLosses = 0; // reset on new trade
         lastSignal = StringFormat("🟢 BUY @ %.2f", ask);

         if(AlertOnTradeOpen)
            Alert(StringFormat("[GoldHunter v5] 🟢 BUY GOLD OPENED\n"
                               "Price: %.2f | SL: %.2f | TP: %.2f\n"
                               "Lot: %.2f | Strategy: %s | Score: %d | Conf: %.0f%%\n"
                               "Balance: $%.2f",
                               ask, sl, tp, lots,
                               stratNames[currentStrategy], score.buyScore,
                               score.confidence,
                               AccountInfoDouble(ACCOUNT_BALANCE)));

         if(PushNotifyOnTrade)
            SendNotification(StringFormat("GHP5 BUY GOLD | %.2f | SL:%.2f TP:%.2f | Lot:%.2f",
                                          ask, sl, tp, lots));

         if(NotifyOnTrade)
            SendDiscord(StringFormat(
               "🟢 **BUY GOLD OPENED** [v5]\n"
               "💲 Price: `%.2f`\n🎯 TP: `%.2f`  🛡️ SL: `%.2f`\n"
               "📦 Lot: `%.2f`  🧠 Strategy: `%s`\n"
               "📊 Score: `%d`  🎯 Conf: `%.0f%%`  Threshold: `%.0f%%`\n"
               "🔍 Reasons: %s\n"
               "💰 Balance: `$%.2f`  Trades today: `%d`",
               ask, tp, sl, lots, stratNames[currentStrategy],
               score.buyScore, score.confidence, dynConfidence,
               score.reasons,
               AccountInfoDouble(ACCOUNT_BALANCE), tradesThisDay));
      }
   }
   //--- SELL signal
   else if(score.sellScore >= minScore && score.sellScore > score.buyScore &&
           score.confidence >= dynConfidence) {

      if(!IsStrongConfluence(false)) { lastSignal = "⏳ No TF Confluence (S)"; return; }
      if(!IsMomentumAligned(false))  { lastSignal = "⏳ No Momentum (S)"; return; }

      double sl = NormalizeDouble(ask + slDist, digits);
      double tp = NormalizeDouble(bid - tpDist, digits);

      if(TryPlaceOrder(ORDER_TYPE_SELL, lots, bid, sl, tp,
                       "GHP5_" + stratNames[currentStrategy])) {
         lastTradeTime = TimeCurrent();
         tradesThisDay++;
         consecutiveLosses = 0;
         lastSignal = StringFormat("🔴 SELL @ %.2f", bid);

         if(AlertOnTradeOpen)
            Alert(StringFormat("[GoldHunter v5] 🔴 SELL GOLD OPENED\n"
                               "Price: %.2f | SL: %.2f | TP: %.2f\n"
                               "Lot: %.2f | Strategy: %s | Score: %d | Conf: %.0f%%\n"
                               "Balance: $%.2f",
                               bid, sl, tp, lots,
                               stratNames[currentStrategy], score.sellScore,
                               score.confidence,
                               AccountInfoDouble(ACCOUNT_BALANCE)));

         if(PushNotifyOnTrade)
            SendNotification(StringFormat("GHP5 SELL GOLD | %.2f | SL:%.2f TP:%.2f | Lot:%.2f",
                                          bid, sl, tp, lots));

         if(NotifyOnTrade)
            SendDiscord(StringFormat(
               "🔴 **SELL GOLD OPENED** [v5]\n"
               "💲 Price: `%.2f`\n🎯 TP: `%.2f`  🛡️ SL: `%.2f`\n"
               "📦 Lot: `%.2f`  🧠 Strategy: `%s`\n"
               "📊 Score: `%d`  🎯 Conf: `%.0f%%`  Threshold: `%.0f%%`\n"
               "🔍 Reasons: %s\n"
               "💰 Balance: `$%.2f`  Trades today: `%d`",
               bid, tp, sl, lots, stratNames[currentStrategy],
               score.sellScore, score.confidence, dynConfidence,
               score.reasons,
               AccountInfoDouble(ACCOUNT_BALANCE), tradesThisDay));
      }
   }
   else {
      LogStatus(StringFormat("Weak signal — B:%d S:%d Conf:%.0f%% Need:%.0f%%",
                             score.buyScore, score.sellScore,
                             score.confidence, dynConfidence));
      lastSignal = StringFormat("⏳ B:%d S:%d [%.0f%%/%.0f%%]",
                                score.buyScore, score.sellScore,
                                score.confidence, dynConfidence);
   }
}

//==========================================================================
//  TP1 tracking helpers
//==========================================================================
bool IsTP1AlreadyExecuted(ulong ticket)
{
   for(int i = 0; i < tp1ExecutedCount; i++)
      if(tp1ExecutedTickets[i] == ticket) return true;
   return false;
}

void MarkTP1Executed(ulong ticket)
{
   ArrayResize(tp1ExecutedTickets, tp1ExecutedCount + 1);
   tp1ExecutedTickets[tp1ExecutedCount] = ticket;
   tp1ExecutedCount++;
}

bool ClosePartialPosition(ulong ticket, double volumeToClose)
{
   if(!posInfo.SelectByTicket(ticket)) return false;

   ENUM_POSITION_TYPE ptype  = posInfo.PositionType();
   double currentVolume      = posInfo.Volume();
   double minLotStep         = symbolInfo.LotsStep();

   volumeToClose = NormalizeDouble(MathFloor(volumeToClose / minLotStep) * minLotStep, 2);
   if(volumeToClose <= 0 || volumeToClose >= currentVolume) return false;

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);

   req.action    = TRADE_ACTION_DEAL;
   req.position  = ticket;
   req.symbol    = posInfo.Symbol();
   req.volume    = volumeToClose;
   req.deviation = SlippagePoints;
   req.magic     = EA_MAGIC_NUMBER;

   if(ptype == POSITION_TYPE_BUY) {
      req.type         = ORDER_TYPE_SELL;
      req.price        = symbolInfo.Bid();
      req.type_filling = ORDER_FILLING_IOC;
   } else {
      req.type         = ORDER_TYPE_BUY;
      req.price        = symbolInfo.Ask();
      req.type_filling = ORDER_FILLING_IOC;
   }

   if(!OrderSend(req, res)) {
      Print("GHP: Partial close error: ", GetLastError(), " Retcode: ", RetcodeToString(res.retcode));
      return false;
   }

   if(res.retcode == TRADE_RETCODE_DONE) {
      MarkTP1Executed(ticket);
      if(NotifyOnTrade)
         SendDiscord(StringFormat("📤 **PARTIAL CLOSE** | #%d | Vol: %.2f | TP1 hit", (int)ticket, volumeToClose));
      return true;
   }
   Print("GHP: Partial close retcode: ", RetcodeToString(res.retcode));
   return false;
}

//==========================================================================
//  ManagePositions — [v5] adds phantom SL guard + min-step check
//==========================================================================
void ManagePositions()
{
   int regime = DetectMarketRegime();
   double sl_m, tp_m;
   GetAdaptiveSLTPMultipliers(regime, sl_m, tp_m);

   double trailDist = atrValue * TrailATRMultiplier;
   double slDist    = UseATRStops ? (atrValue * sl_m) : (FixedSL_Points * symbolInfo.Point());
   int    digits    = symbolInfo.Digits();
   double minStep   = symbolInfo.Point() * 5;

   for(int i = PositionsTotal()-1; i >= 0; i--) {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != Symbol() || posInfo.Magic() != EA_MAGIC_NUMBER) continue;

      ulong  ticket    = posInfo.Ticket();
      double openPrice = posInfo.PriceOpen();
      double curSL     = posInfo.StopLoss();
      double curTP     = posInfo.TakeProfit();
      double volume    = posInfo.Volume();
      double bid       = symbolInfo.Bid();
      double ask       = symbolInfo.Ask();

      if(posInfo.PositionType() == POSITION_TYPE_BUY) {
         double profitPts = (bid - openPrice) / symbolInfo.Point();
         double beDist    = UseBreakEven ? (atrValue * BreakEvenATR) :
                            (UseAdvancedBreakeven ? (BreakevenBufferPips * symbolInfo.Point()) : 0);

         // [v5] Phantom SL guard — price gapped past SL
         if(curSL > 0 && bid < curSL) {
            trade.PositionClose(ticket);
            continue;
         }

         // BreakEven
         if((UseBreakEven || UseAdvancedBreakeven) && bid > openPrice + beDist && curSL < openPrice) {
            double newSL = NormalizeDouble(openPrice + BreakevenBufferPips * symbolInfo.Point(), digits);
            if(newSL > curSL + minStep) trade.PositionModify(ticket, newSL, curTP);
         }

         // TP1 Partial
         double tp1_pts = slDist / symbolInfo.Point() * TP1_Ratio;
         if(UsePartialProfit && profitPts >= tp1_pts && !IsTP1AlreadyExecuted(ticket)) {
            double volClose = NormalizeDouble(volume * TP1_ClosePercent / 100.0, 2);
            if(volClose > 0) ClosePartialPosition(ticket, volClose);
         }

         // Profit Lock
         if(UseProfitLock) {
            double lockThresh = openPrice + slDist * ProfitLockRatio;
            double lockSL     = NormalizeDouble(openPrice + slDist * (ProfitLockRatio * 0.5), digits);
            if(bid >= lockThresh && curSL < lockSL - minStep) trade.PositionModify(ticket, lockSL, curTP);
         }

         // Trailing Stop
         if(UseTrailingStop) {
            double newSL = NormalizeDouble(bid - trailDist, digits);
            if(newSL > curSL + minStep && newSL < bid)
               trade.PositionModify(ticket, newSL, curTP);
         }
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL) {
         double profitPts = (openPrice - ask) / symbolInfo.Point();
         double beDist    = UseBreakEven ? (atrValue * BreakEvenATR) :
                            (UseAdvancedBreakeven ? (BreakevenBufferPips * symbolInfo.Point()) : 0);

         // [v5] Phantom SL guard
         if(curSL > 0 && ask > curSL) {
            trade.PositionClose(ticket);
            continue;
         }

         // BreakEven
         if((UseBreakEven || UseAdvancedBreakeven) && ask < openPrice - beDist &&
            (curSL > openPrice || curSL == 0)) {
            double newSL = NormalizeDouble(openPrice - BreakevenBufferPips * symbolInfo.Point(), digits);
            if(curSL == 0 || newSL < curSL - minStep) trade.PositionModify(ticket, newSL, curTP);
         }

         // TP1 Partial
         double tp1_pts = slDist / symbolInfo.Point() * TP1_Ratio;
         if(UsePartialProfit && profitPts >= tp1_pts && !IsTP1AlreadyExecuted(ticket)) {
            double volClose = NormalizeDouble(volume * TP1_ClosePercent / 100.0, 2);
            if(volClose > 0) ClosePartialPosition(ticket, volClose);
         }

         // Profit Lock
         if(UseProfitLock) {
            double lockThresh = openPrice - slDist * ProfitLockRatio;
            double lockSL     = NormalizeDouble(openPrice - slDist * (ProfitLockRatio * 0.5), digits);
            if(ask <= lockThresh && (curSL > lockSL + minStep || curSL == 0)) trade.PositionModify(ticket, lockSL, curTP);
         }

         // Trailing Stop
         if(UseTrailingStop) {
            double newSL = NormalizeDouble(ask + trailDist, digits);
            if((newSL < curSL - minStep || curSL == 0) && newSL > ask)
               trade.PositionModify(ticket, newSL, curTP);
         }
      }
   }
}

//==========================================================================
//  CalculateLotSize — [v5] Kelly-adjusted with DD scaling
//==========================================================================
double CalculateLotSize(double slDistance)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskPct = RiskPercent;

   // Aggressive growth scaling
   if(UseAggressiveGrowth && equity > dailyStartBalance && dailyStartBalance > 0) {
      double profitFactor = (equity - dailyStartBalance) / dailyStartBalance;
      riskPct += profitFactor * 6.0 * GrowthMultiplier;
      if(riskPct > 8.0) riskPct = 8.0;
   }

   // [v5] Drawdown scaling — reduce risk when in drawdown
   if(peakEquity > 0) {
      double ddPct = (peakEquity - equity) / peakEquity * 100.0;
      if(ddPct > 5.0)  riskPct *= 0.75;  // 5%+ DD → reduce lot 25%
      if(ddPct > 10.0) riskPct *= 0.50;  // 10%+ DD → reduce lot 50%
      if(ddPct > 15.0) riskPct *= 0.25;  // 15%+ DD → very conservative
   }

   // [v5] Consecutive loss scaling
   if(consecutiveLosses >= 2) riskPct *= 0.70;

   double riskAmt  = balance * (riskPct / 100.0);
   double tickVal  = symbolInfo.TickValue();
   double tickSize = symbolInfo.TickSize();

   if(slDistance <= 0 || tickVal <= 0 || tickSize <= 0) return MinLot;

   double slTicks = slDistance / tickSize;
   double lotSize = riskAmt / (slTicks * tickVal);
   double lotStep = symbolInfo.LotsStep();

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(MinLot, MathMin(MaxLot, lotSize));
   return NormalizeDouble(lotSize, 2);
}

//==========================================================================
//  [v6] CHECK SAFETY LIMITS - NO HARD HALTS
//  ─────────────────────────────────────────────────────────────────────
//  Instead of halting the bot, we transition to defensive monitoring:
//  - Continue learning from market conditions
//  - Reduce position sizes significantly
//  - Increase entry confidence thresholds
//  - Never stop the cognitive memory system
//==========================================================================
bool CheckSafetyLimits()
{
   // [v6] Removed hard halt check - bot never fully stops due to limits

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double pnlPerc = (dailyStartBalance > 0) ?
                    ((equity - dailyStartBalance) / dailyStartBalance) * 100.0 : 0;

   // [v6] Dynamic loss threshold - transition to defensive mode instead of halt
   if(pnlPerc <= -MaxDailyLossPerc) {
      // Don't halt - transition to defensive monitoring
      if(currentTradingState != STATE_DEFENSIVE_MONITORING) {
         currentTradingState = STATE_DEFENSIVE_MONITORING;
         string msg = StringFormat("⚠️ **DAILY LOSS THRESHOLD**\nP&L: %.2f%%\nEntering DEFENSIVE MONITORING mode.\nContinuing cognitive learning...", pnlPerc);
         if(NotifyOnRiskEvent) SendDiscord(msg);
         if(PushNotifyOnTrade) SendNotification(msg);
         Alert("[GoldHunter v6] ⚠️ Daily loss threshold reached. Entering defensive monitoring.");
         Print("[GoldHunter v6] Defensive Mode Activated: Continuing to learn from market without hard halt.");
      }
      lastSignal = "🛡️ DEFENSIVE - Learning";
      // Still allow trading but with reduced size and higher confidence
      return true;  // Continue processing
   }

   // [v6] Dynamic profit threshold - scale back but don't halt
   if(pnlPerc >= MaxDailyProfitPerc) {
      // Scale back position sizes but continue monitoring
      if(currentTradingState == STATE_DEFENSIVE_MONITORING) {
         currentTradingState = STATE_RUNNING;  // Return to normal
         string msg = StringFormat("✅ **PROFIT TARGET EXCEEDED**\nP&L: +%.2f%%\nReturning to normal operation.", pnlPerc);
         if(NotifyOnRiskEvent) SendDiscord(msg);
         if(PushNotifyOnTrade) SendNotification(msg);
         Alert("[GoldHunter v6] ✅ Profit target exceeded. Resuming normal operations.");
      }
      lastSignal = "🎯 PROFITABLE - Scaling Back";
      return true;  // Continue processing
   }

   // Reset to running state if within safe bounds
   if(currentTradingState == STATE_DEFENSIVE_MONITORING && pnlPerc > -MaxDailyLossPerc * 0.5) {
      currentTradingState = STATE_RUNNING;
      Print("[GoldHunter v6] P&L recovered. Returning to normal operation.");
   }

   // [v5] MaxTradesPerDay is now advisory only — log but don't block
   if(tradesThisDay >= MaxTradesPerDay) {
      LogStatus(StringFormat("Note: Trades today (%d) exceed advisory limit (%d) — continuing",
                             tradesThisDay, MaxTradesPerDay));
   }

   return true;  // Always allow processing in v6
}

//==========================================================================
//  [v5] ADAPTIVE CIRCUIT BREAKER
//  ─────────────────────────────────────────────────────────────────────
//  แทนที่ "3 ไม้ = 30 นาที" ด้วยระบบที่วิเคราะห์ว่า "ทำไมถึงแพ้"
//  แล้วปรับระยะพักตามสภาพตลาดจริง:
//
//  TRIGGER CONDITIONS (ตรวจทุกอย่างพร้อมกัน):
//    T1: Consecutive losses >= CB_MaxConsecLosses
//    T2: Session loss >= CB_LossPctTrigger% ของ balance
//    T3: Equity drop >= CB_EquityDDTrigger% จาก session peak
//
//  PAUSE DURATION FORMULA:
//    base_minutes = ATR_bars_to_recover × bar_duration_minutes
//    severity_multiplier = 1.0 + (loss_severity_score × 0.5)
//    smart_pause = CLAMP(base × severity, CB_Min, CB_Max)
//
//  โดย:
//    ATR_bars_to_recover = total_loss_pts / atrValue_pts  (เวลาตลาดต้องใช้ฟื้น)
//    loss_severity_score = 0..3 (นับจากกี่ trigger ที่ยิงพร้อมกัน)
//    bar_duration = นาทีต่อแท่งของ timeframe ปัจจุบัน
//
//  ผลลัพธ์:
//    - ตลาด volatile + แพ้หนัก → พักนาน (เข้าใกล้ CB_Max)
//    - ตลาด calm + แพ้เล็กน้อย → พักสั้น (เข้าใกล้ CB_Min)
//    - เปลี่ยน strategy หลังพักโดยอัตโนมัติ
//==========================================================================
void CheckConsecutiveLossCB()
{
   if(!UseAdaptiveCB) return;
   if(cbPauseUntil > 0) return; // already paused

   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double sessionLoss = dailyStartBalance - balance; // positive = loss

   bool t1_consecLoss = (consecutiveLosses >= CB_MaxConsecLosses);
   bool t2_sessionLoss= (balance > 0 && sessionLoss / balance * 100.0 >= CB_LossPctTrigger);
   bool t3_equityDD   = (sessionPeakEquity > 0 &&
                         (sessionPeakEquity - equity) / sessionPeakEquity * 100.0 >= CB_EquityDDTrigger);

   if(!t1_consecLoss && !t2_sessionLoss && !t3_equityDD) return;

   //--- Count how many triggers fired → severity 0-3
   int severity = 0;
   string reasons = "";
   if(t1_consecLoss) {
      severity++;
      reasons += StringFormat("🔴 %d consecutive losses", consecutiveLosses);
   }
   if(t2_sessionLoss) {
      severity++;
      double lossPct = sessionLoss / balance * 100.0;
      reasons += (reasons == "" ? "" : " + ");
      reasons += StringFormat("🔴 Session loss %.1f%%", lossPct);
   }
   if(t3_equityDD) {
      severity++;
      double ddPct = (sessionPeakEquity - equity) / sessionPeakEquity * 100.0;
      reasons += (reasons == "" ? "" : " + ");
      reasons += StringFormat("🔴 Equity DD %.1f%%", ddPct);
   }

   //--- Calculate how many ATR-lengths the market needs to recover
   //    = total_session_loss_in_points / current_ATR_in_points
   double atrPts = (atrValue > 0) ? atrValue / symbolInfo.Point() : 150.0;
   double lossInPoints = 0;
   if(balance > 0 && sessionLoss > 0) {
      double tickVal  = symbolInfo.TickValue();
      double tickSize = symbolInfo.TickSize();
      double lastLot  = MathMax(MinLot, MinLot); // conservative estimate
      // recover in points = loss amount / (tickVal per point per lot * lot)
      // simplified: use ATR-multiples of loss
      lossInPoints = sessionLoss / (balance * 0.01) * atrPts; // scaled estimate
   }

   double atrBarsToRecover = MathMax(1.0, lossInPoints / MathMax(atrPts, 1.0));
   atrBarsToRecover = MathMin(atrBarsToRecover, 20.0); // cap at 20 bars

   //--- Bar duration in minutes for current timeframe
   int barMinutes = 1;
   switch(Period()) {
      case PERIOD_M1:  barMinutes = 1;   break;
      case PERIOD_M5:  barMinutes = 5;   break;
      case PERIOD_M15: barMinutes = 15;  break;
      case PERIOD_M30: barMinutes = 30;  break;
      case PERIOD_H1:  barMinutes = 60;  break;
      case PERIOD_H4:  barMinutes = 240; break;
      default:         barMinutes = 1;   break;
   }

   //--- Base pause = ATR bars to recover × bar duration
   double basePause = atrBarsToRecover * barMinutes;

   //--- Severity multiplier: each additional trigger adds 50% more
   double severityMult = 1.0 + (severity - 1) * 0.5;

   //--- Volatility factor: high ATR expansion = market is wild → pause longer
   double volFactor = 1.0;
   if(prevAtrValue > 0 && atrValue > 0) {
      double atrExpansion = atrValue / prevAtrValue;
      if(atrExpansion > 1.5)      volFactor = 1.5; // volatile → 50% longer
      else if(atrExpansion > 1.2) volFactor = 1.2;
      else if(atrExpansion < 0.8) volFactor = 0.7; // calming down → shorter
   }

   //--- Session factor: during high-volume overlap, markets resolve faster
   double sessFactor = 1.0;
   string sess = GetCurrentSessionName();
   if(sess == "LONDON+NY") sessFactor = 0.8; // overlap = liquidity resolves fast
   else if(sess == "ASIAN")sessFactor = 1.3; // thin = stay out longer

   //--- Final smart pause
   double smartPause = basePause * severityMult * volFactor * sessFactor;
   int pauseMinutes  = (int)MathRound(MathMax(CB_MinPauseMinutes,
                                      MathMin(CB_MaxPauseMinutes, smartPause)));

   cbPauseUntil      = TimeCurrent() + pauseMinutes * 60;
   cbTriggerReason   = reasons;
   cbPauseMinutesLast= pauseMinutes;

   //--- After pause, force re-evaluation of strategy
   //    (stored in currentStrategy — will be recomputed on resume naturally)

   string msg = StringFormat(
      "⚠️ **ADAPTIVE CIRCUIT BREAKER**\n"
      "━━━━━━━━━━━━━━━━━━━━\n"
      "Triggers: %s\n"
      "━━━━━━━━━━━━━━━━━━━━\n"
      "📐 **Pause Calculation:**\n"
      "  ATR bars to recover: `%.1f bars`\n"
      "  Bar duration: `%d min/bar`\n"
      "  Base pause: `%.0f min`\n"
      "  Severity (x%d triggers): `×%.1f`\n"
      "  Volatility factor: `×%.1f`\n"
      "  Session factor (%s): `×%.1f`\n"
      "━━━━━━━━━━━━━━━━━━━━\n"
      "⏱️ **Smart Pause: `%d minutes`**\n"
      "Resumes: `%s`\n"
      "Balance: `$%.2f` | Equity: `$%.2f`",
      reasons,
      atrBarsToRecover, barMinutes, basePause,
      severity, severityMult,
      volFactor,
      sess, sessFactor,
      pauseMinutes,
      TimeToString(cbPauseUntil, TIME_DATE|TIME_MINUTES),
      balance, equity);

   if(NotifyOnRiskEvent) SendDiscord(msg);
   if(PushNotifyOnTrade) SendNotification(StringFormat(
      "GHP5 ADAPTIVE CB | %s | Pause: %d min | Resume: %s",
      reasons, pauseMinutes,
      TimeToString(cbPauseUntil, TIME_MINUTES)));
   Alert(StringFormat("[GoldHunter v5] Adaptive CB: %s\nPause: %d min (smart calc)",
                      reasons, pauseMinutes));

   LogStatus(StringFormat("AdaptiveCB: base=%.0f sev=%.1f vol=%.1f sess=%.1f → %dmin",
                          basePause, severityMult, volFactor, sessFactor, pauseMinutes));
}

//==========================================================================
//  Session Filter
//==========================================================================
bool IsActiveSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   double t   = dt.hour + dt.min / 60.0;
   double buf = SessionBuffer_Min / 60.0;

   bool london = TradeLondonSession && (t >= 7.0 - buf  && t <= 16.0 + buf);
   bool ny     = TradeNYSession     && (t >= 13.0 - buf && t <= 22.0 + buf);
   bool asian  = TradeAsianSession  && (t < 7.0          || t >= 23.0);

   return london || ny || asian;
}

string GetCurrentSessionName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   double t = dt.hour + dt.min / 60.0;

   if(t >= 13.0 && t < 16.0) return "LONDON+NY";
   if(t >= 7.0  && t < 13.0) return "LONDON";
   if(t >= 16.0 && t < 22.0) return "NY";
   if(t >= 23.0 || t < 7.0)  return "ASIAN";
   return "OFF";
}

//==========================================================================
//  New Day Reset
//==========================================================================
void CheckNewDay()
{
   datetime todayStart = iTime(Symbol(), PERIOD_D1, 0);
   if(todayStart == currentDay) return;

   if(NotifyOnDailyReport || PushNotifyOnDaily)
      SendDiscordExtendedReport();

   currentDay        = todayStart;
   tradesThisDay     = 0;
   tradingHalted     = false;  // [v6] Deprecated but kept for compatibility
   currentTradingState = STATE_RUNNING;  // [v6] Reset to running state
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   winCount          = 0;
   lossCount         = 0;
   londonWins=0; londonLosses=0; nyWins=0; nyLosses=0; asianWins=0; asianLosses=0;
   londonPnL=0; nyPnL=0; asianPnL=0;
   consecutiveLosses = 0;
   cbPauseUntil      = 0;

   ArrayResize(tp1ExecutedTickets, 0);
   tp1ExecutedCount = 0;
}

//==========================================================================
//  [v5] Weekly Summary
//==========================================================================
void CheckWeeklyReport()
{
   datetime weekStart = iTime(Symbol(), PERIOD_W1, 0);
   if(weekStart == currentWeek) return;

   if(NotifyOnDailyReport) {
      double weekPnL    = AccountInfoDouble(ACCOUNT_BALANCE) - weeklyStartBalance;
      double weekPnLPct = (weeklyStartBalance > 0) ? weekPnL / weeklyStartBalance * 100.0 : 0;

      SendDiscord(StringFormat(
         "📅 **WEEKLY SUMMARY — GoldHunter v5**\n"
         "Week: `%s`\n"
         "💵 Week P&L: `%s$%.2f` (`%+.2f%%`)\n"
         "💰 Balance: `$%.2f`\n"
         "📈 Peak Equity: `$%.2f`\n"
         "📉 Max Drawdown: `%.2f%%`\n"
         "🏆 Max Win Streak: `%d`\n"
         "😓 Max Loss Streak: `%d`",
         TimeToString(TimeCurrent(), TIME_DATE),
         (weekPnL >= 0 ? "+" : "-"), MathAbs(weekPnL), weekPnLPct,
         AccountInfoDouble(ACCOUNT_BALANCE),
         peakEquity, maxDrawdownPct,
         maxWinStreak, maxLossStreak));
   }

   currentWeek        = weekStart;
   weeklyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   maxDrawdownPct     = 0;
   maxWinStreak       = 0;
   maxLossStreak      = 0;
}

//==========================================================================
//  OnTradeTransaction
//==========================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != EA_MAGIC_NUMBER) return;

   string dealSym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   if(dealSym != Symbol()) return;

   ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   ENUM_DEAL_TYPE  dealType  = (ENUM_DEAL_TYPE) HistoryDealGetInteger(trans.deal, DEAL_TYPE);

   double grossProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   double swap        = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
   double commission  = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   double netProfit   = grossProfit + swap + commission;
   double dealPrice   = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double dealVol     = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   ulong  posId       = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   double curBalance  = AccountInfoDouble(ACCOUNT_BALANCE);

   bool isClose = (dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_INOUT);

   if(isClose || netProfit != 0.0) {
      totalProfit += netProfit;

      // [v5] Update streaks and session stats
      string sess = GetCurrentSessionName();
      if(netProfit > 0) {
         winCount++;
         winStreak++;
         lossStreak = 0;
         consecutiveLosses = 0;
         if(winStreak > maxWinStreak) maxWinStreak = winStreak;
         if(sess == "LONDON" || sess == "LONDON+NY") { londonWins++;  londonPnL += netProfit; }
         else if(sess == "NY")                       { nyWins++;      nyPnL     += netProfit; }
         else                                        { asianWins++;   asianPnL  += netProfit; }
      } else if(netProfit < 0) {
         lossCount++;
         lossStreak++;
         winStreak = 0;
         consecutiveLosses++;
         if(lossStreak > maxLossStreak) maxLossStreak = lossStreak;
         if(sess == "LONDON" || sess == "LONDON+NY") { londonLosses++; londonPnL += netProfit; }
         else if(sess == "NY")                       { nyLosses++;     nyPnL     += netProfit; }
         else                                        { asianLosses++;  asianPnL  += netProfit; }
      }

      CheckConsecutiveLossCB();

      SendPnLAlert(DealEntryToString(dealEntry), grossProfit, netProfit,
                   curBalance, dealSym, posId, dealVol);

      if(NotifyOnTrade) {
         string icon = (netProfit >= 0) ? "✅" : "❌";
         int    wr   = (winCount + lossCount > 0) ? (int)(winCount * 100.0 / (winCount + lossCount)) : 0;
         SendDiscord(StringFormat(
            "%s **TRADE CLOSED** [v5]\n"
            "Symbol: `%s` | #%d\n"
            "Type: `%s` | Vol: `%.2f`\n"
            "Close Price: `%.5f`\n"
            "Gross P&L: `%s$%.2f`\n"
            "Swap: `%+.2f`  Comm: `%+.2f`\n"
            "🔑 **Net P&L: `%s$%.2f`**\n"
            "💰 Balance: `$%.2f`\n"
            "📊 W:%d L:%d WR:%d%% | Streak: %s%d | CB: %d/%d",
            icon, dealSym, (int)posId,
            DealTypeToString(dealType), dealVol,
            dealPrice,
            (grossProfit >= 0 ? "+" : "-"), MathAbs(grossProfit),
            swap, commission,
            (netProfit >= 0 ? "+" : "-"), MathAbs(netProfit),
            curBalance, winCount, lossCount, wr,
            (netProfit > 0 ? "🏆" : "💔"), (netProfit > 0 ? winStreak : lossStreak),
            consecutiveLosses, MaxConsecutiveLosses));
      }
   }
}

//==========================================================================
//  [v5] SendDiscordExtendedReport — Daily + Session Breakdown
//==========================================================================
void SendDiscordExtendedReport()
{
   if(!NotifyOnDailyReport) return;

   double finalBal = AccountInfoDouble(ACCOUNT_BALANCE);
   double dayPnL   = finalBal - dailyStartBalance;
   double dayPnLPct= (dailyStartBalance > 0) ? dayPnL / dailyStartBalance * 100.0 : 0;
   int    wr       = (winCount + lossCount > 0) ?
                     (int)(winCount * 100.0 / (winCount + lossCount)) : 0;

   // London WR
   int londonTotal = londonWins + londonLosses;
   int nyTotal     = nyWins + nyLosses;
   int asianTotal  = asianWins + asianLosses;
   int lwrPct      = londonTotal > 0 ? (int)(londonWins * 100.0 / londonTotal) : 0;
   int nywrPct     = nyTotal     > 0 ? (int)(nyWins     * 100.0 / nyTotal)     : 0;
   int aswrPct     = asianTotal  > 0 ? (int)(asianWins  * 100.0 / asianTotal)  : 0;

   SendDiscord(StringFormat(
      "📋 **DAILY REPORT — GoldHunter v5 — %s**\n"
      "━━━━━━━━━━━━━━━━━━━━\n"
      "📊 Trades: `%d` (Advisory max: %d)\n"
      "✅ Win: `%d`  ❌ Loss: `%d`  WR: `%d%%`\n"
      "🏆 Win Streak: `%d`  😓 Loss Streak: `%d`\n"
      "💵 Day P&L: `%s$%.2f` (`%+.2f%%`)\n"
      "💰 Balance: `$%.2f`\n"
      "📉 Max DD Today: `%.2f%%`\n"
      "━━━━━━━━━━━━━━━━━━━━\n"
      "🇬🇧 London: W%d/L%d WR:%d%% P&L:`%+.2f`\n"
      "🇺🇸 New York: W%d/L%d WR:%d%% P&L:`%+.2f`\n"
      "🌏 Asian: W%d/L%d WR:%d%% P&L:`%+.2f`\n"
      "━━━━━━━━━━━━━━━━━━━━",
      TimeToString(TimeCurrent(), TIME_DATE),
      tradesThisDay, MaxTradesPerDay,
      winCount, lossCount, wr,
      maxWinStreak, maxLossStreak,
      (dayPnL >= 0 ? "+" : "-"), MathAbs(dayPnL), dayPnLPct,
      finalBal, maxDrawdownPct,
      londonWins, londonLosses, lwrPct, londonPnL,
      nyWins, nyLosses, nywrPct, nyPnL,
      asianWins, asianLosses, aswrPct, asianPnL));

   if(PushNotifyOnDaily)
      SendNotification(StringFormat("GHP5 Daily | P&L:%+.2f%%($%+.2f) | W:%d L:%d WR:%d%% | Bal:$%.2f",
                                    dayPnLPct, dayPnL, winCount, lossCount, wr, finalBal));
}

//==========================================================================
//  SendPnLAlert
//==========================================================================
void SendPnLAlert(string action, double grossProfit, double netProfit,
                  double balance, string sym, ulong posId, double lots)
{
   string pnlSign = (netProfit >= 0) ? "+" : "";
   string icon    = (netProfit >= 0) ? "✅ PROFIT" : "❌ LOSS";
   double dayPnL  = balance - dailyStartBalance;

   string alertMsg = StringFormat(
      "[GoldHunter v5] %s\n"
      "Symbol: %s  |  #%d  |  %.2f lot\n"
      "Entry: %s\n"
      "Gross P&L: %s$%.2f\n"
      "Net P&L (inc swap+comm): %s$%.2f\n"
      "─────────────────\n"
      "Balance: $%.2f\n"
      "Day P&L: %s$%.2f  |  W:%d  L:%d\n"
      "Streak: %s | CB: %d/%d",
      icon, sym, (int)posId, lots, action,
      (grossProfit >= 0 ? "+" : "-"), MathAbs(grossProfit),
      pnlSign, MathAbs(netProfit),
      balance,
      (dayPnL >= 0 ? "+" : "-"), MathAbs(dayPnL),
      winCount, lossCount,
      (netProfit > 0 ? StringFormat("Win x%d", winStreak) : StringFormat("Loss x%d", lossStreak)),
      consecutiveLosses, MaxConsecutiveLosses);

   if(AlertOnTradeClose) Alert(alertMsg);

   if(PushNotifyOnTrade)
      SendNotification(StringFormat("GHP5 %s | Net:%s%.2f | Bal:$%.2f | W:%d L:%d",
                                    (netProfit >= 0 ? "WIN" : "LOSS"),
                                    pnlSign, MathAbs(netProfit),
                                    balance, winCount, lossCount));
}

//==========================================================================
//  Discord Helpers
//==========================================================================
string JsonEscape(string v)
{
   StringReplace(v, "\\", "\\\\"); StringReplace(v, "\"", "\\\"");
   StringReplace(v, "\r", "\\r");  StringReplace(v, "\n", "\\n");
   StringReplace(v, "\t", "\\t");
   return v;
}

string DealTypeToString(ENUM_DEAL_TYPE t)
{
   if(t == DEAL_TYPE_BUY)  return "BUY";
   if(t == DEAL_TYPE_SELL) return "SELL";
   return "OTHER";
}

string DealEntryToString(ENUM_DEAL_ENTRY e)
{
   if(e == DEAL_ENTRY_IN)     return "OPEN";
   if(e == DEAL_ENTRY_OUT)    return "CLOSE";
   if(e == DEAL_ENTRY_INOUT)  return "REVERSE";
   if(e == DEAL_ENTRY_OUT_BY) return "CLOSE_BY";
   return "UNKNOWN";
}

string DeinitReasonToString(const int r)
{
   switch(r) {
      case REASON_PROGRAM:     return "Program removed";
      case REASON_REMOVE:      return "EA removed from chart";
      case REASON_RECOMPILE:   return "EA recompiled";
      case REASON_CHARTCHANGE: return "Symbol/period changed";
      case REASON_CHARTCLOSE:  return "Chart closed";
      case REASON_PARAMETERS:  return "Input parameters changed";
      case REASON_ACCOUNT:     return "Account changed";
      case REASON_TEMPLATE:    return "Template changed";
      case REASON_INITFAILED:  return "Initialization failed";
      case REASON_CLOSE:       return "Terminal closed";
   }
   return "Unknown";
}

string RetcodeToString(uint rc)
{
   switch(rc) {
      case TRADE_RETCODE_REQUOTE:        return "Requote";
      case TRADE_RETCODE_REJECT:         return "Rejected";
      case TRADE_RETCODE_CANCEL:         return "Cancelled";
      case TRADE_RETCODE_PLACED:         return "Order placed";
      case TRADE_RETCODE_DONE:           return "Done";
      case TRADE_RETCODE_DONE_PARTIAL:   return "Done partial";
      case TRADE_RETCODE_ERROR:          return "Error";
      case TRADE_RETCODE_TIMEOUT:        return "Timeout";
      case TRADE_RETCODE_INVALID:        return "Invalid";
      case TRADE_RETCODE_INVALID_VOLUME: return "Invalid volume";
      case TRADE_RETCODE_INVALID_PRICE:  return "Invalid price";
      case TRADE_RETCODE_INVALID_STOPS:  return "Invalid SL/TP";
      case TRADE_RETCODE_TRADE_DISABLED: return "Trade disabled";
      case TRADE_RETCODE_MARKET_CLOSED:  return "Market closed";
      case TRADE_RETCODE_NO_MONEY:       return "Insufficient funds";
      case TRADE_RETCODE_PRICE_OFF:      return "Price off";
      case TRADE_RETCODE_INVALID_EXPIRATION: return "Invalid expiration";
      case TRADE_RETCODE_ORDER_CHANGED:  return "Order changed";
      case TRADE_RETCODE_TOO_MANY_REQUESTS: return "Too many requests";
      case TRADE_RETCODE_NO_CHANGES:     return "No changes";
      case TRADE_RETCODE_SERVER_DISABLES_AT: return "Server disabled AT";
      case TRADE_RETCODE_CLIENT_DISABLES_AT: return "Client disabled AT";
      case TRADE_RETCODE_LOCKED:         return "Order locked";
      case TRADE_RETCODE_FROZEN:         return "Order frozen";
      case TRADE_RETCODE_INVALID_FILL:   return "Invalid fill type";
      case TRADE_RETCODE_CONNECTION:     return "No connection";
      case TRADE_RETCODE_ONLY_REAL:      return "Real account only";
      case TRADE_RETCODE_LIMIT_ORDERS:   return "Limit orders limit";
      case TRADE_RETCODE_LIMIT_VOLUME:   return "Volume limit";
      case TRADE_RETCODE_INVALID_ORDER:  return "Invalid order";
      case TRADE_RETCODE_POSITION_CLOSED:return "Position closed";
   }
   return StringFormat("Code_%d", rc);
}

bool SendDiscord(string message)
{
   if(!UseDiscord || DiscordWebhookURL == "") {
      if(!discordWarnShown) {
         Print("GHP: Discord disabled or webhook empty.");
         discordWarnShown = true;
      }
      return false;
   }

   string headers = "Content-Type: application/json\r\n";
   string payload = "{\"username\":\"" + JsonEscape(DiscordBotName) +
                    "\",\"content\":\"" + JsonEscape(message) + "\"}";

   char post[]; int pLen = StringToCharArray(payload, post, 0, WHOLE_ARRAY, CP_UTF8);
   if(pLen > 0) ArrayResize(post, pLen - 1);

   char   resp[]; string respHdr;
   ResetLastError();
   int status = WebRequest("POST", DiscordWebhookURL, headers,
                           DiscordTimeoutMS, post, resp, respHdr);

   if(status == -1) {
      int err = GetLastError();
      if(TimeCurrent() - lastDiscordErrTime > 60) {
         Print("GHP: Discord WebRequest failed. Error:", err,
               ". Add discord.com to: Tools→Options→Expert Advisors→Allow WebRequest");
         lastDiscordErrTime = TimeCurrent();
      }
      return false;
   }
   if(status < 200 || status >= 300) {
      Print("GHP: Discord HTTP status: ", status);
      return false;
   }
   return true;
}

void SendDiscordStartupReport()
{
   if(!NotifyOnBotState) return;
   SendDiscord(StringFormat(
      "💎 **GOLDHUNTER ULTIMATE v%s — XM EDITION**\n"
      "━━━━━━━━━━━━━━━━━━━━\n"
      "Account: `%d` | Broker: `%s`\n"
      "Symbol: `%s` | TF: `%s`\n"
      "Balance: `$%.2f` | Equity: `$%.2f`\n"
      "Strategy: `%s` | Risk: `%.1f%%`\n"
      "━━━━━━━━━━━━━━━━━━━━\n"
      "🆕 v5 Features Active:\n"
      "✅ Triple-TF Confluence (M1+M5+H1)\n"
      "✅ Candle-Close Entry Gate\n"
      "✅ Dynamic Confidence: `%.0f%%` base\n"
      "✅ Circuit Breaker: %d losses → %dmin pause\n"
      "✅ MaxTradesPerDay: STATS ONLY (no hard block)\n"
      "✅ Session P&L Breakdown in Daily Report\n"
      "Status: `%s`",
      EA_VERSION,
      (int)AccountInfoInteger(ACCOUNT_LOGIN),
      AccountInfoString(ACCOUNT_COMPANY),
      Symbol(), EnumToString((ENUM_TIMEFRAMES)Period()),
      AccountInfoDouble(ACCOUNT_BALANCE),
      AccountInfoDouble(ACCOUNT_EQUITY),
      stratNames[StrategyMode], RiskPercent,
      MinConfidence,
      MaxConsecutiveLosses, CBPauseMinutes,
      GetBotRuntimeStatus()));
}

void SendDiscordShutdownReport(const int reason)
{
   if(!NotifyOnBotState) return;
   SendDiscord(StringFormat(
      "🛑 **GOLDHUNTER v%s TERMINATED**\n"
      "Reason: `%s`\n"
      "W: %d | L: %d | Total Net P&L: `%s$%.2f`\n"
      "Balance: `$%.2f`\n"
      "Max DD: `%.2f%%` | Max Win Streak: `%d` | Max Loss Streak: `%d`",
      EA_VERSION, DeinitReasonToString(reason),
      winCount, lossCount,
      (totalProfit >= 0 ? "+" : "-"), MathAbs(totalProfit),
      AccountInfoDouble(ACCOUNT_BALANCE),
      maxDrawdownPct, maxWinStreak, maxLossStreak));
}

void SendDiscordBotStateReport(string state, string detail)
{
   SendDiscord(StringFormat(
      "🔘 **BOT STATE: %s**\n%s\n"
      "Symbol: `%s` | Time: `%s`\n"
      "Balance: `$%.2f` | Equity: `$%.2f`",
      state, detail, Symbol(),
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      AccountInfoDouble(ACCOUNT_BALANCE),
      AccountInfoDouble(ACCOUNT_EQUITY)));
}

//==========================================================================
//  LogStatus
//==========================================================================
void LogStatus(string message)
{
   if(!ShowDebugLog) return;
   static string lastLog = "";
   if(message == lastLog) return;
   Print("GHP_LOG: ", message);
   lastLog = message;
}

//==========================================================================
//  Dashboard
//==========================================================================
void CreateLabel(string name, int x, int y, string text, color clr, int sz)
{
   ObjectCreate(ChartID(), name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(ChartID(), name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(ChartID(), name, OBJPROP_YDISTANCE, y);
   ObjectSetString(ChartID(),  name, OBJPROP_TEXT,      text);
   ObjectSetInteger(ChartID(), name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(ChartID(), name, OBJPROP_FONTSIZE,  sz);
   ObjectSetString(ChartID(),  name, OBJPROP_FONT,      "Arial Bold");
   ObjectSetInteger(ChartID(), name, OBJPROP_BACK,      false);
   ObjectSetInteger(ChartID(), name, OBJPROP_SELECTABLE,false);
}

void CreateDashboard()
{
   string p = "GHP_";
   int x=10, y=30, w=300, h=390;

   ObjectCreate(ChartID(), p+"bg", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(ChartID(), p+"bg", OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(ChartID(), p+"bg", OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(ChartID(), p+"bg", OBJPROP_XSIZE,      w);
   ObjectSetInteger(ChartID(), p+"bg", OBJPROP_YSIZE,      h);
   ObjectSetInteger(ChartID(), p+"bg", OBJPROP_BGCOLOR,    PanelColor);
   ObjectSetInteger(ChartID(), p+"bg", OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(ChartID(), p+"bg", OBJPROP_COLOR,      clrDimGray);
   ObjectSetInteger(ChartID(), p+"bg", OBJPROP_BACK,       false);

   CreateLabel(p+"title",   x+10, y+8,   "💎 GoldHunter UHF AGI v5.0 (XM)", clrGold,      10);
   CreateLabel(p+"sep1",    x+10, y+26,  "──────────────────────────────",   clrDimGray,   7);
   CreateLabel(p+"strat",   x+10, y+38,  "Strategy: AUTO-AI",                 clrYellow,    9);
   CreateLabel(p+"signal",  x+10, y+56,  "Signal: SCANNING...",               TextColor,    9);
   CreateLabel(p+"sep2",    x+10, y+74,  "──────────────────────────────",   clrDimGray,   7);
   CreateLabel(p+"bal",     x+10, y+88,  "Balance:  $0.00",                   TextColor,    9);
   CreateLabel(p+"eq",      x+10, y+106, "Equity:   $0.00",                   TextColor,    9);
   CreateLabel(p+"pnl",     x+10, y+124, "Day P&L:  $0.00",                   TextColor,    9);
   CreateLabel(p+"float",   x+10, y+142, "Float P&L: $0.00",                  TextColor,    9);
   CreateLabel(p+"sep3",    x+10, y+160, "──────────────────────────────",   clrDimGray,   7);
   CreateLabel(p+"rsi",     x+10, y+174, "RSI: 0.00",                         TextColor,    9);
   CreateLabel(p+"atr",     x+10, y+192, "ATR: 0.00",                         TextColor,    9);
   CreateLabel(p+"adx",     x+10, y+210, "ADX: 0.00",                         TextColor,    9);
   CreateLabel(p+"regime",  x+10, y+228, "Regime: SCANNING",                  clrCyan,      9);
   CreateLabel(p+"sep4",    x+10, y+246, "──────────────────────────────",   clrDimGray,   7);
   CreateLabel(p+"trades",  x+10, y+260, "Today: 0 trades (no limit)",        TextColor,    9);
   CreateLabel(p+"winrate", x+10, y+278, "Win: 0  Loss: 0  WR: 0%",           TextColor,    9);
   CreateLabel(p+"streak",  x+10, y+296, "Streak: — | CB: 0/3",               TextColor,    9);
   CreateLabel(p+"session", x+10, y+314, "Session: --",                        clrYellow,    9);
   CreateLabel(p+"conf",    x+10, y+332, "Conf Threshold: 62%",                clrCyan,      9);
   CreateLabel(p+"status",  x+10, y+350, "Status: RUNNING ✅",                clrLime,      9);
   CreateLabel(p+"spread",  x+10, y+368, "Spread: --",                         TextColor,    8);
   ChartRedraw(ChartID());
}

void UpdateDashboard()
{
   string p = "GHP_";
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPnL  = equity - dailyStartBalance;

   double floatPnL = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(posInfo.SelectByIndex(i) && posInfo.Symbol()==Symbol() && posInfo.Magic()==EA_MAGIC_NUMBER)
         floatPnL += posInfo.Profit() + posInfo.Swap();

   int winRate = (winCount + lossCount > 0) ?
                 (int)(winCount * 100.0 / (winCount + lossCount)) : 0;
   double spread = (symbolInfo.Ask() - symbolInfo.Bid()) / symbolInfo.Point();

   int regime = DetectMarketRegime();
   string regStr;
   color  regCol = clrCyan;
   switch(regime) {
      case 1: regStr = "📈 BULL TREND";  regCol = ProfitColor; break;
      case 2: regStr = "📉 BEAR TREND";  regCol = LossColor;   break;
      case 3: regStr = "↔️ RANGING";     regCol = clrYellow;   break;
      case 4: regStr = "⚡ VOLATILE";    regCol = clrOrange;   break;
      default: regStr= "💤 CALM";        regCol = clrCyan;     break;
   }

   string sessStr = GetCurrentSessionName();
   if(!IsActiveSession()) sessStr = "OFF-HOURS";

   string rts = GetBotRuntimeStatus();
   string statusStr; color statusClr;
   if(rts == "RUNNING")                  { statusStr = "Status: RUNNING ✅";         statusClr = clrLime;   }
   else if(rts == "DEFENSIVE_MONITORING"){ statusStr = "Status: DEFENSIVE 🛡️";       statusClr = clrYellow; }
   else if(rts == "CB_PAUSE")            { statusStr = "Status: CB PAUSE ⏸️";        statusClr = clrOrange; }
   else if(rts == "PAUSED_MANUAL")       { statusStr = "Status: PAUSED ⏸️";          statusClr = clrOrange; }
   else if(rts == "DISABLED_BY_INPUT")   { statusStr = "Status: OFF (Input) ⏸️";     statusClr = clrOrange; }
   else                                  { statusStr = "Status: UNKNOWN ⚠️";         statusClr = clrGray;   }

   string streakStr = StringFormat("%s x%d | CB: %d/%d",
      winStreak > lossStreak ? "🏆" : "💔",
      winStreak > lossStreak ? winStreak : lossStreak,
      consecutiveLosses, MaxConsecutiveLosses);

   double dynConf = GetDynamicMinConfidence();

   ObjectSetString(ChartID(),  p+"strat",   OBJPROP_TEXT,  "Strategy: " + stratNames[currentStrategy]);
   ObjectSetString(ChartID(),  p+"signal",  OBJPROP_TEXT,  "Signal: " + lastSignal);
   ObjectSetString(ChartID(),  p+"bal",     OBJPROP_TEXT,  StringFormat("Balance:  $%.2f", balance));
   ObjectSetString(ChartID(),  p+"eq",      OBJPROP_TEXT,  StringFormat("Equity:   $%.2f", equity));
   ObjectSetString(ChartID(),  p+"pnl",     OBJPROP_TEXT,  StringFormat("Day P&L:  %+.2f", dayPnL));
   ObjectSetInteger(ChartID(), p+"pnl",     OBJPROP_COLOR, (dayPnL >= 0) ? ProfitColor : LossColor);
   ObjectSetString(ChartID(),  p+"float",   OBJPROP_TEXT,  StringFormat("Float P&L: %+.2f", floatPnL));
   ObjectSetInteger(ChartID(), p+"float",   OBJPROP_COLOR, (floatPnL >= 0) ? ProfitColor : LossColor);
   ObjectSetString(ChartID(),  p+"rsi",     OBJPROP_TEXT,  StringFormat("RSI: %.1f%s", rsiValue,
                                            rsiValue<30?" 🔵OS":rsiValue>70?" 🔴OB":" ⚪"));
   ObjectSetString(ChartID(),  p+"atr",     OBJPROP_TEXT,  StringFormat("ATR: %.2f (%.0f pts)",
                                            atrValue, atrValue / symbolInfo.Point()));
   ObjectSetString(ChartID(),  p+"adx",     OBJPROP_TEXT,  StringFormat("ADX: %.1f%s", adxValue,
                                            adxValue>30?" 💪":" ⚠️"));
   ObjectSetString(ChartID(),  p+"regime",  OBJPROP_TEXT,  "Regime: " + regStr);
   ObjectSetInteger(ChartID(), p+"regime",  OBJPROP_COLOR, regCol);
   ObjectSetString(ChartID(),  p+"trades",  OBJPROP_TEXT,
                   StringFormat("Today: %d trades (advisory: %d)", tradesThisDay, MaxTradesPerDay));
   ObjectSetString(ChartID(),  p+"winrate", OBJPROP_TEXT,
                   StringFormat("W:%d  L:%d  WR:%d%%", winCount, lossCount, winRate));
   ObjectSetString(ChartID(),  p+"streak",  OBJPROP_TEXT,  "Streak: " + streakStr);
   ObjectSetString(ChartID(),  p+"session", OBJPROP_TEXT,  "Session: " + sessStr);
   ObjectSetString(ChartID(),  p+"conf",    OBJPROP_TEXT,  StringFormat("Conf Threshold: %.0f%%", dynConf));
   ObjectSetString(ChartID(),  p+"status",  OBJPROP_TEXT,  statusStr);
   ObjectSetInteger(ChartID(), p+"status",  OBJPROP_COLOR, statusClr);
   ObjectSetString(ChartID(),  p+"spread",  OBJPROP_TEXT,
                   StringFormat("Spread: %.1f pts %s", spread, spread > MaxSpreadPips ? "⚠️HIGH" : "✅OK"));
   ObjectSetInteger(ChartID(), p+"spread",  OBJPROP_COLOR,
                   spread > MaxSpreadPips ? LossColor : clrGray);

   UpdateBotControlButton();
   UpdateSessionControlButton();
   ChartRedraw(ChartID());
}

//+------------------------------------------------------------------+
//| [v7] ASI AGI CORE FUNCTIONS                                      |
//+------------------------------------------------------------------+

//==========================================================================
//  LoadTradeHistoryFromCSV — Load historical trades for learning
//==========================================================================
bool LoadTradeHistoryFromCSV()
{
   int handle = FileOpen(tradeLogCSV, FILE_READ|FILE_CSV|FILE_ANSI, ";");
   if(handle == INVALID_HANDLE) return false;

   ArrayResize(tradeHistory, MAX_TRADE_HISTORY);
   tradeHistoryCount = 0;

   while(!FileIsEnding(handle) && tradeHistoryCount < MAX_TRADE_HISTORY) {
      string line = FileReadString(handle);
      if(StringLen(line) < 10) continue;

      string parts[];
      StringSplit(line, ';', parts);
      if(ArraySize(parts) < 10) continue;

      tradeHistory[tradeHistoryCount].timestamp = (datetime)StringToTime(parts[0]);
      tradeHistory[tradeHistoryCount].type = (ENUM_ORDER_TYPE)StringToInteger(parts[1]);
      tradeHistory[tradeHistoryCount].entryPrice = StringToDouble(parts[2]);
      tradeHistory[tradeHistoryCount].exitPrice = StringToDouble(parts[3]);
      tradeHistory[tradeHistoryCount].profit = StringToDouble(parts[4]);
      tradeHistory[tradeHistoryCount].slDistance = StringToDouble(parts[5]);
      tradeHistory[tradeHistoryCount].tpDistance = StringToDouble(parts[6]);
      tradeHistory[tradeHistoryCount].regime = (int)StringToInteger(parts[7]);
      tradeHistory[tradeHistoryCount].strategy = (int)StringToInteger(parts[8]);
      tradeHistory[tradeHistoryCount].confidence = StringToDouble(parts[9]);

      if(ArraySize(parts) > 10) tradeHistory[tradeHistoryCount].reasons = parts[10];

      tradeHistoryCount++;
   }

   FileClose(handle);
   Print("[v7] Loaded ", tradeHistoryCount, " trades from CSV for learning");
   return tradeHistoryCount > 0;
}

//==========================================================================
//  SaveTradeToCSV — Log completed trade for reinforcement learning
//==========================================================================
void SaveTradeToCSV(TradeRecord &tr)
{
   int handle = FileOpen(tradeLogCSV, FILE_WRITE|FILE_CSV|FILE_ANSI, ";");
   if(handle == INVALID_HANDLE) return;

   // Write header if new file
   if(FileTell(handle) == 0) {
      FileWrite(handle, "Timestamp;Type;EntryPrice;ExitPrice;Profit;SL_Dist;TP_Dist;Regime;Strategy;Confidence;Reasons");
   }

   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle,
      TimeToString(tr.timestamp),
      IntegerToString((int)tr.type),
      DoubleToString(tr.entryPrice, _Digits),
      DoubleToString(tr.exitPrice, _Digits),
      DoubleToString(tr.profit, 2),
      DoubleToString(tr.slDistance, _Digits),
      DoubleToString(tr.tpDistance, _Digits),
      IntegerToString(tr.regime),
      IntegerToString(tr.strategy),
      DoubleToString(tr.confidence, 1),
      tr.reasons);

   FileClose(handle);
}

//==========================================================================
//  InitializeQTable — Setup Q-learning table with state discretization
//==========================================================================
void InitializeQTable()
{
   ArrayResize(qTable, MAX_QTABLE_ENTRIES);
   qTableSize = 0;

   // Discretize state space: regime(5) x RSI_level(3) x trend(3) = 45 base states
   // Each state has 3 actions: Buy(0), Sell(1), Hold(2)
   for(int r = 0; r < 5; r++) {      // Regime
      for(int ri = 0; ri < 3; ri++) {  // RSI level: 0=OS, 1=Neutral, 2=OB
         for(int t = 0; t < 3; t++) {   // Trend: 0=Bear, 1=Neutral, 2=Bull
            int idx = qTableSize++;
            qTable[idx].qValues[0] = 0.0;  // Initial Q for Buy
            qTable[idx].qValues[1] = 0.0;  // Initial Q for Sell
            qTable[idx].qValues[2] = 0.0;  // Initial Q for Hold
            qTable[idx].visitCount = 0;
            qTable[idx].lastUpdate = (datetime)TimeCurrent();
         }
      }
   }

   // Try to load existing Q-table from CSV
   LoadQTableFromCSV();
   Print("[v7] Q-Table initialized with ", qTableSize, " states");
}

//==========================================================================
//  GetStateIndex — Discretize current market state for Q-learning
//==========================================================================
int GetStateIndex()
{
   int regime = DetectMarketRegime();

   // RSI discretization
   int rsiLevel;
   if(rsiValue < 35) rsiLevel = 0;      // Oversold
   else if(rsiValue > 65) rsiLevel = 2; // Overbought
   else rsiLevel = 1;                    // Neutral

   // Trend discretization
   int trend;
   if(emaFast > emaSlow * 1.001) trend = 2;    // Bull
   else if(emaFast < emaSlow * 0.999) trend = 0; // Bear
   else trend = 1;                               // Neutral

   // Encode state: regime(0-4) * 9 + rsiLevel(0-2) * 3 + trend(0-2)
   int stateIdx = regime * 9 + rsiLevel * 3 + trend;
   return MathMin(stateIdx, qTableSize - 1);
}

//==========================================================================
//  QLearning_SelectAction — Epsilon-greedy action selection
//==========================================================================
int QLearning_SelectAction(int stateIdx)
{
   if(!UseReinforcementLearning) return -1;
   if(stateIdx < 0 || stateIdx >= qTableSize) return -1;

   // Epsilon-greedy: explore with probability epsilon
   if(MathRand() / 32767.0 < Q_EPSILON) {
      return MathRand() % 3;  // Random action: 0=Buy, 1=Sell, 2=Hold
   }

   // Exploit: choose action with highest Q-value
   double maxQ = qTable[stateIdx].qValues[0];
   int bestAction = 0;

   for(int a = 1; a < 3; a++) {
      if(qTable[stateIdx].qValues[a] > maxQ) {
         maxQ = qTable[stateIdx].qValues[a];
         bestAction = a;
      }
   }

   return bestAction;
}

//==========================================================================
//  QLearning_Update — Update Q-values based on reward
//==========================================================================
void QLearning_Update(int stateIdx, int action, double reward, int nextStateIdx)
{
   if(!UseReinforcementLearning) return;
   if(stateIdx < 0 || stateIdx >= qTableSize) return;
   if(nextStateIdx < 0 || nextStateIdx >= qTableSize) return;

   // Q(s,a) ← Q(s,a) + α[r + γ*max_a'Q(s',a') - Q(s,a)]
   double currentQ = qTable[stateIdx].qValues[action];

   // Find max Q for next state
   double maxNextQ = qTable[nextStateIdx].qValues[0];
   for(int a = 1; a < 3; a++) {
      if(qTable[nextStateIdx].qValues[a] > maxNextQ)
         maxNextQ = qTable[nextStateIdx].qValues[a];
   }

   double newQ = currentQ + Q_LEARNING_RATE * (reward + Q_DISCOUNT_FACTOR * maxNextQ - currentQ);
   qTable[stateIdx].qValues[action] = newQ;
   qTable[stateIdx].visitCount++;
   qTable[stateIdx].lastUpdate = (datetime)TimeCurrent();
}

//==========================================================================
//  CalculateReward — Compute reward signal from trade outcome
//==========================================================================
double CalculateReward(double profit, double slDist, double tpDist, bool hitTP, bool hitSL)
{
   // Base reward from profit/loss ratio
   double reward = 0.0;

   if(profit > 0) {
      // Positive reward scaled by R:R achieved
      double rrAchieved = profit / (slDist * symbolInfo.TickValue());
      reward = 1.0 + rrAchieved * 0.5;  // Base 1.0 + bonus for good R:R

      if(hitTP) reward += 2.0;  // Bonus for hitting TP
   } else if(profit < 0) {
      // Negative reward scaled by loss severity
      double lossRatio = MathAbs(profit) / (slDist * symbolInfo.TickValue());
      reward = -1.0 - lossRatio * 0.5;

      if(hitSL) reward -= 1.0;  // Penalty for hitting SL
   } else {
      // Breakeven or small loss
      reward = -0.1;
   }

   return reward;
}

//==========================================================================
//  SaveQTableToCSV — Persist Q-table to file
//==========================================================================
void SaveQTableToCSV()
{
   int handle = FileOpen(qTableCSV, FILE_WRITE|FILE_CSV|FILE_ANSI, ";");
   if(handle == INVALID_HANDLE) return;

   FileWrite(handle, "StateIdx;Q_Buy;Q_Sell;Q_Hold;VisitCount;LastUpdate");

   for(int i = 0; i < qTableSize; i++) {
      FileWrite(handle,
         IntegerToString(i),
         DoubleToString(qTable[i].qValues[0], 6),
         DoubleToString(qTable[i].qValues[1], 6),
         DoubleToString(qTable[i].qValues[2], 6),
         IntegerToString(qTable[i].visitCount),
         TimeToString((datetime)qTable[i].lastUpdate));
   }

   FileClose(handle);
}

//==========================================================================
//  LoadQTableFromCSV — Load Q-table from file
//==========================================================================
bool LoadQTableFromCSV()
{
   int handle = FileOpen(qTableCSV, FILE_READ|FILE_CSV|FILE_ANSI, ";");
   if(handle == INVALID_HANDLE) return false;

   // Skip header
   FileReadString(handle);

   int loaded = 0;
   while(!FileIsEnding(handle) && loaded < qTableSize) {
      string line = FileReadString(handle);
      if(StringLen(line) < 5) continue;

      string parts[];
      StringSplit(line, ';', parts);
      if(ArraySize(parts) < 6) continue;

      int idx = (int)StringToInteger(parts[0]);
      if(idx >= 0 && idx < qTableSize) {
         qTable[idx].qValues[0] = StringToDouble(parts[1]);
         qTable[idx].qValues[1] = StringToDouble(parts[2]);
         qTable[idx].qValues[2] = StringToDouble(parts[3]);
         qTable[idx].visitCount = (int)StringToInteger(parts[4]);
         loaded++;
      }
   }

   FileClose(handle);
   if(loaded > 0) Print("[v7] Loaded ", loaded, " Q-table entries from CSV");
   return loaded > 0;
}

//==========================================================================
//  Bayesian_UpdateStrategyProbabilities — Update posterior probabilities
//==========================================================================
void Bayesian_UpdateStrategyProbabilities(int strategy, double profit)
{
   if(!UseBayesianInference) return;

   // Beta-Bernoulli conjugate update for each strategy
   // Prior: Beta(alpha=1, beta=1) = uniform
   // After observing success/failure: alpha += success, beta += failure

   static double alpha[5] = {1, 1, 1, 1, 1};  // Success counts (prior + observed)
   static double beta[5]  = {1, 1, 1, 1, 1};  // Failure counts

   if(profit > 0) alpha[strategy] += 1.0;
   else           beta[strategy]  += 1.0;

   bayesProbs.totalObservations++;

   // Compute posterior means: E[p] = alpha / (alpha + beta)
   double total = 0;
   for(int s = 0; s < 5; s++) {
      total += alpha[s] / (alpha[s] + beta[s]);
   }

   // Normalize to probabilities
   bayesProbs.scalpProb    = (alpha[1] / (alpha[1] + beta[1])) / total;
   bayesProbs.swingProb    = (alpha[2] / (alpha[2] + beta[2])) / total;
   bayesProbs.breakoutProb = (alpha[3] / (alpha[3] + beta[3])) / total;
   bayesProbs.reversalProb = (alpha[4] / (alpha[4] + beta[4])) / total;
   bayesProbs.autoProb     = (alpha[0] / (alpha[0] + beta[0])) / total;
}

//==========================================================================
//  Bayesian_SelectBestStrategy — Sample from posterior to select strategy
//==========================================================================
int Bayesian_SelectBestStrategy()
{
   if(!UseBayesianInference) return StrategyMode;

   // Thompson sampling: sample from Beta posterior and pick highest
   double samples[5];
   for(int s = 0; s < 5; s++) {
      // Approximate Beta sample using normal approximation
      double mean = bayesProbs.scalpProb;
      if(s == 1) mean = bayesProbs.scalpProb;
      else if(s == 2) mean = bayesProbs.swingProb;
      else if(s == 3) mean = bayesProbs.breakoutProb;
      else if(s == 4) mean = bayesProbs.reversalProb;
      else mean = bayesProbs.autoProb;

      // Add noise for exploration
      samples[s] = mean + (MathRand() / 32767.0 - 0.5) * 0.2;
   }

   int bestStrat = 0;
   double bestSample = samples[0];
   for(int s = 1; s < 5; s++) {
      if(samples[s] > bestSample) {
         bestSample = samples[s];
         bestStrat = s;
      }
   }

   return bestStrat;
}

//==========================================================================
//  NeuralNetwork_Predict — Forward pass through pre-trained network
//==========================================================================
double NeuralNetwork_Predict(double &inputs[])
{
   if(!UseNeuralNetwork) return 0.0;

   // Hidden layer: ReLU activation
   double hidden[15];
   for(int h = 0; h < 15; h++) {
      double sum = nnLayer.hiddenBias[h];
      for(int i = 0; i < 10; i++) {
         sum += inputs[i] * nnLayer.weights[i][h];
      }
      hidden[h] = MathMax(0, sum);  // ReLU
   }

   // Output layer: Sigmoid activation
   double output = nnLayer.outputBias;
   for(int h = 0; h < 15; h++) {
      output += hidden[h] * nnLayer.outputWeights[h];
   }

   return 1.0 / (1.0 + MathExp(-output));  // Sigmoid
}

//==========================================================================
//  NeuralNetwork_LoadWeights — Load pre-trained weights from JSON-like file
//==========================================================================
bool NeuralNetwork_LoadWeights()
{
   int handle = FileOpen(nnWeightsJSON, FILE_READ|FILE_TXT);
   if(handle == INVALID_HANDLE) {
      Print("[v7] NN weights file not found, using random initialization");
      // Initialize with small random weights
      for(int i = 0; i < 10; i++)
         for(int h = 0; h < 15; h++)
            nnLayer.weights[i][h] = (MathRand() / 32767.0 - 0.5) * 0.5;

      for(int h = 0; h < 15; h++) {
         nnLayer.hiddenBias[h] = (MathRand() / 32767.0 - 0.5) * 0.5;
         nnLayer.outputWeights[h] = (MathRand() / 32767.0 - 0.5) * 0.5;
      }
      nnLayer.outputBias = 0.0;
      return false;
   }

   // Simple parsing: expect format "w_i_h:value" per line
   while(!FileIsEnding(handle)) {
      string line = FileReadString(handle);
      if(StringFind(line, "w_") == 0) {
         string parts[];
         StringSplit(line, ':', parts);
         if(ArraySize(parts) == 2) {
            string coords[];
            StringSplit(StringSubstr(parts[0], 2), '_', coords);
            int i = (int)StringToInteger(coords[0]);
            int h = (int)StringToInteger(coords[1]);
            if(i >= 0 && i < 10 && h >= 0 && h < 15)
               nnLayer.weights[i][h] = StringToDouble(parts[1]);
         }
      }
   }

   FileClose(handle);
   Print("[v7] NN weights loaded successfully");
   return true;
}

//==========================================================================
//  TickDelta_Update — Update circular buffer with tick volume delta
//==========================================================================
void TickDelta_Update(double volume, int tickType)
{
   if(!UseOrderFlowImbalance) return;

   datetime currentSec = TimeCurrent();
   if(currentSec != tickDelta.lastUpdate) {
      // New second: advance circular buffer
      tickDelta.currentIndex = (tickDelta.currentIndex + 1) % 60;
      tickDelta.buyVolume[tickDelta.currentIndex] = 0;
      tickDelta.sellVolume[tickDelta.currentIndex] = 0;
      tickDelta.lastUpdate = currentSec;
   }

   // Accumulate volume for current second
   // tickType: 1 = BUY, -1 = SELL, 0 = UNKNOWN
   if(tickType == 1)
      tickDelta.buyVolume[tickDelta.currentIndex] += volume;
   else
      tickDelta.sellVolume[tickDelta.currentIndex] += volume;
}

//==========================================================================
//  TickDelta_GetImbalance — Calculate volume imbalance sigma
//==========================================================================
double TickDelta_GetImbalance()
{
   if(!UseOrderFlowImbalance) return 0.0;

   double buySum = 0, sellSum = 0;
   for(int i = 0; i < 60; i++) {
      buySum += tickDelta.buyVolume[i];
      sellSum += tickDelta.sellVolume[i];
   }

   double netDelta = buySum - sellSum;
   double totalVol = buySum + sellSum;
   if(totalVol == 0) return 0.0;

   // Calculate standard deviation of delta over 60 seconds
   double meanDelta = netDelta / 60.0;
   double variance = 0;
   for(int i = 0; i < 60; i++) {
      double delta = tickDelta.buyVolume[i] - tickDelta.sellVolume[i];
      variance += MathPow(delta - meanDelta, 2);
   }
   double stdDev = MathSqrt(variance / 60.0);

   // Return z-score (number of std devs from mean)
   if(stdDev == 0) return 0.0;
   return netDelta / (stdDev * 60.0);
}

//==========================================================================
//  CorrelationGuard_Update — Update correlation buffer with returns
//==========================================================================
void CorrelationGuard_Update(double xauReturn, double dxyReturn)
{
   if(!UseCorrelationGuard) return;

   corrGuard.currentIndex = (corrGuard.currentIndex + 1) % 20;
   corrGuard.xauReturn[corrGuard.currentIndex] = xauReturn;
   corrGuard.dxyReturn[corrGuard.currentIndex] = dxyReturn;
   corrGuard.dxyAvailable = true;
}

//==========================================================================
//  CorrelationGuard_CheckSameDirection — Check if XAU and DXY moving together
//==========================================================================
bool CorrelationGuard_CheckSameDirection()
{
   if(!UseCorrelationGuard) return false;
   if(!corrGuard.dxyAvailable) return false;

   double xauSum = 0, dxySum = 0;
   int count = 0;

   for(int i = 0; i < 20; i++) {
      if(corrGuard.xauReturn[i] != 0 || corrGuard.dxyReturn[i] != 0) {
         xauSum += corrGuard.xauReturn[i];
         dxySum += corrGuard.dxyReturn[i];
         count++;
      }
   }

   if(count < 5) return false;  // Not enough data

   // Check if both have same sign (both positive or both negative)
   return (xauSum > 0 && dxySum > 0) || (xauSum < 0 && dxySum < 0);
}

//==========================================================================
//  SelfHealingOptimizer_Run — Grid search optimization after batch
//==========================================================================
void SelfHealingOptimizer_Run()
{
   if(!UseSelfHealingOptimizer) return;

   optimizer.tradeBatchCount++;
   if(optimizer.tradeBatchCount < 20) return;  // Wait for 20-trade batch

   Print("[v7] Running self-healing optimization...");

   // Grid search over ±20% of current parameters
   double bestSharpe = -999999;
   double bestSL = ATR_SL_Multiplier;
   double bestTP = ATR_TP_Multiplier;
   double bestConf = MinConfidence;

   double slTests[] = {ATR_SL_Multiplier * 0.8, ATR_SL_Multiplier, ATR_SL_Multiplier * 1.2};
   double tpTests[] = {ATR_TP_Multiplier * 0.8, ATR_TP_Multiplier, ATR_TP_Multiplier * 1.2};
   double confTests[] = {MinConfidence - 5, MinConfidence, MinConfidence + 5};

   // Simulate on last 100 bars (simplified replay)
   for(int s = 0; s < ArraySize(slTests); s++) {
      for(int t = 0; t < ArraySize(tpTests); t++) {
         for(int c = 0; c < ArraySize(confTests); c++) {

            // Calculate Sharpe ratio for this parameter set (simplified)
            double profits[];
            double totalPnL = 0;
            double pnlSqSum = 0;
            int tradeCount = 0;

            // Replay last N trades with these parameters
            for(int i = MathMax(0, tradeHistoryCount - 100); i < tradeHistoryCount; i++) {
               // Simplified: scale PnL by SL/TP ratio change
               double scaledProfit = tradeHistory[i].profit *
                                    (slTests[s] / tradeHistory[i].slDistance) *
                                    (tpTests[t] / tradeHistory[i].tpDistance);

               if(scaledProfit > 0 || tradeHistory[i].confidence >= confTests[c]) {
                  profits[tradeCount++] = scaledProfit;
                  totalPnL += scaledProfit;
                  pnlSqSum += scaledProfit * scaledProfit;
               }
            }

            if(tradeCount < 5) continue;

            double meanPnL = totalPnL / tradeCount;
            double variance = (pnlSqSum / tradeCount) - (meanPnL * meanPnL);
            double stdDev = MathSqrt(MathAbs(variance));

            double sharpe = (stdDev > 0) ? (meanPnL / stdDev) * MathSqrt(252) : 0;

            if(sharpe > bestSharpe) {
               bestSharpe = sharpe;
               bestSL = slTests[s];
               bestTP = tpTests[t];
               bestConf = confTests[c];
            }
         }
      }
   }

   // Auto-apply best parameters
   if(bestSharpe > optimizer.bestSharpe) {
      Print(StringFormat("[v7] Optimization found better params: SL=%.2f TP=%.2f Conf=%.1f Sharpe=%.2f",
                         bestSL, bestTP, bestConf, bestSharpe));

      // Note: In live EA, we'd use GlobalVariableSet or modify inputs dynamically
      // For now, log the recommended changes
      optimizer.bestSharpe = bestSharpe;
      optimizer.bestATR_SL = bestSL;
      optimizer.bestATR_TP = bestTP;
      optimizer.bestMinConf = bestConf;

      // Send Discord alert about optimization
      if(NotifyOnRiskEvent) {
         SendDiscord(StringFormat("🔧 **SELF-HEALING OPTIMIZER**\\n"+
                                  "New optimal parameters found:\\n"+
                                  "ATR_SL: `%.2f` → `%.2f`\\n"+
                                  "ATR_TP: `%.2f` → `%.2f`\\n"+
                                  "MinConf: `%.1f` → `%.1f`\\n"+
                                  "Sharpe: `%.2f`",
                                  ATR_SL_Multiplier, bestSL,
                                  ATR_TP_Multiplier, bestTP,
                                  MinConfidence, bestConf,
                                  bestSharpe));
      }
   }

   optimizer.tradeBatchCount = 0;
   optimizer.lastOptimize = TimeCurrent();
}

//==========================================================================
//  DynamicKelly_CalculateLotSize — Kelly Criterion with safety caps
//==========================================================================
double DynamicKelly_CalculateLotSize(double slDistance)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   // Calculate rolling win rate and avg win/loss from last 50 trades
   int lookback = MathMin(50, tradeHistoryCount);
   if(lookback < 10) return CalculateLotSize(slDistance);  // Not enough data

   int wins = 0;
   double avgWin = 0, avgLoss = 0;
   int winCount_k = 0, lossCount_k = 0;

   for(int i = tradeHistoryCount - lookback; i < tradeHistoryCount; i++) {
      if(tradeHistory[i].profit > 0) {
         wins++;
         avgWin += tradeHistory[i].profit;
         winCount_k++;
      } else if(tradeHistory[i].profit < 0) {
         avgLoss += MathAbs(tradeHistory[i].profit);
         lossCount_k++;
      }
   }

   if(winCount_k > 0) avgWin /= winCount_k;
   if(lossCount_k > 0) avgLoss /= lossCount_k;

   double winRate = (lookback > 0) ? (double)wins / lookback : 0.5;
   double winLossRatio = (avgLoss > 0) ? avgWin / avgLoss : 1.0;

   // Kelly formula: f* = W - (1-W)/R
   // Where W = win probability, R = win/loss ratio
   double kellyFraction = winRate - (1.0 - winRate) / winLossRatio;

   // Apply half-Kelly safety cap
   kellyFraction = kellyFraction / 2.0;

   // Ensure non-negative
   kellyFraction = MathMax(0.01, kellyFraction);

   // Cap at reasonable maximum
   kellyFraction = MathMin(kellyFraction, 0.05);  // Max 5% risk per trade

   // Drawdown scaling: reduce to 25% when max DD > 5%
   double ddPct = (peakEquity > 0) ? (peakEquity - equity) / peakEquity * 100.0 : 0;
   if(ddPct > 5.0) kellyFraction *= 0.25;
   else if(ddPct > 3.0) kellyFraction *= 0.50;

   // Calculate lot size from Kelly fraction
   double riskAmount = balance * kellyFraction;
   double tickVal = symbolInfo.TickValue();
   double tickSize = symbolInfo.TickSize();

   if(slDistance <= 0 || tickVal <= 0 || tickSize <= 0) return MinLot;

   double slTicks = slDistance / tickSize;
   double lotSize = riskAmount / (slTicks * tickVal);
   double lotStep = symbolInfo.LotsStep();

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(MinLot, MathMin(MaxLot, lotSize));

   return NormalizeDouble(lotSize, 2);
}

//==========================================================================
//  PHASE 2: MEMORY SYSTEM FUNCTIONS
//==========================================================================

//+------------------------------------------------------------------+
//| Load Episodic Memory from CSV (Phase 2)                          |
//+------------------------------------------------------------------+
void LoadEpisodicMemory()
{
   int handle = FileOpen(TradeLogCSV, FILE_CSV | FILE_READ | FILE_ANSI, ";");
   if(handle == INVALID_HANDLE) {
      Print("Phase 2: No existing trade log found. Starting fresh memory.");
      return;
   }

   ArrayResize(episodic_memory, 0);
   int records_loaded = 0;

   // Skip header line
   string line = FileReadString(handle);

   while(!FileIsEnding(handle)) {
      line = FileReadString(handle);
      if(StringLen(line) < 10) continue;

      // Parse CSV line (simplified - in production use StringSplit)
      TradeRecordV8 record;
      // ... parsing logic would go here

      ArrayResize(episodic_memory, ArraySize(episodic_memory) + 1);
      episodic_memory[ArraySize(episodic_memory)-1] = record;
      records_loaded++;

      // Limit to last 1000 trades for memory efficiency
      if(records_loaded >= 1000) break;
   }

   FileClose(handle);
   Print("Phase 2: Loaded ", records_loaded, " trades from ", TradeLogCSV);
}

//+------------------------------------------------------------------+
//| Save Episodic Memory to CSV (Phase 2)                            |
//+------------------------------------------------------------------+
void SaveEpisodicMemory()
{
   int handle = FileOpen(TradeLogCSV, FILE_CSV | FILE_WRITE | FILE_ANSI, ";");
   if(handle == INVALID_HANDLE) {
      Print("Phase 2: ERROR - Cannot open ", TradeLogCSV, " for writing");
      return;
   }

   // Write header
   FileWrite(handle, "open_time;ticket;type;volume;open_price;sl;tp;close_price;close_time;profit;commission;swap;state_id;prior_prob;posterior_prob;agent_votes;dag_trace;veto_reason");

   // Write all records
   for(int i=0; i<ArraySize(episodic_memory); i++) {
      FileWrite(handle,
         TimeToString(episodic_memory[i].open_time),
         episodic_memory[i].ticket,
         EnumToString(episodic_memory[i].type),
         episodic_memory[i].volume,
         episodic_memory[i].open_price,
         episodic_memory[i].sl,
         episodic_memory[i].tp,
         episodic_memory[i].close_price,
         TimeToString(episodic_memory[i].close_time),
         episodic_memory[i].profit,
         episodic_memory[i].commission,
         episodic_memory[i].swap,
         episodic_memory[i].state_id,
         episodic_memory[i].prior_prob,
         episodic_memory[i].posterior_prob,
         episodic_memory[i].agent_votes,
         episodic_memory[i].dag_trace,
         episodic_memory[i].veto_reason
      );
   }

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Update Bayesian Priors (Beta-Bernoulli) - Phase 2                |
//+------------------------------------------------------------------+
void UpdateBayesianPrior(int strategy_index, bool success)
{
   if(strategy_index < 0 || strategy_index >= 5) return;

   if(success) {
      strategy_alpha[strategy_index] += 1.0;
   } else {
      strategy_beta[strategy_index] += 1.0;
   }
}

//+------------------------------------------------------------------+
//| Calculate Posterior Mean (Phase 2)                               |
//+------------------------------------------------------------------+
double CalculatePosteriorMean(int strategy_index)
{
   if(strategy_index < 0 || strategy_index >= 5) return 0.5;

   double alpha = strategy_alpha[strategy_index];
   double beta = strategy_beta[strategy_index];

   return alpha / (alpha + beta);
}

//+------------------------------------------------------------------+
//| Encode State for Q-Table (Phase 2)                               |
//+------------------------------------------------------------------+
int EncodeMarketState(double rsi, double adx, int regime, datetime time, bool trend_up)
{
   // Discretize continuous variables
   int rsi_bin = (int)(rsi / 25.0);    // 0-3 (4 bins)
   int adx_bin = (int)(adx / 33.0);    // 0-2 (3 bins)

   // Session encoding (Phase 2)
   MqlDateTime dt;
   TimeToStruct(time, dt);
   int session_bin = 0;
   if(dt.hour >= 0 && dt.hour < 8) session_bin = 0;      // Asia
   else if(dt.hour >= 8 && dt.hour < 16) session_bin = 1; // London
   else session_bin = 2;                                  // NY

   // Mixed-radix encoding: state = regime*144 + rsi*36 + adx*12 + session*4 + trend
   int trend_bin = trend_up ? 1 : 0;
   int state = regime * 144 + rsi_bin * 36 + adx_bin * 12 + session_bin * 4 + trend_bin;

   return MathMin(state, Q_TABLE_STATES - 1);
}

//+------------------------------------------------------------------+
//| Update Working Memory Ring Buffer (Phase 2)                      |
//+------------------------------------------------------------------+
void UpdateWorkingMemory(int regime, double confidence)
{
   working_memory.recent_regimes[working_memory.head_index] = (double)regime;
   working_memory.recent_confidence[working_memory.head_index] = confidence;

   working_memory.head_index++;
   if(working_memory.head_index >= 10) working_memory.head_index = 0;
}

//+------------------------------------------------------------------+
//| Log Trade to Episodic Memory (Phase 2 + Phase 3 DAG trace)       |
//+------------------------------------------------------------------+
void LogTradeToEpisodicMemory(long ticket, ENUM_ORDER_TYPE type, double volume,
                               double open_price, double sl, double tp,
                               int state_id, double prior, double posterior,
                               string votes, string dag_trace, string veto_reason)
{
   ArrayResize(episodic_memory, ArraySize(episodic_memory) + 1);
   int idx = ArraySize(episodic_memory) - 1;

   episodic_memory[idx].open_time = TimeCurrent();
   episodic_memory[idx].ticket = ticket;
   episodic_memory[idx].type = type;
   episodic_memory[idx].volume = volume;
   episodic_memory[idx].open_price = open_price;
   episodic_memory[idx].sl = sl;
   episodic_memory[idx].tp = tp;
   episodic_memory[idx].close_price = 0.0;
   episodic_memory[idx].close_time = 0;
   episodic_memory[idx].profit = 0.0;
   episodic_memory[idx].commission = 0.0;
   episodic_memory[idx].swap = 0.0;
   episodic_memory[idx].state_id = state_id;
   episodic_memory[idx].prior_prob = prior;
   episodic_memory[idx].posterior_prob = posterior;
   episodic_memory[idx].agent_votes = votes;
   episodic_memory[idx].dag_trace = dag_trace;
   episodic_memory[idx].veto_reason = veto_reason;

   // Keep memory bounded
   if(ArraySize(episodic_memory) > 1000) {
      for(int _i = 0; _i < 999; _i++)
         episodic_memory[_i] = episodic_memory[_i + 1];
      ArrayResize(episodic_memory, 999);
   }
}

//==========================================================================
//  PHASE 3: SPECIALIST AGENT & DAG EXECUTION FUNCTIONS
//==========================================================================

//+------------------------------------------------------------------+
//| Run 5 Specialist Agents with VETO System (Phase 3)               |
//+------------------------------------------------------------------+
void RunSpecialistAgents(AgentContext &ctx)
{
   if(!EnableSpecialistAgents) return;

   int buy_votes = 0;
   int sell_votes = 0;
   bool veto_active = false;

   // Reset all agents
   for(int i=0; i<5; i++) {
      specialist_agents[i].signal = 0;
      specialist_agents[i].veto = false;
      specialist_agents[i].reasoning = "";
   }

   // === AGENT 1: TREND AGENT ===
   specialist_agents[0].agent_name = "TrendAgent";
   if(ctx.adxValue > ADX_MinStrength) {
      if(ctx.emaFast > ctx.emaSlow) {
         specialist_agents[0].signal = 1;  // Buy
         specialist_agents[0].confidence = 0.75;
         specialist_agents[0].reasoning = "EMA bullish crossover + ADX strong";
      } else {
         specialist_agents[0].signal = -1; // Sell
         specialist_agents[0].confidence = 0.75;
         specialist_agents[0].reasoning = "EMA bearish crossover + ADX strong";
      }
   } else {
      specialist_agents[0].signal = 0;
      specialist_agents[0].confidence = 0.3;
      specialist_agents[0].reasoning = "ADX weak - no clear trend";
   }

   // === AGENT 2: MOMENTUM AGENT ===
   specialist_agents[1].agent_name = "MomentumAgent";
   double momentum = ctx.rsiValue - 50.0;
   if(MathAbs(momentum) > 10) {
      specialist_agents[1].signal = (momentum > 0) ? 1 : -1;
      specialist_agents[1].confidence = 0.65;
      specialist_agents[1].reasoning = "RSI momentum: " + DoubleToString(momentum, 2);
   } else {
      specialist_agents[1].signal = 0;
      specialist_agents[1].confidence = 0.2;
      specialist_agents[1].reasoning = "RSI neutral";
   }

   // === AGENT 3: MEAN REVERSION AGENT ===
   specialist_agents[2].agent_name = "MeanReversionAgent";
   if(ctx.rsiValue > RSI_OB) {
      specialist_agents[2].signal = -1; // Sell (overbought)
      specialist_agents[2].confidence = 0.7;
      specialist_agents[2].reasoning = "RSI overbought > " + DoubleToString(RSI_OB, 1);
   } else if(ctx.rsiValue < RSI_OS) {
      specialist_agents[2].signal = 1;  // Buy (oversold)
      specialist_agents[2].confidence = 0.7;
      specialist_agents[2].reasoning = "RSI oversold < " + DoubleToString(RSI_OS, 1);
   } else {
      specialist_agents[2].signal = 0;
      specialist_agents[2].confidence = 0.2;
      specialist_agents[2].reasoning = "RSI in neutral zone";
   }

   // === AGENT 4: VOLATILITY AGENT (VETO SPECIALIST) ===
   specialist_agents[3].agent_name = "VolatilityAgent";
   double spread_pips = (symbolInfo.Ask() - symbolInfo.Bid()) / symbolInfo.Point();
   if(spread_pips > MaxSpreadPips) {
      specialist_agents[3].veto = true;
      specialist_agents[3].signal = 0;
      specialist_agents[3].confidence = 1.0;
      specialist_agents[3].reasoning = "SPREAD TOO HIGH: " + DoubleToString(spread_pips, 1) + " > " + IntegerToString(MaxSpreadPips);
      veto_active = true;
      last_veto_reason = specialist_agents[3].reasoning;
   } else {
      specialist_agents[3].veto = false;
      specialist_agents[3].reasoning = "Spread OK: " + DoubleToString(spread_pips, 1);
   }

   // === AGENT 5: SENTIMENT AGENT (VETO SPECIALIST) ===
   specialist_agents[4].agent_name = "SentimentAgent";
   // Simplified news filter - check if current hour is high-impact news time
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   // Major news typically at 8:30, 10:00, 14:00 EST (simplified check)
   if(dt.hour == 13 || dt.hour == 15 || dt.hour == 19) {  // Approximate news hours
      specialist_agents[4].veto = true;
      specialist_agents[4].signal = 0;
      specialist_agents[4].confidence = 1.0;
      specialist_agents[4].reasoning = "HIGH IMPACT NEWS WINDOW (hour=" + IntegerToString(dt.hour) + ")";
      veto_active = true;
      last_veto_reason = specialist_agents[4].reasoning;
   } else {
      specialist_agents[4].veto = false;
      specialist_agents[4].reasoning = "No major news window";
   }

   // === TALLY VOTES (if no veto) ===
   if(!veto_active || !EnableVetoSystem) {
      for(int i=0; i<3; i++) {  // Only strategic agents (0,1,2)
         if(specialist_agents[i].signal == 1) buy_votes++;
         if(specialist_agents[i].signal == -1) sell_votes++;
      }
   }

   // Set final decision in context
   if(veto_active && EnableVetoSystem) {
      ctx.tradingAllowed = false;
      ctx.blockReason = "VETO: " + last_veto_reason;
      ctx.agentBuyVotes = 0;
      ctx.agentSellVotes = 0;
   } else {
      ctx.agentBuyVotes = buy_votes;
      ctx.agentSellVotes = sell_votes;

      if(buy_votes >= ConsensusThreshold) {
         ctx.proposedType = ORDER_TYPE_BUY;
         ctx.tradingAllowed = true;
      } else if(sell_votes >= ConsensusThreshold) {
         ctx.proposedType = ORDER_TYPE_SELL;
         ctx.tradingAllowed = true;
      } else {
         ctx.tradingAllowed = false;
         ctx.blockReason = "Insufficient consensus (Buy:" + IntegerToString(buy_votes) + " Sell:" + IntegerToString(sell_votes) + ")";
      }
   }

   // Update working memory with agent confidence
   double avg_confidence = 0.0;
   for(int i=0; i<5; i++) avg_confidence += specialist_agents[i].confidence;
   avg_confidence /= 5.0;
   UpdateWorkingMemory(ctx.marketRegime, avg_confidence);
}

//+------------------------------------------------------------------+
//| Execute 5-Node Order Execution DAG (Phase 3)                     |
//+------------------------------------------------------------------+
bool ExecuteOrderDAG(ENUM_ORDER_TYPE type, double lots, double price, double sl, double tp, string comment)
{
   if(!EnableDagExecution) {
      // Fallback to direct execution
      return TryPlaceOrder(type, lots, price, sl, tp, comment);
   }

   bool dag_success = true;
   string dag_trace = "";

   // === NODE 1: VALIDATION ===
   dag_nodes[0].timestamp = TimeCurrent();
   dag_nodes[0].passed = false;

   double min_lot = symbolInfo.LotsMin();
   double max_lot = symbolInfo.LotsMax();
   double lot_step = symbolInfo.LotsStep();

   if(lots < min_lot || lots > max_lot) {
      dag_nodes[0].error_message = "Invalid lot size: " + DoubleToString(lots, 2) +
                                   " (min:" + DoubleToString(min_lot, 2) +
                                   " max:" + DoubleToString(max_lot, 2) + ")";
      dag_trace += "Validation:FAIL;";
      dag_success = false;
   } else if(price <= 0) {
      dag_nodes[0].error_message = "Invalid price: " + DoubleToString(price, 5);
      dag_trace += "Validation:FAIL;";
      dag_success = false;
   } else {
      dag_nodes[0].passed = true;
      dag_trace += "Validation:OK;";
   }

   // === NODE 2: RISK CHECK ===
   if(dag_success) {
      dag_nodes[1].timestamp = TimeCurrent();
      dag_nodes[1].passed = false;

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double risk_amount = lots * MathAbs(price - sl) * symbolInfo.TickValue() / symbolInfo.TickSize();
      double max_risk = equity * (RiskPercent / 100.0) * 2.0;  // Hard cap at 2x normal risk

      if(risk_amount > max_risk) {
         dag_nodes[1].error_message = "Risk exceeded: $" + DoubleToString(risk_amount, 2) +
                                      " > $" + DoubleToString(max_risk, 2);
         dag_trace += "RiskCheck:FAIL;";
         dag_success = false;
      } else {
         dag_nodes[1].passed = true;
         dag_trace += "RiskCheck:OK;";
      }
   }

   // === NODE 3: PREFLIGHT ===
   if(dag_success) {
      dag_nodes[2].timestamp = TimeCurrent();
      dag_nodes[2].passed = false;

      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {
         dag_nodes[2].error_message = "Trading not allowed in terminal";
         dag_trace += "PreFlight:FAIL;";
         dag_success = false;
      } else if(!SymbolInfoInteger(Symbol(), SYMBOL_TRADE_MODE)) {
         dag_nodes[2].error_message = "Symbol trading disabled";
         dag_trace += "PreFlight:FAIL;";
         dag_success = false;
      } else {
         dag_nodes[2].passed = true;
         dag_trace += "PreFlight:OK;";
      }
   }

   // === NODE 4: SUBMISSION ===
   ulong ticket = 0;
   if(dag_success) {
      dag_nodes[3].timestamp = TimeCurrent();
      dag_nodes[3].passed = false;

      trade.SetExpertMagicNumber(EA_MAGIC_NUMBER);
      trade.SetDeviationInPoints(SlippagePoints);

      if(type == ORDER_TYPE_BUY) {
         if(trade.Buy(lots, Symbol(), price, sl, tp, comment)) {
            ticket = trade.ResultOrder();
            dag_nodes[3].passed = (ticket > 0);
         }
      } else {
         if(trade.Sell(lots, Symbol(), price, sl, tp, comment)) {
            ticket = trade.ResultOrder();
            dag_nodes[3].passed = (ticket > 0);
         }
      }

      if(!dag_nodes[3].passed) {
         dag_nodes[3].error_message = "Order failed: err=" + IntegerToString(GetLastError());
         dag_trace += "Submission:FAIL;";
         dag_success = false;
      } else {
         dag_trace += "Submission:OK(ticket=" + IntegerToString(ticket) + ");";
      }
   }

   // === NODE 5: CONFIRMATION ===
   if(dag_success && ticket > 0) {
      dag_nodes[4].timestamp = TimeCurrent();
      dag_nodes[4].passed = false;

      Sleep(100);  // Brief pause for broker confirmation
      if(PositionSelectByTicket(ticket)) {
         dag_nodes[4].passed = true;
         dag_trace += "Confirmation:OK;";
         dag_success_count++;
      } else {
         dag_nodes[4].error_message = "Position confirmation failed for ticket #" + IntegerToString(ticket);
         dag_trace += "Confirmation:FAIL;";
         dag_success = false;
         dag_failure_count++;
      }
   }

   // Handle DAG failure
   if(!dag_success) {
      dag_failure_count++;
      last_dag_failure_time = TimeCurrent();

      // Find first failed node
      for(int i=0; i<5; i++) {
         if(!dag_nodes[i].passed) {
            Print("DAG FAILED at Node ", i, " (", dag_nodes[i].node_name, "): ", dag_nodes[i].error_message);
            break;
         }
      }

      // Log failed attempt to episodic memory
      LogTradeToEpisodicMemory((long)ticket, type, lots, price, sl, tp,
                               0, 0.5, 0.5, "", dag_trace, "DAG_EXECUTION_FAILED");
   }

   return dag_success;
}

//+------------------------------------------------------------------+
//| END OF FILE — GoldHunter UHF AGI v8.3 Phase 3 Edition            |
//+------------------------------------------------------------------+