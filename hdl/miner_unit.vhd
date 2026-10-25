-- One hashing unit: double SHA-256 of an 80-byte block header, one nonce at a
-- time, reusing a single compression core for both passes: 62 clocks for the
-- first (rounds 0-2 precomputed by the host), 61 for the second (round 0
-- folded into the load, stops after round 60). Pass 2 starts in the clock
-- pass 1 reports done; pass 1 is loaded during pass 2's last round (122 per
-- nonce).
--
-- The host supplies the midstate (compression of header bytes 0..63), the
-- state after rounds 0-2 of the second block (state3) and the tail (header
-- bytes 64..75). The nonce counter is placed as-is in word 3 of that block,
-- i.e. it holds header bytes 76..79 read big-endian; the host byte-swaps it.
--
-- The core keeps the first hash itself (in a block RAM, see sha256_core) and
-- returns only h7 of the second; mid_e is a midstate word the cores add to
-- the hash words they store, from a register shared by all units.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sha256_pkg.all;

entity miner_unit is
  generic (
    STEP      : positive := 1;                -- nonce increment (units, rounded up)
    STEP_BITS : natural := 2;                 -- log2(STEP), for followers
    MASTER    : boolean := true;              -- false: follow ctl_in
    CSA       : boolean := true;              -- see sha256_core
    HYBRID    : boolean := false;
    UNIT      : natural := 0);                -- low nonce bits of a follower
  port (
    clk       : in  std_logic;
    restart   : in  std_logic;                -- pulse: abort, reload nonce from first
    enable    : in  std_logic;
    midstate  : in  unsigned(255 downto 0);
    mid_e     : in  unsigned(31 downto 0);
    a1m       : in  unsigned(31 downto 0);    -- see sha256_core
    e1m       : in  unsigned(31 downto 0);
    hk1m      : in  unsigned(31 downto 0);
    dhk1m     : in  unsigned(31 downto 0);
    state3    : in  unsigned(255 downto 0);   -- second block state after round 2
    hk3       : in  unsigned(31 downto 0);    -- h + K(3) of state3
    dhk3      : in  unsigned(31 downto 0);    -- d + h + K(3) of state3
    tail      : in  unsigned(95 downto 0);
    first     : in  unsigned(31 downto 0);
    mask      : in  unsigned(31 downto 0);    -- hit when (H7 and mask) = 0
    hit       : out std_logic;                -- one-cycle pulse; nonce already = hit + STEP
    tick      : out std_logic;                -- one-cycle pulse per finished nonce
    kidx      : out unsigned(5 downto 0);     -- see sha256_core
    k_in      : in  unsigned(31 downto 0);
    nonce     : out unsigned(31 downto 0);    -- nonce currently being hashed
    ctl_in    : in  unit_ctl_t;               -- the master unit's control registers
    ctl_out   : out unit_ctl_t);
end entity;

architecture rtl of miner_unit is
  -- Control registers (_q) and what the unit runs on: its own in the master,
  -- the master's in the followers (their own are then trimmed).
  signal st_q       : unit_state_t := ST_IDLE;
  signal n_q        : unsigned(31 downto 0) := (others => '0');
  signal n_next_q   : unsigned(31 downto 0) := (others => '0');   -- n + STEP
  signal pass2_q    : std_logic := '0';
  signal tick_q     : std_logic := '0';
  signal st         : unit_state_t;
  signal n          : unsigned(31 downto 0);
  signal n_next     : unsigned(31 downto 0);
  signal pass2      : std_logic;
  signal core_ctl   : core_ctl_t;
  attribute max_fanout : string;
  attribute max_fanout of st_q, pass2_q : signal is "64";
  signal core_start : std_logic;
  signal p2         : std_logic;                   -- pass the core is on or starting
  signal core_done  : std_logic;
  signal core_busy  : std_logic;
  signal core_idx   : unsigned(3 downto 0);
  signal core_word  : word;
  signal core_mf1   : word;
  signal core_h7    : word;
  signal hit_r      : std_logic := '0';

  function hw(v : unsigned(255 downto 0); i : natural) return word is
  begin
    return v(255 - 32 * i downto 224 - 32 * i);
  end;
begin
  sha : entity work.sha256_core
    generic map (MASTER => MASTER, CSA => CSA, HYBRID => HYBRID)
    port map (
      clk      => clk,
      abort    => restart,
      start    => core_start,
      short    => p2,
      state_in => state3,
      hk3      => hk3,
      dhk3     => dhk3,
      mid0     => midstate(255 downto 224),
      mid1     => midstate(223 downto 192),
      mid2     => midstate(191 downto 160),
      mid3     => midstate(159 downto 128),
      mid_e    => mid_e,
      a1m      => a1m,
      e1m      => e1m,
      hk1m     => hk1m,
      dhk1m    => dhk1m,
      mf1      => core_mf1,
      chain    => enable,
      widx     => core_idx,
      msg_word => core_word,
      ovw0     => tail(95 downto 64),
      ovw1     => tail(63 downto 32),
      ovw2     => tail(31 downto 0),
      kidx     => kidx,
      k_in     => k_in,
      done     => core_done,
      busy     => core_busy,
      h7       => core_h7,
      ctl_in   => ctl_in.core,
      ctl_out  => core_ctl);

  -- Starts are combinational so no clock is lost between passes; in a done
  -- clock the muxes already select the pass about to start.
  -- After pass 2 the carry-save core has usually loaded pass 1 already
  -- (busy); the plain core has not, and is started here.
  core_start <= '1' when (st = ST_IDLE and enable = '1')
                      or (core_done = '1' and st = ST_PASS1)
                      or (core_done = '1' and st = ST_PASS2 and enable = '1' and core_busy = '0')
                else '0';
  p2 <= '1' when core_done = '1' and st = ST_PASS1 else
        '0' when core_done = '1' else
        pass2;

  -- W3 of pass 1, the nonce. A pass 1 loaded while pass 2 ends already
  -- belongs to the next nonce, which n only takes at the end of pass 2.
  core_mf1 <= n_next when st = ST_PASS2 else n;

  -- Padding words. Pass 1 from W4: padding for 640 bits. Pass 2's W0-W7 are
  -- the first hash, which the core reads itself; then padding for 256 bits.
  process (p2, core_idx)
    variable i : natural range 0 to 15;
  begin
    i := to_integer(core_idx);
    core_word <= (others => '0');
    if p2 = '1' then
      case i is
        when 8      => core_word <= x"80000000";
        when 15     => core_word <= x"00000100";
        when others => null;
      end case;
    else
      case i is
        when 4      => core_word <= x"80000000";
        when 15     => core_word <= x"00000280";
        when others => null;
      end case;
    end if;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      hit_r      <= '0';
      tick_q     <= '0';
      n_next_q   <= n + STEP;                 -- settles long before pass 1 needs it
      if restart = '1' then
        n_q     <= first;
        pass2_q <= '0';
        st_q    <= ST_IDLE;
      else
        case st is
          when ST_IDLE =>
            if enable = '1' then
              pass2_q <= '0';
              st_q    <= ST_PASS1;
            end if;
          when ST_PASS1 =>
            if core_done = '1' then
              pass2_q <= '1';
              st_q    <= ST_PASS2;
            end if;
          when ST_PASS2 =>
            if core_done = '1' then
              -- H7 = IV H7 + h; e after round 60 is what h would be after
              -- round 63
              if ((hw(IV, 7) + core_h7) and mask) = 0 then
                hit_r <= '1';
              end if;
              n_q     <= n + STEP;
              tick_q  <= '1';
              pass2_q <= '0';
              if enable = '1' then
                st_q <= ST_PASS1;
              else
                st_q <= ST_IDLE;
              end if;
            end if;
        end case;
      end if;
    end if;
  end process;

  hit       <= hit_r;
  ctl_out <= (st => st_q, pass2 => pass2_q, n => n_q, n_next => n_next_q,
              tick => tick_q, core => core_ctl);
  g_master : if MASTER generate
    st <= st_q; pass2 <= pass2_q; n <= n_q; n_next <= n_next_q;
    tick <= tick_q;
  end generate;
  -- A follower hashes the master's nonce with its own number in the low bits
  g_follow : if not MASTER generate
    st <= ctl_in.st; pass2 <= ctl_in.pass2;
    n      <= ctl_in.n(31 downto STEP_BITS) & to_unsigned(UNIT, STEP_BITS);
    n_next <= ctl_in.n_next(31 downto STEP_BITS) & to_unsigned(UNIT, STEP_BITS);
    tick <= ctl_in.tick;
  end generate;
  nonce     <= n;
end architecture;
