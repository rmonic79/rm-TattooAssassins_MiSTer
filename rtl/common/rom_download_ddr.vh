// GENERATO da mkregions.py — non modificare a mano.
// Decode del download: stessa dichiarazione che genera la MRA.

wire dl_ok_ddr = ioctl_download && (ioctl_index == 16'd0);

wire dl_txl = dl_ok_ddr && ioctl_addr[26:16] >= 11'h011 && ioctl_addr[26:16] < 11'h012;
wire dl_txh = dl_ok_ddr && ioctl_addr[26:16] >= 11'h012 && ioctl_addr[26:16] < 11'h013;
wire dl_bg1_lo = dl_ok_ddr && ioctl_addr[26:16] >= 11'h013 && ioctl_addr[26:16] < 11'h023;
wire dl_bg1_mid = dl_ok_ddr && ioctl_addr[26:16] >= 11'h023 && ioctl_addr[26:16] < 11'h033;
wire dl_spr0_a = dl_ok_ddr && ioctl_addr[26:16] >= 11'h083 && ioctl_addr[26:16] < 11'h0C3;
wire dl_spr0_b = dl_ok_ddr && ioctl_addr[26:16] >= 11'h0C3 && ioctl_addr[26:16] < 11'h103;
wire dl_spr0_p4 = dl_ok_ddr && ioctl_addr[26:16] >= 11'h103 && ioctl_addr[26:16] < 11'h123;
wire dl_spr1_a = dl_ok_ddr && ioctl_addr[26:16] >= 11'h123 && ioctl_addr[26:16] < 11'h163;
wire dl_spr1_b = dl_ok_ddr && ioctl_addr[26:16] >= 11'h163 && ioctl_addr[26:16] < 11'h1A3;
wire dl_bsmt = dl_ok_ddr && ioctl_addr[26:16] >= 11'h1A3 && ioctl_addr[26:16] < 11'h1C3;
// --- DDR3: byte, passo e scostamento dichiarati ---
// Come per la SDRAM, il dato si porta QUI nella convenzione che il
// renderer legge (swab/brev), non a valle con una permutazione.
function [7:0] rev8d(input [7:0] b);
	rev8d = {b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7]};
endfunction
// rot5: le due meta' di una riga finiscono nella STESSA linea da
// 8 byte, cosi' la seconda lettura e' gia' in cache nell'arbitro.
// E' una rotazione dei 5 bit bassi dell'indice di gruppo, e vale
// solo se anche il renderer chiede {codice, riga, meta'}.
wire [19:0] g_txl = (ioctl_addr[20:0] - TXL_LO[20:0]) >> 1;
wire [19:0] g_txh = (ioctl_addr[20:0] - TXH_LO[20:0]) >> 1;
wire [20:0] g_bg1_lo = (ioctl_addr[21:0] - BG1_LO_LO[21:0]) >> 1;
wire [20:0] g_bg1_mid = (ioctl_addr[21:0] - BG1_MID_LO[21:0]) >> 1;
wire [22:0] g_spr0_a = (ioctl_addr[23:0] - SPR0_A_LO[23:0]) >> 1;
wire [22:0] gs_spr0_a = {g_spr0_a[22:5], g_spr0_a[3:0], g_spr0_a[4]};
wire [23:0] g_spr0_b = (ioctl_addr[24:0] - SPR0_B_LO[24:0]) >> 1;
wire [23:0] gs_spr0_b = {g_spr0_b[23:5], g_spr0_b[3:0], g_spr0_b[4]};
wire [24:0] off_spr0_p4 = ioctl_addr[24:0] - SPR0_P4_LO[24:0];
wire [23:0] g_spr1_a = (ioctl_addr[24:0] - SPR1_A_LO[24:0]) >> 1;
wire [23:0] gs_spr1_a = {g_spr1_a[23:5], g_spr1_a[3:0], g_spr1_a[4]};
wire [23:0] g_spr1_b = (ioctl_addr[24:0] - SPR1_B_LO[24:0]) >> 1;
wire [23:0] gs_spr1_b = {g_spr1_b[23:5], g_spr1_b[3:0], g_spr1_b[4]};
wire [24:0] off_bsmt = ioctl_addr[24:0] - BSMT_LO[24:0];

always @(posedge clk) if (ioctl_wr_rise) begin
	if (dl_txl | dl_txh | dl_bg1_lo | dl_bg1_mid) begin
		ddr_dl_waddr  <= dl_txl ? {11'h2B0, g_txl[14:0], 2'b00}
		               : dl_txh ? {11'h2B0, g_txh[14:0], 2'b10}
		               : dl_bg1_lo ? {7'h2B, g_bg1_lo[18:0], 2'b00}
		               : {7'h2B, g_bg1_mid[18:0], 2'b10};
		ddr_dl_wdata  <= {rev8d(ioctl_dout[7:0]), rev8d(ioctl_dout[15:8])};
		ddr_dl_we_req <= ~ddr_dl_we_req;
	end else if (dl_spr0_a | dl_spr0_b) begin
		ddr_dl_waddr  <= dl_spr0_a ? {5'h1, gs_spr0_a[20:0], 2'b00}
		               : {5'h1, gs_spr0_b[20:0], 2'b10};
		ddr_dl_wdata  <= {ioctl_dout[7:0], ioctl_dout[15:8]};
		ddr_dl_we_req <= ~ddr_dl_we_req;
	end else if (dl_spr0_p4) begin
		ddr_dl_waddr  <= {7'hC, off_spr0_p4[20:0]};
		ddr_dl_wdata  <= ioctl_dout;
		ddr_dl_we_req <= ~ddr_dl_we_req;
	end else if (dl_spr1_a | dl_spr1_b) begin
		ddr_dl_waddr  <= dl_spr1_a ? {5'h2, gs_spr1_a[20:0], 2'b00}
		               : {5'h2, gs_spr1_b[20:0], 2'b10};
		ddr_dl_wdata  <= {ioctl_dout[7:0], ioctl_dout[15:8]};
		ddr_dl_we_req <= ~ddr_dl_we_req;
	end else if (dl_bsmt) begin
		ddr_dl_waddr  <= {7'h2A, off_bsmt[20:0]};
		ddr_dl_wdata  <= ioctl_dout;
		ddr_dl_we_req <= ~ddr_dl_we_req;
	end
end
