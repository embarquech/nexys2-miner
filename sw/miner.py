"""Stratum V1 client driving the Nexys2 SHA-256d miner.

  python miner.py [--sim | --cpu [--procs N]] selftest
  python miner.py stress [--seconds 60] [--bits 20]
  python miner.py [--sim | --cpu [--procs N]] mine [--url HOST:PORT --user WALLET.WORKER --pass x]

Pool settings default to pool.json next to this script.

The FPGA flags any hash whose top HIT_BITS bits are zero; every flagged nonce
is re-hashed here with hashlib and only submitted if it meets the pool target.
"""
import argparse
import binascii
import hashlib
import json
import os
import socket
import struct
import threading
import time

import fpga
import sha256_mid

DIFF1_TARGET = 0xFFFF << 208


def sha256d(b):
    return hashlib.sha256(hashlib.sha256(b).digest()).digest()


def bswap32(x):
    return struct.unpack("<I", struct.pack(">I", x))[0]


def hit_mask(bits):
    """Mask on H7 meaning 'the top `bits` bits of the hash value are zero'.
    The hash is read little-endian, so its top 32 bits are H7 byte-swapped."""
    top = ((1 << bits) - 1) << (32 - bits)
    return bswap32(top)


def hash_value(header):
    return int.from_bytes(sha256d(header), "little")


def open_miner(args):
    if args.cpu:
        import cpu_miner
        return cpu_miner.CpuMiner(args.procs)
    dev = fpga.SimDevice() if args.sim else fpga.Depp(args.device)
    return fpga.Miner(dev)


# --------------------------------------------------------------------------
# Self-test: the Bitcoin genesis block, starting a little before its nonce
# --------------------------------------------------------------------------

GENESIS = (struct.pack("<I", 1) + bytes(32)
           + bytes.fromhex("4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b")[::-1]
           + struct.pack("<III", 1231006505, 0x1D00FFFF, 2083236893))


def selftest(args):
    m = open_miner(args)
    print(f"miner found, {m.ncores} hashing units")
    assert sha256d(GENESIS)[::-1].hex().startswith("000000000019d6689c085ae1")
    word = struct.unpack(">I", GENESIS[76:80])[0]
    back = 200 if args.sim else 3_000_000
    first = word - back
    m.load(sha256_mid.midstate(GENESIS), GENESIS[64:76], first, hit_mask(32), header=GENESIS)
    t0 = time.monotonic()
    while time.monotonic() - t0 < 120:
        hit, progress, _ = m.poll()
        if hit is not None:
            dt = time.monotonic() - t0
            m.stop()
            ok = hit == word
            print(f"hit nonce word 0x{hit:08X} from unit {(hit - first) % m.ncores},"
                  f" expected 0x{word:08X}: {'OK' if ok else 'WRONG'}")
            print(f"{back} nonces in {dt:.2f} s, ~{back / dt:,.0f} H/s")
            return 0 if ok else 1
        time.sleep(0.05)
    m.stop()
    print(f"no hit after 120 s (unit 0 at 0x{progress:08X}): FAILED")
    return 1


# --------------------------------------------------------------------------
# Stress test: random headers, every hit re-hashed on the PC
# --------------------------------------------------------------------------

def stress(args):
    """Measures the useful hash rate of an overclocked design: the FPGA's own
    hit counter times the share of read-back hits that re-hash correctly.
    Wrong hashes cost nothing at the pool (the PC checks every hit before
    submitting), so a faster clock with some garbage can still win."""
    import math
    import os
    m = open_miner(args)
    header = os.urandom(76) + bytes(4)
    m.load(sha256_mid.midstate(header), header[64:76], 0, hit_mask(args.bits), header=header)
    good = bad = 0
    progress = 0
    hw_hits = last_count = 0                    # the FPGA's own 8-bit hit counter
    t0 = time.monotonic()
    while time.monotonic() - t0 < args.seconds:
        hit, progress, count = m.poll()
        hw_hits += (count - last_count) & 0xFF
        last_count = count
        if hit is not None:
            bits = 256 - hash_value(header[:76] + struct.pack(">I", hit)).bit_length()
            if bits >= args.bits:
                good += 1
            else:
                bad += 1
        time.sleep(0.002)
    m.stop()
    dt = time.monotonic() - t0
    expected = progress / 2 ** args.bits
    sigma = math.sqrt(max(expected, 1))
    print(f"{progress:,} nonces in {dt:.0f} s = {progress / dt / 1e6:.3f} MH/s")
    good_share = good / max(good + bad, 1)
    useful = hw_hits * good_share * 2 ** args.bits / dt
    print(f"hits: {hw_hits} counted by the FPGA, {expected:.0f} expected (+/- {2 * sigma:.0f});"
          f" {good + bad} read back: {good} good, {bad} bad")
    print(f"useful rate: {useful / 1e6:.3f} MH/s (+/- {2 * useful / sigma / 1e6:.3f})")
    return 0 if good else 1


# --------------------------------------------------------------------------
# Stratum
# --------------------------------------------------------------------------

class Stratum:
    def __init__(self, host, port, user, password):
        self.sock = socket.create_connection((host, port), timeout=30)
        self.sock.settimeout(None)
        self.file = self.sock.makefile("r", encoding="utf-8", newline="\n")
        self.user, self.password = user, password
        self.lock = threading.Lock()
        self.next_id = 1
        self.pending = {}
        self.job = None
        self.job_seq = 0
        self.difficulty = 1.0
        self.extranonce1 = b""
        self.en2_size = 4
        self.accepted = self.rejected = 0
        self.ready = threading.Event()
        threading.Thread(target=self._reader, daemon=True).start()

    def call(self, method, params, on_result=None):
        with self.lock:
            msg_id = self.next_id
            self.next_id += 1
            self.pending[msg_id] = (method, on_result)
            line = json.dumps({"id": msg_id, "method": method, "params": params}) + "\n"
            self.sock.sendall(line.encode())

    def start(self):
        self.call("mining.subscribe", ["nexys2-miner/0.1"], self._on_subscribe)
        self.call("mining.authorize", [self.user, self.password], self._on_authorize)

    def _on_subscribe(self, result, error):
        if error:
            raise SystemExit(f"subscribe failed: {error}")
        self.extranonce1 = bytes.fromhex(result[1])
        self.en2_size = result[2]
        print(f"subscribed, extranonce1={result[1]}, extranonce2 size={self.en2_size}")

    def _on_authorize(self, result, error):
        print("authorized" if result else f"authorize refused: {error}")
        # Ask for a share difficulty this slow miner can actually reach.
        self.call("mining.suggest_difficulty", [1])

    def _on_submit(self, result, error):
        if result:
            self.accepted += 1
            print(f"  share accepted ({self.accepted} ok / {self.rejected} rejected)")
        else:
            self.rejected += 1
            print(f"  share rejected: {error}")

    def _reader(self):
        for line in self.file:
            try:
                msg = json.loads(line)
            except ValueError:
                print(f"ignoring malformed line from pool: {line.strip()[:120]!r}")
                continue
            method = msg.get("method")
            if method == "mining.notify":
                p = msg["params"]
                with self.lock:
                    self.job = {"id": p[0], "prevhash": p[1], "coinb1": p[2], "coinb2": p[3],
                                "branch": p[4], "version": p[5], "nbits": p[6], "ntime": p[7]}
                    self.job_seq += 1
                self.ready.set()
                print(f"new job {p[0]}{' (clean)' if p[8] else ''}")
            elif method == "mining.set_difficulty":
                self.difficulty = float(msg["params"][0])
                print(f"pool difficulty {self.difficulty:g}")
            elif "id" in msg and msg["id"] in self.pending:
                _, cb = self.pending.pop(msg["id"])
                if cb:
                    cb(msg.get("result"), msg.get("error"))
        print("pool closed the connection")
        self.ready.set()


def build_header(job, extranonce1, en2):
    coinbase = bytes.fromhex(job["coinb1"]) + extranonce1 + en2 + bytes.fromhex(job["coinb2"])
    root = sha256d(coinbase)
    for h in job["branch"]:
        root = sha256d(root + bytes.fromhex(h))
    prev = bytes.fromhex(job["prevhash"])
    prev = b"".join(prev[i:i + 4][::-1] for i in range(0, 32, 4))
    return (bytes.fromhex(job["version"])[::-1] + prev + root
            + bytes.fromhex(job["ntime"])[::-1] + bytes.fromhex(job["nbits"])[::-1] + bytes(4))


def mine(args):
    m = open_miner(args)
    print(f"miner found, {m.ncores} hashing units")
    host, port = args.url.rsplit(":", 1)
    pool = Stratum(host, int(port), args.user, args.password)
    pool.start()
    pool.ready.wait()

    mask = hit_mask(args.hit_bits)
    en2 = 0
    seq = -1
    cur = {}

    def load(job):
        en2_bytes = en2.to_bytes(pool.en2_size, "big")
        header = build_header(job, pool.extranonce1, en2_bytes)
        m.load(sha256_mid.midstate(header), header[64:76], 0, mask, header=header)
        cur.update(job=job, en2=en2_bytes, header=header, since=time.monotonic(), last=0)

    stats_t = time.monotonic()
    stats_n = 0
    while True:
        with pool.lock:
            job, job_seq = pool.job, pool.job_seq
        if job is None:
            return 1
        if job_seq != seq:
            seq = job_seq
            load(job)

        hit, progress, _ = m.poll()
        if progress > 0xF0000000:              # nonce space nearly exhausted
            en2 += 1
            load(cur["job"])
            continue
        if hit is not None:
            full = cur["header"][:76] + struct.pack(">I", hit)
            value = hash_value(full)
            nonce = struct.unpack("<I", full[76:80])[0]
            # unit i hashes nonce words first + i, first + i + ncores, ... (first = 0 here)
            print(f"hit nonce {nonce:08x} from unit {hit % m.ncores}:"
                  f" {256 - value.bit_length()} leading zero bits,"
                  f" difficulty {DIFF1_TARGET / max(value, 1):.3g} (pool wants {pool.difficulty:g})")
            if value <= DIFF1_TARGET / pool.difficulty:
                j = cur["job"]
                pool.call("mining.submit", [args.user, j["id"], cur["en2"].hex(),
                                            j["ntime"], f"{nonce:08x}"], pool._on_submit)

        stats_n += progress - cur["last"]
        cur["last"] = progress
        now = time.monotonic()
        if now - stats_t >= 10:
            print(f"{stats_n / (now - stats_t) / 1e3:.0f} kH/s, job {cur['job']['id']}"
                  f" for {now - cur['since']:.0f} s,"
                  f" {pool.accepted} accepted / {pool.rejected} rejected")
            stats_t, stats_n = now, 0
        time.sleep(0.2)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim", action="store_true", help="software model instead of the FPGA")
    ap.add_argument("--cpu", action="store_true", help="mine on the CPU instead of the FPGA")
    ap.add_argument("--procs", type=int, help="CPU worker processes (default: half the cores)")
    ap.add_argument("--device", default="Nexys2", help="Adept device name (djtgcfg enum)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest")
    sp = sub.add_parser("stress")
    sp.add_argument("--seconds", type=float, default=60)
    sp.add_argument("--bits", type=int, default=16)
    mp = sub.add_parser("mine")
    try:
        with open(os.path.join(os.path.dirname(__file__), "pool.json"), encoding="utf-8") as f:
            pool = json.load(f)
    except FileNotFoundError:
        pool = {}
    mp.add_argument("--url", default=pool.get("url"), required="url" not in pool,
                    help="pool HOST:PORT (default from pool.json)")
    mp.add_argument("--user", default=pool.get("user"), required="user" not in pool)
    mp.add_argument("--pass", dest="password", default=pool.get("pass", "x"))
    mp.add_argument("--hit-bits", type=int, default=32,
                    help="report hashes with this many leading zero bits (32 = difficulty 1)")
    args = ap.parse_args()
    if args.cmd == "selftest":
        raise SystemExit(selftest(args))
    if args.cmd == "stress":
        raise SystemExit(stress(args))
    raise SystemExit(mine(args))


if __name__ == "__main__":
    main()
