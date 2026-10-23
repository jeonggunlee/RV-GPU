OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
    . = 0;
    .text : { *(.text.start) *(.text*) }
    .unsupported : { *(.rodata*) *(.data*) *(.sdata*) *(.bss*) *(.sbss*) *(COMMON) }
    ASSERT(SIZEOF(.unsupported) == 0, "Kernel globals/constants need a data loader; not supported")
    ASSERT(SIZEOF(.text) <= 4096, "Kernel exceeds instruction memory")
    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame*) }
}
