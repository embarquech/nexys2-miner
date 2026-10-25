-- rate_display at a 10 MHz "clock" (1 ms = 10 000 cycles). Unit i ticks every
-- 134 + i cycles, so the units read ~74, 74, 73, 73 kH/s and the total ~294
-- (a 1 ms window catches one tick more or less depending on phase).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_display is
end entity;

architecture sim of tb_display is
  signal clk   : std_logic := '0';
  signal ticks : std_logic_vector(3 downto 0) := (others => '0');
  signal btn   : std_logic_vector(3 downto 0) := (others => '0');
  signal seg   : std_logic_vector(7 downto 0);
  signal an    : std_logic_vector(3 downto 0);
  signal done  : boolean := false;
  type shown_t is array (0 to 3) of character;
  signal shown : shown_t := (others => '?');
  signal dp    : std_logic := '0';

  function decode(s : std_logic_vector(6 downto 0)) return character is
  begin
    case s is
      when "1000000" => return '0';
      when "1111001" => return '1';
      when "0100100" => return '2';
      when "0110000" => return '3';
      when "0011001" => return '4';
      when "0010010" => return '5';
      when "0000010" => return '6';
      when "1111000" => return '7';
      when "0000000" => return '8';
      when "0010000" => return '9';
      when "1111111" => return ' ';
      when others    => return '?';
    end case;
  end;
begin
  clk <= not clk after 50 ns when not done;

  dut : entity work.rate_display
    generic map (NCORES => 4, CLK_HZ => 10_000_000)
    port map (clk => clk, ticks => ticks, btn => btn, seg => seg, an => an);

  g : for i in 0 to 3 generate
    process
      variable c : natural := 0;
    begin
      wait until rising_edge(clk);
      if c = 133 + i then
        c := 0;
        ticks(i) <= '1';
      else
        c := c + 1;
        ticks(i) <= '0';
      end if;
    end process;
  end generate;

  -- latch whatever digit is lit
  process (clk)
  begin
    if rising_edge(clk) then
      for i in 0 to 3 loop
        if an(i) = '0' then
          shown(i) <= decode(seg(6 downto 0));
          if i = 3 then
            dp <= not seg(7);
          end if;
        end if;
      end loop;
    end if;
  end process;

  stim : process
    function text(s : shown_t; p : std_logic) return string is
    begin
      if p = '1' then
        return s(3) & '.' & s(2) & s(1) & s(0);
      end if;
      return s(3) & s(2) & s(1) & s(0);
    end;
  begin
    wait for 300 ms;
    report "total : [" & text(shown, dp) & "]";
    assert text(shown, dp)(1 to 3) = " 29" report "total wrong" severity failure;
    btn(2) <= '1';
    wait for 5 ms;
    btn(2) <= '0';
    wait for 10 ms;
    report "unit 2: [" & text(shown, dp) & "]";
    assert text(shown, dp)(1 to 4) = "2. 7" report "unit 2 wrong" severity failure;
    wait for 3100 ms;
    report "after 3 s: [" & text(shown, dp) & "]";
    assert text(shown, dp)(1 to 3) = " 29" report "did not return to total" severity failure;
    report "PASS: display";
    done <= true;
    wait;
  end process;
end architecture;
