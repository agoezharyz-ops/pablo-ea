//+------------------------------------------------------------------+
//|  PabloLayerEA_v2.19-ADAPTIF.mq5                                   |
//|  EA Layer Sentinel - 2 MODE ENTRY + TP / CUT LOSS SOLID          |
//|                                                                  |
//|  ============ v2.17 : SPIDER-PRO (2 SISI / GRID HEDGE) =========== |
//|  Saat FLAT: pasang BUY LIMIT **dan** SELL LIMIT sekaligus.          |
//|  Jadi chart ada 2 garis (biru = buy, oranye = sell) -> kayak jaring  |
//|  laba-laba; harga gerak ke mana saja, kena jaring.                  |
//|  NoHedge dimatikan utk entry awal, tapi saat sudah ada posisi       |
//|  tetap ikut aturan InpNoHedge (default false = boleh hedge).        |
//|  Garis level candle (dot) + label harga entry + label lot.          |
//|  -------------------------------------------------------------- |
//|  TUJUAN: biar kelihatan di harga BERAPA EA mau buy / sell.        |
//|  Uji di backtest/demo dulu. Jangan langsung akun real.            |
//|                                                                  |
//|  Basis: setelan Aska (16-09-2026) + model NPBOT-SPIDER-PRO       |
//|  Target: XAUUSD / XAUUSDc (Exness/HFM CENT, 2 digit)             |
//|                                                                  |
//|  ================= FITUR BARU v2.00 =================             |
//|  1. DUA MODE ENTRY:                                              |
//|     - MODE_MARKET  : langsung buy/sell di harga (versi v1.00)    |
//|     - MODE_PENDING : Buy Limit / Sell Limit (model SPIDER-PRO)   |
//|  2. Tiga gaya sinyal pending:                                    |
//|     - SIG_CANDLE   : candle bearish -> Sell Limit, bullish ->    |
//|                      Buy Limit (persis SPIDER-PRO)               |
//|     - SIG_EMA      : cross EMA cepat/lambat                      |
//|     - SIG_EMA_CANDLE : cross EMA + arah candle (rekomendasi)     |
//|  3. CUT LOSS SOLID (WAJIB - ini yang diminta):                   |
//|     - CutLoss per-posisi (SL harga)                              |
//|     - CutLoss basket (uang) -> tutup semua + pending             |
//|     - CutLoss equity % harian -> tutup semua + stop hari itu     |
//|  4. TAKE PROFIT SOLID:                                           |
//|     - TP per-posisi (harga)                                     |
//|     - TP basket (uang) -> tutup semua jadi satu                  |
//|     - Target profit harian (uang)                                |
//|  5. Trailing + BEP tetap ada (opsional, aman utk pending)        |
//|                                                                  |
//|  CATATAN SATUAN (penting!):                                      |
//|  - Semua input "Harga" (TP/SL/layer) pakai HARGA LANGSUNG gold.  |
//|    Contoh: TP 2.0 = $2, SL 5.0 = $5, jarak layer 60.0 = $60.     |
//|  - Input "uang" (CutLoss $/TP basket $/target harian) = mata uang |
//|    akun (di akun CENT: 1 = 1 cent).                              |
//|  - Di broker 2 digit (Exness/HFM): 1 point = 0.01.               |
//|                                                                  |
//|  ================= PERBAIKAN v2.14 =================            |
//|  KRITIS                                                          |
//|   1. RiskGuard dipanggil paling awal di OnTick. Dulu spread guard |
//|      keluar duluan, jadi cut loss tidak jalan saat spread lebar.  |
//|   2. RiskGuard: target harian & cut loss equity kini tetap dicek  |
//|      walau sedang flat (dulu return dini saat tidak ada posisi).  |
//|   3. Layering pending: anti-duplikat + batas layer dihitung dari  |
//|      posisi + pending (dulu bisa spam pending di level sama).     |
//|   4. Satuan body candle diperbaiki (dulu dikali _Point, jadi 100x |
//|      terlalu kecil; filter news menolak hampir semua candle).     |
//|   5. Level pending dari candle dulu terbalik (bullish->high).     |
//|  PENTING                                                          |
//|   6. SL/TP & harga pending menghormati stops/freeze level broker. |
//|   7. Expiry pending fallback ke GTC bila broker tidak mendukung.  |
//|   8. Panel: pembagian nol saat InpMaxEquityDD=0; panel di-update  |
//|      di semua jalur OnTick (dulu beku saat stop/news/jam lock).   |
//|   9. Profit harian: DEAL_ENTRY_INOUT/OUT_BY + komisi deal masuk.  |
//|  10. Filter news: cache hasil, jam manual lintas tengah malam,    |
//|      rata2 spread tidak lagi terdistorsi oleh panel.              |
//|  11. InpGunakanEMAFilter akhirnya benar2 dipakai (dulu mati).     |
//|  12. Validasi input di OnInit, modify SL divalidasi dulu.         |
//|                                                                  |
//|  ⚠️  BELUM dites di live. WAJIB Strategy Tester + demo dulu.      |
//|  ⚠️  Ini EA averaging/grid: risiko turun bertingkat. Cut loss     |
//|      basket & equity WAJIB aktif.                                 |
//+------------------------------------------------------------------+
#property copyright "Pablo - Keluarga Cemara"
#property version   "2.212"

#include <Trade\Trade.mqh>

//==================================================================
// ENUM
//==================================================================
enum ENUM_ENTRY_MODE
  {
   MODE_PENDING = 0,   // Pending Order (Buy/Sell Limit) - model SPIDER-PRO
   MODE_MARKET  = 1    // Market Order langsung
  };

enum ENUM_SIGNAL_MODE
  {
   SIG_CANDLE      = 0,  // Candle arah (bearish->SellLimit, bullish->BuyLimit)
   SIG_EMA         = 1,  // Cross EMA cepat x lambat
   SIG_EMA_CANDLE  = 2   // Cross EMA + arah candle (rekomendasi)
  };

//==================================================================
// INPUT
//==================================================================
input group "=== MODE ENTRY ==="
input ENUM_ENTRY_MODE  InpEntryMode   = MODE_PENDING;      // Mode entry (v2.16: pending limit = ada GARIS)
input ENUM_SIGNAL_MODE InpSignalMode  = SIG_CANDLE;        // Sumber sinyal (arah candle M1)
input double           InpPendingDist = 0.50;              // Jarak pending dari harga (RAPET: $0.50)
input int              InpPendingExpireHrs = 24;           // Pending kadaluarsa (jam, 0=off)

input group "=== LOT & LAYER ==="
input double InpLotAwal        = 0.01;   // Lot awal (layer 1)
input double InpLotCustom      = 0.01;   // Lot custom (tambah per layer)
input int    InpMaxLayer       = 6;      // Maksimal layer per arah
input double InpMaxLot         = 0.03;   // Maksimal lot per posisi
input double InpJarakLayer     = 1.5;    // Jarak antar layer (RAPET: $1.5)

input group "=== ENTRY CONTROL ==="
input bool   InpAktifBuy       = true;   // Aktifkan Buy
input bool   InpAktifSell      = true;   // Aktifkan Sell
input bool   InpHanyaJikaKosong= false;  // Entry basket baru hanya jika flat (off)
input bool   InpNoHedge        = false;  // Larang OP berlawanan (SPIDER: false = boleh hedge)

input group "=== TP / CUT LOSS (WAJIB) ==="
input bool   InpTPAdaptif      = true;   // v2.19: TP ikut kondisi market (ATR)
input double InpTPMin          = 0.60;   // TP minimal ($) saat market sepi
input double InpTPMax          = 4.00;   // TP maksimal ($) saat market volatil
input double InpTPATRMult      = 1.20;   // TP = ATR M1 x faktor ini (dipakai saat adaptif)
input double InpTakeProfit     = 1.0;    // TP per posisi (dipakai kalau InpTPAdaptif=false) 0=off
input bool   InpPakaiBasketTP  = true;   // Pakai TP basket (uang)
input double InpBasketTPMoney  = 1.5;    // TP basket AWAL (skala ikut TP adaptif)
input double InpStopLoss       = 5.0;    // SL per posisi (HARGA, 5.0=$5) 0=off
input bool   InpPakaiBasketCL  = true;   // Pakai Cut Loss basket (uang)
input double InpBasketCLMoney  = 10.0;   // Cut loss basket (uang) -> tutup semua
input bool   InpPakaiEquityCL  = true;   // Pakai Cut Loss equity harian (%)
input double InpMaxEquityDD    = 20.0;   // Max drawdown equity harian (%)
input double InpTargetHarian   = 50.0;   // Target profit harian (uang, 0=off)

input group "=== BEP ==="
input bool   InpGunakanBEP     = true;   // Gunakan BEP
input double InpBEPTrigger     = 1.0;    // BEP aktif saat profit (HARGA, 1.0=$1)
input double InpBEPLock        = 0.30;   // Kunci profit BEP (HARGA, 0.30=30 cent)

input group "=== TRAILING ==="
input bool   InpGunakanTrailing= true;   // Gunakan Trailing
input double InpTrailStart     = 1.5;    // Trailing start (HARGA, 1.5=$1.5)
input double InpTrailStep      = 0.5;    // Trailing step (HARGA, 0.5=50 cent)

input group "=== FILTER ==="
input bool   InpGunakanEMAFilter = false;// Pakai EMA sbg filter tren (off)
input int    InpEmaCepat         = 10;   // EMA cepat
input int    InpEmaLambat        = 20;   // EMA lambat
input ENUM_TIMEFRAMES InpTFEMA   = PERIOD_M1; // Timeframe EMA (M1)

input group "=== CANDLE TRIGGER (SPIDER-PRO) ==="
input ENUM_TIMEFRAMES InpCandleTF    = PERIOD_M1; // Timeframe trigger candle (M1)
input double          InpCandleMin   = 0.02;      // Body minimal candle (RAPET: $0.02) 0=off
input double          InpCandleMax   = 0.0;       // Body maksimal candle (AGRESIF: 0=off)
input bool            InpCandleSkipNews = false;  // Tolak candle news (off)
input bool            InpShowLevel     = true;    // Tampilkan garis level candle
input bool            InpTampilkanGaris= true;    // v2.16: tampilkan GARIS order pending di chart
input bool            InpOneShotLadder= false;   // v2.18: rapat jarang; true = 1 layer/tick, false = isi ladder penuh

input group "=== TARGET % & JAM LOCK ==="
input bool   InpTargetPersen    = true;   // Target pakai % saldo (bukan angka uang fix)
input double InpTargetPersenVal = 5.0;    // Target profit harian (% saldo)
input bool   InpPakaiJamLock    = false;  // Aktifkan lock jam (off)
input int    InpJamLockStop     = 1;      // Jam BERHENTI trading (jam broker)
input int    InpJamLockResume   = 3;      // Jam MULAI trading lagi (jam broker)
input bool   InpJamLockTutupPos = true;   // Tutup semua posisi saat jam lock

input group "=== CHASE PENDING (v2.21, adopsi SPIDER-PRO) ==="
input bool   InpPakaiChase       = true;   // Geser pending ikut harga kalau belum kena
input double InpChaseTrigger     = 2.0;    // Geser kalau harga menjauh > $ ini dari pending
input int    InpChaseMaxUlang    = 0;      // Maks geser per pending (0=tanpa batas)

input group "=== REGIME SWITCH (v2.21, fleksibel ikut market) ==="
input bool   InpPakaiRegime      = true;   // Aktifkan mode adaptif tren/sideways

input group "=== FILTER SIDEWAYS (v2.21.2, adopsi IronGrid) ==="
input bool   InpPakaiSideways    = true;   // v2.21.2: entry basket BARU hanya saat SIDEWAYS
input int    InpSidewaysLookback = 100;    // Jumlah candle M1 untuk hitung cross
input int    InpSidewaysMinCross = 100;    // Minimal cross (harga lewat MA) = SIDEWAYS
input bool   InpSidewaysPakaiAdx = true;   // Cek tambahan: ADX harus <= InpAdxSepi
input double InpAdxTren          = 25.0;   // ADX >= ini = TREN kuat
input double InpAdxSepi          = 15.0;   // ADX <= ini = SIDEWAYS
input double InpRegimeJarakMult  = 1.60;   // Saat TREN: jarak layer x ini (lebar)
input double InpRegimeTPMult     = 1.30;   // Saat TREN: TP x ini (lebih lebar)

input group "=== TRAILING BASKET (v2.21) ==="
input bool   InpPakaiTrailBasket = true;   // Kunci profit basket saat untung
input double InpTrailBasketMulai = 3.0;    // Mulai trailing saat basket untung ($)
input double InpTrailBasketJaga  = 1.0;    // SL basket = puncak untung - $ ini

input group "=== HEDGE PENUTUP OTOMATIS (v2.20.1) ==="
input bool InpPakaiHedgePenutup   = false; // Aktifkan auto-hedge saat basket rugi
input double InpHedgeTriggerMoney = 2.50;  // Rugi floating yang memicu hedge ($)
input double InpHedgeLotMult      = 1.0;   // Lot hedge = lot terbesar sisi rugi x ini
input double InpHedgeMinProfit    = 0.50;  // Tutup SEPASANG kalau laba pasangan >= ($)
input double InpHedgeStopMoney    = 3.00;  // v2.21.1: kalau hedge RUGI >= ($) -> tutup paksa

input group "=== COOLDOWN / JEDA ENTRY (v2.20) ==="
input bool   InpPakaiCooldown      = true;  // Aktifkan jeda antar entry (v2.20)
input int    InpCooldownDetikEntry = 90;    // Jeda min antar ENTRY baru (detik)
input int    InpCooldownDetikLayer = 20;    // Jeda min antar penambahan LAYER (detik)

input group "=== ANTI-NEWS ==="
input bool   InpPakaiNews        = false; // Aktifkan filter news (off)
input int    InpNewsAksi         = 1;     // Aksi news: 1=blok entry, 2=blok+tutup, 3=blok+tutup+jeda
input int    InpNewsJedaMenit    = 30;    // Jeda setelah news (menit, utk aksi 3)
input int    InpNewsMinImpact    = 2;     // Impact minimal (1=Low,2=Medium,3=High)
input bool   InpNewsPakaiKalender= true;  // Baca kalender ekonomi MT5 (otomatis)
input string InpNewsMataUang     = "USD,XAU"; // Filter mata uang (pisah koma, kosong=semua)
input string InpNewsJamManual    = "20:30,02:00"; // Jam news manual (HH:MM, pisah koma)
input int    InpNewsJendelaMenit = 15;    // Jendela blok sebelum/sesudah news (menit)
input double InpNewsMaxSpreadMult= 3.0;   // Blok jika spread > normal x ini
input bool   InpNewsPakaiATR     = true;  // Pakai filter lonjakan ATR
input double InpNewsATRMult      = 2.5;   // Blok jika ATR > rata2 x ini
input int    InpNewsCacheDetik   = 10;    // Cache hasil cek news (detik)
input int    InpNewsATRPeriod    = 14;    // Periode ATR

input group "=== PANEL DASHBOARD ==="
input color  InpPanelBg        = C'18,18,24';   // Warna background panel
input color  InpPanelFg        = clrWhite;      // Warna teks panel
input color  InpPanelAccent    = C'255,200,0';  // Warna aksen (kuning)
input string InpPanelBrand     = "@Aska";       // Footer branding panel

input group "=== LAIN-LAIN ==="
input int    InpMagic          = 20260916; // Magic number
input int    InpSlippage       = 50;       // Slippage (points)
input int    InpMaxSpreadPts   = 0;        // Maks spread (points) 0=off
input bool   InpTampilkanPanel = true;     // Tampilkan panel di chart

//==================================================================
// GLOBAL
//==================================================================
CTrade   trade;
int      hEmaFast = INVALID_HANDLE;
int      hEmaSlow = INVALID_HANDLE;
double   emaF[], emaS[];
int      hAtr = INVALID_HANDLE;
double   atrBuf[];
// v2.19 ADAPTIF : TP dinamis + skala basket
int      hAdx = INVALID_HANDLE;
int      hMaSide = INVALID_HANDLE;  // v2.21.2: MA utk filter sideways
double   adxBuf[];
double   gTPNow        = 0;      // TP per-posisi aktif saat ini ($)
double   gBasketTPNow  = 0;      // TP basket aktif saat ini (uang)
double   gBasketCLNow  = 0;      // Cut loss basket aktif saat ini (uang)
double   gRegimeScore  = 0;      // 0..100 skor regime (tren+volatilitas)
MqlRates gRates[];
datetime lastBarTime   = 0;
datetime gLastDay      = 0;
double   gDayStartEquity = 0;
bool     gStoppedToday = false;   // cut loss equity / target harian kena
double   gLastCandleLevel = 0;
bool     gJamLockAktif = false;
datetime gLastEntryTime = 0;   // v2.20: waktu entry L1 terakhir (cooldown)
datetime gLastLayerTime = 0;   // v2.20: waktu penambahan layer terakhir
datetime gCooldownUntil = 0;   // v2.20: jeda setelah news (aksi 3)
datetime gLastTPAdaptif = 0;   // v2.20: throttle hitung TP adaptif
double   gHedgeLot        = 0;    // v2.20.1: lot hedge yang lagi dipakai
bool     gHedgePartnerBuy = false; // v2.20.1: true = hedge BUY, pasangan SELL
bool     gHedgeAktif      = false; // v2.20.1: kunci posisi hedge
ulong    gHedgeTicket     = 0;     // v2.20.1: tiket posisi hedge terbuka
// ---- v2.21 Adaptive Spider ----
double   gRegimeJarakMult = 1.0;   // pengali jarak layer menurut regime
double   gRegimeTPMult    = 1.0;   // pengali TP menurut regime
double   gTrailBasketPeak = 0.0;   // puncak untung basket (utk trailing basket)
double   gTrailBasketSL   = 0.0;   // level SL trailing basket ($)
bool     gRegimeTren      = false; // true = sedang tren kuat
bool     gSidewaysNow     = true;  // v2.21.2: true = pasar sideways (boleh entry baru)
int      gCrossCount      = 0;     // v2.21.2: jumlah cross dalam lookback


string   gLevelObjName = "PabloLayer_Level";

// cache anti-news (biar kalender tidak dibaca tiap tick)
datetime gNewsCheckTime = 0;
bool     gNewsBlocked   = false;
string   gNewsWhy       = "";
double   gAvgSpread     = 0;   // rata2 spread bergerak (dipakai filter volatilitas)

// ===== PANEL DASHBOARD =====
#define PN  "PabloPanel_"          // prefix semua objek panel
int      gPX = 12;                 // X awal panel
int      gPY = 22;                 // Y awal panel
int      gPW = 268;                // Lebar panel
int      gPRowH = 17;              // Tinggi baris
int      gPY0 = 0;                 // Y baris-0 (diisi saat create)

//==================================================================
int OnInit()
  {
   // ---- validasi input (cegah setelan mustahil) ----
   if(InpMaxLayer < 1)
     { Print("InpMaxLayer minimal 1"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpLotAwal <= 0)
     { Print("InpLotAwal harus > 0"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpJarakLayer <= 0)
     { Print("InpJarakLayer harus > 0"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpEntryMode == MODE_PENDING && InpPendingDist <= 0)
     { Print("InpPendingDist harus > 0 untuk MODE_PENDING"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpEmaCepat >= InpEmaLambat)
     { Print("InpEmaCepat harus lebih kecil dari InpEmaLambat"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpStopLoss > 0 && InpTakeProfit > 0 && InpBEPLock >= InpStopLoss)
      Print("Peringatan: InpBEPLock >= InpStopLoss, BEP praktis tidak menambah proteksi");
   if(InpPakaiEquityCL && InpMaxEquityDD <= 0)
      Print("Peringatan: InpMaxEquityDD <= 0, cut loss equity dimatikan");
   if(InpPakaiHedgePenutup && InpHedgeTriggerMoney <= 0)
      Print("Peringatan: InpPakaiHedgePenutup aktif tapi InpHedgeTriggerMoney <= 0");
   if(InpPakaiHedgePenutup)
      Print("Info v2.20.1: HEDGE PENUTUP aktif, pemicu $", DoubleToString(InpHedgeTriggerMoney,2),
            " lot x", DoubleToString(InpHedgeLotMult,2));
   if(InpPakaiCooldown && InpCooldownDetikEntry <= 0 && InpCooldownDetikLayer <= 0)
      Print("Peringatan: cooldown aktif tapi kedua jeda 0 detik = tidak ada rem");
   if(InpPakaiNews && InpNewsAksi >= 2)
      Print("Info v2.20: news aksi ", InpNewsAksi, " -> blok+tutup",
            (InpNewsAksi >= 3 ? "+jeda" : ""), " aktif");
   if(!InpPakaiNews)
      Print("PERINGATAN v2.20: InpPakaiNews=false -> EA akan entry normal saat news/FOMC");

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   hEmaFast = iMA(_Symbol, InpTFEMA, InpEmaCepat, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, InpTFEMA, InpEmaLambat, 0, MODE_EMA, PRICE_CLOSE);
   if(hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE)
     { Print("Gagal buat handle EMA"); return(INIT_FAILED); }

   hAtr = iATR(_Symbol, PERIOD_M1, InpNewsATRPeriod);
   if(hAtr == INVALID_HANDLE)
      Print("Peringatan: gagal buat handle ATR, filter ATR dimatikan");

   // v2.19: ADX utk deteksi regime pasar (tren vs sideways)
   hAdx = iADX(_Symbol, PERIOD_M1, 14);
   if(hAdx == INVALID_HANDLE)
      Print("Peringatan: gagal buat handle ADX, skor regime pakai ATR saja");

   // v2.21.2: MA200 M1 utk hitung cross sideways (adopsi IronGrid)
   hMaSide = iMA(_Symbol, PERIOD_M1, InpSidewaysLookback, 0, MODE_SMA, PRICE_CLOSE);
   if(hMaSide == INVALID_HANDLE)
      Print("Peringatan: gagal buat handle MA sideways, filter sideways nonaktif");
   ArraySetAsSeries(adxBuf, true);
   gTPNow       = InpTakeProfit;
   gBasketTPNow = InpBasketTPMoney;
   gBasketCLNow = InpBasketCLMoney;
   // NOTE: gTPNow/gBasketTPNow dihitung ulang tiap tick di OnTick
   // lewat UpdateAdaptif() supaya ikut kondisi pasar terkini.

   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaS, true);
   ArraySetAsSeries(atrBuf, true);
   ArraySetAsSeries(gRates, true);

   ResetDayTracker();
   if(InpTampilkanPanel) PanelCreate();
   Print("PabloLayerEA v2.21.1-hedgefix | ", _Symbol, " | digits=", _Digits,
         " point=", DoubleToString(_Point, 5),
         " | mode=", EnumToString(InpEntryMode));
   return(INIT_SUCCEEDED);
  }

//==================================================================
void OnDeinit(const int reason)
  {
   if(hEmaFast != INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow != INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hAtr     != INVALID_HANDLE) IndicatorRelease(hAtr);
   if(hAdx     != INVALID_HANDLE) IndicatorRelease(hAdx);
   ObjectDelete(0, gLevelObjName);
   // bersihkan semua garis pending v2.16
   ObjectsDeleteAll(0, "PabloPend_");
   PanelDelete();
   Comment("");
  }

//==================================================================
void ResetDayTracker()
  {
   gTrailBasketPeak = 0; gTrailBasketSL = 0;   // v2.21
   gLastDay        = TimeCurrent();
   gDayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   gStoppedToday   = false;
   gCooldownUntil  = 0;      // v2.20: reset jeda news tiap hari baru
  }

//==================================================================
bool NewBar()
  {
   datetime bt = iTime(_Symbol, Period(), 0);
   if(bt == lastBarTime) return false;
   lastBarTime = bt;
   return true;
  }

//==================================================================
// PROFIT: realized hari ini + floating
//==================================================================
double GetDayRealized()
  {
   double rp = 0;
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);
   if(!HistorySelect(dayStart, now)) return 0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      // Komisi sering dibebankan di deal MASUK, jadi komisi dihitung dari
      // semua deal, sedangkan profit/swap hanya dari deal keluar.
      // DEAL_ENTRY_INOUT dan OUT_BY juga menutup posisi (versi lama luput).
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      rp += HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY)
         continue;
      rp += HistoryDealGetDouble(d, DEAL_PROFIT)
          + HistoryDealGetDouble(d, DEAL_SWAP);
     }
   return rp;
  }

double GetEAFloating()
  {
   double fl = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      fl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return fl;
  }

double GetEAProfitToday() { return GetDayRealized() + GetEAFloating(); }

//==================================================================
void CountSides(int &buyCnt, int &sellCnt)
  {
   buyCnt = 0; sellCnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buyCnt++;
      else                                                       sellCnt++;
     }
  }

//==================================================================
// Pending order milik EA
//==================================================================
void CountPending(int &buyPend, int &sellPend)
  {
   buyPend = 0; sellPend = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot == ORDER_TYPE_BUY_LIMIT)  buyPend++;
      if(ot == ORDER_TYPE_SELL_LIMIT) sellPend++;
     }
  }

void DeleteAllPending()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      trade.OrderDelete(t);
     }
  }

//==================================================================
double GetLastOpenPrice(ENUM_POSITION_TYPE type)
  {
   double price = 0; datetime lastTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      if(ot > lastTime) { lastTime = ot; price = PositionGetDouble(POSITION_PRICE_OPEN); }
     }
   return price;
  }

//==================================================================
// Jarak minimal broker (stops level / freeze level) dalam HARGA
//==================================================================
double MinStopDistance()
  {
   long lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long frz = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long m   = (lvl > frz ? lvl : frz);
   if(m < 0) m = 0;
   return (double)m * _Point;
  }

// Broker mengizinkan expiry pending?
bool ExpirySupported()
  {
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   return ((mode & SYMBOL_EXPIRATION_SPECIFIED) != 0);
  }

// Sudah ada pending sejenis di sekitar harga ini?
bool PendingExistsNear(ENUM_ORDER_TYPE otype, double price, double tol)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != otype) continue;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - price) <= tol) return true;
     }
   return false;
  }

//==================================================================
double LotForLayer(int layerIndex)
  {
   double lot = InpLotAwal + (double)(layerIndex - 1) * InpLotCustom;
   if(InpMaxLot > 0 && lot > InpMaxLot) lot = InpMaxLot;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   lot = MathRound(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return lot;
  }

//==================================================================
// CANDLE TRIGGER (model SPIDER-PRO)
//  - Digunakan HANYA untuk entry pertama saat basket FLAT.
//  - Candle close terakhir [1] bearish -> Sell Limit, bullish -> Buy Limit
//  - Filter (opsional): jarak candle minimal (ATR/pips) + tolak candle news
//==================================================================
//  CATATAN: minBody / maxBody memakai HARGA langsung (0.30 = $0.30),
//  sama seperti input TP/SL/jarak layer. Versi lama mengalikan _Point
//  sehingga ambangnya jadi 100x terlalu kecil dan filter news menolak
//  hampir semua candle normal XAUUSD.
bool CandleTrigger(ENUM_TIMEFRAMES tf, double minBody, bool skipNews)
  {
   MqlRates r[];
   if(CopyRates(_Symbol, tf, 0, 3, r) < 3) return false;

   bool bullish = (r[1].close > r[1].open);
   bool bearish = (r[1].close < r[1].open);
   if(!bullish && !bearish) return false;

   double body = MathAbs(r[1].close - r[1].open);   // ukuran body candle [1]

   if(minBody > 0 && body < minBody) return false;

   // tolak candle news: body kelewat besar
   if(skipNews && InpCandleSkipNews && InpCandleMax > 0 && body > InpCandleMax)
      return false;

   return true;
  }

// =================================================================
// Sinyal (mode lama: EMA / EMA+Candle) - dipertahankan
// =================================================================
bool GetSignals(bool &buySig, bool &sellSig)
  {
   buySig = false; sellSig = false;

   bool useEmaCross = (InpSignalMode == SIG_EMA || InpSignalMode == SIG_EMA_CANDLE);

   // arah candle dibaca di TF trigger yang sama dengan mode SIG_CANDLE,
   // bukan TF chart, supaya sinyal konsisten ke mana pun EA dipasang
   if(CopyRates(_Symbol, InpCandleTF, 0, 3, gRates) < 3) return false;
   bool bullish = (gRates[1].close > gRates[1].open);
   bool bearish = (gRates[1].close < gRates[1].open);

   bool emaUp = true, emaDown = true;     // posisi EMA (filter tren)
   bool crossUp = true, crossDown = true; // momen cross

   if(useEmaCross || InpGunakanEMAFilter)
     {
      if(CopyBuffer(hEmaFast, 0, 0, 3, emaF) < 3) return false;
      if(CopyBuffer(hEmaSlow, 0, 0, 3, emaS) < 3) return false;
      emaUp     = (emaF[1] > emaS[1]);
      emaDown   = (emaF[1] < emaS[1]);
      crossUp   = emaUp   && (emaF[2] <= emaS[2]);
      crossDown = emaDown && (emaF[2] >= emaS[2]);
     }

   if(InpSignalMode == SIG_CANDLE)
     {
      buySig  = bullish;
      sellSig = bearish;
     }
   else if(InpSignalMode == SIG_EMA)
     {
      buySig  = crossUp;
      sellSig = crossDown;
     }
   else // SIG_EMA_CANDLE
     {
      buySig  = crossUp   && bullish;
      sellSig = crossDown && bearish;
     }

   // InpGunakanEMAFilter sebelumnya tidak pernah dipakai; sekarang benar2
   // memblok entry yang melawan posisi EMA cepat/lambat
   if(InpGunakanEMAFilter)
     {
      if(!emaUp)   buySig  = false;
      if(!emaDown) sellSig = false;
     }
   return true;
  }

//==================================================================
// Hitung SL & TP per posisi (harga)
//==================================================================
//==================================================================
// v2.19 ADAPTIF : hitung TP terkini dari ATR + regime pasar.
//  - Market sepi   -> TP kecil (cepat ambil profit kecil)
//  - Market volatil-> TP lebar  (biar gak kena noise, ambil gerakan)
// Di-clamp ke [InpTPMin, InpTPMax] supaya tidak ekstrem.
//==================================================================
double HitungTPAdaptif()
  {
   if(!InpTPAdaptif) return InpTakeProfit;

   double tp = InpTakeProfit;
   if(hAtr != INVALID_HANDLE && CopyBuffer(hAtr, 0, 0, 3, atrBuf) >= 3)
     {
      double atr = atrBuf[0];               // ATR M1 terkini (dalam harga)
      tp = atr * InpTPATRMult;
     }

   // regime boost : kalau ADX menunjukkan tren kuat, longgarkan TP
   if(hAdx != INVALID_HANDLE && CopyBuffer(hAdx, 0, 0, 3, adxBuf) >= 3)
     {
      double adx = adxBuf[0];
      gRegimeScore = MathMin(100.0, adx * 4.0);   // ADX 25 -> skor 100
      if(adx >= 25.0) tp *= 1.25;                 // tren kuat -> TP lebih lebar
      else if(adx <= 15.0) tp *= 0.85;            // sideways -> TP lebih rapat
     }

   // v2.21: saat TREN kuat, TP dilebarkan (biar kena gerakan besar),
   // saat SIDEWAYS dirapetkan (cepat ambil untung). Clamp tetap dijaga.
   tp *= gRegimeTPMult;

   tp = MathMax(tp, InpTPMin);
   tp = MathMin(tp, InpTPMax);
   return tp;
  }

//==================================================================
// v2.19 : refresh TP adaptif & skala basket tiap tick
//  - gTPNow  : TP per-posisi aktif
//  - basket TP/CL diskalakan proporsional dengan TP adaptif, supaya
//    saat market volatil target basket juga ikut naik (tetap ada TP!)
//==================================================================
void UpdateAdaptif()
  {
   // v2.20: throttle hitung TP (ATR/ADX) — cukup 5 detik sekali, hemat CPU.
   // Tanpa ini, TP adaptif dihitung tiap tick dan bisa membuat TP "floating"
   // sehingga posisi tidak pernah kena TP dengan konsisten.
   static datetime lastCalc = 0;
   if(TimeCurrent() - lastCalc < 5 && gTPNow > 0) return;
   lastCalc = TimeCurrent();

   gTPNow = InpTPAdaptif ? HitungTPAdaptif() : InpTakeProfit;

   // rasio TP sekarang vs TP acuan -> dipakai menskalakan basket
   double base = (InpTakeProfit > 0 ? InpTakeProfit : 1.0);
   double ratio = gTPNow / base;
   if(ratio < 0.5) ratio = 0.5;
   if(ratio > 3.0) ratio = 3.0;

   gBasketTPNow = InpBasketTPMoney * ratio;
   gBasketCLNow = InpBasketCLMoney * ratio;   // cut loss ikut menyesuaikan

   // v2.21.2: hitung sideways (cross harga vs MA) — dipakai utk blok entry baru
   if(InpPakaiSideways)
      HitungSideways();
   else
     {
      gSidewaysNow = true;
      gCrossCount  = -1;   // -1 = filter OFF
     }

   // v2.21 REGIME SWITCH: baca ADX utk tentukan mode pasar
   if(InpPakaiRegime && hAdx != INVALID_HANDLE && CopyBuffer(hAdx, 0, 0, 3, adxBuf) >= 3)
     {
      double adx = adxBuf[0];
      if(adx >= InpAdxTren)          // TREN KUAT
        {
         gRegimeTren      = true;
         gRegimeJarakMult = InpRegimeJarakMult;
         gRegimeTPMult    = InpRegimeTPMult;
        }
      else if(adx <= InpAdxSepi)     // SIDEWAYS
        {
         gRegimeTren      = false;
         gRegimeJarakMult = 1.0;
         gRegimeTPMult    = 1.0;
        }
      else                            // TRANSISI
        {
         gRegimeTren      = false;
         gRegimeJarakMult = 1.0;
         gRegimeTPMult    = 1.0;
        }
     }
  }

//==================================================================
// v2.21.2 : FILTER SIDEWAYS (adopsi dari IronGrid Hedge V5.1)
//  Ide: EA grid/averaging HANYA menang di pasar SIDEWAYS.
//  Saat pasar TREN lurus, entry baru = lawan arus -> floating menumpuk.
//  Cara ukur (persis IronGrid): hitung berapa kali harga melewati MA
//  dalam N candle terakhir. Kalau cross >= MinCross -> pasar bolak-balik
//  (sideways) -> BOLEH entry basket baru. Kalau tidak -> TAHAN entry baru
//  (manajemen posisi lama: TP/SL/trailing/layer tetap jalan).
//  Opsi tambahan: ADX harus rendah (pakai ADX yang sudah ada).
//==================================================================
void HitungSideways()
  {
   static datetime lastCalc = 0;
   if(TimeCurrent() - lastCalc < 5 && gCrossCount >= 0) return;
   lastCalc = TimeCurrent();

   int lb = InpSidewaysLookback;
   if(lb < 10) lb = 10;
   if(lb > 1000) lb = 1000;

   double ma[];
   int need = lb + 2;
   if(CopyBuffer(hMaSide, 0, 0, need, ma) < need)
     {
      gSidewaysNow = true;    // data kurang -> jangan blok (aman)
      gCrossCount  = -1;
      return;
     }

   int cross = 0;
   // ma[] index 0 = candle terbaru. Bandingkan close vs MA tiap candle.
   // "cross" = sisi (atas/bawah MA) berubah dibanding candle sebelumnya.
   int prevSide = 0;
   for(int i = lb; i >= 1; i--)
     {
      if(i + 1 >= ArraySize(ma)) continue;
      double c  = iClose(_Symbol, PERIOD_M1, i);
      double cN = iClose(_Symbol, PERIOD_M1, i + 1);
      if(c <= 0 || cN <= 0) continue;
      int s  = (c  > ma[i])   ? 1 : -1;
      int sN = (cN > ma[i+1]) ? 1 : -1;
      if(prevSide != 0 && s != prevSide) cross++;
      prevSide = s;
     }

   gCrossCount = cross;

   bool cukupCross = (cross >= InpSidewaysMinCross);
   bool adxTenang   = true;
   if(InpSidewaysPakaiAdx && hAdx != INVALID_HANDLE && CopyBuffer(hAdx, 0, 0, 2, adxBuf) >= 2)
      adxTenang = (adxBuf[0] <= InpAdxSepi + 5.0);   // toleransi +5

   gSidewaysNow = (cukupCross && adxTenang);
  }

void LevelsFor(ENUM_ORDER_TYPE otype, double price, double &sl, double &tp)
  {
   sl = 0.0; tp = 0.0;
   bool isBuy = (otype == ORDER_TYPE_BUY || otype == ORDER_TYPE_BUY_LIMIT);
   double minD = MinStopDistance();     // jarak minimal yang diterima broker

   // v2.19 : pakai TP adaptif kalau diaktifkan
   double tpDist = InpTPAdaptif ? HitungTPAdaptif() : InpTakeProfit;

   if(InpStopLoss > 0)
     {
      double d = MathMax(InpStopLoss, minD);
      sl = isBuy ? NormalizeDouble(price - d, _Digits)
                 : NormalizeDouble(price + d, _Digits);
     }
   if(tpDist > 0)
     {
      double d = MathMax(tpDist, minD);
      tp = isBuy ? NormalizeDouble(price + d, _Digits)
                 : NormalizeDouble(price - d, _Digits);
     }
  }

//==================================================================
// BUKA: market atau pending limit
//==================================================================
bool OpenTrade(ENUM_ORDER_TYPE otype, int layerIdx, string tag)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = LotForLayer(layerIdx);
   double sl, tp;

   if(InpEntryMode == MODE_MARKET)
     {
      double price = (otype == ORDER_TYPE_BUY) ? ask : bid;
      LevelsFor(otype, price, sl, tp);
      // harga 0 = eksekusi di harga pasar saat request diproses
      bool ok = (otype == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, 0.0, sl, tp, tag)
                                          : trade.Sell(lot, _Symbol, 0.0, sl, tp, tag);
      if(!ok) Print("Gagal ", tag, " err=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return ok;
     }

   // MODE_PENDING (limit) -> lewat satu pintu saja: OpenPendingLimit
   double dist = MathMax(InpPendingDist, MinStopDistance());
   double pprice = (otype == ORDER_TYPE_BUY_LIMIT)
                   ? NormalizeDouble(ask - dist, _Digits)
                   : NormalizeDouble(bid + dist, _Digits);
   return OpenPendingLimit(otype, layerIdx, pprice, tag);
  }

//==================================================================
// ENTRY: basket baru (market) - legacy
//==================================================================
void TryEntryMarket()
  {
   int buyCnt, sellCnt; CountSides(buyCnt, sellCnt);
   if(InpHanyaJikaKosong && (buyCnt + sellCnt) > 0) return;
   if(buyCnt + sellCnt > 0) return;
   if(!NewBar()) return;

   bool buySig, sellSig;
   if(!GetSignals(buySig, sellSig)) return;

   if(InpAktifBuy && buySig && (!InpNoHedge || sellCnt == 0))
     { OpenTrade(ORDER_TYPE_BUY, 1, "L1 Buy"); return; }
   if(InpAktifSell && sellSig && (!InpNoHedge || buyCnt == 0))
     { OpenTrade(ORDER_TYPE_SELL, 1, "L1 Sell"); return; }
  }

//==================================================================
// ENTRY: basket baru (PENDING LIMIT, model SPIDER-PRO)
//  - Saat FLAT: candle bearish -> SELL LIMIT, bullish -> BUY LIMIT
//  - Kalau mode sinyal EMA/CANDLE dipilih, dipakai utk konfirmasi arah
//==================================================================
void TryEntryPending()
  {
   int buyCnt, sellCnt, bP, sP;
   CountSides(buyCnt, sellCnt);
   CountPending(bP, sP);
   if(buyCnt + sellCnt > 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minD = MathMax(InpPendingDist, MinStopDistance());

   // --------------------------------------------------------------
   // v2.17 SPIDER-PRO : pasang KEDUA sisi sekaligus (jaring laba-laba)
   //  - BUY LIMIT  di bawah harga (nunggu turun)
   //  - SELL LIMIT di atas harga  (nunggu naik)
   //  Masing-masing sisi dicek anti-duplikat & batas layer sendiri-sendiri
   //  supaya kalau satu sisi sudah terpasang, sisi lain tetap dilengkapi.
   // --------------------------------------------------------------
   bool useCandleTrigger = (InpSignalMode == SIG_CANDLE);
   bool buySig = true, sellSig = true;
   double buyLevel = 0, sellLevel = 0;

   // ----------------------------------------------------------------
   // v2.18 RAPET : level TIDAK dipakai mentah dari candle (candle M1 gold
   // bisa lebar $5-10 -> jaring jadi terlalu renggang). Sebagai gantinya
   // pakai jarak tetap InpPendingDist dari harga, tapi tetap dihargai
   // InpPendingDist minimal (lewat minD di bawah) supaya tidak ditolak
   // broker. Candle hanya dipakai kalau jaraknya masih waras (<$2).
   // ----------------------------------------------------------------
   if(useCandleTrigger)
     {
      MqlRates r[];
      if(CopyRates(_Symbol, InpCandleTF, 0, 3, r) >= 3)
        {
         double candBuy  = r[1].low;
         double candSell = r[1].high;
         // pakai level candle HANYA kalau dekat (<= $2 dari harga)
         if(ask - candBuy  > 0 && ask - candBuy  <= 2.0) buyLevel  = candBuy;
         if(candSell - bid > 0 && candSell - bid <= 2.0) sellLevel = candSell;
        }
     }

   if(!InpAktifBuy)  buySig  = false;
   if(!InpAktifSell) sellSig = false;
   // Saat sudah ada posisi, hormati aturan no-hedge user
   if(InpNoHedge && sellCnt > 0) buySig  = false;
   if(InpNoHedge && buyCnt > 0) sellSig = false;

   // ---- sisi BUY ----
   if(buySig && bP < InpMaxLayer)
     {
      double p = (buyLevel > 0 ? buyLevel : ask - minD);
      if(ask - p < minD) p = ask - minD;
      p = NormalizeDouble(p, _Digits);
      if(!PendingExistsNear(ORDER_TYPE_BUY_LIMIT, p, MathMax(InpJarakLayer*0.25, 10*_Point)))
         if(OpenPendingLimit(ORDER_TYPE_BUY_LIMIT, 1, p, "L1 BuyLim"))
            gLastEntryTime = TimeCurrent();   // v2.20 cooldown
     }

   // ---- sisi SELL ----
   if(sellSig && sP < InpMaxLayer)
     {
      double p = (sellLevel > 0 ? sellLevel : bid + minD);
      if(p - bid < minD) p = bid + minD;
      p = NormalizeDouble(p, _Digits);
      if(!PendingExistsNear(ORDER_TYPE_SELL_LIMIT, p, MathMax(InpJarakLayer*0.25, 10*_Point)))
         if(OpenPendingLimit(ORDER_TYPE_SELL_LIMIT, 1, p, "L1 SellLim"))
            gLastEntryTime = TimeCurrent();   // v2.20 cooldown
     }
  }

void TryEntry()
  {
   if(InpEntryMode == MODE_PENDING) TryEntryPending();
   else                             TryEntryMarket();
  }

//==================================================================
// LAYERING
//  - MODE_MARKET : tambah saat POSISI rugi sejauh jarak
//  - MODE_PENDING: tumpuk pending limit berikutnya sejauh jarak
//==================================================================
//==================================================================
// v2.20.1 HEDGE PENUTUP OTOMATIS
//  Saat basket rugi menyentuh InpHedgeTriggerMoney, buka SATU posisi
//  berlawanan (hedge) supaya kerugian basket "terkunci" dan tidak
//  melebar. Hedging hanya boleh didaftarkan selama basket masih hidup;
//  saat basket dibersihkan/di-cut, kunci dilepas kembali.
//==================================================================
ulong LargestLossTicket(ENUM_POSITION_TYPE &worstType, double &worstLoss, double &worstLot)
  {
   double worst = 0;   // paling negatif
   ulong  wt    = 0;
   worstType = POSITION_TYPE_BUY; worstLot = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(p < worst)
        {
         worst = p; wt = t;
         worstType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         worstLot  = PositionGetDouble(POSITION_VOLUME);
        }
     }
   worstLoss = worst;
   return wt;
  }

void HedgeReset()
  {
   gHedgeAktif = false; gHedgeLot = 0; gHedgeTicket = 0; gHedgePartnerBuy = false;
  }

// Cari pasangan tertua/terbesar dari hedge supaya bisa dibuka bersama2.
bool FindBestHedgePair(ulong hedgeTicket, ulong &partnerTicket)
  {
   partnerTicket = 0;
   if(hedgeTicket == 0 || !PositionSelectByTicket(hedgeTicket)) return false;
   ENUM_POSITION_TYPE ht = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   ENUM_POSITION_TYPE pt = (ht == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   double best = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == hedgeTicket || t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != pt) continue;
      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(p > best) { best = p; partnerTicket = t; }
     }
   return (partnerTicket != 0);
  }

void TutupTicket(ulong t)
  {
   if(t == 0 || !PositionSelectByTicket(t)) return;
   if(!trade.PositionClose(t))
      Print("Hedge: gagal tutup tiket ", t, " err=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
  }

// Dipanggil tiap tick SEBELUM manajemen lain.
// Return true = tick ini sudah ditangani hedge, jangan entry baru.
//==================================================================
// v2.21 CHASE PENDING (adopsi SPIDER-PRO)
//  Kalau harga bergerak MENJAUH dari pending limit > InpChaseTrigger,
//  geser pending itu supaya mengikuti harga. Ini bikin pending tetap
//  relevan walau harga kabur cepat (yang jadi kelemahan model statis).
//==================================================================
void ChasePending()
  {
   if(!InpPakaiChase || InpEntryMode != MODE_PENDING) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minD = MathMax(InpPendingDist, MinStopDistance());
   double trig = MathMax(InpChaseTrigger, minD + _Point);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((int)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;

      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != ORDER_TYPE_BUY_LIMIT && ot != ORDER_TYPE_SELL_LIMIT) continue;

      double op   = OrderGetDouble(ORDER_PRICE_OPEN);
      double sl   = OrderGetDouble(ORDER_SL);
      double tp   = OrderGetDouble(ORDER_TP);
      double lot  = OrderGetDouble(ORDER_VOLUME_CURRENT);
      datetime exp= (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      double newP = op;

      if(ot == ORDER_TYPE_BUY_LIMIT)
        {
         // buy limit harus di BAWAH harga; kalau harga naik terlalu jauh -> geser naik
         if(ask - op > trig) newP = ask - minD;
         if(newP <= bid) continue;                    // jaga validitas
        }
      else
        {
         // sell limit harus di ATAS harga; kalau harga turun terlalu jauh -> geser turun
         if(op - bid > trig) newP = bid + minD;
         if(newP >= ask) continue;
        }

      if(MathAbs(newP - op) < _Point * 5) continue;   // pergeseran terlalu kecil
      newP = NormalizeDouble(newP, _Digits);
      if(PendingExistsNear((ot == ORDER_TYPE_BUY_LIMIT ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT), newP, MathMax(_Point*10, 2*_Point))) continue;

      if(trade.OrderModify(tk, newP, sl, tp, ORDER_TIME_SPECIFIED, exp))
         Print("CHASE: geser pending #", tk, " ", DoubleToString(op, _Digits), " -> ", DoubleToString(newP, _Digits));
     }
  }

//==================================================================
// v2.21 TRAILING BASKET
//  Kunci profit: saat untung basket melewati ambang, pasang SL basket.
//  Kalau untung turun sampai puncak - InpTrailBasketJaga, tutup SEMUA.
//==================================================================
void ManageTrailBasket()
  {
   if(!InpPakaiTrailBasket) return;
   if(InpPakaiBasketTP || InpPakaiBasketCL) { }   // tetap boleh jalan bareng

   int lb, ls; CountSides(lb, ls);
   if(lb + ls == 0) { gTrailBasketPeak = 0; gTrailBasketSL = 0; return; }

   double fl = GetEAFloating();

   if(fl > gTrailBasketPeak) gTrailBasketPeak = fl;

   if(gTrailBasketPeak >= InpTrailBasketMulai)
     {
      double slLevel = gTrailBasketPeak - InpTrailBasketJaga;
      if(slLevel > gTrailBasketSL) gTrailBasketSL = slLevel;

      if(fl <= gTrailBasketSL)
        {
         Print("TRAIL BASKET: kunci profit. puncak=", DoubleToString(gTrailBasketPeak,2),
               " floating=", DoubleToString(fl,2), " -> tutup semua");
         CloseAll();
         gTrailBasketPeak = 0; gTrailBasketSL = 0;
        }
     }
  }

bool ManageHedge()
  {
   if(!InpPakaiHedgePenutup) { HedgeReset(); return false; }

   int bCnt, sCnt; CountSides(bCnt, sCnt);

   // Basket sudah bersih -> lepas kunci hedge
   if(bCnt + sCnt == 0) { HedgeReset(); return false; }

   // ---- 1. Sudah ada hedge terbuka? kelola pasangannya ----
   if(gHedgeAktif && gHedgeTicket > 0)
     {
      if(!PositionSelectByTicket(gHedgeTicket))
        { HedgeReset(); }   // hedge kena TP/SL sendiri -> lepas kunci
      else
        {
         ulong partner = 0;
         if(FindBestHedgePair(gHedgeTicket, partner))
           {
            if(partner != 0 && PositionSelectByTicket(partner) && PositionSelectByTicket(gHedgeTicket))
              {
               double ph = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
               PositionSelectByTicket(partner);
               double pp = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
               double pair = ph + pp;

               // v2.21.1 FIX: hedge TIDAK BOLEH jadi posisi nyangkut baru.
               // Kalau pasangan hedge rugi melebihi InpHedgeStopMoney, TUTUP PAKSA
               // (biarkan cut loss basket/equity yang mengurus sisanya).
               if(InpHedgeStopMoney > 0 && pair <= -MathAbs(InpHedgeStopMoney))
                 {
                  Print("HEDGE STOP: pasangan rugi ", DoubleToString(pair,2),
                        " -> tutup paksa (batas ", DoubleToString(InpHedgeStopMoney,2), ")");
                  TutupTicket(gHedgeTicket);
                  TutupTicket(partner);
                  HedgeReset();
                  return false;   // lanjut ke RiskGuard, biar CL basket/equity menilai
                 }

               // tutup pasangan hanya kalau GABUNGAN kedua posisi untung
               if(pair >= InpHedgeMinProfit)
                 {
                  Print("HEDGE: tutup pasangan (", DoubleToString(ph,2), " + ",
                        DoubleToString(pp,2), ") = ", DoubleToString(ph+pp,2));
                  TutupTicket(gHedgeTicket);
                  TutupTicket(partner);
                  HedgeReset();
                  return true;
                 }
              }
           }
         return false;   // hedge aktif, biarkan jalan; entry baru tetap diblok
        }
     }

   // ---- 2. Belum hedge -> cek apakah rugi sudah nyentuh pemicu ----
   double worstLoss, worstLot; ENUM_POSITION_TYPE worstType;
   ulong wt = LargestLossTicket(worstType, worstLoss, worstLot);
   if(wt == 0) return false;
   if(MathAbs(worstLoss) < InpHedgeTriggerMoney)
     {
      // belum nyentuh pemicu, tapi kalau ada posisi yang sudah hijau besar
      // dan sisi lawannya masih rugi, EA tetap bisa lindungi nilai.
      return false;
     }

   // sisi paling rugi = BUY -> hedge SELL, begitu sebaliknya
   bool hedgeIsBuy = (worstType == POSITION_TYPE_SELL);
   double lot = worstLot * InpHedgeLotMult;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   lot = MathRound(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   if(InpMaxLot > 0 && lot > InpMaxLot) lot = InpMaxLot;

   if(!trade.PositionOpen(_Symbol,
        (hedgeIsBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), lot, 0.0, 0.0, 0.0, "HEDGE"))
     {
      Print("Hedge: gagal buka posisi err=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
      return false;
     }

   gHedgeAktif = true; gHedgeLot = lot;
   gHedgeTicket = trade.ResultOrder();
   // tukar ke tiket POSISI (bukan order) kalau perlu
   if(!PositionSelectByTicket(gHedgeTicket))
     {
      for(int i = PositionsTotal()-1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0 || !PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         string cm = PositionGetString(POSITION_COMMENT);
         if(StringFind(cm, "HEDGE") == 0) { gHedgeTicket = t; break; }
        }
     }
   Print("HEDGE dibuka: ", (hedgeIsBuy ? "BUY" : "SELL"), " ", DoubleToString(lot,2),
         " (rugi sisi lawan ", DoubleToString(worstLoss,2), ")");
   return true;
  }

//==================================================================
// v2.20 COOLDOWN: rem antar entry. Tanpa ini, EA bisa menembak
// puluhan posisi dalam hitungan menit saat volatilitas (mis. FOMC).
//==================================================================
bool CooldownBlocked(string &why)
  {
   if(!InpPakaiCooldown) return false;
   datetime now = TimeCurrent();

   if(gCooldownUntil > now)
     {
      why = "Jeda setelah news (" + IntegerToString((int)((gCooldownUntil - now)/60)+1) + " menit)";
      return true;
     }
   if(gLastEntryTime > 0 && InpCooldownDetikEntry > 0 &&
      (now - gLastEntryTime) < InpCooldownDetikEntry)
     {
      why = "Cooldown entry (" + IntegerToString((int)(now - gLastEntryTime)) + "/" +
            IntegerToString(InpCooldownDetikEntry) + "s)";
      return true;
     }
   return false;
  }

bool LayerCooldownBlocked()
  {
   if(!InpPakaiCooldown || InpCooldownDetikLayer <= 0) return false;
   if(gLastLayerTime <= 0) return false;
   return ((TimeCurrent() - gLastLayerTime) < InpCooldownDetikLayer);
  }

void TryLayerSide(ENUM_POSITION_TYPE side, int curCount)
  {
   if(curCount <= 0) return;
   if(LayerCooldownBlocked()) return;   // v2.20: jeda antar penambahan layer
   double last = GetLastOpenPrice(side);
   if(last <= 0) return;

   int bP, sP; CountPending(bP, sP);
   int pendSide = (side == POSITION_TYPE_BUY ? bP : sP);

   // Batas layer dihitung dari POSISI + PENDING, bukan posisi saja.
   if(curCount + pendSide >= InpMaxLayer) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD = MathMax(InpPendingDist, MinStopDistance());
   double jrk  = InpJarakLayer * gRegimeJarakMult;             // v2.21: jarak ikut regime
   double tol  = MathMax(jrk * 0.25, 10 * _Point);             // toleransi anti-duplikat
   int nextLayer = curCount + pendSide + 1;
   double lot = LotForLayer(nextLayer);

   if(side == POSITION_TYPE_BUY)
     {
      if(InpEntryMode == MODE_MARKET)
        {
         // v2.18 RAPET: isi SEMUA level yang terlewat, bukan cuma 1.
         // Selama harga masih di bawah level berikutnya, terus tambah
         // layer sampai batas InpMaxLayer. Kalau InpOneShotLadder=true,
         // cukup 1 layer per tick (tidak boros).
         if(ask <= last - jrk)
           {
            if(OpenTrade(ORDER_TYPE_BUY, nextLayer, "L"+IntegerToString(nextLayer)+" Buy"))
               gLastLayerTime = TimeCurrent();
            if(!InpOneShotLadder) return;   // sisanya nanti tick berikutnya
           }
        }
      else
        {
         // v2.18 RAPET: pasang LADDER pending buy limit ke bawah
         // mulai dari harga posisi terakhir, selagi masih ada jarak waras.
         for(int k = nextLayer; k <= InpMaxLayer; k++)
           {
            int idx = k - nextLayer;
            double p = NormalizeDouble(last - jrk * (idx + 1), _Digits);
            if(ask - p < minD) break;                    // terlalu dekat/ilegal
            if(PendingExistsNear(ORDER_TYPE_BUY_LIMIT, p, tol)) continue;
            OpenPendingLimit(ORDER_TYPE_BUY_LIMIT, k, p, "L"+IntegerToString(k)+" BuyLim");
            if(InpOneShotLadder) break;                  // 1 per tick
           }
        }
     }
   else
     {
      if(InpEntryMode == MODE_MARKET)
        {
         if(bid >= last + jrk)
           {
            if(OpenTrade(ORDER_TYPE_SELL, nextLayer, "L"+IntegerToString(nextLayer)+" Sell"))
               gLastLayerTime = TimeCurrent();
            if(!InpOneShotLadder) return;
           }
        }
      else
        {
         // v2.18 RAPET: ladder pending sell limit ke atas
         for(int k = nextLayer; k <= InpMaxLayer; k++)
           {
            int idx = k - nextLayer;
            double p = NormalizeDouble(last + jrk * (idx + 1), _Digits);
            if(p - bid < minD) break;
            if(PendingExistsNear(ORDER_TYPE_SELL_LIMIT, p, tol)) continue;
            OpenPendingLimit(ORDER_TYPE_SELL_LIMIT, k, p, "L"+IntegerToString(k)+" SellLim");
            if(InpOneShotLadder) break;
           }
        }
     }
  }

//==================================================================
// Buka pending limit di harga tertentu (utk ladder)
//==================================================================
bool OpenPendingLimit(ENUM_ORDER_TYPE otype, int layerIdx, double pprice, string tag)
  {
   double lot = LotForLayer(layerIdx);
   double sl, tp;
   pprice = NormalizeDouble(pprice, _Digits);
   LevelsFor(otype, pprice, sl, tp);

   // Sebagian broker menolak ORDER_TIME_SPECIFIED. Cek dulu, kalau tidak
   // didukung pakai GTC supaya order tidak gagal dengan error tak jelas.
   ENUM_ORDER_TYPE_TIME tmode = ORDER_TIME_GTC;
   datetime expire = 0;
   if(InpPendingExpireHrs > 0 && ExpirySupported())
     {
      tmode  = ORDER_TIME_SPECIFIED;
      expire = TimeCurrent() + (datetime)InpPendingExpireHrs * 3600;
     }

   bool ok = (otype == ORDER_TYPE_BUY_LIMIT)
             ? trade.BuyLimit(lot, pprice, _Symbol, sl, tp, tmode, expire, tag)
             : trade.SellLimit(lot, pprice, _Symbol, sl, tp, tmode, expire, tag);
   if(ok) Print("Pending ", tag, " @", DoubleToString(pprice, _Digits), " lot=", DoubleToString(lot,2));
   else   Print("Gagal ", tag, " @", DoubleToString(pprice, _Digits),
                " err=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   return ok;
  }

//==================================================================
// BEP + Trailing per posisi
//==================================================================
void ManagePositions()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      double newSL = curSL;

      if(InpGunakanBEP && InpBEPTrigger > 0)
        {
         if(type == POSITION_TYPE_BUY)
           {
            if(bid - open >= InpBEPTrigger)
              {
               double sl = NormalizeDouble(open + InpBEPLock, _Digits);
               if(sl > newSL) newSL = sl;
              }
           }
         else
           {
            if(open - ask >= InpBEPTrigger)
              {
               double sl = NormalizeDouble(open - InpBEPLock, _Digits);
               if(newSL == 0 || sl < newSL) newSL = sl;
              }
           }
        }

      if(InpGunakanTrailing && InpTrailStart > 0)
        {
         if(type == POSITION_TYPE_BUY)
           {
            if(bid - open >= InpTrailStart)
              {
               double sl = NormalizeDouble(bid - InpTrailStep, _Digits);
               if(newSL == 0 || sl > newSL) newSL = sl;
              }
           }
         else
           {
            if(open - ask >= InpTrailStart)
              {
               double sl = NormalizeDouble(ask + InpTrailStep, _Digits);
               if(newSL == 0 || sl < newSL) newSL = sl;
              }
           }
        }

      if(newSL != curSL && MathAbs(newSL - curSL) > _Point / 2.0)
        {
         // SL harus tetap di sisi yang benar dan menghormati stops level,
         // kalau tidak PositionModify akan gagal berulang tiap tick
         double minD = MinStopDistance();
         bool valid = (type == POSITION_TYPE_BUY)
                      ? (newSL > 0 && bid - newSL >= minD)
                      : (newSL > 0 && newSL - ask >= minD);
         if(valid && !trade.PositionModify(t, newSL, curTP))
            Print("Modify SL gagal tiket ", t, " err=", trade.ResultRetcode(),
                  " ", trade.ResultRetcodeDescription());
        }
     }
  }

//==================================================================
void CloseAll()
  {
   DeleteAllPending();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      trade.PositionClose(t);
     }
  }

//==================================================================
// CUT LOSS / TP BASKET (uang) + equity DD + target harian
//  return true = trading distop hari ini
//==================================================================
bool RiskGuard()
  {
   int buyCnt, sellCnt; CountSides(buyCnt, sellCnt);
   int totalPos = buyCnt + sellCnt;

   double floating = GetEAFloating();
   double total    = GetEAProfitToday();

   // Basket TP/CL hanya relevan kalau ada posisi terbuka.
   if(totalPos > 0)
     {
      // 1. TP basket -> tutup semua (ambil untung)
      if(InpPakaiBasketTP && InpBasketTPMoney > 0 && floating >= gBasketTPNow)
        {
         Print("TP BASKET kena (", DoubleToString(floating,2), ") -> CloseAll");
         CloseAll();
         return true;   // habiskan tick ini, jangan langsung entry lagi
        }

      // 2. CUT LOSS basket -> tutup semua (batasi rugi)
      if(InpPakaiBasketCL && InpBasketCLMoney > 0 && floating <= -MathAbs(gBasketCLNow))
        {
         Print("CUT LOSS BASKET kena (", DoubleToString(floating,2), ") -> CloseAll");
         CloseAll();
         return true;
        }
     }

   // Cek 3 & 4 WAJIB jalan walau sedang flat. Di versi lama fungsi ini
   // keluar duluan saat tidak ada posisi, sehingga target harian dan cut
   // loss equity tidak pernah terdeteksi kalau basket sudah tertutup TP.

   // 3. Target profit harian -> berhenti sampai besok
   double tgt = TargetHarianEfektif();
   if(tgt > 0 && total >= tgt)
     {
      Print("TARGET HARIAN kena (", DoubleToString(total,2), " / ", DoubleToString(tgt,2), ") -> stop hari ini");
      CloseAll(); gStoppedToday = true; return true;
     }

   // 4. CUT LOSS equity harian (%) -> stop sampai besok
   if(InpPakaiEquityCL && InpMaxEquityDD > 0.0 && gDayStartEquity > 0)
     {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      double ddPct = (gDayStartEquity - eq) / gDayStartEquity * 100.0;
      if(ddPct >= InpMaxEquityDD)
        {
         Print("CUT LOSS EQUITY kena (", DoubleToString(ddPct,2), "%) -> CloseAll + stop");
         CloseAll(); gStoppedToday = true; return true;
        }
     }

   return false;
  }


//==================================================================
// Target harian EFEKTIF (uang): % saldo atau nilai fix
//==================================================================
double TargetHarianEfektif()
  {
   if(InpTargetPersen)
     {
      double base = AccountInfoDouble(ACCOUNT_BALANCE);
      if(base <= 0) base = gDayStartEquity;
      return base * InpTargetPersenVal / 100.0;
     }
   return InpTargetHarian;
  }

//==================================================================
// JAM LOCK: stop entry (opsi tutup posisi) antara jamStop..jamResume
//  pakai jam broker. Handle lewat tengah malam.
//==================================================================
bool JamLockNow()
  {
   if(!InpPakaiJamLock) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   int a = InpJamLockStop, b = InpJamLockResume;
   if(a == b) return false;
   if(a < b)  return (h >= a && h < b);          // mis. 01 -> 03
   return (h >= a || h < b);                     // mis. 23 -> 03 (lewat malam)
  }

//==================================================================
// ANTI-NEWS HELPERS
//==================================================================

// Cek apakah sekarang termasuk jendela news dari daftar jam manual "HH:MM,..."
bool ManualNewsWindow(string &why)
  {
   if(StringLen(InpNewsJamManual) == 0) return false;
   string parts[];
   int n = StringSplit(InpNewsJamManual, ',', parts);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int nowMin = dt.hour * 60 + dt.min;
   for(int i = 0; i < n; i++)
     {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(StringLen(s) == 0) continue;
      int idx = StringFind(s, ":");
      if(idx <= 0) continue;
      int hh = (int)StringToInteger(StringSubstr(s, 0, idx));
      int mm = (int)StringToInteger(StringSubstr(s, idx + 1));
      if(hh < 0 || hh > 23 || mm < 0 || mm > 59) continue;
      int evMin = hh * 60 + mm;
      // selisih melingkar 24 jam: 23:55 vs 00:05 = 10 menit, bukan 1430
      int diff = (int)MathAbs(nowMin - evMin);
      if(diff > 720) diff = 1440 - diff;
      if(diff <= InpNewsJendelaMenit)
        {
         why = "Jam news manual " + s;
         return true;
        }
     }
   return false;
  }

// Cek kalender ekonomi MT5: event high-impact dlm jendela waktu
bool CalendarNewsWindow(string &why)
  {
   if(!InpNewsPakaiKalender) return false;

   datetime now = TimeCurrent();
   datetime from = now - InpNewsJendelaMenit * 60;
   datetime to   = now + InpNewsJendelaMenit * 60;

   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to, NULL, NULL);
   if(n <= 0) return false;

   // daftar mata uang dipisah SEKALI, bukan di dalam loop event
   string wanted[];
   int wn = 0;
   if(StringLen(InpNewsMataUang) > 0)
     {
      wn = StringSplit(InpNewsMataUang, ',', wanted);
      for(int k = 0; k < wn; k++)
        { StringTrimLeft(wanted[k]); StringTrimRight(wanted[k]); }
     }

   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      // impact: 1=Low,2=Medium,3=High,4=Unknown -> bandingkan
      if((int)ev.importance < InpNewsMinImpact) continue;

      // filter mata uang (kalau diisi)
      if(wn > 0)
        {
         MqlCalendarCountry ctry;
         if(CalendarCountryById(ev.country_id, ctry))
           {
            string cur = ctry.currency;
            bool match = false;
            for(int k = 0; k < wn; k++)
               if(StringLen(wanted[k]) > 0 && StringFind(cur, wanted[k]) >= 0)
                 { match = true; break; }
            if(!match) continue;
           }
        }

      why = "News: " + ev.name;
      return true;
     }
   return false;
  }

// Cek volatilitas: spread melebar / ATR spike
bool VolatilityNewsWindow(string &why)
  {
   // spread. gAvgSpread di-update di OnTick (sekali per tick), bukan di sini,
   // supaya pemanggilan dari panel tidak ikut mengubah rata-ratanya.
   if(InpNewsMaxSpreadMult > 0)
     {
      double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(gAvgSpread > 0 && spread > gAvgSpread * InpNewsMaxSpreadMult)
        {
         why = "Spread spike (" + DoubleToString(spread,0) + " vs " + DoubleToString(gAvgSpread,0) + ")";
         return true;
        }
     }
   // ATR spike
   if(InpNewsPakaiATR && hAtr != INVALID_HANDLE)
     {
      if(CopyBuffer(hAtr, 0, 0, 20, atrBuf) >= 20)
        {
         double cur = atrBuf[0];
         double sum = 0;
         for(int i = 1; i < 20; i++) sum += atrBuf[i];
         double avg = sum / 19.0;
         if(avg > 0 && cur > avg * InpNewsATRMult)
           {
            why = "ATR spike (" + DoubleToString(cur, _Digits) + " vs " + DoubleToString(avg, _Digits) + ")";
            return true;
           }
        }
     }
   return false;
  }

// Gabungan: true = sedang diblok karena news
//  Hasil di-cache beberapa detik: CalendarValueHistory() mahal dan versi
//  lama memanggilnya dua kali per tick (OnTick + PanelUpdate).
bool NewsBlocked(string &why)
  {
   why = "";
   if(!InpPakaiNews) return false;

   int cache = (InpNewsCacheDetik < 1 ? 1 : InpNewsCacheDetik);
   if(TimeCurrent() - gNewsCheckTime < cache)
     { why = gNewsWhy; return gNewsBlocked; }

   gNewsCheckTime = TimeCurrent();
   gNewsBlocked   = false;
   gNewsWhy       = "";

   if(CalendarNewsWindow(gNewsWhy) ||
      ManualNewsWindow(gNewsWhy)   ||
      VolatilityNewsWindow(gNewsWhy))
      gNewsBlocked = true;

   why = gNewsWhy;
   return gNewsBlocked;
  }

//==================================================================
// Tampilkan garis level candle terakhir (opsional)

//==================================================================
// ===================== PANEL DASHBOARD (v2.14) ===================
//==================================================================

void PanelRect(string name, int x, int y, int w, int h, color bg, color border)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void PanelText(string name, int x, int y, string txt, color clr, int size=8, string font="Trebuchet MS")
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString (0, name, OBJPROP_FONT, font);
   ObjectSetString (0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void PanelButton(string name, int x, int y, int w, int h, string txt, color bg, color fg, int size=9)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, fg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString (0, name, OBJPROP_FONT, "Trebuchet MS");
   ObjectSetString (0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//--------------------------------------------
void PanelCreate()
  {
   int x = gPX, y = gPY;
   gPY0 = y + 4;
   int pad = 6;
   int wIn = gPW - 2*pad;            // lebar isi

   // ---- background utama ----
   PanelRect(PN"bg", x, y, gPW, 26 + 15*gPRowH + 76, InpPanelBg, clrDimGray);

   // ---- header ----
   PanelText(PN"hdr", x+pad, gPY0+2, "PabloLayerEA v2.19 SPIDER", InpPanelFg, 9);
   PanelText(PN"hdrSym", x+pad+150, gPY0+2, _Symbol+" "+EnumToString((ENUM_TIMEFRAMES)Period()), InpPanelAccent, 8);

   int yb = gPY0 + 18;

   // ---- kotak SELL / LOT / BUY ----
   int bw = (wIn - 2) / 3;
   PanelRect(PN"sellBox", x+pad, yb, bw, 40, C'120,20,20', clrDimGray);
   PanelText(PN"sellTxt", x+pad+bw/2-16, yb+4, "SELL", clrWhite, 9);
   PanelText(PN"sellPx",  x+pad+6, yb+22, "---.--", C'255,120,120', 9);

   PanelRect(PN"lotBox", x+pad+bw+1, yb, bw, 40, clrWhite, clrDimGray);
   PanelText(PN"lotTxt", x+pad+bw+1+bw/2-16, yb+12, DoubleToString(InpLotAwal,2), clrBlack, 10);

   PanelRect(PN"buyBox", x+pad+2*bw+2, yb, bw, 40, C'20,40,120', clrDimGray);
   PanelText(PN"buyTxt", x+pad+2*bw+2+bw/2-14, yb+4, "BUY", clrWhite, 9);
   PanelText(PN"buyPx",  x+pad+2*bw+2+6, yb+22, "---.--", C'120,170,255', 9);

   int y1 = yb + 46;

   // ---- baris info ----
   PanelText(PN"r1l", x+pad, y1+0*gPRowH, "NET FLOATING:", InpPanelFg, 8);
   PanelText(PN"r1v", x+pad+150, y1+0*gPRowH, "$0.00", InpPanelFg, 8);

   PanelText(PN"r2l", x+pad, y1+1*gPRowH, "TARGET",      C'120,255,120', 8);
   PanelText(PN"r2v", x+pad+150, y1+1*gPRowH, "0%", C'120,255,120', 8);
   PanelRect(PN"tgBg", x+pad, y1+2*gPRowH+1, wIn, 4, C'50,50,50', clrDimGray);
   PanelRect(PN"tgFg", x+pad, y1+2*gPRowH+1, 0, 4, C'40,200,60', clrDimGray);

   PanelText(PN"r3l", x+pad, y1+3*gPRowH+4, "Profit:", InpPanelFg, 8);
   PanelText(PN"r3v", x+pad+150, y1+3*gPRowH+4, "$0.00", InpPanelFg, 8);

   PanelText(PN"r4l", x+pad, y1+4*gPRowH+4, "DD",  C'255,90,90', 8);
   PanelText(PN"r4v", x+pad+150, y1+4*gPRowH+4, "$0.00", InpPanelFg, 8);
   PanelRect(PN"ddBg", x+pad, y1+5*gPRowH+5, wIn, 4, C'50,50,50', clrDimGray);
   PanelRect(PN"ddFg", x+pad, y1+5*gPRowH+5, 0, 4, C'220,60,60', clrDimGray);

   PanelText(PN"r5", x+pad, y1+6*gPRowH+6, "BUY  Pos:0  Lot:0.00", InpPanelFg, 8);
   PanelText(PN"r5v",x+pad+180, y1+6*gPRowH+6, "$0.00", C'120,255,120', 8);
   PanelText(PN"r6", x+pad, y1+7*gPRowH+6, "SELL Pos:0  Lot:0.00", InpPanelFg, 8);
   PanelText(PN"r6v",x+pad+180, y1+7*gPRowH+6, "$0.00", C'120,255,120', 8);

   PanelText(PN"r7", x+pad, y1+8*gPRowH+6, "NextLot B:0.01 S:0.01  Lyr:0", InpPanelFg, 8);
   PanelText(PN"r8", x+pad, y1+9*gPRowH+6, "Status: RUNNING", C'120,255,120', 8);
   PanelText(PN"r9", x+pad, y1+10*gPRowH+6, "News: OFF  JamLock: OFF", InpPanelAccent, 8);

   // ---- tombol ----
   int yt = y1 + 11*gPRowH + 8;
   int hb = 22;
   int bw3 = (wIn - 4) / 3;
   PanelButton(PN"btnReset", x+pad, yt, bw3, hb, "RESET", clrGray, clrWhite, 8);
   PanelButton(PN"btnClBuy", x+pad+bw3+2, yt, bw3, hb, "CLOSE BUY", C'20,40,120', clrWhite, 8);
   PanelButton(PN"btnClSell",x+pad+2*bw3+4, yt, bw3, hb, "CLOSE SELL", C'120,20,20', clrWhite, 8);
   PanelButton(PN"btnClAll", x+pad, yt+hb+3, wIn, 24, "CLOSE ALL POSITIONS", C'200,30,30', clrWhite, 9);

   // ---- footer ----
   PanelText(PN"foot", x+pad, yt+hb+31, "Contact: "+InpPanelBrand, C'150,180,255', 8);
  }

//--------------------------------------------
double SideProfit(ENUM_POSITION_TYPE type, int &cnt, double &lots)
  {
   double p = 0; cnt = 0; lots = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      p += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      lots += PositionGetDouble(POSITION_VOLUME);
      cnt++;
     }
   return p;
  }

//--------------------------------------------
void PanelUpdate()
  {
   if(!InpTampilkanPanel) return;
   if(ObjectFind(0, PN"bg") < 0) PanelCreate();

   // harga
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   ObjectSetString(0, PN"sellPx", OBJPROP_TEXT, DoubleToString(bid, _Digits));
   ObjectSetString(0, PN"buyPx",  OBJPROP_TEXT, DoubleToString(ask, _Digits));

   // posisi
   int bCnt, sCnt; double bLot, sLot;
   double bP = SideProfit(POSITION_TYPE_BUY,  bCnt, bLot);
   double sP = SideProfit(POSITION_TYPE_SELL, sCnt, sLot);

   double flt = GetEAFloating();
   double hari = GetEAProfitToday();
   double tgt = TargetHarianEfektif();

   // floating
   ObjectSetString(0, PN"r1v", OBJPROP_TEXT, DoubleToString(flt,2));
   if(flt >= 0) ObjectSetInteger(0, PN"r1v", OBJPROP_COLOR, clrLime);
   else         ObjectSetInteger(0, PN"r1v", OBJPROP_COLOR, clrRed);

   // target bar
   double tgtPct = (tgt > 0 ? MathMax(0, MathMin(100, hari/tgt*100)) : 0);
   ObjectSetString(0, PN"r2v", OBJPROP_TEXT, DoubleToString(tgtPct,1)+"%");
   int wIn = gPW - 12;
   int barW = (int)(wIn * tgtPct / 100.0);
   ObjectSetInteger(0, PN"tgFg", OBJPROP_XSIZE, MathMax(0, barW));

   // profit
   ObjectSetString(0, PN"r3v", OBJPROP_TEXT, DoubleToString(hari,2)+" / "+DoubleToString(tgt,2));
   if(hari >= 0) ObjectSetInteger(0, PN"r3v", OBJPROP_COLOR, clrLime);
   else          ObjectSetInteger(0, PN"r3v", OBJPROP_COLOR, clrRed);

   // DD bar (equity dari puncak hari)
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddAbs = MathMax(0, bal - eq);
   double ddPct = (gDayStartEquity > 0 ? ddAbs/gDayStartEquity*100.0 : 0);
   ObjectSetString(0, PN"r4v", OBJPROP_TEXT, DoubleToString(ddAbs,2)+" ("+DoubleToString(ddPct,1)+"%)");
   // InpMaxEquityDD bisa 0 (filter dimatikan) -> versi lama bagi nol di sini
   double ddRatio = (InpMaxEquityDD > 0 ? MathMin(100.0, ddPct / InpMaxEquityDD * 100.0) : 0.0);
   int ddW = (int)(wIn * ddRatio / 100.0);
   ObjectSetInteger(0, PN"ddFg", OBJPROP_XSIZE, MathMax(0, ddW));

   // rincian B/S
   // rincian B/S ; tampilkan "FLOATING B:x S:y" ala NPBOT
   ObjectSetString(0, PN"r5", OBJPROP_TEXT, "BUY  "+IntegerToString(bCnt)+" pos  "+DoubleToString(bLot,2)+" lot");
   ObjectSetString(0, PN"r5v", OBJPROP_TEXT, DoubleToString(bP,2));
   if(bP >= 0) ObjectSetInteger(0, PN"r5v", OBJPROP_COLOR, clrLime);
   else        ObjectSetInteger(0, PN"r5v", OBJPROP_COLOR, clrRed);
   ObjectSetString(0, PN"r6", OBJPROP_TEXT, "SELL "+IntegerToString(sCnt)+" pos  "+DoubleToString(sLot,2)+" lot");
   ObjectSetString(0, PN"r6v", OBJPROP_TEXT, DoubleToString(sP,2));
   if(sP >= 0) ObjectSetInteger(0, PN"r6v", OBJPROP_COLOR, clrLime);
   else        ObjectSetInteger(0, PN"r6v", OBJPROP_COLOR, clrRed);

   // next lot
   int lyr = MathMax(bCnt, sCnt);
   ObjectSetString(0, PN"r7", OBJPROP_TEXT,
      "NextLot B:"+DoubleToString(MathMin(InpMaxLot, InpLotAwal + bCnt*InpLotCustom),2)+
      " S:"+DoubleToString(MathMin(InpMaxLot, InpLotAwal + sCnt*InpLotCustom),2)+
      "  Lyr:"+IntegerToString(lyr));

   // status
   string st = "RUNNING"; color sc = C'120,255,120';
   if(gStoppedToday) { st = "STOPPED (limit hari)"; sc = C'255,180,60'; }
   else if(gJamLockAktif) { st = "JAM LOCK"; sc = C'255,180,60'; }
   ObjectSetString(0, PN"r8", OBJPROP_TEXT, "Status: "+st);
   ObjectSetInteger(0, PN"r8", OBJPROP_COLOR, sc);

   string nw; bool nb = NewsBlocked(nw);
   string cdw; bool cb = (InpPakaiCooldown && CooldownBlocked(cdw));
   ObjectSetString(0, PN"r9", OBJPROP_TEXT,
      "News: "+(InpPakaiNews ? (nb ? "BLOK" : "clear") : "OFF")+
      "  CD: "+(InpPakaiCooldown ? (cb ? "JEDA" : "siap") : "OFF")+
      "  Hedge: "+(InpPakaiHedgePenutup ? (gHedgeAktif ? "AKTIF" : "siaga") : "OFF")+
      "  Regime: "+(InpPakaiRegime ? (gRegimeTren ? "TREN" : "SIDEWAYS") : "OFF")+
      "  Chase: "+(InpPakaiChase ? "ON" : "OFF"));
   if(nb) ObjectSetInteger(0, PN"r9", OBJPROP_COLOR, clrRed);
   else   ObjectSetInteger(0, PN"r9", OBJPROP_COLOR, InpPanelAccent);

   // lot box + symbol
   ObjectSetString(0, PN"lotTxt", OBJPROP_TEXT, DoubleToString(InpLotAwal,2));
   // ringkas B:x S:y ala NPBOT (dipakai di judul panel)
   ObjectSetString(0, PN"hdrSym", OBJPROP_TEXT,
      _Symbol+"  B:"+IntegerToString(bCnt)+" S:"+IntegerToString(sCnt)+"  "+EnumToString((ENUM_TIMEFRAMES)Period()));
  }

//--------------------------------------------
void PanelDelete()
  {
   ObjectsDeleteAll(0, PN);
  }

//--------------------------------------------
void DeletePendingSide(ENUM_ORDER_TYPE otype)
  {
   for(int i = OrdersTotal()-1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != otype) continue;
      trade.OrderDelete(tk);
     }
  }

void CloseSide(ENUM_POSITION_TYPE side)
  {
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
      trade.PositionClose(tk);
     }
   if(side == POSITION_TYPE_BUY)  DeletePendingSide(ORDER_TYPE_BUY_LIMIT);
   if(side == POSITION_TYPE_SELL) DeletePendingSide(ORDER_TYPE_SELL_LIMIT);
  }

//==================================================================
//==================================================================
// v2.16: gambar GARIS + LABEL di chart utk tiap ORDER PENDING aktif.
// Tujuan: Aska bisa lihat langsung "EA mau beli / jual di harga berapa".
// Nama objek: PabloPend_<ticket>  (dibersihkan otomatis kalau order hilang)
//==================================================================
void DrawPendingLines()
  {
   if(!InpTampilkanGaris) return;

   // --- kumpulkan ticket pending yang masih hidup ---
   ulong tickets[];
   int n = 0;
   ArrayResize(tickets, OrdersTotal());
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != ORDER_TYPE_BUY_LIMIT && ot != ORDER_TYPE_SELL_LIMIT) continue;
      tickets[n++] = tk;
     }

   // --- gambar / update tiap order ---
   for(int k = 0; k < n; k++)
     {
      if(!OrderSelect(tickets[k])) continue;
      double px    = OrderGetDouble(ORDER_PRICE_OPEN);
      double lot   = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double sl    = OrderGetDouble(ORDER_SL);
      double tp    = OrderGetDouble(ORDER_TP);
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isBuy   = (ot == ORDER_TYPE_BUY_LIMIT);

      string base  = "PabloPend_" + IntegerToString((int)tickets[k]);
      string oname = base + "_ln";
      string lname = base + "_tx";
      color  c     = (isBuy ? clrDodgerBlue : clrOrangeRed);
      string tip   = (isBuy ? "BUY LIMIT" : "SELL LIMIT");

      double lvl = px;
      if(ObjectFind(0, oname) < 0)
        {
         ObjectCreate(0, oname, OBJ_HLINE, 0, 0, lvl);
         ObjectSetInteger(0, oname, OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, oname, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, oname, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, oname, OBJPROP_HIDDEN, true);
        }
      ObjectSetDouble (0, oname, OBJPROP_PRICE, lvl);
      ObjectSetInteger(0, oname, OBJPROP_COLOR, c);
      ObjectSetString (0, oname, OBJPROP_TOOLTIP,
                       tip + " " + DoubleToString(lot,2) + " @ " + DoubleToString(px,_Digits));

      string txt = tip + " " + DoubleToString(lot,2) + " @ " + DoubleToString(px,_Digits);
      if(ObjectFind(0, lname) < 0)
        {
         ObjectCreate(0, lname, OBJ_TEXT, 0, 0, lvl);
         ObjectSetInteger(0, lname, OBJPROP_FONTSIZE, 8);
         ObjectSetString (0, lname, OBJPROP_FONT, "Trebuchet MS");
         ObjectSetInteger(0, lname, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
         ObjectSetInteger(0, lname, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, lname, OBJPROP_HIDDEN, true);
        }
      ObjectSetString (0, lname, OBJPROP_TEXT, txt);
      ObjectSetInteger(0, lname, OBJPROP_COLOR, c);
      ObjectSetDouble (0, lname, OBJPROP_PRICE, lvl);
      ObjectSetInteger(0, lname, OBJPROP_TIME, 0, (datetime)(TimeCurrent() + PeriodSeconds()*3));

      // garis SL / TP dari pending (kalau diisi) supaya sekalian kelihatan
      string sln = base + "_sl";
      string tpn = base + "_tp";
      if(sl > 0)
        {
         if(ObjectFind(0, sln) < 0)
           {
            ObjectCreate(0, sln, OBJ_HLINE, 0, 0, sl);
            ObjectSetInteger(0, sln, OBJPROP_STYLE, STYLE_DOT);
            ObjectSetInteger(0, sln, OBJPROP_WIDTH, 1);
            ObjectSetInteger(0, sln, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, sln, OBJPROP_HIDDEN, true);
           }
         ObjectSetDouble (0, sln, OBJPROP_PRICE, sl);
         ObjectSetInteger(0, sln, OBJPROP_COLOR, clrRed);
         ObjectSetString (0, sln, OBJPROP_TOOLTIP, "SL " + DoubleToString(sl,_Digits));
        }
      else ObjectDelete(0, sln);

      if(tp > 0)
        {
         if(ObjectFind(0, tpn) < 0)
           {
            ObjectCreate(0, tpn, OBJ_HLINE, 0, 0, tp);
            ObjectSetInteger(0, tpn, OBJPROP_STYLE, STYLE_DOT);
            ObjectSetInteger(0, tpn, OBJPROP_WIDTH, 1);
            ObjectSetInteger(0, tpn, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, tpn, OBJPROP_HIDDEN, true);
           }
         ObjectSetDouble (0, tpn, OBJPROP_PRICE, tp);
         ObjectSetInteger(0, tpn, OBJPROP_COLOR, clrLime);
         ObjectSetString (0, tpn, OBJPROP_TOOLTIP, "TP " + DoubleToString(tp,_Digits));
        }
      else ObjectDelete(0, tpn);
     }

   // --- bersihkan garis order yang sudah tidak ada (kena / dibatalkan) ---
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string nm = ObjectName(0, i, -1, -1);
      if(StringFind(nm, "PabloPend_") != 0) continue;
      // ekstrak ticket dari nama: PabloPend_<ticket>_xx
      string rest = StringSubstr(nm, 10);
      int us = StringFind(rest, "_");
      if(us <= 0) continue;
      ulong tk = (ulong)StringToInteger(StringSubstr(rest, 0, us));
      bool alive = false;
      for(int k = 0; k < n; k++) if(tickets[k] == tk) { alive = true; break; }
      if(!alive) ObjectDelete(0, nm);
     }
  }

void UpdateLevelLine()
  {
   if(!InpShowLevel) return;
   MqlRates r[];
   if(CopyRates(_Symbol, InpCandleTF, 0, 3, r) < 3) return;
   // garis di level yang benar2 dipakai sbg harga pending, bukan close
   bool bullish = (r[1].close > r[1].open);
   double lvl = (bullish ? r[1].low : r[1].high);
   gLastCandleLevel = lvl;
   if(ObjectFind(0, gLevelObjName) < 0)
     {
      ObjectCreate(0, gLevelObjName, OBJ_HLINE, 0, 0, lvl);
      ObjectSetInteger(0, gLevelObjName, OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, gLevelObjName, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, gLevelObjName, OBJPROP_WIDTH, 1);
      ObjectSetString(0, gLevelObjName, OBJPROP_TOOLTIP, "Candle trigger level");
     }
   else
      ObjectSetDouble(0, gLevelObjName, OBJPROP_PRICE, lvl);
  }


//==================================================================
// EVENT: klik tombol panel
//==================================================================
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(StringFind(sparam, PN) != 0) return;

   if(sparam == PN + "btnReset")
     {
      ResetDayTracker();
      Print("PANEL: RESET harian -> trading dilanjutkan");
     }
   else if(sparam == PN + "btnClBuy")
     {
      CloseSide(POSITION_TYPE_BUY);
      Print("PANEL: tutup semua BUY");
     }
   else if(sparam == PN + "btnClSell")
     {
      CloseSide(POSITION_TYPE_SELL);
      Print("PANEL: tutup semua SELL");
     }
   else if(sparam == PN + "btnClAll")
     {
      CloseAll();
      Print("PANEL: tutup SEMUA posisi");
     }

   // lepas state tombol biar gak nyangkut
   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   ChartRedraw();
  }

//==================================================================
void OnTick()
  {
   // rata2 spread di-update sekali per tick (dipakai filter volatilitas)
   double sprNow = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(gAvgSpread <= 0) gAvgSpread = sprNow;
   else                gAvgSpread = gAvgSpread * 0.99 + sprNow * 0.01;

   // reset harian
   MqlDateTime nowDt, lastDt;
   TimeToStruct(TimeCurrent(), nowDt);
   TimeToStruct(gLastDay, lastDt);
   if(nowDt.day != lastDt.day || nowDt.mon != lastDt.mon || nowDt.year != lastDt.year)
      ResetDayTracker();

   // v2.21.1 FIX: ManageHedge() TIDAK BOLEH mematikan RiskGuard.
   // v2.21 bug: kalau hedge aktif, OnTick() langsung "return" sehingga
   // CUT LOSS BASKET dan CUT LOSS EQUITY (InpMaxEquityDD) TIDAK PERNAH
   // dicek selama hedge aktif -> rugi bisa menumpuk tanpa rem.
   // Sekarang: hedge hanya menandai "sedang hedge"; RiskGuard SELALU jalan.
   bool hedgeBusy = ManageHedge();

   // PENTING: RiskGuard dijalankan PALING AWAL.
   // Di versi lama, spread guard dan gStoppedToday keluar duluan, jadi saat
   // spread melebar (persis momen paling berbahaya) cut loss tidak pernah
   // dieksekusi. Proteksi harus selalu jalan lebih dulu.
   bool stop = RiskGuard();

   PanelUpdate();   // panel di-update di semua jalur, tidak ikut ter-skip

   if(stop || gStoppedToday)
     { Comment("STOP HARI INI (cut loss / target)"); return; }

   // spread guard: hanya menahan ENTRY BARU, bukan manajemen posisi
   bool spreadLebar = (InpMaxSpreadPts > 0 && (int)sprNow > InpMaxSpreadPts);

   // ===== JAM LOCK =====
   gJamLockAktif = JamLockNow();
   if(gJamLockAktif)
     {
      if(InpJamLockTutupPos)
        {
         int lb, ls; CountSides(lb, ls);
         if(lb + ls > 0) { Print("JAM LOCK: tutup semua posisi"); CloseAll(); }
        }
      Comment("JAM LOCK aktif (", InpJamLockStop, ":00-", InpJamLockResume, ":00 broker)");
      return;
     }

   UpdateAdaptif();   // v2.19: refresh TP adaptif + skala basket + regime (v2.21)

   // v2.21: kelola trailing basket & chase pending lebih dulu.
   ManageTrailBasket();
   if(gStoppedToday) return;
   ChasePending();

   ManagePositions();
   UpdateLevelLine();
   DrawPendingLines();   // v2.16: gambar garis+label order pending di chart

   int buyCnt, sellCnt; CountSides(buyCnt, sellCnt);

   // ===== ANTI-NEWS =====
   string newsWhy = "";
   if(NewsBlocked(newsWhy))
     {
      // aksi 2 / 3 -> tutup semua posisi + pending
      if(InpNewsAksi >= 2)
        {
         if(buyCnt + sellCnt > 0)
           {
            Print("NEWS: tutup semua (", newsWhy, ")");
            CloseAll();
            // v2.20: aksi 3 = blok + tutup + JEDA (dulu input ini ada tapi
            // tidak pernah dipakai). Sekarang jeda benar-benar diterapkan.
            if(InpNewsAksi >= 3 && InpNewsJedaMenit > 0)
               gCooldownUntil = TimeCurrent() + InpNewsJedaMenit * 60;
           }
         Comment("NEWS BLOCK: ", newsWhy);
         return;
        }
      Comment("NEWS BLOCK: ", newsWhy);
      // Aksi 1: entry baru diblok, averaging TETAP jalan (aman utk layer)
      if(!spreadLebar)
        {
         if(buyCnt  > 0) TryLayerSide(POSITION_TYPE_BUY,  buyCnt);
         if(sellCnt > 0) TryLayerSide(POSITION_TYPE_SELL, sellCnt);
        }
      return;
     }

   if(spreadLebar)
     { Comment("Spread lebar: ", DoubleToString(sprNow,0), " (entry ditahan)"); return; }

   Comment("");

   if(buyCnt + sellCnt > 0)
     {
      if(buyCnt  > 0) TryLayerSide(POSITION_TYPE_BUY,  buyCnt);
      if(sellCnt > 0) TryLayerSide(POSITION_TYPE_SELL, sellCnt);
      return;
     }

   // v2.21.1: kalau sedang hedge, JANGAN buka basket BARU.
   // Manajemen posisi (layer, TP, trailing) tetap jalan di atas.
   if(hedgeBusy) { Comment("HEDGE aktif: entry baru ditahan"); return; }

   // v2.21.2 FILTER SIDEWAYS: entry basket BARU hanya saat pasar sideways.
   // Kalau tren -> tahan. Posisi lama tetap dikelola (TP/SL/trailing/layer).
   if(InpPakaiSideways && buyCnt + sellCnt == 0 && !gSidewaysNow)
     {
      Comment("SIDEWAYS FILTER: pasar TREN (cross ", gCrossCount, "/",
              InpSidewaysMinCross, ") -> entry baru ditahan");
      return;
     }

   // ---- flat: entry basket baru ----
   int bp, sp; CountPending(bp, sp);
   if(bp + sp == 0)
     {
      MqlRates rr[];
      if(CopyRates(_Symbol, InpCandleTF, 0, 2, rr) >= 2)
        {
         double body = MathAbs(rr[1].close - rr[1].open);
         static datetime lastLog = 0;
         if(TimeCurrent() - lastLog >= 60)
           {
            lastLog = TimeCurrent();
            Print("DIAG flat: body=", DoubleToString(body, _Digits),
                  " min=", DoubleToString(InpCandleMin, _Digits),
                  " max=", DoubleToString(InpCandleMax, _Digits),
                  " sigmode=", EnumToString(InpSignalMode),
                  " mode=", EnumToString(InpEntryMode));
           }
        }
     }
   // v2.20 COOLDOWN: jeda antar entry baru (ini rem yang bikin 12 entry/7 menit
   // jadi mustahil). Averaging/layer tetap jalan di atas — yang ditahan hanya
   // pembukaan basket BARU.
   string cdWhy;
   if(CooldownBlocked(cdWhy))
     { Comment("COOLDOWN: ", cdWhy); return; }

   TryEntry();
  }
//+------------------------------------------------------------------+
