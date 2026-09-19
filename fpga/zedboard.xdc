## ZedBoard (xc7z020clg484-1) -- Mini-NoC self-test
## Bank 13/33 are 3.3 V. Banks 34/35 follow the VADJ jumper (J18): LVCMOS18 matches the
## Digilent master XDC default. Change to LVCMOS25 if your J18 is set to 2.5 V.

# Board oscillator. The fabric runs at 70 MHz from the MMCM; Vivado derives
# that clock automatically, so do not constrain it here.
create_clock -period 10.000 -name gclk [get_ports GCLK]
set_property -dict {PACKAGE_PIN Y9  IOSTANDARD LVCMOS33} [get_ports GCLK]

set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS18} [get_ports BTNC]

set_property -dict {PACKAGE_PIN F22 IOSTANDARD LVCMOS18} [get_ports {SW[0]}]
set_property -dict {PACKAGE_PIN G22 IOSTANDARD LVCMOS18} [get_ports {SW[1]}]
set_property -dict {PACKAGE_PIN H22 IOSTANDARD LVCMOS18} [get_ports {SW[2]}]
set_property -dict {PACKAGE_PIN F21 IOSTANDARD LVCMOS18} [get_ports {SW[3]}]
set_property -dict {PACKAGE_PIN H19 IOSTANDARD LVCMOS18} [get_ports {SW[4]}]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS18} [get_ports {SW[5]}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS18} [get_ports {SW[6]}]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS18} [get_ports {SW[7]}]

set_property -dict {PACKAGE_PIN T22 IOSTANDARD LVCMOS33} [get_ports {LD[0]}]
set_property -dict {PACKAGE_PIN T21 IOSTANDARD LVCMOS33} [get_ports {LD[1]}]
set_property -dict {PACKAGE_PIN U22 IOSTANDARD LVCMOS33} [get_ports {LD[2]}]
set_property -dict {PACKAGE_PIN U21 IOSTANDARD LVCMOS33} [get_ports {LD[3]}]
set_property -dict {PACKAGE_PIN V22 IOSTANDARD LVCMOS33} [get_ports {LD[4]}]
set_property -dict {PACKAGE_PIN W22 IOSTANDARD LVCMOS33} [get_ports {LD[5]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {LD[6]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {LD[7]}]

## asynchronous user inputs are synchronised in RTL
set_false_path -from [get_ports {BTNC SW[*]}]
set_false_path -to   [get_ports {LD[*]}]
