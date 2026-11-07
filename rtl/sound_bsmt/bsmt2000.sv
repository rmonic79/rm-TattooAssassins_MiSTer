// SPDX-License-Identifier: GPL-3.0-or-later
//
// bsmt2000.sv — il chip audio di Tattoo Assassins.
//
// Il BSMT2000 ("Brian Schmidt's Mouse Trap") e' fisicamente un TMS320C15 con
// firmware mascherato. Il firmware NON e' nel set del gioco: MAME lo tiene
// dentro il proprio device, quindi non si puo' "eseguire". Come fanno MAME e
// SAMbuild, qui se ne riproduce il COMPORTAMENTO, che e' un sample player:
//
//   12 voci PCM 8-bit + 1 voce ADPCM, 7 registri ciascuna
//     CURRPOS=0  RATE=1  LOOPEND=2  LOOPSTART=3  BANK=4  RIGHTVOL=5  LEFTVOL=6
//
// Riferimento: reference/bsmt2000/bsmt2000_sambuild.c (bsmt2000_update) e
// reference/bsmt2000/bs_codec.c (l'ADPCM di Brian Schmidt, verificato
// equivalente a quello di MAME: n*v + n/2 per v>0 == n*(v+0.5)).
//
// Voce PCM, per ogni campione di uscita:
//     sample = base[pos] << 8            base = campioni + bank*0x10000
//     left  += sample * lvol ;  right += sample * rvol
//     frac += rate ; pos += frac>>11 ; frac &= 0x7FF
//     se pos >= LOOPEND:  pos += LOOPSTART-LOOPEND ; frac = 0
//
// Voce ADPCM: frac conta 0..5, pos avanza ogni 6; lo stato si aggiorna ogni 3
// campioni (frac==1 nibble ALTO, frac==4 nibble BASSO) e il suo contributo
// entra nell'accumulatore con volume RADDOPPIATO (2x APAC).
//
// Uscita: accumulatore >> 16 (sul TMS e' una SACH, copia i 16 bit alti).

module bsmt2000 #(
	parameter integer CLK_HZ    = 96000000,   // clk_sys del core (NON 28 MHz)
	parameter integer SAMPLE_HZ =    24000   // 24-34 kHz secondo il modo
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        paused,     // pausa dell'OSD, allineata al frame

	// scrittura registri dalla sound CPU
	input  wire [7:0]  reg_idx,
	input  wire [15:0] reg_data,
	input  wire        reg_wr,

	output reg         ready,      // 1 = pronto (rialza l'IRQ del 6809)

	// ROM campioni (2 MB) — porta di sola lettura
	output reg  [23:0] rom_addr,
	input  wire [7:0]  rom_data,
	output reg         rom_req,
	input  wire        rom_valid,

	output reg signed [15:0] audio_l,
	output reg signed [15:0] audio_r
);

localparam integer NVOICE     = 11;   // voci PCM: il MODO 1 ne ha 11 (vedi decode)
localparam integer ADPCM_V    = 12;   // indice della voce ADPCM

// ── Registri delle voci ──────────────────────────────────────────────────────
// 13 voci x 7 registri. reg_idx e' gia' l'indice invertito calcolato dalla
// sound board (offset ^ 0xFF, decobsmt.cpp:30).
//
// La mappa indice->(voce,campo) NON e' a passo uniforme. Da
// bsmt2000_sambuild.c (regmap del modo 1 + bsmt2000_reg_write):
//     regmap[1] = { 0x00, 0x18, 0x24, 0x30, 0x3C, 0x48, 0xFF }
//     regindex = 6; while (offset < regmap[regindex]) --regindex;
//     voice_index = offset - regmap[regindex];
//     offset >= 0x6D  ->  voce ADPCM
// cioe' il PRIMO campo e' largo 0x18 e gli altri 0x0C:
//     0x00-0x17 CURRPOS   0x18-0x23 RATE      0x24-0x2F LOOPEND
//     0x30-0x3B LOOPSTART 0x3C-0x47 BANK      0x48-0x6C RIGHTVOL
// (LEFTVOL ha base 0xFF: nel modo 1 non si raggiunge.)
// Modo 1 = 24 kHz, 11 voci PCM stereo + 1 ADPCM.
reg [15:0] v_currpos  [0:12];
reg [15:0] v_rate     [0:12];
reg [15:0] v_loopend  [0:12];
reg [15:0] v_loopstart[0:12];
reg [15:0] v_bank     [0:12];
reg [15:0] v_rvol     [0:12];
reg [15:0] v_lvol     [0:12];
reg [10:0] v_frac     [0:12];

// Registro 0x77 del ramo compresso (bsmt2000_sambuild.c: chip->adpcm_77). NON e'
// per voce: e' del chip, e serve come volume di ripiego delle voci PCM.
reg [15:0] adpcm_77;

integer i;

// Richieste verso lo stato ADPCM, che appartiene alla FSM piu' sotto: un reg
// non puo' essere guidato da due always, quindi i registri chiedono e la FSM
// esegue. a_rst_req = azzera current/delta (scrittura di RATE != 0),
// a_pos_req = ricarica la posizione (scrittura di CURRPOS).
reg a_rst_req, a_pos_req;   // lato registri (toggle)
reg a_rst_ack, a_pos_ack;   // lato FSM

// decodifica registro secondo regmap[1] (vedi sopra): niente divisioni, e'
// una scala a soglie e la voce e' la distanza dalla base del campo.
reg [3:0] w_field;
reg [7:0] w_base;
always @(*) begin
	// La scala delle basi NON e' unica: bsmt2000_sambuild.c ha regmap[8][7], una
	// riga per MODO. Qui c'era cablata la riga 0 — quella MONO a 12 voci, dove
	// LEFTVOL non esiste (0xff) — e ogni scrittura finiva nel campo e nella voce
	// sbagliati. Tattoo Assassins usa il MODO 1:
	//     { 0x00, 0x16, 0x21, 0x2c, 0x37, 0x42, 0x4d }   11 voci, stereo
	// PROVATO sul gioco: nel trace il driver scrive due valori costanti su due
	// serie contigue di 11 registri distanti 0x0B — 0x42..0x4C e 0x4D..0x57 —
	// che sono esattamente RIGHTVOL e LEFTVOL del modo 1. Nessuna altra riga
	// della tabella combacia (modo 0 = 0x48 passo 12, modo 5 = 0x54/0x60,
	// modo 6 = 0x38/0x40, modo 7 = 0x3f/0x48).
	// Lo stacco PCM/ADPCM a 0x6D e gli indirizzi ADPCM sono invece FISSI, non
	// dipendono dal modo (bsmt2000_sambuild.c riga 575 e switch a 618).
	if      (reg_idx >= 8'h6D) begin w_field = 4'd7;  w_base = 8'h00; end // ADPCM
	else if (reg_idx >= 8'h4D) begin w_field = 4'd6;  w_base = 8'h4D; end // LEFTVOL
	else if (reg_idx >= 8'h42) begin w_field = 4'd5;  w_base = 8'h42; end // RIGHTVOL
	else if (reg_idx >= 8'h37) begin w_field = 4'd4;  w_base = 8'h37; end // BANK
	else if (reg_idx >= 8'h2C) begin w_field = 4'd3;  w_base = 8'h2C; end // LOOPSTART
	else if (reg_idx >= 8'h21) begin w_field = 4'd2;  w_base = 8'h21; end // LOOPEND
	else if (reg_idx >= 8'h16) begin w_field = 4'd1;  w_base = 8'h16; end // RATE
	else                       begin w_field = 4'd0;  w_base = 8'h00; end // CURRPOS
end
wire [7:0] w_vidx  = reg_idx - w_base;
wire       w_valid = (w_field == 4'd7) | (w_vidx < NVOICE);
wire [3:0] w_voice = (w_field == 4'd7) ? 4'd12 : w_vidx[3:0];

always @(posedge clk) begin
	if (reset) begin
		for (i = 0; i <= 12; i = i + 1) begin
			v_currpos[i]  <= 16'd0; v_rate[i]  <= 16'd0;
			v_loopend[i]  <= 16'd0; v_loopstart[i] <= 16'd0;
			v_bank[i]     <= 16'd0;
			// SAMbuild init_voice(): al reset i volumi valgono 0x7FFF (MASSIMO),
			// non zero. Azzerandoli, ogni voce avviata dal driver senza riscrivere
			// il volume suonava a zero -> muto per sempre dopo un reset del chip.
			v_rvol[i]     <= 16'h7FFF;
			v_lvol[i]     <= 16'h7FFF; v_frac[i]  <= 11'd0;
		end
		a_rst_req <= 1'b0; a_pos_req <= 1'b0;
		adpcm_77  <= 16'd0;
	end else begin
		// ORDINE OBBLIGATO — prima il commit della FSM, POI la scrittura del driver.
		// Erano in catena if/else: nella stessa finestra o si perdeva il commit, o
		// (peggio) il commit riscriveva `vecchia_pos + rate` SOPRA la posizione di
		// partenza appena scritta dal driver, e la voce ripartiva dal punto
		// sbagliato = rumore. Messi in sequenza, entrambi avvengono sempre e su
		// collisione della stessa voce vince l'ultima assegnazione, cioe' il driver.
		if (step_commit) begin
			v_currpos[commit_v] <= nxt_pos;
			v_frac   [commit_v] <= nxt_frac;
		end
		if (adpcm_commit) begin
			v_currpos[ADPCM_V] <= a_pos;
			v_frac   [ADPCM_V] <= {8'd0, a_frac};
		end

		if (reg_wr && w_valid) begin
		if (w_field != 4'd7) begin
			// voce PCM
			case (w_field)
				4'd0: begin v_currpos[w_voice] <= reg_data; v_frac[w_voice] <= 11'd0; end
				4'd1: v_rate     [w_voice] <= reg_data;
				4'd2: v_loopend  [w_voice] <= reg_data;
				4'd3: v_loopstart[w_voice] <= reg_data;
				4'd4: v_bank     [w_voice] <= reg_data;
				4'd5: v_rvol     [w_voice] <= reg_data;
				default: v_lvol  [w_voice] <= reg_data;   // 6 = LEFTVOL
			endcase
		end else begin
			// voce ADPCM: indirizzi SPECIFICI, non un campo generico
			// (bsmt2000_sambuild.c, ramo "compressed voice")
			case (reg_idx)
				8'h6D: v_loopend[ADPCM_V] <= reg_data;                 // loop stop
				8'h6E: v_rvol   [ADPCM_V] <= reg_data;                 // R vol (in play)
				8'h6F: v_bank   [ADPCM_V] <= reg_data;                 // rom bank
				8'h70: v_lvol   [ADPCM_V] <= reg_data;                 // L vol (in play)
				8'h73: begin                                           // RATE = "dati validi"
					v_rate[ADPCM_V] <= reg_data;
					// lo stato ADPCM lo possiede la FSM: qui si chiede il reset
					if (reg_data != 16'd0) a_rst_req <= ~a_rst_req;   // toggle: la FSM allinea
				end
				8'h74: v_rvol   [ADPCM_V] <= reg_data;                 // R vol (avvio)
				8'h75: begin v_currpos[ADPCM_V] <= reg_data; a_pos_req <= ~a_pos_req; end
				8'h78: v_lvol   [ADPCM_V] <= reg_data;                 // L vol (avvio)
				// 0x77 NON e' ignorabile: bsmt2000_sambuild.c:675 lo salva in
				// chip->adpcm_77 e la riga 369 lo usa come volume di RIPIEGO delle
				// voci PCM — `if (adpcm_77 > 0 && rvol == 0 && lvol == 0)
				// rvol = lvol = adpcm_77`. Scartandolo, ogni voce PCM lasciata a
				// volume zero dal driver resta muta invece di suonare ad adpcm_77.
				8'h77: adpcm_77 <= reg_data;
				default: ;   // il resto: ignorato
			endcase
		end
		end
	end
end

// ── Cadenza del campione di uscita ───────────────────────────────────────────
localparam integer SDIV = CLK_HZ / SAMPLE_HZ;
reg [17:0] scnt;
reg        sample_tick;
always @(posedge clk) begin
	sample_tick <= 1'b0;
	// in pausa non si generano nuovi campioni: la FSM resta in S_IDLE e le uscite
	// audio TENGONO l'ultimo valore invece di continuare a suonare.
	if (reset) scnt <= 18'd0;
	else if (paused) scnt <= scnt;
	else if (scnt >= SDIV[17:0]-1) begin scnt <= 18'd0; sample_tick <= 1'b1; end
	else scnt <= scnt + 18'd1;
end

// ── Stato ADPCM ──────────────────────────────────────────────────────────────
reg signed [15:0] a_current;
reg        [11:0] a_delta_n;
reg        [15:0] a_pos;
reg        [2:0]  a_frac;
reg               adpcm_commit;

// SAMbuild incrementa frac e poi TESTA IL VALORE NUOVO:
//     frac++; if (frac == 6) { pos++; frac = 0; }
//     if (frac == 1 || frac == 4) { ...aggiorna lo stato ADPCM... }
// Qui l'incremento di a_frac e' non-blocking, quindi testare `a_frac` significa
// testare il valore VECCHIO: l'uscita usciva sfasata di un campione. Misurato col
// golden in Python contro bsmt2000_sambuild.c sulla ROM campioni vera:
// con a_frac 101 e 133 differenze su 400 campioni (banchi 0 e 3); con il frac
// SUCCESSIVO 0 differenze su 600 campioni per i banchi 0, 3 e 17 — bit-exact.
wire [2:0] a_frac_nxt = (a_frac == 3'd5) ? 3'd0 : a_frac + 3'd1;

// PIPELINE del passo ADPCM su DUE colpi di clock. Nella build precedente TUTTI
// e 20 i percorsi peggiori finivano in `a_current` (sorgenti a_delta_n[11],
// bsmt_smp_data[7], a_frac[2]) con 12.187 ns di data delay contro 10.416 ns di
// periodo: slack -1.720. In un solo ciclo c'era moltiplicatore -> somma ->
// somma -> clamp. Qui la prima meta' (i due moltiplicatori, in parallelo) resta
// in S_ACC e la seconda (somma + clamp) passa in S_DONE, il ciclo dopo.
// NESSUN cambio di comportamento: fra S_ACC e S_DONE nessuno legge a_current,
// perche' l'accumulo nell'uscita e' gia' avvenuto, e il campione successivo
// arriva 4000 clock dopo.
reg signed [31:0] adp_delta;
reg        [19:0] adp_nd;
reg               adp_step;

// Il TMS ha un accumulatore a 32 bit CON SATURAZIONE, e satura dopo OGNI voce
// (bsmt2000_sambuild.c, commento a riga ~421: "this overflow check happens
// after each voices accumulation on the TMS, as it only has a 32bit ACC with
// saturation enabled"). Con volumi da ~15000 e 11 voci la somma supera i 32
// bit: senza saturare il mix esce diverso da quello del chip.
function signed [39:0] sat32(input signed [39:0] v);
	sat32 = (v >  40'sd2147483647) ?  40'sd2147483647 :
	        (v < -40'sd2147483648) ? -40'sd2147483648 : v;
endfunction

function signed [15:0] clamp16(input signed [31:0] v);
	clamp16 = (v >  32767) ?  16'sd32767 :
	          (v < -32768) ? 16'sh8000 : v[15:0];
endfunction

// tabella dei passi (identica in bs_codec.c e in MAME)
function [7:0] delta_tab(input [3:0] v);
	case (v)
		4'd0,4'd1,4'd15: delta_tab = 8'd154;
		4'd2,4'd14:      delta_tab = 8'd128;
		4'd3,4'd13:      delta_tab = 8'd102;
		4'd4,4'd12:      delta_tab = 8'd77;
		default:         delta_tab = 8'd58;
	endcase
endfunction

// ── Macchina a stati: per ogni tick scorre le 13 voci ────────────────────────
localparam S_IDLE=0, S_REQ=1, S_WAIT=2, S_ACC=3, S_DONE=4, S_ADD=5;
reg [2:0]  st;
reg [3:0]  cur_v;
reg signed [39:0] acc_l, acc_r;
wire signed [39:0] acc_l_sh = acc_l >>> 16;   // shift ARITMETICO: tiene il segno
wire signed [39:0] acc_r_sh = acc_r >>> 16;
reg [15:0] nxt_pos;
reg [10:0] nxt_frac;
reg        step_commit;
// Voce a cui appartiene l'aggiornamento di posizione. SERVE: `step_commit` e
// `cur_v <= cur_v+1` sono entrambi non-blocking e scattano nello STESSO ciclo
// di S_ACC, quindi quando il blocco dei registri vede step_commit=1 il
// contatore e' GIA' avanzato: `v_currpos[cur_v] <= nxt_pos` scriveva la
// posizione della voce N dentro la voce N+1.
reg [3:0]  commit_v;

// SAMbuild, ciclo delle voci: `if (voice->reg[REG_BANK] < chip->total_banks)`
// — una voce con bank FUORI REGIONE viene SALTATA, non suonata. I campioni di
// tattass sono 2 MB = 32 bank da 64 KB: senza questo controllo un bank >= 32
// legge oltre la regione (sprite e tile in DDR) e li suona a tutto volume.
localparam [7:0] TOTAL_BANKS = 8'd32;          // 2 MB / 64 KB
wire [23:0] voice_base = {v_bank[cur_v][7:0], 16'd0};   // bank * 0x10000
wire bank_ok = (v_bank[cur_v][15:8] == 8'd0) && (v_bank[cur_v][7:0] < TOTAL_BANKS);
// SAMbuild, voce compressa: contribuisce SOLO se
//   chip->adpcm && reg[REG_BANK] < total_banks && reg[REG_RATE]
// e si FERMA a fine loop (`if (pos >= reg[REG_LOOPEND]) break;`).
// Qui girava sempre: con i volumi a 0x7FFF del reset accumulava a vuoto
// a_current * 0x7FFF * 2 -> rumore continuo a volume pieno.
wire adpcm_bank_ok = (v_bank[ADPCM_V][15:8] == 8'd0)
                  && (v_bank[ADPCM_V][7:0] < TOTAL_BANKS);
wire adpcm_active  = adpcm_bank_ok && (v_rate[ADPCM_V] != 16'd0)
                  && (a_pos < v_loopend[ADPCM_V]);

// bsmt2000_sambuild.c riga 369, ciclo delle voci PCM (NON quello ADPCM):
//     if (chip->adpcm_77 > 0 && rvol == 0 && lvol == 0) rvol = lvol = chip->adpcm_77;
// Serve a entrambi i canali insieme: si applica solo se sono zero TUTTI E DUE.
wire pcm_vol_fb = (adpcm_77 != 16'd0)
               && (v_lvol[cur_v] == 16'd0) && (v_rvol[cur_v] == 16'd0);
// REGISTRATI, non combinatori. Due comparatori a 16 bit piu' un mux davanti
// all'OPERANDO del moltiplicatore allungherebbero il percorso piu' critico del
// modulo (moltiplicatore -> somma a 40 bit -> saturazione). cur_v e' stabile da
// S_REQ fino a S_ACC, quindi si calcolano un colpo prima: stesso risultato,
// zero latenza in piu', profondita' combinatoria invariata rispetto a prima.
reg [15:0] pcm_lvol, pcm_rvol;
// Stessa cosa per la voce ADPCM, che il ripiego 0x77 NON lo usa (in SAMbuild il
// ripiego sta solo nel ciclo delle voci PCM). Misurato: dopo aver spezzato il
// passo ADPCM, i percorsi peggiori del modulo erano diventati
// `v_lvol[12] -> acc_l[*]` a -1.682, cioe' proprio questi due volumi che
// andavano dritti nel moltiplicatore. Registrandoli un colpo prima come i PCM
// il moltiplicatore parte da un registro.
reg [15:0] adp_lvol, adp_rvol;

// PIPELINE DELL'ACCUMULO. In un ciclo solo c'era moltiplicatore 16x16 -> somma
// a 40 bit -> sat32 (due confronti a 40 bit piu' mux) -> registro: misurato
// `v_lvol[12] -> acc_l[19]` con 11.482 ns di ritardo su 10.416 di periodo.
// Qui S_ACC calcola e REGISTRA solo il prodotto, e S_ADD fa somma e
// saturazione. Costa un ciclo per voce, 13 su 4000 disponibili per campione.
// 34 bit: 16x16 con segno fa 32, e il ramo ADPCM raddoppia.
reg signed [33:0] prod_l, prod_r;

always @(posedge clk) begin
	step_commit  <= 1'b0;
	adpcm_commit <= 1'b0;
	rom_req      <= 1'b0;
	adp_step     <= 1'b0;
	// azzerati per default: una voce saltata non deve sommare il prodotto
	// della voce precedente in S_ADD
	prod_l       <= 34'sd0;
	prod_r       <= 34'sd0;

	if (reset) begin
		st <= S_IDLE; cur_v <= 4'd0; commit_v <= 4'd0; ready <= 1'b1;
		acc_l <= 40'sd0; acc_r <= 40'sd0;
		audio_l <= 16'sd0; audio_r <= 16'sd0;
		a_current <= 16'sd0; a_delta_n <= 12'd10; a_pos <= 16'd0; a_frac <= 3'd0;
		a_rst_ack <= 1'b0; a_pos_ack <= 1'b0;
		adp_delta <= 32'sd0; adp_nd <= 20'd0;
		pcm_lvol  <= 16'd0;  pcm_rvol <= 16'd0;
		adp_lvol  <= 16'd0;  adp_rvol <= 16'd0;
	end else begin
	// richieste dai registri (vedi a_rst_req / a_pos_req)
	if (a_rst_req != a_rst_ack) begin
		a_rst_ack <= a_rst_req;
		a_current <= 16'sd0;
		a_delta_n <= 12'd10;
	end
	if (a_pos_req != a_pos_ack) begin
		a_pos_ack <= a_pos_req;
		a_pos     <= v_currpos[ADPCM_V];
		a_frac    <= 3'd0;
	end
	case (st)
		S_IDLE: if (sample_tick) begin
			acc_l <= 40'sd0; acc_r <= 40'sd0;
			cur_v <= 4'd0; st <= S_REQ; ready <= 1'b0;
		end

		S_REQ: begin
			// volumi PCM della voce corrente, calcolati UN COLPO PRIMA (vedi la
			// nota sulla dichiarazione): cur_v non cambia fino a S_ACC.
			pcm_lvol <= pcm_vol_fb ? adpcm_77 : v_lvol[cur_v];
			pcm_rvol <= pcm_vol_fb ? adpcm_77 : v_rvol[cur_v];
			adp_lvol <= v_lvol[ADPCM_V];
			adp_rvol <= v_rvol[ADPCM_V];
			// voce muta o non attiva: salta. Il confronto e' con la voce ADPCM,
			// non con NVOICE: passato a 11 voci, lo slot 11 non rientrava piu' nel
			// salto e faceva una lettura DDR a ogni campione pur non essendo
			// programmabile (w_valid scarta gli indici >= NVOICE).
			if ((cur_v == ADPCM_V) ? !adpcm_active
			                       : ((v_rate[cur_v] == 16'd0) || !bank_ok)) begin
				st <= S_ACC;                       // niente da sommare
			end else begin
				rom_addr <= (cur_v == ADPCM_V) ? (voice_base + {8'd0, a_pos})
				                               : (voice_base + {8'd0, v_currpos[cur_v]});
				rom_req  <= 1'b1;
				st       <= S_WAIT;
			end
		end

		S_WAIT: if (rom_valid) st <= S_ACC;

		S_ACC: begin
			if ((cur_v == ADPCM_V) && adpcm_active) begin
				// contributo: volume RADDOPPIATO
				prod_l <= $signed(a_current) * $signed({1'b0, adp_lvol}) * 2;
				prod_r <= $signed(a_current) * $signed({1'b0, adp_rvol}) * 2;
				// avanzamento: frac 0..5, pos ogni 6, stato ogni 3
				if (a_frac == 3'd5) begin a_frac <= 3'd0; a_pos <= a_pos + 16'd1; end
				else                     a_frac <= a_frac + 3'd1;
				// PRIMA META' del passo: solo i due moltiplicatori, in parallelo.
				// La somma e i clamp stanno in S_DONE (vedi la nota sopra).
				if ((a_frac_nxt == 3'd1) || (a_frac_nxt == 3'd4)) begin : adpcm_step
					reg signed [4:0]  v;
					reg signed [31:0] delta;
					// nibble ALTO a frac 1, BASSO a frac 4, esteso in segno a 5 bit
					v = (a_frac_nxt == 3'd1) ? $signed({rom_data[7], rom_data[7:4]})
					                         : $signed({rom_data[3], rom_data[3:0]});
					delta = $signed(a_delta_n) * v;
					if (v > 0) delta = delta + $signed({1'b0, a_delta_n} >> 1);
					else       delta = delta - $signed({1'b0, a_delta_n} >> 1);
					adp_delta <= delta;
					// SAMbuild: delta_tab[value+8], value = nibble ESTESO IN SEGNO
					// (-8..+7) -> indice = nibble XOR 8. Prima indicizzavo col
					// nibble grezzo: per il nibble 0 usavo 154 invece di 58.
					adp_nd    <= (a_delta_n * delta_tab(v[3:0] ^ 4'd8)) >> 6;
					adp_step  <= 1'b1;
				end
				adpcm_commit <= 1'b1;
			// il `cur_v != ADPCM_V` e' NECESSARIO: se la voce ADPCM viene saltata
			// (non attiva) si finisce comunque in S_ACC, e senza questa guardia il
			// ramo PCM girerebbe sulla voce 12 con rom_data mai letto.
			end else if ((cur_v != ADPCM_V) && (v_rate[cur_v] != 16'd0) && bank_ok) begin : pcm_step
				reg signed [15:0] sample;
				reg        [27:0] f;
				sample = {rom_data, 8'd0};        // 8 bit signed, shiftato a 16
				// Il volume e' il registro INTERO a 16 bit: bsmt2000_sambuild.c
				// riga 386 fa `sample * lvol` con lvol = reg[REG_LEFTVOL], e il
				// commento a riga 379 dice "accumulator expects everything in
				// 16bit*16bit (sampledata*volume)". Prima qui si prendeva solo
				// [7:0]: con RIGHTVOL=0x3AC5 il volume valeva 0xC5=197 invece di
				// 15045, cioe' un valore senza rapporto con quello voluto.
				prod_l <= $signed(sample) * $signed({1'b0, pcm_lvol});
				prod_r <= $signed(sample) * $signed({1'b0, pcm_rvol});
				f = {17'd0, v_frac[cur_v]} + {12'd0, v_rate[cur_v]};
				nxt_pos  = v_currpos[cur_v] + f[26:11];   // pos e' 16 bit: il riporto si scarta
				nxt_frac = f[10:0];
				if (nxt_pos >= v_loopend[cur_v]) begin
					nxt_pos  = nxt_pos + v_loopstart[cur_v] - v_loopend[cur_v];
					nxt_frac = 11'd0;
				end
				// Il commit si applica il ciclo DOPO, mentre `reg_wr` dura un solo
				// clk: se il driver scrive CURRPOS di questa stessa voce proprio
				// adesso, il calcolo qui sopra ha usato la posizione VECCHIA (la
				// non-blocking non e' ancora visibile) e il ciclo prossimo
				// riscriverebbe vecchia_pos+passo SOPRA la posizione di partenza
				// appena impostata. Il riordino del blocco registri chiude la
				// collisione nello stesso ciclo ma non questa: qui il commit in
				// volo va proprio SOPPRESSO.
				step_commit <= ~(reg_wr & w_valid & (w_field == 4'd0)
				                 & (w_voice == cur_v));
				commit_v    <= cur_v;
			end
			st <= S_ADD;
		end

		// SECONDA META' dell'accumulo: somma a 40 bit e saturazione, sul
		// prodotto gia' registrato in S_ACC. Se la voce e' stata saltata i
		// prodotti valgono 0 (azzerati come default a ogni ciclo), quindi
		// sommarli non cambia niente e non serve una guardia.
		S_ADD: begin
			// SECONDA META' del passo ADPCM: somma e clamp, sui prodotti gia'
			// calcolati e registrati in S_ACC. Stessa aritmetica di prima, solo
			// spezzata su due clock (vedi la nota alla dichiarazione di adp_*).
			// `a_rst_req == a_rst_ack` = nessun reset del chip in servizio in questo
			// ciclo. Serve per equivalenza ESATTA col codice a un ciclo solo: li'
			// il reset e l'aggiornamento cadevano sempre nello stesso ciclo e
			// vinceva l'aggiornamento; spezzando in due si aprirebbe una finestra
			// nuova in cui un reset arrivato dopo verrebbe sovrascritto da un
			// passo gia' in volo. Col reset in corso il passo si scarta, che e'
			// anche la semantica giusta: il chip e' stato azzerato.
			if (adp_step && (a_rst_req == a_rst_ack)) begin
				a_current <= clamp16($signed(a_current) + adp_delta);
				a_delta_n <= (adp_nd > 20'd2000) ? 12'd2000 :
				             (adp_nd == 20'd0    ? 12'd1 : adp_nd[11:0]);
			end
			acc_l <= sat32(acc_l + prod_l);
			acc_r <= sat32(acc_r + prod_r);
			st    <= (cur_v == ADPCM_V) ? S_DONE : S_REQ;
			if (cur_v != ADPCM_V) cur_v <= cur_v + 4'd1;
		end

		S_DONE: begin
			// uscita = 16 bit alti dell'accumulatore (la SACH del TMS).
			// NB: acc_l[39:16] sarebbe UNSIGNED (le part-select perdono il segno),
			// quindi si usa lo shift aritmetico e si confronta a piena larghezza.
			audio_l <= (acc_l_sh >  40'sd32767) ?  16'sd32767 :
			           (acc_l_sh < -40'sd32768) ? 16'sh8000 : acc_l_sh[15:0];
			audio_r <= (acc_r_sh >  40'sd32767) ?  16'sd32767 :
			           (acc_r_sh < -40'sd32768) ? 16'sh8000 : acc_r_sh[15:0];
			ready <= 1'b1;
			st    <= S_IDLE;
		end

		default: st <= S_IDLE;
	endcase
	end
end

endmodule
