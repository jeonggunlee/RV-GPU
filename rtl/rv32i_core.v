`timescale 1ns/1ps
// ============================================================================
// 교육용 32비트 싱글 사이클 RISC-V 코어
// ============================================================================
// [지원 명령어: RV32I 기본 정수 연산]
//   레지스터 연산 : ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
//   즉시값 연산   : ADDI, SLLI, SLTI, SLTIU, XORI, SRLI, SRAI, ORI, ANDI
//   상위 즉시값   : LUI, AUIPC
//   조건 분기     : BEQ, BNE, BLT, BGE, BLTU, BGEU
//   무조건 점프   : JAL, JALR
//   메모리 읽기   : LB, LH, LW, LBU, LHU
//   메모리 쓰기   : SB, SH, SW
//   메모리 순서   : FENCE (순차 실행, 버퍼 없는 메모리 구조이므로 no-op)
//   시스템 명령   : ECALL, EBREAK (핸들러 실행 대신 원인을 기록하고 CPU 정지)
//
// [명령 이름 읽기]
//   I = Immediate(즉시값), U = Unsigned(부호 없는 비교/확장),
//   B/H/W = Byte(8비트)/Halfword(16비트)/Word(32비트).
//   SLL/SRL/SRA = 논리 왼쪽/논리 오른쪽/산술 오른쪽 시프트.
//   SLT = Set Less Than: 비교가 참이면 1, 거짓이면 0을 저장.
//   NOP, LI, MV, J, RET 등은 별도 opcode가 아닌 어셈블러 의사 명령이다.
//   예: NOP = ADDI x0,x0,0; RET = JALR x0,0(x1).
//
// [실행 구조]
//   PC -> 외부 명령 메모리 -> 디코드 -> 레지스터 읽기 -> ALU/데이터 메모리
//      -> 다음 상승 에지에서 PC 및 목적 레지스터 갱신.
//   파이프라인이나 메모리 대기 상태 없이 정상 명령 하나를 한 클럭에 실행한다.
//   외부 메모리는 조합 읽기와 상승 에지 쓰기를 제공해야 한다.
//   명령/데이터 버스가 분리된 Harvard 구조이며 주소는 바이트 단위이다.
//
// [범위와 예외 정책]
//   M(곱셈/나눗셈), C(압축 명령), CSR, privileged ISA, 인터럽트는 미구현.
//   FENCE.I도 지원하지 않는다. 모든 명령은 32비트이고 PC는 4바이트 정렬이다.
//   비정렬 접근/접근 오류/잘못된 명령/ECALL/EBREAK에서 fault가 발생한다.
//   예외 명령의 PC를 유지하고 쓰기를 억제한 뒤 halted=1로 정지한다.
//   trap_cause는 진단 출력이며 CSR이 아니다. 정지 해제에는 reset이 필요하다.
// ============================================================================
// Derived from ../RISC-V/rtl/rv32i_core.v; GPU launch ABI added.
module rv32i_core #(
    parameter THREAD_ID=0, NUM_THREADS=0, STACK_TOP=0, OUTPUT_BASE=0
) (
    input wire clk, reset, // 상승 에지 클럭, 동기식 active-high reset
    output reg [31:0] pc, // 외부 명령 메모리에 전달하는 명령 바이트 주소
    input wire [31:0] instr, // 현재 PC의 32비트 명령 (조합 읽기)
    input wire imem_fault, // 외부 명령 메모리의 주소 범위/접근 오류
    output reg mem_valid, mem_write, // 데이터 접근 유효 / 쓰기 요청 (0이면 읽기)
    output reg [31:0] mem_addr, mem_wdata, // 유효 바이트 주소 / lane 위치에 맞춘 쓰기 데이터
    output reg [3:0] mem_wstrb, // byte enable: bit 0->[7:0], bit 3->[31:24]
    input wire [31:0] mem_rdata, // 정렬된 32비트 데이터 워드 (조합 읽기)
    input wire mem_fault, // 외부 데이터 접근 오류, mem_valid일 때만 판정
    output reg halted, // 예외 후 정지 상태 (reset 전까지 유지)
    output reg [3:0] trap_cause // 마지막 예외 원인 번호; reset 직후에는 0
);
    // x0~x31 레지스터 파일: 두 포트를 조합적으로 읽고 한 포트를 동기적으로 쓴다.
    // x0 읽기는 아래에서 0으로 고정하고, 쓰기는 순차 회로에서 차단한다.
    reg [31:0] regs [0:31];
    // 32비트 명령의 공통 필드. 실제 사용 여부는 명령 형식에 따라 달라진다.
    // rs1/rs2: 소스 레지스터 번호, rd: 목적 레지스터 번호 (각각 0~31).
    wire [4:0] rs1=instr[19:15], rs2=instr[24:20], rd=instr[11:7];
    wire [2:0] f3=instr[14:12]; // funct3: 명령군 내 연산/메모리 폭 선택
    wire [6:0] f7=instr[31:25], op=instr[6:0]; // funct7와 opcode (즉시값 명령에서는 f7가 상수의 일부일 수도 있음)
    // 조합 읽기 포트: rs1 -> a, rs2 -> b. x0의 물리 저장값과 무관하게 0 반환.
    wire [31:0] a=(rs1==0)?32'b0:regs[rs1];
    wire [31:0] b=(rs2==0)?32'b0:regs[rs2];
    // 즉시값 생성기: 명령 안에 흩어진 비트를 재배열하고 32비트로 부호 확장.
    // {{N{instr[31]}}, ...}는 부호 비트를 N번 복제하는 Verilog 문법이다.
    // I형: ADDI/논리 즉시값/load/JALR. signed 12비트, 범위 -2048~2047.
    wire [31:0] ii={{20{instr[31]}},instr[31:20]};
    // S형: store의 signed 12비트 주소 오프셋. [31:25]와 [11:7]을 연결.
    wire [31:0] si={{20{instr[31]}},instr[31:25],instr[11:7]};
    // B형: 현재 PC 기준 분기 오프셋. 최하위 비트는 항상 0 (2바이트 단위).
    // 이 코어에는 C 확장이 없으므로 실제로 선택한 목적지는 4바이트 정렬이어야 한다.
    wire [31:0] bi={{19{instr[31]}},instr[31],instr[7],instr[30:25],instr[11:8],1'b0};
    // J형: JAL의 현재 PC 기준 signed 21비트 오프셋. 최하위 비트는 0.
    // U형(LUI/AUIPC)은 아래 opcode 처리에서 [31:12] 뒤에 0을 12개 붙인다.
    wire [31:0] ji={{11{instr[31]}},instr[31],instr[19:12],instr[20],instr[30:21],1'b0};
    // 조합 회로의 임시 신호들. reg 선언 자체가 플립플롭을 의미하지는 않는다.
    // next_pc: 다음 PC, result: rd에 쓸 값, rhs: ALU 오른쪽 피연산자,
    // shifted: 읽은 메모리 워드에서 원하는 byte/halfword를 아래로 옮긴 값.
    reg [31:0] next_pc, result, rhs, shifted;
    // wr: 레지스터 쓰기 허용, illegal: 지원하지 않는 명령 인코딩,
    // taken: 분기 조건 만족, misalign: 데이터 주소 정렬 위반,
    // fault: 이번 명령을 완료하지 않고 정지시킬 예외 발생 여부.
    reg wr, illegal, taken, misalign, fault;
    // cause는 조합 예외 원인; trap_cause는 예외 발생 에지에 저장되는 원인.
    reg [3:0] cause;
    integer i; // reset 시 레지스터 초기화에 사용하는 반복 인덱스
    // ------------------------------------------------------------------------
    // 조합 회로: 디코드, ALU, 분기, 메모리 버스, writeback 값, 예외 판정.
    // blocking 대입(=)으로 앞서 계산한 값을 같은 블록의 다음 문장에서 사용한다.
    // ------------------------------------------------------------------------
    always @* begin
        // 모든 출력/임시값에 기본값을 주어 의도하지 않은 래치 생성을 방지한다.
        // 분기/점프가 아니면 다음 32비트 명령으로 이동한다 (PC + 4바이트).
        next_pc=pc+4; result=0; rhs=b; shifted=0;
        wr=0; illegal=0; taken=0; misalign=0; fault=0; cause=0;
        mem_valid=0; mem_write=0; mem_addr=0; mem_wdata=0; mem_wstrb=0;
        // 7비트 opcode로 명령군을 고르고 funct3/funct7로 세부 연산을 결정한다.
        case(op)
            // LUI rd,imm20: 상위 20비트에 상수를 넣고 하위 12비트를 0으로 만든다.
            7'h37: begin wr=1; result={instr[31:12],12'b0}; end
            // AUIPC rd,imm20: 현재 PC + (imm20 << 12). PC 상대 주소 생성에 사용.
            7'h17: begin wr=1; result=pc+{instr[31:12],12'b0}; end
            // JAL rd,offset: 복귀 주소 PC+4를 rd에 저장하고 PC+offset으로 점프.
            // rd=x0이면 복귀 주소를 버리므로 일반적인 무조건 점프로 사용할 수 있다.
            7'h6f: begin wr=1; result=pc+4; next_pc=pc+ji; end
            // JALR rd,offset(rs1): PC=(rs1+offset)&~1, rd=기존 PC+4.
            // 규약에 따라 목적지 bit 0을 지운다. bit 1이 1이면 아래에서 정렬 예외.
            // funct3=000만 유효하며, 주소 계산에는 쓰기 전 rs1 값이 사용된다.
            7'h67: begin wr=1; result=pc+4; next_pc=(a+ii)&32'hfffffffe; illegal=(f3!=0); end

            // 조건 분기: 레지스터 쓰기 없이 조건이 참일 때만 PC+bi를 선택.
            // signed 비교에는 $signed를 사용하고, unsigned 비교는 그대로 수행.
            7'h63: begin
                case(f3)
                    0: taken=(a==b);                    // BEQ: 같으면 분기
                    1: taken=(a!=b);                    // BNE: 다르면 분기
                    4: taken=($signed(a)<$signed(b));   // BLT: signed 미만
                    5: taken=($signed(a)>=$signed(b));  // BGE: signed 이상
                    6: taken=(a<b);                     // BLTU: unsigned 미만
                    7: taken=(a>=b);                    // BGEU: unsigned 이상
                    default: illegal=1;
                endcase
                if(taken) next_pc=pc+bi;
            end
            // ALU 공유: OP-IMM(0x13)은 rs1과 즉시값, OP(0x33)은 rs1과 rs2 연산.
            // result는 공통 writeback 경로를 거쳐 다음 상승 에지에 rd에 기록된다.
            7'h13,7'h33: begin
                wr=1;
                if(op==7'h13) rhs=ii; // 즉시값 명령이면 rs2 대신 ii 선택
                case(f3)
                    // ADD/ADDI 또는 SUB. SUBI는 별도 명령이 없고 음수 ADDI로 표현.
                    // 덧셈/뺄셈 overflow는 예외가 아니라 하위 32비트만 남는 wraparound.
                    0: begin
                        if(op==7'h33 && f7==7'h20) result=a-rhs;
                        else result=a+rhs;
                        if(op==7'h33 && f7!=0 && f7!=7'h20) illegal=1;
                    end
                    1: begin result=a<<rhs[4:0]; illegal=(f7!=0); end           // SLL/SLLI: 이동량은 0~31
                    2: result={31'b0,($signed(a)<$signed(rhs))};                // SLT/SLTI: signed 비교 결과 0 또는 1
                    3: result={31'b0,(a<rhs)};                                  // SLTU/SLTIU: ii도 먼저 부호 확장한 뒤 unsigned 비교
                    4: result=a^rhs;                                            // XOR/XORI: 비트별 배타적 OR
                    // 오른쪽 시프트: funct7=0x20이면 산술, 0이면 논리 시프트.
                    // 산술 시프트는 부호 비트를, 논리 시프트는 0을 상위 빈자리에 채운다.
                    5: begin
                        if(f7==7'h20) result=$signed(a)>>>rhs[4:0];
                        else result=a>>rhs[4:0];
                        illegal=(f7!=0 && f7!=7'h20);
                    end
                    6: result=a|rhs; // OR/ORI: 비트별 OR
                    7: result=a&rhs; // AND/ANDI: 비트별 AND
                endcase
                // R형에서 ADD/SUB와 SRL/SRA 외의 연산은 funct7=0만 허용한다.
                // 예를 들어 M 확장의 funct7=1은 잘못된 명령으로 처리된다.
                if(op==7'h33 && f3!=0 && f3!=5 && f7!=0) illegal=1;
            end
            // LOAD: 유효 주소 = rs1 + 부호 확장 I형 오프셋.
            // 외부 mem_rdata는 해당 주소가 포함된 정렬된 32비트 워드 전체이다.
            // little-endian: 주소 하위 2비트가 워드 안의 바이트 위치(0~3)를 선택.
            7'h03: begin
                wr=1; mem_valid=1; mem_addr=a+ii;
                // {mem_addr[1:0],3'b0} = 바이트 위치 * 8 -> 0/8/16/24비트 시프트.
                shifted=mem_rdata >> {mem_addr[1:0],3'b0};
                case(f3)
                    0: result={{24{shifted[7]}},shifted[7:0]};                                      // LB: 8비트 -> 32비트 부호 확장
                    1: begin result={{16{shifted[15]}},shifted[15:0]}; misalign=mem_addr[0]; end    // LH: 부호 확장, 2바이트 정렬
                    2: begin result=mem_rdata; misalign=(mem_addr[1:0]!=0); end                     // LW: 32비트, 4바이트 정렬
                    4: result={24'b0,shifted[7:0]};                                                 // LBU: 상위 24비트를 0으로 확장
                    5: begin result={16'b0,shifted[15:0]}; misalign=mem_addr[0]; end                // LHU: 0 확장, 2바이트 정렬
                    default: illegal=1;
                endcase
            end
            // STORE: 유효 주소 = rs1 + 부호 확장 S형 오프셋, 저장할 값 = rs2.
            // store는 rd를 쓰지 않는다. mem_wstrb가 실제로 갱신할 byte lane을 선택.
            7'h23: begin
                mem_valid=1; mem_write=1; mem_addr=a+si;
                // rs2의 하위 바이트들을 목적 byte lane으로 이동한다.
                // 예: 주소 하위 비트=1인 SB -> wdata[15:8], wstrb=0010.
                // 외부 메모리는 mem_valid && mem_write일 때 켜진 lane만 써야 한다.
                mem_wdata=b << {mem_addr[1:0],3'b0};
                case(f3)
                    0: mem_wstrb=4'b0001 << mem_addr[1:0]; // SB: 바이트 1개, 모든 바이트 주소 허용
                    1: begin mem_wstrb=4'b0011 << mem_addr[1:0]; misalign=mem_addr[0]; end // SH: 바이트 2개, 짝수 주소만 허용
                    2: begin mem_wstrb=4'b1111; misalign=(mem_addr[1:0]!=0); end // SW: 바이트 4개, 4의 배수 주소만 허용
                    default: illegal=1;
                endcase
            end
            
            // FENCE: 모든 메모리 작업이 순차적으로 완료되므로 추가 동작 없이 PC+4.
            // funct3!=0(FENCE.I 포함)은 지원하지 않는 명령이다.
            7'h0f: illegal=(f3!=0); // FENCE: in-order, no buffered transactions
            
            // SYSTEM: 정확한 ECALL/EBREAK 인코딩만 식별한다.
            // 운영체제/디버거로 점프하지 않고 이 교육용 실행 환경에서는 CPU를 정지.
            // CSR 명령 등 다른 SYSTEM 인코딩은 illegal instruction(cause=2).
            7'h73: begin
                fault=1;
                if(instr==32'h00000073) cause=11; // ECALL
                else if(instr==32'h00100073) cause=3; // EBREAK
                else begin cause=2; illegal=1; end
            end
            default: illegal=1;
        endcase
        // --------------------------------------------------------------------
        // 예외 병합. 아래쪽 if가 참이면 앞에서 결정한 cause를 덮어쓴다.
        // 우선순위(높음 -> 낮음): 현재 PC 정렬, 명령 fetch 오류, illegal,
        // 선택한 다음 PC 정렬, 데이터 정렬/접근 오류, ECALL/EBREAK.
        // 데이터 정렬 오류는 같은 접근의 mem_fault보다 먼저 처리한다.
        // --------------------------------------------------------------------
        if(misalign) begin fault=1; cause=mem_write?6:4; end // store 정렬=6 / load 정렬=4
        else if(mem_valid && mem_fault) begin fault=1; cause=mem_write?7:5; end // store 접근=7 / load 접근=5

        // 선택된 목적지만 검사: 조건이 거짓인 branch의 오프셋은 검사하지 않는다.
        if(next_pc[1:0]!=0) begin fault=1; cause=0; end // 명령 주소 정렬 오류=0
        if(illegal) begin fault=1; cause=2; end // 잘못된 명령=2
        if(imem_fault) begin fault=1; cause=1; end // 명령 접근 오류=1
        if(pc[1:0]!=0) begin fault=1; cause=0; end // 현재 명령 주소 자체가 비정렬

        // reset/정지/예외 시 레지스터와 메모리 쓰기를 모두 차단한다.
        // mem_valid/주소는 남을 수 있으므로 외부 쓰기는 반드시 mem_write로 한정한다.
        // load/점프의 rd 쓰기도 취소되어 예외 명령의 부분 실행을 방지한다.
        if(reset || halted || fault) begin wr=0; mem_write=0; mem_wstrb=0; end
    end
    
    // ------------------------------------------------------------------------
    // 순차 회로: 상승 에지에서만 architectural state(PC/레지스터/정지 상태) 변경.
    // nonblocking 대입(<=)으로 모든 상태가 에지 직전 값을 기준으로 함께 갱신된다.
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        // 동기식 active-high reset이 정지 상태보다 우선한다.
        // 이 코어의 reset은 외부 메모리를 초기화하지 않는다.
        if(reset) begin
            pc<=0; halted<=0; trap_cause<=0;
            for(i=0;i<32;i=i+1) regs[i]<=0;
            regs[2]<=STACK_TOP; regs[10]<=THREAD_ID;
            regs[11]<=NUM_THREADS; regs[12]<=OUTPUT_BASE;
        // halted=1이면 어떤 상태도 갱신하지 않는다. reset으로만 다시 시작한다.
        end else if(!halted) begin
            // 예외 시 PC를 갱신하지 않아 faulting instruction의 주소가 남는다.
            if(fault) begin halted<=1; trap_cause<=cause; end
            else begin
                pc<=next_pc;
                // x0 쓰기는 무조건 무시한다. 나머지 레지스터는 wr일 때만 갱신.
                if(wr && rd!=0) regs[rd]<=result;
            end
        end
    end
endmodule
