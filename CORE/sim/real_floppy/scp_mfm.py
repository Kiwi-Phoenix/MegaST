#!/usr/bin/env python3
# Decodes the MFM sectors of an SCP flux file revolution by revolution and reports per sector the
# timing quality: the largest and the mean deviation of the flux intervals from 4/6/8 us.
import struct, sys

def crc16(data, crc=0xFFFF):
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = (crc << 1) ^ 0x1021 if crc & 0x8000 else crc << 1
            crc &= 0xFFFF
    return crc

def load(path):
    d = open(path, 'rb').read()
    assert d[:3] == b'SCP'
    revs, res = d[5], d[0xB]
    tick = 25 * (res + 1)
    tracks = {}
    for t in range(168):
        off = struct.unpack_from('<I', d, 0x10 + 4 * t)[0]
        if not off: continue
        assert d[off:off+3] == b'TRK'
        rl = []
        for r in range(revs):
            idx, n, doff = struct.unpack_from('<III', d, off + 4 + 12 * r)
            fl, acc = [], 0
            for i in range(n):
                v = struct.unpack_from('>H', d, off + doff + 2 * i)[0]
                if v == 0: acc += 65536; continue
                fl.append((acc + v) * tick); acc = 0
            rl.append(fl)
        tracks[t] = rl
    return tracks

def decode(fl, cell=2000.0):
    # simple PLL: returns bit cells (0/1 list) and for each 1 the deviation (ns) of its interval
    bits, devs = [], []
    clk = cell
    for iv in fl:
        n = max(2, min(4, round(iv / clk)))       # MFM: 2, 3 or 4 cells
        dev = iv - n * clk
        clk += 0.05 * dev / n                      # slow frequency tracking
        clk = min(max(clk, cell * 0.9), cell * 1.1)
        bits += [0] * (n - 1) + [1]
        devs.append((len(bits), abs(dev), n))
    return bits, devs

def sectors(fl):
    bits, devs = decode(fl)
    # bit position -> deviation of the transition there
    dv = {p: (d, n) for p, d, n in devs}
    s = ''.join(map(str, bits))
    SYNC = '0100010010001001'   # A1 with missing clock
    out, i, idam = [], 0, None
    def byte_at(p):
        v = 0
        for k in range(8): v = v << 1 | int(s[p + 2 * k + 1])
        return v
    def quality(a, b):
        ds = [dv[p][0] for p in range(a, b) if p in dv]
        return (max(ds) if ds else 0, sum(ds) / len(ds) if ds else 0)
    while True:
        i = s.find(SYNC * 3, i)
        if i < 0: break
        p = i + 48
        mark = byte_at(p)
        if mark == 0xFE:
            hdr = [byte_at(p + 16 * k) for k in range(7)]
            ok = crc16(bytes([0xA1] * 3 + hdr[:5])) == hdr[5] << 8 | hdr[6]
            idam = (hdr[0], hdr[1], hdr[2], ok, quality(i, p + 16 * 7))
            i = p + 16 * 7
        elif mark == 0xFB and idam:
            data = [byte_at(p + 16 * k) for k in range(515)]
            ok = crc16(bytes([0xA1] * 3 + data[:513])) == data[513] << 8 | data[514]
            out.append((idam, ok, quality(i, p + 16 * 515)))
            idam = None
            i = p + 16 * 515
        else:
            i = p
    return out

if __name__ == "__main__":
  tracks = load(sys.argv[1])
  for t, revs in sorted(tracks.items()):
    print("== track %d side %d" % (t // 2, t % 2))
    for r, fl in enumerate(revs):
        line = []
        for (c, h, sec, idok, (imx, imn)), dok, (mx, mn) in sectors(fl):
            line.append("%d%s%s(max %d mean %d)" % (sec, "" if idok else "!ID", "" if dok else "!CRC", mx, mn))
        print(" rev %d: %s" % (r, "  ".join(line)))
