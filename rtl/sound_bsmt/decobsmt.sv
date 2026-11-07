// SPDX-License-Identifier: GPL-3.0-or-later
//
// decobsmt.sv — scheda sonora DECOBSMT di Tattoo Assassins (6809 + BSMT2000).
//
// Il core nasce da Night Slashers, che ha un audio COMPLETAMENTE diverso
// (Z80/HuC6280 + YM2151 + due OKI). Tattoo Assassins usa la scheda dei flipper
// Data East: un 68B09E che pilota un BSMT2000. Finora nel core non esisteva:
// la ROM u7.snd e i 2 MB di campioni venivano scaricati e non li leggeva nessuno.
//
// Mappa di memoria — MAME decobsmt.cpp:16 (reference/bsmt2000/decobsmt.cpp):
//   0x0000-0x1FFF  RAM 8 KB
//   0x2000-0xFFFF  ROM (u7.snd a partire dal suo offset 0x2000)
//   0x2000-0x2001  W  reset del BSMT (sul fronte di DISCESA del bit 7)
//   0x2002-0x2003  R  comando arrivato dal main
//   0x2006-0x2007  R  status
//   0x6000         W  latch del byte ALTO del dato verso il BSMT
//   0xA000-0xA0FF  W  scrive il registro: indice = (offset ^ 0xFF),
//                     dato = {latch, questo byte}
//
// Interrupt:
//   FIRQ periodico a 489 Hz (misurato su macchina reale, decobsmt.cpp:52)
//   IRQ  = "BSMT pronto": si ABBASSA quando la CPU scrive un registro
//          (decobsmt.cpp:32 bsmt1_w) e si rialza quando il chip ha finito.
//
// Clock: 68B09E a 24 MHz / 12 = 2 MHz, con E e Q in quadratura (E in ritardo
// di 90 gradi su Q). Qui si generano da clk con un divisore parametrico.

module decobsmt #(
	parameter integer CLK_HZ  = 96000000,   // clk_sys del core (NON 28 MHz)
	parameter integer CPU_HZ  =  2000000,   // 68B09E: 24 MHz / 12
	parameter integer FIRQ_HZ =      489    // FIRQ periodico della scheda
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        paused,     // pausa dell'OSD, allineata al frame

	// comando dal main (via soundlatch del DECO104)
	input  wire [7:0]  latch_data,
	input  wire        latch_wr,       // impulso: il main ha scritto un comando
	output wire        latch_rd,       // impulso: la sound CPU l'ha letto (ack)

	// reset della scheda dal main (tattass_control_w bit 7)
	input  wire        board_reset_n,

	// ROM del 6809 (u7.snd, 64 KB) — porta di sola lettura
	output wire [15:0] rom_addr,
	input  wire [7:0]  rom_data,

	// verso il BSMT2000
	output reg  [7:0]  bsmt_reg,
	output reg  [15:0] bsmt_data,
	output reg         bsmt_wr,        // impulso di scrittura registro
	output reg         bsmt_reset,
	input  wire        bsmt_ready      // 1 = chip pronto (alza IRQ)
);

// ── Clock enable della CPU: E e Q in quadratura ──────────────────────────────
// Il 6809 vuole due clock sfasati di 90 gradi. Il periodo si copre in QUATTRO
// fasi, quindi ogni fase dura CLK_HZ/(CPU_HZ*4) cicli: con *2 la CPU girava a
// meta' della frequenza voluta.
localparam integer DIV = CLK_HZ / (CPU_HZ * 4);
// Inizializzati esplicitamente: da quando non c'e' piu' il ramo di reset non
// avrebbero nessun valore di partenza, e in un simulatore a 4 stati restano X
// per sempre (la scheda sonora non clockerebbe mai). Sul ferro partono a 0.
reg [15:0] div_cnt = 16'd0;
reg [1:0]  phase   = 2'd0;
reg        cpu_E = 1'b0, cpu_Q = 1'b0;
// E e Q NON SI FERMANO MAI, nemmeno durante il reset. Sul ferro vero vengono dal
// generatore di clock della scheda: con /RESET basso continuano a girare, ed e'
// cosi' che la CPU vede il reset. Qui erano azzerati da `reset`, e il risultato e'
// che mc6809i NON si resettava MAI: il suo reset entra solo su un fronte di
// discesa di E (mc6809i.v:582 `always @(negedge E) rnRESET <= nRESET;`), e con E
// fermo a 0 quel fronte non arriva finche' nRESET e' basso.
// PRECISAZIONE sul caso rotto: al boot FREDDO mc6809i parte comunque bene, perche'
// dichiara `reg [6:0] CpuState = CPUSTATE_RESET;` e `reg rnRESET = 0;` (mc6809i.v
// :376 e :581), quindi appena E riparte esegue la sequenza di reset. Il caso che
// questa fix chiude e' il reset CALDO: li' rnRESET e' rimasto a 1, durante il
// reset non arriva nessun negedge E, e alla release il primo fronte trova
// rnRESET==1 -> la CPU RIPRENDE dall'istruzione di prima, PC compreso, con la
// RAM e lo stato della sessione precedente. Da cui il rumore non deterministico
// dopo un reset. Lasciando E e Q liberi il reset dura ~2730 cicli di E
// (131071 clk / 48), piu' che sufficienti.
// `~paused` congela E e Q, cioe' ferma la CPU sonora: la pausa dell'OSD gatava
// solo le catene audio di Night Slashers (in Template.sv), che su questo gioco
// non esistono, quindi il 6809 continuava a suonare a schermo fermo.
// NB: durante il reset `paused` vale 0, quindi E e Q restano liberi e la CPU
// riceve il reset (vedi la nota sopra).
always @(posedge clk) begin
	if (paused) begin
		// fermi: nessun fronte di E, la CPU non avanza
	end else if (div_cnt >= DIV[15:0]-1) begin
		div_cnt <= 16'd0;
		phase   <= phase + 2'd1;
		// Q anticipa E di 90 gradi:  Q = fasi 1,2   E = fasi 2,3
		cpu_Q <= (phase == 2'd0) | (phase == 2'd1);
		cpu_E <= (phase == 2'd1) | (phase == 2'd2);
	end else begin
		div_cnt <= div_cnt + 16'd1;
	end
end
// QUANDO IL BUS E' VALIDO — e perche' NON si usa il fronte di discesa di E.
// In mc6809i lo stato avanza su `always @(negedge E)` e l'indirizzo e'
// COMBINATORIO (`assign ADDR = addr_nxt`, mc6809i.v:156): sul fronte di discesa
// ADDR/DOut/RnW sono GIA' quelli del ciclo successivo. Un e_fall campionato un
// clk dopo scriveva quindi all'indirizzo sbagliato col dato sbagliato, ed era
// perfino gattato dal RnW del ciclo dopo (scritture perse o fantasma).
// Il fronte di SALITA di E cade a meta' del ciclo, con lo stato fermo da un
// quarto di ciclo: e' li' che si campiona il bus.
reg cpu_E_d;
always @(posedge clk) cpu_E_d <= cpu_E;
wire e_rise = cpu_E & ~cpu_E_d;

// ── CPU ──────────────────────────────────────────────────────────────────────
wire [15:0] cpu_addr;
wire [7:0]  cpu_dout;
wire        cpu_rnw;
reg  [7:0]  cpu_din;

reg  firq_n, irq_n;
wire nHALT    = 1'b1;
wire nDMABREQ = 1'b1;

mc6809i u_cpu (
	.D        (cpu_din),
	.DOut     (cpu_dout),
	.ADDR     (cpu_addr),
	.RnW      (cpu_rnw),
	.E        (cpu_E),
	.Q        (cpu_Q),
	.BS       (),
	.BA       (),
	.nIRQ     (irq_n),
	.nFIRQ    (firq_n),
	.nNMI     (1'b1),
	.AVMA     (),
	.BUSY     (),
	.LIC      (),
	.nHALT    (nHALT),
	.nRESET   (board_reset_n & ~reset),
	.nDMABREQ (nDMABREQ),
	.RegData  ()
);

// ── Decodifica ───────────────────────────────────────────────────────────────
wire is_ram     = (cpu_addr <  16'h2000);
wire is_bsmtrst = (cpu_addr >= 16'h2000) && (cpu_addr <  16'h2002);
wire is_comms   = (cpu_addr >= 16'h2002) && (cpu_addr <  16'h2004);
wire is_status  = (cpu_addr >= 16'h2006) && (cpu_addr <  16'h2008);
wire is_bsmt0   = (cpu_addr == 16'h6000);
wire is_bsmt1   = (cpu_addr >= 16'hA000) && (cpu_addr <  16'hA100);
// (la ROM e' il default del mux di lettura: non serve un select dedicato)

// ── RAM 8 KB ─────────────────────────────────────────────────────────────────
(* ramstyle = "M10K", no_rw_check *) reg [7:0] ram [0:8191];
reg [7:0] ram_q;
// `~reset` obbligatorio ora che E gira anche durante il reset: mentre la CPU e'
// tenuta ferma, ADDR/RnW valgono quello che valgono e senza questo gate un
// e_rise potrebbe scrivere spazzatura in RAM. Gli altri blocchi hanno gia' il
// proprio `if (reset)`.
wire      ram_we = is_ram & ~cpu_rnw & e_rise & ~reset;
always @(posedge clk) begin
	if (ram_we) ram[cpu_addr[12:0]] <= cpu_dout;
	ram_q <= ram[cpu_addr[12:0]];
end

// ── ROM: il file u7.snd e' da 64 KB e la mappa parte dal suo offset 0x2000,
//    che coincide con l'indirizzo 0x2000 della CPU: indirizzo passante.
assign rom_addr = cpu_addr;

// ── Comando dal main ─────────────────────────────────────────────────────────
reg [7:0] comms;
reg       comms_pending;
reg       comms_ack;
always @(posedge clk) begin
	comms_ack <= 1'b0;
	if (reset) begin
		comms <= 8'd0; comms_pending <= 1'b0;
	end else begin
		if (latch_wr) begin
			comms         <= latch_data;
			comms_pending <= 1'b1;
		end
		// la CPU legge il comando: e' quello l'acknowledge verso il main
		if (is_comms & cpu_rnw & e_rise) begin
			comms_pending <= 1'b0;
			comms_ack     <= 1'b1;
		end
	end
end
assign latch_rd = comms_ack;

// ── Mux di lettura ───────────────────────────────────────────────────────────
always @(*) begin
	if      (is_ram)    cpu_din = ram_q;
	else if (is_comms)  cpu_din = comms;
	// 0x2006: MAME bsmt_status_r = m_bsmt->read_status() << 7 (decobsmt.cpp:25).
	// Prima tornava comms_pending in bit 0: il driver leggeva sempre 0 nel bit 7
	// e restava ad aspettare un BSMT che per lui non era mai pronto.
	else if (is_status) cpu_din = {bsmt_ready, 7'd0};
	else                cpu_din = rom_data;
end

// ── Scritture verso il BSMT ──────────────────────────────────────────────────
// 0x6000 latcha il byte alto; la scrittura vera avviene su 0xA000-0xA0FF, dove
// l'indice del registro e' l'offset INVERTITO (decobsmt.cpp:30 offset ^ 0xff).
reg [7:0] bsmt_hi;
always @(posedge clk) begin
	bsmt_wr <= 1'b0;
	if (reset) begin
		bsmt_hi <= 8'd0; bsmt_reg <= 8'd0; bsmt_data <= 16'd0;
	end else if (~cpu_rnw & e_rise) begin
		if (is_bsmt0) bsmt_hi <= cpu_dout;
		if (is_bsmt1) begin
			bsmt_reg  <= ~cpu_addr[7:0];          // offset ^ 0xFF
			bsmt_data <= {bsmt_hi, cpu_dout};
			bsmt_wr   <= 1'b1;
		end
	end
end

// reset del BSMT: fronte di DISCESA del bit 7 scritto a 0x2000
reg [7:0] bsmt_rst_reg;
always @(posedge clk) begin
	bsmt_reset <= 1'b0;
	if (reset) begin
		bsmt_rst_reg <= 8'd0;
	end else if (is_bsmtrst & ~cpu_rnw & e_rise) begin
		if (bsmt_rst_reg[7] & ~cpu_dout[7]) bsmt_reset <= 1'b1;
		bsmt_rst_reg <= cpu_dout;
	end
end

// ── Interrupt ────────────────────────────────────────────────────────────────
// IRQ = "BSMT pronto": scende quando la CPU scrive un registro, risale quando
// il chip segnala di aver finito (decobsmt.cpp:32 / bsmt_ready_callback).
always @(posedge clk) begin
	if (reset)            irq_n <= 1'b1;
	else if (bsmt_wr)     irq_n <= 1'b1;   // non pronto (attivo BASSO -> 1 = idle)
	else if (bsmt_ready)  irq_n <= 1'b0;   // pronto -> IRQ attivo
end

// FIRQ periodico a 489 Hz, in HOLD_LINE come MAME (decobsmt.cpp:145
// set_input_line(M6809_FIRQ_LINE, HOLD_LINE)): resta asserito finche' la CPU
// non preleva il vettore. Prima si rilasciava da solo dopo 63 clk: se in quel
// momento F era mascherato l'interrupt si perdeva, e ne arrivavano 14 su 102
// (misurato in simulazione sulla ROM vera).
localparam integer FIRQ_DIV = CLK_HZ / FIRQ_HZ;
reg [19:0] firq_cnt;
always @(posedge clk) begin
	if (reset) begin
		firq_cnt <= 20'd0; firq_n <= 1'b1;
	end else begin
		// vettore FIRQ prelevato (0xFFF6): la CPU ha preso l'interrupt
		if (~firq_n & e_rise & (cpu_addr == 16'hFFF6)) firq_n <= 1'b1;
		// il periodo ha priorita': se scade proprio adesso, si riasserisce
		if (firq_cnt >= FIRQ_DIV[19:0]-1) begin
			firq_cnt <= 20'd0;
			firq_n   <= 1'b0;
		end else begin
			firq_cnt <= firq_cnt + 20'd1;
		end
	end
end

endmodule
