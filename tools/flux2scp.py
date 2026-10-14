#!/usr/bin/env python3
# Converts a flux capture of the MEGA65's internal floppy drive (probe4.tcl FLUX=dump, flux_capture.vhd)
# into an SCP file with the full revolutions between the index markers, e.g. for
# CORE/sim/real_floppy/run_flux_replay.sh or other flux tools.
# Usage: flux2scp.py dump.txt out.scp <cylinder> <head>
import struct, sys

CLK = 32_083_333
UNIT_NS = 2e9 / CLK          # one capture unit = 2 clock cycles = 62.3 ns
SCP_TICK_NS = 25.0

dump, out, cyl, head = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
count, data = None, bytearray()
for line in open(dump):
    if line.startswith("N "):
        count = int(line.split()[1])
    elif line.startswith("D "):
        v = int(line.split()[1], 16)
        data += v.to_bytes(1024, "little")
    elif line.startswith("B "):                       # the whole buffer in one scan
        h = line.split()[1]
        data += int(h, 16).to_bytes(len(h) // 2, "little")
assert count is not None, "no 'N <count>' line in the dump"
data = data[:count]

# revolutions: the intervals between two index markers (00)
marks = [i for i, b in enumerate(data) if b == 0]
revs = [data[a + 1:b] for a, b in zip(marks, marks[1:])]
sat = sum(1 for r in revs for b in r if b == 255)
print("%d bytes, %d index markers, %d full revolutions, %d saturated intervals" % (
    len(data), len(marks), len(revs), sat))
assert revs, "no full revolution in the capture"

track = cyl * 2 + head
tdata, trev = bytearray(), []
hdr_len = 4 + 12 * len(revs)
for r in revs:
    ticks = [max(1, round(b * UNIT_NS / SCP_TICK_NS)) for b in r]
    trev.append((sum(ticks), len(ticks), hdr_len + len(tdata)))
    tdata += b"".join(struct.pack(">H", t) for t in ticks)
    print("revolution: %d transitions, %.2f ms" % (len(ticks), sum(ticks) * SCP_TICK_NS / 1e6))
trk = b"TRK" + bytes([track]) + b"".join(struct.pack("<III", *t) for t in trev) + tdata

hdr = b"SCP" + bytes([0x22, 0x80, len(revs), track, track, 0x01, 0, 0, 0]) + struct.pack("<I", 0)
table = bytearray(168 * 4)
struct.pack_into("<I", table, 4 * track, len(hdr) + len(table))
open(out, "wb").write(hdr + table + trk)
print("written", out, "(track %d = cylinder %d head %d)" % (track, cyl, head))
