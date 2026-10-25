-- SHA-256 constants and round functions (FIPS 180-4), VHDL-93 for Xilinx XST.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package sha256_pkg is
  subtype word is unsigned(31 downto 0);
  type word_array is array (natural range <>) of word;

  constant K : word_array(0 to 63) := (
    x"428a2f98", x"71374491", x"b5c0fbcf", x"e9b5dba5", x"3956c25b", x"59f111f1", x"923f82a4", x"ab1c5ed5",
    x"d807aa98", x"12835b01", x"243185be", x"550c7dc3", x"72be5d74", x"80deb1fe", x"9bdc06a7", x"c19bf174",
    x"e49b69c1", x"efbe4786", x"0fc19dc6", x"240ca1cc", x"2de92c6f", x"4a7484aa", x"5cb0a9dc", x"76f988da",
    x"983e5152", x"a831c66d", x"b00327c8", x"bf597fc7", x"c6e00bf3", x"d5a79147", x"06ca6351", x"14292967",
    x"27b70a85", x"2e1b2138", x"4d2c6dfc", x"53380d13", x"650a7354", x"766a0abb", x"81c2c92e", x"92722c85",
    x"a2bfe8a1", x"a81a664b", x"c24b8b70", x"c76c51a3", x"d192e819", x"d6990624", x"f40e3585", x"106aa070",
    x"19a4c116", x"1e376c08", x"2748774c", x"34b0bcb5", x"391c0cb3", x"4ed8aa4a", x"5b9cca4f", x"682e6ff3",
    x"748f82ee", x"78a5636f", x"84c87814", x"8cc70208", x"90befffa", x"a4506ceb", x"bef9a3f7", x"c67178f2");

  -- Initial hash value, H0 in the top 32 bits.
  constant IV : unsigned(255 downto 0) :=
    x"6a09e667bb67ae853c6ef372a54ff53a510e527f9b05688c1f83d9ab5be0cd19";

  function bsig0(x : word) return word;
  function bsig1(x : word) return word;
  function ssig0(x : word) return word;
  function ssig1(x : word) return word;
  function ch(x, y, z : word) return word;
  function maj(x, y, z : word) return word;
  -- Carry-save adder: x + y + z = csa_s(x, y, z) + csa_c(x, y, z), with no
  -- carry chain; several terms reduce through LUT levels before one real add.
  function csa_s(x, y, z : word) return word;
  function csa_c(x, y, z : word) return word;
end package;

package body sha256_pkg is
  function bsig0(x : word) return word is
  begin
    return rotate_right(x, 2) xor rotate_right(x, 13) xor rotate_right(x, 22);
  end;

  function bsig1(x : word) return word is
  begin
    return rotate_right(x, 6) xor rotate_right(x, 11) xor rotate_right(x, 25);
  end;

  function ssig0(x : word) return word is
  begin
    return rotate_right(x, 7) xor rotate_right(x, 18) xor shift_right(x, 3);
  end;

  function ssig1(x : word) return word is
  begin
    return rotate_right(x, 17) xor rotate_right(x, 19) xor shift_right(x, 10);
  end;

  function ch(x, y, z : word) return word is
  begin
    return (x and y) xor ((not x) and z);
  end;

  function maj(x, y, z : word) return word is
  begin
    return (x and y) xor (x and z) xor (y and z);
  end;
  function csa_s(x, y, z : word) return word is
  begin
    return x xor y xor z;
  end;

  function csa_c(x, y, z : word) return word is
  begin
    return shift_left(maj(x, y, z), 1);
  end;
end package body;
