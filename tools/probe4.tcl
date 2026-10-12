# Floppy drive probe (USER4, 224 bits, CORE/vhdl/floppy/floppy_probe.vhd).
# CMD: optional commands (hex, 24 bits, bits 15..8 = A5, separated by spaces) sent first, e.g. CMD=00A503 =
# motor on, select A; CMD="00A500 00A513" re-arms the motor watchdog first.
# N: number of reads (default 10), DELAY: ms between reads (default 250). Decode with decode4.py.
set n     [expr {[info exists ::env(N)] ? $::env(N) : 10}]
set delay [expr {[info exists ::env(DELAY)] ? $::env(DELAY) : 250}]
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target -jtag_mode on
if {[info exists ::env(CMD)]} {
  foreach c $::env(CMD) {
    scan_ir_hw_jtag 6 -tdi 23
    scan_dr_hw_jtag 224 -tdi "[string repeat 0 50][format %06X [expr {"0x$c"}]]"
    puts "C $c"
    after 100
  }
}
for {set i 0} {$i < $n} {incr i} {
  scan_ir_hw_jtag 6 -tdi 23
  puts "F [scan_dr_hw_jtag 224 -tdi [string repeat 0 56]]"
  after $delay
}
close_hw_target
