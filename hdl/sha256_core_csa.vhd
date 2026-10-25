-- Iterative SHA-256 compression for the two passes of a Bitcoin header hash,
-- one round per clock, with the rounds that do not depend on the nonce taken
-- out:
--   pass 1 (short = '0'): starts at round 3 from a state the host computed
--          once per job (rounds 0-2 only see header words 64..75); 62 clocks.
--   pass 2 (short = '1'): starts from the SHA-256 IV, so round 0 is folded
--          into the load clock, and it stops after round 60 (only H7 is
--          needed, and e then already holds the final h); 61 clocks.
-- There is no separate feed-forward clock: the state is captured with the last
-- round, adding ff_in to the words that come straight from registers (b, c, d,
-- f, g, h). Words 0 and 4 come out of the round's adders and are left raw, or
-- the add would sit on the critical path; the caller adds ff_in there. Pass 2
-- only uses word 4, raw e (H7 = IV H7 + e).
-- (Capturing everything raw would leave 256 flip-flops per core without a LUT
-- to share a slice with, which no longer fits the XC3S500E.)
--
-- h + K(t) + W(t) and d + h + K(t) + W(t) are computed one round ahead (h and
-- d of the next round are the current g and c). The round then reduces its
-- terms with carry-save adders and ends in one carry chain for each of a and e:
--   e = dhkw + S1(e) + Ch(e,f,g)                 one CSA level, one adder
--   a = hkw + S1(e) + Ch(e,f,g) + S0(a) + Maj    three CSA levels, one adder
-- Carry chains are what limit the clock on a Spartan-3E. This costs ~350 LUTs
-- per core more than sha256_core.vhd (two chains on e -> a).
--
-- The message is read one word per clock: widx says which word is wanted on
-- msg_word. The schedule history only needs W(t), W(t-5), W(t-13) and
-- W(t-14), so it lives in a delay line that XST maps to SRL16s. The words a
-- pass skips (W0-W2 in pass 1, W0 in pass 2) never enter it; the caller
-- supplies them on ovw0..ovw2 and they are written into the last two stages
-- of the line just before the rounds that tap them, so the W adders only ever
-- see registers (a mux on the taps put the round counter on the W path).
--
-- The round constants come from outside: kidx says which K is wanted on k_in
-- during the next clock, so one registered K table serves cores in lockstep.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sha256_pkg.all;

entity sha256_core is
  generic (
    MASTER : boolean := true);                 -- false: take t, running... from ctl_in
  port (
    clk       : in  std_logic;
    abort     : in  std_logic;                 -- drops the block in progress
    start     : in  std_logic;                 -- one-cycle pulse
    short     : in  std_logic;                 -- read on start: '1' = pass 2
    state_in  : in  unsigned(255 downto 0);    -- pass 1: state after round 2
    hk3       : in  word;                      -- pass 1: h + K(3) of state_in
    dhk3      : in  word;                      -- pass 1: d + h + K(3) of state_in
    ff_in     : in  unsigned(255 downto 0);    -- pass 1 chaining value (midstate)
    mf0       : in  word;                      -- pass 2: W0, read on start
    mf1       : in  word;                      -- the first round's W of the pass being loaded:
                                               -- W1 (pass 2) or W3, the nonce (pass 1)
    nonce_in  : in  word;                      -- unused (mf1 carries the nonce)
    chain     : in  std_logic;                 -- start pass 1 straight from pass 2's last round
    widx      : out unsigned(3 downto 0);      -- index of the word wanted on msg_word
    msg_word  : in  word;                      -- message word widx
    ovw0      : in  word;                      -- W0 of the current pass
    ovw1      : in  word;                      -- W1 (pass 1)
    ovw2      : in  word;                      -- W2 (pass 1)
    kidx      : out unsigned(5 downto 0);      -- K index wanted on k_in next clock
    k_in      : in  word;                      -- K(t + 1) during round t
    done      : out std_logic;                 -- one-cycle pulse, hash_out valid
    busy      : out std_logic;                 -- running (also right after a chained load)
    hash_out  : out unsigned(255 downto 0);    -- words 0, 4 raw; others ff_in + raw
    ctl_in    : in  core_ctl_t;                -- the master core's control registers
    ctl_out   : out core_ctl_t);               -- this core's (the master's) registers
end entity;

architecture rtl of sha256_core is
  type delay5_t is array (1 to 5) of word;
  type delay8_t is array (6 to 13) of word;

  function iv_w(i : natural) return word is
  begin
    return IV(255 - 32 * i downto 224 - 32 * i);
  end;

  -- Round 0 of pass 2 on the IV: everything but W0 is constant.
  constant T1_IV : word := iv_w(7) + bsig1(iv_w(4)) + ch(iv_w(4), iv_w(5), iv_w(6)) + K(0);
  constant A1_IV : word := T1_IV + bsig0(iv_w(0)) + maj(iv_w(0), iv_w(1), iv_w(2));
  constant E1_IV : word := iv_w(3) + T1_IV;
  constant HK1_IV : word := iv_w(6) + K(1);    -- h after round 0 is IV g
  constant DHK1_IV : word := iv_w(2) + HK1_IV; -- and d is IV c

  signal a, b, c, d, e, f, g, h : word;
  signal hkw     : word;                       -- h + K(t) + W(t)
  signal dhkw    : word;                       -- d + h + K(t) + W(t)
  signal wn      : word;                       -- W(t + 1)
  signal d0      : word;                       -- W(t)
  signal s5      : delay5_t;                   -- s5(k) = W(t - k)
  signal s8      : delay8_t;                   -- s8(k) = W(t - k)
  signal d14     : word;                       -- W(t - 14)
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
  signal hash_r  : unsigned(255 downto 0) := (others => '0');
  signal chain_load : std_logic;               -- pass 2's last round also loads pass 1

  function sw(v : unsigned(255 downto 0); i : natural) return word is
  begin
    return v(255 - 32 * i downto 224 - 32 * i);
  end;
begin
  -- Schedule delay line: no reset and a single enable, so it maps to SRL16.
  process (clk)
  begin
    if rising_edge(clk) then
      if start = '1' or running = '1' then
        if start = '1' or chain_load = '1' then
          d0 <= mf1;                           -- the first round's W
        else
          d0 <= wn;
        end if;
        s5(1) <= d0;
        for k in 2 to 5 loop
          s5(k) <= s5(k - 1);
        end loop;
        s8(6) <= s5(5);
        for k in 7 to 12 loop
          s8(k) <= s8(k - 1);
        end loop;
        s8(13) <= s8(12);
        d14    <= s8(13);
        -- Taps reaching before the first pushed word: pass 1 needs
        -- (W(t-13), W(t-14)) = (W1, W0) at t = 14 and (W2, W1) at 15, then
        -- W2 at 16, which the shift brings along by itself; pass 2 only
        -- needs W0 at t = 14.
        if running = '1' and t = 13 then
          d14 <= ovw0;
          if short_r = '0' then
            s8(13) <= ovw1;
          end if;
        elsif running = '1' and t = 14 and short_r = '0' then
          s8(13) <= ovw2;
        end if;
      end if;
    end if;
  end process;

  -- One load path, taken on a start or on a chained pass 1, so the state
  -- registers keep a single load mux (a second one for the chained load alone
  -- costs 256 LUTs per core and does not fit).
  process (clk)
    variable s1, chv, s0, mj, an, en : word;
    variable ys, yc, zs, zc, ws, wc : word;
    variable ld_p2 : boolean;
  begin
    if rising_edge(clk) then
      s1  := bsig1(e);
      chv := ch(e, f, g);
      s0  := bsig0(a);
      mj  := maj(a, b, c);
      en := csa_s(dhkw, s1, chv) + csa_c(dhkw, s1, chv);
      ys := csa_s(hkw, s1, chv);
      yc := csa_c(hkw, s1, chv);
      zs := csa_s(ys, yc, s0);
      zc := csa_c(ys, yc, s0);
      an := csa_s(zs, zc, mj) + csa_c(zs, zc, mj);

      done_q <= '0';
      -- Capture with the last round instead of spending a clock on the
      -- feed-forward add (see the header comment for words 0 and 4).
      if running = '1' and (t = 63 or (short_r = '1' and t = 60)) then
        done_q <= '1';
        hash_r <= an & (sw(ff_in, 1) + a) & (sw(ff_in, 2) + b) & (sw(ff_in, 3) + c) &
                  en & (sw(ff_in, 5) + e) & (sw(ff_in, 6) + f) & (sw(ff_in, 7) + g);
      end if;

      if abort = '1' then
        running_q <= '0';
      elsif start = '1' or chain_load = '1' then
        -- Pass 1 starts from registers only (state3, the next nonce), so its
        -- load can share pass 2's last clock (chain_load): one clock less per
        -- nonce. Pass 2 cannot do that after pass 1, it needs pass 1's last a.
        ld_p2 := start = '1' and short = '1';
        if ld_p2 then                          -- pass 2: state after round 0
          a <= A1_IV + mf0;
          b <= iv_w(0);
          c <= iv_w(1);
          d <= iv_w(2);
          e <= E1_IV + mf0;
          f <= iv_w(4);
          g <= iv_w(5);
          h <= iv_w(6);
          hkw  <= HK1_IV + mf1;
          dhkw <= DHK1_IV + mf1;
          t_q <= to_unsigned(1, 6);
          idx_q <= to_unsigned(3, 4);
          wn  <= msg_word;                     -- W2
          short_q <= '1';
        else                                   -- pass 1: state after round 2
          a <= sw(state_in, 0);
          b <= sw(state_in, 1);
          c <= sw(state_in, 2);
          d <= sw(state_in, 3);
          e <= sw(state_in, 4);
          f <= sw(state_in, 5);
          g <= sw(state_in, 6);
          h <= sw(state_in, 7);
          hkw  <= hk3 + mf1;
          dhkw <= dhk3 + mf1;
          t_q <= to_unsigned(3, 6);
          idx_q <= to_unsigned(5, 4);
          wn  <= x"80000000";                  -- W4, padding
          short_q <= '0';
        end if;
        running_q <= '1';
      elsif running = '1' then
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
          wn <= msg_word;
        else
          wn <= ssig1(d0) + s5(5) + ssig0(s8(13)) + d14;
        end if;
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
  hash_out <= hash_r;
end architecture;
