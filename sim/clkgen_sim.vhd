-- Simulation stand-in for hdl/clkgen_dcm.vhd: passes the clock through, so
-- the testbenches drive the core clock directly.
library ieee;
use ieee.std_logic_1164.all;

entity clkgen is
  generic (
    CLK_MUL : positive := 6;
    CLK_DIV : positive := 5);
  port (
    clk_in  : in  std_logic;
    clk_out : out std_logic;
    locked  : out std_logic);
end entity;

architecture sim of clkgen is
begin
  clk_out <= clk_in;
  locked  <= '1';
end architecture;
