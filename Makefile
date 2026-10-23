CROSS ?= riscv64-unknown-elf-
PYTHON ?= python3
VIVADO ?= /tools/Xilinx/Vivado/2022.1/bin/vivado
CFLAGS = -march=rv32i -mabi=ilp32 -O2 -ffreestanding -fno-builtin -fno-pic -msmall-data-limit=0 -nostdlib -nostartfiles -Wl,--no-relax -Wl,-T,firmware/link.ld
.PHONY: all firmware test bit program clean
all: test
firmware: firmware/render_simt.hex firmware/selftest_simt.hex
build:
	mkdir -p build
build/%_simt.elf: firmware/%_simt.S firmware/simt.inc firmware/link.ld | build
	$(CROSS)gcc $(CFLAGS) $< -o $@
	$(CROSS)objdump -d $@ > $(@:.elf=.dis)
build/%_simt.bin: build/%_simt.elf
	$(CROSS)objcopy -O binary $< $@
firmware/%_simt.hex: build/%_simt.bin scripts/bin_to_hex.py
	$(PYTHON) scripts/bin_to_hex.py $< $@
.PRECIOUS: build/%_simt.elf build/%_simt.bin
test: firmware | build
	PYTHON="$(PYTHON)" bash scripts/sim.sh
bit: firmware | build
	$(VIVADO) -mode batch -source scripts/build.tcl -log build/simt_vivado.log -journal build/simt_vivado.jou
program:
	@test -f build/a7_simt_gpu.bit
	$(VIVADO) -mode batch -source scripts/program.tcl -log build/program.log -journal build/program.jou
clean:
	rm -rf build
