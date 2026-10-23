# A7-Lite 200T RISC-V Compute GPU

Microphase A7-Lite **XC7A200T-FBG484-2**를 위한 소형 병렬 연산 GPU입니다.
4개의 RV32I 코어가 동일한 C 커널을 서로 다른 픽셀에 실행합니다. FPGA 구성 후
64×64 RGB 이미지를 계산하고, 보드 USB UART로 결과를 반복 전송합니다.

현재 구조는 **독립 PC를 가진 SPMD 멀티코어**입니다. SIMT 워프 스케줄러나
고정 기능 래스터라이저는 없습니다. OpenGL/Vulkan/CUDA 호환 GPU가 아니며,
HDMI·DDR3·부동소수점·텍스처 유닛은 구현 범위에 포함하지 않았습니다.

## 구성

```text
50 MHz board clock → MMCM → 10 MHz
                              │
                         launch / completion
                              │
          ┌──────────┬──────────┬──────────┬──────────┐
          │ RV32I #0 │ RV32I #1 │ RV32I #2 │ RV32I #3 │
          │ 4 KiB ROM per worker, same kernel image │
          │ 8 KiB RAM│ 8 KiB RAM│ 8 KiB RAM│ 8 KiB RAM│
          └──────────┴──────────┴──────────┴──────────┘
                              │ read after all workers halt
                       pixel interleaver
                              │
                         UART 115200 → PC → PPM
```

- 정수 ALU, 비교, 분기, 점프, byte/halfword/word load/store, FENCE 지원.
- RV32I의 ECALL은 오류 정지, EBREAK는 이 실행 환경에서 커널 완료 표시.
- 비정렬 접근, 범위 초과, 잘못된 명령은 해당 코어를 정지시키고 오류를 기록.
- M/A/F/D/C 확장, CSR, 인터럽트, privileged mode는 미지원.
- 명령과 데이터는 Harvard 구조. RAM은 비동기 읽기 distributed RAM이며 BRAM용 설계가 아님.
- 코어 간 공유 메모리·atomic·barrier는 없음. 모든 코어 완료 후 호스트가 결과를 읽음.
- `rtl/rv32i_core.v`와 명령어 테스트는 인접 `../RISC-V` 프로젝트에서 복사하고
  GPU 시작 레지스터 초기화를 추가했습니다. 원본 프로젝트는 변경하지 않았습니다.

## 실행

필요 도구: RV32I/ILP32를 지원하는 GNU RISC-V 툴체인, Python 3,
Icarus Verilog, 비트스트림 생성에는 Vivado와 200T 지원 라이선스.

```bash
make test                 # C 컴파일 + 명령어/멀티코어/이미지/UART 검증
make bit                  # 200T 합성, 배치배선, 타이밍 검사, 비트스트림
make program              # 연결된 200T 한 대에 JTAG SRAM 다운로드
python3 scripts/frame.py --port /dev/ttyUSB0 --output build/captured.ppm --verify
```

`make program`은 명시적으로 실행할 때만 보드를 설정합니다. SPI flash에는 기록하지 않습니다.
UART 포트 이름은 PC 환경에 맞게 바꿉니다. 캡처에는 `pyserial`이 필요합니다.
보드의 USB UART 커넥터를 연결하고 115200 baud, 8-N-1로 사용합니다.
출력은 매 프레임 전송 완료 부근부터 약 1초 간격을 두고 반복하므로 전원을 다시 켤 필요가 없습니다.
시뮬레이션 이미지는 `build/render.ppm`에 저장됩니다.

기본 Vivado 경로는 `/tools/Xilinx/Vivado/2022.1/bin/vivado`입니다.
다른 환경에서는 `make bit VIVADO=/path/to/vivado`를 사용합니다.
시뮬레이션은 PATH의 Icarus 또는 현재 환경의 `/tmp/gpu-iverilog`를 사용합니다.
Icarus가 없으면 먼저 시스템에 `iverilog` 패키지를 설치해야 합니다.
툴체인 접두어는 `make CROSS=riscv32-unknown-elf- test`처럼 바꿀 수 있습니다.

## 커널 수정

`firmware/render.c`를 수정하고 `make test`, `make bit`를 실행합니다.
커널은 구성 시 ROM에 포함되므로 실행 중 UART 업로드 기능은 없습니다.

```c
void kernel(unsigned tid, unsigned workers, volatile unsigned *out);
```

| 시작 레지스터 | 값 |
|---|---|
| PC | 0, `_start` |
| sp / x2 | 0x2000, 코어별 RAM 끝 |
| a0 / x10 | worker ID: 0..3 |
| a1 / x11 | worker 수: 4 |
| a2 / x12 | 0x0400, 코어별 출력 시작 |

| 데이터 주소 | 용도 |
|---|---|
| 0x0000..0x03ff | scratch 공간 |
| 0x0400..0x13ff | 해당 코어의 1024개 RGB 픽셀 |
| 0x1400..0x1fff | 추가 scratch 및 하향 성장 스택 |

전역 픽셀 `p`는 worker `p % 4`의 출력 배열 `p / 4`에 저장됩니다.
32비트 픽셀 형식은 `0x00RRGGBB`입니다. 각 코어는 독립적으로 분기할 수 있습니다.
전역 변수와 `.rodata`용 초기화 로더는 없으므로 링커가 해당 섹션 생성을 거부합니다.
스택/출력 영역 충돌은 소프트웨어가 피해야 합니다. 범위 검사는 RAM 전체에만 적용됩니다.
RAM은 FPGA 구성 시 0으로 초기화되지만 reset 또는 재실행 시에는 보존됩니다.

`compute_gpu`의 `start`는 idle에서 한 클럭 동안 올립니다. busy 중 요청은 무시합니다.
`done`과 worker별 `error`는 다음 시작 또는 reset까지 유지됩니다.
`host_lane`, `host_word`는 비동기 읽기 포트이며, `done=1`일 때 결과를 읽습니다.
잘못된 호스트 인덱스는 0을 반환합니다. 보드 데모의 코어 수는 4로 고정되어 있습니다.
`cycles`에는 완료 감지 오버헤드가 포함됩니다.

## UART 프레임

| 바이트 | 내용 |
|---|---|
| 0..3 | ASCII `GPU1` |
| 4..6 | width=64, height=64, workers=4 |
| 7 | worker 오류 비트맵; 0이면 성공 |
| 8..16391 | 스캔 순서의 4096개 little-endian 32비트 픽셀 |

`led[0]`은 정상 완료, `led[1]`은 오류 논리 신호입니다.
10 MHz / 87 분주로 실제 UART 속도는 약 114943 baud입니다.
프레임 전송에는 약 1.43초가 필요하며, 연산 시간과 별개입니다.
프로토콜에 CRC는 없으며 `--verify`는 기본 데모의 모든 픽셀을 비교합니다.
커널을 바꾸면 해당 검증 기준도 수정하거나 실제 캡처에서 `--verify`를 생략합니다.

## 보드 및 검증 자료

제조사 [A7-Lite Reference Manual](https://fpga-docs.microphase.cn/projects/documentation-of-microphase-fpga-board/en/latest/DEV_BOARD/A7-LITE/A7-Lite_Reference_Manual.html)의
200T 부품 표, 클럭·UART·LED 핀 표와 기존 A7-Lite 프로젝트 설정을 사용했습니다.
클럭 J19, UART TX V2, LED M18/N18, LVCMOS33입니다.
명령 동작의 기준은 [RISC-V RV32I specification](https://docs.riscv.org/reference/isa/v20240411/unpriv/rv32.html)입니다.

테스트는 다음 항목을 검증합니다.

- 2,582개의 directed/random 명령어 단일 스텝 벡터와 예외 동작.
- 전체 커널 실행, busy 중 start 무시, 반복 실행, 호스트 범위 검사.
- worker 하나에 잘못된 명령 주입, 오류 비트맵 확인, 정상 커널 재실행.
- 4,096개 픽셀을 독립적인 Python 기준 구현과 비교.
- UART 핀의 start/data/stop bit에서 전체 16,392바이트와 다음 프레임 헤더 확인.

기본 커널의 시뮬레이션 결과는 **26,004클럭 = 10MHz에서 2.6004ms**입니다.
이는 연산 시뮬레이션 수치이며 UART나 PC 처리 시간을 포함하지 않습니다.
합성 결과는 `build/utilization.rpt`, 배치배선 타이밍은 `build/timing.rpt`,
DRC는 `build/drc.rpt`, 최종 비트스트림은 `build/a7_gpu.bit`입니다.
실물 보드 다운로드와 UART 수신 여부는 별도의 실측 검증입니다.

### 이번 빌드 결과

Vivado 2022.1 / `xc7a200tfbg484-2` / 2026-10-23 배치배선 및 비트스트림 생성 완료.

| 항목 | 결과 |
|---|---|
| LUT | 16,755 (12.52%) |
| 플립플롭 | 4,190 (1.56%) |
| setup WNS / hold WHS | +71.317 ns / +0.108 ns |
| 타이밍 실패 endpoint | 0 |
| DRC 위반 | 0 |
| Icarus 시뮬레이션 | 명령어·GPU·픽셀·UART 모두 PASS |
| 실물 보드 다운로드 / UART 캡처 | 미실행 |

무한 루프 커널을 중단하는 watchdog은 없으므로 해당 경우 reset 또는 재구성이 필요합니다.
