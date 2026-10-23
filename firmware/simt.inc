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
