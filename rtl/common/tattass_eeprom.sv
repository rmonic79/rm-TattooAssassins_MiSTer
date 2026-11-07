// SPDX-License-Identifier: GPL-3.0-or-later
//
// EEPROM di Tattoo Assassins — 1024 byte, protocollo a comandi.
//
// NON e' la 93C46 di Night Slashers: stessa scheda, stesse tre linee
// (CS/CLK/DI sul byte basso di 0x150000), ma dialogo completamente diverso.
// Qui si scrivono 24 bit di comando+indirizzo e poi si legge (o si scrive) a
// raffica, un bit per colpo di clock, senza tornare ai confini di byte:
//
//   lettura : 110aa000  00000000  aaaaaaaa   poi un bit per clock
//   scrittura: 000aa000  00000000  aaaaaaaa  poi 32 bit, gli ultimi 8 sono il dato
//
// Il bit letto esce da `dout` e va nella porta B della protezione DECO104.
// Fedele a tattass_control_w di deco32.cpp: se il gioco non riceve i bit che
// si aspetta resta in attesa e non arriva mai a disegnare.
//
// ── INFERENZA DELLA MEMORIA — non toccare a cuor leggero ────────────────────
// `mem` e' 1024x8 e DEVE finire in un blocco M10K. Perche' Quartus la inferisca
// serve UNA sola porta di scrittura e UNA sola lettura SINCRONA. La versione
// precedente ne aveva DUE di scrittura (caricamento + scrittura seriale) e DUE
// letture ASINCRONE (`mem[rd_addr][rd_bit]` e `mem[addr_nxt][7]`): non inferiva,
// e Quartus la costruiva in logica = 8192 flip-flop piu' due mux da 1024 a 1.
// Effetto: ALM alle stelle e Analysis & Synthesis che non finisce piu'.
// Qui gli indirizzi sono multiplexati PRIMA della memoria e la lettura e'
// registrata: il dato esce un colpo di clock dopo, invisibile al gioco perche'
// le transizioni del protocollo le pilota l'ARM scrivendo a 0x150000 e distano
// centinaia di cicli l'una dall'altra, e il bit lo rilegge con un accesso
// separato alla porta B della protezione.

module tattass_eeprom (
	input             clk,
	input             reset,

	// byte basso scritto a 0x150000: bit6 = CS, bit5 = CLK, bit4 = DI
	input             wr,          // strobe di scrittura (un colpo)
	input      [7:0]  din,

	// caricamento del contenuto iniziale durante il download
	input             ld_wr,
	input      [9:0]  ld_addr,
	input      [7:0]  ld_data,

	output reg        dout         // bit corrente verso la porta B
);

reg [23:0] buffer;
reg [5:0]  buf_ptr;
reg [1:0]  pending;        // 0 = comando, 1 = lettura, 2 = scrittura
reg [12:0] read_bit_count;
reg [9:0]  byte_addr;
reg        last_clock;

wire cs  = din[6];
wire clk_in = din[5];
wire di  = din[4];

// il buffer dopo un altro bit, usato sia per il comando sia per il dato
wire [23:0] buffer_nxt = {buffer[22:0], di};
wire [9:0]  addr_nxt   = {buffer_nxt[20:19], buffer_nxt[7:0]};

// fronte di salita del clock seriale, con CS alto
wire sk_rise = wr & cs & ~last_clock & clk_in;

// ── Memoria: UNA porta di scrittura, UNA lettura sincrona ───────────────────
// Scrittura seriale: al 32-esimo bit gli ultimi 8 sono il dato.
wire       ser_we = sk_rise & (pending == 2'd2) & (buf_ptr == 6'd31);
wire       mem_we = ld_wr | ser_we;
wire [9:0] mem_wa = ld_wr ? ld_addr   : byte_addr;
wire [7:0] mem_wd = ld_wr ? ld_data   : buffer_nxt[7:0];

reg [9:0] mem_ra;          // indirizzo di lettura, REGISTRATO
reg [7:0] mem_q;           // dato letto, disponibile il ciclo dopo
reg [2:0] dout_bit;        // quale bit di mem_q va in uscita

(* ramstyle = "M10K", no_rw_check *) reg [7:0] mem [0:1023];
always @(posedge clk) begin
	if (mem_we) mem[mem_wa] <= mem_wd;
	mem_q <= mem[mem_ra];
end

// `dout` si AGGIORNA SOLO sugli eventi del protocollo, non a ogni clock.
// Rivalutandolo di continuo (`dout <= mem_q[dout_bit]` incondizionato) si
// cambiava il bit anche senza nessun fronte di clock seriale — per esempio
// appena caduto il reset (dava mem[0][7] invece di 0) oppure quando una
// scrittura tocca l'indirizzo che sta in mem_ra. MAME e la versione
// precedente il bit lo TENGONO fra un fronte e l'altro. Qui si tiene uguale,
// solo differito di un ciclo perche' mem_q arriva dopo mem_ra: chi legge il
// comando ne arma l'aggiornamento con dout_pend.
reg dout_pend;

always @(posedge clk) begin
	// aggiornamento differito: mem_q e' valido il ciclo DOPO mem_ra
	dout_pend <= 1'b0;
	if (dout_pend) dout <= mem_q[dout_bit];

	if (reset) begin
		dout      <= 1'b0;
		dout_pend <= 1'b0;
		buffer         <= 24'd0;
		buf_ptr        <= 6'd0;
		pending        <= 2'd0;
		read_bit_count <= 13'd0;
		byte_addr      <= 10'd0;
		last_clock     <= 1'b0;
		mem_ra         <= 10'd0;
		dout_bit       <= 3'd7;
	end else if (wr) begin
		// CS basso: tutto azzerato, comando compreso
		if (!cs) begin
			buf_ptr        <= 6'd0;
			pending        <= 2'd0;
			read_bit_count <= 13'd0;
		end

		if (!last_clock && clk_in && cs) begin
			if (pending == 2'd1) begin
				// lettura in corso: un bit per colpo, senza allinearsi ai byte.
				// L'indirizzo del byte e l'indice del bit sono quelli del bit
				// CORRENTE; mem_q li segue un ciclo dopo, e il gioco rilegge
				// molto piu' tardi.
				mem_ra         <= byte_addr + read_bit_count[12:3];
				dout_bit       <= 3'd7 - read_bit_count[2:0];
				read_bit_count <= read_bit_count + 13'd1;
				dout_pend      <= 1'b1;   // aggiorna dout il ciclo dopo
			end else if (pending == 2'd2) begin
				// scrittura in corso: 32 bit, gli ultimi 8 finiscono in memoria
				// (la write vera la esegue il blocco della memoria via ser_we)
				buffer  <= buffer_nxt;
				buf_ptr <= buf_ptr + 6'd1;
			end else begin
				buffer  <= buffer_nxt;
				buf_ptr <= (buf_ptr >= 6'd32) ? 6'd1 : buf_ptr + 6'd1;
				if (buf_ptr == 6'd23) begin
					byte_addr <= addr_nxt;
					if (buffer_nxt[23:22] == 2'b11) begin
						// comando di lettura: si punta subito al primo byte
						mem_ra         <= addr_nxt;
						dout_bit       <= 3'd7;
						read_bit_count <= 13'd1;
						pending        <= 2'd1;
						dout_pend      <= 1'b1;   // primo bit, un ciclo dopo
					end else if (buffer_nxt[23:22] == 2'b00) begin
						pending <= 2'd2;
					end
				end
			end
		end else if (!cs) begin
			buf_ptr <= 6'd0;
		end

		last_clock <= clk_in;
	end
end

endmodule
