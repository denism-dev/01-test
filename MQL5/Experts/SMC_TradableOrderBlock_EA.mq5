//+------------------------------------------------------------------------------------------------+
//|                                                    SMC_TradableOrderBlock_EA.mq5                 |
//|                                                                                                    |
//|  Smart-Money-Concepts Expert Advisor implementing the "Tradable vs Non-Tradable Order Blocks"     |
//|  methodology: Order Blocks, Imbalance/Liquidity Voids (Extended Range Candles), Flip Zones,       |
//|  Significant Support & Resistance, Market-Structure Breaks, AND genuine Higher-Timeframe ->       |
//|  Confirmation-Timeframe -> Entry-Timeframe Order Block confluence - with a professional           |
//|  risk/trade-management layer on top.                                                              |
//|                                                                                                    |
//|  ------------------------------------------------------------------------------------------------ |
//|  STRATEGY RULES IMPLEMENTED                                                                        |
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
//|  A Tradable Order Block must satisfy ALL of the following (each independently toggleable):        |
//|     1) OB should be at/near Support/Resistance                                                     |
//|     2) OB should be at/near a Flip Zone (former Resistance that flipped to Support, or vice versa) |
//|     3) OB must break the Market Structure [BMS] - guaranteed by construction                       |
//|     4) A Liquidity Void / Imbalance formed after the OB, driven by 2+ consecutive Extended Range   |
//|        Candles (ERC, each closing near ~80% of its own range - see IsERC()), must sit at least     |
//|        2x the OB's risk distance from entry; AND the impulse leg must reach at least 3x the OB's   |
//|        risk distance (used as TP1).                                                                |
//|     5) The OB must take out a PRIOR, ITSELF-VALID opposing Order Block (an opposing OB that never  |
//|        passed these same rules does not count as genuine liquidity worth removing).                |
//|     6) A Bearish OB must sit above, a Bullish OB below, any Significant Support/Resistance level   |
//|        that would otherwise obstruct the move to target (documented approximation - see            |
//|        SSRObstructs()).                                                                            |
//|     7) Higher-Timeframe confluence: the Entry-timeframe OB's zone must nest/overlap with a still-  |
//|        active, valid, same-direction OB on the Confirmation timeframe, which itself was only       |
//|        marked valid because ITS zone nested/overlapped with a still-active, valid, same-direction  |
//|        OB on the Higher timeframe - i.e. a genuine HTF -> Confirmation-TF -> Entry-TF Order Block   |
//|        hierarchy (see COBTimeframeEngine::FindAlignedOB()), not a moving-average bias filter.       |
//|                                                                                                    |
//|  Non-tradable OBs (failing one or more rules) are tracked and optionally drawn on the chart for    |
//|  transparency, but are never traded. Two things are documented, honest approximations of a         |
//|  discretionary source concept rather than an exact mechanical replica: Rule 6 (SSRObstructs) and   |
//|  the ATR-based overlap tolerance used for "nesting" in Rule 7 (FindAlignedOB) - see the comments   |
//|  above each for the precise logic used.                                                            |
//+------------------------------------------------------------------------------------------------+
#property copyright "Order Block SMC EA"
#property link      ""
#property version   "2.00"
#property description "Smart Money Concepts EA - HTF->Confirmation->Entry Order Block confluence + the 6 Tradable-OB rules."

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
input int      InpMaxBarsHistory       = 1500;       // Bars scanned at start-up to build context (per timeframe)
input double   InpWickyRatioThreshold  = 0.33;       // Wick/range ratio above which an OB is "wicky"

input group "=== Tradable-OB Filters (Strategy Rules 1-6) ==="
input bool     InpReq_NearSR           = true;       // Rule 1: OB at/near Support/Resistance
input bool     InpReq_FlipZone         = true;       // Rule 2: OB at/near Flip Zone
input bool     InpReq_BMS              = true;       // Rule 3: OB must break Market Structure
input bool     InpReq_Imbalance        = true;       // Rule 4a: Imbalance >= InpImbalanceMultiplier x OB
input bool     InpReq_RiskReward       = true;       // Rule 4b: RR >= InpRiskRewardMultiplier x OB
input bool     InpReq_OpposingOBTaken  = true;       // Rule 5: OB must take out a VALID opposing OB
input bool     InpReq_SSRPosition      = true;       // Rule 6: BeOB above SSR / BuOB below SSR
input double   InpProximityATRMult     = 0.5;        // Proximity tolerance for S/R & Flip-Zone (x ATR)
input int      InpSSR_MinTouches       = 3;          // Touches required for a level to count as "Significant"
input double   InpSSR_ToleranceATRMult = 0.35;       // Clustering tolerance for SSR levels (x ATR)
input int      InpOpposingLookbackOBs  = 40;         // How many previous opposing OBs to scan for Rule 5

input group "=== Imbalance / Liquidity-Void Settings (PDF: 2-3+ Extended Range Candles) ==="
input double   InpERCCloseRatio        = 0.80;       // Min close-position-in-range for an Extended Range Candle
input int      InpMinERCCount          = 2;          // Minimum consecutive ERC candles required (PDF: "2-3 or more")
input bool     InpAllowFVGAsImbalance  = true;       // Also accept a classic 3-candle FVG as an alternative imbalance
input double   InpImbalanceMultiplier  = 2.0;        // Imbalance distance required, in multiples of OB risk
input double   InpRiskRewardMultiplier = 3.0;        // TP1 distance, in multiples of OB risk (RR filter)
input double   InpTP2_RRMultiplier     = 6.0;        // TP2 distance, in multiples of OB risk (runner target)

input group "=== Multi-Timeframe OB Confluence (HTF -> Confirmation -> Entry, per the PDF) ==="
input bool     InpUseHTFConfluence     = true;       // Require a genuine HTF->Confirmation->Entry OB chain
input ENUM_TIMEFRAMES InpHTFPeriod         = PERIOD_H4; // Higher timeframe (top of the hierarchy)
input ENUM_TIMEFRAMES InpConfirmationPeriod= PERIOD_H1; // Confirmation timeframe (between HTF and entry chart)
input double   InpConfluenceATRMult    = 1.0;        // Zone-overlap tolerance between adjacent-TF OBs (x parent ATR)

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
input bool     InpShowOBBoxes          = true;       // Draw entry-timeframe Order Block zones
input bool     InpShowRejectedOB       = true;       // Also draw non-tradable (rejected) entry-TF OBs
input bool     InpShowHTFOBBoxes       = true;       // Also draw valid Confirmation/HTF OB zones
input bool     InpShowSSRLevels        = true;       // Draw entry-timeframe Significant Support/Resistance lines
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
   bool              valid;            // passed all enabled Tradable-OB rules (incl. HTF confluence)
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

// Forward declarations - defined later in this file, called from inside COBTimeframeEngine methods.
void DrawOBBox(string tag,OrderBlockInfo &ob);
void OnValidEntryOB(OrderBlockInfo &ob);
void PlacePendingOrder(OrderBlockInfo &ob);

//====================================================================================================
// COBTimeframeEngine - the full detection/validation pipeline (swings, structure/BOS, SSR, Order
// Blocks) for ONE timeframe. Instantiated three times (HTF, Confirmation, Entry) below so that the
// PDF's real "Higher-Timeframe OB -> Confirmation-Timeframe OB -> Entry-Timeframe OB" hierarchy can
// be enforced as an actual nested-zone chain, rather than approximated with a moving-average bias.
//====================================================================================================
class COBTimeframeEngine
  {
public:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_period;
   string            m_tag;            // "HTF" / "CTF" / "ENTRY" - used for logging & chart object names
   bool              m_canTrade;       // only the ENTRY engine ever places real orders
   int               m_atrHandle;
   datetime          m_lastBarTime;

   double            lastSwingHighPrice;
   datetime          lastSwingHighTime;
   bool              lastSwingHighBroken;
   double            lastSwingLowPrice;
   datetime          lastSwingLowTime;
   bool              lastSwingLowBroken;

   SwingPointInfo    swingHighs[];
   SwingPointInfo    swingLows[];
   SSRLevelInfo      ssrLevels[];
   OrderBlockInfo    obList[];

   bool Init(string symbol,ENUM_TIMEFRAMES period,string tag,bool canTrade)
     {
      m_symbol=symbol; m_period=period; m_tag=tag; m_canTrade=canTrade;
      m_lastBarTime=0;
      lastSwingHighPrice=0; lastSwingHighBroken=true;
      lastSwingLowPrice=0;  lastSwingLowBroken=true;
      ArrayResize(swingHighs,0); ArrayResize(swingLows,0);
      ArrayResize(ssrLevels,0);  ArrayResize(obList,0);
      m_atrHandle=iATR(symbol,period,14);
      return (m_atrHandle!=INVALID_HANDLE);
     }

   double GetATR(int shift=0)
     {
      double buf[];
      if(m_atrHandle==INVALID_HANDLE) return 10*_Point;
      if(CopyBuffer(m_atrHandle,0,shift,1,buf)!=1) return 10*_Point;
      return buf[0];
     }

   void AddSSRTouch(double price,datetime t)
     {
      double tol=GetATR(0)*InpSSR_ToleranceATRMult;
      for(int i=0;i<ArraySize(ssrLevels);i++)
        {
         if(MathAbs(ssrLevels[i].price-price)<=tol)
           {
            ssrLevels[i].touches++;
            ssrLevels[i].lastTouch=t;
            ssrLevels[i].price=(ssrLevels[i].price+price)/2.0;
            return;
           }
        }
      int n=ArraySize(ssrLevels);
      ArrayResize(ssrLevels,n+1);
      ssrLevels[n].price=price; ssrLevels[n].touches=1; ssrLevels[n].lastTouch=t;
      if(ArraySize(ssrLevels)>150) ArrayRemove(ssrLevels,0,1);
     }

   // Confirms fractal swing pivots at shift (base+InpSwingLength) and updates the "last unbroken"
   // structure trackers used by CheckForBOSAndOB(). Only ever reads shifts >= base -> zero look-ahead.
   void UpdateSwingPoints(int base)
     {
      int c=base+InpSwingLength;
      int bars=Bars(m_symbol,m_period);
      if(c+InpSwingLength>=bars) return;

      double hc=iHigh(m_symbol,m_period,c);
      double lc=iLow(m_symbol,m_period,c);
      bool isHigh=true, isLow=true;
      for(int k=1;k<=InpSwingLength;k++)
        {
         if(iHigh(m_symbol,m_period,c-k)>hc || iHigh(m_symbol,m_period,c+k)>hc) isHigh=false;
         if(iLow(m_symbol,m_period,c-k) <lc || iLow(m_symbol,m_period,c+k) <lc) isLow=false;
        }
      datetime ct=iTime(m_symbol,m_period,c);

      if(isHigh)
        {
         int n=ArraySize(swingHighs);
         ArrayResize(swingHighs,n+1);
         swingHighs[n].time=ct; swingHighs[n].price=hc; swingHighs[n].isHigh=true;
         AddSSRTouch(hc,ct);
         lastSwingHighPrice=hc; lastSwingHighTime=ct; lastSwingHighBroken=false;
         if(ArraySize(swingHighs)>400) ArrayRemove(swingHighs,0,1);
        }
      if(isLow)
        {
         int n=ArraySize(swingLows);
         ArrayResize(swingLows,n+1);
         swingLows[n].time=ct; swingLows[n].price=lc; swingLows[n].isHigh=false;
         AddSSRTouch(lc,ct);
         lastSwingLowPrice=lc; lastSwingLowTime=ct; lastSwingLowBroken=false;
         if(ArraySize(swingLows)>400) ArrayRemove(swingLows,0,1);
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
      if(ArraySize(ssrLevels)==0) return false;
      for(int i=0;i<ArraySize(ssrLevels);i++)
        {
         if(ssrLevels[i].touches<InpSSR_MinTouches) continue;
         double lvl=ssrLevels[i].price;
         if(type==OB_BULLISH) { if(lvl>ob.high && lvl<ob.entry+InpRiskRewardMultiplier*ob.risk) return true; }
         else                 { if(lvl<ob.low  && lvl>ob.entry-InpRiskRewardMultiplier*ob.risk) return true; }
        }
      return false;
     }

   // PDF: "ERC candle often closes at 80% of the candle range" - a strong, low-reversal-wick candle
   // in the direction of the impulse. dir is the OB's implied direction (i.e. the impulse direction).
   bool IsERC(int shift,OB_TYPE dir)
     {
      double o=iOpen(m_symbol,m_period,shift), c=iClose(m_symbol,m_period,shift);
      double h=iHigh(m_symbol,m_period,shift), l=iLow(m_symbol,m_period,shift);
      double range=h-l; if(range<=0) return false;
      if(dir==OB_BULLISH) { if(c<=o) return false; return ((c-l)/range)>=InpERCCloseRatio; }
      else                { if(c>=o) return false; return ((h-c)/range)>=InpERCCloseRatio; }
     }

   // PDF-faithful imbalance test: "Imbalance is created by 2-3 or more Extended Range Candles."
   // Scans the impulse leg for the run of consecutive ERC candles closest to the OB and returns the
   // near edge of the zone they swept through (the level price would need to return to, to "fill"
   // the orders left behind).
   bool FindERCImbalance(OB_TYPE type,int obShift,int breakoutShift,double &nearEdge)
     {
      int run=0; double runExtreme=0;
      for(int k=obShift-1; k>=breakoutShift; k--)
        {
         if(IsERC(k,type))
           {
            double h=iHigh(m_symbol,m_period,k), l=iLow(m_symbol,m_period,k);
            if(run==0) runExtreme=(type==OB_BULLISH)?l:h;
            else       runExtreme=(type==OB_BULLISH)?MathMin(runExtreme,l):MathMax(runExtreme,h);
            run++;
            if(run>=InpMinERCCount) { nearEdge=runExtreme; return true; }
           }
         else run=0;
        }
      return false;
     }

   // Secondary/optional imbalance test: classic 3-candle Fair Value Gap (a single very strong
   // displacement candle can leave a literal untraded gap even without qualifying as 2+ ERCs).
   bool FindImbalanceFVG(OB_TYPE type,int obShift,int breakoutShift,double &gapNearEdge)
     {
      for(int k=obShift-2; k>=breakoutShift; k--)
        {
         double h_k =iHigh(m_symbol,m_period,k);
         double l_k =iLow(m_symbol,m_period,k);
         double h_k2=iHigh(m_symbol,m_period,k+2);
         double l_k2=iLow(m_symbol,m_period,k+2);
         if(type==OB_BULLISH && l_k>h_k2) { gapNearEdge=h_k2; return true; }
         if(type==OB_BEARISH && h_k<l_k2) { gapNearEdge=l_k2; return true; }
        }
      return false;
     }

   double ImpulseExtreme(OB_TYPE type,int obShift,int breakoutShift)
     {
      double ext=(type==OB_BULLISH)?iHigh(m_symbol,m_period,breakoutShift):iLow(m_symbol,m_period,breakoutShift);
      for(int k=breakoutShift; k<=obShift-1; k++)
        {
         double h=iHigh(m_symbol,m_period,k), l=iLow(m_symbol,m_period,k);
         if(type==OB_BULLISH) ext=MathMax(ext,h); else ext=MathMin(ext,l);
        }
      return ext;
     }

   bool FindOBCandle(OB_TYPE type,int breakoutShift,int &obShiftOut)
     {
      for(int s=breakoutShift+1; s<=breakoutShift+InpOBSearchBars; s++)
        {
         double o=iOpen(m_symbol,m_period,s), c=iClose(m_symbol,m_period,s);
         if(type==OB_BULLISH && c<o) { obShiftOut=s; return true; }
         if(type==OB_BEARISH && c>o) { obShiftOut=s; return true; }
        }
      return false;
     }

   // Risk-Entry pricing Hint: wicky vs non-wicky candle -> Entry & SL.
   void ComputeEntrySL(OrderBlockInfo &ob)
     {
      double range=ob.high-ob.low;
      if(range<=0) range=_Point;
      if(ob.type==OB_BULLISH)
        {
         double upperWick=ob.high-ob.open;         // bearish OB candle: body top ~= open
         ob.wicky=((upperWick/range)>InpWickyRatioThreshold);
         ob.entry=ob.wicky ? ob.open : ob.high;
         ob.sl=ob.low;
        }
      else
        {
         double lowerWick=ob.open-ob.low;          // bullish OB candle: body bottom ~= open
         ob.wicky=((lowerWick/range)>InpWickyRatioThreshold);
         ob.entry=ob.wicky ? ob.open : ob.low;
         ob.sl=ob.high;
        }
      ob.risk=MathAbs(ob.entry-ob.sl);
     }

   // Rule 7 (HTF confluence): finds a still-active (not taken out), VALID, same-direction OB in THIS
   // engine's own obList whose price zone overlaps [refLow,refHigh] within `tolerance`, and which
   // existed strictly before `beforeTime` (this time filter is what keeps the historical back-fill
   // free of look-ahead bias regardless of the order the three engines are built in).
   bool FindAlignedOB(OB_TYPE type,double refLow,double refHigh,datetime beforeTime,double tolerance,OrderBlockInfo &found)
     {
      for(int i=ArraySize(obList)-1;i>=0;i--)
        {
         if(obList[i].type!=type) continue;
         if(!obList[i].valid) continue;
         if(obList[i].takenOut) continue;
         if(obList[i].time>=beforeTime) continue;
         bool overlap=!(obList[i].low>refHigh+tolerance || obList[i].high<refLow-tolerance);
         if(overlap) { found=obList[i]; return true; }
        }
      return false;
     }

   int CountValidOBs()
     {
      int v=0;
      for(int i=0;i<ArraySize(obList);i++) if(obList[i].valid) v++;
      return v;
     }

   void CleanupOldOBs()
     {
      int cap=300;
      int n=ArraySize(obList);
      if(n<=cap) return;
      ArrayRemove(obList,0,n-cap);
     }

   // Runs every enabled Tradable-OB rule and sets ob.valid / ob.rejectReason / ob.tp1 / ob.tp2.
   // `parent` is the next-higher-timeframe engine to confluence against (NULL for the HTF engine,
   // which sits at the top of the hierarchy and has nothing above it to confirm against).
   void ValidateOB(OrderBlockInfo &ob,int obShift,int breakoutShift,COBTimeframeEngine *parent)
     {
      ComputeEntrySL(ob);
      bool pass=true;
      string reasons="";

      //--- Practical safety filter (not one of the strategy rules): reject OBs whose SL distance is
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
         if(NearSwing(swingLows,ob.low,ob.time,proxTol,sp))
           {
            nearSR=true;
            if(HasEarlierOpposite(swingHighs,sp.price,sp.time,proxTol)) flip=true;
           }
        }
      else
        {
         if(NearSwing(swingHighs,ob.high,ob.time,proxTol,sp))
           {
            nearSR=true;
            if(HasEarlierOpposite(swingLows,sp.price,sp.time,proxTol)) flip=true;
           }
        }
      if(InpReq_NearSR   && !nearSR) { pass=false; reasons+="Rule1:NotAtS/R;"; }
      if(InpReq_FlipZone && !flip)   { pass=false; reasons+="Rule2:NoFlipZone;"; }

      //--- Rule 3: BMS - guaranteed true (an OB is only ever formed off a confirmed structure break)

      //--- Rule 4: Imbalance/Liquidity-Void >= 2x OB (ERC-run primary, FVG optional fallback), RR >= 3x OB
      double gapEdge=0.0;
      bool hasImb=FindERCImbalance(ob.type,obShift,breakoutShift,gapEdge);
      if(!hasImb && InpAllowFVGAsImbalance)
         hasImb=FindImbalanceFVG(ob.type,obShift,breakoutShift,gapEdge);
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

      //--- Rule 5: the OB must take out a PRIOR, ITSELF-VALID opposing Order Block
      bool opposingOK=false;
      OB_TYPE oppType=(ob.type==OB_BULLISH)?OB_BEARISH:OB_BULLISH;
      int checked=0;
      for(int i=ArraySize(obList)-1; i>=0 && checked<InpOpposingLookbackOBs; i--)
        {
         if(obList[i].type!=oppType) continue;
         checked++;
         if(!obList[i].valid) continue;              // opposing OB must itself be tradable/valid
         if(obList[i].time>=ob.time) continue;
         if(obList[i].takenOut) continue;
         bool violated=false;
         if(oppType==OB_BEARISH)
           {
            for(int k=breakoutShift;k<=obShift;k++)
               if(iClose(m_symbol,m_period,k)>obList[i].high) { violated=true; break; }
           }
         else
           {
            for(int k=breakoutShift;k<=obShift;k++)
               if(iClose(m_symbol,m_period,k)<obList[i].low) { violated=true; break; }
           }
         if(violated) { opposingOK=true; obList[i].takenOut=true; break; }
        }
      if(InpReq_OpposingOBTaken && !opposingOK) { pass=false; reasons+="Rule5:NoValidOpposingOBTaken;"; }

      //--- Rule 6: BeOB above SSR / BuOB below SSR (no major obstruction before target)
      bool ssrOK=!SSRObstructs(ob.type,ob);
      if(InpReq_SSRPosition && !ssrOK) { pass=false; reasons+="Rule6:SSRObstruction;"; }

      //--- Rule 7: genuine HTF -> Confirmation -> Entry Order Block confluence (see FindAlignedOB).
      //    Because `parent` was itself only marked valid after confirming against ITS OWN parent,
      //    passing this check transitively enforces the full hierarchy, not just one level of it.
      if(InpUseHTFConfluence && parent!=NULL)
        {
         OrderBlockInfo aligned;
         double tol=parent.GetATR(0)*InpConfluenceATRMult;
         if(!parent.FindAlignedOB(ob.type,ob.low,ob.high,ob.time,tol,aligned))
           {
            pass=false;
            reasons+="Rule7:NoParentTFOBConfluence;";
           }
        }

      ob.valid=pass;
      ob.rejectReason = pass ? "VALID - all enabled Tradable-OB rules satisfied" : reasons;
     }

   void TryFormOrderBlock(OB_TYPE type,int breakoutShift,bool liveMode,COBTimeframeEngine *parent)
     {
      int obShift;
      if(!FindOBCandle(type,breakoutShift,obShift)) return;

      datetime obTime=iTime(m_symbol,m_period,obShift);
      for(int i=0;i<ArraySize(obList);i++)
         if(obList[i].time==obTime && obList[i].type==type) return; // already recorded

      OrderBlockInfo ob;
      ob.type=type;
      ob.time=obTime;
      ob.barShiftAtDetect=obShift;
      ob.high=iHigh(m_symbol,m_period,obShift);
      ob.low =iLow(m_symbol,m_period,obShift);
      ob.open=iOpen(m_symbol,m_period,obShift);
      ob.close=iClose(m_symbol,m_period,obShift);
      ob.takenOut=false;
      ob.tradedFlag=false;
      ob.pendingTicket=0;
      ob.positionTicket=0;
      ob.expiryTime=0;
      ob.rejectReason="";

      ValidateOB(ob,obShift,breakoutShift,parent);

      int n=ArraySize(obList);
      ArrayResize(obList,n+1);
      obList[n]=ob;

      bool shouldDraw = m_canTrade
                        ? (InpShowOBBoxes && (obList[n].valid || InpShowRejectedOB))
                        : (InpShowHTFOBBoxes && obList[n].valid);
      if(shouldDraw) DrawOBBox(m_tag,obList[n]);

      if(obList[n].valid && liveMode && m_canTrade)
         OnValidEntryOB(obList[n]);
     }

   void CancelOppositePendings(OB_TYPE justConfirmedType)
     {
      if(!m_canTrade) return;
      OB_TYPE opp=(justConfirmedType==OB_BULLISH)?OB_BEARISH:OB_BULLISH;
      for(int i=0;i<ArraySize(obList);i++)
        {
         if(obList[i].type==opp && obList[i].pendingTicket!=0 && obList[i].positionTicket==0)
           {
            if(OrderSelect(obList[i].pendingTicket))
               trade.OrderDelete(obList[i].pendingTicket);
            obList[i].pendingTicket=0;
           }
        }
     }

   void CheckForBOSAndOB(int base,bool liveMode,COBTimeframeEngine *parent)
     {
      double c=iClose(m_symbol,m_period,base);
      if(lastSwingHighPrice>0 && !lastSwingHighBroken && c>lastSwingHighPrice)
        {
         lastSwingHighBroken=true;
         TryFormOrderBlock(OB_BULLISH,base,liveMode,parent);
         if(liveMode) CancelOppositePendings(OB_BULLISH);
        }
      if(lastSwingLowPrice>0 && !lastSwingLowBroken && c<lastSwingLowPrice)
        {
         lastSwingLowBroken=true;
         TryFormOrderBlock(OB_BEARISH,base,liveMode,parent);
         if(liveMode) CancelOppositePendings(OB_BEARISH);
        }
     }

   // Causal, look-ahead-free processing of one closed bar. `base` is the shift of the bar that just
   // closed (base=1 live; BuildHistoricalContext() replays base=N..1 to seed state).
   void ProcessClosedBar(int base,bool liveMode,COBTimeframeEngine *parent)
     {
      CheckForBOSAndOB(base,liveMode,parent);
      UpdateSwingPoints(base);
      CleanupOldOBs();
     }

   void BuildHistoricalContext(int maxBars,COBTimeframeEngine *parent)
     {
      int bars=Bars(m_symbol,m_period);
      int scan=MathMin(maxBars, bars-InpSwingLength*2-InpOBSearchBars-5);
      if(scan<10) { PrintFormat("[OB-EA][%s] Not enough history to build context yet.",m_tag); return; }
      for(int base=scan; base>=1; base--)
         ProcessClosedBar(base,false,parent);
      PrintFormat("[OB-EA][%s] Context built: swings(H/L)=%d/%d OBs=%d(valid=%d) SSR=%d",
                  m_tag,ArraySize(swingHighs),ArraySize(swingLows),ArraySize(obList),CountValidOBs(),ArraySize(ssrLevels));
     }
  };

//====================================================================================================
// GLOBALS
//====================================================================================================
COBTimeframeEngine g_htfEngine;
COBTimeframeEngine g_ctfEngine;
COBTimeframeEngine g_entryEngine;

PendingPlan       g_pendingPlans[];
ManagedTradeInfo  g_managedTrades[];

datetime g_dayStart      = 0;
double   g_dayStartEquity= 0.0;
int      g_tradesToday   = 0;

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

void OnValidEntryOB(OrderBlockInfo &ob)
  {
   if(InpAlertsEnabled)
     {
      string msg=StringFormat("%s Valid %s OrderBlock (HTF confluence confirmed) @ %s | Entry=%.5f SL=%.5f TP1=%.5f TP2=%.5f",
                               _Symbol, ob.type==OB_BULLISH?"BULLISH":"BEARISH",
                               TimeToString(ob.time,TIME_DATE|TIME_MINUTES),
                               ob.entry,ob.sl,ob.tp1,ob.tp2);
      Alert(msg);
      SendNotification(msg);
     }
   PlacePendingOrder(ob);
  }

void PlacePendingOrder(OrderBlockInfo &ob)
  {
   if(!InpEnableTrading) return;
   if(!InSession()) return;
   if((double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD) > InpMaxSpreadPoints) return;
   if(CountOpenPositions()>=InpMaxOpenTrades) return;
   if(g_tradesToday>=InpMaxTradesPerDay) return;
   if(DailyLossLimitHit()) return;

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

      for(int j=0;j<ArraySize(g_entryEngine.obList);j++)
         if(g_entryEngine.obList[j].pendingTicket==ordTicket) { g_entryEngine.obList[j].positionTicket=trans.position; break; }

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
         double atr=g_entryEngine.GetATR(0);
         double newSL = isBuy ? price-atr*InpTrailATRMultiplier : price+atr*InpTrailATRMultiplier;
         bool improve = isBuy ? (newSL>curSL) : (curSL==0 || newSL<curSL);
         if(improve)
            ModifyPositionByTicket(ticket,newSL,curTP);
        }
     }
  }

void ManagePendingOrders()
  {
   for(int i=0;i<ArraySize(g_entryEngine.obList);i++)
     {
      if(g_entryEngine.obList[i].pendingTicket==0 || g_entryEngine.obList[i].positionTicket!=0) continue;
      if(!OrderSelect(g_entryEngine.obList[i].pendingTicket))
        {
         // order no longer exists (filled elsewhere, expired, or manually removed)
         g_entryEngine.obList[i].pendingTicket=0;
         continue;
        }
      if(g_entryEngine.obList[i].expiryTime>0 && TimeCurrent()>=g_entryEngine.obList[i].expiryTime)
        {
         trade.OrderDelete(g_entryEngine.obList[i].pendingTicket);
         g_entryEngine.obList[i].pendingTicket=0;
        }
     }
  }

//====================================================================================================
// VISUALIZATION
//====================================================================================================
void DrawOBBox(string tag,OrderBlockInfo &ob)
  {
   string name="OBEA_"+tag+"_"+(ob.type==OB_BULLISH?"BU_":"BE_")+IntegerToString((long)ob.time);
   if(ObjectFind(0,name)>=0) ObjectDelete(0,name);

   datetime t2=TimeCurrent()+(datetime)(PeriodSeconds(_Period)*30);
   ObjectCreate(0,name,OBJ_RECTANGLE,0,ob.time,ob.high,t2,ob.low);

   color c;
   if(!ob.valid)        c=clrSilver;
   else if(tag=="HTF")  c=clrDarkOrange;
   else if(tag=="CTF")  c=clrDodgerBlue;
   else                 c=(ob.type==OB_BULLISH)?clrLimeGreen:clrTomato;

   ObjectSetInteger(0,name,OBJPROP_COLOR,c);
   ObjectSetInteger(0,name,OBJPROP_STYLE,ob.valid?STYLE_SOLID:STYLE_DOT);
   ObjectSetInteger(0,name,OBJPROP_FILL,ob.valid && tag=="ENTRY");
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,tag=="ENTRY"?1:2);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,
                   StringFormat("[%s] %s %s\nEntry=%.5f SL=%.5f TP1=%.5f TP2=%.5f\n%s",
                                tag, ob.type==OB_BULLISH?"BuOB":"BeOB", ob.valid?"(TRADABLE)":"(non-tradable)",
                                ob.entry,ob.sl,ob.tp1,ob.tp2,ob.rejectReason));
  }

void DrawSSRLevels()
  {
   ObjectsDeleteAll(0,"OBEA_SSR_");
   for(int i=0;i<ArraySize(g_entryEngine.ssrLevels);i++)
     {
      if(g_entryEngine.ssrLevels[i].touches<InpSSR_MinTouches) continue;
      string name="OBEA_SSR_"+IntegerToString(i);
      ObjectCreate(0,name,OBJ_HLINE,0,0,g_entryEngine.ssrLevels[i].price);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrDodgerBlue);
      ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DASHDOT);
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetString(0,name,OBJPROP_TOOLTIP,StringFormat("Significant S/R  touches=%d",g_entryEngine.ssrLevels[i].touches));
     }
  }

void UpdateDashboard()
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = (g_dayStartEquity>0) ? (g_dayStartEquity-eq)/g_dayStartEquity*100.0 : 0.0;

   string s="";
   s+="====== SMC Tradable-OrderBlock EA (Multi-TF) ======\n";
   s+=StringFormat("Symbol: %s\n",_Symbol);
   s+=StringFormat("HTF(%s): OBs=%d valid=%d\n",EnumToString(g_htfEngine.m_period),ArraySize(g_htfEngine.obList),g_htfEngine.CountValidOBs());
   s+=StringFormat("CTF(%s): OBs=%d valid=%d\n",EnumToString(g_ctfEngine.m_period),ArraySize(g_ctfEngine.obList),g_ctfEngine.CountValidOBs());
   s+=StringFormat("Entry(%s): OBs=%d valid=%d\n",EnumToString(g_entryEngine.m_period),ArraySize(g_entryEngine.obList),g_entryEngine.CountValidOBs());
   s+=StringFormat("HTF Confluence required: %s\n",InpUseHTFConfluence?"YES":"NO");
   s+=StringFormat("Trading: %s\n",InpEnableTrading?"ON":"OFF");
   s+=StringFormat("Open Trades: %d/%d    Today: %d/%d\n",CountOpenPositions(),InpMaxOpenTrades,g_tradesToday,InpMaxTradesPerDay);
   s+=StringFormat("Equity: %.2f   Daily DD: %.2f%% (limit %.2f%%)\n",eq,ddPct,InpMaxDailyLossPercent);
   s+=StringFormat("Pending orders: %d\n",ArraySize(g_pendingPlans));
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

   bool okHTF  = g_htfEngine.Init(_Symbol,InpHTFPeriod,"HTF",false);
   bool okCTF  = g_ctfEngine.Init(_Symbol,InpConfirmationPeriod,"CTF",false);
   bool okEntry= g_entryEngine.Init(_Symbol,_Period,"ENTRY",true);
   if(!okHTF || !okCTF || !okEntry)
     {
      PrintFormat("[OB-EA] Failed to create ATR indicator handles (HTF=%s CTF=%s ENTRY=%s).",
                  okHTF?"OK":"FAIL",okCTF?"OK":"FAIL",okEntry?"OK":"FAIL");
      return(INIT_FAILED);
     }

   if(InpUseHTFConfluence && !(InpHTFPeriod>InpConfirmationPeriod && InpConfirmationPeriod>_Period))
      Print("[OB-EA] WARNING: expected InpHTFPeriod > InpConfirmationPeriod > chart period for a genuine top-down hierarchy.");

   ArrayResize(g_pendingPlans,0);
   ArrayResize(g_managedTrades,0);

   // Build oldest-to-newest so each engine's own history is causal; the FindAlignedOB() time filter
   // additionally guarantees no look-ahead across engines regardless of this build order.
   g_htfEngine.BuildHistoricalContext(InpMaxBarsHistory,NULL);
   g_ctfEngine.BuildHistoricalContext(InpMaxBarsHistory,GetPointer(g_htfEngine));
   g_entryEngine.BuildHistoricalContext(InpMaxBarsHistory,GetPointer(g_ctfEngine));

   ResetDailyStats();
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

   datetime tHTF=iTime(_Symbol,g_htfEngine.m_period,0);
   if(tHTF!=g_htfEngine.m_lastBarTime)
     {
      g_htfEngine.m_lastBarTime=tHTF;
      g_htfEngine.ProcessClosedBar(1,true,NULL);
     }

   datetime tCTF=iTime(_Symbol,g_ctfEngine.m_period,0);
   if(tCTF!=g_ctfEngine.m_lastBarTime)
     {
      g_ctfEngine.m_lastBarTime=tCTF;
      g_ctfEngine.ProcessClosedBar(1,true,GetPointer(g_htfEngine));
     }

   datetime tEntry=iTime(_Symbol,g_entryEngine.m_period,0);
   if(tEntry!=g_entryEngine.m_lastBarTime)
     {
      g_entryEngine.m_lastBarTime=tEntry;
      g_entryEngine.ProcessClosedBar(1,true,GetPointer(g_ctfEngine));
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
