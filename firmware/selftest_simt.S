# =============================================================================
# 1 SM / 4 warp / 8 thread-per-warp SIMT 기능 검증 커널
# =============================================================================
# 이 파일은 정상 동작의 결과를 global RAM에 기록한다. 실제 PASS/FAIL 판정은
# sim/tb_simt_control.sv가 커널 종료 후 각 thread의 결과를 읽어서 수행한다.
# 잘못된 명령, stack overflow 등의 오류 주입은 테스트벤치의 별도 프로그램이다.
# 보드의 기본 이미지 생성 커널은 render_simt.S이며 이 파일과 구분된다.
#
# 시작 시 하드웨어가 설정하는 값:
#   a0 = global thread ID(tid), 0..31. 실행 중 이 커널은 a0를 변경하지 않는다.
#   a1 = 전체 thread 수 32, a2 = global 출력 시작 주소 0. 여기서는 직접 사용 안 함.
#   warp ID = tid >> 3, lane ID = tid & 7.
#   같은 warp의 8개 thread는 PC/명령을 공유하지만 레지스터 값은 서로 다르다.
#
# 주요 레지스터 용도:
#   s0 = tid * 4: thread별 32비트 결과의 바이트 오프셋. 끝까지 유지한다.
#   s1 = 0x10000000 + tid*4: 자기 thread의 shared-memory word 주소.
#   s2 = 분기 결과값. 중첩 분기에서는 100/200/300/400, 비교 테스트에서는 0/1.
#   t0..t4 = 각 단계의 주소, 비교값, 읽기 결과, 지연 횟수 등 임시 값.
#
# 결과 주소 = 아래 base + tid*4. 각 결과 배열은 32 words = 128 bytes이다.
#   base       결과 / 기대값
#   0x0000     중첩 분기: tid%4가 0/1/2/3이면 각각 100/300/200/400
#   0x0080     다음 thread ((tid+1)&31)의 중첩 분기 결과
#   0x0100     LB  결과: 0xffffff80
#   0x0180     LBU 결과: 0x00000080
#   0x0200     LH  결과: 0xffff80ff
#   0x0280     LHU 결과: 0x000080ff
#   0x0300     SB/SH 후 LW 결과: 0x1234aa01
#   0x0380     x0 쓰기 무시 확인: 0
#   0x0400     BEQ:  tid == 0
#   0x0480     BNE:  tid != 0
#   0x0500     BLT:  tid < 16
#   0x0580     BGE:  tid >= 16
#   0x0600     BLTU: tid >= 16 (tid-16을 unsigned로 해석)
#   0x0680     BGEU: tid < 16  (tid-16을 unsigned로 해석)
#   0x4000     shared-memory 역순 읽기: 31-tid
# 별도로 global 0x1000 + tid*4를 byte/halfword 접근용 작업 공간으로 사용한다.
# 테스트벤치 host_word는 바이트 주소가 아닌 word index이므로 위 주소를 4로 나눈다.

.include "firmware/simt.inc"    # SSY/JOIN/BAR를 custom-0 기계어로 만드는 매크로
.section .text.start            # 링커가 이 섹션을 코드 시작 주소 0에 배치
.global _start                 # 진입점 이름을 링커에 공개
_start:
    # ABI 초기값을 덮어쓴 뒤 읽기 전용 CSR에서 ID/크기를 다시 가져온다.
    # 일반 레지스터의 값과 무관하게 ID를 재조회할 수 있어야 한다.
    li a0, -1
    li a1, -1
    READ_CSR a0, CSR_THREAD_ID      # thread ID 읽기
    READ_CSR a1, CSR_NUM_THREADS
    # -------------------------------------------------------------------------
    # 1. thread별 주소를 준비하고 warp 간 shared-memory 교환을 검증한다.
    # -------------------------------------------------------------------------
    slli s0,a0,2               # s0 = tid * 4. 메모리 주소는 바이트 단위이다.
    lui s1,0x10000             # LUI는 immediate를 12비트 올림: s1 = 0x10000000
    add s1,s1,s0               # s1 = &shared[tid], 모든 thread가 서로 다른 word 사용

    # warp마다 도착 시간을 의도적으로 다르게 만든다.
    # 반복 횟수는 warp 0/1/2/3에서 4/8/12/16회이다. 같은 warp 안에서는
    # 횟수가 같으므로 이 loop의 BNE는 uniform branch이며 SSY가 필요 없다.
    # 먼저 끝난 warp 0이 BAR 없이 계속 실행하면, warp 3이 아직 쓰지 않은
    # shared[31..24]를 읽을 수 있다. 따라서 실제 barrier 대기 동작을 검증한다.
    srli t4,a0,3               # t4 = warp ID
    addi t4,t4,1               # 1, 2, 3, 4
    slli t4,t4,2               # 4, 8, 12, 16
arrival_delay:
    addi t4,t4,-1              # 남은 반복 횟수 감소
    bne t4,zero,arrival_delay  # 해당 warp의 모든 lane이 함께 반복 또는 탈출
    sw a0,0(s1)                # shared[tid] = tid
    BAR                        # 4 warp 전체가 기록을 마칠 때까지 먼저 온 warp는 대기

    # 자기 값이 아닌 반대편 thread의 값을 읽는다.
    # tid 0은 31을, tid 7은 24를, tid 31은 0을 읽으므로 warp 경계를 넘는다.
    li t0,31
    sub t0,t0,a0               # t0 = 31 - tid
    slli t0,t0,2               # word index -> byte offset
    lui t1,0x10000             # shared RAM base
    add t0,t0,t1               # t0 = &shared[31-tid]
    lw t2,0(t0)                # 기대값: t2 = 31-tid
    lui t3,4                   # t3 = 0x00004000 (4 자체가 아님)
    add t3,t3,s0               # 자기 결과 기록 위치: 0x4000 + tid*4
    sw t2,0(t3)                # 테스트벤치가 host word index 4096+tid에서 확인

    # -------------------------------------------------------------------------
    # 2. 두 단계의 중첩 divergence와 JOIN의 마스크 복원을 검증한다.
    # -------------------------------------------------------------------------
    # mask의 bit n은 lane n을 의미한다. 각 warp의 tid 시작값은 8의 배수이므로
    # 아래 짝수/홀수 및 bit 1 구분은 모든 warp에서 동일한 lane mask를 만든다.
    #   짝수 mask = 0x55 (lane 0,2,4,6), 홀수 mask = 0xaa (lane 1,3,5,7)
    andi t0,a0,1               # tid bit 0: 짝수=0, 홀수=1
    andi t1,a0,2               # tid bit 1: 0 또는 2
    slli t2,t0,16              # 짝수 주소=0, 홀수 주소=0x10000 (접근 범위 밖)
    SSY outer_join             # 현재 mask 0xff와 외부 합류 PC를 stack에 push
    bne t0,zero,odd            # taken-first 정책: 홀수 경로를 먼저 실행

    # 짝수 경로: odd 경로가 outer_join에 도착한 후 이 위치로 돌아온다.
    # 홀수 lane의 t2는 잘못된 주소지만 해당 lane은 비활성 상태이다.
    # LSU가 active lane만 검사/접근하면 fault 없이 주소 0을 읽는다.
    # t3의 읽은 값 자체는 검사하지 않으며, 오류 없이 진행되는지가 핵심이다.
    lw t3,0(t2)                # 현재 mask=0x55, 활성 lane의 주소는 모두 0
    SSY even_join              # 내부 frame에는 0xff가 아닌 현재 mask 0x55를 저장
    bne t1,zero,even_hi         # lane 2,6 (mask 0x44)을 먼저 실행
    li s2,100                  # 나중에 실행되는 lane 0,4 (mask 0x11), tid%4==0
    j even_join                # LI/J는 assembler 의사 명령; J는 JAL x0로 인코딩
 even_hi:
    li s2,200                  # tid%4==2인 lane만 자신의 s2를 갱신
 even_join:
    JOIN                       # 대기 경로가 있으면 전환, 모두 끝나면 mask=0x55 복원
    j outer_join               # 외부 frame의 합류 위치로 이동
 odd:
    # 홀수 경로: 외부 BNE의 taken path이며 mask=0xaa로 진입한다.
    SSY odd_join               # 내부 frame에는 현재 mask 0xaa를 저장
    bne t1,zero,odd_hi          # lane 3,7 (mask 0x88)을 먼저 실행
    li s2,300                  # 나중에 실행되는 lane 1,5 (mask 0x22), tid%4==1
    j odd_join
 odd_hi:
    li s2,400                  # tid%4==3인 lane만 자신의 s2를 갱신
 odd_join:
    JOIN                       # 홀수 내부 두 경로 완료 후 mask=0xaa로 복원
 outer_join:
    # 첫 도착(홀수 경로 완료)에서는 보류 중인 짝수 경로로 전환한다.
    # 두 번째 도착(짝수 경로 완료)에서 외부 frame을 pop하고 mask=0xff를 복원한다.
    # 결과적으로 s2에는 lane별로 100,300,200,400,100,300,200,400이 남는다.
    JOIN
    sw s2,0(s0)                # global[tid] = 분기 결과. 8개 lane 모두 쓰는지 확인
    sw s2,0(s1)                # shared[tid]도 새 분기 결과로 덮어쓴다.
    BAR                        # full mask, 열린 SSY frame 없음: 두 번째 block barrier

    # 다음 thread의 결과를 읽어 두 번째 barrier와 shared-memory 가시성을 확인.
    # tid 7->8, 15->16, 23->24는 다음 warp, tid 31->0은 첫 warp를 읽는다.
    addi t0,a0,1
    andi t0,t0,31              # t0 = (tid+1) % 32. 32가 2의 거듭제곱이라 AND 사용
    slli t0,t0,2
    lui t1,0x10000
    add t0,t0,t1               # &shared[(tid+1)&31]
    lw t2,0(t0)
    sw t2,128(s0)              # global byte address 0x80+tid*4에 기록

    # -------------------------------------------------------------------------
    # 3. load의 폭/부호 확장과 store의 byte enable을 검증한다.
    # -------------------------------------------------------------------------
    lui t0,1                   # t0 = 0x1000, 결과 배열과 겹치지 않는 작업 공간
    add t0,t0,s0               # 각 thread가 자기 word만 수정한다.
    li t1,0x80ff7f01           # 큰 상수 LI는 여러 실제 명령으로 확장될 수 있다.
    sw t1,0(t0)
    # little-endian 배치: [t0+0]=01, [t0+1]=7f, [t0+2]=ff, [t0+3]=80.
    # 주소 하위 비트로 byte/halfword를 선택하고 signed/unsigned load를 비교한다.
    lb t2,3(t0)                # 0x80의 sign bit=1 -> 0xffffff80 (-128)
    sw t2,256(s0)
    lbu t2,3(t0)               # 같은 byte를 zero-extend -> 0x00000080 (128)
    sw t2,384(s0)
    lh t2,2(t0)                # halfword 0x80ff를 sign-extend -> 0xffff80ff
    sw t2,512(s0)
    lhu t2,2(t0)               # 같은 halfword를 zero-extend -> 0x000080ff
    sw t2,640(s0)
    li t1,0xaa
    sb t1,1(t0)                # byte 1만 교체: 0x80ff7f01 -> 0x80ffaa01
    li t1,0x1234
    sh t1,2(t0)                # byte 2,3만 교체: 0x80ffaa01 -> 0x1234aa01
    lw t2,0(t0)                # byte 0의 01과 byte 1의 aa가 보존됐는지 전체 word 확인
    sw t2,768(s0)
    addi zero,zero,99          # x0에 99를 쓰려고 해도 architectural x0 값은 항상 0
    sw zero,896(s0)            # 기대값 0을 메모리로 내보내 테스트벤치에서 확인

    # -------------------------------------------------------------------------
    # 4. 여섯 종류의 conditional branch와 signed/unsigned 비교를 검증한다.
    # -------------------------------------------------------------------------
    addi t0,a0,-16             # signed로 -16..15. tid<16에서는 상위 sign bit가 1
    li t1,16                   # unsigned 비교 기준

# TEST_BRANCH는 아래의 명령열을 호출 지점마다 펼쳐 넣는 assembler 매크로이다.
# 함수 호출이 아니므로 별도의 call/return이나 stack 저장은 없다.
#   branch: BEQ/BNE/BLT/BGE/BLTU/BGEU 중 하나
#   lhs/rhs: 비교할 레지스터 이름
#   offset: thread별 결과 배열의 base byte address
# '\인자명'은 전달한 텍스트로 치환되고, '\@'는 GNU assembler의 매크로 확장 번호다.
# join_\@/taken_\@를 사용하면 여섯 번 확장해도 label 이름이 서로 충돌하지 않는다.
.macro TEST_BRANCH branch, lhs, rhs, offset
    li s2,0                    # false인 thread의 기본 결과를 미리 설정
    SSY join_\@                # 이 비교의 합류 위치와 진입 시 mask를 저장
    \branch \lhs,\rhs,taken_\@ # true thread만 taken 경로로 이동
    j join_\@                  # false thread는 s2=0을 유지한 채 합류
 taken_\@:
    li s2,1                    # true인 active thread만 s2=1로 변경
 join_\@:
    JOIN                       # true/false 결과를 각 레지스터에 유지하며 mask 복원
    sw s2,\offset(s0)          # 결과 주소 = offset + tid*4
.endm
    TEST_BRANCH beq, a0, zero, 1024  # tid==0: thread 0만 1, 나머지는 0
    TEST_BRANCH bne, a0, zero, 1152  # tid!=0: thread 0만 0, 나머지는 1
    TEST_BRANCH blt, t0, zero, 1280  # signed (tid-16)<0: tid 0..15가 1
    TEST_BRANCH bge, t0, zero, 1408  # signed (tid-16)>=0: tid 16..31이 1
    # 음수 -16..-1의 unsigned 값은 0xfffffff0..0xffffffff이므로 16보다 크다.
    # 반면 tid 16..31의 t0 값은 0..15이므로 unsigned로도 16보다 작다.
    TEST_BRANCH bltu, t0, t1, 1536   # unsigned (tid-16)<16: tid 16..31이 1
    TEST_BRANCH bgeu, t0, t1, 1664   # unsigned (tid-16)>=16: tid 0..15가 1

    # BEQ/BNE는 warp 0 내부에서 true/false가 섞여 각각 split 1회가 발생한다.
    # 나머지 네 비교는 warp 경계(16)를 기준으로 나뉘어 warp 내부에서는 uniform이다.
    # 이 커널 전체의 예상 수치:
    #   nested split = warp당 3회 * 4 = 12, 비교 split = 2, 총 14회
    #   block barrier release = 2회
    # 모든 JOIN이 끝났으므로 mask=0xff, stack depth=0 상태에서 정상 종료한다.
    # 이 실행 환경의 EBREAK는 warp 전체의 완료 표시이며 일반 디버거 호출이 아니다.
    ebreak
