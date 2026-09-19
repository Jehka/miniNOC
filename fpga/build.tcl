# build.tcl -- Vivado non-project flow for zed_top
#   vivado -mode batch -source fpga/build.tcl            (run from repo root)
#   vivado -mode batch -source fpga/build.tcl -tclargs ila   (insert ILA on mark_debug nets)
set part   xc7z020clg484-1
set outdir build/vivado
file mkdir $outdir
set use_ila [expr {[llength $argv] > 0 && [lindex $argv 0] eq "ila"}]

read_verilog -sv {
  rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/sync_fifo.sv rtl/skid_reg.sv rtl/bram_sdp.sv
  rtl/endpoint_port.sv rtl/route_decode.sv rtl/output_port_ctrl.sv
  rtl/noc_switch.sv rtl/memory_adapter.sv rtl/noc_top.sv
  fpga/ep_traffic.sv fpga/zed_top.sv
}
read_xdc fpga/zedboard.xdc
set_property verilog_define SYNTHESIS [current_fileset]

synth_design -top zed_top -part $part -verilog_define SYNTHESIS
report_utilization -hierarchical -hierarchical_depth 3 -file $outdir/util_synth.rpt

# Build provenance: if either count is 0, Vivado read an older rtl/ and any
# timing report from this run describes the wrong netlist.
puts "SKID PRESENT: [llength [get_cells -hier -filter {NAME =~ *u_skid*}]] input slices"
puts "MEM SKID    : [llength [get_cells -hier -filter {NAME =~ *u_mem_req_skid*}]] cells"
puts "SOURCE DIR  : [pwd]" 

if {$use_ila} {
  set nets [get_nets -hier -filter {MARK_DEBUG == 1}]
  create_debug_core u_ila ila
  set_property C_DATA_DEPTH 4096 [get_debug_cores u_ila]
  set_property port_width 1 [get_debug_ports u_ila/clk]
  connect_debug_port u_ila/clk [get_nets GCLK_IBUF_BUFG]
  set_property port_width [llength $nets] [get_debug_ports u_ila/probe0]
  connect_debug_port u_ila/probe0 $nets
  implement_debug_core
  write_debug_probes -force $outdir/zed_top.ltx
}

opt_design
place_design
phys_opt_design
route_design
report_timing_summary -max_paths 20 -file $outdir/timing.rpt
report_utilization -file $outdir/util_impl.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $outdir/util_hier.rpt
write_bitstream -force $outdir/zed_top.bit

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "================ WNS @100 MHz = $wns ns ================"
if {$wns < 0} { puts "TIMING NOT MET -- see $outdir/timing.rpt" }
