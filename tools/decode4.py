#!/usr/bin/env python3
# Decodes the output of probe4.tcl (floppy drive probe, CORE/vhdl/floppy/floppy_probe.vhd).
# Usage: decode4.py samples.txt
import sys

CLK = 32_083_333
BINS = ["<1.5us", "1.5-3.5", "4us", "6us", "8us", ">=9us"]

def f(v, hi, lo):
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)

for line in open(sys.argv[1]):
    if line.startswith("C "):
        print("command", line.split()[1])
        continue
    if not line.startswith("F "):
        continue
    v = int(line.split()[1], 16)
    lv = f(v, 7, 0)
    levels = " ".join(n for i, n in enumerate(["INDEX", "TRK00", "WPROT", "DSKCHG", "RDATA", "MOTOR", "STEPPING"])
                      if lv >> i & 1)
    ctrl = f(v, 15, 8)
    per = f(v, 55, 32)
    rpm = "%.1f rpm" % (60 * CLK / per) if per and per != 0xFFFFFF else "no revolution"
    bins = [f(v, 95 + 16 * i, 80 + 16 * i) for i in range(6)]
    print("ctrl %02x idx %5d %s flux %6d [%s] steps %d dskchg edges %d wprot edges %d clk %04x | %s" % (
        ctrl, f(v, 31, 16), rpm, f(v, 79, 56),
        " ".join("%s:%d" % (n, b) for n, b in zip(BINS, bins)),
        f(v, 191, 176), f(v, 199, 192), f(v, 207, 200), f(v, 223, 208), levels or "-"))
