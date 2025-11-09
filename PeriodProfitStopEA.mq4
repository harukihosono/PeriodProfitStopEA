//+------------------------------------------------------------------+
//|                                      PeriodProfitStopEA.mq4   |
//|                              Copyright 2025, ProfitStop EA      |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, PeriodProfitStopEA"
#property version   "1.0"
#property strict
#property description "期間累計損益ストップEA - MQL4版"

// 共通ヘッダーファイルをインクルード
#include "PeriodProfitStopEA.mqh"

//+------------------------------------------------------------------+
//| Expert initialization function                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   PPSEA_Init();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PPSEA_Deinit();
}

//+------------------------------------------------------------------+
//| Expert tick function                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   PPSEA_OnTick();
}
