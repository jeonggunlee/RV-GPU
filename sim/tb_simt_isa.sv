`timescale 1ns/1ps
module tb_simt_isa;
    reg [31:0] insn,a,b,pc=32'h100;
    wire [3:0] kind,alu;
    wire immediate;
    wire [31:0] imm,y;
    wire [4:0] rs1,rs2,rd;
    wire [2:0] f3;
    simt_decode dec(.*);
    simt_alu unit(.op(alu),.a(a),.b(immediate?imm:b),.pc(pc),.y(y));
    integer fd,n,count=0;
    reg [31:0] vi,va,vb,vr,vm,vierr,erd,epc,et,ec,ea,es,ed;
    initial begin
        fd=$fopen("sim/vectors.txt","r");
        if(!fd) $fatal(1,"Missing vectors");
        while(!$feof(fd)) begin
            n=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h\n",vi,va,vb,vr,vm,vierr,erd,epc,et,ec,ea,es,ed);
            if(n!=13) $fatal(1,"Malformed vector");
            insn=vi; a=va; b=vb; #1;
            if((vi[6:0]==7'h13 || vi[6:0]==7'h33 || vi[6:0]==7'h37 || vi[6:0]==7'h17) && et==0 && rd!=0) begin
                if(kind!==0 || y!==erd) $fatal(1,"SIMT ALU insn=%h result=%h expected=%h",vi,y,erd);
                count=count+1;
            end
            if((vi[6:0]==7'h03 || vi[6:0]==7'h23) && et==0) begin
                if(y!==ea) $fatal(1,"SIMT address generation");
                count=count+1;
            end
            if(ec==2 && et==1 && vierr==0 && kind!=15) $fatal(1,"Illegal encoding accepted: %h",vi);
        end
        $display("PASS SIMT shared decoder/ALU: %0d arithmetic/address vectors",count);
        $finish;
    end
endmodule
