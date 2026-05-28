# GoldHunter UHF AGI v7 → v8: Agentic Architecture Strategy & Qwen-Code Master Prompts

> **Document Purpose:** Full architectural blueprint and ready-to-paste Qwen-Code prompts for upgrading `GoldHunter_UHF_AGI_v6_fixed.mq5` from a monolithic reactive EA into a true Agentic AI trading system with formal reasoning loops, separated memory tiers, a tool-execution DAG, and multi-layered safety guardrails.

---

# PART 1: ARCHITECTURAL STRATEGY ANALYSIS

## 1.1 What the Current Codebase Actually Is

Before prescribing upgrades, here is an honest audit of what v7 currently contains and where the architectural debt lives:

| Component | Current State | Architectural Problem |
|---|---|---|
| **Reasoning Loop** | Implicit inside `OnTick()` — a flat waterfall of indicator reads → score → execute | No formal Plan-Execute-Observe cycle; cannot self-interrupt or re-plan |
| **Memory** | `tradeHistory[]` flat array (500-cap), `QTableEntry[]` (200-cap), globals scattered across 3,000 lines | No separation of working memory vs. episodic memory vs. long-term policy. Q-table uses raw integer indices — no state encoder |
| **Strategy Selection** | `BayesianStrategyProb` struct updated in `OnTradeTransaction` + `StrategyAutoAI()` scoring | Bayesian probs and Q-values exist in parallel with no reconciliation layer; one can override the other silently |
| **Tool Execution** | `TryPlaceOrder()` → `ExecuteSignal()` called inline — synchronous, blocking | No retry DAG, no pre-flight validation pipeline, no consequence prediction before execution |
| **Safety / Circuit Breaker** | `CheckSafetyLimits()` + `CheckConsecutiveLossCB()` — reactive only | CB triggers are post-hoc; no predictive risk model. `STATE_DEFENSIVE_MONITORING` doesn't actually reduce lot size — it only flags state |
| **Self-Healing Optimizer** | ±20% grid search over `ATR_SL`, `ATR_TP`, `MinConfidence` every 20 trades | Recommends params but **cannot apply them** (line 2954 comment: "In live EA, we'd use GlobalVariableSet"); the loop is cosmetic |
| **Neural Network** | `NeuralNetworkLayer` struct with weights defined but `UseNeuralNetwork` defaults to `false` | No inference function exists in the file; it's a data stub with no computational path |
| **Observability** | `LogStatus()` + Discord webhooks | No structured trace log; no causality chain linking signal → decision → outcome |

---

## 1.2 Translating AI Research Paradigms into MQ5/C++ Engineering Patterns

### Memory Architecture → Two-Tier Memory Manager

In LangChain/LlamaIndex paradigms, agents have:
- **Working Memory (Short-term):** The current tick's context — indicators, regime, open positions, CB state
- **Episodic Memory (Long-term):** Trade history encoded as feature vectors for Q-learning and Bayesian updates

In MQ5 this maps to:

```
WorkingMemoryContext (struct, rebuilt every OnTick)
  ├── MarketSnapshot: ATR, RSI, ADX, EMA cross state, regime ID
  ├── PositionContext: open tickets, unrealized PnL, trailing levels
  ├── RiskContext: daily DD%, session loss, consecutive losses
  └── SignalContext: buy/sell scores, confidence, reasons[]

EpisodicMemoryStore (persistent, file-backed)
  ├── TradeRecord[] → CSV (already partially implemented)
  ├── QTable (state-hashed entries, not raw int indices)
  └── BayesianObservationLog (strategy → outcome frequency table)
```

This separation is critical: the agent's decision function reads from WorkingMemory, but its policy weights are updated by EpisodicMemory. They must never be the same data structure.

### Agentic Reasoning Loop → The OODA Cycle as a Formal State Machine

The current code conflates **Observation** (UpdateIndicators), **Orientation** (DetectMarketRegime + strategy scoring), **Decision** (ExecuteSignal), and **Action** (TryPlaceOrder) inside a single `OnTick()` call with no checkpoints between phases. An agentic upgrade separates these into a formal pipeline:

```
OnTick() dispatches to AgentLoop():
  [OBSERVE]  → DataIngestionLayer: collects all sensor data, validates completeness
  [ORIENT]   → ReasoningEngine: regime detection + strategy selection (Q + Bayes + NN)
  [DECIDE]   → DecisionGate: confidence threshold check + all filter gates
  [PLAN]     → TradeConstructor: compute entry/SL/TP/lots with validation
  [EXECUTE]  → OrderExecutionDAG: pre-flight → send → verify → record
  [REFLECT]  → OutcomeObserver: update Q-table + Bayes probs + NN gradient (async)
```

Each phase is a function with a typed input and output struct. No phase can skip ahead. This matches the Actor Model pattern where each stage is an actor that consumes an input message and produces an output message.

### Multi-Agent Coordination → Specialist Sub-Agents

Instead of one monolithic strategy scorer, v8 uses specialist sub-agents that report weighted votes:

```
StrategyCoordinator (orchestrator)
  ├── TrendAgent:     EMA cross + ADX + HTF alignment → TREND_LONG/TREND_SHORT/NEUTRAL
  ├── MomentumAgent:  RSI + MACD + Stoch → MOMENTUM_BULL/MOMENTUM_BEAR/NEUTRAL
  ├── VolatilityAgent: BB + ATR regime → BREAKOUT/MEAN_REVERT/RANGING
  ├── OrderFlowAgent: TickDelta 3σ → BUYING_PRESSURE/SELLING_PRESSURE/BALANCED
  └── CorrelationAgent: DXY + XAUUSD → CONFIRMED/DIVERGENT/UNAVAILABLE

Vote aggregation: each agent returns (direction, confidence_0_to_1, reasons[])
Final decision requires: (a) majority vote, (b) minimum aggregate confidence, (c) no critical VETO
```

### Safety Guardrails → Multi-Layer Circuit Breaker with Predictive Risk

Current CB is purely reactive (loss already occurred). The ASI safety research model requires a **predictive + reactive** stack:

```
Layer 1 — Pre-Trade Validator (before any order):
  - Validates proposed lot size against Kelly bounds
  - Checks spread, liquidity, slippage history
  - HARD BLOCK on any parameter that violates constraints

Layer 2 — Reactive Circuit Breaker (existing, upgraded):
  - Loss%, DD%, consecutive losses triggers
  - Smart pause duration (existing logic is good — keep it)
  - MUST actually enforce lot reduction in DEFENSIVE_MONITORING state

Layer 3 — Predictive Risk Monitor (new):
  - Maintains a rolling Value-at-Risk estimate from trade history
  - Fires a "Yellow Alert" when VaR(95%) > 2× expected daily risk budget
  - Reduces confidence threshold by 10% as a soft brake before hard stop

Layer 4 — Immutable Hard Stops (ASI alignment layer):
  - Account equity < 50% of starting balance → DISABLED state, no override
  - More than 3 open positions at once → block new orders (currently not enforced)
  - These CANNOT be modified by the self-healing optimizer
```

### Recursive Self-Improvement → Constrained Optimizer with Alignment Validation

The current `SelfHealingOptimizer_Run()` correctly identifies better parameters but cannot apply them. The architecture upgrade adds an **Alignment Validation Gate** before any parameter mutation:

```
Optimizer proposes: ATR_SL = 1.8 (was 1.5), MinConf = 67 (was 62)
  ↓
AlignmentValidator checks:
  ✓ New SL still within [0.5× , 3.0×] absolute bounds?
  ✓ Confidence threshold not below 55 (hardcoded floor)?
  ✓ Proposed change backed by N ≥ 30 trade observations?
  ✓ Sharpe improvement is statistically significant (p < 0.05)?
  ↓ PASS → apply via GlobalVariableSet + log to audit trail
  ↓ FAIL → reject + notify Discord + increment rejection_count
  ↓ 3+ consecutive rejections → freeze optimizer, alert operator
```

This is the practical engineering analog to the "Alignment Problem" from ASI research — automated improvement systems must have bounded authority and human-auditable decision trails.

---

## 1.3 Target Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│                   GoldHunter AGI v8                      │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │              SAFETY LAYER (Always-On)             │   │
│  │  HardStop | AlignmentValidator | AuditTrail       │   │
│  └────────────────────┬─────────────────────────────┘   │
│                        │ guards every layer below        │
│  ┌──────────────────────────────────────────────────┐   │
│  │              AGENT REASONING LOOP                 │   │
│  │  OBSERVE → ORIENT → DECIDE → PLAN → EXECUTE →    │   │
│  │  REFLECT (OODA with async reflection)             │   │
│  └────────────────────┬─────────────────────────────┘   │
│                        │                                  │
│  ┌─────────┐  ┌────────┴──────────┐  ┌───────────────┐  │
│  │ MEMORY  │  │ SPECIALIST AGENTS │  │ TOOL ENGINE   │  │
│  │         │  │                   │  │               │  │
│  │Working  │  │ TrendAgent        │  │ PreFlightCheck│  │
│  │Memory   │  │ MomentumAgent     │  │ OrderDAG      │  │
│  │         │  │ VolatilityAgent   │  │ PositionMgr   │  │
│  │Episodic │  │ OrderFlowAgent    │  │ PartialClose  │  │
│  │Memory   │  │ CorrelationAgent  │  │ TrailManager  │  │
│  │         │  │                   │  │               │  │
│  │QTable   │  │ VoteAggregator    │  │ RetryPolicy   │  │
│  │BayesLog │  │ (StrategyCoord.)  │  │               │  │
│  │NNWeights│  └───────────────────┘  └───────────────┘  │
│  └─────────┘                                             │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │            SELF-HEALING OPTIMIZER                 │   │
│  │  Constrained grid search + AlignmentValidator     │   │
│  │  GlobalVariableSet application + Audit Log        │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

---

---

# PART 2: MASTER PROMPTS FOR QWEN-CODE

> **Instructions for Use:**
> - Each prompt below is a complete, self-contained instruction. Copy the entire block between the `---PROMPT START---` and `---PROMPT END---` markers.
> - Attach the file `GoldHunter_UHF_AGI_v6_fixed.mq5` to each prompt when submitting to Qwen-Code.
> - Execute prompts **in order** (Phase 1 → 5). Each phase builds on the output of the previous.
> - After each phase, save the output as `GoldHunter_v8_PhaseN.mq5` before proceeding.

---

## PHASE 1 PROMPT — Architecture Setup & Formal OODA State Machine

---PROMPT START---

**Role:** You are an expert MetaTrader 5 / MQL5 software architect. You understand the Actor Model, finite state machines, and agentic AI design patterns equivalent to LangChain's AgentExecutor loop.

**Task:** I am attaching my existing EA file `GoldHunter_UHF_AGI_v6_fixed.mq5` (3,049 lines). Your job is to **refactor its core execution architecture** according to the specifications below. Do NOT change any trading logic, indicator calculations, or parameter values — only restructure the execution pipeline.

**CURRENT PROBLEM:**
The existing `OnTick()` function implicitly chains: UpdateIndicators → DetectMarketRegime → StrategyAutoAI/ScalpM1/Swing/Breakout/Reversal → ExecuteSignal → ManagePositions → CheckSafetyLimits. There are no typed interfaces between phases, no checkpoints, and no ability to abort mid-pipeline cleanly.

**REQUIRED REFACTOR — The OODA Agent Loop:**

**Step 1: Define a `AgentContext` struct** that serves as the single message envelope passed through each phase. It must contain:
```mql5
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
```

**Step 2: Decompose `OnTick()` into these six named pipeline functions**, each accepting and mutating `AgentContext &ctx`:
```mql5
void Phase_Observe(AgentContext &ctx);    // Calls UpdateIndicators, populates sensor fields
void Phase_Orient(AgentContext &ctx);     // Calls specialist vote aggregation
void Phase_Decide(AgentContext &ctx);     // Applies all filter gates, sets tradingAllowed
void Phase_Plan(AgentContext &ctx);       // Computes lots/SL/TP, runs PreFlightValidator
void Phase_Execute(AgentContext &ctx);    // Calls TryPlaceOrder via OrderExecutionDAG
void Phase_Reflect(AgentContext &ctx);    // Updates Q-table + Bayes probs
```

**Step 3: The new `OnTick()` must be:**
```mql5
void OnTick() {
   AgentContext ctx;
   ZeroMemory(ctx);

   // Safety Layer always runs first — can abort entire loop
   if(!SafetyLayer_PreCheck()) return;

   Phase_Observe(ctx);
   if(!ctx.dataValid) return;

   Phase_Orient(ctx);
   Phase_Decide(ctx);

   if(ctx.tradingAllowed) {
      Phase_Plan(ctx);
      Phase_Execute(ctx);
   }

   ManagePositions();   // independent of signal pipeline
   Phase_Reflect(ctx);  // always runs (learning even on no-trade ticks)

   SafetyLayer_PostCheck(ctx);
   UpdateDashboard(ctx);
}
```

**Step 4: Introduce a `PipelineTrace` logging system.** Every phase must append a one-line entry to a string array `pipelineTrace[]` in the format:
```
"[PHASE_NAME][OK/FAIL][timestamp_ms] key=value, key=value"
```
This array (max 50 entries, circular) is printed to MT5 log on trade open/close and sent to Discord on CB trigger. This is the **mechanistic interpretability log** — every decision has a traceable causal chain.

**Constraints:**
- Keep ALL existing input parameters, indicator handles, and global variables — just move them into the new structure
- The refactored code must compile cleanly on MetaEditor 5 (MT5 build 4000+)
- Preserve all existing Discord webhook call sites — just route them through the new pipeline phases
- Output the complete refactored MQ5 file

---PROMPT END---

---

## PHASE 2 PROMPT — Memory Architecture & Context Integration

---PROMPT START---

**Role:** You are an expert MQL5 engineer specializing in persistent state management and learning systems, equivalent to implementing LangChain's ConversationBufferWindowMemory and VectorStoreRetriever in a constrained embedded environment.

**Task:** Upgrade the memory system in the attached EA (output from Phase 1). The current `TradeRecord[]` flat array and `QTableEntry[]` are poorly structured for learning. Implement a **Two-Tier Memory Manager** as specified below.

**TIER 1 — Working Memory (Per-Tick, In-RAM struct):**

The `AgentContext` struct already implements this. Additionally, create a `SessionWorkingMemory` struct that persists across ticks within a trading session:
```mql5
struct SessionWorkingMemory {
   // Recent decision ring buffer (last 10 ticks)
   AgentContext  recentContexts[10];
   int           ringHead;

   // Short-term pattern detector
   int           recentRegimes[20];    // last 20 detected regimes
   int           regimeHead;
   double        recentConfidences[20];// last 20 confidence scores
   int           confHead;

   // Intra-session trade outcomes (not yet persisted)
   double        sessionOpenPnL;
   double        sessionRealizedPnL;
   double        sessionPeakEquity;
   int           sessionWins, sessionLosses;
   int           sessionConsecLosses;
   datetime      sessionStartTime;

   // Trend consistency score (how stable is the regime)
   double        regimeStabilityScore; // 0=choppy, 1=stable trend
};
SessionWorkingMemory workingMem;
```

**Implement `WorkingMemory_Update(AgentContext &ctx)`** called at end of each tick to maintain the ring buffers and compute `regimeStabilityScore` as:
```
regimeStabilityScore = (count of last 10 regimes that equal current regime) / 10.0
```
Use this score in `Phase_Orient`: if `regimeStabilityScore < 0.4`, add +10% to the dynamic confidence threshold requirement (unstable market penalty).

**TIER 2 — Episodic Memory (Persistent, File-Backed):**

The current `TradeRecord` struct is missing critical features needed for Q-learning state encoding. Upgrade it:
```mql5
struct TradeRecordV8 {
   // Identifiers
   datetime  timestamp;
   ulong     ticket;

   // Trade facts
   ENUM_ORDER_TYPE type;
   double    entryPrice, exitPrice;
   double    profit, profitPips;
   double    slDistance, tpDistance;
   double    lotsUsed;
   int       barsHeld;

   // Decision context (the "why")
   int       regime;
   int       strategy;
   double    confidence;
   int       buyScore, sellScore;
   string    reasons;           // pipe-delimited signal reasons
   string    pipelineTrace;     // full mechanistic trace at entry

   // Market conditions at entry
   double    atrAtEntry;
   double    adxAtEntry;
   double    rsiAtEntry;
   double    spreadAtEntry;
   int       sessionAtEntry;    // 0=Asian 1=London 2=NY 3=LondonNY

   // Learning labels (filled on close)
   bool      wasWin;
   double    maePoints;         // Maximum Adverse Excursion in points
   double    mfePoints;         // Maximum Favorable Excursion in points
   int       exitReason;        // 0=SL 1=TP 2=Trailing 3=BreakEven 4=Partial 5=Manual
};
```

**Implement `EpisodicMemory_Persist(TradeRecordV8 &rec)`:**
- Appends to `GoldHunter_TradeLog_v8.csv` with ALL fields as columns
- Uses `FileOpen` with `FILE_CSV|FILE_WRITE|FILE_SHARE_READ|FILE_ANSI` flags
- Header row auto-written if file is new (check `FileSize()` == 0)
- Call this in `OnTradeTransaction` when `DEAL_ENTRY == DEAL_ENTRY_OUT`

**Implement `EpisodicMemory_LoadLast(int n, TradeRecordV8 &out[])`:**
- Reads last N records from CSV on `OnInit()` to restore Q-table and Bayes state
- Uses `FileOpen` with `FILE_CSV|FILE_READ|FILE_SHARE_WRITE` flags
- Skips header row, reads from end of file (open, seek, read backwards)
- Populates the global `tradeHistory[]` array

**Q-Table State Encoder — replace raw integer indexing:**

The current Q-table uses `qTable[index]` with no proper state hashing. Replace with a proper state vector encoder:
```mql5
int QState_Encode(AgentContext &ctx) {
   // Discretize continuous values into buckets
   int regimeBucket  = ctx.marketRegime;              // 1–5 (5 states)
   int rsiBucket     = (ctx.rsiValue < 35) ? 0 :      // 0=OS, 1=Mid, 2=OB
                       (ctx.rsiValue > 65) ? 2 : 1;
   int adxBucket     = (ctx.adxValue < 20) ? 0 :      // 0=Weak, 1=Mod, 2=Strong
                       (ctx.adxValue > 35) ? 2 : 1;
   int emaBucket     = (ctx.emaFast > ctx.emaSlow) ? 1 : 0; // 0=Bear, 1=Bull
   int sessionBucket = GetSessionBucket();             // 0=Asian 1=London 2=NY 3=Overlap

   // Cantor pairing / mixed-radix encoding → single int key
   // State space: 5 × 3 × 3 × 2 × 4 = 360 states (fits in MAX_QTABLE_ENTRIES)
   return regimeBucket + 5*(rsiBucket + 3*(adxBucket + 3*(emaBucket + 2*sessionBucket)));
}
```

**Q-Table persistence — implement these two functions:**
```mql5
void QTable_Save();  // writes all entries to GoldHunter_QTable_v8.csv (key, q0, q1, q2, visits, lastUpdate)
void QTable_Load();  // reads on OnInit(), populates qTable[] using QState_Encode as key
```

**Bayesian Update — fix the implicit update:**

Currently `BayesianStrategyProb` is a simple probability struct with no observation log. Implement:
```mql5
void Bayes_UpdatePosterior(int strategy, bool wasWin, double priorWeight) {
   // Beta-Bernoulli conjugate update
   // For each strategy s: alpha_s (wins+1), beta_s (losses+1)
   // Posterior mean = alpha / (alpha + beta)
   // Store alpha/beta counts, not raw probabilities
}
double Bayes_GetPosteriorMean(int strategy);
int    Bayes_SelectBestStrategy(AgentContext &ctx); // returns strategy with highest posterior
```

**Constraints:**
- All file I/O must use MQL5 `FileXxx` API — no external DLLs
- Array sizes must be `#define` constants to avoid stack overflow
- The `TradeRecordV8` CSV must be human-readable (for manual auditing)
- Output the complete upgraded MQ5 file

---PROMPT END---

---

## PHASE 3 PROMPT — Specialist Agent Voting & Tool-Execution DAG

---PROMPT START---

**Role:** You are an expert MQL5 architect implementing a multi-agent coordination pattern equivalent to a LangChain `RouterChain` with specialist tool agents. You also understand Directed Acyclic Graph (DAG) execution pipelines for order flow management.

**Task:** Upgrade the attached EA (Phase 2 output) with (A) a formal specialist agent voting system and (B) a robust Order Execution DAG. These replace the monolithic `StrategyAutoAI()` scoring function and the simple `TryPlaceOrder()` fallback chain.

---

### PART A: Specialist Agent System

**Replace** the single `StrategyAutoAI()` function with five specialist agents. Each agent is a function with this signature:
```mql5
struct AgentVote {
   int    direction;        // +1=Buy, -1=Sell, 0=Neutral
   double confidence;       // 0.0 to 1.0
   double weight;           // agent's vote weight (dynamic)
   string reasons;          // pipe-delimited evidence string
   bool   isVeto;           // if true, BLOCKS trade regardless of others
};
```

**Implement these five agent functions** using the existing indicator values in `AgentContext`:

**1. `AgentVote TrendAgent_Vote(AgentContext &ctx)`**
- Evidence: EMA8/21/89 hierarchy, H4 EMA50/200, HTF alignment, ADX > threshold
- Weight: 3.0 in trending regimes (1,2), 0.5 in ranging regime (3)
- Veto: if ADX < 18 AND regime is forced-trend, emit `isVeto=true` to block trend trades

**2. `AgentVote MomentumAgent_Vote(AgentContext &ctx)`**
- Evidence: RSI divergence, MACD crossover + histogram direction, Stochastic K/D cross
- Weight: 2.0 in all regimes
- Veto: if RSI > 85 on buy or RSI < 15 on sell (extreme extension — high reversal risk)

**3. `AgentVote VolatilityAgent_Vote(AgentContext &ctx)`**
- Evidence: BB width vs 20-period average, ATR expansion ratio, pin bars, engulfing bars
- Weight: 3.0 in volatile regime (4), 2.0 in breakout, 1.0 otherwise
- Veto: if `atrValue > prevAtrValue * 2.5` (ATR spike 2.5×) — abnormal volatility, block all new entries

**4. `AgentVote OrderFlowAgent_Vote(AgentContext &ctx)`**
- Evidence: TickDelta (buy volume minus sell volume from `tickDelta` struct), 3σ imbalance check
- Weight: 2.5 when imbalance is detected, 0.5 when balanced
- Implementation: compute rolling mean and std of delta buffer, fire VETO if delta is NaN or buffer has < 10 ticks

**5. `AgentVote CorrelationAgent_Vote(AgentContext &ctx)`**
- Evidence: DXY/XAUUSD return correlation from `corrGuard` struct
- Direction: if DXY and XAUUSD moving in same direction → SELL (anomaly, gold should inverse DXY)
- Weight: 1.5 when data available, 0.0 when `corrGuard.dxyAvailable == false`
- Veto: if correlation data is fresh but DXY signal directly contradicts proposed direction with high confidence (>0.8)

**Implement `VoteAggregator_Run(AgentContext &ctx)`:**
```mql5
void VoteAggregator_Run(AgentContext &ctx) {
   AgentVote votes[5];
   votes[0] = TrendAgent_Vote(ctx);
   votes[1] = MomentumAgent_Vote(ctx);
   votes[2] = VolatilityAgent_Vote(ctx);
   votes[3] = OrderFlowAgent_Vote(ctx);
   votes[4] = CorrelationAgent_Vote(ctx);

   // Check for any veto
   for(int i = 0; i < 5; i++) {
      if(votes[i].isVeto) {
         ctx.tradingAllowed = false;
         ctx.blockReason = "VETO:" + votes[i].reasons;
         return; // Hard stop
      }
   }

   // Weighted vote summation
   double buyScore = 0, sellScore = 0, totalWeight = 0;
   for(int i = 0; i < 5; i++) {
      totalWeight += votes[i].weight;
      if(votes[i].direction == +1)  buyScore  += votes[i].confidence * votes[i].weight;
      else if(votes[i].direction == -1) sellScore += votes[i].confidence * votes[i].weight;
      ctx.decisionReasons += votes[i].reasons + "|";
   }

   // Normalize to 0–100 confidence
   if(totalWeight > 0) {
      double maxScore = MathMax(buyScore, sellScore);
      ctx.aggregateConfidence = (maxScore / totalWeight) * 100.0;
      ctx.agentBuyVotes  = (int)(buyScore  * 10); // scale to old score range for compatibility
      ctx.agentSellVotes = (int)(sellScore * 10);
   }
}
```

Integrate `VoteAggregator_Run(ctx)` into `Phase_Orient()` to replace the old `StrategyAutoAI()` call.

---

### PART B: Order Execution DAG

Replace `TryPlaceOrder()` with an **OrderExecutionDAG** that has explicit nodes:

```
Node 1: PreFlightValidation
   - Check spread <= MaxSpreadPips
   - Check lots within [MinLot, MaxLot] and >= SymbolInfo.LotsMin()
   - Check SL distance >= SymbolInfo.StopsLevel() * Point
   - Check no existing EA position on this symbol (prevent double entry)
   - Check CB pause not active
   → FAIL: log to pipelineTrace, return false, record skip reason

Node 2: LiquidityCheck
   - Check tick volume of last bar >= 10 (not a dead market)
   - Check bid-ask spread has not widened since signal was generated (re-check)
   → FAIL: log warning, still allow but flag in TradeRecordV8.exitReason

Node 3: OrderSubmission (3-attempt retry with fill-mode fallback)
   - Attempt 1: IOC fill
   - Attempt 2: FOK fill (if retcode is REQUOTE or PRICE_OFF)
   - Attempt 3: RETURN fill
   - On each failure: log retcode + timestamp to pipelineTrace
   → FAIL all 3: increment failed_attempts counter, send Discord alert after 3 consecutive failures

Node 4: OrderVerification
   - Wait up to 500ms for `PositionsTotal()` to reflect new position
   - Verify ticket exists via PositionSelectByTicket
   - Verify open price is within acceptable slippage of intended price
   → FAIL: flag as "GHOST_ORDER", trigger Discord alert, log full context

Node 5: PostTradeRecord
   - Populate TradeRecordV8 entry (partial — closes will fill exit fields)
   - Store pipeline trace string in record
   - Call EpisodicMemory_Persist() with partial record
```

**Implement as:**
```mql5
bool OrderExecutionDAG_Run(AgentContext &ctx);  // returns true only if Node 4 verification succeeds
```

**Also implement `PositionManager_DAG()`** which replaces `ManagePositions()`:
- Same logic as existing ManagePositions (trailing, breakeven, TP1, profit lock)
- BUT: each modification attempt must be verified (check `trade.ResultRetcode()`)
- Phantom SL guard (existing) must also apply to partial closes
- Log each modification action to pipelineTrace with before/after values

**Constraints:**
- Existing `CTrade trade`, `CSymbolInfo symbolInfo`, `CPositionInfo posInfo` objects must be reused
- DAG nodes must be individual named functions (not one monolithic block) for auditability
- Output the complete upgraded MQ5 file

---PROMPT END---

---

## PHASE 4 PROMPT — Safety Guardrails, Circuit Breakers & Alignment Layer

---PROMPT START---

**Role:** You are an expert MQL5 safety systems engineer with deep knowledge of ASI alignment principles, circuit breaker design patterns, and mechanistic interpretability logging. You understand that in a live trading system with real financial consequences, safety layers must be **hard-coded immutable constraints** that no self-improvement routine can override.

**Task:** Upgrade the attached EA (Phase 3 output) with a comprehensive multi-layer safety architecture. Current problems to fix:
1. `STATE_DEFENSIVE_MONITORING` sets a flag but does NOT actually reduce position sizes
2. Hard stops are soft — they transition to defensive mode instead of blocking orders
3. The SelfHealingOptimizer recommends parameter changes but cannot validate them against safety bounds
4. No audit trail exists that is separate from the regular Discord notifications

---

### LAYER 0 — Immutable Hard Stop Constants (ASI Alignment Layer)

Add these `#define` constants at the top of the file. They CANNOT be `input` parameters. They CANNOT be modified by any optimizer. They are the **Constitutional Rules** of the system:

```mql5
// === CONSTITUTIONAL SAFETY CONSTANTS — DO NOT MODIFY WITHOUT HUMAN REVIEW ===
#define HARD_STOP_EQUITY_FLOOR_PCT    50.0   // Equity < 50% of session start → FULL DISABLE
#define HARD_STOP_MAX_OPEN_POSITIONS  3      // Never hold more than 3 EA positions simultaneously
#define HARD_STOP_MAX_LOT_ABSOLUTE    2.0    // Hard ceiling on lot size regardless of Kelly
#define HARD_STOP_MIN_CONFIDENCE      50.0   // Confidence floor — optimizer cannot go below this
#define HARD_STOP_MIN_SL_ATR_MULT     0.3    // SL multiplier floor — optimizer cannot go below this
#define HARD_STOP_MAX_SL_ATR_MULT     5.0    // SL multiplier ceiling
#define HARD_STOP_MAX_RISK_PCT        10.0   // Max risk per trade as % of balance — hard ceiling
#define HARD_STOP_MAX_DAILY_LOSS_PCT  30.0   // Absolute max daily loss — triggers FULL DISABLE
#define AUDIT_LOG_FILE                "GoldHunter_AuditTrail.log"
#define SAFETY_REPORT_INTERVAL_SEC    300    // Send safety status to Discord every 5 minutes
```

**Implement `HardStop_CheckAll()`:**
```mql5
bool HardStop_CheckAll() {
   // Returns true = safe to proceed, false = block all trading
   // This function is called FIRST in OnTick() before any AgentContext allocation

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);

   // Check 1: Equity floor
   double sessionStart = (dailyStartBalance > 0) ? dailyStartBalance : balance;
   if(equity < sessionStart * (1.0 - HARD_STOP_MAX_DAILY_LOSS_PCT / 100.0)) {
      HardStop_TriggerDisable("EQUITY_FLOOR: " +
            DoubleToString((equity-sessionStart)/sessionStart*100, 2) + "% DD");
      return false;
   }

   // Check 2: Max open positions
   int eaPositions = CountEAPositions();
   if(eaPositions >= HARD_STOP_MAX_OPEN_POSITIONS) {
      // Don't disable — just block new entries. Log it.
      AuditLog_Write("POSITION_CAP", "EA positions=" + IntegerToString(eaPositions) +
                     " >= hard cap=" + IntegerToString(HARD_STOP_MAX_OPEN_POSITIONS));
      return false; // block new order only
   }

   // Check 3: Account margin level (broker safety)
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(marginLevel > 0 && marginLevel < 150.0) {
      HardStop_TriggerDisable("MARGIN_LEVEL_CRITICAL: " + DoubleToString(marginLevel,1) + "%");
      return false;
   }

   return true;
}
```

**Implement `HardStop_TriggerDisable(string reason)`:**
- Sets `currentTradingState = STATE_DISABLED`
- Sets `manualBotEnabled = false`
- Writes to `AUDIT_LOG_FILE` with full timestamp + account snapshot
- Sends HIGH-PRIORITY Discord alert
- Calls `SendNotification()` (MT5 push notification)
- Does NOT close positions (that is a separate human decision)

---

### LAYER 1 — Pre-Trade Validation with Hard Bounds Enforcement

Enhance `Phase_Decide()` with `ValidationLayer_Check(AgentContext &ctx)`:

```mql5
bool ValidationLayer_Check(AgentContext &ctx) {
   // Check 1: Lot size absolute ceiling
   if(ctx.proposedLots > HARD_STOP_MAX_LOT_ABSOLUTE) {
      ctx.proposedLots = HARD_STOP_MAX_LOT_ABSOLUTE;
      AuditLog_Write("LOT_CAPPED", "Proposed=" + DoubleToString(ctx.proposedLots,2) +
                     " capped to " + DoubleToString(HARD_STOP_MAX_LOT_ABSOLUTE,2));
   }

   // Check 2: Risk % ceiling
   double riskAmt  = ctx.proposedLots * ctx.proposedSL / symbolInfo.Point() * symbolInfo.TickValue();
   double riskPct  = (AccountInfoDouble(ACCOUNT_BALANCE) > 0) ?
                      riskAmt / AccountInfoDouble(ACCOUNT_BALANCE) * 100.0 : 0;
   if(riskPct > HARD_STOP_MAX_RISK_PCT) {
      ctx.tradingAllowed = false;
      ctx.blockReason    = "RISK_PCT_EXCEEDED: " + DoubleToString(riskPct, 2) + "%";
      AuditLog_Write("RISK_BLOCK", ctx.blockReason);
      return false;
   }

   // Check 3: Spread gate
   double spreadPts = (symbolInfo.Ask() - symbolInfo.Bid()) / symbolInfo.Point();
   if(spreadPts > MaxSpreadPips * 10) {
      ctx.tradingAllowed = false;
      ctx.blockReason    = "SPREAD_GATE: " + DoubleToString(spreadPts,1) + " pts";
      return false;
   }

   // Check 4: SL distance sanity
   double slPts = ctx.proposedSL > 0 ?
      MathAbs(ctx.proposedEntry - ctx.proposedSL) / symbolInfo.Point() : 0;
   double minSLPts = (double)symbolInfo.StopsLevel() * 2.0;
   if(slPts < minSLPts) {
      ctx.tradingAllowed = false;
      ctx.blockReason    = "SL_TOO_CLOSE: " + DoubleToString(slPts,1) + " pts";
      return false;
   }

   return true;
}
```

---

### LAYER 2 — Upgraded Adaptive Circuit Breaker

The existing `AdaptiveCB_Trigger()` is good. Upgrade it with:

1. **Predictive pre-trigger warning** — add `PredictiveCB_Check(AgentContext &ctx)`:
```mql5
void PredictiveCB_Check(AgentContext &ctx) {
   // Calculate rolling VaR-like estimate from last 20 trades
   // If projected loss from current session exceeds 1.5× expected daily risk, issue Yellow Alert
   // Yellow Alert: increase dynamic confidence threshold by 10% (soft brake)
   // Emit to pipelineTrace but do NOT block trading
}
```

2. **DEFENSIVE_MONITORING must actually reduce lots** — add to `Phase_Plan()`:
```mql5
if(currentTradingState == STATE_DEFENSIVE_MONITORING) {
   ctx.proposedLots *= 0.25;  // 75% lot reduction in defensive mode
   ctx.proposedLots  = MathMax(MinLot, NormalizeDouble(
                          MathFloor(ctx.proposedLots / symbolInfo.LotsStep()) *
                          symbolInfo.LotsStep(), 2));
   AuditLog_Write("DEFENSIVE_LOT_REDUCED",
                  "Lots reduced to " + DoubleToString(ctx.proposedLots,2) +
                  " (defensive mode)");
}
```

3. **CB state must survive MT5 restarts** — persist CB state using `GlobalVariableSet`:
```mql5
// On CB trigger: GlobalVariableSet("GHP_CB_PAUSE_UNTIL", (double)cbPauseUntil)
// On OnInit(): cbPauseUntil = (datetime)GlobalVariableGet("GHP_CB_PAUSE_UNTIL")
```

---

### LAYER 3 — Constrained Self-Healing Optimizer (Alignment-Safe)

Replace `SelfHealingOptimizer_Run()` with a version that has an embedded `AlignmentValidator`:

**Implement `AlignmentValidator_Check(string paramName, double proposedValue, double currentValue)`:**
```mql5
bool AlignmentValidator_Check(string paramName, double proposedValue,
                               double currentValue, string &rejectReason) {
   // Rule 1: ATR_SL_Multiplier bounds
   if(paramName == "ATR_SL" &&
      (proposedValue < HARD_STOP_MIN_SL_ATR_MULT || proposedValue > HARD_STOP_MAX_SL_ATR_MULT)) {
      rejectReason = "OUT_OF_BOUNDS: " + DoubleToString(proposedValue,2);
      return false;
   }
   // Rule 2: MinConfidence floor
   if(paramName == "MIN_CONF" && proposedValue < HARD_STOP_MIN_CONFIDENCE) {
      rejectReason = "BELOW_CONF_FLOOR: " + DoubleToString(proposedValue,1);
      return false;
   }
   // Rule 3: Change too large (max 30% delta per optimization cycle)
   double changePct = MathAbs(proposedValue - currentValue) / MathAbs(currentValue) * 100.0;
   if(changePct > 30.0) {
      rejectReason = "CHANGE_TOO_LARGE: " + DoubleToString(changePct,1) + "%";
      return false;
   }
   // Rule 4: Must be backed by minimum observations
   if(optimizer.tradeBatchCount < 25) {
      rejectReason = "INSUFFICIENT_DATA: " + IntegerToString(optimizer.tradeBatchCount) + " trades";
      return false;
   }
   return true;
}
```

**Upgrade `SelfHealingOptimizer_Run()` to actually apply validated changes:**
```mql5
// After finding bestSL, bestTP, bestConf:
string rejectReason;
bool slValid   = AlignmentValidator_Check("ATR_SL",   bestSL,   ATR_SL_Multiplier, rejectReason);
bool tpValid   = AlignmentValidator_Check("ATR_TP",   bestTP,   ATR_TP_Multiplier, rejectReason);
bool confValid = AlignmentValidator_Check("MIN_CONF", bestConf, MinConfidence,      rejectReason);

if(slValid && tpValid && confValid) {
   // Apply via GlobalVariable (persists across restarts, readable by OnInit)
   GlobalVariableSet("GHP_OPT_ATR_SL",   bestSL);
   GlobalVariableSet("GHP_OPT_ATR_TP",   bestTP);
   GlobalVariableSet("GHP_OPT_MIN_CONF", bestConf);
   optimizer.bestSharpe    = bestSharpe;
   optimizer.appliedCount++;
   AuditLog_Write("OPTIMIZER_APPLIED", StringFormat("SL=%.2f TP=%.2f Conf=%.1f Sharpe=%.2f",
                                                     bestSL, bestTP, bestConf, bestSharpe));
} else {
   optimizer.rejectedCount++;
   AuditLog_Write("OPTIMIZER_REJECTED", rejectReason);
   if(optimizer.rejectedCount >= 3) {
      AuditLog_Write("OPTIMIZER_FROZEN", "3 consecutive rejections — human review required");
      SendDiscord("🔒 **OPTIMIZER FROZEN** — 3 consecutive rejections.\nLast reason: " + rejectReason +
                  "\nHuman review required before optimizer resumes.");
      optimizer.frozenUntil = TimeCurrent() + 3600; // freeze for 1 hour
   }
}
```

---

### Audit Trail — `AuditLog_Write(string event, string detail)`

This is the mechanistic interpretability log. Implement it as:
```mql5
void AuditLog_Write(string event, string detail) {
   string line = StringFormat("%s | %s | %s | BAL:%.2f EQ:%.2f DD:%.2f%% POS:%d",
                              TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                              event, detail,
                              AccountInfoDouble(ACCOUNT_BALANCE),
                              AccountInfoDouble(ACCOUNT_EQUITY),
                              peakEquity > 0 ? (peakEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / peakEquity * 100 : 0,
                              CountEAPositions());

   int handle = FileOpen(AUDIT_LOG_FILE, FILE_TXT|FILE_WRITE|FILE_SHARE_READ|FILE_ANSI, '\n');
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWriteString(handle, line + "\n");
      FileClose(handle);
   }

   if(ShowDebugLog) Print("[AUDIT] ", line);
}
```

Audit log events that MUST be written: every HardStop trigger, every CB trigger, every optimizer apply/reject, every VETO from any agent, every lot-size reduction from defensive mode, every order ghost, every consecutive failure batch.

**Constraints:**
- The `HARD_STOP_*` constants must be `#define` not `input` — they cannot appear in the MT5 input panel
- The audit log must be a separate file from the trade log CSV
- `STATE_DISABLED` must check `currentTradingState` on EVERY `OnTick()` entry — not just at entry signal time
- Output the complete upgraded MQ5 file

---PROMPT END---

---

## PHASE 5 PROMPT — Neural Network Inference & Reinforcement Learning Integration

---PROMPT START---

**Role:** You are an expert MQL5 ML engineer implementing lightweight on-device neural network inference and tabular Q-learning in a constrained MetaTrader 5 environment. You are NOT using external Python/TensorFlow — all computation must run inside the MT5 EA in pure MQL5.

**Task:** Activate and complete the partially-implemented learning systems in the attached EA (Phase 4 output). Currently: `UseNeuralNetwork = false` because the inference function does not exist. The Q-table update is basic. Bayesian updates are simplified. Fix all three.

---

### PART A: Feedforward Neural Network — Inference & Online Learning

The `NeuralNetworkLayer` struct exists but has no inference function. Implement the full pipeline:

**10-Input Feature Vector — implement `NN_BuildInputVector(AgentContext &ctx, double &inputs[10])`:**
```mql5
void NN_BuildInputVector(AgentContext &ctx, double &inputs[10]) {
   // All inputs normalized to [-1, +1] using historical min/max or natural bounds
   inputs[0] = (ctx.rsiValue - 50.0) / 50.0;                           // RSI: [0,100] → [-1,+1]
   inputs[1] = (ctx.adxValue - 30.0) / 30.0;                           // ADX centered at 30
   inputs[2] = (ctx.emaFast - ctx.emaSlow) / ctx.atrValue;             // EMA spread in ATR units
   inputs[3] = (ctx.macdMain - ctx.macdSignal) / ctx.atrValue;         // MACD cross in ATR units
   inputs[4] = (iClose(Symbol(), PERIOD_CURRENT, 1) - ctx.bbMiddle) /  // BB position
               ((ctx.bbUpper - ctx.bbLower) / 2.0 + 0.0001);
   inputs[5] = (ctx.stochMain - 50.0) / 50.0;                          // Stoch: [0,100] → [-1,+1]
   inputs[6] = (double)(ctx.marketRegime - 3) / 2.0;                    // Regime: [1,5] → [-1,+1]
   inputs[7] = workingMem.regimeStabilityScore * 2.0 - 1.0;            // Stability → [-1,+1]
   inputs[8] = (ctx.atrValue / (ctx.prevAtrValue + 0.0001)) - 1.0;     // ATR expansion
   inputs[9] = (double)GetSessionBucket() / 3.0 * 2.0 - 1.0;          // Session → [-1,+1]
}
```

**Implement `NN_Forward(double &inputs[10])` → returns confidence score [-1=Strong Sell, +1=Strong Buy]:**
```mql5
double NN_Forward(double &inputs[10]) {
   double hidden[15];
   // Hidden layer: tanh activation
   for(int j = 0; j < 15; j++) {
      double sum = nnLayer.hiddenBias[j];
      for(int i = 0; i < 10; i++)
         sum += inputs[i] * nnLayer.weights[i][j];
      hidden[j] = MathTanh(sum);
   }
   // Output layer: tanh activation (single output neuron)
   double out = nnLayer.outputBias;
   for(int j = 0; j < 15; j++)
      out += hidden[j] * nnLayer.outputWeights[j];
   return MathTanh(out);  // in [-1, +1]
}
```

**Implement `NN_Backprop(double &inputs[10], double target, double learningRate)`** — online learning:
```mql5
// target: +1.0 for profitable trade, -1.0 for loss, 0.0 for breakeven
// Call this in Phase_Reflect() after a trade closes
// Use standard backpropagation: output delta → hidden deltas → weight updates
// Apply gradient clipping: clip delta to [-1.0, +1.0] before weight update
// Apply L2 regularization: weight -= learningRate * (delta + 0.001 * weight)
void NN_Backprop(double &inputs[10], double target, double learningRate);
```

**Integrate NN into `Phase_Orient()`:**
```mql5
if(UseNeuralNetwork) {
   double nnInputs[10];
   NN_BuildInputVector(ctx, nnInputs);
   double nnOutput = NN_Forward(nnInputs);
   // nnOutput in [-1,+1]: contributes as a 6th agent vote
   AgentVote nnVote;
   nnVote.direction   = (nnOutput > 0.1) ? +1 : (nnOutput < -0.1) ? -1 : 0;
   nnVote.confidence  = MathAbs(nnOutput);
   nnVote.weight      = 2.0;  // NN vote weight (adjustable)
   nnVote.reasons     = StringFormat("NN:%.3f", nnOutput);
   nnVote.isVeto      = false;
   // Include in vote aggregation
}
```

**Implement `NN_SaveWeights()` / `NN_LoadWeights()`:**
- Save/load `nnLayer` struct to `GoldHunter_NN_Weights_v8.bin` using `FileWriteStruct` / `FileReadStruct`
- Call `NN_SaveWeights()` every 50 trades and on `OnDeinit()`
- Call `NN_LoadWeights()` on `OnInit()` — if file missing, initialize weights with Xavier initialization: `weight = RandomNormal(0, sqrt(2.0 / 10))`

**Implement `Xavier_InitWeights()`:**
```mql5
void Xavier_InitWeights() {
   double std_hidden = MathSqrt(2.0 / 10.0);  // 10 inputs
   double std_output = MathSqrt(2.0 / 15.0);  // 15 hidden
   for(int i = 0; i < 10; i++)
      for(int j = 0; j < 15; j++)
         nnLayer.weights[i][j] = RandomGaussian(0, std_hidden);
   for(int j = 0; j < 15; j++) {
      nnLayer.hiddenBias[j]    = 0.0;
      nnLayer.outputWeights[j] = RandomGaussian(0, std_output);
   }
   nnLayer.outputBias = 0.0;
}
// Implement RandomGaussian using Box-Muller transform with MathRand()
```

---

### PART B: Q-Learning — Upgrade to Full Bellman Update with Eligibility Traces

Current Q-learning in `OnTradeTransaction` uses a basic update. Upgrade to **Q(λ) — Q-learning with eligibility traces** for faster policy convergence:

**Add to `QTableEntry` struct:**
```mql5
struct QTableEntry {
   double qValues[3];    // 0=Buy, 1=Sell, 2=Hold
   double eligibility[3]; // eligibility traces (λ-weighted)
   int    visitCount;
   datetime lastUpdate;
   double avgReward;     // rolling average reward for this state
};
```

**Implement `QLearning_UpdateWithTrace(int stateKey, int action, double reward, int nextStateKey)`:**
```mql5
void QLearning_UpdateWithTrace(int stateKey, int action, double reward, int nextStateKey) {
   // Standard Q(λ) update:
   // 1. Compute TD error: δ = reward + γ * max(Q[s']) - Q[s,a]
   // 2. Increment eligibility: e[s,a] += 1
   // 3. For ALL states in table: Q[s,a] += α * δ * e[s,a]; e[s,a] *= γλ
   // Use γ = Q_DISCOUNT_FACTOR, λ = 0.7, α = Q_LEARNING_RATE
   // Decay eligibility traces that are < 0.01 to 0 (sparsity)
}
```

**Integrate QL action selection into `Phase_Orient()`:**
```mql5
if(UseReinforcementLearning) {
   int stateKey = QState_Encode(ctx);
   int qlAction = QLearning_SelectAction(stateKey);  // ε-greedy
   // qlAction overrides proposed direction if QL confidence > threshold
   // QL contribution is weighted alongside agent votes
   double qlConfidence = MathMax(qTable[stateKey].qValues) - MathMin(qTable[stateKey].qValues);
   // Add as agent vote with weight proportional to visit count (more visits = more trust)
   double qlWeight = MathMin(3.0, qTable[stateKey].visitCount / 20.0);
   // ... add to vote aggregation
}
```

---

### PART C: Phase_Reflect() — Complete Implementation

```mql5
void Phase_Reflect(AgentContext &ctx) {
   // This runs every tick (not just on trades) for continuous learning

   // 1. Update working memory ring buffers
   WorkingMemory_Update(ctx);

   // 2. NN inference on current state (even if no trade placed)
   //    Track prediction accuracy in a rolling buffer

   // 3. If a trade just closed (check OnTradeTransaction flag):
   //    a. Compute reward = profit / (atrAtEntry * lotsUsed) — normalized
   //    b. Call QLearning_UpdateWithTrace()
   //    c. Call Bayes_UpdatePosterior()
   //    d. Call NN_Backprop() with target = sign(profit)
   //    e. Complete the TradeRecordV8 entry with exit fields
   //    f. Call EpisodicMemory_Persist()

   // 4. Every 50 trades: call SelfHealingOptimizer_Run()
   // 5. Every 50 trades: call NN_SaveWeights() + QTable_Save()
   // 6. Every 100 trades: call Bayes state persistence
}
```

**Add a `reflectPending` flag** — set to `true` in `OnTradeTransaction` when a closing deal is processed. `Phase_Reflect()` checks this flag to trigger the learning update. Reset after processing.

**Implement `RandomGaussian(double mean, double stddev)`** using Box-Muller:
```mql5
double RandomGaussian(double mean, double stddev) {
   double u1 = (MathRand() + 1.0) / (32768.0 + 1.0);
   double u2 = (MathRand() + 1.0) / (32768.0 + 1.0);
   double z  = MathSqrt(-2.0 * MathLog(u1)) * MathCos(2.0 * M_PI * u2);
   return mean + stddev * z;
}
```

**Constraints:**
- `UseNeuralNetwork = true` should now be a functional flag — inference + backprop must execute without errors
- NN weights file must be validated on load (check array dimensions, check for NaN/Inf values)
- Q(λ) trace decay must not cause memory leaks — entries with eligibility < 0.001 must be zeroed
- The full Phase_Reflect() must complete within 5ms on average (profile with `GetMicrosecondCount()` and log if exceeded)
- Output the **complete, final, compilable** MQ5 file ready for MetaEditor 5

---PROMPT END---

---

## PHASE 5b PROMPT — Final Integration Test & Dashboard Upgrade (Optional)

---PROMPT START---

**Role:** You are a senior MQL5 QA engineer and dashboard designer. Your job is to perform a final integration pass on the attached complete EA (Phase 5 output) and upgrade the visual dashboard to expose AGI v8's new internal state.

**Tasks:**

**1. Compilation Audit — fix these known risk areas:**
- Scan for any `ArrayResize()` inside `OnTick()` without bounds checking — replace with pre-allocated ring buffer patterns
- Scan for any `FileOpen()` without matching `FileClose()` in all code paths (especially on early return)
- Verify all `AgentContext` struct usages pass by reference (`&ctx`) not by value (performance)
- Verify `pipelineTrace[]` string array is never written beyond its declared size
- Remove any `#define` that shadows an `input` variable

**2. Upgrade the Dashboard** to show AGI v8 state. Add these rows to the existing panel (use existing `ObjectCreate` / `ObjectSetString` pattern):

```
Row: "AGENT VOTES"     → "B:X S:Y Vetos:Z | Conf: XX%"
Row: "MEMORY"          → "Regime Stability: X% | Session Wins/Losses: W/L"
Row: "LEARNING"        → "Q-State: XXXX | NN Output: +0.XX | Bayes Best: SWING"
Row: "OPTIMIZER"       → "Applied: N | Rejected: N | Frozen: YES/NO"
Row: "AUDIT EVENTS"    → "Last: [event] at [time]"
Row: "PIPELINE TRACE"  → Last 3 trace entries scrolling
```

**3. Discord Report Upgrade** — add AGI-specific fields to `SendDiscordExtendedReport()`:
```
🧠 **AGI COGNITIVE STATE**
  Q-Table: `XXX states learned` | NN Backprop: `XXX updates`
  Bayes Best Strategy: `SWING (73% win posterior)`
  Optimizer: `Applied ×N` | `Rejected ×N` | Frozen: `NO`
  Regime Stability: `82%` (last 20 bars)
  Last Audit Event: `[event] @ [time]`
```

**4. OnDeinit cleanup** — ensure all of these are called on EA removal:
```mql5
NN_SaveWeights();
QTable_Save();
EpisodicMemory_Persist_Flush();  // write any buffered records
AuditLog_Write("DEINIT", "EA removed. Reason: " + IntegerToString(reason));
// Release all indicator handles
IndicatorRelease(handleEMAFast); // ... all handles
// Remove all chart objects
ObjectsDeleteAll(ChartID(), "GHP_");
```

**Output:** Final complete, clean, compilable `GoldHunter_v8_Final.mq5`

---PROMPT END---

---

# APPENDIX: Quick Reference — Architecture Mapping

| AI Research Concept | Engineering Pattern Used | Location in v8 |
|---|---|---|
| **Agentic Reasoning Loop** | OODA cycle as formal DAG (Phase 1) | `AgentLoop()` / 6 `Phase_X()` functions |
| **Working Memory** | `SessionWorkingMemory` ring buffer struct | Phase 2 — rebuilt every tick |
| **Episodic Memory** | `TradeRecordV8` CSV + Q-table persistence | Phase 2 — file-backed, survives restarts |
| **Long-term Policy** | Q(λ) table + Bayesian posterior + NN weights | Phase 5 — updated after every trade |
| **Multi-Agent Coordination** | 5 specialist agent vote aggregation | Phase 3 — `VoteAggregator_Run()` |
| **Tool Integration** | `OrderExecutionDAG` (5-node validation pipeline) | Phase 3 — `OrderExecutionDAG_Run()` |
| **Mechanistic Interpretability** | `PipelineTrace[]` + `AuditLog_Write()` | Phases 1 & 4 — every decision has a trace |
| **ASI Hard Alignment** | `HARD_STOP_*` constitutional `#define` constants | Phase 4 — immutable, cannot be input params |
| **Predictive Safety** | `PredictiveCB_Check()` + `ValidationLayer_Check()` | Phase 4 — pre-trade, every tick |
| **Recursive Self-Improvement** | `SelfHealingOptimizer` + `AlignmentValidator` gate | Phase 4 — optimizer bounded by hard rules |
| **Online Neural Learning** | Backprop in `Phase_Reflect()`, Xavier init | Phase 5 — live weight updates after trades |

---

*Document generated for GoldHunter UHF AGI v7 → v8 upgrade. Architecture and prompts authored based on full code analysis of the 3,049-line source file and current agentic AI paradigms.*
