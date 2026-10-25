-- Core clock: the 50 MHz board oscillator through a DCM_SP frequency
-- synthesizer, clk_in * CLK_MUL / CLK_DIV. Synthesis only; sim/clkgen_sim.vhd
-- stands in for it in GHDL, which has no UNISIM library.
library ieee;
use ieee.std_logic_1164.all;
library unisim;
use unisim.vcomponents.all;

entity clkgen is
  generic (
    CLK_MUL : positive := 6;
    CLK_DIV : positive := 5);
  port (
    clk_in  : in  std_logic;                       -- 50 MHz pin
    clk_out : out std_logic;
    locked  : out std_logic);
end entity;

architecture xilinx of clkgen is
  signal clk_ibuf, clk_fx : std_logic;
begin
  ibuf : IBUFG port map (I => clk_in, O => clk_ibuf);

  dcm : DCM_SP
    generic map (
      CLKIN_PERIOD       => 20.0,
      CLKFX_MULTIPLY     => CLK_MUL,
      CLKFX_DIVIDE       => CLK_DIV,
      CLK_FEEDBACK       => "NONE",
      DFS_FREQUENCY_MODE => "LOW",
      STARTUP_WAIT       => false)
    port map (
      CLKIN  => clk_ibuf,
      CLKFB  => '0',
      RST    => '0',
      DSSEN  => '0',
      PSCLK  => '0',
      PSEN   => '0',
      PSINCDEC => '0',
      CLKFX  => clk_fx,
      LOCKED => locked);

  bufg_fx : BUFG port map (I => clk_fx, O => clk_out);
end architecture;
