#!/usr/bin/env python3
"""Public zero-model producer for observer tests, never native Agent evidence."""
import os
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
deadline = time.monotonic() + 90
try:
    os.write(1, b'\x1b[?1049h\x1b[?1004hPUBLIC_OBSERVER_PROBE\r\n')
    (root / 'observer-ready').touch()
    for phase in ('early', 'late'):
        while not (root / ('observer-' + phase)).exists():
            if (root / 'observer-exit').exists():
                raise SystemExit(0)
            if time.monotonic() >= deadline:
                raise SystemExit(124)
            time.sleep(.02)
        os.write(1, bytes([7]))
    while not (root / 'observer-exit').exists():
        if time.monotonic() >= deadline:
            raise SystemExit(124)
        time.sleep(.02)
finally:
    os.write(1, b'\x1b[?1004l\x1b[?1049l')
