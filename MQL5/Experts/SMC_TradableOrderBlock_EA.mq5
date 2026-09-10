//+------------------------------------------------------------------------------------------------+
//|                                                    SMC_TradableOrderBlock_EA.mq5                 |
//|                                                                                                    |
//|  Smart-Money-Concepts Expert Advisor implementing the "Tradable vs Non-Tradable Order Blocks"     |
//|  methodology (Order Blocks, Imbalance/Liquidity Voids, Flip Zones, Significant Support &          |
//|  Resistance, Market-Structure Breaks) with a professional risk/trade-management layer on top.     |
//|                                                                                                    |
//|  ------------------------------------------------------------------------------------------------ |
//|  STRATEGY RULES IMPLEMENTED (mapped 1:1 to the source document)                                    |
//|  ------------------------------------------------------------------------------------------------ |
//|  Order Block [OB]:                                                                                 |
//|     - Down candle at/near Support before a move up  = Bullish Order Block (BuOB)                  |
//|     - Up candle at/near Resistance before a move down = Bearish Order Block (BeOB)                |
//|                                                                                                    |
//|  Risk-Entry pricing Hint:                                                                          |
//|     - BuOB not wicky -> Buy Limit at candle High,  SL at candle Low                                |
//|     - BuOB wicky     -> Buy Limit at candle Open,  SL at candle Low                                |
//|     - BeOB not wicky -> Sell Limit at candle Low,  SL at candle High                                |
//|     - BeOB wicky     -> Sell Limit at candle Open, SL at candle High                                |
//|                                                                                                    |
//|  A Tradable Order Block must satisfy ALL SIX characteristics:                                      |
//|     1) OB should be at/near Support/Resistance                                                     |
//|     2) OB should be at/near a Flip Zone (former Resistance that flipped to Support, or vice versa) |
//|     3) OB must break the Market Structure [BMS]                                                    |
//|     4) Imbalance (Liquidity Void) after creation of the OB must be >= 2x the OB size,               |
//|        and the achievable Risk:Reward must be >= 3x the OB size                                     |
//|     5) The OB must take out an opposing Order Block                                                |
//|     6) A Bearish OB must sit above a Significant Support/Resistance level, a Bullish OB must sit    |
//|        below a Significant Support/Resistance level (implemented as a "no major obstruction        |
//|        between entry and target" filter - see ValidateOB() comments for the exact approximation)   |
//|                                                                                                    |
//|  Non-tradable order blocks (those failing one or more rules) are tracked and optionally drawn on   |
//|  the chart for transparency, but are never traded.                                                 |
//+------------------------------------------------------------------------------------------------+
#property copyright "Order Block SMC EA"
#property link      ""
#property version   "1.00"
#property description "Smart Money Concepts EA - trades ONLY Order Blocks that pass all 6 'Tradable OB' rules."

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================================================
// INPUTS
//====================================================================================================
input group "=== General ==="
input long     InpMagicNumber          = 20260910;   // Magic number
input string   InpTradeComment         = "OB-SMC";   // Order comment prefix
input bool     InpEnableTrading        = true;       // Allow the EA to open new trades

input group "=== Structure & Order Block Detection ==="
input int      InpSwingLength          = 2;          // Fractal swing length (bars each side)
input int      InpOBSearchBars         = 25;         // Max bars searched backward for the OB candle
input int      InpMaxBarsHistory       = 1500;       // Bars scanned at start-up to build market context
input double   InpWickyRatioThreshold  = 0.33;       // Wick/range ratio above which an OB is "wicky"

input group "=== Tradable-OB Filters (Strategy Rules 1-6, ALL ON = 100% strategy adherence) ==="
input bool     InpReq_NearSR           = true;       // Rule 1: OB at/near Support/Resistance
input bool     InpReq_FlipZone         = true;       // Rule 2: OB at/near Flip Zone
input bool     InpReq_BMS              = true;       // Rule 3: OB must break Market Structure
input bool     InpReq_Imbalance        = true;       // Rule 4a: Imbalance >= InpImbalanceMultiplier x OB
input bool     InpReq_RiskReward       = true;       // Rule 4b: RR >= InpRiskRewardMultiplier x OB
input bool     InpReq_OpposingOBTaken  = true;       // Rule 5: OB must take out an opposing OB
input bool     InpReq_SSRPosition      = true;       // Rule 6: BeOB above SSR / BuOB below SSR
input double   InpImbalanceMultiplier  = 2.0;        // Imbalance distance required, in multiples of OB risk
input double   InpRiskRewardMultiplier = 3.0;        // TP1 distance, in multiples of OB risk (RR filter)
input double   InpTP2_RRMultiplier     = 6.0;        // TP2 distance, in multiples of OB risk (runner target)
input double   InpProximityATRMult     = 0.5;        // Proximity tolerance for S/R & Flip-Zone (x ATR)
input int      InpSSR_MinTouches       = 3;          // Touches required for a level to count as "Significant"
input double   InpSSR_ToleranceATRMult = 0.35;       // Clustering tolerance for SSR levels (x ATR)
input int      InpOpposingLookbackOBs  = 40;         // How many previous opposing OBs to scan for Rule 5

input group "=== Higher-Timeframe Bias Filter (intelligent addition) ==="
input bool     InpUseHTFBias           = true;       // Only trade in the direction of HTF bias
input ENUM_TIMEFRAMES InpHTFPeriod     = PERIOD_H4;  // Higher timeframe used for bias
input int      InpHTF_EMA_Period       = 50;         // EMA period on the higher timeframe

input group "=== Risk Management ==="
input double   InpRiskPercent          = 1.0;        // % of balance risked per trade
input double   InpFixedLots            = 0.0;        // If > 0, overrides risk-based position sizing
input double   InpMaxSpreadPoints      = 30;         // Max allowed spread, in points
input int      InpMaxOpenTrades        = 3;          // Max concurrent EA positions
input int      InpMaxTradesPerDay      = 6;          // Max new entries per day
input double   InpMaxDailyLossPercent  = 5.0;        // Daily equity-drawdown kill-switch
input int      InpPendingExpiryBars    = 20;         // Bars before an unfilled pending order is cancelled
input bool     InpFilterTinyStops      = true;       // Reject OBs whose SL distance is unrealistically tight
input double   InpMinStopPoints        = 50;         // Minimum OB risk distance required, in points
input double   InpMaxMarginUsagePercent= 50.0;       // Max % of free margin a single new order may consume

input group "=== Trade Management ==="
input bool     InpPartialCloseAtTP1    = true;       // Close part of the position at TP1 (3R)
input double   InpPartialClosePercent  = 50.0;       // % of volume to close at TP1
input bool     InpMoveSLToBEOnTP1      = true;       // Move SL to break-even once TP1 is hit
input double   InpBreakEvenBufferPts   = 20;         // Break-even buffer, in points
input bool     InpTrailAfterBE         = true;       // ATR-trail the runner after break-even
input double   InpTrailATRMultiplier   = 1.5;        // ATR multiplier used for trailing

input group "=== Session Filter ==="
input bool     InpUseSessionFilter     = false;      // Restrict new entries to a time window
input int      InpSessionStartHour     = 6;          // Session start hour (server time)
input int      InpSessionEndHour       = 20;         // Session end hour (server time)

input group "=== Visualization & Alerts ==="
input bool     InpShowOBBoxes          = true;       // Draw valid Order Block zones
input bool     InpShowRejectedOB       = true;       // Also draw non-tradable (rejected) OBs
input bool     InpShowSSRLevels        = true;       // Draw Significant Support/Resistance lines
input bool     InpShowDashboard        = true;       // Show on-chart info panel
input bool     InpAlertsEnabled        = true;       // Alert()/SendNotification() on valid OB & fills

//====================================================================================================
// TYPES
//====================================================================================================
enum OB_TYPE
  {
   OB_BULLISH = 0,
   OB_BEARISH = 1
  };

struct OrderBlockInfo
  {
   OB_TYPE           type;
   datetime          time;             // OB candle open time
   int               barShiftAtDetect;
   double            high, low, open, close;
   double            entry, sl, tp1, tp2, risk;
   bool              wicky;
   bool              valid;            // passed all enabled Tradable-OB rules
   bool              takenOut;         // this OB has since been mitigated/used as an "opposing OB"
   bool              tradedFlag;
   ulong             pendingTicket;
   ulong             positionTicket;
   datetime          expiryTime;
   string            rejectReason;
  };

struct SwingPointInfo
  {
   datetime          time;
   double            price;
   bool              isHigh;
  };

struct SSRLevelInfo
  {
   double            price;
   int               touches;
   datetime          lastTouch;
  };

struct PendingPlan
  {
   ulong             orderTicket;
   double            entry, sl, tp1, tp2, risk;
   bool              isBuy;
  };

struct ManagedTradeInfo
  {
   ulong             ticket;
   double            entry, sl, tp1, tp2, risk;
   bool              isBuy;
   bool              partialDone;
   bool              beDone;
  };

//====================================================================================================
// GLOBALS
//====================================================================================================
OrderBlockInfo    g_obList[];
SwingPointInfo    g_swingHighs[];
SwingPointInfo    g_swingLows[];
SSRLevelInfo      g_ssrLevels[];
PendingPlan       g_pendingPlans[];
ManagedTradeInfo  g_managedTrades[];

double   g_lastSwingHighPrice = 0.0;
datetime g_lastSwingHighTime  = 0;
bool     g_lastSwingHighBroken = true;

double   g_lastSwingLowPrice  = 0.0;
datetime g_lastSwingLowTime   = 0;
bool     g_lastSwingLowBroken  = true;

datetime g_lastBarTime  = 0;
datetime g_dayStart     = 0;
double   g_dayStartEquity = 0.0;
int      g_tradesToday  = 0;

int      g_atrHandle    = INVALID_HANDLE;
int      g_htfEmaHandle = INVALID_HANDLE;

//====================================================================================================
// UTILITIES
//====================================================================================================
double NormalizeVolume(double lot)
  {
   double minV  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxV  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) step=0.01;
   lot = MathFloor(lot/step)*step;
   lot = MathMax(minV, MathMin(maxV, lot));
   return NormalizeDouble(lot,2);
  }

double CalcLotByRisk(double riskDistancePrice)
  {
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance*InpRiskPercent/100.0;
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0 || riskDistancePrice<=0)
      return NormalizeVolume(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN));
   double lossPerLot = (riskDistancePrice/tickSize)*tickValue;
   if(lossPerLot<=0)
      return NormalizeVolume(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN));
   double lot = riskMoney/lossPerLot;
   return NormalizeVolume(lot);
  }

int CountOpenPositions()
  {
   int cnt=0;
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         cnt++;
     }
   return cnt;
  }

bool InSession()
  {
   if(!InpUseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   if(InpSessionStartHour<=InpSessionEndHour)
      return (dt.hour>=InpSessionStartHour && dt.hour<InpSessionEndHour);
   return (dt.hour>=InpSessionStartHour || dt.hour<InpSessionEndHour);
  }

bool DailyLossLimitHit()
  {
   if(g_dayStartEquity<=0) return false;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct=(g_dayStartEquity-eq)/g_dayStartEquity*100.0;
   return (ddPct>=InpMaxDailyLossPercent);
  }

void ResetDailyStats()
  {
   g_dayStart       = iTime(_Symbol,PERIOD_D1,0);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_tradesToday    = 0;
  }

void CheckDailyReset()
  {
   datetime d=iTime(_Symbol,PERIOD_D1,0);
   if(d!=g_dayStart) ResetDailyStats();
  }

int GetHTFBias()
  {
   if(!InpUseHTFBias) return 0;
   if(g_htfEmaHandle==INVALID_HANDLE) return 0;
   double ema[];
   if(CopyBuffer(g_htfEmaHandle,0,0,1,ema)!=1) return 0;
   double closeHTF=iClose(_Symbol,InpHTFPeriod,0);
   if(closeHTF>ema[0]) return 1;
   if(closeHTF<ema[0]) return -1;
   return 0;
  }

string BiasText(int b){ return b>0?"BULLISH":(b<0?"BEARISH":"NEUTRAL"); }

double GetATR(int shift=0)
  {
   double buf[];
   if(g_atrHandle==INVALID_HANDLE) return 10*_Point;
   if(CopyBuffer(g_atrHandle,0,shift,1,buf)!=1) return 10*_Point;
   return buf[0];
  }

//====================================================================================================
// SWING / SSR / STRUCTURE
//====================================================================================================
void AddSSRTouch(double price,datetime t)
  {
   double tol=GetATR(0)*InpSSR_ToleranceATRMult;
   for(int i=0;i<ArraySize(g_ssrLevels);i++)
     {
      if(MathAbs(g_ssrLevels[i].price-price)<=tol)
        {
         g_ssrLevels[i].touches++;
         g_ssrLevels[i].lastTouch=t;
         g_ssrLevels[i].price=(g_ssrLevels[i].price+price)/2.0;
         return;
        }
     }
   int n=ArraySize(g_ssrLevels);
   ArrayResize(g_ssrLevels,n+1);
   g_ssrLevels[n].price=price;
   g_ssrLevels[n].touches=1;
   g_ssrLevels[n].lastTouch=t;
   if(ArraySize(g_ssrLevels)>150) ArrayRemove(g_ssrLevels,0,1);
  }

// Confirms fractal swing pivots at shift (base+InpSwingLength) and updates the "last unbroken"
// structure trackers used by CheckForBOSAndOB(). Only ever reads shifts >= base -> zero look-ahead.
void UpdateSwingPoints(int base)
  {
   int c=base+InpSwingLength;
   int bars=Bars(_Symbol,_Period);
   if(c+InpSwingLength>=bars) return;

   double hc=iHigh(_Symbol,_Period,c);
   double lc=iLow(_Symbol,_Period,c);
   bool isHigh=true, isLow=true;
   for(int k=1;k<=InpSwingLength;k++)
     {
      if(iHigh(_Symbol,_Period,c-k)>hc || iHigh(_Symbol,_Period,c+k)>hc) isHigh=false;
      if(iLow(_Symbol,_Period,c-k) <lc || iLow(_Symbol,_Period,c+k) <lc) isLow=false;
     }
   datetime ct=iTime(_Symbol,_Period,c);

   if(isHigh)
     {
      int n=ArraySize(g_swingHighs);
      ArrayResize(g_swingHighs,n+1);
      g_swingHighs[n].time=ct; g_swingHighs[n].price=hc; g_swingHighs[n].isHigh=true;
      AddSSRTouch(hc,ct);
      g_lastSwingHighPrice=hc; g_lastSwingHighTime=ct; g_lastSwingHighBroken=false;
      if(ArraySize(g_swingHighs)>400) ArrayRemove(g_swingHighs,0,1);
     }
   if(isLow)
     {
      int n=ArraySize(g_swingLows);
      ArrayResize(g_swingLows,n+1);
      g_swingLows[n].time=ct; g_swingLows[n].price=lc; g_swingLows[n].isHigh=false;
      AddSSRTouch(lc,ct);
      g_lastSwingLowPrice=lc; g_lastSwingLowTime=ct; g_lastSwingLowBroken=false;
      if(ArraySize(g_swingLows)>400) ArrayRemove(g_swingLows,0,1);
     }
  }

bool NearSwing(SwingPointInfo &arr[],double price,datetime beforeTime,double tolerance,SwingPointInfo &found)
  {
   for(int i=ArraySize(arr)-1;i>=0;i--)
     {
      if(arr[i].time>=beforeTime) continue;
      if(MathAbs(arr[i].price-price)<=tolerance) { found=arr[i]; return true; }
     }
   return false;
  }

bool HasEarlierOpposite(SwingPointInfo &oppArr[],double price,datetime beforeTime,double tolerance)
  {
   for(int i=ArraySize(oppArr)-1;i>=0;i--)
      if(oppArr[i].time<beforeTime && MathAbs(oppArr[i].price-price)<=tolerance) return true;
   return false;
  }

// Rule 6 approximation: a Bearish OB must sit ABOVE any nearby Significant S/R (no major support/
// resistance obstruction between entry and the 3R target); a Bullish OB must sit BELOW one likewise.
bool SSRObstructs(OB_TYPE type,OrderBlockInfo &ob)
  {
   if(ArraySize(g_ssrLevels)==0) return false;
   for(int i=0;i<ArraySize(g_ssrLevels);i++)
     {
      if(g_ssrLevels[i].touches<InpSSR_MinTouches) continue;
      double lvl=g_ssrLevels[i].price;
      if(type==OB_BULLISH)
        {
         if(lvl>ob.high && lvl<ob.entry+InpRiskRewardMultiplier*ob.risk) return true;
        }
      else
        {
         if(lvl<ob.low && lvl>ob.entry-InpRiskRewardMultiplier*ob.risk) return true;
        }
     }
   return false;
  }

//====================================================================================================
// ORDER BLOCK DETECTION
//====================================================================================================
bool FindOBCandle(OB_TYPE type,int breakoutShift,int &obShiftOut)
  {
   for(int s=breakoutShift+1; s<=breakoutShift+InpOBSearchBars; s++)
     {
      double o=iOpen(_Symbol,_Period,s), c=iClose(_Symbol,_Period,s);
      if(type==OB_BULLISH && c<o) { obShiftOut=s; return true; }
      if(type==OB_BEARISH && c>o) { obShiftOut=s; return true; }
     }
   return false;
  }

// Rule 4a helper: classic 3-candle Fair Value Gap / Imbalance search across the impulse leg.
bool FindImbalance(OB_TYPE type,int obShift,int breakoutShift,double &gapNearEdge)
  {
   for(int k=obShift-2; k>=breakoutShift; k--)
     {
      double h_k =iHigh(_Symbol,_Period,k);
      double l_k =iLow(_Symbol,_Period,k);
      double h_k2=iHigh(_Symbol,_Period,k+2);
      double l_k2=iLow(_Symbol,_Period,k+2);
      if(type==OB_BULLISH && l_k>h_k2) { gapNearEdge=h_k2; return true; }
      if(type==OB_BEARISH && h_k<l_k2) { gapNearEdge=l_k2; return true; }
     }
   return false;
  }

double ImpulseExtreme(OB_TYPE type,int obShift,int breakoutShift)
  {
   double ext = (type==OB_BULLISH) ? iHigh(_Symbol,_Period,breakoutShift) : iLow(_Symbol,_Period,breakoutShift);
   for(int k=breakoutShift; k<=obShift-1; k++)
     {
      double h=iHigh(_Symbol,_Period,k), l=iLow(_Symbol,_Period,k);
      if(type==OB_BULLISH) ext=MathMax(ext,h);
      else                 ext=MathMin(ext,l);
     }
   return ext;
  }

// Risk-Entry pricing Hint: wicky vs non-wicky candle -> Entry & SL.
void ComputeEntrySL(OrderBlockInfo &ob)
  {
   double range=ob.high-ob.low;
   if(range<=0) range=_Point;

   if(ob.type==OB_BULLISH)
     {
      double upperWick=ob.high-ob.open;         // bearish OB candle: body top ~= open
      double ratio=upperWick/range;
      ob.wicky=(ratio>InpWickyRatioThreshold);
      ob.entry=ob.wicky ? ob.open : ob.high;
      ob.sl=ob.low;
     }
   else
     {
      double lowerWick=ob.open-ob.low;          // bullish OB candle: body bottom ~= open
      double ratio=lowerWick/range;
      ob.wicky=(ratio>InpWickyRatioThreshold);
      ob.entry=ob.wicky ? ob.open : ob.low;
      ob.sl=ob.high;
     }
   ob.risk=MathAbs(ob.entry-ob.sl);
  }

// Runs all 6 Tradable-OB rules and sets ob.valid / ob.rejectReason / ob.tp1 / ob.tp2.
void ValidateOB(OrderBlockInfo &ob,int obShift,int breakoutShift)
  {
   ComputeEntrySL(ob);
   bool pass=true;
   string reasons="";

   //--- Practical safety filter (not one of the 6 strategy rules): reject OBs whose SL distance is
   //    so tight that risk-based lot sizing would need an oversized position to risk InpRiskPercent,
   //    which can exceed available margin (tight stops are also more prone to spread/noise stop-outs).
   if(InpFilterTinyStops && ob.risk<InpMinStopPoints*_Point)
     {
      pass=false;
      reasons+="TinyStopFilter;";
     }

   double atrVal=GetATR(obShift);
   double proxTol=atrVal*InpProximityATRMult;

   //--- Rule 1 & 2: at/near Support-Resistance, and at/near a Flip Zone
   bool nearSR=false, flip=false;
   SwingPointInfo sp;
   if(ob.type==OB_BULLISH)
     {
      if(NearSwing(g_swingLows,ob.low,ob.time,proxTol,sp))
        {
         nearSR=true;
         if(HasEarlierOpposite(g_swingHighs,sp.price,sp.time,proxTol)) flip=true;
        }
     }
   else
     {
      if(NearSwing(g_swingHighs,ob.high,ob.time,proxTol,sp))
        {
         nearSR=true;
         if(HasEarlierOpposite(g_swingLows,sp.price,sp.time,proxTol)) flip=true;
        }
     }
   if(InpReq_NearSR   && !nearSR) { pass=false; reasons+="Rule1:NotAtS/R;"; }
   if(InpReq_FlipZone && !flip)   { pass=false; reasons+="Rule2:NoFlipZone;"; }

   //--- Rule 3: BMS - guaranteed true (an OB is only ever formed off a confirmed structure break)
   if(InpReq_BMS) { /* satisfied by construction */ }

   //--- Rule 4: Imbalance >= 2x OB, and RR >= 3x OB
   double gapEdge=0.0;
   bool hasImb=FindImbalance(ob.type,obShift,breakoutShift,gapEdge);
   bool imbOK=false;
   if(hasImb)
     {
      double dist=MathAbs(gapEdge-ob.entry);
      imbOK=(dist>=InpImbalanceMultiplier*ob.risk);
     }
   if(InpReq_Imbalance && !imbOK) { pass=false; reasons+="Rule4a:ImbalanceFail;"; }

   double extreme=ImpulseExtreme(ob.type,obShift,breakoutShift);
   double rr = (ob.risk>0) ? MathAbs(extreme-ob.entry)/ob.risk : 0.0;
   bool rrOK=(rr>=InpRiskRewardMultiplier);
   if(InpReq_RiskReward && !rrOK) { pass=false; reasons+="Rule4b:RRFail;"; }

   ob.tp1 = (ob.type==OB_BULLISH) ? ob.entry+InpRiskRewardMultiplier*ob.risk : ob.entry-InpRiskRewardMultiplier*ob.risk;
   ob.tp2 = (ob.type==OB_BULLISH) ? ob.entry+InpTP2_RRMultiplier*ob.risk    : ob.entry-InpTP2_RRMultiplier*ob.risk;

   //--- Rule 5: the OB must take out an opposing OB
   bool opposingOK=false;
   OB_TYPE oppType=(ob.type==OB_BULLISH)?OB_BEARISH:OB_BULLISH;
   int checked=0;
   for(int i=ArraySize(g_obList)-1; i>=0 && checked<InpOpposingLookbackOBs; i--)
     {
      if(g_obList[i].type!=oppType) continue;
      checked++;
      if(g_obList[i].time>=ob.time) continue;
      if(g_obList[i].takenOut) continue;
      bool violated=false;
      if(oppType==OB_BEARISH)
        {
         for(int k=breakoutShift;k<=obShift;k++)
            if(iClose(_Symbol,_Period,k)>g_obList[i].high) { violated=true; break; }
        }
      else
        {
         for(int k=breakoutShift;k<=obShift;k++)
            if(iClose(_Symbol,_Period,k)<g_obList[i].low) { violated=true; break; }
        }
      if(violated) { opposingOK=true; g_obList[i].takenOut=true; break; }
     }
   if(InpReq_OpposingOBTaken && !opposingOK) { pass=false; reasons+="Rule5:NoOpposingOBTaken;"; }

   //--- Rule 6: BeOB above SSR / BuOB below SSR (no major obstruction before target)
   bool ssrOK=!SSRObstructs(ob.type,ob);
   if(InpReq_SSRPosition && !ssrOK) { pass=false; reasons+="Rule6:SSRObstruction;"; }

   ob.valid=pass;
   ob.rejectReason = pass ? "VALID - all enabled Tradable-OB rules satisfied" : reasons;
  }

void DrawOBBox(OrderBlockInfo &ob);   // fwd decl (defined in Visualization section)

void TryFormOrderBlock(OB_TYPE type,int breakoutShift,bool liveMode)
  {
   int obShift;
   if(!FindOBCandle(type,breakoutShift,obShift)) return;

   datetime obTime=iTime(_Symbol,_Period,obShift);
   for(int i=0;i<ArraySize(g_obList);i++)
      if(g_obList[i].time==obTime && g_obList[i].type==type) return; // already recorded

   OrderBlockInfo ob;
   ob.type=type;
   ob.time=obTime;
   ob.barShiftAtDetect=obShift;
   ob.high=iHigh(_Symbol,_Period,obShift);
   ob.low =iLow(_Symbol,_Period,obShift);
   ob.open=iOpen(_Symbol,_Period,obShift);
   ob.close=iClose(_Symbol,_Period,obShift);
   ob.takenOut=false;
   ob.tradedFlag=false;
   ob.pendingTicket=0;
   ob.positionTicket=0;
   ob.expiryTime=0;
   ob.rejectReason="";

   ValidateOB(ob,obShift,breakoutShift);

   int n=ArraySize(g_obList);
   ArrayResize(g_obList,n+1);
   g_obList[n]=ob;

   if(InpShowOBBoxes && (g_obList[n].valid || InpShowRejectedOB))
      DrawOBBox(g_obList[n]);

   if(g_obList[n].valid && liveMode)
     {
      if(InpAlertsEnabled)
        {
         string msg=StringFormat("%s Valid %s OrderBlock @ %s | Entry=%.5f SL=%.5f TP1=%.5f TP2=%.5f",
                                  _Symbol, type==OB_BULLISH?"BULLISH":"BEARISH",
                                  TimeToString(ob.time,TIME_DATE|TIME_MINUTES),
                                  g_obList[n].entry,g_obList[n].sl,g_obList[n].tp1,g_obList[n].tp2);
         Alert(msg);
         SendNotification(msg);
        }
      PlacePendingOrder(g_obList[n]);
     }
  }

void CancelOppositePendings(OB_TYPE justConfirmedType)
  {
   OB_TYPE opp=(justConfirmedType==OB_BULLISH)?OB_BEARISH:OB_BULLISH;
   for(int i=0;i<ArraySize(g_obList);i++)
     {
      if(g_obList[i].type==opp && g_obList[i].pendingTicket!=0 && g_obList[i].positionTicket==0)
        {
         if(OrderSelect(g_obList[i].pendingTicket))
            trade.OrderDelete(g_obList[i].pendingTicket);
         g_obList[i].pendingTicket=0;
        }
     }
  }

void CheckForBOSAndOB(int base,bool liveMode)
  {
   double c=iClose(_Symbol,_Period,base);
   if(g_lastSwingHighPrice>0 && !g_lastSwingHighBroken && c>g_lastSwingHighPrice)
     {
      g_lastSwingHighBroken=true;
      TryFormOrderBlock(OB_BULLISH,base,liveMode);
      if(liveMode) CancelOppositePendings(OB_BULLISH);
     }
   if(g_lastSwingLowPrice>0 && !g_lastSwingLowBroken && c<g_lastSwingLowPrice)
     {
      g_lastSwingLowBroken=true;
      TryFormOrderBlock(OB_BEARISH,base,liveMode);
      if(liveMode) CancelOppositePendings(OB_BEARISH);
     }
  }

void CleanupOldOBs()
  {
   int cap=300;
   int n=ArraySize(g_obList);
   if(n<=cap) return;
   ArrayRemove(g_obList,0,n-cap);
  }

// Causal, look-ahead-free processing of one closed bar. `base` is the shift of the bar that just
// closed (base=1 in live trading; BuildHistoricalContext() replays base=N..1 to seed state).
void ProcessClosedBar(int base,bool liveMode)
  {
   CheckForBOSAndOB(base,liveMode);
   UpdateSwingPoints(base);
   CleanupOldOBs();
  }

void BuildHistoricalContext()
  {
   int bars=Bars(_Symbol,_Period);
   int scan=MathMin(InpMaxBarsHistory, bars-InpSwingLength*2-InpOBSearchBars-5);
   if(scan<10) { Print("Not enough history to build context yet."); return; }
   for(int base=scan; base>=1; base--)
      ProcessClosedBar(base,false);
   PrintFormat("Historical context built: swingHighs=%d swingLows=%d OBs=%d (valid=%d) SSR levels=%d",
               ArraySize(g_swingHighs),ArraySize(g_swingLows),ArraySize(g_obList),
               CountValidOBs(),ArraySize(g_ssrLevels));
  }

int CountValidOBs()
  {
   int v=0;
   for(int i=0;i<ArraySize(g_obList);i++) if(g_obList[i].valid) v++;
   return v;
  }

//====================================================================================================
// TRADE EXECUTION & MANAGEMENT
//====================================================================================================
// Ensures the position we are about to open cannot exceed InpMaxMarginUsagePercent of free margin;
// scales the lot down (respecting the volume step/min) or refuses the trade if even the minimum
// lot would breach the cap. Prevents "not enough money for order" failures that a purely
// risk-percent based lot size can produce when an Order Block's stop distance is very tight
// (small risk-in-price does NOT mean small margin requirement - leverage does not care about pips).
bool CapLotByMargin(ENUM_ORDER_TYPE orderType,double price,double &lot)
  {
   double margin=0.0;
   if(!OrderCalcMargin(orderType,_Symbol,lot,price,margin)) return false;
   double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double allowed=freeMargin*(InpMaxMarginUsagePercent/100.0);
   if(margin<=allowed) return true;

   double minV=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) step=0.01;

   double scaled=NormalizeVolume(lot*(allowed/margin));
   while(scaled>=minV)
     {
      if(!OrderCalcMargin(orderType,_Symbol,scaled,price,margin)) return false;
      if(margin<=allowed) { lot=scaled; return true; }
      scaled=NormalizeVolume(scaled-step);
     }
   return false; // even the minimum lot would exceed the allowed margin usage
  }

void PlacePendingOrder(OrderBlockInfo &ob)
  {
   if(!InpEnableTrading) return;
   if(!InSession()) return;
   if((double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD) > InpMaxSpreadPoints) return;
   if(CountOpenPositions()>=InpMaxOpenTrades) return;
   if(g_tradesToday>=InpMaxTradesPerDay) return;
   if(DailyLossLimitHit()) return;

   int bias=GetHTFBias();
   if(InpUseHTFBias)
     {
      if(ob.type==OB_BULLISH && bias<0) return;
      if(ob.type==OB_BEARISH && bias>0) return;
     }

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double stopLevel=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;

   double lot = (InpFixedLots>0) ? NormalizeVolume(InpFixedLots) : CalcLotByRisk(ob.risk);
   if(lot<=0) return;

   ENUM_ORDER_TYPE orderType=(ob.type==OB_BULLISH)?ORDER_TYPE_BUY_LIMIT:ORDER_TYPE_SELL_LIMIT;
   if(!CapLotByMargin(orderType,ob.entry,lot))
     {
      PrintFormat("[OB-EA] Skipped %s OB @ %s - insufficient free margin even at minimum lot",
                  ob.type==OB_BULLISH?"BULLISH":"BEARISH",TimeToString(ob.time,TIME_DATE|TIME_MINUTES));
      return;
     }

   datetime expiry=TimeCurrent()+(datetime)(InpPendingExpiryBars*PeriodSeconds(_Period));

   bool ok=false;
   if(ob.type==OB_BULLISH)
     {
      if(ob.entry>=ask) return;                       // price already ran through the OB
      if(ask-ob.entry<stopLevel) return;               // too close to market per broker rules
      ok=trade.BuyLimit(lot,ob.entry,_Symbol,ob.sl,ob.tp2,ORDER_TIME_SPECIFIED,expiry,InpTradeComment+"-BuOB");
     }
   else
     {
      if(ob.entry<=bid) return;
      if(ob.entry-bid<stopLevel) return;
      ok=trade.SellLimit(lot,ob.entry,_Symbol,ob.sl,ob.tp2,ORDER_TIME_SPECIFIED,expiry,InpTradeComment+"-BeOB");
     }

   if(ok)
     {
      ulong ticket=trade.ResultOrder();
      ob.pendingTicket=ticket;
      ob.tradedFlag=true;
      ob.expiryTime=expiry;

      int p=ArraySize(g_pendingPlans);
      ArrayResize(g_pendingPlans,p+1);
      g_pendingPlans[p].orderTicket=ticket;
      g_pendingPlans[p].entry=ob.entry;
      g_pendingPlans[p].sl=ob.sl;
      g_pendingPlans[p].tp1=ob.tp1;
      g_pendingPlans[p].tp2=ob.tp2;
      g_pendingPlans[p].risk=ob.risk;
      g_pendingPlans[p].isBuy=(ob.type==OB_BULLISH);

      g_tradesToday++;
      PrintFormat("[OB-EA] Placed %s pending #%I64u @ %.5f SL=%.5f TP1=%.5f TP2=%.5f lot=%.2f",
                  ob.type==OB_BULLISH?"BUY LIMIT":"SELL LIMIT",ticket,ob.entry,ob.sl,ob.tp1,ob.tp2,lot);
     }
   else
     {
      PrintFormat("[OB-EA] Order placement failed: %d %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
     }
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   ulong dealTicket=trans.deal;
   if(!HistoryDealSelect(dealTicket)) return;

   long magic=HistoryDealGetInteger(dealTicket,DEAL_MAGIC);
   long entryFlag=HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
   if(magic!=InpMagicNumber || entryFlag!=DEAL_ENTRY_IN) return;

   ulong ordTicket=(ulong)HistoryDealGetInteger(dealTicket,DEAL_ORDER);

   for(int i=0;i<ArraySize(g_pendingPlans);i++)
     {
      if(g_pendingPlans[i].orderTicket!=ordTicket) continue;

      ManagedTradeInfo mt;
      mt.ticket=trans.position;
      mt.entry=g_pendingPlans[i].entry;
      mt.sl=g_pendingPlans[i].sl;
      mt.tp1=g_pendingPlans[i].tp1;
      mt.tp2=g_pendingPlans[i].tp2;
      mt.risk=g_pendingPlans[i].risk;
      mt.isBuy=g_pendingPlans[i].isBuy;
      mt.partialDone=false;
      mt.beDone=false;

      int m=ArraySize(g_managedTrades);
      ArrayResize(g_managedTrades,m+1);
      g_managedTrades[m]=mt;

      for(int j=0;j<ArraySize(g_obList);j++)
         if(g_obList[j].pendingTicket==ordTicket) { g_obList[j].positionTicket=trans.position; break; }

      if(InpAlertsEnabled)
        {
         string msg=StringFormat("%s Order filled: %s @ %.5f",_Symbol,mt.isBuy?"BUY":"SELL",mt.entry);
         Alert(msg);
        }

      ArrayRemove(g_pendingPlans,i,1);
      break;
     }
  }

// The CTrade wrapper's PositionModify()/PositionClosePartial() only have symbol-based overloads,
// and on a hedging account a symbol-based call can silently act on the WRONG position when more
// than one position is open on the same symbol (broker modifies "the position with the lowest
// ticket"). Since this EA can hold several concurrent positions on one symbol, position modify and
// partial-close are done here with raw MqlTradeRequest calls that pin the exact ticket via
// request.position - this is unambiguous under both netting and hedging accounting.
ENUM_ORDER_TYPE_FILLING GetFillingMode(const string symbol)
  {
   long filling=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK)!=0) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC)!=0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

bool ModifyPositionByTicket(ulong ticket,double sl,double tp)
  {
   if(!PositionSelectByTicket(ticket)) return false;
   MqlTradeRequest request; MqlTradeResult result;
   ZeroMemory(request); ZeroMemory(result);
   request.action   = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol   = PositionGetString(POSITION_SYMBOL);
   request.sl       = NormalizeDouble(sl,_Digits);
   request.tp       = NormalizeDouble(tp,_Digits);
   if(!OrderSend(request,result))
     {
      PrintFormat("[OB-EA] Modify failed for #%I64u: %d %s",ticket,result.retcode,result.comment);
      return false;
     }
   return (result.retcode==TRADE_RETCODE_DONE);
  }

bool ClosePartialByTicket(ulong ticket,double volume)
  {
   if(!PositionSelectByTicket(ticket)) return false;
   string symbol   = PositionGetString(POSITION_SYMBOL);
   long   posType  = PositionGetInteger(POSITION_TYPE);
   MqlTradeRequest request; MqlTradeResult result;
   ZeroMemory(request); ZeroMemory(result);
   request.action       = TRADE_ACTION_DEAL;
   request.position     = ticket;
   request.symbol       = symbol;
   request.volume       = volume;
   request.deviation    = 20;
   request.type_filling = GetFillingMode(symbol);
   request.type  = (posType==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (posType==POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol,SYMBOL_BID) : SymbolInfoDouble(symbol,SYMBOL_ASK);
   if(!OrderSend(request,result))
     {
      PrintFormat("[OB-EA] Partial close failed for #%I64u: %d %s",ticket,result.retcode,result.comment);
      return false;
     }
   return (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL);
  }

void ManageOpenPositions()
  {
   for(int i=ArraySize(g_managedTrades)-1; i>=0; i--)
     {
      ulong ticket=g_managedTrades[i].ticket;
      if(!PositionSelectByTicket(ticket)) { ArrayRemove(g_managedTrades,i,1); continue; }

      bool isBuy=g_managedTrades[i].isBuy;
      double price = isBuy ? SymbolInfoDouble(_Symbol,SYMBOL_BID) : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double vol   = PositionGetDouble(POSITION_VOLUME);
      double curTP = PositionGetDouble(POSITION_TP);
      double curSL = PositionGetDouble(POSITION_SL);

      if(InpPartialCloseAtTP1 && !g_managedTrades[i].partialDone)
        {
         bool hit = isBuy ? (price>=g_managedTrades[i].tp1) : (price<=g_managedTrades[i].tp1);
         if(hit)
           {
            double closeVol=NormalizeVolume(vol*InpPartialClosePercent/100.0);
            double minV=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
            if(closeVol>=minV && closeVol<vol)
               ClosePartialByTicket(ticket,closeVol);
            g_managedTrades[i].partialDone=true;

            if(InpMoveSLToBEOnTP1)
              {
               double be = isBuy ? g_managedTrades[i].entry+InpBreakEvenBufferPts*_Point
                                  : g_managedTrades[i].entry-InpBreakEvenBufferPts*_Point;
               ModifyPositionByTicket(ticket,be,curTP);
               g_managedTrades[i].beDone=true;
              }
            continue;
           }
        }

      if(InpTrailAfterBE && g_managedTrades[i].beDone)
        {
         double atr=GetATR(0);
         double newSL = isBuy ? price-atr*InpTrailATRMultiplier : price+atr*InpTrailATRMultiplier;
         bool improve = isBuy ? (newSL>curSL) : (curSL==0 || newSL<curSL);
         if(improve)
            ModifyPositionByTicket(ticket,newSL,curTP);
        }
     }
  }

void ManagePendingOrders()
  {
   for(int i=0;i<ArraySize(g_obList);i++)
     {
      if(g_obList[i].pendingTicket==0 || g_obList[i].positionTicket!=0) continue;
      if(!OrderSelect(g_obList[i].pendingTicket))
        {
         // order no longer exists (filled elsewhere, expired, or manually removed)
         g_obList[i].pendingTicket=0;
         continue;
        }
      if(g_obList[i].expiryTime>0 && TimeCurrent()>=g_obList[i].expiryTime)
        {
         trade.OrderDelete(g_obList[i].pendingTicket);
         g_obList[i].pendingTicket=0;
        }
     }
  }

//====================================================================================================
// VISUALIZATION
//====================================================================================================
void DrawOBBox(OrderBlockInfo &ob)
  {
   string name="OBEA_OB_"+(ob.type==OB_BULLISH?"BU_":"BE_")+IntegerToString((long)ob.time);
   if(ObjectFind(0,name)>=0) ObjectDelete(0,name);

   datetime t2=TimeCurrent()+(datetime)(PeriodSeconds(_Period)*30);
   ObjectCreate(0,name,OBJ_RECTANGLE,0,ob.time,ob.high,t2,ob.low);

   color c = ob.valid ? (ob.type==OB_BULLISH?clrLimeGreen:clrTomato) : clrSilver;
   ObjectSetInteger(0,name,OBJPROP_COLOR,c);
   ObjectSetInteger(0,name,OBJPROP_STYLE,ob.valid?STYLE_SOLID:STYLE_DOT);
   ObjectSetInteger(0,name,OBJPROP_FILL,ob.valid);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,
                   StringFormat("%s %s\nEntry=%.5f SL=%.5f TP1=%.5f TP2=%.5f\n%s",
                                ob.type==OB_BULLISH?"BuOB":"BeOB", ob.valid?"(TRADABLE)":"(non-tradable)",
                                ob.entry,ob.sl,ob.tp1,ob.tp2,ob.rejectReason));
  }

void DrawSSRLevels()
  {
   ObjectsDeleteAll(0,"OBEA_SSR_");
   for(int i=0;i<ArraySize(g_ssrLevels);i++)
     {
      if(g_ssrLevels[i].touches<InpSSR_MinTouches) continue;
      string name="OBEA_SSR_"+IntegerToString(i);
      ObjectCreate(0,name,OBJ_HLINE,0,0,g_ssrLevels[i].price);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrDodgerBlue);
      ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DASHDOT);
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetString(0,name,OBJPROP_TOOLTIP,StringFormat("Significant S/R  touches=%d",g_ssrLevels[i].touches));
     }
  }

void UpdateDashboard()
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = (g_dayStartEquity>0) ? (g_dayStartEquity-eq)/g_dayStartEquity*100.0 : 0.0;

   string s="";
   s+="====== SMC Tradable-OrderBlock EA ======\n";
   s+=StringFormat("Symbol: %s   TF: %s\n",_Symbol,EnumToString(_Period));
   s+=StringFormat("Trading: %s   HTF Bias(%s): %s\n",InpEnableTrading?"ON":"OFF",
                    EnumToString(InpHTFPeriod),BiasText(GetHTFBias()));
   s+=StringFormat("Open Trades: %d/%d    Today: %d/%d\n",CountOpenPositions(),InpMaxOpenTrades,
                    g_tradesToday,InpMaxTradesPerDay);
   s+=StringFormat("Equity: %.2f   Daily DD: %.2f%% (limit %.2f%%)\n",eq,ddPct,InpMaxDailyLossPercent);
   s+=StringFormat("Order Blocks tracked: %d   Valid(tradable): %d\n",ArraySize(g_obList),CountValidOBs());
   s+=StringFormat("Significant S/R levels: %d   Pending orders: %d\n",ArraySize(g_ssrLevels),ArraySize(g_pendingPlans));
   Comment(s);
  }

//====================================================================================================
// EXPERT EVENT HANDLERS
//====================================================================================================
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_atrHandle=iATR(_Symbol,_Period,14);
   if(InpUseHTFBias)
      g_htfEmaHandle=iMA(_Symbol,InpHTFPeriod,InpHTF_EMA_Period,0,MODE_EMA,PRICE_CLOSE);

   if(g_atrHandle==INVALID_HANDLE || (InpUseHTFBias && g_htfEmaHandle==INVALID_HANDLE))
     {
      Print("[OB-EA] Failed to create indicator handles.");
      return(INIT_FAILED);
     }

   ArrayResize(g_obList,0);
   ArrayResize(g_swingHighs,0);
   ArrayResize(g_swingLows,0);
   ArrayResize(g_ssrLevels,0);
   ArrayResize(g_pendingPlans,0);
   ArrayResize(g_managedTrades,0);

   BuildHistoricalContext();
   ResetDailyStats();
   g_lastBarTime=iTime(_Symbol,_Period,0);

   if(InpShowSSRLevels) DrawSSRLevels();

   EventSetTimer(30);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0,"OBEA_");
   Comment("");
  }

void OnTick()
  {
   ManageOpenPositions();
   ManagePendingOrders();

   datetime t0=iTime(_Symbol,_Period,0);
   if(t0!=g_lastBarTime)
     {
      g_lastBarTime=t0;
      ProcessClosedBar(1,true);
      CheckDailyReset();
      if(InpShowSSRLevels) DrawSSRLevels();
     }

   if(InpShowDashboard) UpdateDashboard();
  }

void OnTimer()
  {
   CheckDailyReset();
   ManagePendingOrders();
  }
//+------------------------------------------------------------------------------------------------+
