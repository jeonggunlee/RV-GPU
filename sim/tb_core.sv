`timescale 1ns/1ps
module tb_core;
    reg clk=0,reset=1;
    reg [31:0] instr=32'h13,rdata=0;
    reg mf=0,imf=0;
    wire [31:0] pc,addr,wdata;
    wire valid,we,halted;
    wire [3:0] strb,cause;
    rv32i_core dut(.clk(clk),.reset(reset),.pc(pc),.instr(instr),.imem_fault(imf),
      .mem_valid(valid),.mem_write(we),.mem_addr(addr),.mem_wdata(wdata),
      .mem_wstrb(strb),.mem_rdata(rdata),.mem_fault(mf),.halted(halted),.trap_cause(cause));
    always #5 clk=~clk;
    integer fd,n,count=0;
    reg [31:0] vi,va,vb,vr,vm,vierr,erd,epc,et,ec,ea,es,ed;
    initial begin
        fd=$fopen("sim/vectors.txt","r");
        if(!fd) $fatal(1,"Missing vectors");
        while(!$feof(fd)) begin
            n=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h\n",
              vi,va,vb,vr,vm,vierr,erd,epc,et,ec,ea,es,ed);
            if(n!=13) $fatal(1,"Malformed vectors");
            reset=1;
            @(negedge clk);
            reset=0; dut.pc=32'h100; dut.regs[1]=va; dut.regs[2]=vb;
            instr=vi; rdata=vr; mf=vm; imf=vierr;
            #1;
            if(addr!==ea || strb!==es[3:0] || wdata!==ed || we!==(es!=0))
                $fatal(1,"Bus vector %0d ins=%h addr=%h/%h strb=%h/%h data=%h/%h",count,vi,addr,ea,strb,es,wdata,ed);
            @(negedge clk);
            if(pc!==epc || dut.regs[3]!==erd || halted!==et[0] || cause!==ec[3:0] || dut.regs[0]!==0)
                $fatal(1,"Vector %0d ins=%h PC=%h/%h rd=%h/%h trap=%h/%h cause=%h/%h",count,vi,pc,epc,dut.regs[3],erd,halted,et,cause,ec);
            if(halted) begin
                instr=32'h00100193;
                @(negedge clk);
                if(pc!==epc || dut.regs[3]!==erd || we) $fatal(1,"Halt did not hold");
            end
            count=count+1;
        end
        $display("PASS core: %0d directed/random architectural vectors",count);
        $finish;
    end
endmodule
