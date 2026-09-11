//+------------------------------------------------------------------+
//|                                AsianBreakout_ATR_BE_Filtered.mq5 |
//|          Bot Phien A + BE + Bo Loc + Weekly Schedule + Hidden SL/TP |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "3.06"

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "--- Thoi gian Phien A ---"
input int      InpAsiaStartHour     = 0;        // Gio bat dau phien A
input int      InpAsiaEndHour       = 8;        // Gio ket thuc phien A

input group "--- LICHI LAM VIEC & TP THEO THU TRONG TUAN ---"
input bool     InpEnableMonday      = false;    // Chay Bot vao Thu 2?
input double   InpTP_ATR_Mon        = 3.0;      // TP x ATR cho Thu 2

input bool     InpEnableTuesday     = true;     // Chay Bot vao Thu 3?
input double   InpTP_ATR_Tue        = 3.0;      // TP x ATR cho Thu 3

input bool     InpEnableWednesday   = true;     // Chay Bot vao Thu 4?
input double   InpTP_ATR_Wed        = 3.0;      // TP x ATR cho Thu 4

input bool     InpEnableThursday    = true;     // Chay Bot vao Thu 5?
input double   InpTP_ATR_Thu        = 6.0;      // TP x ATR cho Thu 5

input bool     InpEnableFriday      = true;     // Chay Bot vao Thu 6?
input double   InpTP_ATR_Fri        = 6.0;      // TP x ATR cho Thu 6

input group "--- Quan ly Rui ro theo ATR ---"
input double   InpLotSize           = 0.05;     // Khoi luong vao lenh
input int      InpATRPeriod         = 14;       // Chu ky ATR
input double   InpSL_ATR_Mult       = 1.5;      // Stop Loss = 1.5 x ATR
input int      InpEMAPeriod         = 200;      // Duong xu huong EMA 200 (H1)
input ulong    InpMagicNumber       = 782026;   // Magic Number

input group "--- Quan ly Hoa von (Breakeven) ---"
input bool     InpUseBreakeven      = true;     // Bat/Tat tinh nang doi SL ve Hoa von
input double   InpBE_Trigger_ATR    = 1.5;      // Lai dat bao nhieu x ATR thi kich hoat Breakeven
input double   InpBE_Lock_Pips      = 1.0;      // So Pips cong them de bu Spread/Phi

input group "--- BỘ LỌC CHỐNG BẪY & CHUỖI THUA ---"
input bool     InpUseFilterRange    = true;     // Bat/Tat bo loc Bien do Phien A
input double   InpMinAsiaRange_ATR  = 0.8;      // Bien do A toi thieu (x ATR) - Tranh sideway nen
input double   InpMaxAsiaRange_ATR  = 2.5;      // Bien do A toi da (x ATR) - Tranh giat 2 dau
input bool     InpUseFilterExhaust  = true;     // Bat/Tat bo loc Nen Breakout kiet suc
input double   InpMaxBreakout_ATR   = 2.0;      // Do dai nến Breakout toi da (x ATR)

input group "--- HIDDEN SL/TP (Chống quét lệnh) ---"
input bool     InpUseHiddenSLTP     = false;    // Bat/Tat che do An SL/TP thuc te
input double   InpHiddenSL_Buffer_ATR = 0.5;    // SL gui len san = SL that + bao nhieu x ATR (đệm an toàn)
input double   InpHiddenTP_Buffer_ATR = 1.0;    // TP gui len san = TP that + bao nhieu x ATR (đệm an toàn)
input int      InpHiddenCheckSeconds  = 1;      // Khoang cach (giay) giua 2 lan kiem tra gia real-time

CTrade         trade;
datetime       g_lastTradeDate      = 0;
double         g_asiaHigh           = 0.0;
double         g_asiaLow            = 0.0;
bool           g_asiaRangeSet       = false;
int            g_emaHandle;
int            g_atrHandle;
datetime       g_lastHiddenCheck    = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);

   uint fillType = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillType & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillType & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);

   g_emaHandle = iMA(_Symbol, PERIOD_H1, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle = iATR(_Symbol, PERIOD_H1, InpATRPeriod);

   if(g_emaHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
   {
      Print("Loi khoi tao Handle Indicator!");
      return(INIT_FAILED);
   }

   Print("Bot AsianBreakout_ATR_BE_Filtered v3.06 (Weekly Schedule + Hidden SL/TP) khoi tao thanh cong!");
   if(InpUseHiddenSLTP)
      Print("⚠️ Che do Hidden SL/TP dang BAT - SL/TP that duoc EA tu quan ly noi bo, khong gui het len san.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_emaHandle);
   IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // ==== 1. Quản lý Hidden SL/TP (chạy trước tiên, ưu tiên cao nhất để bảo vệ vốn) ====
   if(InpUseHiddenSLTP)
   {
      // Giới hạn tần suất kiểm tra để giảm tải (mặc định mỗi giây), tránh spam CPU mỗi tick
      if(TimeCurrent() - g_lastHiddenCheck >= InpHiddenCheckSeconds)
      {
         CheckAndApplyHiddenSLTP();
         g_lastHiddenCheck = TimeCurrent();
      }
   }

   // ==== 2. Quản lý Breakeven ====
   if(InpUseBreakeven)
   {
      CheckAndApplyBreakeven();
   }

   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));

   // Reset thông số phiên Á khi sang ngày mới
   if(today != g_lastTradeDate && dt.hour < InpAsiaEndHour)
   {
      g_asiaRangeSet = false;
      g_asiaHigh     = 0.0;
      g_asiaLow      = 0.0;
   }

   // KIỂM TRA BOT CÓ ĐƯỢC PHÉP CHẠY HÔM NAY KHÔNG?
   if(!IsDayEnabled(dt.day_of_week)) return;

   // Tính biên độ phiên Á sau khi hết giờ phiên Á
   if(dt.hour >= InpAsiaEndHour && !g_asiaRangeSet)
   {
      CalculateAsiaRange(today);
   }

   // Kiểm tra tín hiệu vào lệnh
   if(g_asiaRangeSet && dt.hour >= InpAsiaEndHour)
   {
      if(g_lastTradeDate != today && CountOpenPositions() == 0)
      {
         CheckAndExecute(today, dt.day_of_week);
      }
   }
}

//+------------------------------------------------------------------+
//| KIỂM TRA BẬT/TẮT THEO THỨ                                         |
//+------------------------------------------------------------------+
bool IsDayEnabled(int dayOfWeek)
{
   switch(dayOfWeek)
   {
      case 1: return InpEnableMonday;    // Thứ 2
      case 2: return InpEnableTuesday;   // Thứ 3
      case 3: return InpEnableWednesday; // Thứ 4
      case 4: return InpEnableThursday;  // Thứ 5
      case 5: return InpEnableFriday;    // Thứ 6
      default: return false;             // Thứ 7 & CN bỏ qua
   }
}

//+------------------------------------------------------------------+
//| LẤY HỆ SỐ TP ATR THEO THỨ                                        |
//+------------------------------------------------------------------+
double GetTPMultForDay(int dayOfWeek)
{
   switch(dayOfWeek)
   {
      case 1: return InpTP_ATR_Mon;
      case 2: return InpTP_ATR_Tue;
      case 3: return InpTP_ATR_Wed;
      case 4: return InpTP_ATR_Thu;
      case 5: return InpTP_ATR_Fri;
      default: return 3.0; // Mặc định nếu lỗi
   }
}

//+------------------------------------------------------------------+
//| TÍNH BIÊN ĐỘ PHIÊN Á                                              |
//+------------------------------------------------------------------+
void CalculateAsiaRange(datetime today)
{
   datetime startTime = today + InpAsiaStartHour * 3600;
   datetime endTime   = today + InpAsiaEndHour * 3600 - 1;

   MqlRates rates[];
   ArraySetAsSeries(rates, false);

   int copied = CopyRates(_Symbol, PERIOD_H1, startTime, endTime, rates);
   if(copied > 0)
   {
      g_asiaHigh = rates[0].high;
      g_asiaLow  = rates[0].low;

      for(int i = 1; i < copied; i++)
      {
         if(rates[i].high > g_asiaHigh) g_asiaHigh = rates[i].high;
         if(rates[i].low  < g_asiaLow)  g_asiaLow  = rates[i].low;
      }

      g_asiaRangeSet = true;
   }
}

//+------------------------------------------------------------------+
//| KIỂM TRA ĐIỀU KIỆN & VÀO LỆNH (CÓ LỊCH TP THEO THỨ + HIDDEN SL/TP)|
//+------------------------------------------------------------------+
void CheckAndExecute(datetime today, int dayOfWeek)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_H1, 0, 2, rates) < 2) return;

   double ema[], atr[];
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(g_emaHandle, 0, 0, 2, ema) < 2) return;
   if(CopyBuffer(g_atrHandle, 0, 0, 2, atr) < 2) return;

   double currentATR = atr[1];
   double asiaRangeHeight = g_asiaHigh - g_asiaLow;

   // BỘ LỌC 1: KIỂM TRA BIÊN ĐỘ PHIÊN Á
   if(InpUseFilterRange)
   {
      if(asiaRangeHeight < (currentATR * InpMinAsiaRange_ATR)) return;
      if(asiaRangeHeight > (currentATR * InpMaxAsiaRange_ATR)) return;
   }

   // BỘ LỌC 2: KIỂM TRA NẾN BREAKOUT KIỆT SỨC
   double breakoutCandleSize = MathAbs(rates[1].close - rates[1].open);
   if(InpUseFilterExhaust && (breakoutCandleSize > currentATR * InpMaxBreakout_ATR)) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Lấy hệ số TP ATR tương ứng với thứ trong tuần hiện tại
   double tpMult = GetTPMultForDay(dayOfWeek);

   double slDistance = currentATR * InpSL_ATR_Mult;
   double tpDistance = currentATR * tpMult;

   // Khoảng đệm an toàn cho SL/TP "ẩn" (chỉ dùng nếu InpUseHiddenSLTP = true)
   double slBufferDistance = currentATR * InpHiddenSL_Buffer_ATR;
   double tpBufferDistance = currentATR * InpHiddenTP_Buffer_ATR;

   // BUY
   if(rates[1].close > g_asiaHigh && rates[1].close > ema[1])
   {
      double realSL   = NormalizeDouble(ask - slDistance, _Digits);
      double realTP   = NormalizeDouble(ask + tpDistance, _Digits);

      // SL/TP thực tế gửi lên sàn: nếu Hidden Mode bật -> gửi mức RỘNG HƠN (lưới an toàn),
      // nếu tắt -> gửi đúng mức thật như code gốc (hành vi mặc định không đổi)
      double serverSL = InpUseHiddenSLTP ? NormalizeDouble(realSL - slBufferDistance, _Digits) : realSL;
      double serverTP = InpUseHiddenSLTP ? NormalizeDouble(realTP + tpBufferDistance, _Digits) : realTP;

      if(trade.Buy(InpLotSize, _Symbol, ask, serverSL, serverTP, "Asian ATR Buy"))
      {
         g_lastTradeDate = today;
         PrintFormat("-> MỞ BUY THÀNH CÔNG! [Thứ: %d | TP Mult: %.1fxATR]", dayOfWeek, tpMult);
         if(InpUseHiddenSLTP)
            SaveHiddenLevels(realSL, realTP);
      }
   }
   // SELL
   else if(rates[1].close < g_asiaLow && rates[1].close < ema[1])
   {
      double realSL   = NormalizeDouble(bid + slDistance, _Digits);
      double realTP   = NormalizeDouble(bid - tpDistance, _Digits);

      double serverSL = InpUseHiddenSLTP ? NormalizeDouble(realSL + slBufferDistance, _Digits) : realSL;
      double serverTP = InpUseHiddenSLTP ? NormalizeDouble(realTP - tpBufferDistance, _Digits) : realTP;

      if(trade.Sell(InpLotSize, _Symbol, bid, serverSL, serverTP, "Asian ATR Sell"))
      {
         g_lastTradeDate = today;
         PrintFormat("-> MỞ SELL THÀNH CÔNG! [Thứ: %d | TP Mult: %.1fxATR]", dayOfWeek, tpMult);
         if(InpUseHiddenSLTP)
            SaveHiddenLevels(realSL, realTP);
      }
   }
}

//+------------------------------------------------------------------+
//| LƯU MỨC SL/TP THẬT (ẨN) VÀO GLOBAL VARIABLE THEO TICKET           |
//| Dùng Global Variable của Terminal -> vẫn còn nguyên nếu EA restart|
//+------------------------------------------------------------------+
void SaveHiddenLevels(double realSL, double realTP)
{
   // Sau khi lệnh vừa mở thành công, vì EA chỉ cho phép tối đa 1 lệnh/lúc (CountOpenPositions==0),
   // nên vị thế vừa mở chắc chắn là vị thế duy nhất hiện có cho Symbol + Magic này.
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         GlobalVariableSet("HSL_" + IntegerToString(ticket), realSL);
         GlobalVariableSet("HTP_" + IntegerToString(ticket), realTP);
         PrintFormat("   [Hidden] Đã lưu SL thật=%.2f, TP thật=%.2f cho ticket #%d (SL/TP gửi sàn ở mức rộng hơn)",
                     realSL, realTP, ticket);
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| GIÁM SÁT & ĐÓNG LỆNH TẠI ĐÚNG MỨC SL/TP THẬT (ẨN VỚI SÀN)         |
//+------------------------------------------------------------------+
void CheckAndApplyHiddenSLTP()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ulong  ticket = PositionGetInteger(POSITION_TICKET);
      long   type   = PositionGetInteger(POSITION_TYPE);

      string hslName = "HSL_" + IntegerToString(ticket);
      string htpName = "HTP_" + IntegerToString(ticket);

      // Nếu lệnh này không có mức Hidden lưu sẵn (VD: lệnh cũ từ trước khi bật tính năng), bỏ qua
      if(!GlobalVariableCheck(hslName) || !GlobalVariableCheck(htpName))
         continue;

      double realSL = GlobalVariableGet(hslName);
      double realTP = GlobalVariableGet(htpName);

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      bool shouldClose = false;
      string reason = "";

      if(type == POSITION_TYPE_BUY)
      {
         if(bid <= realSL) { shouldClose = true; reason = "Hidden SL"; }
         else if(bid >= realTP) { shouldClose = true; reason = "Hidden TP"; }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         if(ask >= realSL) { shouldClose = true; reason = "Hidden SL"; }
         else if(ask <= realTP) { shouldClose = true; reason = "Hidden TP"; }
      }

      if(shouldClose)
      {
         if(trade.PositionClose(ticket))
         {
            PrintFormat("   [Hidden] Đã đóng lệnh #%d tại mức %s (thực tế, ẩn với sàn)", ticket, reason);
            GlobalVariableDel(hslName);
            GlobalVariableDel(htpName);
         }
      }
   }

   // Dọn dẹp Global Variable mồ côi (lệnh đã đóng qua đường khác, VD SL/TP rộng trên sàn bị chạm trước)
   CleanupOrphanedHiddenLevels();
}

//+------------------------------------------------------------------+
//| DỌN DẸP GLOBAL VARIABLE CỦA CÁC LỆNH ĐÃ ĐÓNG (TRÁNH RÁC TÍCH TỤ)  |
//+------------------------------------------------------------------+
void CleanupOrphanedHiddenLevels()
{
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, "HSL_") != 0 && StringFind(name, "HTP_") != 0)
         continue;

      string ticketStr = StringSubstr(name, 4);
      ulong  ticket     = (ulong)StringToInteger(ticketStr);

      if(!PositionSelectByTicket(ticket))
      {
         // Lệnh không còn tồn tại (đã đóng qua SL/TP rộng trên sàn, hoặc đóng tay) -> xóa biến rác
         GlobalVariableDel(name);
      }
   }
}

//+------------------------------------------------------------------+
//| LOGIC DỜI STOP LOSS VỀ HÒA VỐN (BREAKEVEN)                        |
//| Nếu Hidden Mode BẬT: chỉ cập nhật mức SL "thật" nội bộ, KHÔNG      |
//| gửi lệnh sửa SL lên sàn -> giữ bí mật vị trí thoát lệnh với sàn.  |
//+------------------------------------------------------------------+
void CheckAndApplyBreakeven()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 2, atr) < 2) return;

   double triggerDistance = atr[1] * InpBE_Trigger_ATR;
   double lockOffset      = InpBE_Lock_Pips * _Point * 10;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         ulong  ticket     = PositionGetInteger(POSITION_TICKET);
         long   type       = PositionGetInteger(POSITION_TYPE);
         double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL  = PositionGetDouble(POSITION_SL);
         double currentTP  = PositionGetDouble(POSITION_TP);

         if(type == POSITION_TYPE_BUY)
         {
            double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double newSL      = NormalizeDouble(openPrice + lockOffset, _Digits);

            if(currentBid - openPrice >= triggerDistance)
            {
               if(InpUseHiddenSLTP)
               {
                  // Chỉ cập nhật mức SL "thật" nội bộ (Global Variable), KHÔNG đụng vào SL trên sàn
                  string hslName = "HSL_" + IntegerToString(ticket);
                  if(GlobalVariableCheck(hslName))
                  {
                     double currentHiddenSL = GlobalVariableGet(hslName);
                     if(currentHiddenSL < newSL)
                        GlobalVariableSet(hslName, newSL);
                  }
               }
               else if(currentSL < newSL)
               {
                  trade.PositionModify(ticket, newSL, currentTP);
               }
            }
         }
         else if(type == POSITION_TYPE_SELL)
         {
            double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double newSL      = NormalizeDouble(openPrice - lockOffset, _Digits);

            if(openPrice - currentAsk >= triggerDistance)
            {
               if(InpUseHiddenSLTP)
               {
                  string hslName = "HSL_" + IntegerToString(ticket);
                  if(GlobalVariableCheck(hslName))
                  {
                     double currentHiddenSL = GlobalVariableGet(hslName);
                     if(currentHiddenSL > newSL || currentHiddenSL == 0)
                        GlobalVariableSet(hslName, newSL);
                  }
               }
               else if(currentSL > newSL || currentSL == 0)
               {
                  trade.PositionModify(ticket, newSL, currentTP);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ĐẾM SỐ LỆNH ĐANG MỞ                                              |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol)
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            count++;
      }
   }
   return count;
}