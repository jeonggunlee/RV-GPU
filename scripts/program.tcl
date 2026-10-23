# Explicit make program only; no SPI flash programming.
open_hw_manager
connect_hw_server
open_hw_target
set devices [get_hw_devices -filter {PART =~ "xc7a200t*"}]
if {[llength $devices] != 1} {error "Expected exactly one XC7A200T device"}
set dev [lindex $devices 0]
current_hw_device $dev
set_property PROGRAM.FILE [file normalize build/a7_simt_gpu.bit] $dev
program_hw_devices $dev
close_hw_manager
