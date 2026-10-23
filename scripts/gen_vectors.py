#!/usr/bin/env python3
"""Deterministic directed and randomized architectural single-step vectors."""
import random
from encoding import I,S,B,J,R,ROOT
rng=random.Random(0x52563332)
mask=0xffffffff
rows=[]
def signed(v): return v if v<0x80000000 else v-(1<<32)
def emit(ins,a=0,b=0,rd=0,pcnext=0x104,trap=0,cause=0,addr=0,st=0,data=0,read=0,mf=0,imf=0):
    rows.append([ins,a,b,read,mf,imf,rd&mask,pcnext,trap,cause,addr&mask,st,data&mask])
vals=[0,1,31,32,0x7fffffff,0x80000000,0xffffffff,0x87654321]
for n in range(100):
    a=vals[n%len(vals)] if n<16 else rng.getrandbits(32)
    b=vals[(n+3)%len(vals)] if n<16 else rng.getrandbits(32)
    for f in range(8):
        res=[a+b,a<<(b&31),int(signed(a)<signed(b)),int(a<b),a^b,a>>(b&31),a|b,a&b][f]
        emit(R(0,2,1,f,3),a,b,res)
    emit(R(0x20,2,1,0,3),a,b,a-b)
    emit(R(0x20,2,1,5,3),a,b,signed(a)>>(b&31))
    imm=rng.randrange(-2048,2048); u=imm&mask
    for f in [0,2,3,4,6,7]:
        res={0:a+imm,2:int(signed(a)<imm),3:int(a<u),4:a^u,6:a|u,7:a&u}[f]
        emit(I(imm,1,f,3),a,b,res)
    sh=rng.randrange(32)
    emit(I(sh,1,1,3),a,b,a<<sh)
    emit(I(sh,1,5,3),a,b,a>>sh)
    emit(I(0x400+sh,1,5,3),a,b,signed(a)>>sh)
    for f,take in [(0,a==b),(1,a!=b),(4,signed(a)<signed(b)),(5,signed(a)>=signed(b)),(6,a<b),(7,a>=b)]:
        off=-16 if n%2 else 20
        emit(B(off,2,1,f),a,b,pcnext=0x100+off if take else 0x104)
for a,b in [(0,0),(1,1),(0xffffffff,0xffffffff),(0x80000000,0x80000000),(1,2)]:
    for f,t in [(0,a==b),(1,a!=b),(4,signed(a)<signed(b)),(5,signed(a)>=signed(b)),(6,a<b),(7,a>=b)]:
        emit(B(-4,2,1,f),a,b,pcnext=0xfc if t else 0x104)
emit(0xabcde000|(3<<7)|0x37,rd=0xabcde000)
emit(0xfffff000|(3<<7)|0x17,rd=0xfffff100)
for off in [-256,-4,4,128]: emit(J(off,3),rd=0x104,pcnext=0x100+off)
emit(I(9,1,0,3,0x67),a=0x100,rd=0x104,pcnext=0x108)
emit(I(123,0,0,0)) # x0 write ignored
for f in [0,1,2,4,5]:
    size={0:1,1:2,2:4,4:1,5:2}[f]
    for off in range(4):
        data=0x80ff817f; v=(data>>(off*8))&((1<<(size*8))-1)
        if f in [0,1] and v&(1<<(size*8-1)): v-=1<<(size*8)
        bad=off%size!=0
        emit(I(off,1,f,3,3),a=0x20,rd=0 if bad else v,read=data,
             addr=0x20+off,trap=int(bad),cause=4 if bad else 0,pcnext=0x100 if bad else 0x104)
for f in [0,1,2]:
    size=1<<f
    for off in range(4):
        bad=off%size!=0
        emit(S(off,2,1,f),a=0x20,b=0xdeadbeef,addr=0x20+off,
             st=0 if bad else ((1<<size)-1)<<off,data=0xdeadbeef<<(off*8),
             trap=int(bad),cause=6 if bad else 0,pcnext=0x100 if bad else 0x104)
for ins,cause in [(0xffffffff,2),(0x00000073,11),(0x00100073,3),
                  (R(1,2,1,0,3),2),(I(0x20,1,1,3),2),(J(2,3),0),
                  (I(2,0,0,3,0x67),0),(B(2,0,0,0),0)]:
    emit(ins,trap=1,cause=cause,pcnext=0x100)
emit(0x0ff0000f) # FENCE
emit(I(0,1,2,3,3),a=0x1000,mf=1,trap=1,cause=5,addr=0x1000,pcnext=0x100)
emit(S(0,2,1),a=0x1000,b=0x1234,mf=1,trap=1,cause=7,addr=0x1000,data=0x1234,pcnext=0x100)
emit(I(1,0,0,3),imf=1,trap=1,cause=1,pcnext=0x100)
(ROOT/'sim'/'vectors.txt').write_text(''.join(' '.join(f'{x&mask:08x}' for x in row)+'\n' for row in rows))
print(f'Generated {len(rows)} architectural vectors')
