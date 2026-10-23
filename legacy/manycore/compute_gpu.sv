`timescale 1ns/1ps
// Four independent RV32I workers: SPMD execution, private scratchpad banks.
// Host reads are combinational; only consume them after done. Memories survive
// reset/relaunch. Instruction image is fixed at FPGA configuration time.
module compute_gpu #(
    parameter LANES=4, IMEM_WORDS=1024, DMEM_WORDS=2048,
    parameter ROM_FILE="firmware/render.hex"
)(
    input wire clk, reset, start,
    output reg busy, done,
    output reg [LANES-1:0] error,
    output reg [31:0] cycles,
    input wire [31:0] host_lane, host_word,
    output wire [31:0] host_rdata
);
    wire [LANES-1:0] halted;
    wire [3:0] cause [0:LANES-1];
    wire [31:0] bank_read [0:LANES-1];
    assign host_rdata=(host_lane<LANES && host_word<DMEM_WORDS)?bank_read[host_lane]:32'b0;
    integer k;
    always @(posedge clk) begin
        if(reset) begin busy<=0; done<=0; error<=0; cycles<=0; end
        else if(start && !busy) begin busy<=1; done<=0; error<=0; cycles<=0; end
        else if(busy) begin
            cycles<=cycles+1;
            if(&halted) begin
                busy<=0; done<=1;
                for(k=0;k<LANES;k=k+1) error[k]<=(cause[k]!=3);
            end
        end
    end
    genvar g;
    generate for(g=0;g<LANES;g=g+1) begin: lane
        (* rom_style="distributed" *) reg [31:0] imem[0:IMEM_WORDS-1];
        (* ram_style="distributed" *) reg [31:0] dmem[0:DMEM_WORDS-1];
        wire [31:0] pc, addr, wdata, rdata, instr;
        wire valid, we;
        wire [3:0] strb;
        integer n, b;
        initial begin
            for(n=0;n<IMEM_WORDS;n=n+1) imem[n]=32'h00100073;
            for(n=0;n<DMEM_WORDS;n=n+1) dmem[n]=0;
            $readmemh(ROM_FILE,imem);
        end
        assign instr=(pc<IMEM_WORDS*4)?imem[pc[$clog2(IMEM_WORDS)+1:2]]:32'h0;
        assign rdata=(addr<DMEM_WORDS*4)?dmem[addr[$clog2(DMEM_WORDS)+1:2]]:32'b0;
        assign bank_read[g]=(host_word<DMEM_WORDS)?dmem[host_word[$clog2(DMEM_WORDS)-1:0]]:32'b0;
        rv32i_core #(.THREAD_ID(g),.NUM_THREADS(LANES),
            .STACK_TOP(DMEM_WORDS*4),.OUTPUT_BASE(1024)) core(
            .clk(clk),.reset(reset || !busy),.pc(pc),.instr(instr),
            .imem_fault(pc>=IMEM_WORDS*4),.mem_valid(valid),.mem_write(we),
            .mem_addr(addr),.mem_wdata(wdata),.mem_wstrb(strb),.mem_rdata(rdata),
            .mem_fault(addr>=DMEM_WORDS*4),.halted(halted[g]),.trap_cause(cause[g]));
        always @(posedge clk)
            if(!reset && busy && valid && we && addr<DMEM_WORDS*4)
                for(b=0;b<4;b=b+1)
                    if(strb[b]) dmem[addr[$clog2(DMEM_WORDS)+1:2]][b*8+:8]<=wdata[b*8+:8];
    end endgenerate
endmodule
