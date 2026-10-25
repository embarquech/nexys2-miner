-- Hash rate on the Nexys2's 4-digit 7-segment display.
--
-- Each unit pulses its tick once per finished nonce. Counting ticks over a
-- 1 ms window gives nonces per millisecond, which is kH/s with no division.
-- The display shows the total; pressing BTNi shows unit i for 3 seconds as
-- "i.rrr" (unit number, decimal point, kH/s).
--
-- Area is tight, so there are two counters rather than one per unit: one adds
-- every unit's ticks, the other follows only the unit selected by the buttons.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rate_display is
  generic (
    NCORES : positive := 4;
    CLK_HZ : positive := 50_000_000);
  port (
    clk   : in  std_logic;
    ticks : in  std_logic_vector(NCORES - 1 downto 0);
    btn   : in  std_logic_vector(3 downto 0);    -- active high
    seg   : out std_logic_vector(7 downto 0);    -- CA..CG, DP; active low
    an    : out std_logic_vector(3 downto 0));   -- AN3 is the leftmost digit; active low
end entity;

architecture rtl of rate_display is
  constant MS_CYCLES : positive := CLK_HZ / 1000;
  constant HOLD_MS   : natural := 3000;
  constant SHOW_ALL  : natural := NCORES;
  constant BLANK     : unsigned(3 downto 0) := x"F";

  type digit_array is array (0 to 3) of unsigned(3 downto 0);

  signal ms_cnt  : natural range 0 to MS_CYCLES - 1 := 0;
  signal ms_tick : std_logic := '0';
  signal cnt_all  : unsigned(13 downto 0) := (others => '0');
  signal rate_all : unsigned(13 downto 0) := (others => '0');
  signal cnt_one  : unsigned(9 downto 0) := (others => '0');
  signal rate_one : unsigned(9 downto 0) := (others => '0');

  signal btn_s   : std_logic_vector(3 downto 0) := (others => '0');
  signal btn_ss  : std_logic_vector(3 downto 0) := (others => '0');
  signal sel     : natural range 0 to NCORES := SHOW_ALL;
  signal hold    : natural range 0 to HOLD_MS := 0;
  signal refresh : natural range 0 to 249 := 0;

  signal bin     : unsigned(13 downto 0) := (others => '0');
  signal bcd     : unsigned(15 downto 0) := (others => '0');
  signal steps   : natural range 0 to 14 := 0;
  signal bcd_sel : natural range 0 to NCORES := SHOW_ALL;
  signal digits  : digit_array := (others => BLANK);
  signal dp3     : std_logic := '0';
  signal scan    : unsigned(1 downto 0) := "00";

  function seven(d : unsigned(3 downto 0)) return std_logic_vector is
  begin
    case to_integer(d) is                          -- gfedcba, active low
      when 0      => return "1000000";
      when 1      => return "1111001";
      when 2      => return "0100100";
      when 3      => return "0110000";
      when 4      => return "0011001";
      when 5      => return "0010010";
      when 6      => return "0000010";
      when 7      => return "1111000";
      when 8      => return "0000000";
      when 9      => return "0010000";
      when others => return "1111111";
    end case;
  end;
begin
  process (clk)
    variable n_all : unsigned(13 downto 0);
    variable n_one : unsigned(9 downto 0);
    variable v     : unsigned(15 downto 0);
  begin
    if rising_edge(clk) then
      btn_s  <= btn;
      btn_ss <= btn_s;

      -- 1 ms window
      ms_tick <= '0';
      if ms_cnt = MS_CYCLES - 1 then
        ms_cnt  <= 0;
        ms_tick <= '1';
      else
        ms_cnt <= ms_cnt + 1;
      end if;

      n_all := (others => '0');
      n_one := (others => '0');
      for i in 0 to NCORES - 1 loop
        if ticks(i) = '1' then
          n_all := n_all + 1;
          if sel = i then
            n_one := to_unsigned(1, 10);
          end if;
        end if;
      end loop;
      if ms_tick = '1' then
        rate_all <= cnt_all;
        rate_one <= cnt_one;
        cnt_all  <= n_all;
        cnt_one  <= n_one;
      else
        cnt_all <= cnt_all + n_all;
        cnt_one <= cnt_one + n_one;
      end if;

      -- Buttons (sampled once per ms, which also debounces them) and refresh
      if ms_tick = '1' then
        if hold > 0 then
          hold <= hold - 1;
        else
          sel <= SHOW_ALL;
        end if;
        for i in 0 to NCORES - 1 loop
          if i < 4 and btn_ss(i) = '1' then
            sel  <= i;
            hold <= HOLD_MS;
          end if;
        end loop;

        scan <= scan + 1;

        if refresh = 0 and steps = 0 then
          refresh <= 249;                           -- every 250 ms
          if sel = SHOW_ALL then
            bin <= rate_all;
          else
            bin <= resize(rate_one, 14);
          end if;
          bcd_sel <= sel;
          bcd     <= (others => '0');
          steps   <= 14;
        elsif refresh > 0 then
          refresh <= refresh - 1;
        end if;
        -- After a button press, refresh once the selected unit has had a
        -- full window of its own (2 ms), not the previous unit's count.
        if sel /= bcd_sel and steps = 0 and refresh > 2 then
          refresh <= 2;
        end if;
      end if;

      -- Binary to BCD, double dabble, one bit per clock
      if steps > 0 then
        v := bcd;
        for k in 0 to 3 loop
          if v(4 * k + 3 downto 4 * k) >= 5 then
            v(4 * k + 3 downto 4 * k) := v(4 * k + 3 downto 4 * k) + 3;
          end if;
        end loop;
        bcd   <= v(14 downto 0) & bin(13);
        bin   <= bin(12 downto 0) & '0';
        steps <= steps - 1;
        if steps = 1 then
          -- bcd is one shift short here; use the value being written
          v := v(14 downto 0) & bin(13);
          digits(0) <= v(3 downto 0);
          if v(15 downto 4) = 0 then digits(1) <= BLANK; else digits(1) <= v(7 downto 4); end if;
          if v(15 downto 8) = 0 then digits(2) <= BLANK; else digits(2) <= v(11 downto 8); end if;
          if bcd_sel = SHOW_ALL then
            dp3 <= '0';
            if v(15 downto 12) = 0 then digits(3) <= BLANK; else digits(3) <= v(15 downto 12); end if;
          else
            dp3       <= '1';
            digits(3) <= to_unsigned(bcd_sel, 4);
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Multiplexed digits, one per ms
  process (scan, digits, dp3)
    variable i : natural range 0 to 3;
  begin
    i := to_integer(scan);
    an      <= (others => '1');
    an(i)   <= '0';
    seg(6 downto 0) <= seven(digits(i));
    if i = 3 and dp3 = '1' then
      seg(7) <= '0';
    else
      seg(7) <= '1';
    end if;
  end process;
end architecture;
