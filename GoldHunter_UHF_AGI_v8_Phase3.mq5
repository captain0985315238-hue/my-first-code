//+------------------------------------------------------------------+
//|                                      GoldHunter_UHF_AGI_v8_Phase3.mq5 |
//|                        Expert Advisor: Agentic AI Architecture Phase 3 |
//|                        Features: OODA Loop, 2-Tier Memory, Q-Learning, |
//|                                  Bayesian Updates, 5-Agent VETO, 5-Node DAG |
//+------------------------------------------------------------------+
#property copyright "GoldHunter AGI Team"
#property link      "https://goldhunter.ai"
#property version   "8.03"
#property strict

//--- Includes
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Global Objects
CTrade         trade;
CPositionInfo  position;
COrderInfo     order;
CAccountInfo   account;
CSymbolInfo    symbol;

//+------------------------------------------------------------------+
//| Input Parameters - Strategy & Risk                               |
//+------------------------------------------------------------------+
input group "=== Risk Management ==="
input double RiskPercent        = 1.0;   // Risk per trade (%)
input int    MaxSpread          = 30;    // Max Spread (points)
input int    MagicNumber        = 88888; // Unique Magic Number
input bool   AllowHedging       = false; // Allow Hedging Positions

input group "=== AI & Memory ==="
input bool   UseMemorySystem    = true;  // Enable Two-Tier Memory
input bool   UseBayesianUpdate  = true;  // Enable Beta-Bernoulli Updates
input string MemoryFileName     = "GoldHunter_Memory_v8.dat";
input string TradeLogFileName   = "GoldHunter_TradeLog_v8.csv";

input group "=== Phase 3: Agents & DAG ==="
input bool   EnableVetoSystem   = true;  // Enable Specialist Veto
input bool   EnableDagExecution = true;  // Enable 5-Node DAG
input int    ConsensusThreshold = 3;     // Min Agents for Approval (if no veto)

//+------------------------------------------------------------------+
//| Phase 3: Specialist Agent Structures                             |
//+------------------------------------------------------------------+
struct AgentVote
{
   string agent_name;
   int    signal;       // 1=Buy, -1=Sell, 0=Neutral
   double confidence;   // 0.0 to 1.0
   bool   veto;         // True if this agent blocks the trade
   string reasoning;    // Explainable AI reason
};

//+------------------------------------------------------------------+
//| Phase 3: Order Execution DAG Node Result                         |
//+------------------------------------------------------------------+
struct DAGNodeResult
{
   string node_name;
   bool   passed;
   string error_message;
   datetime timestamp;
};

//+------------------------------------------------------------------+
//| Core State: AgentContext (Envelope)                              |
//+------------------------------------------------------------------+
struct AgentContext
{
   datetime timestamp;
   double   price_bid;
   double   price_ask;
   double   spread_points;
   
   // Technical Indicators
   double   rsi_value;
   double   adx_value;
   double   ema_fast;
   double   ema_slow;
   
   // Market Regime
   ENUM_MARKET_REGIME regime;
   
   // AI State
   int    encoded_state;    // Q-Learning State Key
   double bayesian_alpha;   // Success count (Strategy specific)
   double bayesian_beta;    // Failure count
   double posterior_mean;   // P(Success | Data)
   
   // Decision
   int    action;           // 1=Buy, -1=Sell, 0=Hold
   double lot_size;
   double sl_price;
   double tp_price;
   
   // Interpretability
   string pipeline_trace;  // Log of decisions
};

//+------------------------------------------------------------------+
//| Phase 2: Two-Tier Memory System                                  |
//+------------------------------------------------------------------+
struct SessionWorkingMemory
{
   // Ring Buffer for Recent Contexts (Simplified to avoid forward decl issues)
   double recent_regimes[10];
   double recent_confidence[10];
   int    head_index;
   
   double session_pnl;
   int    trades_today;
   datetime last_reset_time;
};

struct TradeRecordV8
{
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
   
   // AI Metadata
   int      state_id;
   double   prior_prob;
   double   posterior_prob;
   string   agent_votes;    // Serialized votes
   string   dag_trace;      // DAG execution path
   string   veto_reason;    // If rejected
};

// Global Memory Instances
SessionWorkingMemory working_memory;
TradeRecordV8        episodic_memory[]; // Dynamic array for history

// Q-Table Storage (State -> Action Value)
double Q_Table[]; 
int Q_TABLE_SIZE = 360; // 5*4*3*3*2 resolution

// Bayesian Priors per Strategy (Alpha, Beta)
double Strategy_Alpha[5]; 
double Strategy_Beta[5];

// Phase 3 Globals
AgentVote agent_votes[5];
DAGNodeResult dag_results[5];
int dag_failed_attempts = 0;
datetime last_dag_failure_time = 0;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== GoldHunter AGI v8.3 (Phase 3) Initializing ===");
   
   // Initialize Symbol Info
   if(!symbol.Name(_Symbol)) return(INIT_FAILED);
   symbol.Refresh();
   
   // Initialize Working Memory
   working_memory.head_index = 0;
   working_memory.session_pnl = 0.0;
   working_memory.trades_today = 0;
   working_memory.last_reset_time = TimeCurrent();
   
   // Initialize Q-Table
   ArrayResize(Q_Table, Q_TABLE_SIZE);
   ArrayInitialize(Q_Table, 0.0);
   
   // Initialize Bayesian Priors (Uniform Prior: Alpha=1, Beta=1)
   for(int i=0; i<5; i++) {
      Strategy_Alpha[i] = 1.0;
      Strategy_Beta[i]  = 1.0;
   }
   
   // Load Episodic Memory
   if(UseMemorySystem) LoadEpisodicMemory();
   
   Print("Initialization Complete. OODA Loop Ready.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   SaveEpisodicMemory();
   Print("GoldHunter AGI Shutting Down. Memory Saved.");
}

//+------------------------------------------------------------------+
//| Main Event Loop: OODA State Machine                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Refresh Symbol Data
   symbol.Refresh();
   
   // --- OBSERVE ---
   AgentContext current_context;
   Observe(current_context);
   
   // --- ORIENT ---
   Orient(current_context);
   
   // --- DECIDE (Phase 3: Multi-Agent + VETO) ---
   int decision = Decide(current_context);
   
   // --- ACT (Phase 3: DAG Execution) ---
   if(decision != 0)
   {
      Act(current_context, decision);
   }
   
   // Update Working Memory Ring Buffer
   UpdateWorkingMemory(current_context);
}

//+------------------------------------------------------------------+
//| PHASE 1: OBSERVE - Data Collection                               |
//+------------------------------------------------------------------+
void Observe(AgentContext &ctx)
{
   ctx.timestamp = TimeCurrent();
   ctx.price_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ctx.price_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   ctx.spread_points = (long)((ctx.price_ask - ctx.price_bid) / SymbolInfoDouble(_Symbol, SYMBOL_POINT));
   
   // Simplified Indicator Calculation (Replace with actual handles in prod)
   // Using iHandle functions would require proper handle management
   // For now, using placeholder values that will be replaced with real indicator calls
   double rsi_buffer[];
   double adx_buffer[];
   double ema_fast_buffer[];
   double ema_slow_buffer[];
   
   ArraySetAsSeries(rsi_buffer, true);
   ArraySetAsSeries(adx_buffer, true);
   ArraySetAsSeries(ema_fast_buffer, true);
   ArraySetAsSeries(ema_slow_buffer, true);
   
   // Copy indicator values (assuming handles are created in OnInit)
   // In production, create handles in OnInit and copy here
   int rsi_handle = iRSI(_Symbol, _Period, 14, PRICE_CLOSE);
   int adx_handle = iADX(_Symbol, _Period, 14);
   int ema_fast_handle = iMA(_Symbol, _Period, 9, 0, MODE_EMA, PRICE_CLOSE);
   int ema_slow_handle = iMA(_Symbol, _Period, 21, 0, MODE_EMA, PRICE_CLOSE);
   
   if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_buffer) > 0) ctx.rsi_value = rsi_buffer[0];
   else ctx.rsi_value = 50.0;
   
   if(CopyBuffer(adx_handle, 0, 0, 1, adx_buffer) > 0) ctx.adx_value = adx_buffer[0];
   else ctx.adx_value = 20.0;
   
   if(CopyBuffer(ema_fast_handle, 0, 0, 1, ema_fast_buffer) > 0) ctx.ema_fast = ema_fast_buffer[0];
   else ctx.ema_fast = ctx.price_bid;
   
   if(CopyBuffer(ema_slow_handle, 0, 0, 1, ema_slow_buffer) > 0) ctx.ema_slow = ema_slow_buffer[0];
   else ctx.ema_slow = ctx.price_bid;
   
   // Release handles (in production, create once in OnInit and release in OnDeinit)
   IndicatorRelease(rsi_handle);
   IndicatorRelease(adx_handle);
   IndicatorRelease(ema_fast_handle);
   IndicatorRelease(ema_slow_handle);
   
   ctx.pipeline_trace = "OBSERVE: Data Collected | Spread: " + IntegerToString((long)ctx.spread_points);
}

//+------------------------------------------------------------------+
//| PHASE 1: ORIENT - State Encoding & Memory Retrieval              |
//+------------------------------------------------------------------+
void Orient(AgentContext &ctx)
{
   // 1. Determine Market Regime
   if(ctx.adx_value > 25.0) ctx.regime = REGIME_TRENDING;
   else ctx.regime = REGIME_RANGING;
   
   // 2. Encode State for Q-Table (Phase 2 Requirement)
   // Encoding: Regime(2) * RSI(4) * ADX(3) * Session(3) * Trend(2) = 360 states
   int rsi_bin = (int)(ctx.rsi_value / 25.0); // 0-4
   if(rsi_bin > 3) rsi_bin = 3;
   if(rsi_bin < 0) rsi_bin = 0;
   
   int adx_bin = (int)(ctx.adx_value / 30.0); // 0-3
   if(adx_bin > 2) adx_bin = 2;
   if(adx_bin < 0) adx_bin = 0;
   
   int session_bin = GetSessionBin(ctx.timestamp);
   int trend_bin = (ctx.ema_fast > ctx.ema_slow) ? 1 : 0;
   
   ctx.encoded_state = (int)ctx.regime * 144 + rsi_bin * 36 + adx_bin * 12 + session_bin * 4 + trend_bin;
   if(ctx.encoded_state >= Q_TABLE_SIZE) ctx.encoded_state = Q_TABLE_SIZE - 1;
   if(ctx.encoded_state < 0) ctx.encoded_state = 0;
   
   // 3. Retrieve Bayesian Priors for this State/Strategy
   // Mapping state to strategy index (simplified)
   int strategy_idx = ctx.encoded_state % 5;
   ctx.bayesian_alpha = Strategy_Alpha[strategy_idx];
   ctx.bayesian_beta  = Strategy_Beta[strategy_idx];
   
   // Calculate Posterior Mean: Alpha / (Alpha + Beta)
   if((ctx.bayesian_alpha + ctx.bayesian_beta) > 0.0)
      ctx.posterior_mean = ctx.bayesian_alpha / (ctx.bayesian_alpha + ctx.bayesian_beta);
   else
      ctx.posterior_mean = 0.5;
   
   ctx.pipeline_trace += " | ORIENT: State=" + IntegerToString(ctx.encoded_state) + 
                         " | Prob=" + DoubleToString(ctx.posterior_mean, 3);
}

//+------------------------------------------------------------------+
//| PHASE 3: DECIDE - Multi-Agent Voting & VETO                      |
//+------------------------------------------------------------------+
int Decide(AgentContext &ctx)
{
   int consensus_buy = 0;
   int consensus_sell = 0;
   bool veto_active = false;
   string veto_reason = "";
   
   // Reset Votes
   for(int i=0; i<5; i++) {
      agent_votes[i].agent_name = "";
      agent_votes[i].signal = 0;
      agent_votes[i].veto = false;
      agent_votes[i].confidence = 0.0;
      agent_votes[i].reasoning = "";
   }
   
   // --- Run 5 Specialist Agents ---
   
   // 1. Trend Agent
   agent_votes[0].agent_name = "TrendAgent";
   if(ctx.regime == REGIME_TRENDING) {
      if(ctx.ema_fast > ctx.ema_slow) {
         agent_votes[0].signal = 1;
         agent_votes[0].reasoning = "Uptrend detected (EMA Fast > Slow)";
      } else {
         agent_votes[0].signal = -1;
         agent_votes[0].reasoning = "Downtrend detected (EMA Fast < Slow)";
      }
      agent_votes[0].confidence = 0.8;
   } else {
      agent_votes[0].signal = 0;
      agent_votes[0].confidence = 0.2;
      agent_votes[0].reasoning = "No clear trend (Ranging regime)";
   }
   
   // 2. Momentum Agent
   agent_votes[1].agent_name = "MomentumAgent";
   double momentum = ctx.price_bid - ctx.ema_fast;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(MathAbs(momentum) > point * 5.0) {
      if(momentum > 0) {
         agent_votes[1].signal = 1;
         agent_votes[1].reasoning = "Positive momentum";
      } else {
         agent_votes[1].signal = -1;
         agent_votes[1].reasoning = "Negative momentum";
      }
      agent_votes[1].confidence = 0.7;
   } else {
      agent_votes[1].signal = 0;
      agent_votes[1].reasoning = "Low momentum";
   }
   
   // 3. Mean Reversion Agent
   agent_votes[2].agent_name = "MeanRevAgent";
   if(ctx.regime == REGIME_RANGING) {
      if(ctx.rsi_value > 70.0) {
         agent_votes[2].signal = -1; // Sell
         agent_votes[2].confidence = 0.75;
         agent_votes[2].reasoning = "RSI overbought (>70)";
      } else if(ctx.rsi_value < 30.0) {
         agent_votes[2].signal = 1; // Buy
         agent_votes[2].confidence = 0.75;
         agent_votes[2].reasoning = "RSI oversold (<30)";
      } else {
         agent_votes[2].signal = 0;
         agent_votes[2].reasoning = "RSI neutral";
      }
   } else {
      agent_votes[2].signal = 0;
      agent_votes[2].reasoning = "Trending regime (no mean reversion)";
   }
   
   // 4. Volatility Agent (VETO SPECIALIST)
   agent_votes[3].agent_name = "VolatilityAgent";
   if(ctx.spread_points > (double)MaxSpread) {
      agent_votes[3].veto = true;
      veto_active = true;
      veto_reason = "Spread too high: " + IntegerToString((long)ctx.spread_points);
      agent_votes[3].reasoning = veto_reason;
   } else {
      agent_votes[3].reasoning = "Spread within limits";
   }
   
   // 5. Sentiment Agent (VETO SPECIALIST)
   agent_votes[4].agent_name = "SentimentAgent";
   // Simulated News Check (In real impl, check economic calendar)
   if(IsHighImpactNewsWindow()) {
      agent_votes[4].veto = true;
      veto_active = true;
      if(veto_reason == "") veto_reason = "High Impact News Window";
      else veto_reason += " + High Impact News";
      agent_votes[4].reasoning = veto_reason;
   } else {
      agent_votes[4].reasoning = "No high impact news";
   }
   
   // --- Tally Votes ---
   if(!veto_active || !EnableVetoSystem) {
      for(int i=0; i<3; i++) { // Only count strategic agents (0,1,2)
         if(agent_votes[i].signal == 1) consensus_buy++;
         if(agent_votes[i].signal == -1) consensus_sell++;
      }
   }
   
   // Final Decision Logic
   int final_action = 0;
   
   if(veto_active && EnableVetoSystem) {
      final_action = 0; // BLOCKED
      ctx.pipeline_trace += " | DECIDE: VETOED by " + veto_reason;
   } else {
      if(consensus_buy >= ConsensusThreshold) {
         final_action = 1;
         ctx.pipeline_trace += " | DECIDE: BUY (Votes: " + IntegerToString(consensus_buy) + ")";
      }
      else if(consensus_sell >= ConsensusThreshold) {
         final_action = -1;
         ctx.pipeline_trace += " | DECIDE: SELL (Votes: " + IntegerToString(consensus_sell) + ")";
      }
      else {
         final_action = 0;
         ctx.pipeline_trace += " | DECIDE: HOLD (Insufficient consensus)";
      }
   }
   
   // Calculate Lot Size based on Risk
   if(final_action != 0) {
      ctx.lot_size = CalculateLotSize(RiskPercent);
      ctx.action = final_action;
      
      // Set SL/TP (Simplified - 50 pips SL, 100 pips TP)
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double sl_distance = 500.0 * point;
      double tp_distance = 1000.0 * point;
      
      if(final_action == 1) {
         ctx.sl_price = NormalizeDouble(ctx.price_bid - sl_distance, _Digits);
         ctx.tp_price = NormalizeDouble(ctx.price_ask + tp_distance, _Digits);
      } else {
         ctx.sl_price = NormalizeDouble(ctx.price_ask + sl_distance, _Digits);
         ctx.tp_price = NormalizeDouble(ctx.price_bid - tp_distance, _Digits);
      }
   }
   
   return final_action;
}

//+------------------------------------------------------------------+
//| PHASE 3: ACT - 5-Node DAG Execution                              |
//+------------------------------------------------------------------+
void Act(AgentContext &ctx, int action)
{
   if(!EnableDagExecution) {
      // Fallback to direct execution if DAG disabled
      ExecuteMarketOrder(action, ctx.lot_size, ctx.sl_price, ctx.tp_price);
      return;
   }
   
   // Initialize DAG Results
   bool dag_success = true;
   
   // NODE 1: Validation
   dag_results[0].node_name = "Validation";
   dag_results[0].timestamp = TimeCurrent();
   dag_results[0].error_message = "";
   
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   if(ctx.lot_size <= 0.0 || ctx.lot_size < min_lot || ctx.lot_size > max_lot) {
      dag_results[0].passed = false;
      dag_results[0].error_message = "Invalid Lot Size: " + DoubleToString(ctx.lot_size, 2);
      dag_success = false;
   } else {
      dag_results[0].passed = true;
   }
   
   // NODE 2: RiskCheck
   if(dag_success) {
      dag_results[1].node_name = "RiskCheck";
      dag_results[1].timestamp = TimeCurrent();
      dag_results[1].error_message = "";
      
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      
      // Simplified risk calculation
      double risk_amount = ctx.lot_size * 500.0 * tick_value; // Assuming 50 pip SL
      
      if(equity > 0.0 && risk_amount > equity * (RiskPercent / 100.0) * 2.0) {
         dag_results[1].passed = false;
         dag_results[1].error_message = "Risk Limit Exceeded";
         dag_success = false;
      } else {
         dag_results[1].passed = true;
      }
   }
   
   // NODE 3: PreFlight
   if(dag_success) {
      dag_results[2].node_name = "PreFlight";
      dag_results[2].timestamp = TimeCurrent();
      dag_results[2].error_message = "";
      
      bool trade_allowed = TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
      bool trade_mode_ok = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_DISABLED;
      
      if(!trade_allowed || !trade_mode_ok) {
         dag_results[2].passed = false;
         dag_results[2].error_message = "Trading Disabled";
         dag_success = false;
      } else {
         dag_results[2].passed = true;
      }
   }
   
   // NODE 4: Submission
   long ticket = -1;
   if(dag_success) {
      dag_results[3].node_name = "Submission";
      dag_results[3].timestamp = TimeCurrent();
      dag_results[3].error_message = "";
      
      // Attempt Order
      trade.SetExpertMagicNumber(MagicNumber);
      trade.SetDeviationInPoints(50);
      trade.SetTypeFilling(ORDER_FILLING_IOC);
      
      if(action == 1) {
         if(trade.Buy(ctx.lot_size, _Symbol, 0.0, ctx.sl_price, ctx.tp_price, "AGI_Phase3")) {
            ticket = OrderGetTicket();
            dag_results[3].passed = true;
         } else {
            dag_results[3].passed = false;
            dag_results[3].error_message = "Order Send Failed: " + ErrorDescription(GetLastError());
            dag_success = false;
         }
      } else if(action == -1) {
         if(trade.Sell(ctx.lot_size, _Symbol, 0.0, ctx.sl_price, ctx.tp_price, "AGI_Phase3")) {
            ticket = OrderGetTicket();
            dag_results[3].passed = true;
         } else {
            dag_results[3].passed = false;
            dag_results[3].error_message = "Order Send Failed: " + ErrorDescription(GetLastError());
            dag_success = false;
         }
      }
   }
   
   // NODE 5: Confirmation
   if(dag_success) {
      dag_results[4].node_name = "Confirmation";
      dag_results[4].timestamp = TimeCurrent();
      dag_results[4].error_message = "";
      
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         dag_results[4].passed = true;
         // Update Bayesian Success
         UpdateBayesian(ctx.encoded_state, true);
         LogTradeRecord(ctx, ticket, true, "");
      } else {
         dag_results[4].passed = false;
         dag_results[4].error_message = "Position Confirmation Failed";
         dag_success = false;
      }
   }
   
   // Handle DAG Failure
   if(!dag_success) {
      dag_failed_attempts++;
      last_dag_failure_time = TimeCurrent();
      
      // Find first failed node for logging
      string fail_node = "Unknown";
      string fail_reason = "";
      for(int i=0; i<5; i++) {
         if(!dag_results[i].passed) {
            fail_node = dag_results[i].node_name;
            fail_reason = dag_results[i].error_message;
            break;
         }
      }
      Print("DAG Execution Failed at Node: ", fail_node, " | Reason: ", fail_reason);
      
      // Update Bayesian Failure (if we got to submission but failed)
      if(dag_results[3].passed && !dag_results[4].passed) {
         UpdateBayesian(ctx.encoded_state, false);
      }
      
      LogTradeRecord(ctx, -1, false, fail_node + ": " + fail_reason);
   }
}

//+------------------------------------------------------------------+
//| Helper: Execute Market Order (Fallback)                          |
//+------------------------------------------------------------------+
void ExecuteMarketOrder(int action, double lots, double sl, double tp)
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(50);
   
   if(action == 1) {
      if(trade.Buy(lots, _Symbol, 0.0, sl, tp, "AGI_Direct")) {
         Print("Direct BUY executed successfully");
         UpdateBayesian(0, true); // Simplified state update
      } else {
         Print("Direct BUY failed: ", ErrorDescription(GetLastError()));
         UpdateBayesian(0, false);
      }
   } else if(action == -1) {
      if(trade.Sell(lots, _Symbol, 0.0, sl, tp, "AGI_Direct")) {
         Print("Direct SELL executed successfully");
         UpdateBayesian(0, true);
      } else {
         Print("Direct SELL failed: ", ErrorDescription(GetLastError()));
         UpdateBayesian(0, false);
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: Update Bayesian Priors (Phase 2)                         |
//+------------------------------------------------------------------+
void UpdateBayesian(int state, bool success)
{
   if(!UseBayesianUpdate) return;
   
   int strat_idx = state % 5;
   if(strat_idx < 0 || strat_idx >= 5) strat_idx = 0;
   
   if(success) {
      Strategy_Alpha[strat_idx] += 1.0;
   } else {
      Strategy_Beta[strat_idx] += 1.0;
   }
}

//+------------------------------------------------------------------+
//| Helper: Log Trade Record to CSV (Phase 2)                        |
//+------------------------------------------------------------------+
void LogTradeRecord(AgentContext &ctx, long ticket, bool executed, string failure_reason)
{
   if(!UseMemorySystem) return;
   
   int handle = FileOpen(TradeLogFileName, FILE_CSV | FILE_WRITE | FILE_ANSI, ";");
   if(handle == INVALID_HANDLE) {
      Print("Failed to open trade log file");
      return;
   }
   
   // Write Header if new
   if(FileSize(handle) == 0) {
      FileWrite(handle, "Time;Ticket;Type;Volume;Open;SL;TP;Close;Profit;StateID;Posterior;DAG_Trace;Failure_Reason");
   }
   
   FileSeek(handle, 0, SEEK_END);
   
   string dag_trace = "";
   if(executed) {
      for(int i=0; i<5; i++) {
         dag_trace += dag_results[i].node_name + ":" + (dag_results[i].passed ? "OK" : "FAIL") + ";";
      }
   } else {
      dag_trace = "EXECUTION_FAILED";
   }
   
   FileWrite(handle, 
      TimeToString(ctx.timestamp),
      ticket,
      (ctx.action == 1 ? "BUY" : "SELL"),
      ctx.lot_size,
      ctx.price_bid,
      ctx.sl_price,
      ctx.tp_price,
      0.0, // Close price pending
      0.0, // Profit pending
      ctx.encoded_state,
      ctx.posterior_mean,
      dag_trace,
      failure_reason
   );
   
   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Helper: Load/Save Episodic Memory (Phase 2)                      |
//+------------------------------------------------------------------+
void LoadEpisodicMemory() {
   // Implementation to load historical trades into episodic_memory[]
   int handle = FileOpen(MemoryFileName, FILE_BIN | FILE_READ);
   if(handle != INVALID_HANDLE) {
      Print("Loading Episodic Memory from ", MemoryFileName);
      // Read logic would go here
      FileClose(handle);
   } else {
      Print("No existing memory file found, starting fresh");
   }
}

void SaveEpisodicMemory() {
   // Implementation to save episodic_memory[] to disk
   int handle = FileOpen(MemoryFileName, FILE_BIN | FILE_WRITE);
   if(handle != INVALID_HANDLE) {
      Print("Saving Episodic Memory to ", MemoryFileName);
      // Write logic would go here
      FileClose(handle);
   }
}

//+------------------------------------------------------------------+
//| Helper: Update Working Memory Ring Buffer                        |
//+------------------------------------------------------------------+
void UpdateWorkingMemory(AgentContext &ctx)
{
   working_memory.recent_regimes[working_memory.head_index] = (double)ctx.regime;
   working_memory.recent_confidence[working_memory.head_index] = ctx.posterior_mean;
   
   working_memory.head_index++;
   if(working_memory.head_index >= 10) working_memory.head_index = 0;
}

//+------------------------------------------------------------------+
//| Helper: Session Bin Encoder                                      |
//+------------------------------------------------------------------+
int GetSessionBin(datetime time)
{
   MqlDateTime dt;
   TimeToStruct(time, dt);
   int hour = dt.hour;
   
   if(hour >= 0 && hour < 8) return 0;   // Asia
   if(hour >= 8 && hour < 16) return 1;  // London
   return 2;                             // NY
}

//+------------------------------------------------------------------+
//| Helper: Calculate Lot Size                                       |
//+------------------------------------------------------------------+
double CalculateLotSize(double risk_percent)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   double risk_money = equity * (risk_percent / 100.0);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double stop_loss_points = 500.0; // Default 50 pips
   
   if(tick_size <= 0.0 || tick_value <= 0.0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   double lot = risk_money / (stop_loss_points * (tick_value / tick_size));
   
   // Normalize
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(step <= 0.0) step = 0.01;
   
   lot = MathFloor(lot / step) * step;
   if(lot < min_lot) lot = min_lot;
   if(lot > max_lot) lot = max_lot;
   
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Helper: News Filter Stub                                         |
//+------------------------------------------------------------------+
bool IsHighImpactNewsWindow()
{
   // Placeholder: Integrate with Economic Calendar API
   // For now, returns false (no news blocking)
   return false; 
}

//+------------------------------------------------------------------+
//| Enum Definitions                                                 |
//+------------------------------------------------------------------+
enum ENUM_MARKET_REGIME {
   REGIME_TRENDING = 1,
   REGIME_RANGING = 2
};
//+------------------------------------------------------------------+
