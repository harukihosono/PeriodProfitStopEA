//+------------------------------------------------------------------+
//|                                      PeriodProfitStopEA.mqh    |
//|                              Copyright 2025, ProfitStop EA      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, PeriodProfitStopEA"
#property strict

//+------------------------------------------------------------------+
//| MQL4/MQL5 互換性マクロ定義                                      |
//+------------------------------------------------------------------+
#ifdef __MQL5__
   #include <Trade\Trade.mqh>
   CTrade g_trade;

   #define MODE_TRADES 0
   #define SELECT_BY_POS 0
   #define MODE_HISTORY 1
   #define SELECT_BY_TICKET 1
   #define MODE_BID 1
   #define MODE_ASK 2
   #define OP_BUY 0
   #define OP_SELL 1
#endif

// AutoTradingControlをインクルード
#include "AutoTradingControl.mqh"

//+------------------------------------------------------------------+
//| 期間計算モード                                                  |
//+------------------------------------------------------------------+
enum ENUM_PERIOD_MODE
{
   PERIOD_FROM_STARTUP,     // EA起動時から
   PERIOD_FROM_DATETIME     // 指定日時から
};

//+------------------------------------------------------------------+
//| 目標達成時のアクション                                          |
//+------------------------------------------------------------------+
enum ENUM_TARGET_ACTION
{
   ACTION_STOP_ONLY,        // EAを停止のみ
   ACTION_CLOSE_AND_STOP    // 全決済＋EA停止
};

//+------------------------------------------------------------------+
//| Input Parameters                                                |
//+------------------------------------------------------------------+
sinput string separator1 = "=== 期間設定 ===";           // 期間設定
input ENUM_PERIOD_MODE PeriodMode = PERIOD_FROM_STARTUP; // 期間計算モード
input datetime StartDateTime = D'2025.01.01 00:00';      // 開始日時(指定日時モード時)

sinput string separator2 = "=== 損益目標設定 ===";       // 損益目標設定
input bool EnableProfitTarget = true;                    // 利益目標を有効化
input double ProfitTargetAmount = 10000.0;               // 利益目標金額
input bool EnableLossLimit = true;                       // 損失制限を有効化
input double LossLimitAmount = 10000.0;                  // 損失制限金額
input ENUM_TARGET_ACTION TargetAction = ACTION_CLOSE_AND_STOP; // 目標達成時のアクション

sinput string separator3 = "=== 通知設定 ===";           // 通知設定
input bool EnableSound = true;                           // サウンド通知を有効化
input string SoundFile = "alert.wav";                    // 通知サウンドファイル

sinput string separator4 = "=== 表示設定 ===";           // 表示設定
input int DisplayX = 10;                                 // 表示位置X座標
input int DisplayY = 25;                                 // 表示位置Y座標
input int FontSize = 12;                                 // 基本フォントサイズ
input int FontSizeStopAdd = 2;                           // 停止時の追加サイズ
input string FontName = "MS Gothic";                     // フォント名（日本語対応）

sinput string separator5 = "=== 決済設定 ===";           // 決済設定
input int MaxRetries = 3;                                // 決済リトライ回数
input int RetryDelay = 1000;                             // リトライ間隔(ミリ秒)
input int MagicNumber = 0;                               // マジックナンバー(0=全ポジション)

//+------------------------------------------------------------------+
//| グローバル変数                                                  |
//+------------------------------------------------------------------+
datetime g_periodStartTime = 0;                          // 期間開始時刻
double g_periodStartBalance = 0;                         // 期間開始時残高
bool g_targetReached = false;                            // 目標達成フラグ
bool g_eaStopped = false;                                // EA停止フラグ
bool g_pendingAutoTradingStop = false;                   // 自動売買停止待機フラグ
datetime g_pendingStopStartTime = 0;                     // 自動売買停止待機開始時刻
string g_prefix = "PPSEA_";                              // オブジェクト名プレフィックス
bool g_lastAutoTradingEnabled = true;                    // 前回の自動売買状態

// 表示最適化用キャッシュ
double g_lastDisplayedBalance = 0;                       // 前回表示した残高
double g_lastDisplayedProfit = 0;                        // 前回表示した利益
double g_lastDisplayedProgress = 0;                      // 前回表示した進捗率

// 検証済み入力パラメータ
int g_maxRetries = 3;                                    // 検証済みリトライ回数
int g_retryDelay = 1000;                                 // 検証済みリトライ間隔

//+------------------------------------------------------------------+
//| アカウント情報関数ラッパー                                      |
//+------------------------------------------------------------------+
double PPSEA_AccountBalance()
{
#ifdef __MQL5__
   return AccountInfoDouble(ACCOUNT_BALANCE);
#else
   return AccountBalance();
#endif
}

double PPSEA_AccountEquity()
{
#ifdef __MQL5__
   return AccountInfoDouble(ACCOUNT_EQUITY);
#else
   return AccountEquity();
#endif
}

int PPSEA_OrdersTotal()
{
#ifdef __MQL5__
   return PositionsTotal();
#else
   return OrdersTotal();
#endif
}

//+------------------------------------------------------------------+
//| 現在のオープンポジションの含み損益を取得                          |
//+------------------------------------------------------------------+
double PPSEA_OrderProfit()
{
#ifdef __MQL5__
   return PositionGetDouble(POSITION_PROFIT);
#else
   return OrderProfit() + OrderSwap() + OrderCommission();
#endif
}

//+------------------------------------------------------------------+
//| フィルター済みポジションの含み損益合計を取得                      |
//+------------------------------------------------------------------+
double GetFilteredPositionsProfit()
{
   double totalProfit = 0;
   for(int i = 0; i < PPSEA_OrdersTotal(); i++)
   {
      if(!PPSEA_OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      // ポジションタイプチェック（ペンディングオーダーを除外）
      int type = PPSEA_OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;

      // マジックナンバーフィルター
      if(MagicNumber != 0)
      {
#ifdef __MQL5__
         long posMagic = PositionGetInteger(POSITION_MAGIC);
#else
         int posMagic = OrderMagicNumber();
#endif
         if(posMagic != MagicNumber)
            continue;
      }

      totalProfit += PPSEA_OrderProfit();
   }
   return totalProfit;
}

//+------------------------------------------------------------------+
//| 期間内の決済済み取引の損益合計を取得                              |
//+------------------------------------------------------------------+
double GetClosedTradesProfit()
{
   double totalProfit = 0;

#ifdef __MQL5__
   // MQL5の場合
   HistorySelect(g_periodStartTime, TimeCurrent());
   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      // エントリーのみ対象（決済取引）
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      // マジックナンバーフィルター
      if(MagicNumber != 0)
      {
         long dealMagic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
         if(dealMagic != MagicNumber)
            continue;
      }

      // 損益を加算
      totalProfit += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      totalProfit += HistoryDealGetDouble(ticket, DEAL_SWAP);
      totalProfit += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
#else
   // MQL4の場合
   int total = OrdersHistoryTotal();

   for(int i = 0; i < total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;

      // 決済時刻が期間内かチェック
      if(OrderCloseTime() < g_periodStartTime)
         continue;

      // マジックナンバーフィルター
      if(MagicNumber != 0)
      {
         if(OrderMagicNumber() != MagicNumber)
            continue;
      }

      // ポジションのみ対象
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;

      // 損益を加算
      totalProfit += OrderProfit();
      totalProfit += OrderSwap();
      totalProfit += OrderCommission();
   }
#endif

   return totalProfit;
}

//+------------------------------------------------------------------+
//| MQL5用関数ラッパー                                              |
//+------------------------------------------------------------------+
#ifdef __MQL5__
bool PPSEA_OrderSelect(int index, int select, int pool = MODE_TRADES)
{
   ResetLastError();

   if(pool == MODE_TRADES && select == SELECT_BY_POS)
   {
      return (PositionGetTicket(index) > 0);
   }
   else if(select == SELECT_BY_TICKET)
   {
      return PositionSelectByTicket(index);
   }

   Print("ERROR: PPSEA_OrderSelect - Invalid parameters. select=", select, " pool=", pool);
   return false;
}

// ulong版オーバーロード（チケット選択用）
bool PPSEA_OrderSelect(ulong ticket, int select, int pool = MODE_TRADES)
{
   ResetLastError();

   if(select == SELECT_BY_TICKET)
   {
      return PositionSelectByTicket(ticket);
   }

   Print("ERROR: PPSEA_OrderSelect(ulong) - Invalid select mode: ", select);
   return false;
}

string PPSEA_OrderSymbol()
{
   return PositionGetString(POSITION_SYMBOL);
}

int PPSEA_OrderType()
{
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   return (type == POSITION_TYPE_BUY) ? OP_BUY : OP_SELL;
}

double PPSEA_OrderLots()
{
   return PositionGetDouble(POSITION_VOLUME);
}

ulong PPSEA_OrderTicket()
{
   return PositionGetInteger(POSITION_TICKET);
}

double PPSEA_MarketInfo(string symbol, int mode)
{
   double price = 0;

   if(mode == MODE_BID)
      price = SymbolInfoDouble(symbol, SYMBOL_BID);
   else if(mode == MODE_ASK)
      price = SymbolInfoDouble(symbol, SYMBOL_ASK);
   else
   {
      Print("ERROR: PPSEA_MarketInfo - Invalid mode: ", mode);
      return 0;
   }

   if(price <= 0)
   {
      Print("ERROR: PPSEA_MarketInfo - Invalid price for ", symbol, " mode=", mode, " price=", price);
   }

   return price;
}

bool PPSEA_OrderClose(ulong ticket, double lots, double price, int slippage)
{
   g_trade.SetDeviationInPoints(slippage);
   return g_trade.PositionClose(ticket);
}

#else // MQL4

bool PPSEA_OrderSelect(int index, int select, int pool = MODE_TRADES)
{
   ResetLastError();
   bool result = OrderSelect(index, select, pool);

   if(!result)
   {
      int error = GetLastError();
      if(error != ERR_NO_ERROR)
      {
         Print("ERROR: PPSEA_OrderSelect failed. index=", index, " select=", select, " pool=", pool, " Error=", error);
      }
   }

   return result;
}

string PPSEA_OrderSymbol()
{
   return OrderSymbol();
}

int PPSEA_OrderType()
{
   return OrderType();
}

double PPSEA_OrderLots()
{
   return OrderLots();
}

int PPSEA_OrderTicket()
{
   return OrderTicket();
}

double PPSEA_MarketInfo(string symbol, int mode)
{
   double price = MarketInfo(symbol, mode);

   if(price <= 0)
   {
      Print("ERROR: PPSEA_MarketInfo - Invalid price for ", symbol, " mode=", mode, " price=", price);
   }

   return price;
}

bool PPSEA_OrderClose(int ticket, double lots, double price, int slippage)
{
   return OrderClose(ticket, lots, price, slippage, clrYellow);
}
#endif

//+------------------------------------------------------------------+
//| 金額をカンマ区切りでフォーマット                                 |
//+------------------------------------------------------------------+
string FormatMoney(double value, int digits = 2)
{
   string sign = "";
   if(value < 0)
   {
      sign = "-";
      value = MathAbs(value);
   }

   string str = DoubleToString(value, digits);
   string result = "";
   int dotPos = StringFind(str, ".");
   string intPart = "";
   string decPart = "";

   if(dotPos >= 0)
   {
      intPart = StringSubstr(str, 0, dotPos);
      decPart = StringSubstr(str, dotPos);
   }
   else
   {
      intPart = str;
      decPart = "";
   }

   int len = StringLen(intPart);
   for(int i = 0; i < len; i++)
   {
      if(i > 0 && (len - i) % 3 == 0)
         result += ",";
      result += StringSubstr(intPart, i, 1);
   }

   return sign + result + decPart;
}

//+------------------------------------------------------------------+
//| エラーコード説明関数                                            |
//+------------------------------------------------------------------+
string ErrorDescription(int error_code)
{
   string error_string = "";

   switch(error_code)
   {
      case 0:     error_string = "No error"; break;
      case 1:     error_string = "No error, trade operation successful"; break;
      case 2:     error_string = "Common error"; break;
      case 3:     error_string = "Invalid trade parameters"; break;
      case 4:     error_string = "Trade server is busy"; break;
      case 128:   error_string = "Trade timeout"; break;
      case 129:   error_string = "Invalid price"; break;
      case 130:   error_string = "Invalid stops"; break;
      case 131:   error_string = "Invalid trade volume"; break;
      case 132:   error_string = "Market is closed"; break;
      case 133:   error_string = "Trade is disabled"; break;
      case 134:   error_string = "Not enough money"; break;
      case 135:   error_string = "Price changed"; break;
      case 136:   error_string = "Off quotes"; break;
      case 137:   error_string = "Broker is busy"; break;
      case 138:   error_string = "Requote"; break;
      case 139:   error_string = "Order is locked"; break;
      case 146:   error_string = "Trade context is busy"; break;
      default:    error_string = "Unknown error (" + IntegerToString(error_code) + ")";
   }

   return error_string;
}

//+------------------------------------------------------------------+
//| フィルター済みポジション数を取得                                  |
//+------------------------------------------------------------------+
int GetFilteredPositionCount()
{
   int count = 0;
   for(int i = 0; i < PPSEA_OrdersTotal(); i++)
   {
      if(!PPSEA_OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      // ポジションタイプチェック（ペンディングオーダーを除外）
      int type = PPSEA_OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;

      // マジックナンバーフィルター
      if(MagicNumber != 0)
      {
#ifdef __MQL5__
         long posMagic = PositionGetInteger(POSITION_MAGIC);
#else
         int posMagic = OrderMagicNumber();
#endif
         if(posMagic != MagicNumber)
            continue;
      }

      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| フィルター済みペンディングオーダー数を取得                          |
//+------------------------------------------------------------------+
int GetFilteredPendingOrderCount()
{
#ifdef __MQL5__
   int count = 0;
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      // マジックナンバーフィルター
      if(MagicNumber != 0)
      {
         long orderMagic = OrderGetInteger(ORDER_MAGIC);
         if(orderMagic != MagicNumber)
            continue;
      }

      count++;
   }
   return count;
#else
   int count = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(!PPSEA_OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      // ペンディングオーダーのみカウント
      int type = PPSEA_OrderType();
      if(type == OP_BUY || type == OP_SELL)
         continue;

      // マジックナンバーフィルター
      if(MagicNumber != 0)
      {
         int orderMagic = OrderMagicNumber();
         if(orderMagic != MagicNumber)
            continue;
      }

      count++;
   }
   return count;
#endif
}

//+------------------------------------------------------------------+
//| 初期化処理                                                      |
//+------------------------------------------------------------------+
void PPSEA_Init()
{
   // DLL機能の確認
   if(!IsDLLAvailable())
   {
      Print("ERROR: DLL imports are not enabled. AutoTrading control will not work.");
      Alert("PeriodProfitStopEA: DLL機能が無効です。\nツール > オプション > エキスパートアドバイザ > DLLの使用を許可 をチェックしてください。");
      ExpertRemove();
      return;
   }

   // 入力パラメータ検証
   if(!EnableProfitTarget && !EnableLossLimit)
   {
      Print("ERROR: Both profit target and loss limit are disabled. EA cannot function.");
      Alert("PeriodProfitStopEA: 利益目標と損失制限の両方が無効です。最低1つを有効にしてください。");
      ExpertRemove();
      return;
   }

   if(EnableProfitTarget && ProfitTargetAmount <= 0)
   {
      Print("ERROR: Profit target amount must be positive (", ProfitTargetAmount, ")");
      Alert("PeriodProfitStopEA: 利益目標金額は正の数である必要があります。");
      ExpertRemove();
      return;
   }

   if(EnableLossLimit && LossLimitAmount <= 0)
   {
      Print("ERROR: Loss limit amount must be positive (", LossLimitAmount, ")");
      Alert("PeriodProfitStopEA: 損失制限金額は正の数である必要があります。");
      ExpertRemove();
      return;
   }

   // 入力パラメータを検証してグローバル変数に格納
   g_maxRetries = MaxRetries;
   g_retryDelay = RetryDelay;

   if(g_maxRetries < 1)
   {
      Print("WARNING: MaxRetries is too small (", MaxRetries, "). Setting to default value 3.");
      g_maxRetries = 3;
   }

   if(g_retryDelay < 100)
   {
      Print("WARNING: RetryDelay is too small (", RetryDelay, " ms). Setting to minimum 100ms.");
      g_retryDelay = 100;
   }

   // 期間開始時刻の設定
   if(PeriodMode == PERIOD_FROM_STARTUP)
   {
      g_periodStartTime = TimeCurrent();
      Print("Period mode: From EA startup");
   }
   else
   {
      g_periodStartTime = StartDateTime;
      Print("Period mode: From specified datetime: ", TimeToString(g_periodStartTime, TIME_DATE|TIME_MINUTES));
   }

   // 開始残高を取得
   g_periodStartBalance = PPSEA_AccountBalance();

   // フラグ初期化
   g_targetReached = false;
   g_eaStopped = false;
   g_pendingAutoTradingStop = false;
   g_pendingStopStartTime = 0;
   g_lastAutoTradingEnabled = IsAutoTradingEnabled();

   // 表示キャッシュ初期化
   g_lastDisplayedBalance = 0;
   g_lastDisplayedProfit = 0;
   g_lastDisplayedProgress = 0;

#ifdef __MQL5__
   // CTrade設定
   g_trade.SetDeviationInPoints(10);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
#endif

   // 表示初期化
   CreateDisplay();
   UpdateDisplay();

   Print("===========================================");
   Print("PeriodProfitStopEA v1.0 initialized");
   Print("Period start time: ", TimeToString(g_periodStartTime, TIME_DATE|TIME_MINUTES));
   Print("Period start balance: ", DoubleToString(g_periodStartBalance, 2));
   if(EnableProfitTarget)
      Print("Profit target: ", DoubleToString(ProfitTargetAmount, 2));
   if(EnableLossLimit)
      Print("Loss limit: ", DoubleToString(LossLimitAmount, 2));
   Print("Target action: ", (TargetAction == ACTION_CLOSE_AND_STOP ? "Close all + Stop" : "Stop only"));
   Print("Max retry attempts: ", g_maxRetries);
   Print("Magic number filter: ", MagicNumber == 0 ? "Disabled (all positions)" : IntegerToString(MagicNumber));
   Print("===========================================");
}

//+------------------------------------------------------------------+
//| 終了処理                                                        |
//+------------------------------------------------------------------+
void PPSEA_Deinit()
{
   // オブジェクト削除
   ObjectDelete(0, g_prefix + "Background");
   ObjectDelete(0, g_prefix + "Title");
   ObjectDelete(0, g_prefix + "PeriodMode");
   ObjectDelete(0, g_prefix + "StartTime");
   ObjectDelete(0, g_prefix + "StartBalance");
   ObjectDelete(0, g_prefix + "CurrentBalance");
   ObjectDelete(0, g_prefix + "ClosedProfit");
   ObjectDelete(0, g_prefix + "OpenProfit");
   ObjectDelete(0, g_prefix + "TotalProfit");
   ObjectDelete(0, g_prefix + "ProfitTarget");
   ObjectDelete(0, g_prefix + "LossLimit");
   ObjectDelete(0, g_prefix + "Status");

   Print("PeriodProfitStopEA deinitialized");
}

//+------------------------------------------------------------------+
//| メイン処理                                                      |
//+------------------------------------------------------------------+
void PPSEA_OnTick()
{
   // 自動売買停止待機中の場合、ポジション・オーダー確認
   if(g_pendingAutoTradingStop)
   {
      // タイムアウトチェック（60秒）
      if(g_pendingStopStartTime == 0)
         g_pendingStopStartTime = TimeCurrent();

      int remainingPositions = GetFilteredPositionCount();
      int remainingOrders = GetFilteredPendingOrderCount();

      if(remainingPositions == 0 && remainingOrders == 0)
      {
         DisableAutoTrading();

         // 停止処理中に新規ポジション・オーダーが開かれていないか確認
         Sleep(500);
         int newPositions = GetFilteredPositionCount();
         int newOrders = GetFilteredPendingOrderCount();

         if(newPositions > 0 || newOrders > 0)
         {
            Print("WARNING: ", newPositions, " position(s) and ", newOrders, " order(s) opened during AutoTrading disable");
            Print("WARNING: Re-enabling AutoTrading and continuing wait");
            EnableAutoTrading();
            g_pendingStopStartTime = TimeCurrent();
         }
         else
         {
            g_pendingAutoTradingStop = false;
            g_pendingStopStartTime = 0;
            Print("All filtered positions and orders closed. AutoTrading disabled successfully.");
         }
      }
      else if(TimeCurrent() - g_pendingStopStartTime > 60)
      {
         Print("WARNING: Timeout waiting for positions/orders to close (60 seconds elapsed).");
         Print("WARNING: ", remainingPositions, " positions and ", remainingOrders, " orders still remain.");
         Print("WARNING: Disabling AutoTrading anyway. Please check manually!");
         DisableAutoTrading();
         g_pendingAutoTradingStop = false;
         g_pendingStopStartTime = 0;
      }
      else
      {
         int elapsedTime = (int)(TimeCurrent() - g_pendingStopStartTime);
         Print("Waiting for ", remainingPositions, " positions and ", remainingOrders, " orders to close... (", elapsedTime, "/60 seconds)");
      }
      UpdateDisplay();
      return;
   }

   // 自動売買の状態変化チェック（手動でONに戻された場合）
   bool currentAutoTradingEnabled = IsAutoTradingEnabled();
   if(!g_lastAutoTradingEnabled && currentAutoTradingEnabled && g_eaStopped)
   {
      // 停止状態から手動でONに戻された場合、リセットして再スタート
      Print("===========================================");
      Print("AutoTrading manually re-enabled. Resetting EA...");
      Print("===========================================");

      // 期間開始時刻をリセット
      if(PeriodMode == PERIOD_FROM_STARTUP)
      {
         g_periodStartTime = TimeCurrent();
      }
      else
      {
         g_periodStartTime = StartDateTime;
      }

      // 開始残高を再取得
      g_periodStartBalance = PPSEA_AccountBalance();

      // フラグをリセット
      g_targetReached = false;
      g_eaStopped = false;
      g_pendingAutoTradingStop = false;
      g_pendingStopStartTime = 0;

      // フォントサイズを元に戻す
      UpdateLabelSize(g_prefix + "Title", FontSize + 2);
      UpdateLabelSize(g_prefix + "PeriodMode", FontSize);
      UpdateLabelSize(g_prefix + "StartTime", FontSize);
      UpdateLabelSize(g_prefix + "StartBalance", FontSize);
      UpdateLabelSize(g_prefix + "CurrentBalance", FontSize);
      UpdateLabelSize(g_prefix + "ClosedProfit", FontSize);
      UpdateLabelSize(g_prefix + "OpenProfit", FontSize);
      UpdateLabelSize(g_prefix + "TotalProfit", FontSize + 1);
      UpdateLabelSize(g_prefix + "ProfitTarget", FontSize);
      UpdateLabelSize(g_prefix + "LossLimit", FontSize);
      UpdateLabelSize(g_prefix + "Status", FontSize + 1);

      Print("EA restarted from: ", TimeToString(g_periodStartTime, TIME_DATE|TIME_MINUTES));
      Print("New start balance: ", DoubleToString(g_periodStartBalance, 2));
   }
   g_lastAutoTradingEnabled = currentAutoTradingEnabled;

   // EA停止中の場合は表示のみ更新
   if(g_eaStopped)
   {
      UpdateDisplay();
      return;
   }

   // 累計損益計算
   double closedProfit = GetClosedTradesProfit();
   double openProfit = GetFilteredPositionsProfit();
   double totalProfit = closedProfit + openProfit;

   // 利益目標達成チェック
   if(EnableProfitTarget && !g_targetReached && totalProfit >= ProfitTargetAmount)
   {
      OnTargetReached(totalProfit, true);
   }
   // 損失制限達成チェック
   else if(EnableLossLimit && !g_targetReached && totalProfit <= -LossLimitAmount)
   {
      OnTargetReached(totalProfit, false);
   }

   // 表示更新
   UpdateDisplay();
}

//+------------------------------------------------------------------+
//| 目標達成時の処理                                                |
//+------------------------------------------------------------------+
void OnTargetReached(double profit, bool isProfitTarget)
{
   g_targetReached = true;
   g_eaStopped = true;

   Print("===========================================");
   if(isProfitTarget)
   {
      Print("Profit target reached! Total profit: ", DoubleToString(profit, 2));
   }
   else
   {
      Print("Loss limit reached! Total loss: ", DoubleToString(profit, 2));
   }
   Print("===========================================");

   // サウンド通知
   if(EnableSound)
   {
      PlaySound(SoundFile);
   }

   // アクション実行
   if(TargetAction == ACTION_CLOSE_AND_STOP)
   {
      Print("Closing all positions...");
      CloseAllPositions();

      // 決済後のポジション数とオーダー数を確認
      int remainingPositions = GetFilteredPositionCount();
      int remainingOrders = GetFilteredPendingOrderCount();

      if(remainingPositions == 0 && remainingOrders == 0)
      {
         DisableAutoTrading();
         Print("All positions and orders closed successfully. AutoTrading disabled.");
      }
      else
      {
         g_pendingAutoTradingStop = true;
         Print("EA stopped. ", remainingPositions, " positions and ", remainingOrders, " orders remain.");
         Print("Waiting for all positions and orders to close before disabling AutoTrading.");
      }
   }
   else if(TargetAction == ACTION_STOP_ONLY)
   {
      DisableAutoTrading();
      Print("EA stopped and AutoTrading disabled (positions remain open).");
   }
}

//+------------------------------------------------------------------+
//| 全ポジション決済                                                |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   int maxConsecutiveFailures = g_maxRetries;
   int consecutiveFailures = 0;
   int totalClosed = 0;
   int totalAttempts = 0;
   const int MAX_TOTAL_ATTEMPTS = g_maxRetries * 10;

   Print("Starting CloseAllPositions");
   Print("Magic number filter: ", MagicNumber == 0 ? "None (all positions)" : IntegerToString(MagicNumber));

   while(consecutiveFailures < maxConsecutiveFailures && totalAttempts < MAX_TOTAL_ATTEMPTS)
   {
      totalAttempts++;

#ifdef __MQL5__
      ulong tickets[];
#else
      int tickets[];
#endif
      int ticketCount = 0;
      int total = PPSEA_OrdersTotal();

      for(int i = 0; i < total; i++)
      {
         if(!PPSEA_OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;

         // マジックナンバーフィルター
         if(MagicNumber != 0)
         {
#ifdef __MQL5__
            long posMagic = PositionGetInteger(POSITION_MAGIC);
#else
            int posMagic = OrderMagicNumber();
#endif
            if(posMagic != MagicNumber)
               continue;
         }

         // ポジションタイプチェック
         int type = PPSEA_OrderType();
         if(type != OP_BUY && type != OP_SELL)
            continue;

         // チケット収集
         ArrayResize(tickets, ticketCount + 1);
#ifdef __MQL5__
         tickets[ticketCount] = (ulong)PPSEA_OrderTicket();
#else
         tickets[ticketCount] = (int)PPSEA_OrderTicket();
#endif
         ticketCount++;
      }

      if(ticketCount == 0)
      {
         Print("All target positions closed. Total closed: ", totalClosed);
         return;
      }

      Print("Round ", totalAttempts, ": Found ", ticketCount, " positions to close");

      int closedThisRound = 0;

      for(int i = 0; i < ticketCount; i++)
      {
         if(!PPSEA_OrderSelect(tickets[i], SELECT_BY_TICKET))
         {
            Print("Position #", tickets[i], " no longer exists (already closed)");
            closedThisRound++;
            continue;
         }

         string symbol = PPSEA_OrderSymbol();
         int type = PPSEA_OrderType();
         double lots = PPSEA_OrderLots();

         double closePrice = (type == OP_BUY) ?
                            PPSEA_MarketInfo(symbol, MODE_BID) :
                            PPSEA_MarketInfo(symbol, MODE_ASK);

         if(closePrice <= 0)
         {
            Print("ERROR: Invalid price for ", symbol);
            continue;
         }

#ifdef __MQL5__
         bool success = PPSEA_OrderClose((ulong)tickets[i], lots, closePrice, 3);
#else
         bool success = PPSEA_OrderClose(tickets[i], lots, closePrice, 3);
#endif

         if(success)
         {
            closedThisRound++;
            totalClosed++;
            Print("Closed #", tickets[i], " (", symbol, " ",
                  (type == OP_BUY ? "BUY" : "SELL"), " ", lots, " lots)");
            Sleep(100);
         }
         else
         {
            int error = GetLastError();
            if(error == 138 || error == 135)
            {
               Print("Requote for #", tickets[i], " - will retry");
            }
            else
            {
               Print("Failed to close #", tickets[i], " ", symbol,
                     " Error: ", error, " - ", ErrorDescription(error));
            }
         }
      }

      Print("Round ", totalAttempts, " result: Closed ", closedThisRound, "/", ticketCount);

      if(closedThisRound > 0)
      {
         consecutiveFailures = 0;
         Sleep(g_retryDelay / 2);
      }
      else
      {
         consecutiveFailures++;
         Print("No progress. Consecutive failures: ", consecutiveFailures, "/", maxConsecutiveFailures);

         if(consecutiveFailures < maxConsecutiveFailures)
         {
            Sleep(g_retryDelay);
         }
      }
   }

   int remaining = GetFilteredPositionCount();

   if(remaining > 0)
   {
      Print("WARNING: ", remaining, " target positions remain after ", totalAttempts, " attempts");
      Print("Total closed: ", totalClosed);
      Alert("PeriodProfitStopEA: ", remaining, " positions failed to close! Manual intervention required.");
   }
   else
   {
      Print("SUCCESS: All target positions closed. Total: ", totalClosed, " in ", totalAttempts, " attempts");
   }
}

//+------------------------------------------------------------------+
//| 表示作成                                                        |
//+------------------------------------------------------------------+
void CreateDisplay()
{
   // 背景パネルの作成
   int panelWidth = 400;
   int panelHeight = 360;
   CreatePanel(g_prefix + "Background", DisplayX - 5, DisplayY - 5, panelWidth, panelHeight);

   int y = DisplayY;
   int lineHeight = 26;  // 行間を広げる

   CreateLabel(g_prefix + "Title", "■ 期間累計損益ストップEA", DisplayX, y, clrWhite, FontSize + 2, true);
   y += 35;

   CreateLabel(g_prefix + "PeriodMode", "", DisplayX, y, clrSilver, FontSize);
   y += lineHeight;

   CreateLabel(g_prefix + "StartTime", "", DisplayX, y, clrGray, FontSize);
   y += lineHeight;

   CreateLabel(g_prefix + "StartBalance", "", DisplayX, y, clrSilver, FontSize);
   y += lineHeight;

   CreateLabel(g_prefix + "CurrentBalance", "", DisplayX, y, clrSilver, FontSize);
   y += lineHeight + 5;

   CreateLabel(g_prefix + "ClosedProfit", "", DisplayX, y, clrWhite, FontSize);
   y += lineHeight;

   CreateLabel(g_prefix + "OpenProfit", "", DisplayX, y, clrWhite, FontSize);
   y += lineHeight;

   CreateLabel(g_prefix + "TotalProfit", "", DisplayX, y, clrWhite, FontSize + 1, true);
   y += 32;

   CreateLabel(g_prefix + "ProfitTarget", "", DisplayX, y, clrGold, FontSize);
   y += lineHeight;

   CreateLabel(g_prefix + "LossLimit", "", DisplayX, y, clrOrangeRed, FontSize);
   y += lineHeight + 5;

   CreateLabel(g_prefix + "Status", "", DisplayX, y, clrWhite, FontSize + 1);
}

//+------------------------------------------------------------------+
//| 表示更新                                                        |
//+------------------------------------------------------------------+
void UpdateDisplay()
{
   double currentBalance = PPSEA_AccountBalance();
   double closedProfit = GetClosedTradesProfit();
   double openProfit = GetFilteredPositionsProfit();
   double totalProfit = closedProfit + openProfit;

   // 変化チェック（最適化）
   double balanceDiff = MathAbs(currentBalance - g_lastDisplayedBalance);
   double profitDiff = MathAbs(totalProfit - g_lastDisplayedProfit);

   if(balanceDiff < 0.01 && profitDiff < 0.01 && !g_targetReached)
   {
      return;
   }

   g_lastDisplayedBalance = currentBalance;
   g_lastDisplayedProfit = totalProfit;

   // 停止時の全体カラーとサイズ設定
   color baseColor = clrSilver;
   color grayColor = clrGray;

   if(g_targetReached)
   {
      // 停止時：損益に応じて全体の色を変更し、フォントサイズを増加
      if(totalProfit >= 0)
      {
         baseColor = clrLime;
         grayColor = clrLime;
      }
      else
      {
         baseColor = clrRed;
         grayColor = clrRed;
      }

      // フォントサイズを更新（パラメーター指定の追加サイズ）
      UpdateLabelSize(g_prefix + "Title", FontSize + 2 + FontSizeStopAdd);
      UpdateLabelSize(g_prefix + "PeriodMode", FontSize + FontSizeStopAdd);
      UpdateLabelSize(g_prefix + "StartTime", FontSize + FontSizeStopAdd);
      UpdateLabelSize(g_prefix + "StartBalance", FontSize + FontSizeStopAdd);
      UpdateLabelSize(g_prefix + "CurrentBalance", FontSize + FontSizeStopAdd);
      UpdateLabelSize(g_prefix + "ClosedProfit", FontSize + FontSizeStopAdd);
      UpdateLabelSize(g_prefix + "OpenProfit", FontSize + FontSizeStopAdd);
      UpdateLabelSize(g_prefix + "TotalProfit", FontSize + 1 + FontSizeStopAdd);
      UpdateLabelSize(g_prefix + "ProfitTarget", FontSize + FontSizeStopAdd);
      UpdateLabelSize(g_prefix + "LossLimit", FontSize + FontSizeStopAdd);
      UpdateLabelSize(g_prefix + "Status", FontSize + 1 + FontSizeStopAdd);
   }

   // 停止時以外の基本色を調整
   color periodModeColor = g_targetReached ? baseColor : clrWhiteSmoke;
   color startTimeColor = g_targetReached ? grayColor : clrWhiteSmoke;
   color balanceColor = g_targetReached ? baseColor : clrWhiteSmoke;

   // 期間モード表示
   string periodModeText = (PeriodMode == PERIOD_FROM_STARTUP) ? "計算期間: EA起動時から" : "計算期間: 指定日時から";
   UpdateLabel(g_prefix + "PeriodMode", periodModeText, periodModeColor);

   // 開始時刻表示
   UpdateLabel(g_prefix + "StartTime", "開始: " + TimeToString(g_periodStartTime, TIME_DATE|TIME_MINUTES), startTimeColor);

   // 残高表示
   UpdateLabel(g_prefix + "StartBalance", "開始残高: " + FormatMoney(g_periodStartBalance, 2), balanceColor);
   UpdateLabel(g_prefix + "CurrentBalance", "現在残高: " + FormatMoney(currentBalance, 2), balanceColor);

   // 損益表示
   color closedColor = g_targetReached ? baseColor : ((closedProfit >= 0) ? clrLime : clrRed);
   color openColor = g_targetReached ? baseColor : ((openProfit >= 0) ? clrLime : clrRed);
   color totalColor = g_targetReached ? baseColor : ((totalProfit >= 0) ? clrLime : clrRed);

   UpdateLabel(g_prefix + "ClosedProfit", "決済済損益: " + FormatMoney(closedProfit, 2), closedColor);
   UpdateLabel(g_prefix + "OpenProfit", "含み損益: " + FormatMoney(openProfit, 2), openColor);
   UpdateLabel(g_prefix + "TotalProfit", "累計損益: " + FormatMoney(totalProfit, 2), totalColor);

   // 目標表示
   if(EnableProfitTarget)
   {
      double profitRemaining = ProfitTargetAmount - totalProfit;
      string profitText = (totalProfit >= ProfitTargetAmount) ? "利益目標達成!" : "利益目標まで: " + FormatMoney(profitRemaining, 2);
      color profitTargetColor = g_targetReached ? baseColor : ((totalProfit >= ProfitTargetAmount) ? clrLime : clrGold);
      UpdateLabel(g_prefix + "ProfitTarget", profitText, profitTargetColor);
   }
   else
   {
      UpdateLabel(g_prefix + "ProfitTarget", "利益目標: 無効", g_targetReached ? baseColor : clrGray);
   }

   if(EnableLossLimit)
   {
      double lossRemaining = LossLimitAmount + totalProfit;
      string lossText = (totalProfit <= -LossLimitAmount) ? "損失制限到達!" : "損失制限まで: " + FormatMoney(lossRemaining, 2);
      color lossLimitColor = g_targetReached ? baseColor : ((totalProfit <= -LossLimitAmount) ? clrRed : clrOrangeRed);
      UpdateLabel(g_prefix + "LossLimit", lossText, lossLimitColor);
   }
   else
   {
      UpdateLabel(g_prefix + "LossLimit", "損失制限: 無効", g_targetReached ? baseColor : clrGray);
   }

   // ステータス表示
   if(g_targetReached)
   {
      UpdateLabel(g_prefix + "Status", "状態: 目標達成(停止)", baseColor);
   }
   else
   {
      UpdateLabel(g_prefix + "Status", "状態: 稼働中", clrLime);
   }
}

//+------------------------------------------------------------------+
//| パネル作成                                                      |
//+------------------------------------------------------------------+
void CreatePanel(string name, int x, int y, int width, int height)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'25,25,35');  // 濃い青みがかったグレー
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_COLOR, C'60,60,80');     // 枠線の色
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);            // 前面に表示
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);              // 最前面
   }
}

//+------------------------------------------------------------------+
//| ラベル作成                                                      |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr, int size, bool bold = false)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);

      string fontToUse = FontName;
      if(bold && (FontName == "Arial" || FontName == "Tahoma"))
      {
         fontToUse = FontName + " Bold";
      }
      ObjectSetString(0, name, OBJPROP_FONT, fontToUse);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }

   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| ラベル更新                                                      |
//+------------------------------------------------------------------+
void UpdateLabel(string name, string text, color clr)
{
   if(ObjectFind(0, name) >= 0)
   {
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   }
}

//+------------------------------------------------------------------+
//| ラベルサイズ更新                                                |
//+------------------------------------------------------------------+
void UpdateLabelSize(string name, int size)
{
   if(ObjectFind(0, name) >= 0)
   {
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   }
}
