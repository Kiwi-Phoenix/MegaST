#!/usr/bin/env bash
# GHDL test of floppy/m65_floppy_port.vhd and floppy/floppy_probe.vhd (internal floppy drive, phase 0).
# Needs GHDL (e.g. from the OSS CAD Suite).
# Usage: ./run.sh
set -e
cd "$(dirname "$0")"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
# the LLVM build of GHDL links with -lz: provide libz.so if only libz.so.1 is installed
mkdir -p "$W/lib"
for z in /lib/x86_64-linux-gnu/libz.so.1 /usr/lib/libz.so.1; do [ -e "$z" ] && ln -sf "$z" "$W/lib/libz.so" && break; done
ghdl -a --std=08 --workdir="$W" ../../vhdl/floppy/m65_floppy_port.vhd ../../vhdl/floppy/floppy_probe.vhd tb_floppy_port.vhd
if ghdl --version | grep -q mcode; then
   ghdl --elab-run --std=08 --workdir="$W" tb_floppy_port --assert-level=error
else
   ghdl -e --std=08 --workdir="$W" -Wl,-L"$W/lib" -o "$W/tb" tb_floppy_port
   "$W/tb" --assert-level=error
fi
