#!/usr/bin/env python3
# scp2txt.py <scp> <cyl> <head> <st image> <outdir>: writes flux.txt (one interval in ns per line, 'I' at
# each index, all captured revolutions) and expect.txt (the 10 x 512 sector bytes of the image, hex)
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scp_mfm import load
scp, cyl, head, img, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
revs = load(scp)[cyl * 2 + head]
with open(os.path.join(out, 'flux.txt'), 'w') as f:
    for fl in revs:
        f.write('I\n')
        for iv in fl: f.write('%d\n' % iv)
d = open(img, 'rb').read()
off = (cyl * 2 + head) * 10 * 512
with open(os.path.join(out, 'expect.txt'), 'w') as f:
    for b in d[off:off + 5120]: f.write('%02X\n' % b)
print(sum(len(r) for r in revs), "intervals,", len(revs), "revolutions")
