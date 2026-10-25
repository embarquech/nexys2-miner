-- miner_top with HOST_UART, driven through its UART pins like the ESP32 does:
-- magic, a job, hit, nonce read-back, dark-mode register. The UART build
-- always starts at nonce 0 and its hit mask is fixed at 20 bits, so the job
-- is the genesis header and the first hit is nonce word 0x3417D (213 373,
-- found with hashlib). A fast baud
-- rate (10 clocks per bit) keeps the simulation short.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_uart is
end entity;

architecture sim of tb_uart is
  constant MIDSTATE : std_logic_vector(255 downto 0) :=
    x"bc909a336358bff090ccac7d1e59caa8c3c8d8e94f0103c896b187364719f91b";
  constant TAIL     : std_logic_vector(95 downto 0) := x"4b1e5e4a29ab5f49ffff001d";
  -- state after rounds 0-2 of the second block (sw/sha256_mid.state3)
  constant STATE3   : std_logic_vector(255 downto 0) :=
    x"de8459101f8aee5cb7f888dfbc909a33238956e3af5e1cbaa8a8881cc3c8d8e9";
  constant WINNER   : unsigned(31 downto 0) := x"0003417d";
  constant BIT_T    : time := 200 ns;               -- 5 Mbaud at a 50 MHz clock

  signal clk      : std_logic := '0';
  signal to_fpga  : std_logic := '1';
  signal from_fpga : std_logic;
  signal led      : std_logic_vector(3 downto 0);
  signal an       : std_logic_vector(3 downto 0);
  signal stop_clk : boolean := false;
begin
  clk <= not clk after 10 ns when not stop_clk;

  dut : entity work.miner_top
    generic map (NCORES => 4, CLK_MUL => 1, CLK_DIV => 1,
                 HOST_UART => true, UART_BAUD => 5_000_000)
    port map (clk50 => clk, EppAstb => '1', EppDstb => '1', EppWr => '1',
              EppWait => open, EppDB => open, UartRx => to_fpga, UartTx => from_fpga,
              Btn => "0000", Seg => open, An => an, Led => led);

  host : process
    procedure send(b : std_logic_vector(7 downto 0)) is
    begin
      to_fpga <= '0'; wait for BIT_T;
      for i in 0 to 7 loop
        to_fpga <= b(i); wait for BIT_T;
      end loop;
      to_fpga <= '1'; wait for BIT_T;
    end;

    procedure recv(b : out std_logic_vector(7 downto 0)) is
    begin
      wait until from_fpga = '0';
      wait for BIT_T * 3 / 2;
      for i in 0 to 7 loop
        b(i) := from_fpga; wait for BIT_T;
      end loop;
      assert from_fpga = '1' report "bad stop bit" severity failure;
    end;

    procedure write_cmd(cmd : std_logic_vector(7 downto 0); a : natural; data : std_logic_vector) is
      variable ack : std_logic_vector(7 downto 0);
      constant n   : natural := data'length / 8;
      variable d   : std_logic_vector(data'length - 1 downto 0) := data;
    begin
      send(cmd); send(std_logic_vector(to_unsigned(a, 8)));
      send(std_logic_vector(to_unsigned(n, 8)));
      for i in 0 to n - 1 loop
        send(d(d'left - 8 * i downto d'left - 8 * i - 7));
      end loop;
      recv(ack);
      assert ack = x"06" report "no ack" severity failure;
    end;

    procedure write_regs(a : natural; data : std_logic_vector) is
    begin
      write_cmd(x"57", a, data);
    end;

    procedure read_regs(a : natural; n : natural; v : out unsigned) is
      variable b : std_logic_vector(7 downto 0);
    begin
      send(x"52"); send(std_logic_vector(to_unsigned(a, 8)));
      send(std_logic_vector(to_unsigned(n, 8)));
      for i in 0 to n - 1 loop
        recv(b);
        v(v'left - 8 * i downto v'left - 8 * i - 7) := unsigned(b);
      end loop;
    end;

    variable v16   : unsigned(15 downto 0);
    variable v8    : unsigned(7 downto 0);
    variable v32   : unsigned(31 downto 0);
    variable tries : natural := 0;
  begin
    wait for 1 us;
    send(x"FF");                                     -- noise is ignored
    read_regs(16#4E#, 2, v16);
    assert v16 = x"B704" report "bad magic/ncores" severity failure;
    report "magic ok, 4 units";

    write_cmd(x"4A", 16#00#, MIDSTATE & TAIL & x"00000000" & x"000000FF" & STATE3);
    write_regs(16#38#, x"01");
    loop
      read_regs(16#39#, 1, v8);
      exit when v8(1) = '1';
      tries := tries + 1;
      assert tries < 100000 report "no hit" severity failure;
    end loop;
    read_regs(16#40#, 4, v32);
    assert v32 = WINNER + 4 report "WRONG nonce" severity failure;
    report "hit nonce read back over UART";

    assert led(0) = '1' report "LD0 should be on" severity failure;
    write_regs(16#3B#, x"01");
    wait for 100 ns;
    assert led = "0000" and an = "1111" report "dark mode not dark" severity failure;
    read_regs(16#3B#, 1, v8);
    assert v8 = x"01" report "0x3B read-back" severity failure;
    report "PASS: UART host";
    stop_clk <= true;
    wait;
  end process;
end architecture;
