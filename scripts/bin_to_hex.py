#!/usr/bin/env python3
from pathlib import Path
import sys
raw = Path(sys.argv[1]).read_bytes()
if len(raw) > 4096 or len(raw) % 4:
    raise SystemExit('Expected aligned RV32I code, maximum 4096 bytes')
words = [int.from_bytes(raw[i:i+4], 'little') for i in range(0,len(raw),4)]
words += [0x00100073] * (1024-len(words))
Path(sys.argv[2]).write_text(''.join(f'{w:08x}\n' for w in words))
