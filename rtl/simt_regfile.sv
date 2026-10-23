`timescale 1ns/1ps
// One physical lane: 4 warp contexts x 32 architectural registers x 32 bits.
// Launch initialization uses the write port for 128 cycles; no huge reset mux.
module simt_regfile(
    input wire clk, input wire [1:0] warp,
    input wire [4:0] rs1,rs2,
    output wire [31:0] a,b,
    input wire we, input wire [6:0] waddr, input wire [31:0] wdata
);
    (* ram_style="distributed" *) reg [31:0] regs[0:127];
    assign a=(rs1==0)?32'b0:regs[{warp,rs1}];
    assign b=(rs2==0)?32'b0:regs[{warp,rs2}];
    always @(posedge clk) if(we) regs[waddr]<=wdata;
endmodule
