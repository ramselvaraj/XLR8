# XLR8 PYNQ-Z2 build.
#   vivado -mode batch -source fpga/pynq_z2/build.tcl -tclargs [options]
# Options (key value pairs, any order):
#   board_repo <dir>   folder containing pynq-z2/A.0/board.xml
#                      (default: $env(XLR8_BOARD_REPO), else the rv32-linux copy)
#   until <stage>      bd | synth | impl | bit   (default bit)
#   fclk <MHz>         PL clock from FCLK_CLK0   (default 50)
#   slverr <0|1>       xlr8_regs SLVERR_EN       (default 0: an SLVERR kills the accessing process on the ARM)
#   tag <name>         suffix for reports in results/ (default <fclk>mhz)
set root [file normalize [file dirname [info script]]/../..]

array set opt [list \
  board_repo [expr {[info exists ::env(XLR8_BOARD_REPO)] ? $::env(XLR8_BOARD_REPO) : "/mnt/windows/Users/ramse/linux_projects/rv32-linux/build/fpga/board_repo"}] \
  until bit fclk 50 slverr 0 tag ""]
foreach {k v} $argv { set opt($k) $v }
if {$opt(tag) eq ""} { set opt(tag) "$opt(fclk)mhz" }

set bdir $root/build/fpga/xlr8_$opt(tag)
set out  $root/build/fpga/out_$opt(tag)
set rpt  $root/results
file mkdir $out
file delete -force $bdir

set_param board.repoPaths [list $opt(board_repo)]
create_project xlr8 $bdir -part xc7z020clg400-1
set_property board_part tul.com.tw:pynq-z2:part0:1.0 [current_project]

# ---- RTL
set rtl [list]
foreach f [split [string trim [read [open $root/rtl/gpu/files.txt]]] "\n"] {
  if {![string match *tb_* $f]} { lappend rtl $root/$f }
}
foreach f [split [string trim [read [open $root/rtl/axi/files.txt]]] "\n"] { lappend rtl $root/$f }
add_files $rtl
set_property file_type SystemVerilog [get_files *.sv]
update_compile_order -fileset sources_1

# ---- block design
create_bd_design system
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps
set_property -dict [list \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $opt(fclk) \
  CONFIG.PCW_USE_M_AXI_GP0 1 \
  CONFIG.PCW_USE_S_AXI_HP0 1 CONFIG.PCW_S_AXI_HP0_DATA_WIDTH 32 \
  CONFIG.PCW_USE_FABRIC_INTERRUPT 1 CONFIG.PCW_IRQ_F2P_INTR 1 \
  CONFIG.PCW_EN_CLK0_PORT 1 CONFIG.PCW_EN_RST0_PORT 1] $ps

set x [create_bd_cell -type module -reference xlr8_top xlr8]
set_property -dict [list CONFIG.SLVERR_EN $opt(slverr)] $x

set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect ic_ctrl]
set_property -dict [list CONFIG.NUM_MI 1 CONFIG.NUM_SI 1] $ic
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst0]

connect_bd_net [get_bd_pins $ps/FCLK_CLK0] \
  [get_bd_pins $ps/M_AXI_GP0_ACLK] [get_bd_pins $ps/S_AXI_HP0_ACLK] \
  [get_bd_pins $x/aclk] [get_bd_pins $rst/slowest_sync_clk] \
  [get_bd_pins $ic/ACLK] [get_bd_pins $ic/S00_ACLK] [get_bd_pins $ic/M00_ACLK]
connect_bd_net [get_bd_pins $ps/FCLK_RESET0_N] [get_bd_pins $rst/ext_reset_in]
connect_bd_net [get_bd_pins $rst/peripheral_aresetn] \
  [get_bd_pins $x/aresetn] [get_bd_pins $ic/ARESETN] \
  [get_bd_pins $ic/S00_ARESETN] [get_bd_pins $ic/M00_ARESETN]

connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_GP0] [get_bd_intf_pins $ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $ic/M00_AXI]   [get_bd_intf_pins $x/s_axi_ctrl]
connect_bd_intf_net [get_bd_intf_pins $x/m_axi]      [get_bd_intf_pins $ps/S_AXI_HP0]
# IRQ_F2P[0] (SPI 29) is taken by PYNQ's own generic-uio node, so XLR8 uses IRQ_F2P[1] (SPI 30)
set cc [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat irq_cc]
set zero [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant irq_zero]
set_property -dict [list CONFIG.NUM_PORTS 2] $cc
set_property -dict [list CONFIG.CONST_WIDTH 1 CONFIG.CONST_VAL 0] $zero
connect_bd_net [get_bd_pins $zero/dout] [get_bd_pins $cc/In0]
connect_bd_net [get_bd_pins $x/irq] [get_bd_pins $cc/In1]
connect_bd_net [get_bd_pins $cc/dout] [get_bd_pins $ps/IRQ_F2P]

assign_bd_address
# registers at a fixed address, 8 KiB (13-bit space). PYNQ's base device tree already owns
# 0x40000000-0x4000FFFF (generic-uio), so XLR8 lives just above it.
set_property offset 0x40010000 [get_bd_addr_segs -of_objects [get_bd_addr_spaces $ps/Data] -filter {NAME =~ *xlr8*}]
set_property range 8K          [get_bd_addr_segs -of_objects [get_bd_addr_spaces $ps/Data] -filter {NAME =~ *xlr8*}]
puts "ADDRESS MAP:"
foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces $ps/Data]] {
  puts "  $s offset [get_property OFFSET $s] range [get_property RANGE $s]"
}
foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces $x/m_axi]] {
  puts "  GPU master: $s offset [get_property OFFSET $s] range [get_property RANGE $s]"
}
validate_bd_design
save_bd_design
make_wrapper -files [get_files $bdir/xlr8.srcs/sources_1/bd/system/system.bd] -top
add_files -norecurse $bdir/xlr8.gen/sources_1/bd/system/hdl/system_wrapper.v
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1
if {$opt(until) eq "bd"} { puts "BD OK"; exit 0 }

# ---- implementation
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }
if {$opt(until) eq "synth"} { exit 0 }
launch_runs impl_1 -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }
open_run impl_1
report_timing_summary -delay_type min_max -max_paths 10 -file $rpt/timing_$opt(tag).rpt
report_utilization -file $rpt/utilization_$opt(tag).rpt
report_clock_utilization -file $rpt/clocks_$opt(tag).rpt
report_drc -file $rpt/drc_$opt(tag).rpt
report_methodology -file $rpt/methodology_$opt(tag).rpt
report_timing -sort_by group -max_paths 3 -path_type full -file $rpt/worst_paths_$opt(tag).rpt
if {$opt(until) eq "impl"} { exit 0 }
close_design
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
write_hw_platform -fixed -force $out/xlr8.xsa
file copy -force $bdir/xlr8.runs/impl_1/system_wrapper.bit $out/xlr8.bit
file copy -force [glob $bdir/xlr8.gen/sources_1/bd/system/hw_handoff/*.hwh] $out/xlr8.hwh
puts "BITSTREAM: $out/xlr8.bit"
