# Floppy drive probe (USER4, 304 bits: CORE/vhdl/floppy/floppy_probe.vhd + command log of wd1772_m65.v).
# CMD: optional commands (hex, 24 bits, bits 15..8 = A5, separated by spaces) sent first, e.g. CMD=00A503 =
# motor on, select A; CMD="00A500 00A513" re-arms the motor watchdog first.
# N: number of reads (default 10), DELAY: ms between reads (default 250).
# LOG=1: instead dump the command log of the real floppy controller (256 entries).
# Decode with decode4.py.
set n     [expr {[info exists ::env(N)] ? $::env(N) : 10}]
set delay [expr {[info exists ::env(DELAY)] ? $::env(DELAY) : 250}]
set bits  304
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
if {[info exists ::env(LOG)]} {
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
