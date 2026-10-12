#!/usr/bin/env bash
# GHDL equivalence test of the WF1772IP clock enable conversion (CORE/vhdl/floppy/wf1772ip/README.md):
# the original IP on 16 MHz and the converted IP on 32 MHz with CE, same CPU accesses, same drive model.
# Needs GHDL (e.g. from the OSS CAD Suite). Takes about 10 minutes with the mcode backend.
# Usage: ./run_wf1772.sh
set -e
cd "$(dirname "$0")"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
F="--std=08 -fsynopsys -frelaxed --workdir=$W -P$W"
ORDER="pkg am_detector control crc_logic digital_pll registers transceiver top_soc"
for f in $ORDER; do
   ghdl -a $F --work=wf_orig ../../vhdl/floppy/wf1772ip/orig/wf1772ip_$f.vhd
   ghdl -a $F --work=wf_ce   ../../vhdl/floppy/wf1772ip/wf1772ip_$f.vhd
done
ghdl -a $F floppy_model.vhd tb_wf1772_ce.vhd
# the IP's arithmetic warns about 'U' operands before the reset: filter these warnings
ghdl --elab-run $F tb_wf1772_ce --assert-level=error 2>&1 | grep -v "std_logic_arith\|^$"
test "${PIPESTATUS[0]}" -eq 0
