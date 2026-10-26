# Rebuilding the shipped bitstream

The bitstream in `bitstreams/` (MD5 of the `.bit`: `6cec27a1b4c6474f61d5f73f1aedb349`)
is build **b6x5** re-clocked to 106.67 MHz: 6 hashing units, 5.25 MH/s, 0 wrong
hashes in 2000 checked over 10 minutes on the author's board. ISE is
deterministic for identical inputs and seed, so these steps give the same
placement and routing.

## Sources and tools

- This repository at commit `78ec81b` or later for the HDL; `ise/build.sh`
  needs the `PAROPT` variable (added after it).
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

## 2. Re-clock to 106.67 MHz

Same placement and routing, only the DCM changes (through XDL):

```bash
bash ise/refreq.sh 32 15 b6x5_1067 /tmp/nexys2-build/miner_top.ncd prom
```

DCM x32 / 15 = 106.67 MHz. Outputs `ise/out/b6x5_1067.bit` (JTAG load) and
`ise/out/b6x5_1067.svf` (PROM). The UART divider still assumes 103.3 MHz, so
the link runs 3.2 % fast; the ESP32 driver finds the baud rate by itself.

## 3. Load (Windows, Digilent Adept Runtime)

```powershell
cd sw
python svfplay.py ..\ise\out\b6x5_1067.svf   # writes the XCF04S PROM; mode jumper on ROM
python jtagprog.py ..\ise\out\b6x5_1067.bit  # or straight into the FPGA until power-off
```

## 4. ESP32

ESP-Miner v2.15.4 with `esp32/esp-miner-nexys2.patch` (see `esp32/README.md`),
frequency setting **107** in AxeOS (the patch's default). The driver detects 6
units and the nonce stride of 8 from the bitstream.

## Measured on the board

| Clock | Wrong hashes | Rate |
|---|---|---|
| 106.67 MHz | 0 in 2000 over 10 min | 5.25 MH/s |
| 107.1 MHz | 0 in 2 min, 5 in 3000 over 10 min | 5.27 MH/s |
| 108.3 MHz | 1 in 2 min | 5.33 MH/s |

The shipped clock is the highest with no wrong hashes over 10 minutes. These are one board at
room temperature: another chip may need a step lower (`ise/refreq.sh 17 8`
for 106.25 MHz, `21 10` for 105 MHz).
