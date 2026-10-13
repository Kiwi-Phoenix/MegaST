#!/usr/bin/env bash
# Replays a real flux capture into the floppy controller (WF1772IP, clock enable version) and reads every
# sector of the track (tb_flux_replay.vhd). Needs GHDL (e.g. from the OSS CAD Suite) and python3.
# Usage: ./run_flux_replay.sh <capture.scp> <cylinder> <head> <image.st> [pulse_ns]
#   capture.scp: e.g. gw read --tracks c=3:h=1 --revs 5 capture.scp (Greaseweazle)
#   image.st:    the disk image the capture was written from (10 sectors per track)
set -e
cd "$(dirname "$0")"
D=$(pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
python3 -I "$D/scp2txt.py" "$1" "$2" "$3" "$4" "$W"
F="--std=08 -fsynopsys -frelaxed --workdir=$W -P$W"
for f in pkg am_detector control crc_logic digital_pll registers transceiver top_soc; do
   ghdl -a $F --work=wf_ce ../../vhdl/floppy/wf1772ip/wf1772ip_$f.vhd
done
ghdl -a $F tb_flux_replay.vhd
cd "$W"
# the IP's arithmetic warns about 'U' operands before the reset: filter these warnings
ghdl --elab-run $F tb_flux_replay -gG_TRACK="$2" ${5:+-gG_PULSE="$5 ns"} --assert-level=error 2>&1 \
   | grep -v "std_logic_arith\|^$"
