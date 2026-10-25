"""Load a .bit file into the Nexys2's FPGA over JTAG, using djtg.dll from the
Digilent Adept Runtime (no Adept Utilities / djtgcfg needed).

  python jtagprog.py ..\\ise\\out\\miner_top.bit [--device Nexys2]

JTAG chain on the Nexys2: TDI -> XC3S500E/1200E (IR 6) -> XCF04S PROM (IR 8) -> TDO.
The PROM is kept in BYPASS. Sequence from UG332 (Spartan-3 Generation
Configuration User Guide), JTAG configuration: JPROGRAM, CFG_IN + bitstream,
JSTART, then clocks in Run-Test/Idle.
"""
import argparse
import ctypes
import time

FPGA_IR_LEN = 6
PROM_IR_LEN = 8
JPROGRAM = 0b001011
CFG_IN = 0b000101
JSTART = 0b001100
BYPASS_FPGA = 0b111111
BYPASS_PROM = 0xFF
IDCODE_FPGA = {0x1C22093: "XC3S500E", 0x1C2E093: "XC3S1200E"}


def read_bit(path):
    """Configuration data of a Xilinx .bit file (the 'e' field)."""
    d = open(path, "rb").read()
    n = int.from_bytes(d[0:2], "big")
    i = 2 + n + 2                        # skip the fixed header and the 'a' key length
    fields = {}
    while i < len(d):
        key = chr(d[i])
        i += 1
        if key == "e":
            length = int.from_bytes(d[i:i + 4], "big")
            fields["e"] = d[i + 4:i + 4 + length]
            break
        length = int.from_bytes(d[i:i + 2], "big")
        fields[key] = d[i + 2:i + 2 + length].rstrip(b"\0").decode()
        i += 2 + length
    return fields


class Jtag:
    def __init__(self, device):
        self.dmgr = ctypes.WinDLL("dmgr")
        self.djtg = ctypes.WinDLL("djtg")
        self.hif = ctypes.c_uint32()
        if not self.dmgr.DmgrOpen(ctypes.byref(self.hif), device.encode()):
            raise RuntimeError(f"DmgrOpen({device!r}) failed, erc={self.dmgr.DmgrGetLastError()}")
        if not self.djtg.DjtgEnable(self.hif):
            raise RuntimeError(f"DjtgEnable failed, erc={self.dmgr.DmgrGetLastError()}")

    def close(self):
        self.djtg.DjtgDisable(self.hif)
        self.dmgr.DmgrClose(self.hif)

    def tms(self, bits, n):
        """Clock n TMS bits (LSB first) with TDI low."""
        buf = (ctypes.c_ubyte * 8)(*bits.to_bytes(8, "little"))
        if not self.djtg.DjtgPutTmsBits(self.hif, False, buf, None, n, False):
            raise RuntimeError("DjtgPutTmsBits failed")

    def shift(self, value, n, read=False):
        """Shift n bits (LSB first) in Shift-IR/DR; the last bit leaves to Exit1."""
        out = 0
        if n > 1:
            nbytes = (n - 1 + 7) // 8
            buf = (ctypes.c_ubyte * nbytes)(*(value & ((1 << (n - 1)) - 1)).to_bytes(nbytes, "little"))
            rcv = (ctypes.c_ubyte * nbytes)()
            if not self.djtg.DjtgPutTdiBits(self.hif, False, buf, rcv if read else None, n - 1, False):
                raise RuntimeError("DjtgPutTdiBits failed")
            out = int.from_bytes(bytes(rcv), "little")
        last = (value >> (n - 1)) & 1
        pair = (ctypes.c_ubyte * 1)(last | 0b10)  # TDI = last bit, TMS = 1
        rcv1 = (ctypes.c_ubyte * 1)()
        if not self.djtg.DjtgPutTmsTdiBits(self.hif, pair, rcv1, 1, False):
            raise RuntimeError("DjtgPutTmsTdiBits failed")
        return out | ((rcv1[0] & 1) << (n - 1))

    def shift_bytes(self, data):
        """Shift a large buffer into Shift-DR, leaving with TMS on the last bit."""
        body, last = data[:-1], data[-1]
        if body:
            buf = (ctypes.c_ubyte * len(body)).from_buffer_copy(body)
            if not self.djtg.DjtgPutTdiBits(self.hif, False, buf, None, len(body) * 8, False):
                raise RuntimeError("DjtgPutTdiBits failed")
        self.shift(last, 8)

    def reset(self):
        self.tms(0b011111, 6)            # Test-Logic-Reset, then Run-Test/Idle

    def ir(self, fpga_ir):
        """Load the FPGA IR, PROM in BYPASS; ends in Run-Test/Idle."""
        self.tms(0b0011, 4)              # RTI -> Select-DR -> Select-IR -> Capture-IR -> Shift-IR
        value = BYPASS_PROM | (fpga_ir << PROM_IR_LEN)
        captured = self.shift(value, PROM_IR_LEN + FPGA_IR_LEN, read=True)
        self.tms(0b01, 2)                # Exit1 -> Update -> RTI
        return captured >> PROM_IR_LEN   # the FPGA's IR capture bits

    def dr_begin(self):
        self.tms(0b001, 3)               # RTI -> Select-DR -> Capture-DR -> Shift-DR

    def dr_end(self):
        self.tms(0b01, 2)                # Exit1 -> Update -> RTI

    def idcodes(self):
        self.reset()
        self.dr_begin()
        v = self.shift(0, 64, read=True)
        self.dr_end()
        return v & 0xFFFFFFFF, v >> 32   # first out is the PROM, nearest TDO

    def idle(self, clocks):
        self.tms(0, clocks)


def reverse_bits(data):
    table = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
    return data.translate(table)


def program(jt, config):
    jt.reset()
    jt.ir(JPROGRAM)
    jt.ir(CFG_IN)
    time.sleep(0.02)                     # INIT_B: configuration memory clear
    jt.ir(CFG_IN)
    jt.dr_begin()
    # The bitstream goes in MSB first per byte; JTAG shifts LSB first. The PROM's
    # bypass bit trails the FPGA, so one padding byte flushes the last real bit.
    jt.shift_bytes(reverse_bits(config) + b"\0")
    jt.dr_end()
    jt.ir(JSTART)
    jt.idle(64)
    status = jt.ir(BYPASS_FPGA)
    jt.reset()
    return status


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bitfile")
    ap.add_argument("--device", default="Nexys2")
    args = ap.parse_args()
    fields = read_bit(args.bitfile)
    print(f"{args.bitfile}: design {fields.get('a')}, part {fields.get('b')}, "
          f"built {fields.get('c')} {fields.get('d')}, {len(fields['e'])} bytes")
    jt = Jtag(args.device)
    try:
        prom, fpga = jt.idcodes()
        name = IDCODE_FPGA.get(fpga & 0x0FFFFFFF)
        print(f"FPGA IDCODE 0x{fpga:08X} ({name or 'unknown'}), PROM 0x{prom:08X}")
        if name is None or name.lower()[2:] not in fields.get("b", "").lower():
            raise SystemExit(f"bitstream part {fields.get('b')} does not match the board")
        t0 = time.monotonic()
        status = program(jt, fields["e"])
        # Spartan-3E IR capture: bit 5 = DONE, bit 4 = INIT_B (UG332, JTAG IR capture).
        done = bool(status & 0b100000)
        print(f"loaded in {time.monotonic() - t0:.1f} s, IR capture 0b{status:06b}, "
              f"DONE={'high' if done else 'LOW'}")
        raise SystemExit(0 if done else 1)
    finally:
        jt.close()


if __name__ == "__main__":
    main()
