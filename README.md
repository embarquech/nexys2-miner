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
| Hash rate | **3.39 MH/s** (4 units x 103.3 MHz / 122 clocks per nonce) |
| Error rate | 0 wrong hashes over the bench runs (every hit is re-hashed by the ESP32) |
| Device use | 99 % of slices, ~90 % of LUTs |
| Boots from | the on-board XCF04S Platform Flash, mode jumper on ROM |

## How it works

```
pool <-stratum-> ESP32-S3 (ESP-Miner + nexys2 driver) <-UART 921600-> FPGA
                  midstate, rounds 0-2 precomputed          4 hashing units
                  re-hashes every hit                         sha256_core_csa
```

The ESP32 builds each block header, computes the **midstate** (SHA-256 of the
first 64 bytes, the same for every nonce) and the state after **rounds 0-2** of
the second block (they only see header bytes 64..75), and sends an 84-byte job.
The FPGA only does the nonce-dependent work and reports back nonces whose hash
has 20 leading zero bits. The ESP32 re-hashes each one, keeps a running count of
wrong hashes, and passes the ones with 26 or more zero bits to ESP-Miner, which
submits those that meet the pool difficulty.

### The hashing unit (`hdl/miner_unit.vhd`, `hdl/sha256_core_csa.vhd`)

Each of the 4 units runs both SHA-256 passes on one iterative core, one round
per clock, **122 clocks per nonce**:

- **pass 1** starts at round 3 from the precomputed state (61 rounds); its load
  shares the clock of pass 2's last round;
- **pass 2** starts from the SHA-256 IV, so round 0 is folded into its load
  clock, and it **stops after round 60**: only H7 is needed for the target
  test, and e after round 60 is what h would be after round 63 (61 clocks);
- no feed-forward clock: the state is captured with the last round, the
  midstate added on the way;
- **carry-save adders**: each round ends in a single carry chain for `a` and
  one for `e`; `h+K+W` and `d+h+K+W` are computed one round ahead;
- the message schedule lives in a delay line that maps to SRL16s, and the
  words a pass skips (W0-W2) are injected into it just before the rounds that
  tap them;
- one K table in block RAM serves all units, which run in lockstep;
- the units split the nonce space: unit *i* hashes *i*, *i*+4, *i*+8, ...

### Clock

The core clock comes from a DCM: 50 MHz x 31 / 15 = **103.3 MHz**. The timing
tools only guarantee ~74 MHz worst case (slowest silicon, 85 degC); the real
chip at room temperature runs 103 MHz without errors and starts failing around
106-110 MHz. Two tricks get there:

- `ise/build.sh` can tell PAR the input clock is slower than it is (the
  `ts_ns` argument). Asked for the true target, PAR gives up and places far
  worse; asked for ~90 MHz it places well, and the DCM still runs at 103 MHz.
- `ise/refreq.sh` changes only the DCM multiplier/divider of an already placed
  and routed design (through XDL), to measure the same placement at several
  frequencies.

PAR seeds matter: on the same design, the wrong-hash rate at 103 MHz ranged
from 0 % to 10 % depending on the seed. The shipped bitstream is the best of
several.

## Repository

| Path | |
|---|---|
| `hdl/` | VHDL-93 for XST. `miner_top.vhd` (register bus, host link, units), `miner_unit.vhd`, `sha256_core_csa.vhd` (carry-save, 122 clocks, shipped), `sha256_core.vhd` (two carry chains, 123 clocks, smaller), `uart_bridge.vhd`, `rate_display.vhd` (7-segment hash rate, optional), `clkgen_dcm.vhd`, `nexys2.ucf`, `ja_probe.vhd` (wiring probe) |
| `sim/` | GHDL testbenches: `tb_top` (USB host, genesis block), `tb_uart` (UART host, as the ESP32 does it), `tb_display` |
| `sw/` | Python host for a PC over USB: `miner.py` (stratum client, self-test, stress test), `fpga.py`, `jtagprog.py` (load a `.bit` over JTAG), `svfplay.py` (play an SVF, used to write the PROM), `cpu_miner.py` |
| `ise/` | `build.sh` (command-line ISE flow), `refreq.sh`, `probe.sh`, `sites.sh`, `geom.sh`, floorplan experiments |
| `esp32/` | The ESP-Miner changes: patch, driver sources, NVS config template |
| `bitstreams/` | The shipped UART build: `.bit` for JTAG, `.svf` for the PROM |

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
# part, units, Area, DCM mul/div, tag, PAR input period (ns), seed, host link, display, core
bash ise/build.sh xc3s500e-fg320-4 4 Area 31 15 mybuild 22.94 7 uart nodisplay sha256_core_csa.vhd
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

- **5 units**: no room. **Floorplanning** each unit into its own region: logic
  of different area groups never shares a slice, which costs ~190 slices
  (104-105 %), whatever the region shapes.
- **A 2-stage pipeline** (two nonces interleaved per core): doubles the state
  registers, no room.
- **Above ~106 MHz**: 25 % wrong hashes at 110 MHz, 79 % at 115 MHz.
- **3 units overclocked**: the round's critical path does not shrink with
  fewer units; it would need ~138 MHz to match 4 units.

## History

1.1 -> 1.48 -> 1.79 -> 2.07 -> 2.40 -> 2.79 -> 2.88 -> 3.00 -> 3.20 -> 3.36 ->
**3.39 MH/s**: four units instead of three, a DCM, folding and skipping rounds,
carry-save arithmetic, shared constants, and a lot of placement experiments.
