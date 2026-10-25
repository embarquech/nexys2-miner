-- Drives miner_top through its DEPP pins like the Adept host does, loads the
-- Bitcoin genesis block 40 nonces before the winning one, and checks the hit.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_top is
end entity;

architecture sim of tb_top is
  constant MIDSTATE : std_logic_vector(255 downto 0) :=
    x"bc909a336358bff090ccac7d1e59caa8c3c8d8e94f0103c896b187364719f91b";
  constant TAIL     : std_logic_vector(95 downto 0) := x"4b1e5e4a29ab5f49ffff001d";
  -- state after rounds 0-2 of the second block (sw/sha256_mid.state3)
  constant STATE3   : std_logic_vector(255 downto 0) :=
    x"de8459101f8aee5cb7f888dfbc909a33238956e3af5e1cbaa8a8881cc3c8d8e9";
  constant WINNER   : unsigned(31 downto 0) := x"1dac2b7c";
  constant FIRST_W  : std_logic_vector(31 downto 0) := std_logic_vector(WINNER - 40);

  signal clk     : std_logic := '0';
  signal astb    : std_logic := '1';
  signal dstb    : std_logic := '1';
  signal wr      : std_logic := '1';
  signal wt      : std_logic;
  signal db      : std_logic_vector(7 downto 0) := (others => 'Z');
  signal led     : std_logic_vector(3 downto 0);
  signal stop_clk : boolean := false;
begin
  clk <= not clk after 10 ns when not stop_clk;

  dut : entity work.miner_top
    generic map (NCORES => 4)
    port map (clk50 => clk, EppAstb => astb, EppDstb => dstb, EppWr => wr,
              EppWait => wt, EppDB => db, UartRx => '1', UartTx => open, Btn => "0000", Seg => open, An => open,
              Led => led);

  host : process
    procedure set_addr(a : natural) is
    begin
      db <= std_logic_vector(to_unsigned(a, 8)); wr <= '0'; wait for 30 ns;
      astb <= '0'; wait until wt = '1';
      astb <= '1'; wait until wt = '0';
      wr <= '1'; db <= (others => 'Z'); wait for 30 ns;
    end;

    procedure put(a : natural; v : std_logic_vector(7 downto 0)) is
    begin
      set_addr(a);
      db <= v; wr <= '0'; wait for 30 ns;
      dstb <= '0'; wait until wt = '1';
      dstb <= '1'; wait until wt = '0';
      wr <= '1'; db <= (others => 'Z'); wait for 30 ns;
    end;

    procedure get(a : natural; v : out std_logic_vector(7 downto 0)) is
    begin
      set_addr(a);
      dstb <= '0'; wait until wt = '1'; wait for 5 ns;
      v := db;
      dstb <= '1'; wait until wt = '0';
      wait for 30 ns;
    end;

    procedure put32(a : natural; v : std_logic_vector(31 downto 0)) is
    begin
      for i in 0 to 3 loop
        put(a + i, v(31 - 8 * i downto 24 - 8 * i));
      end loop;
    end;

    procedure get32(a : natural; v : out unsigned(31 downto 0)) is
      variable b : std_logic_vector(7 downto 0);
    begin
      for i in 0 to 3 loop
        get(a + i, b);
        v(31 - 8 * i downto 24 - 8 * i) := unsigned(b);
      end loop;
    end;

    variable b     : std_logic_vector(7 downto 0);
    variable n     : unsigned(31 downto 0);
    variable tries : natural := 0;
  begin
    wait for 200 ns;
    get(16#4E#, b);
    assert b = x"B7" report "bad magic" severity failure;
    get(16#4F#, b);
    report "NCORES = " & integer'image(to_integer(unsigned(b)));

    -- job port: midstate, tail, first, mask, state3, all to address 0
    for i in 0 to 31 loop
      put(0, MIDSTATE(255 - 8 * i downto 248 - 8 * i));
    end loop;
    for i in 0 to 11 loop
      put(0, TAIL(95 - 8 * i downto 88 - 8 * i));
    end loop;
    for i in 0 to 3 loop
      put(0, FIRST_W(31 - 8 * i downto 24 - 8 * i));
    end loop;
    for i in 0 to 3 loop
      put(0, x"FF");
    end loop;
    for i in 0 to 31 loop
      put(0, STATE3(255 - 8 * i downto 248 - 8 * i));
    end loop;
    put(16#38#, x"01");

    loop
      get(16#39#, b);
      exit when b(1) = '1';
      tries := tries + 1;
      assert tries < 2000 report "no hit" severity failure;
      wait for 2 us;
    end loop;
    get32(16#40#, n);
    report "hit nonce word = " & integer'image(to_integer(n(31 downto 16))) & ":" &
           integer'image(to_integer(n(15 downto 0)));
    assert n = WINNER + 4 report "WRONG nonce" severity failure;
    get32(16#44#, n);
    assert n > WINNER - 40 report "progress did not advance" severity failure;
    get(16#48#, b);
    report "hits = " & integer'image(to_integer(unsigned(b)));
    put(16#38#, x"02");
    report "PASS: genesis nonce found" severity note;
    stop_clk <= true;
    wait;
  end process;
end architecture;
