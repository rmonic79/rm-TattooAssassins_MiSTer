//////////////////////////////////////////////////////////////////
//                                                              //
//  Multiplication Module for Amber 2 Core                      //
//                                                              //
//  This file is part of the Amber project                      //
//  http://www.opencores.org/project,amber                      //
//                                                              //
//  Description                                                 //
//  64-bit Booth signed or unsigned multiply and                //
//  multiply-accumulate supported. It takes about 38 clock      //
//  cycles to complete an operation.                            //
//                                                              //
//  Author(s):                                                  //
//      - Conor Santifort, csantifort.amber@gmail.com           //
//                                                              //
//////////////////////////////////////////////////////////////////
//                                                              //
// Copyright (C) 2010 Authors and OPENCORES.ORG                 //
//                                                              //
// This source file may be used and distributed without         //
// restriction provided that this copyright statement is not    //
// removed from the file and that any derivative work contains  //
// the original copyright notice and the associated disclaimer. //
//                                                              //
// This source file is free software; you can redistribute it   //
// and/or modify it under the terms of the GNU Lesser General   //
// Public License as published by the Free Software Foundation; //
// either version 2.1 of the License, or (at your option) any   //
// later version.                                               //
//                                                              //
// This source is distributed in the hope that it will be       //
// useful, but WITHOUT ANY WARRANTY; without even the implied   //
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR      //
// PURPOSE.  See the GNU Lesser General Public License for more //
// details.                                                     //
//                                                              //
// You should have received a copy of the GNU Lesser General    //
// Public License along with this source; if not, download it   //
// from http://www.opencores.org/lgpl.shtml                     //
//                                                              //
//////////////////////////////////////////////////////////////////



// bit 0 go, bit 1 accumulate
// Command:
//  4'b01 :  MUL   - 32 bit multiplication
//  4'b11 :  MLA   - 32 bit multiply and accumulate
//
//  34-bit Booth adder
//  The adder needs to be 34 bit to deal with signed and unsigned 32-bit
//  multiplication inputs. This adds 1 extra bit. Then to deal with the
//  case of two max negative numbers another bit is required.
//

// ----------------------------------------------------------------------------
// rm (Tattoo Assassins, 2026-10-24): MUL e MLA in 2 CICLI come MAME
// (arm.cpp HandleMul: m_icount -= S_CYCLE + I_CYCLE).
// Il Booth originale (sotto, disattivato) avanzava di UN bit per ciclo CPU:
// 34 cicli per MUL e 35 per MLA. La routine del dim della palette (0x1F368,
// script delle fatality) fa 6 moltiplicazioni x 2048 voci per passo: con il
// Booth ogni passo durava ~4 frame invece di <1 -> la pausa nelle fatality.
// Ora la decodifica fa la MUL in EXECUTE + MULT_STORE: gli operandi (Rm, Rs e,
// per MLA, Rn) si catturano al tick in cui lo stadio di esecuzione ha la MUL con
// la condizione vera, e il prodotto lo fanno i DSP in DUE clock di sistema.
// La scrittura del registro avviene al tick successivo, che arriva almeno 3
// clock dopo anche alla velocita' CPU massima dell'OSD (28,3 MHz su 96 MHz).
// Il risultato e' quello di MAME: i 32 bit bassi di Rm*Rs (+Rn); N e Z da li'.
// ----------------------------------------------------------------------------
module a23_multiply (
input                       i_clk,
input                       i_fetch_stall,

input       [31:0]          i_a_in,         // Rs
input       [31:0]          i_b_in,         // Rm
input       [31:0]          i_c_in,         // Rn (accumulo, solo MLA)
input       [1:0]           i_function,
input                       i_execute,

output      [31:0]          o_out,
output      [1:0]           o_flags,        // [1] = N, [0] = Z
output reg                  o_done = 'd0    // non piu' usato: la decodifica non aspetta
);

// Cattura degli operandi: solo nel tick della MUL (i_function[0] lo alza la
// decodifica in EXECUTE e lo rimette a zero in MULT_STORE).
reg  [31:0] mul_a = 32'd0;   // Rs
reg  [31:0] mul_b = 32'd0;   // Rm
reg  [31:0] mul_c = 32'd0;   // Rn se MLA, altrimenti 0
always @ ( posedge i_clk )
    if ( !i_fetch_stall && i_execute && i_function[0] )
        begin
        mul_a <= i_a_in;
        mul_b <= i_b_in;
        mul_c <= i_function[1] ? i_c_in : 32'd0;
        end

// Stadio 1: prodotti parziali. Servono solo i 32 bit bassi di a*b:
//   a*b mod 2^32 = (a * b[15:0]) mod 2^32 + ((a[15:0] * b[31:16]) mod 2^16) << 16
reg  [31:0] pp_lo = 32'd0;
reg  [15:0] pp_hi = 16'd0;
reg  [31:0] acc_d = 32'd0;
always @ ( posedge i_clk )
    begin
    pp_lo <= mul_a * mul_b[15:0];
    pp_hi <= mul_a[15:0] * mul_b[31:16];
    acc_d <= mul_c;
    end

// Stadio 2: somma dei parziali e dell'accumulo
reg  [31:0] mul_res = 32'd0;
always @ ( posedge i_clk )
    mul_res <= pp_lo + { pp_hi, 16'd0 } + acc_d;

assign o_out   = mul_res;
assign o_flags = { mul_res[31], mul_res == 32'd0 };

endmodule


// ============================================================================
// Booth originale di Amber, DISATTIVATO (non compilato): resta come riferimento.
// ============================================================================
`ifdef A23_MULTIPLY_BOOTH_ORIGINALE
module a23_multiply_booth (
input                       i_clk,
input                       i_fetch_stall,

input       [31:0]          i_a_in,         // Rds
input       [31:0]          i_b_in,         // Rm
input       [1:0]           i_function,
input                       i_execute,

output      [31:0]          o_out,
output      [1:0]           o_flags,        // [1] = N, [0] = Z
output reg                  o_done = 'd0    // goes high 2 cycles before completion
);


wire        enable;
wire        accumulate;
wire [33:0] multiplier;
wire [33:0] multiplier_bar;
wire [33:0] sum;
wire [33:0] sum34_b;

reg  [5:0]  count = 'd0;
reg  [5:0]  count_nxt;
reg  [67:0] product = 'd0;
reg  [67:0] product_nxt;
reg  [1:0]  flags_nxt;
wire [32:0] sum_acc1;           // the MSB is the carry out for the upper 32 bit addition


assign enable         = i_function[0];
assign accumulate     = i_function[1];
 
assign multiplier     =  { 2'd0, i_a_in} ;
assign multiplier_bar = ~{ 2'd0, i_a_in} + 34'd1 ;

assign sum34_b        =  product[1:0] == 2'b01 ? multiplier     :
                         product[1:0] == 2'b10 ? multiplier_bar :
                                                 34'd0          ;


// Use DSP modules from Xilinx Spartan6 FPGA devices
`ifdef XILINX_FPGA
    // -----------------------------------
    // 34-bit adder - booth multiplication
    // -----------------------------------
    `ifdef XILINX_SPARTAN6_FPGA
        xs6_addsub_n #(.WIDTH(34)) 
    `endif
    `ifdef XILINX_VIRTEX6_FPGA
        xv6_addsub_n #(.WIDTH(34))  
    `endif
        
        u_xx_addsub_34_sum (
        .i_a    ( product[67:34]        ),
        .i_b    ( sum34_b               ),
        .i_cin  ( 1'd0                  ),
        .i_sub  ( 1'd0                  ),
        .o_sum  ( sum                   ),
        .o_co   (                       )
    );

    // ------------------------------------
    // 33-bit adder - accumulate operations
    // ------------------------------------
    `ifdef XILINX_SPARTAN6_FPGA
        xs6_addsub_n #(.WIDTH(33)) 
    `endif
    `ifdef XILINX_VIRTEX6_FPGA
        xv6_addsub_n #(.WIDTH(33)) 
    `endif
        u_xx_addsub_33_acc1 (
        .i_a    ( {1'd0, product[32:1]} ),
        .i_b    ( {1'd0, i_a_in}        ),
        .i_cin  ( 1'd0                  ),
        .i_sub  ( 1'd0                  ),
        .o_sum  ( sum_acc1              ),
        .o_co   (                       )
    );

`else
 
    // -----------------------------------
    // 34-bit adder - booth multiplication
    // -----------------------------------
    assign sum =  product[67:34] + sum34_b;
     
    // ------------------------------------
    // 33-bit adder - accumulate operations
    // ------------------------------------
    assign sum_acc1 = {1'd0, product[32:1]} + {1'd0, i_a_in};
     
`endif


always @*
    begin
    // Defaults
    count_nxt           = count;
    product_nxt         = product;
    
    // update Negative and Zero flags
    // Use registered value of product so this adds an extra cycle
    // but this avoids having the 64-bit zero comparator on the
    // main adder path
    flags_nxt   = { product[32], product[32:1] == 32'd0 }; 
    

    if ( count == 6'd0 )
        product_nxt = {33'd0, 1'd0, i_b_in, 1'd0 } ;
    else if ( count <= 6'd33 )
        product_nxt = { sum[33], sum, product[33:1]} ;
    else if ( count == 6'd34 && accumulate )
        begin
        // Note that bit 0 is not part of the product. It is used during the booth
        // multiplication algorithm
        product_nxt         = { product[64:33], sum_acc1[31:0], 1'd0}; // Accumulate
        end
        
    // Multiplication state counter
    if (count == 6'd0)  // start
        count_nxt   = enable ? 6'd1 : 6'd0;
    else if ((count == 6'd34 && !accumulate) ||  // MUL
             (count == 6'd35 &&  accumulate)  )  // MLA
        count_nxt   = 6'd0;
    else
        count_nxt   = count + 1'd1;
    end


always @ ( posedge i_clk )
    if ( !i_fetch_stall )
        begin
        count           <= i_execute ? count_nxt          : count;           
        product         <= i_execute ? product_nxt        : product;        
        o_done          <= i_execute ? count == 6'd31     : o_done;          
        end

// Outputs
assign o_out   = product[32:1];
assign o_flags = flags_nxt;

endmodule
`endif // A23_MULTIPLY_BOOTH_ORIGINALE


