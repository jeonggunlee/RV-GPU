`timescale 1ns/1ps
// =============================================================================
// 단일 SIMT SM: 4 warp × 8 thread = 32 thread로 구성된 block 하나를 실행한다.
//
// [실행 모델]
//   - warp마다 PC/active mask/분기 스택을 가지며, thread마다 x0..x31을 가진다.
//   - 명령 fetch/decode는 하나이고, 선택한 warp의 명령을 8개 ALU lane에 배포한다.
//   - 같은 명령이라도 lane별 피연산자와 결과는 다르다. inactive lane은 쓰지 않는다.
//   - PICK → FETCH → EXEC의 비파이프라인 구조: 일반 명령은 warp당 3클럭이다.
//   - LSU는 활성 lane을 순차 처리하며 완료까지 SM 전체를 점유한다.
//     메모리 처리 중 다른 warp 실행, 8-bank RAM, store buffer는 아직 없다.
//
// [조건 분기]
//   - SSY로 재합류 문맥을 push하고, divergent branch의 taken 경로부터 실행한다.
//   - 첫 JOIN에서 보류 경로로 전환하고, 마지막 JOIN에서 원래 mask를 복원한다.
//   - warp당 8-entry LIFO 스택이며 thread의 x2/sp 소프트웨어 스택과 별개다.
//
// [시간/상태 표기]
//   - always @*는 조합 회로이고 posedge 블록은 상승 에지에서 상태를 갱신한다.
//   - <= 우변은 에지 직전 상태를 사용한다. 따라서 EXEC에서 PC+4를 예약해도
//     같은 블록의 jump/link/SSY 계산은 현재 명령의 원래 PC를 참조한다.
// =============================================================================
module simt_sm #(parameter ROM_FILE="firmware/render_simt.hex")(
    // reset: 동기식 제어 상태 초기화. 진행 중 실행을 중단하지만 RAM을 지우지 않는다.
    // start: !busy일 때만 수락. 실행 동안 계속 1이면 종료 뒤 다시 시작할 수 있으므로
    //        호출자는 일반적으로 한 클럭 펄스로 전달한다.
    input wire clk,reset,start,
    // busy: INIT부터 전체 종료 판정까지 1. done: 완료 후 다음 start/reset까지 유지.
    // done은 성공만을 뜻하지 않는다. 반드시 error/fault_codes도 확인한다.
    output reg busy,done,
    // error[w]: warp w의 오류 여부. fault_codes[w*8 +: 8]: 해당 warp의 원인 코드.
    output reg [3:0] error,
    output reg [31:0] fault_codes,
    // cycles: busy 상태의 클럭 수(INIT/스케줄링/LSU 포함).
    // instructions: 오류 없이 EXEC를 통과한 warp 명령 수(활성 thread 수를 곱하지 않음).
    // divergences: 실제 mask 분할 횟수. barriers: block barrier가 해제된 횟수.
    // 모든 카운터는 start/reset 시 0이며 32비트 넘침 시 wrap한다.
    output reg [31:0] cycles,instructions,divergences,barriers,
    // host_word는 바이트 주소가 아닌 global RAM의 32비트 word index이다.
    // 호스트는 done 이후 데이터를 소비한다. busy 중 같은 주소 read/write 충돌의
    // 반환값은 인터페이스 계약으로 보장하지 않는다. host_rdata는 동기 읽기 결과다.
    input wire [31:0] host_word,
    output wire [31:0] host_rdata
);
    // -------------------------------------------------------------------------
    // 1. 실행 상태와 warp별 문맥
    // -------------------------------------------------------------------------
    // INIT은 128개 register 주소를 순회한다. MEM_SCAN/MEM_LOAD는 단일 LSU 상태다.
    localparam IDLE=0, INIT=1, PICK=2, FETCH=3, EXEC=4, MEM_SCAN=5, MEM_LOAD=6;
    reg [2:0] state;
    // init_index = {warp[1:0], register[4:0]}; 같은 주소를 8개 lane에 동시에 쓴다.
    // current는 FETCH/EXEC/LSU 동안 고정된다. rr은 다음 PICK의 탐색 시작 warp이다.
    reg [6:0] init_index;
    reg [1:0] current,rr;
    reg [31:0] insn;
    // pc는 byte address. mask[w][lane]=1인 thread만 해당 warp 명령에 참여한다.
    // halted는 정상 EBREAK와 오류 정지를 모두 포함한다. waiting은 BAR 대기 전용.
    // BAR 실행 후 pc는 이미 +4가 되므로 도착 지점 비교용 barrier_pc를 따로 둔다.
    reg [31:0] pc[0:3];
    reg [7:0] mask[0:3];
    reg [3:0] halted,waiting;
    reg [31:0] barrier_pc[0:3];
    // 분기 스택을 [warp*8 + entry]의 평탄한 배열로 저장한다. depth의 범위는 0..8.
    // join_pc: SSY가 지정한 JOIN 주소 / saved_mask: SSY 진입 시 활성 thread.
    // pending_pc/pending_mask: 아직 실행하지 않은 fall-through 경로와 thread.
    // split_used: 해당 SSY frame이 이미 한 번 분할되었는지 표시한다.
    // 보류 경로로 전환한 뒤에도 split_used=1을 유지하여 같은 frame의 재분할을 막는다.
    reg [3:0] depth[0:3];
    reg [31:0] join_pc[0:31],pending_pc[0:31];
    reg [7:0] saved_mask[0:31],pending_mask[0:31];
    reg split_used[0:31];
    // stack_top은 기존 최상단, stack_new는 다음 push 위치이다.
    // depth=0의 top / depth=8의 new는 유효 entry가 아니므로 아래 fault 검사로
    // underflow/overflow 동작을 차단한다. 스택 데이터 자체는 reset할 필요가 없다.
    wire [4:0] stack_top={current,3'b0}+depth[current]-1;
    wire [4:0] stack_new={current,3'b0}+depth[current];
    // -------------------------------------------------------------------------
    // 2. 프로그램 ROM과 온칩 데이터 RAM
    // -------------------------------------------------------------------------
    // imem: 4KiB / global: 32KiB(0x00000000..0x00007fff)
    // shared: 4KiB(0x10000000..0x10000fff). 배열 첨자는 모두 word 단위이다.
    // 속성은 FPGA 합성 시 distributed ROM / block RAM 추론을 유도한다.
    (* rom_style="distributed" *) reg [31:0] imem[0:1023];
    (* ram_style="block" *) reg [31:0] global_mem[0:8191];
    (* ram_style="block" *) reg [31:0] shared_mem[0:1023];
    integer n;
    // FPGA 구성 시 초기 내용이며 launch/reset 때 반복 실행되는 로직이 아니다.
    // ROM의 미사용 부분은 정상 종료 EBREAK로 채우고 hex 파일의 명령을 덮어쓴다.
    initial begin
        for(n=0;n<1024;n=n+1) imem[n]=32'h00100073;
        for(n=0;n<8192;n=n+1) global_mem[n]=0;
        for(n=0;n<1024;n=n+1) shared_mem[n]=0;
        $readmemh(ROM_FILE,imem);
    end
    // 호스트 전용 global BRAM 읽기 포트. 주소를 샘플한 상승 에지 뒤 결과가 나온다.
    // 범위 판정도 함께 레지스터링하여 host_raw와 host_valid의 시점을 맞춘다.
    // 범위 밖 주소도 내부에서는 하위 비트로 읽지만, 출력 mux가 0으로 가린다.
    // 이 mux를 RAM 읽기 레지스터 뒤에 두어 동기 BRAM 추론 형태를 유지한다.
    reg [31:0] host_raw;
    reg host_valid;
    always @(posedge clk) begin
        host_raw<=global_mem[host_word[12:0]];
        host_valid<=(host_word<8192);
    end
    assign host_rdata=host_valid?host_raw:32'b0;

    // -------------------------------------------------------------------------
    // 3. 공유 decoder와 8개 lane의 레지스터 파일/ALU
    // -------------------------------------------------------------------------
    // kind: 0 ALU, 1 load, 2 store, 3 branch, 4 JAL, 5 JALR, 6 FENCE,
    //       7 EBREAK, 8 SSY, 9 JOIN, 10 BAR, 11 ECALL, 12 ID CSR, 15 illegal.
    // alu는 연산 선택, immediate는 ALU 두 번째 입력에 imm을 사용할지 선택한다.
    // load/store의 ALU 결과는 데이터가 아니라 rs1+imm 유효 주소이다.
    wire [3:0] kind,alu;
    wire immediate;
    wire [31:0] imm;
    wire [4:0] rs1,rs2,rd;
    wire [2:0] f3;
    simt_decode decode(.insn(insn),.kind(kind),.alu(alu),.immediate(immediate),
        .imm(imm),.rs1(rs1),.rs2(rs2),.rd(rd),.f3(f3));
    wire [31:0] a[0:7],b[0:7],result[0:7];
    // lane마다 서로 다른 읽기/쓰기 데이터가 있지만 register 번호는 warp가 공유한다.
    // rf_waddr={warp,rd}; rf_we의 각 bit가 해당 lane 쓰기를 허가한다.
    // lane별 RF는 4 warp × 32 register를 보관하므로 warp 전환 시 복사가 없다.
    reg [7:0] rf_we;
    reg [6:0] rf_waddr;
    reg [31:0] rf_wdata[0:7];
    genvar g;
    generate for(g=0;g<8;g=g+1) begin: lanes
        simt_regfile rf(.clk(clk),.warp(current),.rs1(rs1),.rs2(rs2),
            .a(a[g]),.b(b[g]),.we(rf_we[g]),.waddr(rf_waddr),.wdata(rf_wdata[g]));
        simt_alu unit(.op(alu),.a(a[g]),.b(immediate?imm:b[g]),.pc(pc[current]),.y(result[g]));
    end endgenerate

    // -------------------------------------------------------------------------
    // 4. Round-robin warp 선택(조합 우선순위 탐색)
    // -------------------------------------------------------------------------
    // rr부터 4개 warp를 원형 탐색하고 처음 발견한 실행 가능 warp만 선택한다.
    // selected가 이미 1이면 뒤 후보는 덮어쓰지 않는다. 실제 선택 반영은 PICK에서 한다.
    // 메모리 대기 warp 비트가 없는 이유: 현재 LSU는 current를 유지하며 SM을 독점한다.
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

    // -------------------------------------------------------------------------
    // 5. lane별 분기 비교, jump 목적지 합의, 명령 부작용 전 사전 검증
    // -------------------------------------------------------------------------
    // taken은 active mask와 비교 결과를 결합한 bit mask이다.
    // 0: 전원 fall-through / mask와 동일: 전원 taken / 그 외: divergence.
    // target 기본값은 PC+imm이며 JALR만 lane별 rs1+imm에서 얻는다.
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
                // BEQ/BNE/BLT/BGE/BLTU/BGEU. $signed는 부호 있는 비교를 명시한다.
                // branch 이외 명령에서도 조합 값은 생기지만 제어부가 kind로 사용을 제한한다.
                case(f3)
                    0:taken[l]=(a[l]==b[l]); 1:taken[l]=(a[l]!=b[l]);
                    4:taken[l]=($signed(a[l])<$signed(b[l]));
                    5:taken[l]=($signed(a[l])>=$signed(b[l]));
                    6:taken[l]=(a[l]<b[l]); 7:taken[l]=(a[l]>=b[l]);
                    default:taken[l]=0;
                endcase
                // JALR은 bit 0을 지운 주소를 사용한다. 첫 active lane을 기준으로
                // 나머지 active lane의 주소가 같아야 warp의 단일 PC로 실행할 수 있다.
                if(kind==5) begin
                    if(!target_seen) begin target=result[l]&32'hfffffffe; target_seen=1; end
                    else if(target!=(result[l]&32'hfffffffe)) indirect_diverged=1;
                end
                // 모든 active lane을 먼저 검사한다. inactive lane의 잘못된 주소는 무시.
                // halfword는 2바이트, word는 4바이트 정렬이 필요하며 byte는 제한 없다.
                // 하나라도 실패하면 해당 vector 명령 전체를 취소하여 부분 store를 막는다.
                if(kind==1 || kind==2) begin
                    if(!(result[l]<32768 || (result[l]>=32'h10000000 && result[l]<32'h10001000))) bad_addr=1;
                    if((f3[1:0]==1 && result[l][0]) || (f3==2 && result[l][1:0]!=0)) bad_align=1;
                end
            end
        end
        // fault 우선순위: illegal/ECALL → 메모리 정렬/범위 → 분기 → 구조화 제어.
        // 0=정상, 2=illegal(CSR 미지원/쓰기 포함), 11=ECALL.
        // load 정렬/범위=4/5, store 정렬/범위=6/7.
        // 0x80=명령 비정렬(프로젝트 코드), 19=lane별 JALR 주소 불일치.
        // 분기하지 않는 conditional branch는 사용하지 않을 target 정렬을 검사하지 않는다.
        // jump의 ROM 범위 초과는 다음 FETCH에서 code 1로 판정한다.
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
        // SSY는 앞으로 향하는 4-byte 정렬 JOIN만 허용한다. signed 12-bit imm에서
        // 양수이므로 최대 정렬 변위는 2044이다. target의 실제 opcode는 여기서 읽지 않는다.
        // JOIN 실행 때 스택 존재와 SSY가 지정한 PC 일치 여부를 검사한다.
        end else if(kind==8) begin
            if(depth[current]==8) fault=17;
            else if(imm==0 || imm[31] || target[1:0]!=0 || target>=4096) fault=18;
        end else if(kind==9) begin
            if(depth[current]==0) fault=18;
            else if(pc[current]!=join_pc[stack_top]) fault=18;
        end else if(kind==7 && (mask[current]!=8'hff || depth[current]!=0)) fault=20;
        else if(kind==10 && (mask[current]!=8'hff || depth[current]!=0)) fault=21;
    end

    // -------------------------------------------------------------------------
    // 6. Blocking LSU: 검증 완료된 한 warp 명령을 latch하고 lane별 순차 접근
    // -------------------------------------------------------------------------
    // mem_addr/data/mask는 EXEC 시점의 스냅샷이다. current도 완료까지 바뀌지 않는다.
    // mem_lane은 0..7 lane 번호 + 종료 표식 8을 표현하므로 4비트가 필요하다.
    // mem_rd/f3는 완료 시 load 목적 레지스터와 접근 폭/부호 확장 종류를 복원한다.
    reg [31:0] mem_addr[0:7],mem_data[0:7];
    reg [7:0] mem_mask;
    reg [3:0] mem_lane;
    reg mem_store;
    reg [2:0] mem_f3;
    reg [4:0] mem_rd;
    reg [31:0] global_q,shared_q;
    wire [31:0] maddr=mem_addr[mem_lane[2:0]];
    // little-endian: byte offset만큼 store 데이터를 왼쪽으로 옮기고 byte enable 생성.
    // 예: SB offset=2이면 하위 8비트를 word[23:16]에 쓰고 mstrb=0100이다.
    // maddr[28]로 공간 선택이 가능한 것은 EXEC에서 허용 주소 범위를 검증했기 때문이다.
    wire [31:0] mwrite=mem_data[mem_lane[2:0]] << {maddr[1:0],3'b0};
    wire [3:0] mstrb=(mem_f3==0)?(4'b0001 << maddr[1:0]):
                       (mem_f3==1)?(4'b0011 << maddr[1:0]):4'b1111;
    // 종료 표식 8에서는 하위 3비트가 0이지만 mem_lane<8 조건이 재접근을 막는다.
    // reset 중 쓰기/읽기 enable을 차단하여 중단된 LSU가 RAM을 수정하지 않게 한다.
    wire mem_access=state==MEM_SCAN && mem_lane<8 && mem_mask[mem_lane[2:0]] && !reset;
    wire [31:0] mem_word=maddr[28]?shared_q:global_q;
    integer global_byte,shared_byte;
    // byte-write BRAM 추론을 위해 공간별 동기 read 출력 레지스터를 분리한다.
    // 같은 에지의 read는 write 이전 word를 읽는 read-first 형태이다(store readback 미사용).
    // global의 별도 host 포트는 read-only이며 shared에는 host 포트가 없다.
    // lane은 오름차순 처리되므로 같은 주소/byte에 중복 저장하면 뒤 lane의 값이 남는다.
    // 이 결정적 순서는 atomic 연산이나 warp 간 동기화를 제공한다는 뜻은 아니다.
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
    // -------------------------------------------------------------------------
    // 7. Load 데이터 정렬/확장 및 RF writeback 선택
    // -------------------------------------------------------------------------
    // MEM_SCAN 에지에서 RAM 출력을 얻고 MEM_LOAD 동안 아래 회로로 가공한다.
    // 주소 byte offset만큼 오른쪽 이동한 뒤 LB/LH는 sign extend, LBU/LHU는 zero extend.
    // LW는 정렬된 전체 word를 사용한다. 미지원 f3는 decoder에서 이미 차단된다.
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
        // 기본값은 쓰기 금지. INIT/정상 EXEC/load 완료에서만 필요한 lane을 허가한다.
        // reset 또는 fault 명령의 GPR 부작용도 이 경로에서 차단한다.
        rf_we=0; rf_waddr={current,rd};
        for(r=0;r<8;r=r+1) rf_wdata[r]=result[r];
        if(!reset) begin
            // INIT: 모든 GPR을 0으로 만들되 launch ABI를 아래 값으로 설정한다.
            // x2/sp=32768-tid*256: thread마다 아래로 자라는 256-byte stack의 상단.
            // x10/a0=tid, x11/a1=32, x12/a2=framebuffer base 0.
            // x0 저장소도 초기화하지만 RF 읽기 회로는 언제나 상수 0을 반환한다.
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
            end else if(state==EXEC && fault==0 && rd!=0 && (kind==0 || kind==4 || kind==5 || kind==12)) begin
                rf_we=mask[current];
                if(kind==4 || kind==5) for(r=0;r<8;r=r+1) rf_wdata[r]=pc[current]+4;
                // JAL/JALR은 공통 복귀 주소 PC+4를 각 active lane의 rd에 쓴다.
                // CSR은 별도 ID 저장 RAM 없이 current와 lane 번호 r로 값을 생성한다.
                // 주소 0xCC0/1/2/3 = THREAD_ID/WARP_ID/LANE_ID/NUM_THREADS.
                // decoder가 전체 주소와 CSRRS rd,csr,x0 형태를 검증했으므로 여기서는
                // CSR 주소 하위 2비트(insn[21:20])만 사용한다. GPR을 덮어써도 ID는 불변.
                // 예: warp 2는 lane 0..7에 thread ID 16..23, warp ID 2를 반환한다.
                if(kind==12) for(r=0;r<8;r=r+1) begin
                    case(insn[21:20])
                        0:rf_wdata[r]=current*8+r; // block-local thread ID
                        1:rf_wdata[r]={30'b0,current};
                        2:rf_wdata[r]=r;
                        3:rf_wdata[r]=32;
                    endcase
                end
            // 현재 load의 한 lane만 쓴다. 모든 wdata 선에 같은 값을 연결해도
            // one-hot rf_we가 나머지 lane의 갱신을 막는다. rd=x0이면 결과만 버린다.
            // x0 목적 load도 주소 검증과 메모리 접근 자체는 수행한다.
            end else if(state==MEM_LOAD && mem_rd!=0) begin
                rf_we=8'b1 << mem_lane[2:0]; rf_waddr={current,mem_rd};
                for(r=0;r<8;r=r+1) rf_wdata[r]=load_result;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 8. 순차 제어: 실행 상태, warp 문맥, 분기 스택, barrier와 완료 처리
    // -------------------------------------------------------------------------
    // reset > idle 상태의 start > busy 실행 순으로 우선한다.
    // RAM/GPR 전체에 reset을 걸지 않는다. GPR은 INIT으로 초기화하고 RAM은 유지한다.
    // 스택 payload는 depth=0, LSU payload는 state/mem_mask로 무효화하므로 초기화 불필요.
    integer w,j;
    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE; busy<=0; done<=0; error<=0; fault_codes<=0;
            cycles<=0; instructions<=0; divergences<=0; barriers<=0;
            halted<=0; waiting<=0; current<=0; rr<=0; init_index<=0; insn<=32'h13;
            mem_mask<=0; mem_lane<=0; mem_store<=0; mem_f3<=0; mem_rd<=0;
            for(w=0;w<4;w=w+1) begin pc[w]<=0; mask[w]<=8'hff; depth[w]<=0; barrier_pc[w]<=0; end
        // 새 launch는 오류/통계/warp 문맥을 초기화한다. done의 이전 완료 표시도 지운다.
        // 기존 shared/global RAM 내용은 보존되므로 커널이 필요한 값을 직접 초기화한다.
        end else if(start && !busy) begin
            busy<=1; done<=0; error<=0; fault_codes<=0; cycles<=0;
            instructions<=0; divergences<=0; barriers<=0;
            halted<=0; waiting<=0; rr<=0; init_index<=0; state<=INIT;
            for(w=0;w<4;w=w+1) begin pc[w]<=0; mask[w]<=8'hff; depth[w]<=0; end
        end else if(busy) begin
            cycles<=cycles+1;
            case(state)
                // 마지막 INIT 에지에서도 writeback 회로가 주소 127을 기록한다.
                // 8 lane 병렬 × 128 주소 = 32 thread의 전체 GPR 초기화.
                INIT: if(init_index==127) state<=PICK; else init_index<=init_index+1;
                // 전체 종료 → 전원 barrier 도착 → runnable 선택 → 교착 판정 순서.
                // 정상 종료와 오류 종료 모두 halted에 포함되므로 done과 error를 함께 본다.
                // BAR는 같은 정적 명령 주소에 도착해야 한다. 0x16은 10진수 fault 22이다.
                // 일부 warp가 종료해 BAR를 채울 수 없으면 waiting warp만 code 22를 받는다.
                // 실행 가능한 warp가 무한 반복하면 교착으로 판정하지 않는다(watchdog 없음).
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
                // PC를 검사한 뒤 ROM word를 insn에 latch한다. C 확장은 없으므로 4-byte 정렬.
                // fetch fault는 잘못된 PC를 유지하고 해당 warp만 정지시킨다.
                FETCH: begin
                    if(pc[current]>=4096 || pc[current][1:0]!=0) begin
                        error[current]<=1; halted[current]<=1;
                        fault_codes[current*8+:8]<=(pc[current][1:0]!=0)?8'h80:8'd1;
                        state<=PICK;
                    end else begin insn<=imem[pc[current][11:2]]; state<=EXEC; end
                end
                // 정상 명령은 기본적으로 다음 PICK/PC+4로 진행한다.
                // 아래 case의 추가 nonblocking 할당이 필요한 경우 기본 전이를 덮어쓴다.
                // fault이면 PC/명령 카운터를 유지한다. RF 쓰기는 조합부 fault 조건으로 차단.
                // ALU/CSR/link의 실제 RF 쓰기는 별도 writeback 회로가 같은 에지에 수행한다.
                // kind 0/6/12는 추가 상태 처리가 없다. FENCE는 순차 LSU 구조에서 no-op.
                EXEC: begin
                    state<=PICK;
                    if(fault!=0) begin
                        error[current]<=1; halted[current]<=1; fault_codes[current*8+:8]<=fault;
                    end else begin
                        instructions<=instructions+1;
                        pc[current]<=pc[current]+4;
                        case(kind)
                            // 전체 활성 lane 검증이 통과한 경우에만 LSU를 시작한다.
                            // PC는 미리 +4지만 다음 명령 fetch는 전체 메모리 명령 완료 후다.
                            1,2: begin
                                mem_mask<=mask[current]; mem_lane<=0; mem_store<=(kind==2); mem_f3<=f3; mem_rd<=rd;
                                for(j=0;j<8;j=j+1) begin mem_addr[j]<=result[j]; mem_data[j]<=b[j]; end
                                state<=MEM_SCAN;
                            end
                            // taken=0이면 기본 PC+4. 전원 taken이면 target으로 이동만 한다.
                            // 일부 taken이면 현재 SSY frame에 false 경로를 보류하고
                            // taken mask만 실행한다. saved_mask/join_pc는 SSY의 값을 유지한다.
                            // 중첩 split은 새로운 SSY frame이 필요하며 분기 자체는 push하지 않는다.
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
                            // EBREAK는 디버그 trap 대신 warp 정상 종료다.
                            // full mask와 빈 스택 조건을 사전 검사하여 thread 일부 종료를 막는다.
                            7:halted[current]<=1;
                            // SSY push: 아직 split하지 않은 frame을 생성한다.
                            // pending_pc는 pending_mask=0일 때 사용하지 않으므로 여기서는 안 쓴다.
                            8:begin
                                join_pc[stack_new]<=target; saved_mask[stack_new]<=mask[current];
                                pending_mask[stack_new]<=0; split_used[stack_new]<=0; depth[current]<=depth[current]+1;
                            end
                            // JOIN에 보류 경로가 있으면 PC/mask를 바꾸고 frame을 유지한다.
                            // 두 번째 도착(또는 uniform 분기로 첫 도착)에는 saved_mask 복원/pop.
                            // pending_mask를 비워도 split_used는 유지하므로 같은 frame의
                            // false 경로에서 또 split하려면 별도의 중첩 SSY가 필요하다.
                            9:begin
                                if(pending_mask[stack_top]!=0) begin
                                    pc[current]<=pending_pc[stack_top]; mask[current]<=pending_mask[stack_top]; pending_mask[stack_top]<=0;
                                end else begin mask[current]<=saved_mask[stack_top]; depth[current]<=depth[current]-1; end
                            end
                            // BAR 도착 기록. barrier_pc는 원래 PC, pc는 기본 할당으로 BAR+4.
                            // 기존 LSU가 blocking이므로 이 지점 전에 발행한 store는 이미 완료됐다.
                            // 해제 여부는 다음 PICK에서 전체 warp의 도착 상태로 판단한다.
                            10:begin waiting[current]<=1; barrier_pc[current]<=pc[current]; end
                        endcase
                    end
                end
                // 0..7의 모든 lane과 종료 표식 8을 스캔한다(총 9 scan 클럭).
                // store는 이 상태의 에지에서 쓰고 바로 다음 lane으로 진행한다.
                // inactive lane은 접근 없이 건너뛴다. active load만 MEM_LOAD를 추가한다.
                // 따라서 LSU 추가 시간은 store=9, load=9+활성 lane 수이며,
                // 명령 전체 시간에는 PICK/FETCH/EXEC 3클럭이 더해진다.
                MEM_SCAN: begin
                    if(mem_lane==8) state<=PICK;
                    else if(!mem_mask[mem_lane[2:0]] || mem_store) mem_lane<=mem_lane+1;
                    else state<=MEM_LOAD;
                end
                // 이 에지에서 writeback 회로가 동기 RAM 결과를 해당 lane에 기록한다.
                // mem_lane은 그 다음 번호로 갱신되어 다음 MEM_SCAN 접근을 준비한다.
                MEM_LOAD: begin mem_lane<=mem_lane+1; state<=MEM_SCAN; end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
