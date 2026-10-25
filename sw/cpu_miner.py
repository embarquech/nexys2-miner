"""CPU stand-in for the FPGA: same interface as fpga.Miner, real hashing with
hashlib in worker processes.

hashlib cannot start from a midstate, so it hashes the first 64 header bytes
once per job and copies that state for every nonce instead. Nonce words and
the hit test follow the HDL exactly (word placed big-endian, H7 & mask == 0).
"""
import hashlib
import multiprocessing as mp
import os
import queue
import struct

BATCH = 20000


def _worker(prefix, tail, first, step, mask, count, hits, stop):
    base = hashlib.sha256(prefix)
    sha256 = hashlib.sha256
    pack = struct.Struct(">I").pack
    unpack_h7 = struct.Struct(">I").unpack_from
    n = first
    while not stop.is_set():
        for _ in range(BATCH):
            h = base.copy()
            h.update(tail + pack(n))
            d = sha256(h.digest()).digest()
            if unpack_h7(d, 28)[0] & mask == 0:
                hits.put(n)
            n = (n + step) & 0xFFFFFFFF
        with count.get_lock():
            count.value += BATCH


class CpuMiner:
    def __init__(self, processes=None):
        self.ncores = processes or max(1, (os.cpu_count() or 2) // 2)
        self.count = mp.Value("Q", 0)
        self.hits = mp.Queue()
        self.stop_event = mp.Event()
        self.procs = []
        self.first = 0
        self.hit_count = 0

    def load(self, mid, tail, first_word, mask, header=None):
        if header is None:
            raise ValueError("the CPU miner needs the raw header, not just the midstate")
        self.stop()
        while True:                             # drop hits from the previous job
            try:
                self.hits.get_nowait()
            except queue.Empty:
                break
        self.stop_event = mp.Event()
        with self.count.get_lock():
            self.count.value = 0
        self.first = first_word
        self.hit_count = 0
        self.procs = [mp.Process(target=_worker, daemon=True,
                                 args=(header[:64], bytes(tail), (first_word + i) & 0xFFFFFFFF,
                                       self.ncores, mask, self.count, self.hits, self.stop_event))
                      for i in range(self.ncores)]
        for p in self.procs:
            p.start()

    def stop(self):
        self.stop_event.set()
        for p in self.procs:
            p.join()
        self.procs = []

    def poll(self):
        """(hit nonce word or None, nonce word reached, hit count), like fpga.Miner."""
        hit = None
        try:
            hit = self.hits.get_nowait()
            self.hit_count += 1
        except queue.Empty:
            pass
        progress = (self.first + self.count.value) & 0xFFFFFFFF
        return hit, progress, self.hit_count
