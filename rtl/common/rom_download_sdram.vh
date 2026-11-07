// GENERATO da mkregions.py — non modificare a mano.
// Decode del download: stessa dichiarazione che genera la MRA.

wire dl_ok = ioctl_download && (ioctl_index == 16'd0);

wire dl_main = dl_ok && ioctl_addr[26:16] >= 11'h000 && ioctl_addr[26:16] < 11'h010;
wire dl_bg1_lo = dl_ok && ioctl_addr[26:16] >= 11'h013 && ioctl_addr[26:16] < 11'h023;
wire dl_bg1_mid = dl_ok && ioctl_addr[26:16] >= 11'h023 && ioctl_addr[26:16] < 11'h033;
wire dl_fg0 = dl_ok && ioctl_addr[26:16] >= 11'h043 && ioctl_addr[26:16] < 11'h063;
wire dl_fg1 = dl_ok && ioctl_addr[26:16] >= 11'h063 && ioctl_addr[26:16] < 11'h083;

// --- SDRAM: word a 16 bit, banco dichiarato ---
// Il dato si porta QUI nella convenzione che il renderer legge, cosi'
// a valle non serve permutare niente e il renderer resta agnostico:
//   swab: scambia i due byte della word
//   brev: rovescia i bit dentro ogni byte
function [7:0] rev8(input [7:0] b);
	rev8 = {b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7]};
endfunction
wire [15:0] dw_main = ioctl_dout;
wire [15:0] dw_bg1_lo = {rev8(ioctl_dout[7:0]), rev8(ioctl_dout[15:8])};
wire [15:0] dw_bg1_mid = {rev8(ioctl_dout[7:0]), rev8(ioctl_dout[15:8])};
wire [15:0] dw_fg0 = {rev8(ioctl_dout[7:0]), rev8(ioctl_dout[15:8])};
wire [15:0] dw_fg1 = {rev8(ioctl_dout[7:0]), rev8(ioctl_dout[15:8])};
always @(*) begin
	dl_accept = 1'b0; dl_target_ba = 2'd0; dl_word_addr = 22'd0;
	dl_data_in = ioctl_dout;
	if (dl_main) begin
		dl_accept    = 1'b1;
		dl_target_ba = 2'd2;
		dl_word_addr = 22'h0 + ((ioctl_addr - MAIN_LO) >> 1);
		dl_data_in   = dw_main;
	end else if (dl_bg1_lo) begin
		dl_accept    = 1'b1;
		dl_target_ba = 2'd3;
		dl_word_addr = 22'h0 + ((ioctl_addr - BG1_LO_LO) >> 1);
		dl_data_in   = dw_bg1_lo;
	end else if (dl_bg1_mid) begin
		dl_accept    = 1'b1;
		dl_target_ba = 2'd3;
		dl_word_addr = 22'h80000 + ((ioctl_addr - BG1_MID_LO) >> 1);
		dl_data_in   = dw_bg1_mid;
	end else if (dl_fg0) begin
		dl_accept    = 1'b1;
		dl_target_ba = 2'd0;
		dl_word_addr = 22'h0 + ((ioctl_addr - FG0_LO) >> 1);
		dl_data_in   = dw_fg0;
	end else if (dl_fg1) begin
		dl_accept    = 1'b1;
		dl_target_ba = 2'd1;
		dl_word_addr = 22'h0 + ((ioctl_addr - FG1_LO) >> 1);
		dl_data_in   = dw_fg1;
	end
end

