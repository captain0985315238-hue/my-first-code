//+------------------------------------------------------------------+
//|         GOLDHUNTER ULTIMATE v8.4 UHF AGI — PHASE 4 EDITION            |
//|    Ultra-High-Frequency AGI Trading Bot for XAUUSD (Gold) Scalp/Swing    |
//|    Standard: MetaEditor 5 / XM Global MT5 Servers    |
//|    Build Target: MT5 4000+ | Tested: XAUUSD M1/M5/M15/H1        |
//|    PHASE 4: Safety Guardrails + Circuit Breakers + Alignment Layer   |
//+------------------------------------------------------------------+
#property copyright "GoldHunter UHF AGI v8.4 — Phase 4 Edition"
#property version   "8.04"
#property description "UHF Gold EA | XAUUSD | 1-Second Execution | AGI OODA + 5-Agent VETO + DAG + Safety"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>

//--- Forward declarations for existing functions
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

// PHASE 4: New forward declarations
int      CountEAPositions();
void     AuditLog_Write(string event, string detail);
void     HardStop_TriggerDisable(string reason);
bool     HardStop_CheckAll();
bool     ValidationLayer_Check(AgentContext &ctx);
void     PredictiveCB_Check(AgentContext &ctx);
bool     AlignmentValidator_Check(string paramName, double proposedValue, 
                                   double currentValue, string &rejectReason);
void     SelfHealingOptimizer_Run_Phase4();

CTrade         trade;
CSymbolInfo    symbolInfo;
CPositionInfo  posInfo;
