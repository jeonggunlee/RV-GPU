`timescale 1ns/1ps
module tb_simt_control;
    reg clk=0,reset=1,start=0;
    reg [31:0] host_word=0;
    wire busy,done;
    wire [3:0] error;
    wire [31:0] cycles,fault_codes,instructions,divergences,barriers,host_rdata;
    simt_sm #(.ROM_FILE("firmware/selftest_simt.hex")) dut(.*);
    always #5 clk=~clk;
    integer i,t;
    reg [3:0] seen;
    reg partial_seen;
    reg check_schedule=1;
    always @(negedge clk) if(!reset && busy && dut.state==4) begin
        if(check_schedule && instructions<8 && dut.current!==instructions[1:0]) $fatal(1,"Round robin issue order");
        seen[dut.current]=1;
        if(dut.mask[dut.current]!=8'hff) partial_seen=1;
        if((dut.rf_we & ~dut.mask[dut.current])!=0) $fatal(1,"Inactive register write");
    end
    function [31:0] I(input integer imm,rs1,f3,rd,op);
        I=((imm&4095)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op;
    endfunction
    function [31:0] B(input integer imm,rs2,rs1,f3);
        B=(((imm>>12)&1)<<31)|(((imm>>5)&63)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(((imm>>1)&15)<<8)|(((imm>>11)&1)<<7)|7'h63;
    endfunction
    function [31:0] val(input integer tid);
        case(tid%4) 0:val=100;1:val=300;2:val=200;3:val=400;endcase
    endfunction
    task run;
        begin
            @(negedge clk);seen=0;partial_seen=0;start=1;
            @(negedge clk);start=0;wait(done);@(negedge clk);
        end
    endtask
    task check(input integer word_index,input [31:0] expected);
        begin
            host_word=word_index;@(negedge clk);
            if(host_rdata!==expected) $fatal(1,"word %0d: %h != %h",word_index,host_rdata,expected);
        end
    endtask
    task clear_program;
        begin for(i=0;i<1024;i=i+1) dut.imem[i]=32'h00100073;end
    endtask
    task expect_fault(input [3:0] bits,input [7:0] code);
        begin
            run();
            if(error!==bits) $fatal(1,"Error mask %b expected %b, codes=%h",error,bits,fault_codes);
            for(t=0;t<4;t=t+1) if(bits[t] && fault_codes[t*8+:8]!==code) $fatal(1,"Cause warp %0d got %0d expected %0d",t,fault_codes[t*8+:8],code);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);reset=0;
        run();
        if(error!==0 || seen!==4'hf || !partial_seen || barriers!=2 || divergences!=14)
            $fatal(1,"Selftest error=%b seen=%b partial=%b barriers=%d splits=%d",error,seen,partial_seen,barriers,divergences);
        for(t=0;t<32;t=t+1) begin
            check(t,val(t));check(32+t,val((t+1)%32));
            check(64+t,32'hffffff80);check(96+t,128);
            check(128+t,32'hffff80ff);check(160+t,32'h80ff);
            check(192+t,32'h1234aa01);check(224+t,0);check(4096+t,31-t);
            check(256+t,t==0);check(288+t,t!=0);
            check(320+t,t<16);check(352+t,t>=16);
            check(384+t,t>=16);check(416+t,t<16);
        end
        $display("PASS SIMT nested divergence, reconvergence, inactive memory masking, cross-warp shared memory, repeated barriers, byte/half/word loads/stores, x0");

        check_schedule=0;
        clear_program();dut.imem[0]=32'hffffffff;expect_fault(15,2);
        clear_program();dut.imem[0]=32'h00000073;expect_fault(15,11);
        clear_program();dut.imem[0]=I(1,10,7,5,7'h13);dut.imem[1]=B(8,0,5,1);expect_fault(15,16);
        clear_program();for(i=0;i<9;i=i+1) dut.imem[i]=I(128-i*4,0,0,0,7'h0b);expect_fault(15,17);
        clear_program();dut.imem[0]=32'h0000100b;expect_fault(15,18);
        clear_program();dut.imem[0]=I(2,10,1,5,7'h13);dut.imem[1]=I(0,5,0,0,7'h67);expect_fault(15,19);
        // Divergent region must not exit or wait at a block barrier.
        clear_program();dut.imem[0]=I(1,10,7,5,7'h13);dut.imem[1]=I(20,0,0,0,7'h0b);
        dut.imem[2]=B(8,0,5,1);dut.imem[3]=32'h00c0006f;dut.imem[4]=32'h0000200b;
        dut.imem[5]=32'h0040006f;dut.imem[6]=32'h0000100b;expect_fault(15,21);
        dut.imem[4]=32'h00100073;expect_fault(15,20);
        // Validate entire vector store before committing lane zero.
        clear_program();dut.global_mem[0]=32'hdeadbeef;
        dut.imem[0]=I(13,10,1,5,7'h13);dut.imem[1]=I(90,0,0,6,7'h13);
        dut.imem[2]=32'h0062a023;expect_fault(15,7);check(0,32'hdeadbeef);
        clear_program();dut.imem[0]=I(1,0,0,5,7'h13);dut.imem[1]=I(0,5,2,0,7'h03);expect_fault(15,4);
        clear_program();dut.imem[0]=32'h000082b7;dut.imem[1]=I(0,5,2,0,7'h03);expect_fault(15,5);
        clear_program();dut.imem[0]=32'h0000106f;expect_fault(15,1);
        clear_program();dut.imem[0]=32'h0020006f;expect_fault(15,8'h80);
        // Warp zero exits; other warps cannot complete a full-block barrier.
        clear_program();dut.imem[0]=I(3,10,5,5,7'h13);dut.imem[1]=B(8,0,5,0);
        dut.imem[2]=32'h0000200b;expect_fault(14,22);
        // All warps arrive, but at different barrier instruction addresses.
        clear_program();dut.imem[0]=I(3,10,5,5,7'h13);dut.imem[1]=B(12,0,5,0);
        dut.imem[2]=32'h0000200b;dut.imem[3]=32'h00c0006f;
        dut.imem[4]=32'h0000200b;expect_fault(15,22);
        // Full-depth legal stack and uniform subroutine control flow.
        clear_program();
        for(i=0;i<8;i=i+1) dut.imem[i]=I(60-i*8,0,0,0,7'h0b);
        for(i=8;i<16;i=i+1) dut.imem[i]=32'h0000100b;
        run();if(error!==0) $fatal(1,"Legal eight-deep stack rejected");
        clear_program();dut.imem[0]=32'h008000ef;
        dut.imem[2]=I(123,0,0,5,7'h13);dut.imem[3]=32'h00502023;
        dut.imem[4]=32'h00102223;dut.imem[5]=I(1,1,0,1,7'h13);
        dut.imem[6]=I(0,1,0,0,7'h67);
        run();if(error!==0) $fatal(1,"JAL/JALR return failed");check(0,123);check(1,4);
        clear_program();dut.imem[0]=I(12,0,0,0,7'h0b);dut.imem[1]=32'h0000100b;expect_fault(15,18);
        // A same-address vector store has deterministic ascending lane order.
        clear_program();dut.imem[0]=32'h00a02023;run();
        if(error!==0) $fatal(1,"Colliding stores failed");check(0,31);
        // Reset while an LSU transaction is pending must abort it cleanly.
        clear_program();dut.imem[0]=32'h00a02023;
        @(negedge clk);start=1;@(negedge clk);start=0;
        wait(dut.state==5);@(negedge clk);reset=1;
        @(negedge clk);
        if(busy!==0 || done!==0 || error!==0) $fatal(1,"Reset did not abort work");
        reset=0;
        // Restart reinitializes registers/masks/stacks/status after every failure.
        clear_program();run();if(error!==0 || fault_codes!==0) $fatal(1,"Fault recovery");
        $display("PASS SIMT fault handling: invalid ISA, split stack, indirect branches, partial exit/barrier, memory precision, fetch, barrier deadlock and restart");
        $finish;
    end
    initial begin #10000000;$fatal(1,"SIMT test timeout");end
endmodule
