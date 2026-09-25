#!/usr/bin/env python3
"""py65: the 6502 generator (jam.s) must match engine.py byte for byte.

    python3 test_jam.py [STYLE ...] [--bars N] [--seed S] [-v]

Runs jam_init + jam_bar N times in a bare 6502, collects the ring output
(psq body bytes) and compares it with engine.py's event stream encoded the
same way. On a mismatch it prints the first differing event on both sides.
"""
import argparse
import os
import subprocess
import sys

from py65.devices.mpu6502 import MPU

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "synth"))
import psq  # noqa: E402

import engine  # noqa: E402
import styles  # noqa: E402

CA, LD = os.path.expanduser("~/.local/bin/ca65"), os.path.expanduser("~/.local/bin/ld65")
RING, RINGSZ = 0x9800, 0x800


def build():
    subprocess.run([sys.executable, "gen_tables.py"], cwd=HERE, check=True, stdout=subprocess.DEVNULL)
    os.makedirs(os.path.join(HERE, "build"), exist_ok=True)
    subprocess.run([CA, "-g", "-o", "build/jamtest.o", "jamtest.s"], cwd=HERE, check=True)
    subprocess.run([LD, "-C", "jamtest.cfg", "-Ln", "build/jamtest.lbl", "-o",
                    "build/jamtest.bin", "build/jamtest.o"], cwd=HERE, check=True)
    lbl = {}
    for line in open(os.path.join(HERE, "build/jamtest.lbl")):
        _, a, n = line.split()
        lbl[n.lstrip(".")] = int(a, 16)
    return lbl


class Jam:
    def __init__(self, lbl):
        self.l = lbl
        self.m = MPU()
        d = open(os.path.join(HERE, "build/jamtest.bin"), "rb").read()
        self.m.memory[0x5000:0x5000 + len(d)] = list(d)
        self.rd = RING
        self.cycles = 0

    def call(self, name, a=0, limit=50_000_000):
        m, mem = self.m, self.m.memory
        SENT = 0xFFF0
        mem[SENT] = 0xEA
        ret = SENT - 1
        mem[0x1FF], mem[0x1FE] = ret >> 8, ret & 255
        m.sp, m.a = 0xFD, a
        m.pc = self.l[name]
        c0 = m.processorCycles
        n = 0
        while m.pc != SENT:
            m.step()
            n += 1
            if n > limit:
                raise RuntimeError(f"runaway in {name} at pc={m.pc:04X}")
        self.cycles = m.processorCycles - c0
        return self.cycles

    def drain(self):
        mem = self.m.memory
        wp = mem[0xB0] | mem[0xB1] << 8
        out = []
        while self.rd != wp:
            out.append(mem[self.rd])
            self.rd += 1
            if self.rd == RING + RINGSZ:
                self.rd = RING
        return out


def decode(body):
    ev, i, t = [], 0, 0
    while i < len(body):
        while body[i] == 255:
            t += 255
            i += 1
        t += body[i]
        op, tr = body[i + 1] >> 4, body[i + 1] & 15
        i += 2
        arg = 0
        if psq.HAS_ARG.get(op, False):
            arg = body[i]
            i += 1
        ev.append((t, op, tr, arg))
    return ev


def encode(events):
    out, t = [], 0
    for f, op, tr, arg in events:
        d = f - t
        while d > 254:
            out.append(255)
            d -= 255
        out += [d, (op << 4) | tr]
        if psq.HAS_ARG[op]:
            out.append(arg)
        t = f
    return out


def run(lbl, style, seed, bars, verbose):
    rnd = style == "RANDOM"                 # RANDOM = JAZZ first, then any
    style = "JAZZ" if rnd else style
    idx = list(styles.STYLES).index(style)
    j = Jam(lbl)
    mem = j.m.memory
    mem[lbl["JSEED"]], mem[lbl["JSEED"] + 1] = seed & 255, seed >> 8
    mem[lbl["jrand"]] = int(rnd)
    j.call("jam_init", a=idx)
    got = j.drain()
    e = engine.Engine(style, seed, random=rnd)
    want_ev = []
    worst = 0
    for b in range(bars):
        cyc = j.call("jam_bar")
        worst = max(worst, cyc)
        got += j.drain()
        n0 = len(e.out)
        e.bar()
        want_ev = e.out
    want = encode(want_ev)
    ok = got == want
    if not ok:
        g, w = decode(got), want_ev
        k = next((i for i in range(min(len(g), len(w))) if g[i] != w[i]), min(len(g), len(w)))
        print(f"FAIL {style} seed {seed}: first difference at event {k} "
              f"(6502 {len(g)} events, python {len(w)})")
        for i in range(max(0, k - 4), k + 4):
            gi = g[i] if i < len(g) else None
            wi = w[i] if i < len(w) else None
            print(f"   {i:5d}  6502 {gi}   py {wi}{'   <--' if gi != wi else ''}")
    else:
        print(f"PASS {style}{' +RANDOM' if rnd else ''} seed {seed}: {bars} bars, {len(want_ev)} events, "
              f"worst bar {worst} cycles ({worst / 29868:.1f} frames of CPU)")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("styles", nargs="*")
    ap.add_argument("--bars", type=int, default=200)
    ap.add_argument("--seed", type=int, action="append")
    ap.add_argument("-v", action="store_true")
    a = ap.parse_args()
    lbl = build()
    ok = True
    for st in [s.upper() for s in a.styles] or list(styles.STYLES) + ["RANDOM"]:
        for seed in a.seed or [1984, 7]:
            ok &= run(lbl, st, seed, a.bars, a.v)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
