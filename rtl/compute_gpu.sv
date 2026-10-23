`timescale 1ns/1ps
// Public wrapper for the single-SM GPU. Host indexes global 32-bit words.
module compute_gpu #(parameter ROM_FILE="firmware/render_simt.hex")(
    input wire clk,reset,start,
    output wire busy,done,
    output wire [3:0] error,
    output wire [31:0] cycles,
    input wire [31:0] host_word,
    output wire [31:0] host_rdata
);
    wire [31:0] fault_codes,instructions,divergences,barriers;
    simt_sm #(.ROM_FILE(ROM_FILE)) sm(.clk(clk),.reset(reset),.start(start),
        .busy(busy),.done(done),.error(error),.cycles(cycles),.fault_codes(fault_codes),
        .instructions(instructions),.divergences(divergences),.barriers(barriers),
        .host_word(host_word),.host_rdata(host_rdata));
endmodule
