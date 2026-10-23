# Microphase A7-Lite 200T, XC7A200T-FBG484-2, 50 MHz.
# Manufacturer A7-Lite Reference Manual: clock, USB UART, LED tables.
set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -name sys_clk -period 20.000 [get_ports clk]
set_property -dict {PACKAGE_PIN V2 IOSTANDARD LVCMOS33} [get_ports uart_tx]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
# Asynchronous serial output and status LEDs have no external synchronous clock.
set_false_path -to [get_ports {uart_tx led[*]}]
