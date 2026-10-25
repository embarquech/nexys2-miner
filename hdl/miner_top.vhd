-- Nexys2 SHA-256d miner: NCORES hashing units behind a register interface,
-- reached either through the on-board USB controller (Digilent DEPP, for the
-- PC) or through a UART on Pmod JA (for an ESP32-S3), chosen by HOST_UART.
--
-- Register map (8-bit address, 8-bit data, multi-byte values big-endian):
--   0x00       W   job port: 84 bytes written in a row (same address) shift in
--                    midstate (32, H0 first), header bytes 64..75 (12),
--                    first nonce word (4; header bytes 76..79 read big-endian,
--                    a multiple of 4 with 4 units), hit mask (4, ANDed with
--                    H7 of the final hash), state3 (32: second block a..h
--                    after rounds 0-2, sw/sha256_mid.state3).
--                  With the UART link the job is 76 bytes, without the first
--                    nonce word (always 0) and the mask (fixed at 20 bits).
--                  One address instead of 84 saves a byte decoder per byte.
--   0x38       W   bit0 = restart and run, bit1 = stop
--   0x39       R   bit0 = running, bit1 = hit pending
--   0x3A       W   any value clears the pending hit
--   0x3B       RW  bit0 = LEDs and 7-segment display off (dark mode)
--   0x40-0x43  R   nonce word of the pending hit, plus NCORES (it is the unit's
--                  counter, read the clock after it stepped past the hit)
--   0x44-0x47  R   nonce word unit 0 is hashing (0x44 snapshots all four)
--   0x48       R   hits since restart (wraps; USB link only)
--   0x4E       R   magic: 0xB7 (84-byte job), 0xB8 (76-byte job, UART link)
--   0x4F       R   NCORES
-- The job is write-only; 0x3B reads back. The UART protocol is in
-- uart_bridge.vhd.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sha256_pkg.all;

entity miner_top is
  generic (
    NCORES  : positive := 4;
    CLK_MUL : positive := 6;                       -- core clock = 50 MHz * MUL / DIV
    CLK_DIV : positive := 5;
    HOST_UART : boolean := false;                  -- false: USB/DEPP, true: UART
    UART_BAUD : positive := 921_600;
    SHOW_RATE : boolean := true);                  -- 7-segment display and LEDs
  port (
    clk50   : in    std_logic;                     -- board oscillator
    EppAstb : in    std_logic;
    EppDstb : in    std_logic;
    EppWr   : in    std_logic;
    EppWait : out   std_logic;
    EppDB   : inout std_logic_vector(7 downto 0);
    UartRx  : in    std_logic;                     -- Pmod JA1, from the ESP32 TX
    UartTx  : out   std_logic;                     -- Pmod JA2, to the ESP32 RX
    Btn     : in    std_logic_vector(3 downto 0);   -- BTN0..BTN3: show unit 0..3
    Seg     : out   std_logic_vector(7 downto 0);   -- CA..CG, DP
    An      : out   std_logic_vector(3 downto 0);
    Led     : out   std_logic_vector(3 downto 0));
end entity;

architecture rtl of miner_top is
  constant CLK_HZ   : positive := 50_000_000 / CLK_DIV * CLK_MUL;
  signal clk        : std_logic;
  signal dcm_locked : std_logic;
  type byte_array is array (natural range <>) of std_logic_vector(7 downto 0);
  type nonce_array is array (natural range <>) of unsigned(31 downto 0);

  function job_bytes_f return positive is
  begin
    if HOST_UART then
      return 76;
    end if;
    return 84;
  end;
  constant JOB_BYTES : positive := job_bytes_f;
  signal job    : std_logic_vector(JOB_BYTES * 8 - 1 downto 0) := (others => '0');
  signal lights : std_logic := '0';

  -- register bus
  signal bus_we    : std_logic := '0';
  signal bus_re    : std_logic := '0';
  signal bus_addr  : unsigned(7 downto 0) := (others => '0');
  signal bus_wdata : std_logic_vector(7 downto 0) := (others => '0');
  signal bus_rdata : std_logic_vector(7 downto 0);

  -- DEPP slave
  signal astb_s, dstb_s, wr_s : std_logic_vector(1 downto 0) := "11";
  signal ep_busy  : std_logic := '0';
  signal ep_wait  : std_logic := '0';
  signal ep_wait_d : std_logic_vector(1 downto 0) := "00";
  signal ep_drive : std_logic := '0';
  signal ep_addr  : unsigned(7 downto 0) := (others => '0');
  signal ep_dout  : std_logic_vector(7 downto 0) := (others => '0');

  -- job
  signal midstate : unsigned(255 downto 0);
  signal state3   : unsigned(255 downto 0);
  signal hk3      : unsigned(31 downto 0) := (others => '0');
  signal dhk3     : unsigned(31 downto 0) := (others => '0');
  signal tail     : unsigned(95 downto 0);
  signal first    : unsigned(31 downto 0);
  signal mask     : unsigned(31 downto 0);
  signal restart  : std_logic := '0';
  signal enable   : std_logic := '0';

  -- results
  signal hits        : std_logic_vector(NCORES - 1 downto 0);
  signal ticks       : std_logic_vector(NCORES - 1 downto 0);
  type kidx_array is array (0 to NCORES - 1) of unsigned(5 downto 0);
  signal kidxs       : kidx_array;
  signal k_shared    : unsigned(31 downto 0) := (others => '0');
  signal nonces      : nonce_array(0 to NCORES - 1);
  type ctl_array is array (0 to NCORES - 1) of unit_ctl_t;
  signal ctls        : ctl_array;
  signal firsts      : nonce_array(0 to NCORES - 1);
  signal found       : std_logic := '0';
  signal found_nonce : unsigned(31 downto 0) := (others => '0');
  signal hit_count   : unsigned(7 downto 0) := (others => '0');
  signal snap        : unsigned(31 downto 0) := (others => '0');
  signal an_int      : std_logic_vector(3 downto 0);
  signal led_int     : std_logic_vector(3 downto 0);
  -- K in a block RAM: the 64x32 table otherwise costs ~130 LUTs
  type krom_t is array (0 to 63) of std_logic_vector(31 downto 0);
  function krom_init return krom_t is
    variable r : krom_t;
  begin
    for i in 0 to 63 loop
      r(i) := std_logic_vector(K(i));
    end loop;
    return r;
  end;
  constant KROM : krom_t := krom_init;
  signal k_q : std_logic_vector(31 downto 0) := (others => '0');
  attribute rom_style : string;
  attribute rom_style of k_q : signal is "block";
  signal lights_off  : std_logic;
begin
  clocks : entity work.clkgen
    generic map (CLK_MUL => CLK_MUL, CLK_DIV => CLK_DIV)
    port map (clk_in => clk50, clk_out => clk, locked => dcm_locked);

  ---------------------------------------------------------------------------
  -- Job registers, unpacked
  ---------------------------------------------------------------------------
  -- the first byte written ends at the top after all of them have shifted in
  midstate <= unsigned(job(job'high downto job'high - 255));
  tail     <= unsigned(job(job'high - 256 downto job'high - 351));
  -- With the UART link the hit threshold is fixed at 20 leading zero bits
  -- (~3 hits/s at 3.4 MH/s): a constant mask saves a 32-bit register compare
  -- per unit, and the ESP32 re-hashes every hit anyway, so it keeps a running
  -- error count and forwards only the ones it wants. The first nonce is
  -- always 0, so neither is sent.
  g_mask_fixed : if HOST_UART generate
    first <= (others => '0');
    mask  <= x"00F0FFFF";                    -- byte-swapped top 20 bits of the hash
  end generate;
  g_mask_reg : if not HOST_UART generate
    first <= unsigned(job(319 downto 288));
    mask  <= unsigned(job(287 downto 256));
  end generate;
  state3   <= unsigned(job(255 downto 0));

  ---------------------------------------------------------------------------
  -- Hashing units: unit i hashes first + i, first + i + NCORES, ...
  ---------------------------------------------------------------------------
  g_units : for i in 0 to NCORES - 1 generate
    -- With 4 units and a first nonce word that is a multiple of 4 (the hosts
    -- always send one), first + i is just i in the low two bits: no adders.
    -- The ESP32 always starts a job at nonce 0, so with the UART link the
    -- first nonce is a constant and no unit needs a 32-bit reload mux.
    g_fixed : if HOST_UART generate
      firsts(i) <= to_unsigned(i, 32);
    end generate;
    g_wire : if not HOST_UART and NCORES = 4 generate
      firsts(i) <= first(31 downto 2) & to_unsigned(i, 2);
    end generate;
    g_add : if not HOST_UART and NCORES /= 4 generate
      firsts(i) <= first + i;            -- VHDL-93: no expressions in port maps
    end generate;
    -- With 4 units, unit 0 runs the round counters and state machine for
    -- all of them (they are in lockstep anyway): ~50 slices per follower.
    u : entity work.miner_unit
      generic map (STEP => NCORES, MASTER => i = 0 or NCORES /= 4, UNIT => i)
      port map (
        clk       => clk,
        restart   => restart,
        enable    => enable,
        midstate  => midstate,
        state3    => state3,
        hk3       => hk3,
        dhk3      => dhk3,
        tail      => tail,
        first     => firsts(i),
        mask      => mask,
        hit       => hits(i),
        tick      => ticks(i),
        kidx      => kidxs(i),
        k_in      => k_shared,
        nonce     => nonces(i),
        ctl_in    => ctls(0),
        ctl_out   => ctls(i));
  end generate;

  -- One K table for all units. They restart together and run identical state
  -- machines, so they are always on the same round; unit 0 sets the pace.
  -- The per-job sums each pass 1 starts from are computed here once as well.
  process (clk)
  begin
    if rising_edge(clk) then
      k_q      <= KROM(to_integer(kidxs(0)));
      hk3      <= state3(31 downto 0) + K(3);
      dhk3     <= state3(159 downto 128) + state3(31 downto 0) + K(3);
    end if;
  end process;

  -- The display costs ~150 slices, which the units can use instead when the
  -- host (AxeOS on the ESP32) shows the rate anyway.
  g_display : if SHOW_RATE generate
    display : entity work.rate_display
      generic map (NCORES => NCORES, CLK_HZ => CLK_HZ)
      port map (clk => clk, ticks => ticks, btn => Btn, seg => Seg, an => an_int);
  end generate;
  g_no_display : if not SHOW_RATE generate
    an_int <= (others => '1');
    Seg    <= (others => '1');
  end generate;
  k_shared <= unsigned(k_q);

  lights_off <= lights;
  An <= an_int or (An'range => lights_off);          -- anodes are active low

  ---------------------------------------------------------------------------
  -- Register bus: writes, hit capture, read multiplexer
  ---------------------------------------------------------------------------
  process (clk)
    variable ai : integer range 0 to 255;
  begin
    if rising_edge(clk) then
      restart <= '0';

      -- Hits: the lowest-numbered unit wins if several land on the same clock.
      for i in NCORES - 1 downto 0 loop
        if hits(i) = '1' and found = '0' then
          found_nonce <= nonces(i);
        end if;
      end loop;
      if hits /= (hits'range => '0') then
        found <= '1';
        if not HOST_UART then                -- only the PC stress test reads it
          hit_count <= hit_count + 1;
        end if;
      end if;

      ai := to_integer(bus_addr);
      if bus_we = '1' then
        if ai = 16#00# then
          job <= job(job'high - 8 downto 0) & bus_wdata;
        elsif ai = 16#3B# then
          lights <= bus_wdata(0);
        end if;
        if ai = 16#38# then
          if bus_wdata(0) = '1' then
            restart   <= '1';
            enable    <= '1';
            found     <= '0';
            hit_count <= (others => '0');
          end if;
          if bus_wdata(1) = '1' then
            enable <= '0';
          end if;
        elsif ai = 16#3A# then
          found <= '0';
        end if;
      end if;
      if bus_re = '1' and ai = 16#44# then
        snap <= nonces(0);
      end if;
    end if;
  end process;

  process (bus_addr, lights, found, enable, found_nonce, nonces, snap, hit_count)
    variable ai : integer range 0 to 255;
    variable rd : std_logic_vector(7 downto 0);
  begin
    ai := to_integer(bus_addr);
    rd := (others => '0');
    case ai is
      when 16#3B# => rd := "0000000" & lights;
      when 16#39# => rd := "000000" & found & enable;
      when 16#40# => rd := std_logic_vector(found_nonce(31 downto 24));
      when 16#41# => rd := std_logic_vector(found_nonce(23 downto 16));
      when 16#42# => rd := std_logic_vector(found_nonce(15 downto 8));
      when 16#43# => rd := std_logic_vector(found_nonce(7 downto 0));
      when 16#44# => rd := std_logic_vector(nonces(0)(31 downto 24));
      when 16#45# => rd := std_logic_vector(snap(23 downto 16));
      when 16#46# => rd := std_logic_vector(snap(15 downto 8));
      when 16#47# => rd := std_logic_vector(snap(7 downto 0));
      when 16#48# => rd := std_logic_vector(hit_count);
      when 16#4E# =>
        if HOST_UART then
          rd := x"B8";
        else
          rd := x"B7";
        end if;
      when 16#4F# => rd := std_logic_vector(to_unsigned(NCORES, 8));
      when others => null;
    end case;
    bus_rdata <= rd;
  end process;

  ---------------------------------------------------------------------------
  -- Host link: the Nexys2's USB port (DEPP) or a UART on Pmod JA. The chip is
  -- too full for both at once.
  ---------------------------------------------------------------------------
  g_uart : if HOST_UART generate
    bridge : entity work.uart_bridge
      generic map (CLK_HZ => CLK_HZ, BAUD => UART_BAUD)
      port map (clk => clk, rx => UartRx, tx => UartTx,
                bus_we => bus_we, bus_re => bus_re, bus_addr => bus_addr,
                bus_wdata => bus_wdata, bus_rdata => bus_rdata);
    EppWait <= '0';
    EppDB   <= (others => 'Z');
  end generate;

  g_depp : if not HOST_UART generate
    process (clk)
    begin
      if rising_edge(clk) then
        astb_s <= astb_s(0) & EppAstb;
        dstb_s <= dstb_s(0) & EppDstb;
        wr_s   <= wr_s(0) & EppWr;
        bus_we <= '0';
        bus_re <= '0';
        if ep_busy = '0' then
          if astb_s(1) = '0' then                       -- address cycle
            if wr_s(1) = '0' then
              ep_addr <= unsigned(EppDB);
            else
              ep_dout  <= std_logic_vector(ep_addr);
              ep_drive <= '1';
            end if;
            ep_wait <= '1';
            ep_busy <= '1';
          elsif dstb_s(1) = '0' then                    -- data cycle
            if wr_s(1) = '0' then
              bus_we    <= '1';
              bus_wdata <= EppDB;
            else
              bus_re   <= '1';
              ep_dout  <= bus_rdata;
              ep_drive <= '1';
            end if;
            ep_wait <= '1';
            ep_busy <= '1';
          end if;
        elsif astb_s(1) = '1' and dstb_s(1) = '1' then  -- host released the strobe
          ep_wait  <= '0';
          ep_drive <= '0';
          ep_busy  <= '0';
        end if;
        -- Raise Wait two clocks after the data driver turns on: at 99 % slice
        -- use the tristate enable is routed far slower than EppWait, and the
        -- host would otherwise sample a bus still holding its own address.
        ep_wait_d <= ep_wait_d(0) & ep_wait;
      end if;
    end process;
    bus_addr <= ep_addr;
    EppWait  <= ep_wait_d(1) and ep_wait;
    EppDB    <= ep_dout when ep_drive = '1' else (others => 'Z');
    UartTx   <= '1';
  end generate;

  led_int(0) <= enable and not lights_off;
  led_int(1) <= found and not lights_off;
  led_int(2) <= nonces(0)(20) and not lights_off;     -- blinks while hashing
  led_int(3) <= '1' when hit_count /= 0 and lights_off = '0' else '0';
  Led <= led_int when SHOW_RATE else (others => '0');
end architecture;
