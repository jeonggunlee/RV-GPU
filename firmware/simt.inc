# Structured control-flow extension, custom-0 opcode. Target must be a forward
# JOIN within signed 12-bit PC-relative range. Each frame handles one split.
.macro SSY target
    .word (((\target - .) & 0xfff) << 20) | 0x0000000b
.endm
.macro JOIN
    .word 0x0000100b
.endm
.macro BAR
    .word 0x0000200b
.endm

# Project read-only ID CSRs. Only CSRRS rd, csr, x0 is implemented.
.equ CSR_THREAD_ID,   0xCC0  # block-local thread index, 0..31
.equ CSR_WARP_ID,     0xCC1  # resident warp index, 0..3
.equ CSR_LANE_ID,     0xCC2  # lane within warp, 0..7
.equ CSR_NUM_THREADS, 0xCC3  # resident block size, 32

# Encode csrr without enabling/claiming the complete Zicsr extension.
# CSR addresses 0xCC0..0xCC3 are encoded as signed 12-bit immediates.
# Example: READ_CSR a0, CSR_THREAD_ID
.macro READ_CSR dest, csr
    .insn i 0x73, 2, \dest, x0, (\csr - 0x1000)
.endm
