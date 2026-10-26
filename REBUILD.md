# Rebuilding the shipped bitstreams

There are two bitstreams in `bitstreams/`. They are the **same build, b6x5**
(same placement and routing), re-clocked to two frequencies:

| File | Clock | Wrong hashes over 10 min | Rate (useful) | MD5 of the `.bit` |
|---|---|---|---|---|
| `nexys2-miner-uart.bit` / `.svf` (default) | **108.33 MHz** | 0.37 % (11 in 3000) | 5.33 (5.31) MH/s | `f92ae2a7ce31525070d88a981b049dce` |
| `nexys2-miner-uart-zero-errors.bit` / `.svf` | **106.67 MHz** | 0 (0 in 2000) | 5.25 (5.25) MH/s | `6cec27a1b4c6474f61d5f73f1aedb349` |

- **108.33 MHz** finds about 1.2 % more valid shares. The few wrong hashes
  cost nothing else: the ESP32 re-hashes every hit and drops the wrong ones,
  so nothing wrong reaches the pool. The error rate rises with temperature.
- **106.67 MHz** is the highest clock with no wrong hash at all. Use it for a
  warm room, a closed case, or a board that is slower than the author's.

The numbers are from one board at room temperature. ISE is deterministic for
identical inputs and seed, so the steps below give the same placement and
routing, and the same files.

## Sources and tools

- This repository at commit `4d865f3` or later (the HDL has not changed since
  `78ec81b`; `ise/build.sh` takes `PAROPT` since `4d865f3`).
- Xilinx ISE 14.7, from AMD's VirtualBox VM "ISE 14.7 Windows 10 and
  Windows 11" (see the README for the VM notes).
- Device: `xc3s500e-fg320-4` (Digilent Nexys2 500K).

## 1. Build (inside the VM)

```bash
PAROPT="-ol high -xe n" bash ise/build.sh xc3s500e-fg320-4 6 Area 31 15 b6x5 22.94 5 uart nodisplay plain
```

| Argument | Value | Meaning |
|---|---|---|
| part | `xc3s500e-fg320-4` | |
| units | `6` | generic `NCORES` = 6 (nonce stride 8) |
| optimisation | `Area` | XST `-opt_mode Area -opt_level 1`, MAP `-cm area -c 100` |
| DCM mul / div | `31` / `15` | 103.3 MHz for the build itself |
| tag | `b6x5` | output name |
| PAR input period | `22.94` ns | the UCF's 20 ns clock period is replaced by 22.94: PAR aims at ~90 MHz and places far better than when asked for the real clock |
| PAR seed | `5` | `par -w -ol high -xe n -t 5` (high effort and extra effort, from `PAROPT`; the default effort places worse) |
| host link | `uart` | `HOST_UART` = true: 100-byte job (magic 0xB9), fixed 20-bit hit test |
| display | `nodisplay` | `SHOW_RATE` = false |
| round | `plain` | `CSA` = false, `HYBRID` = false (two carry chains for `a`) |

Expected reports:

| | |
|---|---|
| Occupied slices | 4,654 of 4,656 (99 %) |
| 4-input LUTs | 8,204 of 9,312 (88 %) |
| Block RAMs | 13 of 20 |
| Minimum period | 12.745 ns (78.46 MHz worst case) |

## 2. Re-clock

Same placement and routing, only the DCM's multiplier and divider change
(through XDL). One command per version:

```bash
bash ise/refreq.sh 13 6  b6x5_108  /tmp/nexys2-build/miner_top.ncd prom   # 108.33 MHz, the default
bash ise/refreq.sh 32 15 b6x5_1067 /tmp/nexys2-build/miner_top.ncd prom   # 106.67 MHz, zero errors
```

Each writes `ise/out/<tag>.bit` (JTAG load) and `ise/out/<tag>.svf` (PROM).
The UART divider still assumes 103.3 MHz, so the link runs 3-5 % fast; the
ESP32 driver finds the baud rate by itself.

## 3. Load (Windows, Digilent Adept Runtime)

```powershell
cd sw
python svfplay.py ..\bitstreams\nexys2-miner-uart.svf               # 108.33 MHz into the PROM (mode jumper on ROM)
python svfplay.py ..\bitstreams\nexys2-miner-uart-zero-errors.svf   # or 106.67 MHz
python jtagprog.py ..\bitstreams\nexys2-miner-uart.bit              # or straight into the FPGA until power-off
```

## 4. ESP32

ESP-Miner v2.15.4 with `esp32/esp-miner-nexys2.patch` (see `esp32/README.md`).
Set the frequency in AxeOS to match the bitstream: **108** (the patch's
default) or **107** for the zero-error one. It only sets the expected hash
rate; the driver detects 6 units and the nonce stride of 8 by itself, and
logs a running count of wrong hashes every 1000 hits.

## Measured on the board (b6x5, 10 minutes each unless noted)

| Clock | Wrong hashes | % | Useful rate | Valid shares vs 106.67 |
|---|---|---|---|---|
| 106.67 MHz | 0 in 2000 | 0 % | 5.25 MH/s | reference |
| 107.1 MHz | 5 in 3000 | 0.17 % | 5.26 MH/s | +0.3 % |
| **108.33 MHz** | 11 in 3000 | **0.37 %** | **5.31 MH/s** | **+1.2 %** |
| 110 MHz | 71 in 3000 | 2.4 % | 5.28 MH/s | +0.6 % |

Beyond 108.33 MHz each step costs more in wrong hashes than it brings.
Another chip may need a step lower (`ise/refreq.sh 17 8` for 106.25 MHz,
`21 10` for 105 MHz).
