# nexys2-miner

A SHA-256d (Bitcoin-style) miner for the **Digilent Nexys2** board
(Xilinx Spartan-3E **XC3S500E**), driven by an **ESP32-S3** running a patched
[ESP-Miner](https://github.com/bitaxeorg/ESP-Miner), the Bitaxe firmware, so the
board shows up in AxeOS like any Bitaxe: pool setup, hashrate, shares.

It mines for real: it has had shares accepted by a pool. It is also ~300,000
times slower than a single Bitaxe Gamma, so this is a project about pushing a
2007 FPGA as far as it goes, not about earning anything.

| | |
|---|---|
| Hash rate | **4.10 MH/s** (5 units x 100 MHz / 122 clocks per nonce) |
| Error rate | ~0.5 % wrong hashes, re-hashed and dropped by the ESP32 |
| Device use | 94 % of slices, 82 % of LUTs, 6 of 20 block RAMs |
| Boots from | the on-board XCF04S Platform Flash, mode jumper on ROM |

## How it works

```
pool <-stratum-> ESP32-S3 (ESP-Miner + nexys2 driver) <-UART 921600-> FPGA
                  midstate, rounds 0-2 precomputed          5 hashing units
                  re-hashes every hit                         sha256_core
```

The ESP32 builds each block header, computes the **midstate** (SHA-256 of the
first 64 bytes, the same for every nonce) and the state after **rounds 0-2** of
the second block (they only see header bytes 64..75), and sends a 76-byte job.
The FPGA only does the nonce-dependent work and reports back nonces whose hash
has 20 leading zero bits. The ESP32 re-hashes each one, keeps a running count of
wrong hashes, and passes the ones with 24 or more zero bits to ESP-Miner, which
submits those that meet the pool difficulty.

### The hashing unit (`hdl/miner_unit.vhd`, `hdl/sha256_core.vhd`)

Each of the 5 units runs both SHA-256 passes on one iterative core, one round
per clock, **122 clocks per nonce**:

- **pass 1** starts at round 3 from the precomputed state (61 rounds); its load
  shares the clock of pass 2's last round;
- **pass 2** starts from the SHA-256 IV, so round 0 is folded into its load
  clock, and it **stops after round 60**: only H7 is needed for the target
  test, and e after round 60 is what h would be after round 63 (61 clocks);
- **pass 1's hash is never captured**: its words are the last four values of
  `a` and `e`, written into a block RAM two per clock (one per port) as they
  leave the last rounds, midstate added on the way in; pass 2 reads them back
  as message words. This replaced a 256-bit register, six adders and a word
  mux per unit, and is what made room for a fifth unit;
- the round has two carry chains for `a` (T1, then T1 + T2), ~250 LUTs per
  unit smaller than the carry-save round (`csa`, one chain each for `a` and
  `e`, which the 4-unit builds used); `h+K+W` is computed one round ahead, and
  pass 2's round-0 sums with the midstate once per job;
- the message schedule lives in a delay line that maps to SRL16s, and the
  words a pass skips (W0-W2) are injected into it just before the rounds that
  tap them;
- the units run in lockstep, so unit 0 owns the round counter, state machine
  and nonce counter for all of them, and one K table in block RAM serves them
  all (XST does not merge identical registers across units by itself: sharing
  them by hand saved ~600 LUTs and ~240 flip-flops). Selects that sit in front
  of adders are per-unit registers instead: as shared logic they became nets
  with a fanout of 500;
- the units split the nonce space with a stride of 8: unit *i* hashes *i*,
  *i*+8, ... (3 nonces in 8 are skipped; a job is replaced long before its
  2^32 nonces run out).

### Clock

The core clock comes from a DCM: 50 MHz x 2 = **100 MHz**. The timing tools
only guarantee 67.4 MHz worst case (slowest silicon, 85 degC); the real chip at
room temperature runs 100 MHz with ~0.5 % wrong hashes, 103.3 MHz with ~8 %.
The 4-unit carry-save build (77.6 MHz worst case) ran 106.25 MHz without errors,
3.48 MH/s. Two tricks get there:

- `ise/build.sh` can tell PAR the input clock is slower than it is (the
  `ts_ns` argument). Asked for the true target, PAR gives up and places far
  worse; asked for ~90 MHz it places well (77.6 MHz worst case; asked for 94
  it gave 74.3, for 98 only 64.8).
- the design is built at 31/15 (103.3 MHz), then
  `ise/refreq.sh` changes only the DCM multiplier/divider of the placed and
  routed design (through XDL): the same placement measured at several
  frequencies, and the shipped one re-clocked to 2/1 (`prom` also writes the
  PROM file). The UART divider still assumes 103.3 MHz, so the link runs at
  the same ratio; the ESP32 driver scans for the baud rate if 921600 gets no
  answer, so any re-clocked bitstream works.

PAR seeds matter: on the same design, the wrong-hash rate at 103 MHz ranged
from 0 % to 33 % depending on the seed. The shipped bitstream is the best of
several (77.6 MHz worst case per the timing report, 0 wrong hashes at 103 MHz).

## Repository

| Path | |
|---|---|
| `hdl/` | VHDL-93 for XST. `miner_top.vhd` (register bus, host link, units), `miner_unit.vhd`, `sha256_core.vhd` (the core; generics `CSA`/`HYBRID` pick the round's arithmetic), `uart_bridge.vhd`, `rate_display.vhd` (7-segment hash rate, optional), `clkgen_dcm.vhd`, `nexys2.ucf`, `ja_probe.vhd` (wiring probe) |
| `sim/` | GHDL testbenches: `tb_top` (USB host, genesis block), `tb_uart` (UART host, as the ESP32 does it), `tb_display`; `ramb16_sim.vhd` models the block RAM primitive |
| `sw/` | Python host for a PC over USB: `miner.py` (stratum client, self-test, stress test), `fpga.py`, `jtagprog.py` (load a `.bit` over JTAG), `svfplay.py` (play an SVF, used to write the PROM), `cpu_miner.py` |
| `ise/` | `build.sh` (command-line ISE flow), `refreq.sh`, `probe.sh`, `sites.sh`, `geom.sh`, floorplan experiments |
| `esp32/` | The ESP-Miner changes: patch, driver sources, NVS config template |
| `bitstreams/` | The shipped UART build: `.bit` for JTAG, `.svf` for the PROM |
| `hardware/case/` | 3D-printable case for the board: `nexys2_tray.stl` and `nexys2_lid.stl` |

## Hardware

- Digilent Nexys2 with the **XC3S500E** (the 1200E version would fit ~8 units).
- ESP32-S3 **DevKitC-1 N16R8** (ESP-Miner needs the 16 MB flash and the PSRAM).
- Three wires, all 3.3 V, no level shifter:

| ESP32-S3 | Nexys2 Pmod JA |
|---|---|
| GPIO17 | pin 1 (FPGA RX, L15) |
| GPIO18 | pin 2 (FPGA TX, K12) |
| GND | pin 5 or 11 |

Do not connect the Pmod 3.3 V pins (6, 12) or the ESP32 5 V; each board keeps
its own USB power. The driver tries GPIO17/18 both ways round, so crossed
signal wires work. Not the RS-232 connector: its MAX3232 outputs +/-12 V.
If nothing answers, `hdl/ja_probe.vhd` shows on the 7-segment display which
JA pins see a signal; a missing common ground was the first failure here.

## Building the FPGA

ISE 14.7 is required (Vivado does not support the Spartan-3E). AMD now only
offers it as a VirtualBox VM ("ISE 14.7 Windows 10 and Windows 11"). Notes for
that VM under Windows 11 with Hyper-V/VBS active:

- import the `.ova` with `VBoxManage import` (the installer wrongly reports
  VT-x disabled); 1 CPU and `--paravirtprovider none`, or the guest hangs at boot;
- NAT network, and set the MAC to the one the bundled licence is tied to;
- remove the USB filters so the board stays with Windows; share this folder.

Inside the VM:

```bash
# part, units, Area, DCM mul/div, tag, PAR input period (ns), seed, host link, display, round
bash ise/build.sh xc3s500e-fg320-4 5 Area 31 15 mybuild 22.94 3 uart nodisplay plain
bash ise/refreq.sh 2 1 mybuild100 /tmp/nexys2-build/miner_top.ncd prom   # re-clock to 100 MHz
# -> ise/out/mybuild.bit (JTAG) and ise/out/mybuild.svf (PROM)
```

`depp` instead of `uart` builds the USB variant for the Python host. The chip
cannot hold both links, nor the 7-segment display next to the carry-save core.

## Loading it (Windows, Digilent Adept Runtime installed)

```powershell
cd sw
python jtagprog.py ..\bitstreams\nexys2-miner-uart.bit   # into the FPGA, until power-off
python svfplay.py  ..\bitstreams\nexys2-miner-uart.svf   # into the PROM (~40 s, verified)
```

`jtagprog.py` and `svfplay.py` only need `djtg.dll` from the Adept Runtime,
not the Adept Utilities.

## The ESP32 firmware

See [`esp32/README.md`](esp32/README.md). In short: apply the patch to
ESP-Miner, build, flash, and write an NVS image made from
`esp32/config-nexys2.cvs` with your pool and Wi-Fi.

## The Python host (optional, USB build)

```powershell
cd sw
copy pool.example.json pool.json      # then edit pool and worker
python miner.py selftest              # finds the genesis block nonce
python miner.py stress --seconds 60   # useful hash rate and wrong-hash rate
python miner.py mine --hit-bits 24
```

These need a `depp` build loaded; the shipped bitstream is the UART one.
`--sim` (bit-exact software model) and `--cpu` (real mining on the PC) work
without the board.

## What did not work

- **5 units with the carry-save round**: 103 % of slices. **Floorplanning** each unit into its own region: logic
  of different area groups never shares a slice, which costs ~190 slices
  (104-105 %), whatever the region shapes.
- **A 2-stage pipeline** (two nonces interleaved per core): doubles the state
  registers, no room.
- **Above 106.25 MHz**: wrong hashes eat the gain (see Clock); on older
  builds 25 % at 110 MHz, 79 % at 115 MHz.
- **Chaining pass 2 onto pass 1's last round** (121 clocks): pass 2's first
  state needs pass 1's last `a` plus the midstate plus a constant, two more
  adder levels on the path that already sets the clock: -10 % clock for
  +0.8 % fewer clocks.
- **3 units overclocked**: the round's critical path does not shrink with
  fewer units; it would need ~138 MHz to match 4 units.

## History

1.1 -> 1.48 -> 1.79 -> 2.07 -> 2.40 -> 2.79 -> 2.88 -> 3.00 -> 3.20 -> 3.36 ->
3.39 -> 3.48 -> **4.10 MH/s**: four units instead of three, a DCM, folding and skipping rounds,
carry-save arithmetic, shared constants and control, pass 1's hash in block
RAM for a fifth unit, and a lot of placement experiments.
