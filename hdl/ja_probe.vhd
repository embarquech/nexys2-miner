-- Wiring probe for Pmod JA: latches every signal pin that ever goes low (a
-- UART start bit) and shows them on the 7-segment display, one digit per
-- top-row pin: digit 3 = pin 1, 2 = pin 2, 1 = pin 3, 0 = pin 4, showing the
-- pin number when active and "-" otherwise. LD0-LD3 do the same for pins
-- 7-10 of the bottom row. BTN0 clears. All pins are inputs with pull-ups,
-- so nothing on the ESP32 side can be driven against.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ja_probe is
  port (
    clk50 : in  std_logic;
    Ja    : in  std_logic_vector(7 downto 0);   -- pins 1,2,3,4,7,8,9,10
    Btn   : in  std_logic_vector(3 downto 0);
    Seg   : out std_logic_vector(7 downto 0);
    An    : out std_logic_vector(3 downto 0);
    Led   : out std_logic_vector(3 downto 0));
end entity;

architecture rtl of ja_probe is
  signal s1, s2  : std_logic_vector(7 downto 0) := (others => '1');
  signal seen    : std_logic_vector(7 downto 0) := (others => '0');
  signal div     : unsigned(17 downto 0) := (others => '0');
  signal digit   : unsigned(1 downto 0);

  function glyph(active : std_logic; n : natural) return std_logic_vector is
  begin
    if active = '0' then
      return "10111111";                          -- "-"
    end if;
    case n is                                     -- DP off, gfedcba active low
      when 1 => return "11111001";
      when 2 => return "10100100";
      when 3 => return "10110000";
      when others => return "10011001";           -- 4
    end case;
  end;
begin
  process (clk50)
  begin
    if rising_edge(clk50) then
      s1 <= Ja;
      s2 <= s1;
      if Btn(0) = '1' then
        seen <= (others => '0');
      else
        seen <= seen or not s2;
      end if;
      div <= div + 1;
    end if;
  end process;

  digit <= div(17 downto 16);
  process (digit, seen)
  begin
    An <= "1111";
    case to_integer(digit) is
      when 3 => An(3) <= '0'; Seg <= glyph(seen(0), 1);
      when 2 => An(2) <= '0'; Seg <= glyph(seen(1), 2);
      when 1 => An(1) <= '0'; Seg <= glyph(seen(2), 3);
      when others => An(0) <= '0'; Seg <= glyph(seen(3), 4);
    end case;
  end process;
  Led <= seen(7 downto 4);
end architecture;
