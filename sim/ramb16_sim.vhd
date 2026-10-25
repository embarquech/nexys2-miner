-- Simulation model of the Spartan-3E RAMB16_S36_S36 block RAM, for GHDL
-- (XST uses the primitive): 512 x 32 dual port, both ports on one clock,
-- parity bits ignored, write modes as in the Xilinx library.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity RAMB16_S36_S36 is
  generic (
    WRITE_MODE_A : string := "WRITE_FIRST";
    WRITE_MODE_B : string := "WRITE_FIRST");
  port (
    DOA   : out std_logic_vector(31 downto 0);
    DOB   : out std_logic_vector(31 downto 0);
    DOPA  : out std_logic_vector(3 downto 0);
    DOPB  : out std_logic_vector(3 downto 0);
    ADDRA : in  std_logic_vector(8 downto 0);
    ADDRB : in  std_logic_vector(8 downto 0);
    CLKA  : in  std_logic;
    CLKB  : in  std_logic;
    DIA   : in  std_logic_vector(31 downto 0);
    DIB   : in  std_logic_vector(31 downto 0);
    DIPA  : in  std_logic_vector(3 downto 0);
    DIPB  : in  std_logic_vector(3 downto 0);
    ENA   : in  std_logic;
    ENB   : in  std_logic;
    SSRA  : in  std_logic;
    SSRB  : in  std_logic;
    WEA   : in  std_logic;
    WEB   : in  std_logic);
end entity;

architecture sim of RAMB16_S36_S36 is
  type mem_t is array (0 to 511) of std_logic_vector(31 downto 0);
begin
  DOPA <= (others => '0');
  DOPB <= (others => '0');

  process (CLKA)
    variable mem : mem_t := (others => (others => '0'));
    variable ia, ib : natural;
    variable olda, oldb : std_logic_vector(31 downto 0);
  begin
    if rising_edge(CLKA) then
      ia := to_integer(unsigned(ADDRA));
      ib := to_integer(unsigned(ADDRB));
      olda := mem(ia);
      oldb := mem(ib);
      if ENA = '1' and WEA = '1' then
        mem(ia) := DIA;
      end if;
      if ENB = '1' and WEB = '1' then
        mem(ib) := DIB;
      end if;
      if ENA = '1' then
        if WEA = '0' or WRITE_MODE_A = "READ_FIRST" then
          DOA <= olda;
        elsif WRITE_MODE_A = "WRITE_FIRST" then
          DOA <= DIA;
        end if;
      end if;
      if ENB = '1' then
        if WEB = '0' or WRITE_MODE_B = "READ_FIRST" then
          DOB <= oldb;
        elsif WRITE_MODE_B = "WRITE_FIRST" then
          DOB <= DIB;
        end if;
      end if;
    end if;
  end process;
end architecture;
