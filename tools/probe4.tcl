# Floppy drive probe (USER4, 336 bits: CORE/vhdl/floppy/floppy_probe.vhd, command log of wd1772_m65.v,
# flux capture status of flux_capture.vhd).
# CMD: optional commands (hex, 24 bits, bits 15..8 = A5, separated by spaces) sent first, e.g. CMD=00A503 =
# motor on, select A; CMD="00A500 00A513" re-arms the motor watchdog first.
# N: number of reads (default 10), DELAY: ms between reads (default 250).
# LOG=1: instead dump the command log of the real floppy controller (256 entries).
# FLUX=arm: start a flux capture (128 KB of the drive's flux, about 3 revolutions of the track under the head).
# FLUX=dump: read the capture buffer (line "B <hex>", one scan, ~20 s); convert with tools/flux2scp.py.
# Decode with decode4.py.
set n     [expr {[info exists ::env(N)] ? $::env(N) : 10}]
set delay [expr {[info exists ::env(DELAY)] ? $::env(DELAY) : 250}]
set bits  336
set zeros [string repeat 0 [expr {$bits / 4}]]
proc cmd {c} {
  global bits
  scan_ir_hw_jtag 6 -tdi 23
  scan_dr_hw_jtag $bits -tdi "[string repeat 0 [expr {$bits / 4 - 6}]][format %06X [expr {"0x$c"}]]"
}
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target -jtag_mode on
if {[info exists ::env(CMD)]} {
  foreach c $::env(CMD) {
    cmd $c
    puts "C $c"
    after 100
  }
}
if {[info exists ::env(FLUX)] && $::env(FLUX) eq "arm"} {
  cmd 00C301
  puts "C 00C301"
} elseif {[info exists ::env(FLUX)] && $::env(FLUX) eq "dump"} {
  scan_ir_hw_jtag 6 -tdi 23
  set snap [scan_dr_hw_jtag $bits -tdi $zeros]
  puts "F $snap"
  # bits 321..304: bytes captured
  set v "0x$snap"
  set count [expr {($v >> 304) & 0x3FFFF}]
  puts "N $count"
  # one scan for the whole buffer: each scan loses the byte it has loaded last (mega65.vhd, fx_byte)
  cmd 00C302
  scan_ir_hw_jtag 6 -tdi 23
  set nbits [expr {$count * 8}]
  puts "B [scan_dr_hw_jtag $nbits -tdi [string repeat 0 [expr {$nbits / 4}]]]"
  cmd 00C300
} elseif {[info exists ::env(LOG)]} {
  for {set i 0} {$i < 256} {incr i} {
    cmd [format 005A%02X $i]
    scan_ir_hw_jtag 6 -tdi 23
    puts "F [scan_dr_hw_jtag $bits -tdi $zeros]"
  }
} else {
  for {set i 0} {$i < $n} {incr i} {
    scan_ir_hw_jtag 6 -tdi 23
    puts "F [scan_dr_hw_jtag $bits -tdi $zeros]"
    after $delay
  }
}
close_hw_target
