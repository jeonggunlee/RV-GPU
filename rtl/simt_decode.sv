`timescale 1ns/1ps
// One decoder per SM, shared by all eight lanes. Kinds/ALU codes are documented
// in docs/architecture.md. No independent per-thread instruction fetch/decode.
module simt_decode(
    input wire [31:0] insn,
    output reg [3:0] kind, alu,
    output reg immediate,
    output reg [31:0] imm,
    output wire [4:0] rs1, rs2, rd,
    output wire [2:0] f3
);
    wire [6:0] op=insn[6:0], f7=insn[31:25];
    assign rs1=insn[19:15]; assign rs2=insn[24:20];
    assign rd=insn[11:7]; assign f3=insn[14:12];
    always @* begin
        kind=15; alu=0; immediate=0; imm={{20{insn[31]}},insn[31:20]};
        case(op)
            7'h37,7'h17: begin
                kind=0; alu=(op==7'h37)?10:11;
                immediate=1; imm={insn[31:12],12'b0};
            end
            7'h13,7'h33: begin
                kind=0; immediate=(op==7'h13);
                case(f3)
                    0: begin
                        alu=(op==7'h33 && f7==7'h20)?1:0;
                        if(op==7'h33 && f7!=0 && f7!=7'h20) kind=15;
                    end
                    1: begin alu=2; if(f7!=0) kind=15; end
                    2: alu=3;
                    3: alu=4;
                    4: alu=5;
                    5: begin alu=(f7==7'h20)?7:6; if(f7!=0 && f7!=7'h20) kind=15; end
                    6: alu=8;
                    7: alu=9;
                endcase
                if(op==7'h33 && f3!=0 && f3!=5 && f7!=0) kind=15;
            end
            7'h03: begin
                kind=1; immediate=1;
                if(f3!=0 && f3!=1 && f3!=2 && f3!=4 && f3!=5) kind=15;
            end
            7'h23: begin
                kind=2; immediate=1; imm={{20{insn[31]}},insn[31:25],insn[11:7]};
                if(f3>2) kind=15;
            end
            7'h63: begin
                kind=3; imm={{19{insn[31]}},insn[31],insn[7],insn[30:25],insn[11:8],1'b0};
                if(f3==2 || f3==3) kind=15;
            end
            7'h6f: begin
                kind=4; imm={{11{insn[31]}},insn[31],insn[19:12],insn[20],insn[30:21],1'b0};
            end
            7'h67: begin kind=(f3==0)?5:15; immediate=1; end
            7'h0f: kind=(f3==0)?6:15;
            7'h73: begin
                if(insn==32'h00100073) kind=7;
                else if(insn==32'h00000073) kind=11;
                // Project read-only ID CSRs: CSRRS rd, csr, x0 (csrr).
                // Reject writes, other CSR forms and unimplemented addresses.
                // This subset does not claim full Zicsr support.
                else if(f3==2 && rs1==0 && insn[31:22]==10'b1100110000)
                    kind=12; // 0xCC0..0xCC3
            end
            7'h0b: begin
                if(f3==0 && rs1==0 && rd==0) kind=8; // SSY signed I-immediate, relative to PC
                else if(insn==32'h0000100b) kind=9;  // JOIN
                else if(insn==32'h0000200b) kind=10; // BAR, all 32 threads
            end
        endcase
    end
endmodule
