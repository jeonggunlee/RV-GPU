#!/usr/bin/env python3
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def I(imm, rs1, f3, rd, op=0x13):
    return ((imm & 0xfff)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def S(imm, rs2, rs1, f3=2):
    v=imm&0xfff
    return ((v>>5)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((v&31)<<7)|0x23
def B(imm, rs2, rs1, f3):
    v=imm&0x1fff
    return ((v>>12)<<31)|(((v>>5)&63)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(((v>>1)&15)<<8)|(((v>>11)&1)<<7)|0x63
def J(imm, rd=0):
    v=imm&0x1fffff
    return ((v>>20)<<31)|(((v>>1)&1023)<<21)|(((v>>11)&1)<<20)|(((v>>12)&255)<<12)|(rd<<7)|0x6f
def R(f7,rs2,rs1,f3,rd):
    return (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|0x33
