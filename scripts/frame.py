#!/usr/bin/env python3
"""Read simulated hex or a live 115200-baud GPU2 UART frame; emit binary PPM."""
import argparse
from pathlib import Path
import struct
import time


def reference(p):
    x,y=p%64,p//64
    if abs(x-31)+abs(y-31)<16:
        return 0xffc020
    return ((x*4)<<16)|((y*4)<<8)|(224 if ((x//8)^(y//8))&1 else 32)


def read_serial(port):
    try:
        import serial
    except ImportError:
        raise SystemExit('Live capture requires pyserial: python3 -m pip install pyserial')
    with serial.Serial(port,115200,timeout=0.2) as dev:
        deadline=time.monotonic()+10
        window=bytearray()
        while time.monotonic()<deadline:
            window.extend(dev.read(1))
            window=window[-4:]
            if window==b'GPU2':
                payload=bytearray()
                while len(payload)<16388 and time.monotonic()<deadline:
                    payload.extend(dev.read(16388-len(payload)))
                if len(payload)!=16388:
                    raise SystemExit('Incomplete UART frame')
                if payload[:3]!=bytes([64,64,32]):
                    raise SystemExit('Unsupported frame geometry')
                if payload[3]:
                    raise SystemExit(f'GPU warp error bitmap: 0x{payload[3]:02x}')
                return list(struct.unpack('<4096I',payload[4:]))
    raise SystemExit('No complete GPU2 frame within 10 seconds')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    src=ap.add_mutually_exclusive_group(required=True)
    src.add_argument('--hex',type=Path)
    src.add_argument('--port')
    ap.add_argument('--output',type=Path,default=Path('build/captured.ppm'))
    ap.add_argument('--verify',action='store_true')
    args=ap.parse_args()
    words=[int(s,16) for s in args.hex.read_text().split()] if args.hex else read_serial(args.port)
    if len(words)!=4096: raise SystemExit(f'Expected 4096 pixels; got {len(words)}')
    if args.verify:
        for p,word in enumerate(words):
            if word!=reference(p): raise SystemExit(f'Pixel {p}: {word:08x} != {reference(p):08x}')
        print('PASS image: all 4096 pixels match independent reference')
    rgb=bytes(c for w in words for c in ((w>>16)&255,(w>>8)&255,w&255))
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_bytes(b'P6\n64 64\n255\n'+rgb)
    print(f'Wrote {args.output}')

if __name__=='__main__': main()
