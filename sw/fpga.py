"""Access to the miner's registers: on the Nexys2 through Digilent Adept DEPP,
or a bit-accurate software model of the same registers for testing."""
import ctypes
import struct
import time

import sha256_mid

REG_JOB = 0x00          # 84-byte job port: midstate, tail, first, mask, state3
REG_CTRL = 0x38
REG_STATUS = 0x39
REG_CLEAR = 0x3A
REG_FOUND = 0x40
REG_PROGRESS = 0x44
REG_HITS = 0x48
REG_MAGIC = 0x4E
REG_NCORES = 0x4F
MAGIC = 0xB7


class Depp:
    """Digilent Adept 2 DEPP port (dmgr.dll + depp.dll from the Adept Runtime)."""

    def __init__(self, device):
        self.dmgr = ctypes.WinDLL("dmgr")
        self.depp = ctypes.WinDLL("depp")
        self.hif = ctypes.c_uint32(0)
        if not self.dmgr.DmgrOpen(ctypes.byref(self.hif), device.encode()):
            raise RuntimeError(f"DmgrOpen({device!r}) failed, erc={self._erc()} "
                               "(check the name with: djtgcfg enum)")
        if not self.depp.DeppEnable(self.hif):
            self.dmgr.DmgrClose(self.hif)
            raise RuntimeError(f"DeppEnable failed, erc={self._erc()}")

    def _erc(self):
        return self.dmgr.DmgrGetLastError()

    def write(self, addr, data, fixed=False):
        """Write consecutive registers starting at addr, or all to addr."""
        pairs = bytearray()
        for i, b in enumerate(data):
            pairs += bytes((addr if fixed else addr + i, b))
        buf = (ctypes.c_ubyte * len(pairs)).from_buffer(pairs)
        if not self.depp.DeppPutRegSet(self.hif, buf, len(data), False):
            raise RuntimeError(f"DeppPutRegSet failed, erc={self._erc()}")

    def read(self, addr, count=1):
        """Read consecutive registers starting at addr, in address order."""
        addrs = (ctypes.c_ubyte * count)(*range(addr, addr + count))
        out = (ctypes.c_ubyte * count)()
        if not self.depp.DeppGetRegSet(self.hif, addrs, out, count, False):
            raise RuntimeError(f"DeppGetRegSet failed, erc={self._erc()}")
        return bytes(out)

    def close(self):
        self.depp.DeppDisable(self.hif)
        self.dmgr.DmgrClose(self.hif)


class SimDevice:
    """Software model of miner_top's registers, hashing exactly like the HDL
    (midstate + tail + nonce word, H7 & mask test). Slow: ~5 kH/s."""

    def __init__(self, ncores=4):
        self.regs = bytearray(0x50)
        self.job = bytes(84)
        self.regs[REG_MAGIC] = MAGIC
        self.regs[REG_NCORES] = ncores
        self.ncores = ncores
        self.running = False
        self.found = False
        self.found_nonce = 0
        self.hits = 0
        self.n = 0
        self.snap = 0

    def write(self, addr, data, fixed=False):
        for i, b in enumerate(data):
            a = addr if fixed else addr + i
            if a == REG_JOB:
                self.job = (self.job + bytes((b,)))[-84:]
            elif a < 0x40:
                self.regs[a] = b
            if a == REG_CTRL:
                if b & 1:
                    self.n = struct.unpack(">I", self.job[44:48])[0]
                    self.running, self.found, self.hits = True, False, 0
                if b & 2:
                    self.running = False
            elif a == REG_CLEAR:
                self.found = False

    def read(self, addr, count=1):
        self._hash_some()
        out = bytearray()
        for a in range(addr, addr + count):
            if a == REG_STATUS:
                out.append(int(self.running) | int(self.found) << 1)
            elif REG_FOUND <= a < REG_FOUND + 4:
                out.append(struct.pack(">I", self.found_nonce)[a - REG_FOUND])
            elif a == REG_PROGRESS:
                self.snap = self.n
                out.append(self.snap >> 24)
            elif REG_PROGRESS < a < REG_PROGRESS + 4:
                out.append(struct.pack(">I", self.snap)[a - REG_PROGRESS])
            elif a == REG_HITS:
                out.append(self.hits & 0xFF)
            else:
                out.append(self.regs[a])
        return bytes(out)

    def _hash_some(self, budget=0.05):
        if not self.running:
            return
        mid = list(struct.unpack(">8I", self.job[0:32]))
        tail = bytes(self.job[32:44])
        mask = struct.unpack(">I", self.job[48:52])[0]
        pad1 = b"\x80" + bytes(43) + struct.pack(">I", 640)
        pad2 = b"\x80" + bytes(27) + struct.pack(">I", 256)
        end = time.monotonic() + budget
        while time.monotonic() < end:
            h1 = sha256_mid.compress(mid, tail + struct.pack(">I", self.n) + pad1)
            h2 = sha256_mid.compress(sha256_mid.IV, struct.pack(">8I", *h1) + pad2)
            if h2[7] & mask == 0:
                if not self.found:
                    self.found_nonce = (self.n + self.ncores) & 0xFFFFFFFF   # as the HDL reports it
                self.found = True
                self.hits += 1
            self.n = (self.n + 1) & 0xFFFFFFFF

    def close(self):
        pass


class Miner:
    """The register protocol, independent of the transport."""

    def __init__(self, dev):
        self.dev = dev
        magic = dev.read(REG_MAGIC)[0]
        if magic != MAGIC:
            raise RuntimeError(f"bad magic 0x{magic:02X}: is the miner bitstream loaded?")
        self.ncores = dev.read(REG_NCORES)[0]

    def load(self, mid, tail, first_word, mask, header=None):
        """Stop, write a job, and restart hashing from first_word."""
        self.dev.write(REG_CTRL, b"\x02")
        self.dev.write(REG_JOB, struct.pack(">8I", *mid) + tail
                       + struct.pack(">II", first_word, mask)
                       + struct.pack(">8I", *sha256_mid.state3(mid, tail)), fixed=True)
        self.dev.write(REG_CTRL, b"\x01")

    def stop(self):
        self.dev.write(REG_CTRL, b"\x02")

    def poll(self):
        """(hit nonce word or None, nonce word unit 0 is on, hit count)."""
        status = self.dev.read(REG_STATUS)[0]
        hit = None
        if status & 2:
            # the FPGA reports the unit's counter, already one step past the hit
            hit = (struct.unpack(">I", self.dev.read(REG_FOUND, 4))[0] - self.ncores) & 0xFFFFFFFF
            self.dev.write(REG_CLEAR, b"\x00")
        progress = struct.unpack(">I", self.dev.read(REG_PROGRESS, 4))[0]
        hits = self.dev.read(REG_HITS)[0]
        return hit, progress, hits
