`timescale 1ns/1ps
// 1 SM / 4 resident warps / 8 physical lanes / 32 threads per block.
// Single issue, unpipelined: PICK -> FETCH -> EXEC. Blocking serialized LSU.
// Structured divergence uses SSY/JOIN and an eight-entry stack per warp.
module simt_sm #(parameter ROM_FILE="firmware/render_simt.hex")(
    input wire clk,reset,start,
    output reg busy,done,
    output reg [3:0] error,
    output reg [31:0] fault_codes,
    output reg [31:0] cycles,instructions,divergences,barriers,
    input wire [31:0] host_word,
    output wire [31:0] host_rdata
);
    localparam IDLE=0, INIT=1, PICK=2, FETCH=3, EXEC=4, MEM_SCAN=5, MEM_LOAD=6;
    reg [2:0] state;
    reg [6:0] init_index;
    reg [1:0] current,rr;
    reg [31:0] insn;
    reg [31:0] pc[0:3];
    reg [7:0] mask[0:3];
    reg [3:0] halted,waiting;
    reg [31:0] barrier_pc[0:3];
    reg [3:0] depth[0:3];
    reg [31:0] join_pc[0:31],pending_pc[0:31];
    reg [7:0] saved_mask[0:31],pending_mask[0:31];
    reg split_used[0:31];
    wire [4:0] stack_top={current,3'b0}+depth[current]-1;
    wire [4:0] stack_new={current,3'b0}+depth[current];
    (* rom_style="distributed" *) reg [31:0] imem[0:1023];
    (* ram_style="block" *) reg [31:0] global_mem[0:8191];
    (* ram_style="block" *) reg [31:0] shared_mem[0:1023];
    integer n;
    initial begin
        for(n=0;n<1024;n=n+1) imem[n]=32'h00100073;
        for(n=0;n<8192;n=n+1) global_mem[n]=0;
        for(n=0;n<1024;n=n+1) shared_mem[n]=0;
        $readmemh(ROM_FILE,imem);
    end
    // Independent synchronous BRAM port; bounds mux stays AFTER the register.
    reg [31:0] host_raw;
    reg host_valid;
    always @(posedge clk) begin
        host_raw<=global_mem[host_word[12:0]];
        host_valid<=(host_word<8192);
    end
    assign host_rdata=host_valid?host_raw:32'b0;

    wire [3:0] kind,alu;
    wire immediate;
    wire [31:0] imm;
    wire [4:0] rs1,rs2,rd;
    wire [2:0] f3;
    simt_decode decode(.insn(insn),.kind(kind),.alu(alu),.immediate(immediate),
        .imm(imm),.rs1(rs1),.rs2(rs2),.rd(rd),.f3(f3));
    wire [31:0] a[0:7],b[0:7],result[0:7];
    reg [7:0] rf_we;
    reg [6:0] rf_waddr;
    reg [31:0] rf_wdata[0:7];
    genvar g;
    generate for(g=0;g<8;g=g+1) begin: lanes
        simt_regfile rf(.clk(clk),.warp(current),.rs1(rs1),.rs2(rs2),
            .a(a[g]),.b(b[g]),.we(rf_we[g]),.waddr(rf_waddr),.wdata(rf_wdata[g]));
        simt_alu unit(.op(alu),.a(a[g]),.b(immediate?imm:b[g]),.pc(pc[current]),.y(result[g]));
    end endgenerate

    // Round-robin scheduling of runnable warps. No warp/thread instruction
    // duplication: exactly one instruction is broadcast on each EXEC cycle.
    reg selected;
    reg [1:0] choice;
    integer s,idx;
    always @* begin
        selected=0; choice=rr; idx=0;
        for(s=0;s<4;s=s+1) begin
            idx=(rr+s)&3;
            if(!selected && !halted[idx] && !waiting[idx]) begin selected=1; choice=idx; end
        end
    end

    reg [7:0] taken;
    reg [31:0] target;
    reg target_seen,indirect_diverged;
    reg [7:0] fault;
    reg bad_addr,bad_align;
    integer l;
    always @* begin
        taken=0; target=pc[current]+imm; target_seen=0; indirect_diverged=0;
        bad_addr=0; bad_align=0;
        for(l=0;l<8;l=l+1) begin
            if(mask[current][l]) begin
                case(f3)
                    0:taken[l]=(a[l]==b[l]); 1:taken[l]=(a[l]!=b[l]);
                    4:taken[l]=($signed(a[l])<$signed(b[l]));
                    5:taken[l]=($signed(a[l])>=$signed(b[l]));
                    6:taken[l]=(a[l]<b[l]); 7:taken[l]=(a[l]>=b[l]);
                    default:taken[l]=0;
                endcase
                if(kind==5) begin
                    if(!target_seen) begin target=result[l]&32'hfffffffe; target_seen=1; end
                    else if(target!=(result[l]&32'hfffffffe)) indirect_diverged=1;
                end
                if(kind==1 || kind==2) begin
                    if(!(result[l]<32768 || (result[l]>=32'h10000000 && result[l]<32'h10001000))) bad_addr=1;
                    if((f3[1:0]==1 && result[l][0]) || (f3==2 && result[l][1:0]!=0)) bad_align=1;
                end
            end
        end
        fault=0;
        if(kind==15) fault=2;
        else if(kind==11) fault=11;
        else if(kind==1 || kind==2) begin
            if(bad_align) fault=(kind==2)?6:4;
            else if(bad_addr) fault=(kind==2)?7:5;
        end else if(kind==3 || kind==4 || kind==5) begin
            if((kind!=3 || taken!=0) && target[1:0]!=0) fault=8'h80; // misaligned instruction (encoded 0x80)
            else if(indirect_diverged) fault=19;
            else if(kind==3 && taken!=0 && taken!=mask[current]) begin
                if(depth[current]==0) fault=16;
                else if(split_used[stack_top]) fault=16;
            end
        end else if(kind==8) begin
            if(depth[current]==8) fault=17;
            else if(imm==0 || imm[31] || target[1:0]!=0 || target>=4096) fault=18;
        end else if(kind==9) begin
            if(depth[current]==0) fault=18;
            else if(pc[current]!=join_pc[stack_top]) fault=18;
        end else if(kind==7 && (mask[current]!=8'hff || depth[current]!=0)) fault=20;
        else if(kind==10 && (mask[current]!=8'hff || depth[current]!=0)) fault=21;
    end

    // A memory instruction is validated for ALL active lanes before any write.
    // Then one lane at a time accesses the synchronous RAM. No atomics/coalescing.
    reg [31:0] mem_addr[0:7],mem_data[0:7];
    reg [7:0] mem_mask;
    reg [3:0] mem_lane;
    reg mem_store;
    reg [2:0] mem_f3;
    reg [4:0] mem_rd;
    reg [31:0] global_q,shared_q;
    wire [31:0] maddr=mem_addr[mem_lane[2:0]];
    wire [31:0] mwrite=mem_data[mem_lane[2:0]] << {maddr[1:0],3'b0};
    wire [3:0] mstrb=(mem_f3==0)?(4'b0001 << maddr[1:0]):
                       (mem_f3==1)?(4'b0011 << maddr[1:0]):4'b1111;
    wire mem_access=state==MEM_SCAN && mem_lane<8 && mem_mask[mem_lane[2:0]] && !reset;
    wire [31:0] mem_word=maddr[28]?shared_q:global_q;
    integer global_byte,shared_byte;
    // Separate registered read outputs match the byte-write BRAM templates.
    // Port A is read-first; store readback is unused. Host port B is read-only.
    always @(posedge clk) begin
        if(mem_access && !maddr[28]) begin
            if(mem_store) for(global_byte=0;global_byte<4;global_byte=global_byte+1)
                if(mstrb[global_byte]) global_mem[maddr[14:2]][global_byte*8+:8]<=mwrite[global_byte*8+:8];
            global_q<=global_mem[maddr[14:2]];
        end
    end
    always @(posedge clk) begin
        if(mem_access && maddr[28]) begin
            if(mem_store) for(shared_byte=0;shared_byte<4;shared_byte=shared_byte+1)
                if(mstrb[shared_byte]) shared_mem[maddr[11:2]][shared_byte*8+:8]<=mwrite[shared_byte*8+:8];
            shared_q<=shared_mem[maddr[11:2]];
        end
    end
    reg [31:0] load_result,shifted;
    integer r;
    always @* begin
        shifted=mem_word >> {maddr[1:0],3'b0};
        case(mem_f3)
            0:load_result={{24{shifted[7]}},shifted[7:0]};
            1:load_result={{16{shifted[15]}},shifted[15:0]};
            2:load_result=mem_word;
            4:load_result={24'b0,shifted[7:0]};
            5:load_result={16'b0,shifted[15:0]};
            default:load_result=0;
        endcase
        rf_we=0; rf_waddr={current,rd};
        for(r=0;r<8;r=r+1) rf_wdata[r]=result[r];
        if(!reset) begin
            if(state==INIT) begin
                rf_we=8'hff; rf_waddr=init_index;
                for(r=0;r<8;r=r+1) begin
                    rf_wdata[r]=0;
                    case(init_index[4:0])
                        2:rf_wdata[r]=32768-((init_index[6:5]*8+r)*256);
                        10:rf_wdata[r]=init_index[6:5]*8+r;
                        11:rf_wdata[r]=32;
                        12:rf_wdata[r]=0; // global framebuffer base
                    endcase
                end
            end else if(state==EXEC && fault==0 && rd!=0 && (kind==0 || kind==4 || kind==5)) begin
                rf_we=mask[current];
                if(kind==4 || kind==5) for(r=0;r<8;r=r+1) rf_wdata[r]=pc[current]+4;
            end else if(state==MEM_LOAD && mem_rd!=0) begin
                rf_we=8'b1 << mem_lane[2:0]; rf_waddr={current,mem_rd};
                for(r=0;r<8;r=r+1) rf_wdata[r]=load_result;
            end
        end
    end

    integer w,j;
    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE; busy<=0; done<=0; error<=0; fault_codes<=0;
            cycles<=0; instructions<=0; divergences<=0; barriers<=0;
            halted<=0; waiting<=0; current<=0; rr<=0; init_index<=0; insn<=32'h13;
            mem_mask<=0; mem_lane<=0; mem_store<=0; mem_f3<=0; mem_rd<=0;
            for(w=0;w<4;w=w+1) begin pc[w]<=0; mask[w]<=8'hff; depth[w]<=0; barrier_pc[w]<=0; end
        end else if(start && !busy) begin
            busy<=1; done<=0; error<=0; fault_codes<=0; cycles<=0;
            instructions<=0; divergences<=0; barriers<=0;
            halted<=0; waiting<=0; rr<=0; init_index<=0; state<=INIT;
            for(w=0;w<4;w=w+1) begin pc[w]<=0; mask[w]<=8'hff; depth[w]<=0; end
        end else if(busy) begin
            cycles<=cycles+1;
            case(state)
                INIT: if(init_index==127) state<=PICK; else init_index<=init_index+1;
                PICK: begin
                    if(&halted) begin busy<=0; done<=1; state<=IDLE; end
                    else if(waiting==4'b1111) begin
                        if(barrier_pc[0]==barrier_pc[1] && barrier_pc[0]==barrier_pc[2] && barrier_pc[0]==barrier_pc[3]) begin
                            waiting<=0; barriers<=barriers+1;
                        end else begin halted<=4'hf; error<=4'hf; fault_codes<=32'h16161616; waiting<=0; end
                    end else if(selected) begin current<=choice; rr<=choice+1; state<=FETCH; end
                    else begin // finished/failed warp prevents a full-block barrier
                        halted<=4'hf;
                        for(w=0;w<4;w=w+1) if(waiting[w]) begin error[w]<=1; fault_codes[w*8+:8]<=22; end
                        waiting<=0;
                    end
                end
                FETCH: begin
                    if(pc[current]>=4096 || pc[current][1:0]!=0) begin
                        error[current]<=1; halted[current]<=1;
                        fault_codes[current*8+:8]<=(pc[current][1:0]!=0)?8'h80:8'd1;
                        state<=PICK;
                    end else begin insn<=imem[pc[current][11:2]]; state<=EXEC; end
                end
                EXEC: begin
                    state<=PICK;
                    if(fault!=0) begin
                        error[current]<=1; halted[current]<=1; fault_codes[current*8+:8]<=fault;
                    end else begin
                        instructions<=instructions+1;
                        pc[current]<=pc[current]+4;
                        case(kind)
                            1,2: begin
                                mem_mask<=mask[current]; mem_lane<=0; mem_store<=(kind==2); mem_f3<=f3; mem_rd<=rd;
                                for(j=0;j<8;j=j+1) begin mem_addr[j]<=result[j]; mem_data[j]<=b[j]; end
                                state<=MEM_SCAN;
                            end
                            3: begin
                                if(taken!=0) pc[current]<=target;
                                if(taken!=0 && taken!=mask[current]) begin
                                    pending_pc[stack_top]<=pc[current]+4;
                                    pending_mask[stack_top]<=mask[current]&~taken;
                                    split_used[stack_top]<=1; mask[current]<=taken;
                                    divergences<=divergences+1;
                                end
                            end
                            4,5:pc[current]<=target;
                            7:halted[current]<=1;
                            8:begin
                                join_pc[stack_new]<=target; saved_mask[stack_new]<=mask[current];
                                pending_mask[stack_new]<=0; split_used[stack_new]<=0; depth[current]<=depth[current]+1;
                            end
                            9:begin
                                if(pending_mask[stack_top]!=0) begin
                                    pc[current]<=pending_pc[stack_top]; mask[current]<=pending_mask[stack_top]; pending_mask[stack_top]<=0;
                                end else begin mask[current]<=saved_mask[stack_top]; depth[current]<=depth[current]-1; end
                            end
                            10:begin waiting[current]<=1; barrier_pc[current]<=pc[current]; end
                        endcase
                    end
                end
                MEM_SCAN: begin
                    if(mem_lane==8) state<=PICK;
                    else if(!mem_mask[mem_lane[2:0]] || mem_store) mem_lane<=mem_lane+1;
                    else state<=MEM_LOAD;
                end
                MEM_LOAD: begin mem_lane<=mem_lane+1; state<=MEM_SCAN; end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
