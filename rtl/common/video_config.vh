// GENERATO da mameconf.py — non modificare a mano.
// Configurazione video di tattass, letta da deco32.cpp.
// La catena del colore, per ogni layer di tilemap, e':
//     indice_palette = BASE_PALETTE + (colore_tile & COL_MASK) * 16
//                      + COL_BANK * 16 + banco_runtime + pen
// dove COL_BANK e COL_MASK sono qui sotto e BASE_PALETTE viene dal
// GFXDECODE del driver.

// tilegen[0]
localparam [3:0] TG0_PF1_COL_BANK       = 4'h0;
localparam [4:0] TG0_PF2_COL_BANK       = 5'h10;
localparam [3:0] TG0_PF1_COL_MASK       = 4'hF;
localparam [3:0] TG0_PF2_COL_MASK       = 4'hF;
localparam [3:0] TG0_PF12_8X8_BANK      = 4'h0;
localparam [3:0] TG0_PF12_16X16_BANK    = 4'h1;
localparam [15:0] TG0_PF1_SIZE_W         = 16'd64;   // DECO_64x32
localparam [15:0] TG0_PF1_SIZE_H         = 16'd32;
localparam [15:0] TG0_PF2_SIZE_W         = 16'd64;   // DECO_64x32
localparam [15:0] TG0_PF2_SIZE_H         = 16'd32;

// tilegen[1]
localparam [5:0] TG1_PF1_COL_BANK       = 6'h20;
localparam [5:0] TG1_PF2_COL_BANK       = 6'h30;
localparam [3:0] TG1_PF1_COL_MASK       = 4'hF;
localparam [3:0] TG1_PF2_COL_MASK       = 4'hF;
localparam [3:0] TG1_PF12_8X8_BANK      = 4'h0;
localparam [3:0] TG1_PF12_16X16_BANK    = 4'h2;
localparam [15:0] TG1_PF1_SIZE_W         = 16'd64;   // DECO_64x32
localparam [15:0] TG1_PF1_SIZE_H         = 16'd32;
localparam [15:0] TG1_PF2_SIZE_W         = 16'd64;   // DECO_64x32
localparam [15:0] TG1_PF2_SIZE_H         = 16'd32;

// reset del registro banco colore (0x164000): il valore che
// riproduce i banchi statici del driver (pf1 0x20, pf2 0x30).
localparam [7:0] TILEMAP_CBANK_RESET = 8'h1A;

// basi di palette dal GFXDECODE (entry nell'ordine del driver)
localparam [11:0] GFX0_PAL_BASE = 12'h800;   // tiles1 / charlayout
localparam [11:0] GFX1_PAL_BASE = 12'h000;   // tiles1 / tilelayout
localparam [11:0] GFX2_PAL_BASE = 12'h000;   // tiles2 / tilelayout

localparam [11:0] SPR0_PAL_BASE = 12'h000;   // sprites1
localparam [11:0] SPR1_PAL_BASE = 12'h000;   // sprites2
