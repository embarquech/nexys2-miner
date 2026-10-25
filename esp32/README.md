# ESP32-S3 host: ESP-Miner with a Nexys2 "ASIC"

The Nexys2 is driven by [ESP-Miner](https://github.com/bitaxeorg/ESP-Miner), the
Bitaxe firmware, with one more chip type: `NEXYS2`. Everything else (Wi-Fi,
stratum, AxeOS, pool settings, statistics) is stock.

## Files

| File | |
|---|---|
| `esp-miner-nexys2.patch` | All the changes, as `git diff` from the base below |
| `components/asic/nexys2.c`, `include/nexys2.h` | The driver (also in the patch) |
| `config-nexys2.cvs` | NVS template: board, pool, no display or self-test |

The patch was made on ESP-Miner **v2.15.4** plus the share-statistics commits of
the `dan/oled-share-stats` fork (built with ESP-IDF 5.5). The driver, device and
hashrate changes apply to stock ESP-Miner; the `/api/system/cores` hunk in
`http_server.c` only exists in that fork, so drop it on stock code.

## What the patch does

- **`components/asic/nexys2.c`**: the driver. It talks to the FPGA over UART1
  (GPIO17/18, 921600 baud) with the protocol in `hdl/uart_bridge.vhd`:
  - on each job, builds the 80-byte header, computes the midstate and the state
    after rounds 0-2, and sends the 84-byte job with one `J` command;
  - polls for hits every 20 ms, re-hashes each one, counts wrong hashes (logged
    every 1000 hits) and passes hashes with 26+ leading zero bits to ESP-Miner;
  - reads the FPGA's nonce counter once a second for the hash rate;
  - finds the FPGA at boot, and swaps TX/RX itself if the wires are crossed;
  - switches the board's LEDs and display with the `fpgaLightsOff` setting.
- **`asic.c`**, **`device_config.h`**: the `NEXYS2` chip and family, board
  version `nexys2`, no I2C bus, regulator, fan, sensors or display.
- **`hashrate_monitor_task.c`**: a `REGISTER_HASHRATE_HPS` register type, the
  hash rate in plain H/s (the BM chips' 2^20-hash unit is too coarse for MH/s).
- **`power_management_task.c`**: expected hash rate = frequency x 4 / 122, and
  applies `fpgaLightsOff` when it changes.
- **`display.c`**: no I2C bus means no display, instead of a failed init that
  would stop mining.
- **NVS / API / AxeOS**: the `fpgaLightsOff` setting (checkbox in Settings,
  shown for the Nexys2 only), `Nexys2 FPGA` in the ASIC model enum.
- **`http_server.c`**: `/api/system/cores` reports the chip's own core count,
  so the Shares page shows 4 cells instead of 128.

## Build and flash (DevKitC-1 N16R8)

```bash
git apply esp-miner-nexys2.patch        # in the ESP-Miner tree
idf.py build
```

Make an NVS image from the template with your pool and Wi-Fi filled in:

```bash
python $IDF_PATH/components/nvs_flash/nvs_partition_generator/nvs_partition_gen.py \
    generate config-nexys2.cvs nvs.bin 0x6000
esptool.py --chip esp32s3 -p COMx -b 460800 write_flash \
    0x0 build/bootloader/bootloader.bin 0x8000 build/partition_table/partition-table.bin \
    0x9000 nvs.bin 0x10000 build/esp-miner.bin 0xf10000 build/ota_data_initial.bin
```

Without Wi-Fi in NVS it opens its `Bitaxe_XXXX` access point like any Bitaxe.

Notes: keep `selftest` unset (it would fail on the missing sensors); the
`frequency` setting is informative only, the FPGA clock is fixed by the
bitstream (103 MHz, so set 103 for a correct expected hash rate).
