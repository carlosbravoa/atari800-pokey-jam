#!/usr/bin/env python3
"""py65: POKEY JAM as a whole (player front-end + composer), no Atari.

    python3 test_jamplayer.py [--seconds 120] [--style N]

Boots build/jam.xex, loads a style and runs VBI + main-loop passes frame by
frame. Checks: the ring never starves, the sequencer plays exactly the
events engine.py composes for the same seed, and how long the composer
holds up a main-loop pass.
"""
import argparse
import os
import sys

from py65.devices.mpu6502 import MPU

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "synth"))
import engine  # noqa: E402
import styles  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--seconds", type=int, default=120)
ap.add_argument("--style", type=int, default=0)
a = ap.parse_args()

lbl = {}
for line in open(os.path.join(HERE, "build/jam.lbl")):
    _, ad, n = line.split()
    lbl[n.lstrip(".")] = int(ad, 16)
EQ = dict(PLAYING=0x0644, SEVN=0x0647, SPOS=0x065A, JSTARVE=0x06E5, JBARS=0x06E6,
          JUSED=0x06E9, STEREO=None)


def L(n):
    return lbl[n]


m = MPU()
mem = m.memory
d = open(os.path.join(HERE, "build/jam.xex"), "rb").read()
i = 2
while i < len(d):
    if d[i:i + 2] == b"\xff\xff":
        i += 2
    s = int.from_bytes(d[i:i + 2], "little")
    e = int.from_bytes(d[i + 2:i + 4], "little")
    mem[s:e + 1] = list(d[i + 4:i + 5 + e - s])
    i += 5 + e - s
for ad in range(0xE000, 0xE400):
    mem[ad] = ad & 255
mem[0xE45C] = 0x60
mem[0xE462] = 0x60
mem[0xD20F] = 0xFF
mem[0xD20A] = 0x77
mem[0x0278] = 0x0F
SENT = 0xFFF0
mem[SENT] = 0xEA
ok = True


def check(c, msg):
    global ok
    print(("PASS " if c else "FAIL ") + msg)
    ok &= bool(c)


def call(name, av=0):
    m.a = av
    ret = SENT - 1
    mem[0x1FF], mem[0x1FE] = ret >> 8, ret & 255
    m.sp = 0xFD
    m.pc = L(name)
    c0 = m.processorCycles
    n = 0
    while m.pc != SENT:
        m.step()
        n += 1
        assert n < 20_000_000, f"runaway in {name} pc={m.pc:04X}"
    return m.processorCycles - c0


m.pc, m.sp = L("start"), 0xFF
n = 0
while m.pc != L("mainloop"):
    m.step()
    n += 1
    assert n < 4_000_000, "start never reached mainloop"
mem[0x0673] = 1
call("draw_static")
call("song_load", a.style)
seed = mem[0x06EB] | mem[0x06EC] << 8
style = (list(styles.STYLES) + ["RANDOM"])[a.style]
print(f"style {style}, seed {seed:#06x}")

frames = a.seconds * 60
sevn_prev, executed, starved, worst = mem[EQ["SEVN"]], 0, 0, 0
for f in range(frames):
    call("vbi")
    executed += (mem[EQ["SEVN"]] - sevn_prev) & 255
    sevn_prev = mem[EQ["SEVN"]]
    starved += mem[EQ["JSTARVE"]]
    worst = max(worst, call("jam_pump"))

e = engine.Engine(style, seed)
while e.sent_frame < frames + 600:
    e.bar()
want = sum(1 for ev in e.out if ev[0] < frames - 1)
check(starved == 0, f"the ring never starved ({starved} starved frames)")
check(abs(executed - want) <= 8, f"sequencer played {executed} events, engine.py composed {want} "
      f"before frame {frames}")
bars = mem[EQ["JBARS"]] | mem[EQ["JBARS"] + 1] << 8
print(f"      {bars} bars composed while playing; slowest pump {worst} cycles "
      f"({worst / 29868:.1f} frames)")
sys.exit(0 if ok else 1)
