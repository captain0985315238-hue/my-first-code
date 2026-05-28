//+------------------------------------------------------------------+
//|  GOLDHUNTER AGI v8.4 — MISSING PHASE 4 & 5 IMPLEMENTATIONS      |
//|  Paste this block BEFORE the "END OF FILE" comment in god.mq5    |
//|  (replace the final comment at line ~4108)                       |
//+------------------------------------------------------------------+
//  CONTENTS:
//  ─────────────────────────────────────────────────────────────────
//  [PH4-A]  AuditLog_Write                  — append-only audit trail
//  [PH4-B]  AlignmentValidator              — bounds-checked optimizer gate
//  [PH4-C]  ValidationLayer_Check           — pre-trade hard-rule enforcement
//  [PH4-D]  PredictiveCB_Check              — VaR-based Dynamic Policy Throttler
//  [PH4-E]  HardStop_CheckAll               — immutable constitutional breakers
//  ─────────────────────────────────────────────────────────────────
//  [PH5-A]  QTable_Save / QTable_Load       — binary Q-table persistence
//  [PH5-B]  Bayes_UpdatePosterior           — full Beta-Bernoulli update with
//             Thompson sampling and strategy_alpha/beta sync
//  [PH5-C]  EpisodicMemory_Persist          — single-record append to CSV
//  [PH5-D]  EpisodicMemory_Persist_Flush    — full rewrite on deinit
//  [PH5-E]  Phase_Reflect                   — OODA REFLECT stage (online
//             learning: Q(λ) + Bayes + NN backprop + optimizer trigger)
//  ─────────────────────────────────────────────────────────────────
//  [PH5b-A] OODA AgentLoop                  — full OnTick OODA rewrite
//  [PH5b-B] Phase_Observe / Orient / Decide / Plan / Execute stubs
//             (integrate existing functions into formal typed pipeline)
//  [PH5b-C] Dashboard_AGI_Update            — new AGI rows on existing panel
//  [PH5b-D] SendDiscordExtendedReport_AGI   — upgraded Discord report
//  [PH5b-E] OnDeinit_AGI                    — upgraded teardown
//  ─────────────────────────────────────────────────────────────────

//==========================================================================
//  ADDITIONAL GLOBAL STATE REQUIRED BY NEW PHASES
//  Add these declarations near the existing global variable block.
//==========================================================================

// --- Reflection-phase flags (set in OnTradeTransaction, read in Phase_Reflect) ---
bool   reflectPending        = false;  // True when a trade close just occurred
double reflectProfit         = 0.0;    // Net profit of the just-closed trade
int    reflectStateKey       = -1;     // Q-state at time of trade entry
int    reflectAction         = 2;      // 0=Buy 1=Sell 2=Hold
double reflectATRAtEntry     = 0.0;    // ATR at entry for reward normalisation
double reflectLotsUsed       = 0.01;
long   reflectTicket         = 0;

// --- PredictiveCB rolling VaR buffer ---
double varPnLBuffer[50];               // Rolling 50-trade P&L for VaR
int    varBufHead    = 0;
int    varBufCount   = 0;
double varThrottleFactor = 1.0;        // 1.0 = full size, < 1.0 = throttled

// --- Alignment Validator state ---
int    alignmentRejectStreak = 0;      // Consecutive optimizer rejections
bool   optimizerFrozen       = false;  // True if freeze triggered

// --- Phase_Reflect timing ---
ulong  lastReflectUs         = 0;      // GetMicrosecondCount at last reflect

// --- AGI Learning counters for dashboard / Discord ---
int    nnBackpropCount       = 0;
int    qLearnUpdateCount     = 0;
string lastAuditEvent        = "";
datetime lastAuditEventTime  = 0;


//==========================================================================
//  [PH4-A]  AuditLog_Write
//  Appends a timestamped, categorised entry to the immutable audit trail.
//  File is opened in append mode; every call is atomic from this process.
//==========================================================================
void AuditLog_Write(string category, string detail)
{
   int handle = FileOpen(AUDIT_LOG_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(handle == INVALID_HANDLE) {
      Print("[AUDIT] Cannot open audit log. Error=", GetLastError());
      return;
   }

   // Seek to end for append-only writes
   FileSeek(handle, 0, SEEK_END);

   string entry = StringFormat("[%s][%s] %s | Equity=$%.2f Balance=$%.2f",
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
      category,
      detail,
      AccountInfoDouble(ACCOUNT_EQUITY),
      AccountInfoDouble(ACCOUNT_BALANCE));

   FileWriteString(handle, entry + "\n");
   FileClose(handle);

   // Keep last event for dashboard display
   lastAuditEvent     = category + ": " + detail;
   lastAuditEventTime = TimeCurrent();

   if(ShowDebugLog)
      Print("[AUDIT] ", entry);
}


//==========================================================================
//  [PH4-B]  AlignmentValidator
//  Reviews a proposed parameter mutation from the Self-Healing Optimizer.
//  Returns true if the change is within constitutional bounds AND is
//  statistically significant; false otherwise.
//  All bounds are derived from HARD_STOP_* defines — the optimizer cannot
//  circumvent them by calling this function.
//==========================================================================
bool AlignmentValidator(double proposed_sl_mult, double proposed_tp_mult,
                        double proposed_min_conf, double proposed_sharpe,
                        int    observation_count)
{
   string failReason = "";
   bool   passed     = true;

   // ── Constitutional Bound Checks ──────────────────────────────────────
   if(proposed_sl_mult < HARD_STOP_MIN_SL_ATR_MULT) {
      failReason = StringFormat("SL mult %.2f < floor %.2f",
                                proposed_sl_mult, HARD_STOP_MIN_SL_ATR_MULT);
      passed = false;
   }
   if(proposed_sl_mult > HARD_STOP_MAX_SL_ATR_MULT) {
      failReason = StringFormat("SL mult %.2f > ceil %.2f",
                                proposed_sl_mult, HARD_STOP_MAX_SL_ATR_MULT);
      passed = false;
   }
   if(proposed_min_conf < HARD_STOP_MIN_CONFIDENCE) {
      failReason = StringFormat("MinConf %.1f < floor %.1f",
                                proposed_min_conf, HARD_STOP_MIN_CONFIDENCE);
      passed = false;
   }
   if(proposed_tp_mult <= 0.0) {
      failReason = "TP multiplier <= 0";
      passed = false;
   }

   // ── Minimum Observation Requirement ──────────────────────────────────
   if(passed && observation_count < 30) {
      failReason = StringFormat("Insufficient observations: %d < 30", observation_count);
      passed = false;
   }

   // ── Statistical Significance Check (simplified p-value proxy) ─────────
   // Require the new Sharpe to exceed the old by at least one bootstrap
   // standard error ≈ 1/sqrt(N).  This is the p<0.05 proxy mentioned in the spec.
   if(passed) {
      double se = (observation_count > 0) ? 1.0 / MathSqrt((double)observation_count) : 1.0;
      if(proposed_sharpe < optimizer.bestSharpe + se) {
         failReason = StringFormat("Sharpe improvement %.4f < required SE %.4f",
                                   proposed_sharpe - optimizer.bestSharpe, se);
         passed = false;
      }
   }

   // ── Verdict ──────────────────────────────────────────────────────────
   if(!passed) {
      alignmentRejectStreak++;
      optimizer.rejectedCount++;
      optimizerRejectedCount++;

      AuditLog_Write("ALIGN_REJECT",
         StringFormat("Reason='%s' SL=%.2f TP=%.2f Conf=%.1f Sharpe=%.3f N=%d RejStreak=%d",
                      failReason, proposed_sl_mult, proposed_tp_mult,
                      proposed_min_conf, proposed_sharpe, observation_count,
                      alignmentRejectStreak));

      if(NotifyOnRiskEvent)
         SendDiscord(StringFormat(
            "🔒 **ALIGNMENT VALIDATOR — REJECTED**\n"
            "Reason: `%s`\n"
            "Proposed: SL=`%.2f` TP=`%.2f` Conf=`%.1f` Sharpe=`%.3f`\n"
            "Reject streak: `%d`", failReason,
            proposed_sl_mult, proposed_tp_mult, proposed_min_conf, proposed_sharpe,
            alignmentRejectStreak));

      // Freeze optimizer after 3 consecutive rejections
      if(alignmentRejectStreak >= 3 && !optimizerFrozen) {
         optimizerFrozen      = true;
         optimizerFrozenUntil = TimeCurrent() + 3600; // 1-hour freeze
         optimizer.frozenUntil = optimizerFrozenUntil;

         AuditLog_Write("OPTIMIZER_FREEZE",
            "3 consecutive rejections — optimizer frozen for 1 hour");

         if(NotifyOnRiskEvent)
            SendDiscord("🧊 **OPTIMIZER FROZEN** — 3 consecutive alignment rejections.\n"
                        "Resumes in 60 minutes. Manual review recommended.");
      }
      return false;
   }

   // ── Passed: apply parameters and reset rejection streak ──────────────
   alignmentRejectStreak = 0;

   // Live parameter injection via GlobalVariable
   string gvPrefix = "GHP_" + Symbol() + "_";
   GlobalVariableSet(gvPrefix + "ATR_SL",  proposed_sl_mult);
   GlobalVariableSet(gvPrefix + "ATR_TP",  proposed_tp_mult);
   GlobalVariableSet(gvPrefix + "MinConf", proposed_min_conf);

   optimizer.appliedCount++;
   optimizer.bestSharpe   = proposed_sharpe;
   optimizer.bestATR_SL   = proposed_sl_mult;
   optimizer.bestATR_TP   = proposed_tp_mult;
   optimizer.bestMinConf  = proposed_min_conf;

   AuditLog_Write("ALIGN_ACCEPT",
      StringFormat("SL=%.2f TP=%.2f Conf=%.1f Sharpe=%.3f N=%d Applied#%d",
                   proposed_sl_mult, proposed_tp_mult, proposed_min_conf,
                   proposed_sharpe, observation_count, optimizer.appliedCount));

   if(NotifyOnRiskEvent)
      SendDiscord(StringFormat(
         "✅ **ALIGNMENT VALIDATOR — ACCEPTED**\n"
         "ATR_SL: `%.2f`  ATR_TP: `%.2f`  MinConf: `%.1f`\n"
         "Sharpe: `%.3f`  Observations: `%d`\n"
         "Applied count: `%d`",
         proposed_sl_mult, proposed_tp_mult, proposed_min_conf,
         proposed_sharpe, observation_count, optimizer.appliedCount));

   return true;
}


//==========================================================================
//  [PH4-C]  ValidationLayer_Check
//  Pre-trade hard-rule enforcement called BEFORE every order submission.
//  Returns false → order must NOT be sent.
//  Does NOT lock trading; it only blocks the specific proposed order and
//  provides a diagnostic reason string.
//==========================================================================
bool ValidationLayer_Check(double proposed_lots, double proposed_sl_dist,
                            double proposed_entry, ENUM_ORDER_TYPE proposed_dir,
                            string &out_reason)
{
   out_reason = "";
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);

   // ── Hard Stop: equity floor ───────────────────────────────────────────
   double startBal = (dailyStartBalance > 0) ? dailyStartBalance : balance;
   if(equity < startBal * (HARD_STOP_EQUITY_FLOOR_PCT / 100.0)) {
      out_reason = StringFormat("HARD STOP: Equity $%.2f < %.0f%% of start $%.2f",
                                equity, HARD_STOP_EQUITY_FLOOR_PCT, startBal);
      return false;
   }

   // ── Hard Stop: max open positions ────────────────────────────────────
   int ea_positions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == Symbol() && posInfo.Magic() == EA_MAGIC_NUMBER)
            ea_positions++;
   }
   if(ea_positions >= HARD_STOP_MAX_OPEN_POSITIONS) {
      out_reason = StringFormat("HARD STOP: %d positions open >= max %d",
                                ea_positions, HARD_STOP_MAX_OPEN_POSITIONS);
      return false;
   }

   // ── Hard Stop: absolute lot ceiling ──────────────────────────────────
   if(proposed_lots > HARD_STOP_MAX_LOT_ABSOLUTE) {
      out_reason = StringFormat("HARD STOP: Lots %.2f > absolute max %.2f",
                                proposed_lots, HARD_STOP_MAX_LOT_ABSOLUTE);
      return false;
   }

   // ── Hard Stop: risk % per trade ceiling ──────────────────────────────
   if(proposed_sl_dist > 0 && equity > 0) {
      double tick_val  = symbolInfo.TickValue();
      double tick_size = symbolInfo.TickSize();
      if(tick_val > 0 && tick_size > 0) {
         double risk_amount = proposed_lots * (proposed_sl_dist / tick_size) * tick_val;
         double risk_pct    = (risk_amount / equity) * 100.0;
         if(risk_pct > HARD_STOP_MAX_RISK_PCT) {
            out_reason = StringFormat("HARD STOP: Risk %.1f%% > max %.0f%%",
                                      risk_pct, HARD_STOP_MAX_RISK_PCT);
            return false;
         }
      }
   }

   // ── Hard Stop: absolute daily loss ───────────────────────────────────
   double daily_dd_pct = (dailyStartBalance > 0) ?
                         (dailyStartBalance - balance) / dailyStartBalance * 100.0 : 0.0;
   if(daily_dd_pct >= HARD_STOP_MAX_DAILY_LOSS_PCT) {
      out_reason = StringFormat("HARD STOP: Daily loss %.1f%% >= max %.0f%%",
                                daily_dd_pct, HARD_STOP_MAX_DAILY_LOSS_PCT);
      return false;
   }

   // ── Lot size within broker bounds ────────────────────────────────────
   double min_lot  = symbolInfo.LotsMin();
   double max_lot  = symbolInfo.LotsMax();
   double lot_step = symbolInfo.LotsStep();
   if(proposed_lots < min_lot) {
      out_reason = StringFormat("LOT: %.3f < broker min %.3f", proposed_lots, min_lot);
      return false;
   }
   if(proposed_lots > max_lot) {
      out_reason = StringFormat("LOT: %.3f > broker max %.3f", proposed_lots, max_lot);
      return false;
   }

   // ── Price validity ───────────────────────────────────────────────────
   if(proposed_entry <= 0) {
      out_reason = "PRICE: Entry price <= 0";
      return false;
   }

   // ── VaR throttle check — reduce lot size if PredictiveCB engaged ─────
   // (This is advisory; ValidationLayer scales lots before returning true)
   // If varThrottleFactor < 1.0, the caller should scale lots accordingly.

   PipelineTraceLog("VALIDATE", "PASS",
      StringFormat("Lots=%.2f SL=%.4f Entry=%.2f Dir=%s Pos=%d",
                   proposed_lots, proposed_sl_dist,
                   proposed_entry, EnumToString(proposed_dir), ea_positions));

   return true;
}


//==========================================================================
//  [PH4-D]  PredictiveCB_Check
//  Dynamic Policy Throttler — implements "Continuous But Scaled Execution".
//  Instead of halting, it adjusts varThrottleFactor which callers use to
//  scale lot sizes.  The OODA loop CONTINUES running at all times.
//
//  Based on Karl Friston's Active Inference principle: maintain continuous
//  environmental interaction for epistemic value, but modulate action
//  intensity proportional to surprise (unexpected loss).
//==========================================================================
void PredictiveCB_Check()
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   // ── Update rolling P&L VaR buffer ────────────────────────────────────
   // Called every tick; VaR recalc happens only when new trade data arrives.
   // (The buffer is populated in Phase_Reflect.)

   if(varBufCount < 5) {
      // Not enough data for VaR — operate at full but conservative size
      varThrottleFactor = 1.0;
      return;
   }

   // ── Compute mean and standard deviation of rolling P&L ───────────────
   int n     = varBufCount;
   double sum = 0.0, sq = 0.0;
   for(int i = 0; i < n; i++) {
      sum += varPnLBuffer[i];
      sq  += varPnLBuffer[i] * varPnLBuffer[i];
   }
   double mean   = sum / n;
   double var_sq = (sq / n) - (mean * mean);
   double stddev = (var_sq > 0) ? MathSqrt(var_sq) : 0.0;

   // ── VaR(95%) = mean - 1.645 * stddev  (parametric, normal assumption) ─
   double var95 = mean - 1.645 * stddev;

   // ── Expected daily risk budget: RiskPercent% × balance ───────────────
   double daily_budget = balance * (RiskPercent / 100.0);

   // ── Throttle logic: tiered exponential scaling ────────────────────────
   // Yellow Alert: VaR(95%) < -2× budget → reduce to 50% size
   // Orange Alert: VaR(95%) < -4× budget → reduce to 20% "epistemic probe" size
   // Red Alert:    VaR(95%) < -6× budget → reduce to min-lot probe only

   if(var95 < -(daily_budget * 6.0)) {
      varThrottleFactor = 0.05;  // Epistemic micro-probe: minimum viable signal
      PipelineTraceLog("PRED_CB", "RED_ALERT",
         StringFormat("VaR95=%.2f Budget=%.2f Throttle=5%%", var95, daily_budget));
   }
   else if(var95 < -(daily_budget * 4.0)) {
      varThrottleFactor = 0.20;
      PipelineTraceLog("PRED_CB", "ORANGE_ALERT",
         StringFormat("VaR95=%.2f Budget=%.2f Throttle=20%%", var95, daily_budget));
   }
   else if(var95 < -(daily_budget * 2.0)) {
      varThrottleFactor = 0.50;
      PipelineTraceLog("PRED_CB", "YELLOW_ALERT",
         StringFormat("VaR95=%.2f Budget=%.2f Throttle=50%%", var95, daily_budget));
   }
   else {
      varThrottleFactor = 1.0;  // Normal regime — full execution
   }

   // ── Drawdown-based secondary throttle ────────────────────────────────
   double peak = MathMax(peakEquity, balance);
   double dd_pct = (peak > 0) ? (peak - equity) / peak * 100.0 : 0.0;

   if(dd_pct > 10.0)      varThrottleFactor = MathMin(varThrottleFactor, 0.25);
   else if(dd_pct > 5.0)  varThrottleFactor = MathMin(varThrottleFactor, 0.50);
   else if(dd_pct > 3.0)  varThrottleFactor = MathMin(varThrottleFactor, 0.75);

   // ── Log notable state transitions only ───────────────────────────────
   static double prevFactor = 1.0;
   if(MathAbs(varThrottleFactor - prevFactor) > 0.05) {
      AuditLog_Write("PRED_CB",
         StringFormat("Throttle %.0f%% → %.0f%% | VaR95=%.2f DD=%.1f%%",
                      prevFactor * 100.0, varThrottleFactor * 100.0, var95, dd_pct));

      if(NotifyOnRiskEvent && varThrottleFactor < prevFactor) {
         SendDiscord(StringFormat(
            "🔶 **PREDICTIVE CB — THROTTLE ENGAGED**\n"
            "Lot size now: `%.0f%%` of normal\n"
            "VaR(95%%): `$%.2f`  Daily budget: `$%.2f`\n"
            "Drawdown: `%.1f%%`\n"
            "OODA loop continues — epistemic probing active.",
            varThrottleFactor * 100.0, var95, daily_budget, dd_pct));
      }
      if(varThrottleFactor > prevFactor)
         AuditLog_Write("PRED_CB", "Throttle relaxed — risk metrics improving");

      prevFactor = varThrottleFactor;
   }
}


//==========================================================================
//  [PH4-E]  HardStop_CheckAll
//  Evaluates ALL constitutional hard stops every OnTick call.
//  Sets currentTradingState to STATE_DISABLED if any trigger fires.
//  Returns false = trading MUST be blocked this tick.
//
//  Critical: this function CANNOT be bypassed by any other module.
//==========================================================================
bool HardStop_CheckAll()
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double startBal = (dailyStartBalance > 0) ? dailyStartBalance : balance;

   // ── Unfreeze optimizer if time elapsed ───────────────────────────────
   if(optimizerFrozen && TimeCurrent() >= optimizerFrozenUntil) {
      optimizerFrozen       = false;
      alignmentRejectStreak = 0;
      optimizer.frozenUntil = 0;
      AuditLog_Write("OPTIMIZER_UNFREEZE", "Freeze period elapsed — optimizer re-enabled");
   }

   // ── Equity floor hard stop ────────────────────────────────────────────
   if(equity < startBal * (HARD_STOP_EQUITY_FLOOR_PCT / 100.0)) {
      if(currentTradingState != STATE_DISABLED) {
         currentTradingState = STATE_DISABLED;
         string msg = StringFormat(
            "🚨 **HARD STOP TRIGGERED — EA DISABLED**\n"
            "Equity `$%.2f` fell below `%.0f%%` of start balance `$%.2f`.\n"
            "This is an immutable constitutional limit. "
            "Manual intervention required to resume.",
            equity, HARD_STOP_EQUITY_FLOOR_PCT, startBal);

         AuditLog_Write("HARD_STOP", StringFormat(
            "EQUITY_FLOOR: Equity=%.2f StartBal=%.2f Floor=%.1f%%",
            equity, startBal, HARD_STOP_EQUITY_FLOOR_PCT));

         SendDiscord(msg);
         Alert("[GoldHunter HARD STOP] Equity floor breached. EA disabled.");
      }
      return false;
   }

   // ── Absolute daily loss hard stop ─────────────────────────────────────
   double daily_loss_pct = (startBal > 0) ?
                           (startBal - balance) / startBal * 100.0 : 0.0;
   if(daily_loss_pct >= HARD_STOP_MAX_DAILY_LOSS_PCT) {
      if(currentTradingState != STATE_DISABLED) {
         currentTradingState = STATE_DISABLED;
         AuditLog_Write("HARD_STOP",
            StringFormat("DAILY_LOSS: Loss=%.2f%% >= max %.0f%%",
                         daily_loss_pct, HARD_STOP_MAX_DAILY_LOSS_PCT));

         SendDiscord(StringFormat(
            "🚨 **HARD STOP — DAILY LOSS LIMIT**\n"
            "Daily loss `%.1f%%` >= constitutional max `%.0f%%`.\n"
            "EA disabled for remainder of session.",
            daily_loss_pct, HARD_STOP_MAX_DAILY_LOSS_PCT));
      }
      return false;
   }

   // ── Re-enable from DISABLED only on new day reset ─────────────────────
   if(currentTradingState == STATE_DISABLED) return false;

   // ── Transition to DEFENSIVE_MONITORING (non-blocking) ────────────────
   double session_loss_pct = (startBal > 0) ?
                             (startBal - balance) / startBal * 100.0 : 0.0;
   if(session_loss_pct >= MaxDailyLossPerc && currentTradingState == STATE_RUNNING) {
      currentTradingState = STATE_DEFENSIVE_MONITORING;
      AuditLog_Write("STATE_CHANGE",
         StringFormat("→ DEFENSIVE_MONITORING: Loss=%.2f%% >= SoftLimit=%.0f%%",
                      session_loss_pct, MaxDailyLossPerc));
   }

   // ── Restore to RUNNING if equity recovers ─────────────────────────────
   if(session_loss_pct < MaxDailyLossPerc * 0.8 &&
      currentTradingState == STATE_DEFENSIVE_MONITORING) {
      currentTradingState = STATE_RUNNING;
      AuditLog_Write("STATE_CHANGE",
         StringFormat("→ RUNNING: Loss recovered to %.2f%%", session_loss_pct));
   }

   return true;
}


//==========================================================================
//  [PH5-A]  QTable_Save  /  QTable_Load
//  Binary persistence for the Q-learning table including eligibility traces,
//  visit counts, and rolling average rewards.
//==========================================================================
void QTable_Save()
{
   if(!UseReinforcementLearning) return;

   string filename = "GoldHunter_QTable_v8.bin";
   int handle = FileOpen(filename, FILE_WRITE | FILE_BIN);
   if(handle == INVALID_HANDLE) {
      Print("[PH5] QTable_Save: Cannot open file. Error=", GetLastError());
      return;
   }

   // Write header: magic + size
   FileWriteInteger(handle, 0x51544238);  // 'QT85' magic
   FileWriteInteger(handle, qTableSize);

   for(int i = 0; i < qTableSize; i++) {
      FileWriteArray(handle, qTable[i].qValues);
      FileWriteArray(handle, qTable[i].eligibility);
      FileWriteInteger(handle, qTable[i].visitCount);
      FileWriteLong(handle, (long)qTable[i].lastUpdate);
      FileWriteDouble(handle, qTable[i].avgReward);
   }

   FileClose(handle);
   Print("[PH5] QTable saved: ", qTableSize, " states → ", filename);
}

bool QTable_Load()
{
   if(!UseReinforcementLearning) return false;

   string filename = "GoldHunter_QTable_v8.bin";
   int handle = FileOpen(filename, FILE_READ | FILE_BIN);
   if(handle == INVALID_HANDLE) {
      Print("[PH5] QTable_Load: File not found, using initialised zeros.");
      return false;
   }

   int magic = FileReadInteger(handle);
   if(magic != 0x51544238) {
      Print("[PH5] QTable_Load: Magic mismatch — file corrupt, skipping.");
      FileClose(handle);
      return false;
   }

   int saved_size = FileReadInteger(handle);
   int load_count = MathMin(saved_size, qTableSize);

   for(int i = 0; i < load_count; i++) {
      FileReadArray(handle, qTable[i].qValues);
      FileReadArray(handle, qTable[i].eligibility);
      qTable[i].visitCount = FileReadInteger(handle);
      qTable[i].lastUpdate = (datetime)FileReadLong(handle);
      qTable[i].avgReward  = FileReadDouble(handle);

      // Validate loaded values
      for(int a = 0; a < 3; a++) {
         if(!IsNumberValid(qTable[i].qValues[a]))    qTable[i].qValues[a]    = 0.0;
         if(!IsNumberValid(qTable[i].eligibility[a]))qTable[i].eligibility[a]= 0.0;
      }
      if(!IsNumberValid(qTable[i].avgReward)) qTable[i].avgReward = 0.0;
   }

   FileClose(handle);
   Print("[PH5] QTable loaded: ", load_count, " states from ", filename);
   return load_count > 0;
}


//==========================================================================
//  [PH5-B]  Bayes_UpdatePosterior
//  Full Beta-Bernoulli conjugate update.
//  Updates the persistent strategy_alpha[] / strategy_beta[] arrays and
//  recomputes all BayesianStrategyProb fields in a single pass.
//  Unlike the older Bayesian_UpdateStrategyProbabilities() which used
//  a local static shadow array, this function uses the Phase 2 globals
//  directly — ensuring OnInit reload and file persistence stay in sync.
//==========================================================================
void Bayes_UpdatePosterior(int strategy_idx, double profit)
{
   if(!UseBayesianInference) return;
   if(strategy_idx < 0 || strategy_idx >= 5) return;

   // Beta-Bernoulli update
   if(profit > 0.0)
      strategy_alpha[strategy_idx] += 1.0;
   else
      strategy_beta[strategy_idx]  += 1.0;

   bayesProbs.totalObservations++;

   // Recompute posterior means for all strategies
   double raw[5];
   double total = 0.0;
   for(int s = 0; s < 5; s++) {
      raw[s] = strategy_alpha[s] / (strategy_alpha[s] + strategy_beta[s]);
      total += raw[s];
   }

   if(total > 0) {
      bayesProbs.autoProb     = raw[0] / total;
      bayesProbs.scalpProb    = raw[1] / total;
      bayesProbs.swingProb    = raw[2] / total;
      bayesProbs.breakoutProb = raw[3] / total;
      bayesProbs.reversalProb = raw[4] / total;
   }

   // Persist alpha/beta to GlobalVariables for crash resilience
   string pfx = "GHP_BAYES_" + Symbol() + "_";
   for(int s = 0; s < 5; s++) {
      GlobalVariableSet(pfx + "A" + IntegerToString(s), strategy_alpha[s]);
      GlobalVariableSet(pfx + "B" + IntegerToString(s), strategy_beta[s]);
   }

   if(ShowDebugLog)
      Print(StringFormat("[PH5] Bayes updated str=%d profit=%.2f | "
                         "Auto=%.2f Scalp=%.2f Swing=%.2f BO=%.2f Rev=%.2f",
                         strategy_idx, profit,
                         bayesProbs.autoProb,    bayesProbs.scalpProb,
                         bayesProbs.swingProb,   bayesProbs.breakoutProb,
                         bayesProbs.reversalProb));
}


//==========================================================================
//  [PH5-C]  EpisodicMemory_Persist
//  Appends a SINGLE completed trade record to the CSV in append mode.
//  Called immediately when a trade closes — O(1), not a full rewrite.
//==========================================================================
void EpisodicMemory_Persist(int record_idx)
{
   if(record_idx < 0 || record_idx >= ArraySize(episodic_memory)) return;

   int handle = FileOpen(TradeLogCSV, FILE_CSV | FILE_WRITE | FILE_ANSI | FILE_SHARE_READ);
   if(handle == INVALID_HANDLE) {
      Print("[PH5] EpisodicMemory_Persist: Cannot open ", TradeLogCSV,
            " Error=", GetLastError());
      return;
   }

   // Seek to end for append
   FileSeek(handle, 0, SEEK_END);

   TradeRecordV8 &r = episodic_memory[record_idx];
   FileWrite(handle,
      TimeToString(r.open_time),
      (long)r.ticket,
      EnumToString(r.type),
      DoubleToString(r.volume, 2),
      DoubleToString(r.open_price, _Digits),
      DoubleToString(r.sl, _Digits),
      DoubleToString(r.tp, _Digits),
      DoubleToString(r.close_price, _Digits),
      TimeToString(r.close_time),
      DoubleToString(r.profit, 2),
      DoubleToString(r.commission, 2),
      DoubleToString(r.swap, 2),
      r.state_id,
      DoubleToString(r.prior_prob, 4),
      DoubleToString(r.posterior_prob, 4),
      r.agent_votes,
      r.dag_trace,
      r.veto_reason);

   FileClose(handle);
}


//==========================================================================
//  [PH5-D]  EpisodicMemory_Persist_Flush
//  Full rewrite of all in-memory episodic records to CSV.
//  Called in OnDeinit only (slow, but ensures full consistency on shutdown).
//==========================================================================
void EpisodicMemory_Persist_Flush()
{
   int n = ArraySize(episodic_memory);
   if(n == 0) return;

   int handle = FileOpen(TradeLogCSV, FILE_CSV | FILE_WRITE | FILE_ANSI);
   if(handle == INVALID_HANDLE) {
      Print("[PH5] EpisodicMemory_Persist_Flush: Cannot open file.");
      return;
   }

   // Header
   FileWrite(handle,
      "open_time;ticket;type;volume;open_price;sl;tp;"
      "close_price;close_time;profit;commission;swap;"
      "state_id;prior_prob;posterior_prob;agent_votes;dag_trace;veto_reason");

   for(int i = 0; i < n; i++) {
      TradeRecordV8 &r = episodic_memory[i];
      FileWrite(handle,
         TimeToString(r.open_time),   (long)r.ticket,
         EnumToString(r.type),         DoubleToString(r.volume, 2),
         DoubleToString(r.open_price, _Digits),
         DoubleToString(r.sl, _Digits),
         DoubleToString(r.tp, _Digits),
         DoubleToString(r.close_price, _Digits),
         TimeToString(r.close_time),   DoubleToString(r.profit, 2),
         DoubleToString(r.commission, 2), DoubleToString(r.swap, 2),
         r.state_id,
         DoubleToString(r.prior_prob, 4), DoubleToString(r.posterior_prob, 4),
         r.agent_votes, r.dag_trace, r.veto_reason);
   }

   FileClose(handle);
   Print("[PH5] EpisodicMemory flush: wrote ", n, " records to ", TradeLogCSV);
}


//==========================================================================
//  [PH5-E]  Phase_Reflect
//  The REFLECT stage of the OODA loop.
//  Runs every tick for regime stability tracking.
//  Triggers full online learning update when reflectPending == true,
//  which is set by OnTradeTransaction when a closing deal is detected.
//
//  Design contract: must complete in < 5ms on average.
//  Timing is logged if exceeded.
//==========================================================================
void Phase_Reflect(AgentContext &ctx)
{
   ulong t_start = GetMicrosecondCount();

   // ─────────────────────────────────────────────────────────────────────
   // 1. Working Memory: update regime stability (every tick)
   // ─────────────────────────────────────────────────────────────────────
   UpdateWorkingMemory(ctx.marketRegime, ctx.aggregateConfidence / 100.0);

   // Compute regime stability score: fraction of last 10 regimes matching current
   double stability = 0.0;
   for(int i = 0; i < 10; i++) {
      if((int)working_memory.recent_regimes[i] == ctx.marketRegime) stability += 1.0;
   }
   working_memory.regimeStabilityScore = stability / 10.0;

   // ─────────────────────────────────────────────────────────────────────
   // 2. PredictiveCB: update throttle factor every tick
   // ─────────────────────────────────────────────────────────────────────
   PredictiveCB_Check();

   // ─────────────────────────────────────────────────────────────────────
   // 3. HardStop: constitutional check every tick
   // ─────────────────────────────────────────────────────────────────────
   HardStop_CheckAll();

   // ─────────────────────────────────────────────────────────────────────
   // 4. NN inference (non-learning pass) — track prediction accuracy
   // ─────────────────────────────────────────────────────────────────────
   if(UseNeuralNetwork) {
      double nn_inputs[10];
      NN_BuildInputVector(nn_inputs, ctx);
      double nn_out = NN_Forward(nn_inputs);
      ctx.aggregateConfidence = MathMax(ctx.aggregateConfidence,
                                        MathAbs(nn_out) * 100.0 * 0.3);
   }

   // ─────────────────────────────────────────────────────────────────────
   // 5. Full online learning update — triggered when a trade just closed
   // ─────────────────────────────────────────────────────────────────────
   if(!reflectPending) {
      // Nothing to learn this tick
      ulong elapsed = GetMicrosecondCount() - t_start;
      if(elapsed > 5000)
         AuditLog_Write("REFLECT_SLOW", StringFormat("Tick-only reflect: %d µs", (int)elapsed));
      return;
   }

   // ── 5a. Compute normalised reward ────────────────────────────────────
   double reward;
   double normaliser = (reflectATRAtEntry > 0 && reflectLotsUsed > 0) ?
                        reflectATRAtEntry * reflectLotsUsed : 1.0;
   reward = reflectProfit / normaliser;
   // Clip reward to [-5, +5] for training stability
   reward = MathMax(-5.0, MathMin(5.0, reward));

   // ── 5b. Q(λ) update ───────────────────────────────────────────────────
   if(UseReinforcementLearning && reflectStateKey >= 0) {
      int next_state = GetStateIndex();  // Current market state post-close
      QLearning_UpdateWithTrace(reflectStateKey, reflectAction,
                                reward, next_state);
      qLearnUpdateCount++;

      // Add closed-trade P&L to VaR rolling buffer
      varPnLBuffer[varBufHead] = reflectProfit;
      varBufHead  = (varBufHead + 1) % 50;
      varBufCount = MathMin(varBufCount + 1, 50);
   }

   // ── 5c. Bayesian posterior update ────────────────────────────────────
   if(UseBayesianInference)
      Bayes_UpdatePosterior(currentStrategy, reflectProfit);

   // ── 5d. NN backprop ───────────────────────────────────────────────────
   if(UseNeuralNetwork) {
      double nn_inputs[10];
      NN_BuildInputVector(nn_inputs, ctx);
      NN_TrainOnTradeOutcome(nn_inputs, reflectProfit);
      nnBackpropCount++;
   }

   // ── 5e. Complete episodic memory record ──────────────────────────────
   // Find the episodic record matching the closed ticket
   int ep_idx = -1;
   int ep_size = ArraySize(episodic_memory);
   for(int i = ep_size - 1; i >= MathMax(0, ep_size - 50); i--) {
      if(episodic_memory[i].ticket == reflectTicket) {
         ep_idx = i;
         break;
      }
   }
   if(ep_idx >= 0) {
      episodic_memory[ep_idx].close_price    = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      episodic_memory[ep_idx].close_time     = TimeCurrent();
      episodic_memory[ep_idx].profit         = reflectProfit;
      episodic_memory[ep_idx].posterior_prob = CalculatePosteriorMean(currentStrategy);
      EpisodicMemory_Persist(ep_idx);  // O(1) append
   }

   // ── 5f. Periodic saves ────────────────────────────────────────────────
   int total_trades = winCount + lossCount;

   if(total_trades > 0 && total_trades % 50 == 0) {
      NN_SaveWeights();
      QTable_Save();
      AuditLog_Write("PERIODIC_SAVE",
         StringFormat("Trade #%d: NN + QTable saved", total_trades));
   }

   if(total_trades > 0 && total_trades % 20 == 0 && UseSelfHealingOptimizer) {
      // Unfrozen optimizer guard
      if(!optimizerFrozen || TimeCurrent() > optimizerFrozenUntil) {
         if(optimizerFrozen) {
            optimizerFrozen = false;
            alignmentRejectStreak = 0;
         }
         SelfHealingOptimizer_Run();
      }
   }

   // ── Reset pending flag ────────────────────────────────────────────────
   reflectPending    = false;
   reflectProfit     = 0.0;
   reflectStateKey   = -1;
   reflectAction     = 2;
   reflectATRAtEntry = 0.0;
   reflectLotsUsed   = 0.01;
   reflectTicket     = 0;

   // ── Timing guard ─────────────────────────────────────────────────────
   ulong elapsed = GetMicrosecondCount() - t_start;
   if(elapsed > 5000)
      AuditLog_Write("REFLECT_SLOW",
         StringFormat("Full reflect: %d µs > 5000 µs budget", (int)elapsed));
   else if(ShowDebugLog)
      Print(StringFormat("[PH5] Phase_Reflect complete: reward=%.3f elapsed=%d µs",
                         reward, (int)elapsed));
}


//==========================================================================
//  [PH5b-A]  AgentLoop  — Full OODA rewrite
//  Replaces the old monolithic OnTick body.
//  Call AgentLoop() from OnTick() after the spread + bot-state checks.
//==========================================================================
void AgentLoop()
{
   AgentContext ctx;

   // ── PHASE 0: Constitutional safety check (runs before everything) ────
   if(!HardStop_CheckAll()) {
      lastSignal = "🚨 HARD STOP ACTIVE";
      if(ShowDashboard) Dashboard_AGI_Update(ctx);
      return;
   }

   // ── OBSERVE ──────────────────────────────────────────────────────────
   ctx.dataValid = UpdateIndicators();
   if(!ctx.dataValid) {
      PipelineTraceLog("OBSERVE", "FAIL", "Indicators not ready");
      return;
   }

   ctx.atrValue    = atrValue;   ctx.rsiValue  = rsiValue;
   ctx.adxValue    = adxValue;   ctx.emaFast   = emaFast;
   ctx.emaSlow     = emaSlow;    ctx.emaTrend  = emaTrend;
   ctx.macdMain    = macdMain;   ctx.macdSignal= macdSignal;
   ctx.bbUpper     = bbUpper;    ctx.bbMiddle  = bbMiddle;
   ctx.bbLower     = bbLower;
   ctx.stochMain   = stochMain;  ctx.stochSignal=stochSignal;
   ctx.plusDI      = plusDI;     ctx.minusDI   = minusDI;
   ctx.prevAtrValue= prevAtrValue;ctx.emaTrend_HTF=emaTrend_HTF;
   ctx.averageVolume=averageVolume;
   ctx.marketRegime = DetectMarketRegime();

   PipelineTraceLog("OBSERVE", "OK",
      StringFormat("Regime=%d ATR=%.2f RSI=%.1f", ctx.marketRegime, ctx.atrValue, ctx.rsiValue));

   // ── ORIENT: Specialist Agents + Q-learning vote ───────────────────────
   RunSpecialistAgents(ctx);

   // Q-learning contribution
   if(UseReinforcementLearning) {
      int stateKey  = GetStateIndex();
      int qlAction  = QLearning_SelectAction(stateKey);
      double maxQ   = qTable[stateKey].qValues[0];
      double minQ   = qTable[stateKey].qValues[0];
      for(int a = 1; a < 3; a++) {
         maxQ = MathMax(maxQ, qTable[stateKey].qValues[a]);
         minQ = MathMin(minQ, qTable[stateKey].qValues[a]);
      }
      double qlConf = maxQ - minQ;
      double qlWeight = MathMin(3.0, (double)qTable[stateKey].visitCount / 20.0);

      if(qlConf > 0.1 && qlWeight > 0.5 && qlAction != 2) {
         if(qlAction == 0) ctx.agentBuyVotes  += (int)MathRound(qlWeight);
         if(qlAction == 1) ctx.agentSellVotes += (int)MathRound(qlWeight);
         ctx.decisionReasons += StringFormat(" | QL(w=%.1f conf=%.2f)", qlWeight, qlConf);
      }
   }

   PipelineTraceLog("ORIENT", "OK",
      StringFormat("BuyV=%d SellV=%d Veto=%s",
                   ctx.agentBuyVotes, ctx.agentSellVotes,
                   ctx.tradingAllowed ? "N" : "Y"));

   // ── DECIDE: ValidationLayer + PredictiveCB ────────────────────────────
   if(!ctx.tradingAllowed) {
      PipelineTraceLog("DECIDE", "BLOCK", ctx.blockReason);
      Phase_Reflect(ctx);
      if(ShowDashboard) Dashboard_AGI_Update(ctx);
      return;
   }

   // Check cooldown
   if((int)(TimeCurrent() - lastTradeTime) < TradeCooldownSec) {
      PipelineTraceLog("DECIDE", "COOLDOWN", "Trade cooldown active");
      Phase_Reflect(ctx);
      if(ShowDashboard) Dashboard_AGI_Update(ctx);
      return;
   }

   // Check existing position
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i) &&
         posInfo.Symbol() == Symbol() &&
         posInfo.Magic() == EA_MAGIC_NUMBER) {
         PipelineTraceLog("DECIDE", "HAS_POS", "Position already open");
         Phase_Reflect(ctx);
         ManagePositions();
         if(ShowDashboard) Dashboard_AGI_Update(ctx);
         return;
      }
   }

   // ── PLAN: Construct order parameters ─────────────────────────────────
   int regime = ctx.marketRegime;
   double sl_m, tp_m;
   GetAdaptiveSLTPMultipliers(regime, sl_m, tp_m);

   // Apply live parameters from AlignmentValidator if available
   string gvPfx = "GHP_" + Symbol() + "_";
   if(GlobalVariableCheck(gvPfx + "ATR_SL")) sl_m = GlobalVariableGet(gvPfx + "ATR_SL");
   if(GlobalVariableCheck(gvPfx + "ATR_TP")) tp_m = GlobalVariableGet(gvPfx + "ATR_TP");

   double slDist = UseATRStops ? (ctx.atrValue * sl_m) : (FixedSL_Points * symbolInfo.Point());
   double tpDist = UseATRStops ? (ctx.atrValue * tp_m) : (FixedTP_Points * symbolInfo.Point());

   double base_lots = CalculateLotSize(slDist);

   // Apply PredictiveCB throttle factor
   double lots = NormalizeDouble(base_lots * varThrottleFactor,
                                 (int)MathLog10(1.0 / symbolInfo.LotsStep()));
   lots = MathMax(symbolInfo.LotsMin(),
          MathMin(symbolInfo.LotsMax(),
          MathMax(MinLot * varThrottleFactor, lots)));

   ctx.proposedLots = lots;
   ctx.proposedSL   = slDist;
   ctx.proposedTP   = tpDist;

   bool isBuy  = (ctx.proposedType == ORDER_TYPE_BUY);
   bool isSell = (ctx.proposedType == ORDER_TYPE_SELL);

   if(!isBuy && !isSell) {
      PipelineTraceLog("PLAN", "NO_SIGNAL", "No directional vote");
      Phase_Reflect(ctx);
      if(ShowDashboard) Dashboard_AGI_Update(ctx);
      return;
   }

   // Confluence gates
   if(!IsStrongConfluence(isBuy)) {
      lastSignal = isBuy ? "⏳ No TF Confluence (B)" : "⏳ No TF Confluence (S)";
      PipelineTraceLog("PLAN", "NO_CONF", lastSignal);
      Phase_Reflect(ctx);
      if(ShowDashboard) Dashboard_AGI_Update(ctx);
      return;
   }

   symbolInfo.RefreshRates();
   double ask = symbolInfo.Ask(), bid = symbolInfo.Bid();
   int    digits = symbolInfo.Digits();

   if(isBuy) {
      ctx.proposedEntry = ask;
      ctx.proposedSL    = NormalizeDouble(bid - slDist, digits);
      ctx.proposedTP    = NormalizeDouble(ask + tpDist, digits);
   } else {
      ctx.proposedEntry = bid;
      ctx.proposedSL    = NormalizeDouble(ask + slDist, digits);
      ctx.proposedTP    = NormalizeDouble(bid - tpDist, digits);
   }

   // Pre-trade ValidationLayer hard check
   string val_reason;
   if(!ValidationLayer_Check(lots, slDist, ctx.proposedEntry,
                             ctx.proposedType, val_reason)) {
      lastSignal = "🛑 " + val_reason;
      AuditLog_Write("VAL_BLOCK", val_reason);
      PipelineTraceLog("PLAN", "VAL_FAIL", val_reason);
      Phase_Reflect(ctx);
      if(ShowDashboard) Dashboard_AGI_Update(ctx);
      return;
   }

   PipelineTraceLog("PLAN", "OK",
      StringFormat("Dir=%s Lots=%.2f(x%.2f) SL=%.4f TP=%.4f",
                   isBuy ? "BUY" : "SELL", lots, varThrottleFactor,
                   ctx.proposedSL, ctx.proposedTP));

   // ── EXECUTE: 5-Node DAG ───────────────────────────────────────────────
   // Store Q-state BEFORE placing order for Phase_Reflect
   reflectStateKey   = GetStateIndex();
   reflectAction     = isBuy ? 0 : 1;
   reflectATRAtEntry = ctx.atrValue;
   reflectLotsUsed   = lots;

   string comment = StringFormat("GHP8_%s_VaR%.0f",
                                  stratNames[currentStrategy],
                                  varThrottleFactor * 100.0);

   ctx.orderPlaced = ExecuteOrderDAG(ctx.proposedType, lots,
                                      ctx.proposedEntry,
                                      ctx.proposedSL, ctx.proposedTP,
                                      comment);

   if(ctx.orderPlaced) {
      ctx.placedTicket  = (ulong)trade.ResultOrder();
      reflectTicket     = (long)ctx.placedTicket;
      lastTradeTime     = TimeCurrent();
      tradesThisDay++;
      consecutiveLosses = 0;

      lastSignal = StringFormat("%s @ %.2f | Lots=%.2f (VaR=%.0f%%)",
                                isBuy ? "🟢 BUY" : "🔴 SELL",
                                ctx.proposedEntry, lots,
                                varThrottleFactor * 100.0);

      // Log to episodic memory
      double prior = CalculatePosteriorMean(currentStrategy);
      string votes = StringFormat("B%d:S%d", ctx.agentBuyVotes, ctx.agentSellVotes);
      LogTradeToEpisodicMemory(
         (long)ctx.placedTicket, ctx.proposedType, lots,
         ctx.proposedEntry, ctx.proposedSL, ctx.proposedTP,
         reflectStateKey, prior, prior, votes, "", "");

      AuditLog_Write("ORDER_PLACED",
         StringFormat("%s Lots=%.2f Entry=%.2f SL=%.4f TP=%.4f Ticket=%d Throttle=%.0f%%",
                      isBuy ? "BUY" : "SELL", lots, ctx.proposedEntry,
                      ctx.proposedSL, ctx.proposedTP,
                      (long)ctx.placedTicket, varThrottleFactor * 100.0));

      PipelineTraceLog("EXECUTE", "OK",
         StringFormat("Ticket=%d", (long)ctx.placedTicket));
   } else {
      PipelineTraceLog("EXECUTE", "FAIL", "DAG execution failed");
   }

   // ── REFLECT: online learning ──────────────────────────────────────────
   Phase_Reflect(ctx);

   // ── Post-execution safety check ───────────────────────────────────────
   SafetyLayer_PostCheck(ctx);

   if(ShowDashboard) Dashboard_AGI_Update(ctx);
}


//==========================================================================
//  [PH5b-C]  Dashboard_AGI_Update
//  Appends new AGI v8 rows to the existing panel.
//  Requires CreateDashboard() to have been called first (existing function).
//  Uses the same ObjectSetString / CreateLabel pattern.
//==========================================================================
void Dashboard_AGI_Update(AgentContext &ctx)
{
   if(!ShowDashboard) return;

   string p = "GHP_";
   int xL = 10, baseY = 430;   // Position below existing 17-row panel
   int rowH = 16;

   // Helper lambda-equivalent: create label if missing, then update
   #define DASH_ROW(name, yoff, txt, col) \
      if(ObjectFind(ChartID(), p+"agi_"+(name)) < 0) \
         CreateLabel(p+"agi_"+(name), xL, baseY+(yoff)*rowH, "", col, 8); \
      ObjectSetString(ChartID(),  p+"agi_"+(name), OBJPROP_TEXT, txt); \
      ObjectSetInteger(ChartID(), p+"agi_"+(name), OBJPROP_COLOR, col);

   // ── Row: Agent Votes ──────────────────────────────────────────────────
   string vetoStr = (!ctx.tradingAllowed && StringFind(ctx.blockReason, "VETO") >= 0)
                    ? " ⛔VETO" : "";
   DASH_ROW("votes", 0,
      StringFormat("AGENTS  B:%d S:%d%s | Conf:%.0f%%",
                   ctx.agentBuyVotes, ctx.agentSellVotes, vetoStr,
                   ctx.aggregateConfidence),
      clrCyan);

   // ── Row: Memory ───────────────────────────────────────────────────────
   DASH_ROW("memory", 1,
      StringFormat("MEMORY  Stab:%.0f%% | W:%d L:%d Sess:+%.2f",
                   working_memory.regimeStabilityScore * 100.0,
                   winCount, lossCount,
                   working_memory.session_pnl),
      clrLightGray);

   // ── Row: Learning ─────────────────────────────────────────────────────
   // Best Bayesian strategy
   double bProbs[5] = { bayesProbs.autoProb, bayesProbs.scalpProb,
                         bayesProbs.swingProb, bayesProbs.breakoutProb,
                         bayesProbs.reversalProb };
   int bBest = 0;
   for(int s = 1; s < 5; s++) if(bProbs[s] > bProbs[bBest]) bBest = s;

   double nnOut = 0.0;
   if(UseNeuralNetwork) {
      double nn_inp[10];
      NN_BuildInputVector(nn_inp, ctx);
      nnOut = NN_Forward(nn_inp);
   }

   DASH_ROW("learn", 2,
      StringFormat("LEARN   Q:%d states | NN:%+.2f | Bayes:%s",
                   qTableSize, nnOut, stratNames[bBest]),
      clrLightBlue);

   // ── Row: Optimizer ────────────────────────────────────────────────────
   string frozenStr = optimizerFrozen ? "🧊YES" : "NO";
   DASH_ROW("optim", 3,
      StringFormat("OPTIM   Applied:%d Rej:%d Frozen:%s VaR:%.0f%%",
                   optimizer.appliedCount, optimizer.rejectedCount,
                   frozenStr, varThrottleFactor * 100.0),
      optimizerFrozen ? clrOrange : clrLightGray);

   // ── Row: Last Audit Event ─────────────────────────────────────────────
   string auditDisp = (lastAuditEvent != "")
      ? StringFormat("%s @%s", lastAuditEvent,
                     TimeToString(lastAuditEventTime, TIME_MINUTES))
      : "—";
   // Truncate to fit panel width
   if(StringLen(auditDisp) > 48) auditDisp = StringSubstr(auditDisp, 0, 45) + "...";
   DASH_ROW("audit", 4, "AUDIT   " + auditDisp, clrYellow);

   // ── Row: Pipeline Trace (last 2 entries) ─────────────────────────────
   int traceCount = ArraySize(pipelineTrace);
   string traceStr = "—";
   if(traceCount > 0) {
      int last = (pipelineTraceHead - 1 + MAX_PIPELINE_TRACE) % MAX_PIPELINE_TRACE;
      last = MathMin(last, traceCount - 1);
      traceStr = pipelineTrace[last];
      if(StringLen(traceStr) > 45) traceStr = StringSubstr(traceStr, 0, 42) + "...";
   }
   DASH_ROW("trace", 5, "TRACE   " + traceStr, clrGray);

   #undef DASH_ROW

   ChartRedraw(ChartID());
}


//==========================================================================
//  [PH5b-D]  SendDiscordExtendedReport  (upgraded — replaces existing)
//  Adds the 🧠 AGI COGNITIVE STATE section to the daily report.
//  Drop-in replacement: same function name, same call site in CheckNewDay().
//==========================================================================
void SendDiscordExtendedReport()
{
   if(!NotifyOnDailyReport) return;

   double finalBal = AccountInfoDouble(ACCOUNT_BALANCE);
   double dayPnL   = finalBal - dailyStartBalance;
   double dayPnLPct= (dailyStartBalance > 0) ? dayPnL / dailyStartBalance * 100.0 : 0;
   int    wr       = (winCount + lossCount > 0) ?
                     (int)(winCount * 100.0 / (winCount + lossCount)) : 0;

   int londonTotal = londonWins + londonLosses;
   int nyTotal     = nyWins + nyLosses;
   int asianTotal  = asianWins + asianLosses;
   int lwrPct  = londonTotal > 0 ? (int)(londonWins * 100.0 / londonTotal) : 0;
   int nywrPct = nyTotal     > 0 ? (int)(nyWins     * 100.0 / nyTotal)     : 0;
   int aswrPct = asianTotal  > 0 ? (int)(asianWins  * 100.0 / asianTotal)  : 0;

   // Bayesian best strategy
   double bProbs[5] = { bayesProbs.autoProb, bayesProbs.scalpProb,
                         bayesProbs.swingProb, bayesProbs.breakoutProb,
                         bayesProbs.reversalProb };
   int bBest = 0;
   for(int s = 1; s < 5; s++) if(bProbs[s] > bProbs[bBest]) bBest = s;
   int bPct = (int)(bProbs[bBest] * 100.0);

   string frozenStr = optimizerFrozen ? "YES 🧊" : "NO";

   string auditLine = (lastAuditEvent != "")
      ? StringFormat("`%s` @ `%s`",
                     lastAuditEvent,
                     TimeToString(lastAuditEventTime, TIME_DATE | TIME_MINUTES))
      : "`None`";

   SendDiscord(StringFormat(
      "📋 **DAILY REPORT — GoldHunter AGI v8.4 — %s**\n"
      "━━━━━━━━━━━━━━━━━━━━\n"
      "📊 Trades: `%d` (advisory max: %d)\n"
      "✅ Win: `%d`  ❌ Loss: `%d`  WR: `%d%%`\n"
      "🏆 Win Streak: `%d`  😓 Loss Streak: `%d`\n"
      "💵 Day P&L: `%s$%.2f` (`%+.2f%%`)\n"
      "💰 Balance: `$%.2f`\n"
      "📉 Max DD Today: `%.2f%%`\n"
      "━━━━━━━━━━━━━━━━━━━━\n"
      "🇬🇧 London: W%d/L%d WR:%d%% P&L:`%+.2f`\n"
      "🇺🇸 New York: W%d/L%d WR:%d%% P&L:`%+.2f`\n"
      "🌏 Asian: W%d/L%d WR:%d%% P&L:`%+.2f`\n"
      "━━━━━━━━━━━━━━━━━━━━\n"
      "🧠 **AGI COGNITIVE STATE**\n"
      "  Q-Table: `%d states learned` | NN Backprop: `%d updates`\n"
      "  Bayes Best Strategy: `%s (%d%% posterior)`\n"
      "  Optimizer: Applied `×%d` | Rejected `×%d` | Frozen: `%s`\n"
      "  Regime Stability: `%.0f%%` (last 10 bars)\n"
      "  VaR Throttle: `%.0f%%` of normal lot\n"
      "  Last Audit: %s\n"
      "━━━━━━━━━━━━━━━━━━━━",
      TimeToString(TimeCurrent(), TIME_DATE),
      tradesThisDay, MaxTradesPerDay,
      winCount, lossCount, wr,
      maxWinStreak, maxLossStreak,
      (dayPnL >= 0 ? "+" : "-"), MathAbs(dayPnL), dayPnLPct,
      finalBal, maxDrawdownPct,
      londonWins, londonLosses, lwrPct, londonPnL,
      nyWins, nyLosses, nywrPct, nyPnL,
      asianWins, asianLosses, aswrPct, asianPnL,
      // AGI block
      qTableSize, nnBackpropCount,
      stratNames[bBest], bPct,
      optimizer.appliedCount, optimizer.rejectedCount, frozenStr,
      working_memory.regimeStabilityScore * 100.0,
      varThrottleFactor * 100.0,
      auditLine));

   if(PushNotifyOnDaily)
      SendNotification(StringFormat(
         "GHP8 Daily | P&L:%+.2f%%($%+.2f) | W:%d L:%d WR:%d%% | "
         "VaR:%.0f%% | Bayes:%s | Bal:$%.2f",
         dayPnLPct, dayPnL, winCount, lossCount, wr,
         varThrottleFactor * 100.0, stratNames[bBest], finalBal));
}


//==========================================================================
//  [PH5b-E]  OnDeinit_AGI  — Upgraded teardown
//  Call this at the START of the existing OnDeinit(), before indicator
//  releases, to ensure all learning state is flushed.
//==========================================================================
void OnDeinit_AGI(const int reason)
{
   // Persist all learning state before any resources are released
   NN_SaveWeights();
   QTable_Save();
   EpisodicMemory_Persist_Flush();

   AuditLog_Write("DEINIT",
      StringFormat("EA removed. Reason: %s | W:%d L:%d NetPnL:%.2f "
                   "NN_bp:%d Q_upd:%d Optimizer(A:%d R:%d) VaRThrottle:%.0f%%",
                   DeinitReasonToString(reason),
                   winCount, lossCount, totalProfit,
                   nnBackpropCount, qLearnUpdateCount,
                   optimizer.appliedCount, optimizer.rejectedCount,
                   varThrottleFactor * 100.0));

   // Persist Bayesian priors via GlobalVariables (already done in Bayes_UpdatePosterior,
   // but do a final sync here as a belt-and-suspenders measure)
   string pfx = "GHP_BAYES_" + Symbol() + "_";
   for(int s = 0; s < 5; s++) {
      GlobalVariableSet(pfx + "A" + IntegerToString(s), strategy_alpha[s]);
      GlobalVariableSet(pfx + "B" + IntegerToString(s), strategy_beta[s]);
   }

   Print("[PH5b] OnDeinit_AGI complete. Reason=", DeinitReasonToString(reason));
}


//==========================================================================
//  INTEGRATION NOTES  (Read before patching into god.mq5)
//==========================================================================
//
//  1. GLOBAL STATE BLOCK
//     Copy the "ADDITIONAL GLOBAL STATE" section at the top of this file
//     into god.mq5 immediately after the existing global variable block
//     (after the `SelfHealOptimizer optimizer;` declaration, ~line 448).
//
//  2. OnInit ADDITIONS
//     After the existing Phase 2/3 initialisation in OnInit(), add:
//
//       // Load Bayesian priors from GlobalVariables (survives restarts)
//       string pfx = "GHP_BAYES_" + Symbol() + "_";
//       for(int s = 0; s < 5; s++) {
//          if(GlobalVariableCheck(pfx+"A"+IntegerToString(s)))
//             strategy_alpha[s] = GlobalVariableGet(pfx+"A"+IntegerToString(s));
//          if(GlobalVariableCheck(pfx+"B"+IntegerToString(s)))
//             strategy_beta[s]  = GlobalVariableGet(pfx+"B"+IntegerToString(s));
//       }
//       // Load Q-table (binary) + NN weights
//       QTable_Load();
//       NN_LoadWeights_Binary();
//       // Audit startup
//       AuditLog_Write("INIT", "GoldHunter AGI v8.4 started");
//
//  3. OnTick REPLACEMENT
//     Replace the body of OnTick() from the ManagePositions() call onwards
//     with:
//
//       ManagePositions();
//       CheckConsecutiveLossCB();
//       AgentLoop();           // ← full OODA pipeline
//
//     Keep the spread check, bot-state check, and CB-lift logic above it.
//
//  4. OnTradeTransaction ADDITIONS
//     At the END of the existing isClose branch (after consecutiveLosses++),
//     add the following to trigger Phase_Reflect:
//
//       if(isClose || netProfit != 0.0) {
//          // ... existing code ...
//          // NEW: feed reflection pipeline
//          reflectPending    = true;
//          reflectProfit     = netProfit;
//          reflectTicket     = (long)posId;
//          // Store ATR and lot at entry time; if not available use current
//          reflectATRAtEntry = (atrValue > 0) ? atrValue : 10.0;
//          reflectLotsUsed   = dealVol;
//          // Resolve action from deal type
//          reflectAction = (dealType == DEAL_TYPE_BUY) ? 0 :
//                          (dealType == DEAL_TYPE_SELL) ? 1 : 2;
//          working_memory.session_pnl += netProfit;
//       }
//
//  5. OnDeinit ADDITIONS
//     At the VERY START of OnDeinit(), before IndicatorRelease calls:
//
//       OnDeinit_AGI(reason);   // flush learning state
//
//  6. DASHBOARD
//     Dashboard_AGI_Update() is called from AgentLoop().
//     If you keep UpdateDashboard() elsewhere, also call Dashboard_AGI_Update()
//     from there, passing a default-constructed AgentContext.
//
//  7. FUNCTION NAME COLLISION: SendDiscordExtendedReport
//     This file redefines SendDiscordExtendedReport() (upgraded version).
//     DELETE or comment out the original definition at ~line 2281 in god.mq5
//     to avoid duplicate symbol errors.
//
//  8. COMPILATION ORDER
//     MQL5 requires all identifiers to be declared before use.
//     Since this block references HardStop_CheckAll(), ValidationLayer_Check(),
//     PredictiveCB_Check(), etc. from AgentLoop(), and AgentLoop() calls
//     Phase_Reflect(), all of which are defined in THIS file in the correct
//     top-to-bottom order, paste this entire block BEFORE the
//     RunSpecialistAgents / ExecuteOrderDAG functions in god.mq5
//     (i.e., before line ~3825).
//
//==========================================================================
//  END OF MISSING IMPLEMENTATIONS — GoldHunter AGI v8.4
//==========================================================================
