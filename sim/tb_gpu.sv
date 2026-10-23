`timescale 1ns/1ps
module tb_gpu;
    reg clk=0,reset=1,start=0;
    reg [31:0] host_word=0;
    wire busy,done;
    wire [3:0] error;
    wire [31:0] cycles,host_rdata;
    compute_gpu dut(.*);
    always #5 clk=~clk;
    integer p,fd,run;
    task read_word(input integer address);
        begin @(negedge clk);host_word=address;@(negedge clk);end
    endtask
    initial begin
        repeat(3) @(negedge clk);reset=0;
        for(run=0;run<2;run=run+1) begin
            @(negedge clk);start=1;@(negedge clk);start=0;
            repeat(200) @(negedge clk);
            start=1;@(negedge clk);start=0; // ignored while busy
            wait(done);@(negedge clk);
            if(error!==0 || busy) $fatal(1,"SIMT render failure %b codes=%h",error,dut.fault_codes);
            if(dut.divergences==0 || dut.barriers!=1) $fatal(1,"Render did not exercise divergence/barrier");
            fd=$fopen("build/frame.hex","w");
            for(p=0;p<4096;p=p+1) begin
                read_word(p);
                if(^host_rdata===1'bx) $fatal(1,"Unknown pixel");
                $fdisplay(fd,"%08x",host_rdata);
            end
            $fclose(fd);
            for(p=0;p<32;p=p+1) begin
                read_word(4096+p);
                if(host_rdata!==31-p) $fatal(1,"Cross-warp exchange tid %0d",p);
            end
            read_word(8192);if(host_rdata!==0) $fatal(1,"Host bounds");
            $display("PASS SIMT render %0d: 32 threads, cycles=%0d warp_instructions=%0d splits=%0d barriers=%0d",run,cycles,dut.instructions,dut.divergences,dut.barriers);
        end
        $finish;
    end
    initial begin #10000000; $fatal(1,"GPU timeout");end
endmodule
