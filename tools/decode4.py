#!/usr/bin/env python3
# Decodes the output of probe4.tcl (floppy drive probe, CORE/vhdl/floppy/floppy_probe.vhd).
# Usage: decode4.py samples.txt          (drive snapshots)
#        decode4.py --log samples.txt    (command log of the real floppy controller, probe4.tcl with LOG=1)
import sys

CLK = 32_083_333
BINS = ["<1.5us", "1.5-3.5", "4us", "6us", "8us", ">=9us"]

def f(v, hi, lo):
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)

def command(c):
    if c >> 4 == 0x0: return "restore"
    if c >> 4 == 0x1: return "seek"
    if c >> 5 == 0x1: return "step"
    if c >> 5 == 0x2: return "step in"
    if c >> 5 == 0x3: return "step out"
    if c >> 5 == 0x4: return "read sector" + (" (multi)" if c & 0x10 else "")
    if c >> 5 == 0x5: return "write sector" + (" (multi)" if c & 0x10 else "")
    if c >> 4 == 0xC: return "read address"
    if c >> 4 == 0xD: return "force interrupt"
    if c >> 4 == 0xE: return "read track"
    return "write track"

def status(c, s):
    if s == 0xFF: return "not read"
    names = ["busy", "index" if c < 0x80 else "drq", "track0" if c < 0x80 else "LOST DATA", "CRC ERROR",
             "SEEK ERROR" if c < 0x80 else "RECORD NOT FOUND", "spun up" if c < 0x80 else "record type",
             "write prot", "motor on"]
    return "%02x %s" % (s, " ".join(n for i, n in enumerate(names) if s >> i & 1))

lines = [l for l in open(sys.argv[-1]) if l.startswith(("C ", "F "))]

if "--log" in sys.argv:
    entries = {}
    count = 0
    for line in lines:
        if line.startswith("F "):
            v = int(line.split()[1], 16)
            count = f(v, 239, 224)
            entries[f(v, 303, 296)] = f(v, 295, 240)
    print("%d commands logged" % count)
    for n in range(max(0, count - 256), count):
        e = entries[n % 256]
        c = f(e, 7, 0)
        print("#%5d  %02x %-20s track %3d data %3d sector %3d side %d  dma %4d  %s" % (
            n, c, command(c), f(e, 15, 8), f(e, 23, 16), f(e, 31, 24), f(e, 50, 50), f(e, 49, 40),
            status(c, f(e, 39, 32))))
    sys.exit()

for line in lines:
    if line.startswith("C "):
        print("command", line.split()[1])
        continue
    v = int(line.split()[1], 16)
    lv = f(v, 7, 0)
    levels = " ".join(n for i, n in enumerate(["INDEX", "TRK00", "WPROT", "DSKCHG", "RDATA", "MOTOR", "STEPPING"])
                      if lv >> i & 1)
    ctrl = f(v, 15, 8)
    per = f(v, 55, 32)
    rpm = "%.1f rpm" % (60 * CLK / per) if per and per != 0xFFFFFF else "no revolution"
    bins = [f(v, 95 + 16 * i, 80 + 16 * i) for i in range(6)]
    print("ctrl %02x idx %5d %s flux %6d [%s] steps %d dskchg edges %d wprot edges %d clk %04x capture %d%s%s | %s" % (
        ctrl, f(v, 31, 16), rpm, f(v, 79, 56),
        " ".join("%s:%d" % (n, b) for n, b in zip(BINS, bins)),
        f(v, 191, 176), f(v, 199, 192), f(v, 207, 200), f(v, 223, 208), f(v, 321, 304),
        " busy" if f(v, 322, 322) else "", " done" if f(v, 323, 323) else "", levels or "-"))
