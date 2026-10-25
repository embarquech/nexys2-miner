-- Register access over a UART, for a microcontroller host (ESP32-S3) instead
-- of the Nexys2's USB port. 8N1, BAUD from the core clock.
--
-- Host -> FPGA:
--   'W' (0x57), addr, n, data[n]   write n consecutive registers, reply 0x06
--   'J' (0x4A), addr, n, data[n]   write n bytes to the same register (the job
--                                  port), reply 0x06
--   'R' (0x52), addr, n            reply n bytes from consecutive registers
-- n = 0 is taken as 256. Any other first byte is ignored, which also lets the
-- host resynchronise by sending a few idle bytes.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_bridge is
  generic (
    CLK_HZ : positive := 96_875_000;
    BAUD   : positive := 921_600);
  port (
    clk       : in  std_logic;
    rx        : in  std_logic;
    tx        : out std_logic;
    bus_we    : out std_logic;                     -- one-cycle write strobe
    bus_re    : out std_logic;                     -- one-cycle read strobe
    bus_addr  : out unsigned(7 downto 0);
    bus_wdata : out std_logic_vector(7 downto 0);
    bus_rdata : in  std_logic_vector(7 downto 0)); -- valid in the bus_re clock
end entity;

architecture rtl of uart_bridge is
  constant BIT_CYCLES : positive := (CLK_HZ + BAUD / 2) / BAUD;

  -- receiver
  signal rx_s     : std_logic_vector(2 downto 0) := "111";
  signal rx_busy  : std_logic := '0';
  signal rx_cnt   : natural range 0 to BIT_CYCLES * 3 / 2 := 0;
  signal rx_bit   : natural range 0 to 9 := 0;
  signal rx_shift : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_valid : std_logic := '0';
  signal rx_data  : std_logic_vector(7 downto 0) := (others => '0');

  -- transmitter
  signal tx_busy  : std_logic := '0';
  signal tx_cnt   : natural range 0 to BIT_CYCLES - 1 := 0;
  signal tx_bit   : natural range 0 to 9 := 0;
  signal tx_shift : std_logic_vector(9 downto 0) := (others => '1');
  signal tx_start : std_logic := '0';
  signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');

  -- command state
  type state_t is (S_CMD, S_ADDR, S_COUNT, S_WDATA, S_RDATA, S_RWAIT, S_ACK);
  signal st     : state_t := S_CMD;
  signal is_wr  : std_logic := '0';
  signal fixed  : std_logic := '0';                -- 'J': no address increment
  signal addr   : unsigned(7 downto 0) := (others => '0');
  signal count  : unsigned(8 downto 0) := (others => '0');
begin
  -----------------------------------------------------------------------------
  -- UART receiver: start bit edge, then sample each bit mid-period
  -----------------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      rx_s     <= rx_s(1 downto 0) & rx;
      rx_valid <= '0';
      if rx_busy = '0' then
        if rx_s(2) = '0' then                        -- start bit
          rx_busy <= '1';
          rx_cnt  <= BIT_CYCLES + BIT_CYCLES / 2 - 1; -- to the middle of bit 0
          rx_bit  <= 0;
        end if;
      elsif rx_cnt /= 0 then
        rx_cnt <= rx_cnt - 1;
      elsif rx_bit < 8 then
        rx_shift <= rx_s(2) & rx_shift(7 downto 1);  -- LSB first
        rx_bit   <= rx_bit + 1;
        rx_cnt   <= BIT_CYCLES - 1;
      else                                           -- stop bit
        rx_busy <= '0';
        if rx_s(2) = '1' then
          rx_valid <= '1';
          rx_data  <= rx_shift;
        end if;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- UART transmitter
  -----------------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      if tx_busy = '0' then
        if tx_start = '1' then
          tx_shift <= '1' & tx_data & '0';
          tx_busy  <= '1';
          tx_bit   <= 0;
          tx_cnt   <= BIT_CYCLES - 1;
        end if;
      elsif tx_cnt /= 0 then
        tx_cnt <= tx_cnt - 1;
      elsif tx_bit < 9 then
        tx_shift <= '1' & tx_shift(9 downto 1);
        tx_bit   <= tx_bit + 1;
        tx_cnt   <= BIT_CYCLES - 1;
      else
        tx_busy <= '0';
      end if;
    end if;
  end process;
  tx <= tx_shift(0) when tx_busy = '1' else '1';

  -----------------------------------------------------------------------------
  -- Command decoder
  -----------------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      bus_we   <= '0';
      bus_re   <= '0';
      tx_start <= '0';
      case st is
        when S_CMD =>
          if rx_valid = '1' then
            if rx_data = x"57" or rx_data = x"4A" then
              is_wr <= '1';
              if rx_data = x"4A" then
                fixed <= '1';
              else
                fixed <= '0';
              end if;
              st    <= S_ADDR;
            elsif rx_data = x"52" then
              is_wr <= '0';
              st    <= S_ADDR;
            end if;
          end if;
        when S_ADDR =>
          if rx_valid = '1' then
            addr <= unsigned(rx_data);
            st   <= S_COUNT;
          end if;
        when S_COUNT =>
          if rx_valid = '1' then
            if rx_data = x"00" then
              count <= to_unsigned(256, 9);
            else
              count <= resize(unsigned(rx_data), 9);
            end if;
            if is_wr = '1' then
              st <= S_WDATA;
            else
              st <= S_RDATA;
            end if;
          end if;
        when S_WDATA =>
          if rx_valid = '1' then
            bus_we    <= '1';
            bus_wdata <= rx_data;
            bus_addr  <= addr;
            if fixed = '0' then
              addr <= addr + 1;
            end if;
            count     <= count - 1;
            if count = 1 then
              st <= S_ACK;
            end if;
          end if;
        when S_ACK =>
          if tx_busy = '0' and tx_start = '0' then
            tx_data  <= x"06";
            tx_start <= '1';
            st       <= S_CMD;
          end if;
        when S_RDATA =>
          if tx_busy = '0' and tx_start = '0' then
            bus_addr <= addr;
            bus_re   <= '1';
            st       <= S_RWAIT;
          end if;
        when S_RWAIT =>                               -- bus_rdata is valid now
          tx_data  <= bus_rdata;
          tx_start <= '1';
          addr     <= addr + 1;
          count    <= count - 1;
          if count = 1 then
            st <= S_CMD;
          else
            st <= S_RDATA;
          end if;
      end case;
    end if;
  end process;
end architecture;
