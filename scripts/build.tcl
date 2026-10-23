set root [file dirname [file dirname [file normalize [info script]]]]
cd $root
file mkdir build
set_param general.maxThreads 4
read_verilog -sv [glob rtl/*.v rtl/*.sv]
read_xdc constraints/a7_lite_200t.xdc
synth_design -top a7_gpu_top -part xc7a200tfbg484-2
write_checkpoint -force build/a7_simt_gpu_synth.dcp
# Keep synchronous BRAM enables. Default power optimization creates look-ahead
# host-read enables with async reset fan-in (REQP-1839 in Vivado 2022.1).
opt_design -directive NoBramPowerOpt
place_design
phys_opt_design
route_design
report_timing_summary -file build/simt_timing.rpt
report_utilization -file build/simt_utilization.rpt
report_drc -file build/simt_drc.rpt
write_checkpoint -force build/a7_simt_gpu_routed.dcp
set worst [get_timing_paths -delay_type min_max -max_paths 1]
if {[llength $worst] == 0} {error "No timed paths found"}
if {[get_property SLACK $worst] < 0} {error "Timing failed; see build/simt_timing.rpt"}
write_bitstream -force build/a7_simt_gpu.bit
