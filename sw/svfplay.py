"""Play an SVF file on the Nexys2's JTAG chain through djtg.dll (Adept Runtime).
Used to write the XCF04S Platform Flash with the SVF iMPACT generates.

  python svfplay.py ..\\ise\\out\\miner_prom.svf [--device Nexys2]

Supports the subset iMPACT emits: SIR, SDR, HIR, TIR, HDR, TDR, ENDIR, ENDDR,
STATE, RUNTEST, FREQUENCY, TRST. Every TDO the file expects is checked under
its MASK; the first mismatch stops playback.
"""
import argparse
import ctypes
import re
import sys
import time
from collections import deque

from jtagprog import Jtag

# state: (next with TMS=0, next with TMS=1)
TAP = {
    "RESET": ("IDLE", "RESET"),
    "IDLE": ("IDLE", "DRSELECT"),
    "DRSELECT": ("DRCAPTURE", "IRSELECT"),
    "DRCAPTURE": ("DRSHIFT", "DREXIT1"),
    "DRSHIFT": ("DRSHIFT", "DREXIT1"),
    "DREXIT1": ("DRPAUSE", "DRUPDATE"),
    "DRPAUSE": ("DRPAUSE", "DREXIT2"),
    "DREXIT2": ("DRSHIFT", "DRUPDATE"),
    "DRUPDATE": ("IDLE", "DRSELECT"),
    "IRSELECT": ("IRCAPTURE", "RESET"),
    "IRCAPTURE": ("IRSHIFT", "IREXIT1"),
    "IRSHIFT": ("IRSHIFT", "IREXIT1"),
    "IREXIT1": ("IRPAUSE", "IRUPDATE"),
    "IRPAUSE": ("IRPAUSE", "IREXIT2"),
    "IREXIT2": ("IRSHIFT", "IRUPDATE"),
    "IRUPDATE": ("IDLE", "DRSELECT"),
}


def tms_path(src, dst):
    """Shortest TMS sequence from src to dst (empty if equal, except RESET)."""
    if src == dst:
        return [1] * 5 if dst == "RESET" else []
    seen = {src: []}
    q = deque([src])
    while q:
        s = q.popleft()
        for bit in (0, 1):
            n = TAP[s][bit]
            if n not in seen:
                seen[n] = seen[s] + [bit]
                if n == dst:
                    return seen[n]
                q.append(n)
    raise ValueError(f"no path {src} -> {dst}")


class Scan:
    """One of HIR/TIR/HDR/TDR/SIR/SDR: length plus sticky TDI/TDO/MASK/SMASK."""

    def __init__(self):
        self.length = 0
        self.tdi = 0
        self.tdo = None
        self.mask = 0
        self.smask = 0

    def update(self, length, fields):
        if length != self.length:
            self.tdi, self.mask = 0, (1 << length) - 1
            self.smask = (1 << length) - 1
        self.length = length
        self.tdo = None                       # TDO is never sticky
        for k, v in fields.items():
            setattr(self, k.lower(), v)
        if "MASK" not in fields and length != 0 and self.mask == 0:
            self.mask = (1 << length) - 1


class Player:
    def __init__(self, jt):
        self.jt = jt
        self.state = "RESET"
        self.endir = "IDLE"
        self.enddr = "IDLE"
        self.regs = {k: Scan() for k in ("HIR", "TIR", "HDR", "TDR", "SIR", "SDR")}
        self.jt.tms(0b11111, 5)
        self.checks = 0
        self.freq = 1e6                       # SVF FREQUENCY; RUNTEST counts mean time
        self.run_state = "IDLE"               # sticky across RUNTESTs, per the SVF spec
        self.run_end = "IDLE"

    def goto(self, dst):
        path = tms_path(self.state, dst)
        for i in range(0, len(path), 32):
            chunk = path[i:i + 32]
            self.jt.tms(sum(b << k for k, b in enumerate(chunk)), len(chunk))
        self.state = dst

    def scan(self, kind, length, fields):
        ir = kind == "SIR"
        reg = self.regs[kind]
        reg.update(length, fields)
        head = self.regs["HIR" if ir else "HDR"]
        tail = self.regs["TIR" if ir else "TDR"]
        # Header devices sit nearest TDO, so their bits go in first (LSB side).
        total = head.length + reg.length + tail.length
        tdi = head.tdi | (reg.tdi << head.length) | (tail.tdi << (head.length + reg.length))
        self.goto("IRSHIFT" if ir else "DRSHIFT")
        want = reg.tdo is not None
        out = self.jt.shift(tdi, total, read=want)
        self.state = "IREXIT1" if ir else "DREXIT1"
        if want:
            got = (out >> head.length) & ((1 << reg.length) - 1)
            if (got ^ reg.tdo) & reg.mask:
                raise RuntimeError(f"{kind} {length}: TDO mismatch, got {got:x}, "
                                   f"expected {reg.tdo:x} mask {reg.mask:x}")
            self.checks += 1
        self.goto(self.endir if ir else self.enddr)

    def runtest(self, args):
        state, count, secs, end = None, 0, 0.0, None
        toks = args
        i = 0
        if toks and toks[0] in TAP:
            state = toks[0]
            i = 1
        while i < len(toks):
            if i + 1 < len(toks) and toks[i + 1] == "TCK":
                count = int(float(toks[i]))
                i += 2
            elif i + 1 < len(toks) and toks[i + 1] == "SEC":
                secs = max(secs, float(toks[i]))
                i += 2
            elif toks[i] == "MAXIMUM":
                i += 3
            elif toks[i] == "ENDSTATE":
                end = toks[i + 1]
                i += 2
            else:
                i += 1
        # A TCK count is a delay at the file's FREQUENCY (erase and program
        # times); djtg clocks much faster, so wait out the time as well.
        if count:
            secs = max(secs, count / self.freq)
        # Without an explicit state RUNTEST runs in the last one given (IDLE by
        # default), never "where we are": iMPACT parks in IRPAUSE after an
        # instruction and relies on this move through Update-IR to start it.
        if state:
            self.run_state = state
            self.run_end = state
        if end:
            self.run_end = end
        run_state = self.run_state
        self.goto(run_state)
        t0 = time.monotonic()
        if count:
            tms = 1 if run_state == "RESET" else 0
            if not self.jt.djtg.DjtgClockTck(self.jt.hif, tms, False, count, False):
                raise RuntimeError("DjtgClockTck failed")
        left = secs - (time.monotonic() - t0)
        if left > 0:
            time.sleep(left)
        self.goto(self.run_end)

    def command(self, words):
        op = words[0]
        if op in ("SIR", "SDR", "HIR", "TIR", "HDR", "TDR"):
            length = int(words[1])
            fields = {}
            for m in re.finditer(r"(TDI|TDO|MASK|SMASK)\s*\(\s*([0-9A-Fa-f\s]*)\)", " ".join(words[2:])):
                fields[m.group(1)] = int(m.group(2).replace(" ", "") or "0", 16)
            if op in ("SIR", "SDR"):
                self.scan(op, length, fields)
            else:
                self.regs[op].update(length, fields)
        elif op == "ENDIR":
            self.endir = words[1]
        elif op == "ENDDR":
            self.enddr = words[1]
        elif op == "STATE":
            for s in words[1:]:
                self.goto(s)
        elif op == "RUNTEST":
            self.runtest(words[1:])
        elif op == "FREQUENCY":
            if len(words) > 1:
                self.freq = float(words[1])
        elif op == "TRST":
            pass
        else:
            raise ValueError(f"unsupported SVF command {op}")


def commands(text):
    text = re.sub(r"(//|!)[^\n]*", "", text)
    for stmt in text.split(";"):
        # keep hex groups intact: "TDI (abc def)" -> one token inside the parens
        stmt = " ".join(stmt.split())
        if stmt:
            yield re.findall(r"\([^)]*\)|[^\s()]+", stmt)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("svf")
    ap.add_argument("--device", default="Nexys2")
    args = ap.parse_args()
    cmds = list(commands(open(args.svf).read()))
    print(f"{args.svf}: {len(cmds)} commands")
    jt = Jtag(args.device)
    try:
        p = Player(jt)
        t0 = time.monotonic()
        for i, words in enumerate(cmds):
            p.command(words)
            if i % 500 == 0:
                print(f"\r  {i}/{len(cmds)}  {time.monotonic() - t0:.0f} s", end="", flush=True)
        p.goto("RESET")
        print(f"\rdone: {len(cmds)} commands, {p.checks} TDO checks OK, {time.monotonic() - t0:.0f} s")
    except Exception as e:
        print(f"\nFAILED at command {i}: {' '.join(words)[:200]}\n  {e}")
        sys.exit(1)
    finally:
        jt.close()


if __name__ == "__main__":
    main()
