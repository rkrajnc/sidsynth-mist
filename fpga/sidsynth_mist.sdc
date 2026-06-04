# SIDsynth - timing constraints
#
# Input clocks present on MiST: CLOCK_27 (27 MHz), CLOCK_32 (32 MHz),
# CLOCK_50 (50 MHz). v1 uses CLOCK_27[0] driving a PLL to a 54 MHz sys
# clock (M=12, N=1, C0=6; VCO=324 MHz). 54 MHz is exactly 54x the SID
# ce_1m strobe (1.000 MHz, no drift).


# time format
set_time_format -unit ns -decimal_places 3


# input clocks
create_clock -name clk_27_0 -period 37.037 [get_ports {CLOCK_27[0]}]
create_clock -name clk_27_1 -period 37.037 [get_ports {CLOCK_27[1]}]
create_clock -name clk_32_0 -period 31.250 [get_ports {CLOCK_32[0]}]
create_clock -name clk_32_1 -period 31.250 [get_ports {CLOCK_32[1]}]
create_clock -name clk_50_0 -period 20.000 [get_ports {CLOCK_50[0]}]
create_clock -name clk_50_1 -period 20.000 [get_ports {CLOCK_50[1]}]
create_clock -name spi_clk  -period 40.000 [get_ports {SPI_SCK}]


# PLL-generated clocks (sys_clk = 54 MHz on c0)
derive_pll_clocks
derive_clock_uncertainty


# group asynchronous domains
#  - sys_clk (54 MHz, pll c0)
#  - clk_pix (25.2 MHz VGA dot clock, pll_pix c0) -- async to sys_clk
#  - spi_clk (ARM SPI link; user_io/osd cross into sys/pix internally)
set_clock_groups -asynchronous \
  -group [get_clocks {pll_inst|altpll_component|auto_generated|pll1|clk[0]}] \
  -group [get_clocks {pll_pix_inst|altpll_component|auto_generated|pll1|clk[0]}] \
  -group [get_clocks {spi_clk}]


# false paths on slow IO (no timing-critical interface in v1)
set_false_path -from * -to [get_ports {LED}]
set_false_path -from * -to [get_ports {UART_TX}]
set_false_path -from [get_ports {UART_RX}] -to *
set_false_path -from * -to [get_ports {VGA_*}]
set_false_path -from * -to [get_ports {AUDIO_L}]
set_false_path -from * -to [get_ports {AUDIO_R}]


# JTAG
set ports [get_ports -nowarn {altera_reserved_tck}]
if {[get_collection_size $ports] == 1} {
  create_clock -name tck -period 100.000 [get_ports {altera_reserved_tck}]
  set_clock_groups -exclusive -group altera_reserved_tck
  set_output_delay -clock tck 20 [get_ports altera_reserved_tdo]
  set_input_delay  -clock tck 20 [get_ports altera_reserved_tdi]
  set_input_delay  -clock tck 20 [get_ports altera_reserved_tms]
  set_false_path -from *                              -to [get_ports altera_reserved_tdo]
  set_false_path -from [get_ports altera_reserved_tms] -to *
  set_false_path -from [get_ports altera_reserved_tdi] -to *
}
