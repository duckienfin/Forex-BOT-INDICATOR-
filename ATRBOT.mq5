//+------------------------------------------------------------------+
//|                                    Breakout_Virtual_Pending.mq5  |
//|                                  Copyright 2026, Gemini Assistant |
//+------------------------------------------------------------------+
#property copyright "Gemini Assistant"
#property link      ""
#property version   "1.08"
#property strict

#include <Trade\Trade.mqh>

//--- ENUM LOẠI LỆNH ẢO
enum ENUM_VIRTUAL_TYPE
  {
   VIRTUAL_NONE = 0,
   VIRTUAL_BUY  = 1,
   VIRTUAL_SELL = 2
  };

//--- CẤU TRÚC LƯU LỆNH CHỜ ẢO
struct VirtualOrder
  {
   ENUM_VIRTUAL_TYPE type;          // Loại lệnh ảo (BUY / SELL)
   double            limitPrice;    // Mức giá Limit chờ khớp
   double            sl;            // Mức giá Stop Loss
   double            tp;            // Mức giá Take Profit
   double            cancelPrice;   // Mức giá nếu chạm trước sẽ HỦY LỆNH ẢO
   datetime          expiration;    // Thời gian hết hạn lệnh chờ
   bool              active;        // Trạng thái (true: đang chờ, false: trống)
  };

//--- INPUT PARAMETERS
input group "--- Cấu hình Khung Thời Gian ---"
input ENUM_TIMEFRAMES InpTimeframe    = PERIOD_M5;   // Khung thời gian chạy thuật toán

input group "--- Cấu hình Bộ lọc Biến động ATR ---"
input int      InpATRPeriod           = 14;          // Chu kỳ ATR
input bool     InpUseMinATR           = true;        // Bật/Tắt kiểm tra ATR Tối thiểu
input double   InpMinATRValue         = 0.0005;      // Giá trị ATR tối thiểu
input bool     InpUseMaxATR           = true;        // Bật/Tắt kiểm tra ATR Tối đa
input double   InpMaxATRValue         = 0.0030;      // Giá trị ATR tối đa

input group "--- Cấu hình Biên Độ Dao Động ATR (MỚI) ---"
input bool     InpUseATRRangeFilter   = true;        // Bật/Tắt kiểm tra biên độ ATR trong N nến
input int      InpATRRangeBars        = 20;          // Số cây nến xét biên độ dao động ATR
input double   InpMaxATRRatio         = 1.5;         // Tỷ lệ ATR Max / ATR Min tối đa cho phép (Ví dụ: 1.5 = ATR không biến động quá 50%)

input group "--- Cấu hình Nến Breakout ---"
input bool     InpUseMinBodyFilter    = true;        // Bật/Tắt lọc kích thước thân nến Breakout
input double   InpMinBody_ATR_Mult    = 1.2;         // Thân nến Breakout tối thiểu theo hệ số ATR (|Close - Open| >= Mult * ATR)

input group "--- Cấu hình Vùng Range & Breakout ---"
input int      InpRangeBars           = 12;          // Số cây nến tích lũy tạo vùng Range
input ulong    InpSlippage            = 10;          // Độ trượt giá tối đa (Slippage)

input group "--- Cấu hình Fibonacci & Lệnh Chờ Ảo ---"
input double   InpFiboLevel           = 0.50;        // Mức Fibo hồi quy (0.50 = 50%, 0.618 = 61.8%)
input int      InpPendingExpireBars   = 6;           // Thời gian hết hạn lệnh chờ ảo (Số nến M5)
input bool     InpUseCancelByATR      = true;        // Bật/Tắt Hủy Lệnh Ảo khi giá đã đi xa theo hướng TP
input double   InpCancelTP_ATR_Mult   = 1.2;         // Khoảng cách ATR giá đã chạm trước để HỦY lệnh ảo

input group "--- Quản lý Rủi ro Cơ bản (SL/TP) ---"
input double   InpSL_ATR_Mult         = 1.5;         // Hệ số SL theo ATR
input double   InpTP_ATR_Mult         = 3.0;         // Hệ số TP theo ATR
input double   InpLotSize             = 0.1;         // Khối lượng vào lệnh (Lot)
input ulong    InpMagicNumber         = 123456;      // Magic Number quản lý lệnh

input group "--- Cấu hình Dời SL về Hòa Vốn (BE) ---"
input bool     InpUseBE               = true;        // Bật/Tắt dời SL về Hòa vốn
input double   InpBE_Trigger_ATR_Mult = 1.0;         // Mức lợi nhuận đạt tới để bật BE (hệ số ATR)
input double   InpBE_Profit_Pips      = 2.0;         // Pips khóa lợi nhuận bù phí Spread (pips)

input group "--- Cấu hình Thoát sớm khi Bất lợi (Adverse TP Adjustment) ---"
input bool     InpUseAdverseTP        = true;        // Bật/Tắt dời TP sớm khi bất lợi
input double   InpAdverseThreshold_ATR= 0.8;         // Ngưỡng giá đi ngược lệnh để kích hoạt (hệ số ATR)
input double   InpNewTP_Loss_ATR_Mult = 0.3;         // Mức TP mới chấp nhận cắt lỗ nhỏ (hệ số ATR)

//--- GLOBAL VARIABLES
CTrade         trade;
int            handleATR;
datetime       lastBarTime;
VirtualOrder   vOrder;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);

   handleATR = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   if(handleATR == INVALID_HANDLE)
     {
      Print("Lỗi khởi tạo chỉ báo ATR!");
      return(INIT_FAILED);
     }

   lastBarTime = 0;
   ResetVirtualOrder();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(handleATR != INVALID_HANDLE)
      IndicatorRelease(handleATR);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Kiểm tra & Khớp / Hủy Lệnh Chờ Ảo liên tục theo từng Tick giá
   ProcessVirtualOrder();

   // 2. Quản lý vị thế đang chạy
   ManageOpenPositions();

   // 3. Quét tạo tín hiệu Lệnh Ảo mới khi nến mới vừa đóng cửa
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);
   if(currentBarTime == lastBarTime) return;

   // Mảng chứa dữ liệu ATR
   double atrValues[];
   ArraySetAsSeries(atrValues, true);
   
   // Đọc số lượng ATR nến cần lấy để lọc biên độ
   int barsToCopy = MathMax(1, InpATRRangeBars);
   if(CopyBuffer(handleATR, 0, 1, barsToCopy, atrValues) < barsToCopy) return;

   double currentATR = atrValues[0]; // ATR nến index 1

   // --- LỌC ATR TỐI THIỂU VÀ TỐI ĐA CƠ BẢN ---
   if(InpUseMinATR && currentATR < InpMinATRValue) return; 
   if(InpUseMaxATR && currentATR > InpMaxATRValue) return; 

   // --- LỌC BIÊN ĐỘ DAO ĐỘNG ATR TRONG N NẾN (MỚI) ---
   if(InpUseATRRangeFilter && barsToCopy > 1)
     {
      double maxATR = atrValues[0];
      double minATR = atrValues[0];

      for(int i = 1; i < barsToCopy; i++)
        {
         if(atrValues[i] > maxATR) maxATR = atrValues[i];
         if(atrValues[i] < minATR) minATR = atrValues[i];
        }

      if(minATR > 0)
        {
         double atrRatio = maxATR / minATR;
         if(atrRatio > InpMaxATRRatio)
           {
            // Bỏ qua vì biên độ ATR biến động quá mạnh/không ổn định trong N nến qua
            return;
           }
        }
     }

   // Xác định vùng Range
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, InpTimeframe, 2, InpRangeBars, rates);
   if(copied < InpRangeBars) return;

   double rangeHigh = -1.0;
   double rangeLow  = 999999.0;

   for(int i = 0; i < copied; i++)
     {
      double bodyMax = MathMax(rates[i].open, rates[i].close);
      double bodyMin = MathMin(rates[i].open, rates[i].close);

      if(bodyMax > rangeHigh) rangeHigh = bodyMax;
      if(bodyMin < rangeLow)  rangeLow  = bodyMin;
     }

   // Thông tin nến Breakout
   MqlRates breakBar[];
   ArraySetAsSeries(breakBar, true);
   if(CopyRates(_Symbol, InpTimeframe, 1, 1, breakBar) <= 0) return;

   double breakClose = breakBar[0].close;
   double breakOpen  = breakBar[0].open;
   double candleBody = MathAbs(breakClose - breakOpen);

   // --- LỌC KÍCH THƯỚC THÂN NẾN BREAKOUT ---
   if(InpUseMinBodyFilter)
     {
      double minRequiredBody = currentATR * InpMinBody_ATR_Mult;
      if(candleBody < minRequiredBody) return;
     }

   if(HasOpenPosition() || vOrder.active) return;

   // --- THIẾT LẬP LỆNH CHỜ ẢO BUY ---
   if(breakClose > rangeHigh && breakClose > breakOpen)
     {
      double breakHigh = breakBar[0].high; 
      
      double limitPrice = breakHigh - (breakHigh - rangeLow) * InpFiboLevel;
      limitPrice = NormalizeDouble(limitPrice, _Digits);

      double sl = NormalizeDouble(limitPrice - (currentATR * InpSL_ATR_Mult), _Digits);
      double tp = NormalizeDouble(limitPrice + (currentATR * InpTP_ATR_Mult), _Digits);
      double cancelPrice = NormalizeDouble(limitPrice + (currentATR * InpCancelTP_ATR_Mult), _Digits);

      vOrder.type        = VIRTUAL_BUY;
      vOrder.limitPrice  = limitPrice;
      vOrder.sl          = sl;
      vOrder.tp          = tp;
      vOrder.cancelPrice = cancelPrice;
      vOrder.expiration  = TimeCurrent() + (InpPendingExpireBars * PeriodSeconds(InpTimeframe));
      vOrder.active      = true;

      lastBarTime = currentBarTime;
      Print("-> Tạo Lệnh Chờ Ảo BUY LIMIT tại: ", limitPrice, " | Mức Hủy Ảo: ", cancelPrice);
     }

   // --- THIẾT LẬP LỆNH CHỜ ẢO SELL ---
   else if(breakClose < rangeLow && breakClose < breakOpen)
     {
      double breakLow = breakBar[0].low;

      double limitPrice = breakLow + (rangeHigh - breakLow) * InpFiboLevel;
      limitPrice = NormalizeDouble(limitPrice, _Digits);

      double sl = NormalizeDouble(limitPrice + (currentATR * InpSL_ATR_Mult), _Digits);
      double tp = NormalizeDouble(limitPrice - (currentATR * InpTP_ATR_Mult), _Digits);
      double cancelPrice = NormalizeDouble(limitPrice - (currentATR * InpCancelTP_ATR_Mult), _Digits);

      vOrder.type        = VIRTUAL_SELL;
      vOrder.limitPrice  = limitPrice;
      vOrder.sl          = sl;
      vOrder.tp          = tp;
      vOrder.cancelPrice = cancelPrice;
      vOrder.expiration  = TimeCurrent() + (InpPendingExpireBars * PeriodSeconds(InpTimeframe));
      vOrder.active      = true;

      lastBarTime = currentBarTime;
      Print("-> Tạo Lệnh Chờ Ảo SELL LIMIT tại: ", limitPrice, " | Mức Hủy Ảo: ", cancelPrice);
     }
  }

//+------------------------------------------------------------------+
//| Xử lý trạng thái Lệnh Chờ Ảo theo từng Tick giá                 |
//+------------------------------------------------------------------+
void ProcessVirtualOrder()
  {
   if(!vOrder.active) return;

   // 1. Kiểm tra hết hạn lệnh chờ ảo
   if(TimeCurrent() >= vOrder.expiration)
     {
      Print("HỦY LỆNH ẢO: Lệnh đã hết thời gian chờ!");
      ResetVirtualOrder();
      return;
     }

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- THIẾT LẬP LỆNH ẢO BUY ---
   if(vOrder.type == VIRTUAL_BUY)
     {
      if(InpUseCancelByATR && currentBid >= vOrder.cancelPrice)
        {
         Print("HỦY LỆNH ẢO BUY: Giá đã đâm tới ngưỡng ATR (", vOrder.cancelPrice, ") trước khi quay lại!");
         ResetVirtualOrder();
         return;
        }

      if(currentAsk <= vOrder.limitPrice)
        {
         if(trade.Buy(InpLotSize, _Symbol, currentAsk, vOrder.sl, vOrder.tp, "Breakout Virtual Buy"))
           {
            Print("KHỚP LỆNH MARKET BUY từ Lệnh Chờ Ảo tại giá: ", currentAsk);
            ResetVirtualOrder();
           }
        }
     }

   // --- THIẾT LẬP LỆNH ẢO SELL ---
   else if(vOrder.type == VIRTUAL_SELL)
     {
      if(InpUseCancelByATR && currentAsk <= vOrder.cancelPrice)
        {
         Print("HỦY LỆNH ẢO SELL: Giá đã đâm tới ngưỡng ATR (", vOrder.cancelPrice, ") trước khi quay lại!");
         ResetVirtualOrder();
         return;
        }

      if(currentBid >= vOrder.limitPrice)
        {
         if(trade.Sell(InpLotSize, _Symbol, currentBid, vOrder.sl, vOrder.tp, "Breakout Virtual Sell"))
           {
            Print("KHỚP LỆNH MARKET SELL từ Lệnh Chờ Ảo tại giá: ", currentBid);
            ResetVirtualOrder();
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Reset cấu trúc Lệnh Chờ Ảo về mặc định                          |
//+------------------------------------------------------------------+
void ResetVirtualOrder()
  {
   vOrder.type        = VIRTUAL_NONE;
   vOrder.limitPrice  = 0.0;
   vOrder.sl          = 0.0;
   vOrder.tp          = 0.0;
   vOrder.cancelPrice = 0.0;
   vOrder.expiration  = 0;
   vOrder.active      = false;
  }

//+------------------------------------------------------------------+
//| Quản lý vị thế đang chạy                                         |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!InpUseBE && !InpUseAdverseTP) return;

   double atrValues[];
   ArraySetAsSeries(atrValues, true);
   if(CopyBuffer(handleATR, 0, 0, 1, atrValues) <= 0) return;
   double currentATR = atrValues[0];

   double beOffset = InpBE_Profit_Pips * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      string symbol = PositionGetSymbol(i);
      if(symbol != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ulong ticket            = PositionGetInteger(POSITION_TICKET);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice        = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL        = PositionGetDouble(POSITION_SL);
      double currentTP        = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
        {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

         if(InpUseBE)
           {
            double beTriggerPrice = openPrice + (currentATR * InpBE_Trigger_ATR_Mult);
            double newSL = NormalizeDouble(openPrice + beOffset, _Digits);

            if(currentBid >= beTriggerPrice && (currentSL < newSL || currentSL == 0))
              {
               trade.PositionModify(ticket, newSL, currentTP);
               Print("Buy Position #", ticket, ": Dời SL về hòa vốn!");
              }
           }

         if(InpUseAdverseTP)
           {
            double adversePriceThreshold = openPrice - (currentATR * InpAdverseThreshold_ATR);
            double targetTP = NormalizeDouble(openPrice - (currentATR * InpNewTP_Loss_ATR_Mult), _Digits);

            if(currentBid <= adversePriceThreshold && currentTP > targetTP)
              {
               trade.PositionModify(ticket, currentSL, targetTP);
               Print("Buy Position #", ticket, ": Giá đi bất lợi, đã dời TP về sớm!");
              }
           }
        }

      else if(type == POSITION_TYPE_SELL)
        {
         double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         if(InpUseBE)
           {
            double beTriggerPrice = openPrice - (currentATR * InpBE_Trigger_ATR_Mult);
            double newSL = NormalizeDouble(openPrice - beOffset, _Digits);

            if(currentAsk <= beTriggerPrice && (currentSL > newSL || currentSL == 0))
              {
               trade.PositionModify(ticket, newSL, currentTP);
               Print("Sell Position #", ticket, ": Dời SL về hòa vốn!");
              }
           }

         if(InpUseAdverseTP)
           {
            double adversePriceThreshold = openPrice + (currentATR * InpAdverseThreshold_ATR);
            double targetTP = NormalizeDouble(openPrice + (currentATR * InpNewTP_Loss_ATR_Mult), _Digits);

            if(currentAsk >= adversePriceThreshold && currentTP < targetTP)
              {
               trade.PositionModify(ticket, currentSL, targetTP);
               Print("Sell Position #", ticket, ": Giá đi bất lợi, đã dời TP về sớm!");
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Kiểm tra vị thế đang mở                                          |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      string symbol = PositionGetSymbol(i);
      if(symbol == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return true;
     }
   return false;
  }