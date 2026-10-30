`timescale 1ns/1ps
module tb_simt_csr;
    reg clk=0,reset=1,start=0;
    reg [31:0] host_word=0;
    wire busy,done;
    wire [3:0] error;
    wire [31:0] fault_codes,cycles,instructions,divergences,barriers,host_rdata;
    simt_sm dut(.*);
    always #5 clk=~clk;

    // Independently check every CSR address, funct3, and source-field form.
    reg [31:0] insn;
    wire [3:0] kind,alu;
    wire immediate;
    wire [31:0] imm;
    wire [4:0] rs1,rs2,rd;
    wire [2:0] f3;
    simt_decode dec(.*);
    integer c,f,src,i,t,mode,checks=0;
    reg legal;
    function [31:0] I(input integer imm,rs1,f3,rd,op);
        I=((imm&4095)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op;
    endfunction
    function [31:0] B(input integer imm,rs2,rs1,f3);
        B=(((imm>>12)&1)<<31)|(((imm>>5)&63)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(((imm>>1)&15)<<8)|(((imm>>11)&1)<<7)|7'h63;
    endfunction
    function [31:0] value(input integer csr_index,tid);
        case(csr_index)
            0:value=tid; 1:value=tid/8; 2:value=tid%8; 3:value=32;
        endcase
    endfunction
    task clear_program;
        begin for(i=0;i<1024;i=i+1) dut.imem[i]=32'h00100073; end
    endtask
    task run;
        begin
            @(negedge clk);start=1;
            @(negedge clk);start=0;
            wait(done);@(negedge clk);
        end
    endtask
    task check(input integer word_index,input [31:0] expected);
        begin
            host_word=word_index;@(negedge clk);
            if(host_rdata!==expected) $fatal(1,"CSR word %0d got %h expected %h",word_index,host_rdata,expected);
            checks=checks+1;
        end
    endtask
    task bad_csr(input [31:0] instruction);
        begin
            clear_program();
            dut.imem[0]=I(123,0,0,5,7'h13);
            dut.imem[1]=instruction;
            dut.imem[2]=32'h00502023; // must never commit this store
            dut.global_mem[0]=32'hdeadbeef;
            run();
            if(error!==15 || fault_codes!==32'h02020202) $fatal(1,"CSR fault missing: %h, codes=%h",instruction,fault_codes);
            for(t=0;t<4;t=t+1) if(dut.pc[t]!==4) $fatal(1,"CSR fault advanced PC");
            check(0,32'hdeadbeef);
        end
    endtask
    always @(negedge clk) if(!reset && busy && dut.state==4) begin
        if((dut.rf_we & ~dut.mask[dut.current])!=0) $fatal(1,"Inactive CSR write");
        if(dut.fault!=0 && dut.rf_we!=0) $fatal(1,"Faulting CSR wrote registers");
        if(dut.rd==0 && dut.rf_we!=0) $fatal(1,"CSR wrote x0");
    end
    initial begin
        // rd=5 avoids ECALL/EBREAK aliasing when checking SYSTEM funct3=0.
        for(c=0;c<4096;c=c+1) for(f=0;f<8;f=f+1) for(src=0;src<32;src=src+1) begin
            insn=I(c,src,f,5,7'h73);#1;
            legal=(c>=12'hcc0 && c<=12'hcc3 && f==2 && src==0);
            if(legal && kind!==12) $fatal(1,"Legal CSR rejected %h",insn);
            if(!legal && kind!==15) $fatal(1,"Illegal CSR accepted %h",insn);
        end
        repeat(3) @(negedge clk);reset=0;
        // Execute every ID with full mask and both complementary divergent masks.
        for(c=0;c<4;c=c+1) for(mode=0;mode<3;mode=mode+1) begin
            clear_program();
            dut.imem[0]=I(-1,0,0,5,7'h13);       // destination sentinel
            dut.imem[1]=I(2,10,1,6,7'h13);       // result byte offset = ABI tid*4
            dut.imem[2]=I(1,10,7,7,7'h13);       // parity
            if(mode==0) begin
                dut.imem[3]=I(12'hcc0+c,0,2,5,7'h73);
                dut.imem[4]=32'h00532023;         // sw t0,0(t1)
                dut.imem[5]=I(12'hcc0+c,0,2,0,7'h73); // legal read to x0
                dut.imem[6]=32'h00100073;
            end else begin
                dut.imem[3]=I(16,0,0,0,7'h0b);   // SSY PC=28
                dut.imem[4]=B(8,0,7,(mode==1)?1:0);
                dut.imem[5]=32'h0080006f;         // skipped lanes jump to JOIN
                dut.imem[6]=I(12'hcc0+c,0,2,5,7'h73);
                dut.imem[7]=32'h0000100b;
                dut.imem[8]=32'h00532023;
            end
            run();
            if(error!==0) $fatal(1,"CSR execution fault %h",fault_codes);
            for(t=0;t<32;t=t+1)
                check(t,(mode==0 || (mode==1 && t%2==1) || (mode==2 && t%2==0))?value(c,t):32'hffffffff);
        end
        // x0 reads still return zero after csrr x0; ABI register overwrite does not change IDs.
        clear_program();
        dut.imem[0]=I(-1,0,0,10,7'h13);
        dut.imem[1]=I(12'hcc0,0,2,10,7'h73);
        dut.imem[2]=I(2,10,1,6,7'h13);
        dut.imem[3]=I(12'hcc3,0,2,0,7'h73);
        dut.imem[4]=32'h00032023;
        run();if(error!==0) $fatal(1,"CSR restart/x0 failure");
        for(t=0;t<32;t=t+1) check(t,0);
        // Unsupported addresses, even rd=x0, and all write/unsupported forms.
        bad_csr(I(12'hcc4,0,2,5,7'h73));
        bad_csr(I(12'hc00,0,2,0,7'h73));
        for(c=0;c<4;c=c+1) begin
            for(f=1;f<8;f=f+1) if(f!=2) bad_csr(I(12'hcc0+c,0,f,5,7'h73));
            bad_csr(I(12'hcc0+c,1,2,5,7'h73)); // x1 contains zero, but this is a write attempt
            bad_csr(I(12'hcc0+c,1,2,0,7'h73)); // rd=x0 does not suppress invalid writes
        end
        clear_program();run();if(error!==0 || fault_codes!==0) $fatal(1,"CSR fault recovery");
        $display("PASS SIMT CSR: exhaustive SYSTEM decode (1048576 encodings), 32-thread IDs, both partial masks, x0, precise faults, restart; %0d memory checks",checks);
        $finish;
    end
    initial begin #10000000;$fatal(1,"CSR test timeout");end
endmodule
