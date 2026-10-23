.section .text.start
.global _start
_start:
    # Hardware initializes sp, a0=worker ID, a1=worker count, a2=output pointer.
    call kernel
    ebreak
1:  j 1b
