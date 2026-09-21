# n1_bd.tcl -- block design for stage N1: Zynq PS + n1_top over M_AXI_GP0
#
#   vivado -mode batch -source fpga/n1_bd.tcl          (run from repo root)
#
# Produces build/n1/n1.xsa for Vitis and a bitstream. Project mode, because block
# designs need one; everything is created fresh each run so nothing stale is reused.
#
# FCLK_CLK0 is requested at 66.67 MHz. The fabric's measured ceiling is 73.6 MHz
# (design spec 12.3); the PS derives FCLK by integer division from the IO PLL, so
# 70 MHz is not exactly available and 71.4 MHz leaves too little margin.
set part    xc7z020clg484-1
set proj    n1
set outdir  build/n1
set noc_base 0x43C00000          ;# must match NOC_BASE in sw/noc_bridge.h

# A project left open from a previous run locks build/n1; close it first.
if {[llength [get_projects -quiet]]} { close_project }
file delete -force $outdir
create_project $proj $outdir -part $part
set_property board_part avnet.com:zedboard:part0:1.4 [current_project]

add_files -norecurse [list \
  rtl/noc_pkg.sv rtl/rr_arbiter.sv rtl/sync_fifo.sv rtl/skid_reg.sv rtl/bram_sdp.sv \
  rtl/endpoint_port.sv rtl/route_decode.sv rtl/output_port_ctrl.sv rtl/noc_switch.sv \
  rtl/memory_adapter.sv rtl/noc_top.sv rtl/fwd_table.sv rtl/axil_noc_bridge.sv \
  fpga/ep_traffic.sv fpga/n1_top.sv ]
# Module references can't have a SystemVerilog top; wrap with a Verilog shim.
set shim [file normalize $outdir/n1_top_wrap.v]
set fh [open $shim w]
puts $fh {// Verilog-2001 wrapper: BD module references need a Verilog top.
module n1_top_wrap (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET rst_n" *)
  input clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input rst_n,
  input  [7:0]  s_axi_awaddr,  input  s_axi_awvalid, output s_axi_awready,
  input  [31:0] s_axi_wdata,   input  [3:0] s_axi_wstrb,
  input  s_axi_wvalid,         output s_axi_wready,
  output [1:0]  s_axi_bresp,   output s_axi_bvalid,  input  s_axi_bready,
  input  [7:0]  s_axi_araddr,  input  s_axi_arvalid, output s_axi_arready,
  output [31:0] s_axi_rdata,   output [1:0] s_axi_rresp,
  output s_axi_rvalid,         input  s_axi_rready,
  input  [1:0]  sw,            output [7:0] led);
  n1_top u (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .sw(sw), .led(led));
endmodule}
close $fh
add_files -norecurse $shim
read_xdc fpga/n1.xdc
update_compile_order -fileset sources_1

create_bd_design n1
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps
set_property -dict [list CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {66.67} \
                         CONFIG.PCW_USE_M_AXI_GP0 {1}] $ps

set noc [create_bd_cell -type module -reference n1_top_wrap noc]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
  -config {Master "/ps7/M_AXI_GP0" Clk "Auto"} [get_bd_intf_pins noc/s_axi]

create_bd_port -dir I -from 1 -to 0 sw
create_bd_port -dir O -from 7 -to 0 led
connect_bd_net [get_bd_ports sw]  [get_bd_pins noc/sw]
connect_bd_net [get_bd_ports led] [get_bd_pins noc/led]

assign_bd_address

# Pin the bridge address so software and hardware agree. Automation picked
# 0x40000000 on the first run, which would not have matched the C header.
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data] -filter {NAME =~ *noc*}]
if {[llength $seg] == 1} {
  set_property offset $noc_base $seg
  set_property range  4K        $seg
} else {
  puts "WARNING: could not find a unique NoC address segment (found: $seg)"
}
foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data]] {
  puts "ADDRESS: $s  offset=[get_property OFFSET $s]  range=[get_property RANGE $s]"
}

validate_bd_design
save_bd_design

make_wrapper -files [get_files $outdir/$proj.srcs/sources_1/bd/n1/n1.bd] -top
add_files -norecurse $outdir/$proj.gen/sources_1/bd/n1/hdl/n1_wrapper.v
set_property top n1_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
report_timing_summary -file $outdir/timing.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "================ N1 WNS = $wns ns ================"
write_hw_platform -fixed -include_bit -force $outdir/n1.xsa
puts "XSA: $outdir/n1.xsa"