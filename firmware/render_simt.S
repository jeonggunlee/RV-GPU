.include "firmware/simt.inc"
.section .text.start
.global _start
_start:
    # Launch ABI: a0=global tid (0..31), a1=32, a2=global output base (0).
    # Exchange thread IDs through SM shared memory, synchronized across 4 warps.
    lui t0,0x10000
    slli t1,a0,2
    add t2,t0,t1
    sw a0,0(t2)
    BAR
    li t3,31
    sub t3,t3,a0
    slli t3,t3,2
    add t3,t3,t0
    lw t4,0(t3)
    lui t5,4
    add t5,t5,t1
    sw t4,0(t5)                 # diagnostics at global 0x4000 + tid*4
    mv s0,a0
    li s1,4096
pixel_loop:
    andi t0,s0,63               # x
    srli t1,s0,6                # y
    srli t2,t0,3
    srli t3,t1,3
    xor t2,t2,t3
    andi t2,t2,1
    slli t3,t2,7
    slli t2,t2,6
    add t2,t2,t3
    addi t2,t2,32               # checker blue = 32 or 224
    slli t3,t0,18               # (x*4)<<16
    slli t4,t1,10               # (y*4)<<8
    or s2,t3,t4
    or s2,s2,t2
    addi t0,t0,-31
    srai t2,t0,31
    xor t0,t0,t2
    sub t0,t0,t2                # abs(x-31)
    addi t1,t1,-31
    srai t2,t1,31
    xor t1,t1,t2
    sub t1,t1,t2                # abs(y-31)
    add t0,t0,t1
    li t1,16
    SSY diamond_join
    bltu t0,t1,diamond
    j diamond_join
 diamond:
    li s2,0x00ffc020
 diamond_join:
    JOIN
    slli t0,s0,2
    add t0,t0,a2
    sw s2,0(t0)
    add s0,s0,a1
    bltu s0,s1,pixel_loop       # uniform: every thread has 128 pixels
    ebreak
