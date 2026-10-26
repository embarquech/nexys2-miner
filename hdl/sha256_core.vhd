-- Iterative SHA-256 compression for the two passes of a Bitcoin header hash,
-- one round per clock, with the rounds that do not depend on the nonce taken
-- out:
--   pass 1 (short = '0'): starts at round 3 from a state the host computed
--          once per job (rounds 0-2 only see header words 64..75); 61 clocks,
--          the load sharing pass 2's last clock (chain).
--   pass 2 (short = '1'): starts from the SHA-256 IV, so round 0 is folded
--          into the load clock, and it stops after round 60 (only H7 is
--          needed, and e then already holds the final h); 61 clocks.
--
-- Pass 1's hash is never captured. Its words are the last four values of a
-- and of e: they are written into a block RAM, two per clock (one per port),
-- as they come out of the last rounds, raw, and pass 2 reads them back
-- into a register and adds the midstate word there (mid_w): one adder per
-- core instead of one per port, and the RAM's slow clock-to-out never sits in
-- front of it.
-- W0-W2 are read from the registers in the load clock, when the whole hash is
-- still in a..h. This replaces a 256-bit capture register, its six adders and
-- an 8-way word mux per core. The one clash, three accesses in the load clock,
-- is avoided with READ_FIRST: port A writes W0's raw word over W3's and gets
-- W3 back.
-- Pass 2's result is h7: raw e after round 60 (H7 = IV H7 + h7).
--
-- h + K(t) + W(t) and d + h + K(t) + W(t) are computed one round ahead (h and
-- d of the next round are the current g and c). The round then reduces its
-- terms with carry-save adders and ends in one carry chain for each of a and e:
--   e = dhkw + S1(e) + Ch(e,f,g)                 one CSA level, one adder
--   a = hkw + S1(e) + Ch(e,f,g) + S0(a) + Maj    three CSA levels, one adder
-- Carry chains are what limit the clock on a Spartan-3E. With CSA false the
-- round is T1 = hkw + S1 + Ch (one CSA level, one adder), a = T1 + (S0 + Maj),
-- e = d + T1: two chains in a row for a, but ~250 LUTs per core smaller.
--
-- The message is read one word per clock: widx says which word is wanted on
-- msg_word (the padding constants; pass 2's hash words come from the RAM).
-- The schedule history only needs W(t), W(t-5), W(t-13) and W(t-14), so it
-- lives in a second block RAM used as a ring of 11 words:
-- port A writes W(t) and reads back (READ_FIRST) the word written 11 pushes
-- earlier, port B reads W(t-5) ahead; both outputs are registered, so the
-- RAM's clock-to-out stays out of the W adders. That replaces two SRL16
-- columns per core. The words a pass skips
-- (W0-W2 in pass 1, W0 in pass 2) never enter it; they are written into the
-- last two stages of the line just before the rounds that tap them (pass 1's
-- from ovw0..ovw2, pass 2's W0 from the RAM).
--
-- The round constants come from outside: kidx says which K is wanted on k_in
-- during the next clock, so one registered K table serves cores in lockstep.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sha256_pkg.all;

entity sha256_core is
  generic (
    MASTER : boolean := true;                  -- false: take t, running... from ctl_in
    CSA    : boolean := true;                  -- false: two carry chains for a, smaller
    HYBRID : boolean := false);                -- with CSA: e = d + T1 by carry-save, no dhkw
  port (
    clk       : in  std_logic;
    abort     : in  std_logic;                 -- drops the block in progress
    start     : in  std_logic;                 -- one-cycle pulse
    short     : in  std_logic;                 -- read on start: '1' = pass 2
    state_in  : in  unsigned(255 downto 0);    -- pass 1: state after round 2
    hk3       : in  word;                      -- pass 1: h + K(3) of state_in
    dhk3      : in  word;                      -- pass 1: d + h + K(3) of state_in
    mid1      : in  word;                      -- midstate word 1
    a1m       : in  word;                      -- per job: pass 2's a and e after round 0
    e1m       : in  word;                      -- are a1m / e1m + raw a of pass 1 (W0 = mid0 + a),
    hk1m      : in  word;                      -- its h + K(1) + W1 and d + h + K(1) + W1 are
    dhk1m     : in  word;                      -- hk1m / dhk1m + raw b (W1 = mid1 + b)
    mid_w     : in  word;                      -- midstate word of the W read this clock:
                                               -- 2 in the load clock, 3..7 in rounds 1-5,
                                               -- 0 in round 13 (registered, shared)
    mf1       : in  word;                      -- pass 1: W3, the nonce, read on start / chain
    chain     : in  std_logic;                 -- start pass 1 straight from pass 2's last round
    widx      : out unsigned(3 downto 0);      -- index of the word wanted on msg_word
    msg_word  : in  word;                      -- message word widx
    ovw0      : in  word;                      -- W0 (pass 1)
    ovw1      : in  word;                      -- W1 (pass 1)
    ovw2      : in  word;                      -- W2 (pass 1)
    kidx      : out unsigned(5 downto 0);      -- K index wanted on k_in next clock
    k_in      : in  word;                      -- K(t + 1) during round t
    done      : out std_logic;                 -- one-cycle pulse; after pass 2, h7 valid
    busy      : out std_logic;                 -- running (also right after a chained load)
    h7        : out word;                      -- pass 2: raw e after round 60
    ctl_in    : in  core_ctl_t;                -- the master core's control registers
    ctl_out   : out core_ctl_t);               -- this core's (the master's) registers
end entity;

architecture rtl of sha256_core is

  function iv_w(i : natural) return word is
  begin
    return IV(255 - 32 * i downto 224 - 32 * i);
  end;

  -- Round 0 of pass 2 on the IV: everything but W0 is constant. Its sums
  -- with the midstate words come from outside (a1m...).

  signal a, b, c, d, e, f, g, h : word;
  signal hkw     : word;                       -- h + K(t) + W(t)
  signal dhkw    : word;                       -- d + h + K(t) + W(t)
  signal wn      : word;                       -- W(t + 1)
  signal d0      : word;                       -- W(t)
  signal r5      : word;                       -- W(t - 5)
  signal r13     : word;                       -- W(t - 13)
  signal d14     : word;                       -- W(t - 14)
  signal wptr    : unsigned(3 downto 0) := (others => '0');   -- ring position, mod 11
  signal wram_en : std_logic;
  signal wram_doa, wram_dob : std_logic_vector(31 downto 0);
  signal wram_addra, wram_addrb : std_logic_vector(8 downto 0);
  signal wram_dia : std_logic_vector(31 downto 0);
  -- Control registers (_q), and what the core runs on: its own in the
  -- master, the master's in the others, whose own registers are then unused
  -- and trimmed.
  signal t_q       : unsigned(5 downto 0) := (others => '0');
  signal idx_q     : unsigned(3 downto 0) := (others => '0');
  signal running_q : std_logic := '0';
  signal short_q   : std_logic := '0';
  signal done_q    : std_logic := '0';
  signal t       : unsigned(5 downto 0);
  signal idx     : unsigned(3 downto 0);
  signal running : std_logic;
  signal short_r : std_logic;
  signal done_r  : std_logic;
  signal h7_r    : word := (others => '0');
  -- pass 1's hash words, for pass 2: a values on port A, e values on port B
  signal ram_doa, ram_dob : std_logic_vector(31 downto 0);
  signal ram_wea, ram_web : std_logic;
  signal ram_addrb : unsigned(3 downto 0);
  signal ram_w   : word;                       -- pass 2's W for wn: W2 in the load clock, then read back
  signal ram_q   : word := (others => '0');    -- the raw hash word for ram_w
  signal w1      : word;                       -- pass 2's W1 (load clock)
  -- Load values, outside the round's process so that XST cannot share their
  -- adders with the round's (it did: a mux in the middle of a's carry chains)
  signal a_p2, e_p2, hkw_ld, dhkw_ld : word;
  -- The control registers drive every core's state registers; let XST copy
  -- them instead of routing one net to all units.
  attribute max_fanout : string;
  attribute max_fanout of running_q, short_q, done_q, t_q, idx_q : signal is "64";
  signal mf1_e   : word;                       -- the loaded pass's first W
  signal ld_p2   : std_logic;                  -- this clock loads pass 2
  signal ld_p2_q : std_logic := '0';
  attribute equivalent_register_removal : string;
  attribute equivalent_register_removal of ld_p2_q : signal is "no";
  attribute max_fanout of ld_p2_q : signal is "64";
  signal ovw0_e  : word;
  signal ram_addrb_v : std_logic_vector(8 downto 0);
  signal ram_dia, ram_dib : std_logic_vector(31 downto 0);

  component RAMB16_S36_S36
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
  end component;
  signal chain_load : std_logic;               -- pass 2's last round also loads pass 1

  function sw(v : unsigned(255 downto 0); i : natural) return word is
  begin
    return v(255 - 32 * i downto 224 - 32 * i);
  end;
begin
  -- Schedule history. Every clock that shifts (a load or a round) pushes
  -- W(t) at wptr; counted in pushes, port A gives back W(t - 11) a clock
  -- later, registered as r13 = W(t - 13) one more clock on, and port B,
  -- read at wptr - 3, gives W(t - 3) a clock later, registered as r5 =
  -- W(t - 5).
  wram_en    <= '1';                           -- the ring turns every clock too
  wram_addra <= "00000" & std_logic_vector(wptr);
  wram_addrb <= "00000" & std_logic_vector(wptr + 8) when wptr < 3 else
                "00000" & std_logic_vector(wptr - 3);
  wram_dia   <= std_logic_vector(d0);
  wram : RAMB16_S36_S36
    generic map (WRITE_MODE_A => "READ_FIRST", WRITE_MODE_B => "READ_FIRST")
    port map (
      DOA => wram_doa, DOB => wram_dob, DOPA => open, DOPB => open,
      ADDRA => wram_addra, ADDRB => wram_addrb,
      CLKA => clk, CLKB => clk,
      DIA => wram_dia, DIB => (others => '0'),
      DIPA => "0000", DIPB => "0000",
      ENA => wram_en, ENB => wram_en, SSRA => '0', SSRB => '0',
      WEA => wram_en, WEB => '0');

  process (clk)
  begin
    if rising_edge(clk) then
      -- every clock, as the datapath
      if start = '1' or chain_load = '1' then
        d0 <= mf1_e;                         -- the first round's W
      else
        d0 <= wn;
      end if;
      if wptr = 10 then
        wptr <= (others => '0');
      else
        wptr <= wptr + 1;
      end if;
      r5  <= unsigned(wram_dob);
      r13 <= unsigned(wram_doa);
      d14 <= r13;
      -- Taps reaching before the first pushed word: pass 1 needs
      -- (W(t-13), W(t-14)) = (W1, W0) at t = 14 and (W2, W1) at 15, then
      -- W2 at 16, which the ring brings along by itself; pass 2 only
      -- needs W0 at t = 14.
      if running = '1' and t = 13 then
        d14 <= ovw0_e;
        if short_r = '0' then
          r13 <= ovw1;
        end if;
      elsif running = '1' and t = 14 and short_r = '0' then
        r13 <= ovw2;
      end if;
    end if;
  end process;

  -- One load path, taken on a start or on a chained pass 1, so the state
  -- registers keep a single load mux (a second one for the chained load alone
  -- costs 256 LUTs per core and does not fit).
  process (clk)
    variable s1, chv, s0, mj, an, en, t1 : word;
    variable ys, yc, zs, zc, ws, wc : word;
  begin
    if rising_edge(clk) then
      s1  := bsig1(e);
      chv := ch(e, f, g);
      s0  := bsig0(a);
      mj  := maj(a, b, c);
      ys := csa_s(hkw, s1, chv);
      yc := csa_c(hkw, s1, chv);
      if CSA and HYBRID then                   -- as below, but e from d instead of dhkw
        en := csa_s(ys, yc, d) + csa_c(ys, yc, d);
        zs := csa_s(ys, yc, s0);
        zc := csa_c(ys, yc, s0);
        an := csa_s(zs, zc, mj) + csa_c(zs, zc, mj);
      elsif CSA then
        en := csa_s(dhkw, s1, chv) + csa_c(dhkw, s1, chv);
        zs := csa_s(ys, yc, s0);
        zc := csa_c(ys, yc, s0);
        an := csa_s(zs, zc, mj) + csa_c(zs, zc, mj);
      else                                     -- T1 then a = T1 + T2, e = d + T1
        t1 := ys + yc;
        an := t1 + (s0 + mj);
        en := d + t1;                          -- dhkw is left unused and trimmed
      end if;

      done_q <= '0';
      ld_p2_q <= '0';
      if running = '1' and short_r = '0' and t = 63 and abort = '0' then
        ld_p2_q <= '1';
      end if;
      -- Capture with the last round instead of spending a clock on the
      -- feed-forward add (see the header comment for words 0 and 4).
      if running = '1' and (t = 63 or (short_r = '1' and t = 60)) then
        done_q <= '1';
      end if;
      if running = '1' and short_r = '1' and t = 60 then
        h7_r <= en;
      end if;

      -- The datapath runs every clock, loaded or not: what it computes while
      -- the core is idle is never used, and without a hold every register
      -- loses an input (IV constant / job word / shift fits one LUT).
      -- Only the control registers below look at running and abort.
      if start = '1' or chain_load = '1' then
        -- Pass 1 starts from registers only (state3, the next nonce), so its
        -- load can share pass 2's last clock (chain_load): one clock less per
        -- nonce. Pass 2 cannot do that after pass 1, it needs pass 1's last a.
        if ld_p2 = '1' then                    -- pass 2: state after round 0
          a <= a_p2;
          b <= iv_w(0);
          c <= iv_w(1);
          d <= iv_w(2);
          e <= e_p2;
          f <= iv_w(4);
          g <= iv_w(5);
          h <= iv_w(6);
          wn  <= ram_w;                        -- W2
        else                                   -- pass 1: state after round 2
          a <= sw(state_in, 0);
          b <= sw(state_in, 1);
          c <= sw(state_in, 2);
          d <= sw(state_in, 3);
          e <= sw(state_in, 4);
          f <= sw(state_in, 5);
          g <= sw(state_in, 6);
          h <= sw(state_in, 7);
          wn  <= x"80000000";                  -- W4, padding
        end if;
        hkw  <= hkw_ld;
        dhkw <= dhkw_ld;
      else
        h <= g;
        g <= f;
        f <= e;
        e <= en;
        d <= c;
        c <= b;
        b <= a;
        a <= an;
        -- next round: h = g, d = c
        ws := csa_s(g, k_in, wn);
        wc := csa_c(g, k_in, wn);
        hkw  <= ws + wc;
        dhkw <= csa_s(ws, wc, c) + csa_c(ws, wc, c);

        if t <= 13 then                        -- W(t + 2) is a message word
          if short_r = '1' and idx <= 7 then
            wn <= ram_w;                       -- pass 2: W3-W7, pass 1's hash
          else
            wn <= msg_word;                    -- padding
          end if;
        else
          wn <= ssig1(d0) + r5 + ssig0(r13) + d14;
        end if;
      end if;

      if abort = '1' then
        running_q <= '0';
      elsif start = '1' or chain_load = '1' then
        if ld_p2 = '1' then
          t_q     <= to_unsigned(1, 6);
          idx_q   <= to_unsigned(3, 4);
          short_q <= '1';
        else
          t_q     <= to_unsigned(3, 6);
          idx_q   <= to_unsigned(5, 4);
          short_q <= '0';
        end if;
        running_q <= '1';
      elsif running = '1' then
        idx_q <= idx + 1;
        t_q <= t + 1;
        if t = 63 or (short_r = '1' and t = 60) then
          running_q <= '0';
        end if;
      end if;
    end if;
  end process;

  -- The clock after start runs the first round, which looks K one ahead.
  chain_load <= '1' when running = '1' and short_r = '1' and t = 60 and chain = '1' else '0';
  kidx <= to_unsigned(2, 6) when start = '1' and short = '1' else
          to_unsigned(4, 6) when start = '1' or chain_load = '1' else
          t + 2;
  widx <= to_unsigned(2, 4) when start = '1' and short = '1' else
          to_unsigned(4, 4) when start = '1' else
          idx;
  ctl_out <= (t => t_q, idx => idx_q, running => running_q, short_r => short_q, done_r => done_q);
  g_master : if MASTER generate
    t <= t_q; idx <= idx_q; running <= running_q; short_r <= short_q; done_r <= done_q;
  end generate;
  g_follow : if not MASTER generate
    t <= ctl_in.t; idx <= ctl_in.idx; running <= ctl_in.running;
    short_r <= ctl_in.short_r; done_r <= ctl_in.done_r;
  end generate;
  done     <= done_r;
  busy     <= running;
  h7       <= h7_r;

  -- Pass 2's first words, straight from the registers in the load clock
  -- Pass 1 just ended, so this clock loads pass 2 (the caller always starts
  -- it then). A register of each core's own, set in pass 1's last round: it
  -- selects in front of adders, and as logic shared by all units it was one
  -- net with a fanout of 500.
  ld_p2 <= ld_p2_q;
  w1    <= mid1 + b;
  mf1_e <= w1 when ld_p2 = '1' else mf1;
  -- One adder each: the midstate word is already in the per-job constant
  a_p2    <= a1m + a;
  e_p2    <= e1m + a;
  hkw_ld  <= hk1m + b when ld_p2 = '1' else hk3 + mf1;
  dhkw_ld <= dhk1m + b when ld_p2 = '1' else dhk3 + mf1;

  -- Pass 1's hash, raw, as it leaves the rounds. In the clock of round t, a
  -- and e hold the state after round t - 1; after round 63 (the load clock)
  -- a..h hold the whole hash. W7..W5 (e after rounds 60..62) are written at
  -- 7..5 in rounds 61-63 and W4 (e after round 63) at 4 in the load clock,
  -- on port B; W0 (a after round 63) at 15 in the load clock, on port A.
  -- ram_q then holds the raw word of the W built in the next clock:
  --   round 63:   b = W2 (a after round 61)  -> W2 in the load clock
  --   load clock: d = W3 (a after round 60)  -> W3 in round 1
  --   round 1:    W4, port B's write-through of the load clock -> round 2
  --   rounds 1-3 read W5..W7 at idx + 2 = 5..7 -> rounds 3-5
  --   round 11 reads W0 at idx + 2 = 15 -> round 13, the delay line
  ram_wea   <= ld_p2;
  ram_web   <= '1' when ld_p2 = '1' or (running = '1' and short_r = '0' and t >= 61) else '0';
  ram_addrb <= to_unsigned(4, 4) when ld_p2 = '1' else
               to_unsigned(4, 4) - t(3 downto 0) when short_r = '0' else
               idx + 2;
  ram : RAMB16_S36_S36
    generic map (WRITE_MODE_A => "WRITE_FIRST", WRITE_MODE_B => "WRITE_FIRST")
    port map (
      DOA => ram_doa, DOB => ram_dob, DOPA => open, DOPB => open,
      ADDRA => "000001111",
      ADDRB => ram_addrb_v,
      CLKA => clk, CLKB => clk,
      DIA => ram_dia, DIB => ram_dib,
      DIPA => "0000", DIPB => "0000",
      ENA => '1', ENB => '1', SSRA => '0', SSRB => '0',
      WEA => ram_wea, WEB => ram_web);
  ram_addrb_v <= "00000" & std_logic_vector(ram_addrb);
  ram_dia     <= std_logic_vector(a);
  ram_dib     <= std_logic_vector(e);

  process (clk)
  begin
    if rising_edge(clk) then
      if ld_p2 = '1' then
        ram_q <= d;
      elsif running = '1' and short_r = '0' and t = 63 then
        ram_q <= b;
      else
        ram_q <= unsigned(ram_dob);
      end if;
    end if;
  end process;
  ram_w  <= mid_w + ram_q;
  ovw0_e <= ram_w when short_r = '1' else ovw0;
end architecture;
