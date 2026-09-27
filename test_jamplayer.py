#!/usr/bin/env python3
"""py65: POKEY JAM as a whole (player front-end + composer), no Atari.

    python3 test_jamplayer.py [--seconds 120] [--style N] [--mono]

Boots build/jam.xex, loads a style and runs VBI + main-loop passes frame by
frame. Checks: the ring never starves, the sequencer plays exactly the
events engine.py composes for the same seed, and how long the composer
holds up a main-loop pass. --mono runs it as on a one-POKEY machine: the
stereo arrangement still plays (POKEY2's part wins on the one chip), and the
panel says MONO with only the BASS HARM DRUM2 meters.
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
ap.add_argument("--mono", action="store_true")
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
mem[0x0673] = 1                     # POKEY JAM always drives both POKEYs
d = L("detect_stereo")
mem[d:d + 6] = [0xA9, 1, 0x8D, 0x73, 0x06, 0x60]   # (lda #1 / sta STEREO / rts)
# what the chips read: one POKEY reads the same through $D2xx and $D21x; a
# second has no keyboard (the Tang core: KBCODE $FF, SKSTAT $F7)
mem[0xD209], mem[0xD20F] = 0x1C, 0xFF
mem[0xD219], mem[0xD21F] = (0x1C, 0xFF) if a.mono else (0xFF, 0xF7)
call("draw_static")
mem[0x057F] = 0 if a.mono else 1    # JHW: what the machine is (display only)
call("jam_panel")
call("song_load", a.style)
seed = mem[0x06EB] | mem[0x06EC] << 8
style = (list(styles.STYLES) + ["RANDOM"])[a.style]
print(f"style {style}, seed {seed:#06x}")

frames = a.seconds * 60
VB = 0x0B40
seen = dict(v0=set(), v1=set())
mapt = list(mem[L("mapt"):L("mapt") + 24])
if a.mono:
    # one POKEY: the stereo arrangement (POKEY2's part wins on the one chip);
    # the panel says MONO and meters only BASS HARM DRUM2
    check(mapt == list(mem[L("map_st"):L("map_st") + 24]), "mono: the stereo map is loaded")
    row2 = "".join(chr((c & 0x3F) + 32) for c in mem[0x4000 + 80 + 16:0x4000 + 80 + 22])
    check(row2 == "MONO  ", f"mono: the panel says {row2!r}")
    check(list(mem[L("vusrc"):L("vusrc") + 6])[:3] == [0xFF] * 3, "mono: LEAD VOICE DRUM meters off")
sevn_prev, executed, starved, worst = mem[EQ["SEVN"]], 0, 0, 0
for f in range(frames):
    call("vbi")
    executed += (mem[EQ["SEVN"]] - sevn_prev) & 255
    sevn_prev = mem[EQ["SEVN"]]
    starved += mem[EQ["JSTARVE"]]
    if mem[0x0655] != 0xFF:          # PRESREQ: the main loop loads the lead's sound
        pr, mem[0x0655] = mem[0x0655], 0xFF
        call("set_preset", pr)
    worst = max(worst, call("jam_pump"))
    if a.mono:
        if 1 <= mem[VB + 2] <= 3:
            seen["v0"].add(mem[VB + 1])
        if 1 <= mem[VB + 20 + 2] <= 3:
            seen["v1"].add(mem[VB + 20 + 1])

e = engine.Engine(style, seed)
while e.sent_frame < frames + 600:
    e.bar()
want = sum(1 for ev in e.out if ev[0] < frames - 1 and (ev[1] >= 14 or mapt[ev[1] * 4 + (ev[2] & 3)] != 0xFF))
check(starved == 0, f"the ring never starved ({starved} starved frames)")
check(abs(executed - want) <= 8, f"sequencer played {executed} events, engine.py composed {want} "
      f"before frame {frames}")
if a.mono:
    bass = {ev[3] for ev in e.out if ev[1] == 0 and ev[2] == engine.BASS}
    comp = {ev[3] for ev in e.out if ev[1] == 0 and ev[2] == engine.COMP1}
    check(seen["v0"] and seen["v0"] <= bass, f"mono: voice 0 (POKEY2 ch1+2) plays the bass ({len(seen['v0'])} pitches)")
    check(seen["v1"] and seen["v1"] <= comp, f"mono: voice 1 (POKEY2 ch3) plays the chords ({len(seen['v1'])} pitches)")
    before = mem[0x06FC]
    m.x = 3
    call("jam_key")
    check(mem[0x06FC] ^ before == 8, "mono: key 4 mutes the bass")
    m.x = 3
    call("jam_key")
    # M: MONO>MONO -- bass on the lead's 16-bit pair, chords on ch3 (voice 0)
    row20 = lambda: "".join(chr((c & 0x3F) + 32) for c in mem[0x4000 + 800 + 10:0x4000 + 800 + 29])
    call("jam_mtoggle")
    mapt2 = list(mem[L("mapt"):L("mapt") + 24])
    check(mem[0x0673] == 0 and mapt2 == list(mem[L("map_jmono"):L("map_jmono") + 24]),
          "mono: M switches to MONO>MONO (map_jmono)")
    check(row20() == "M  MIX: MONO>MONO  ", f"mono: row 20 {row20()!r}")
    pair, ch3 = set(), set()
    f0 = frames
    for f in range(900):
        call("vbi")
        if mem[0x0655] != 0xFF:
            pr, mem[0x0655] = mem[0x0655], 0xFF
            call("set_preset", pr)
        call("jam_pump")
        if 1 <= mem[0x060A + 1] <= 3:         # the lead engine's envelope: sounding
            pair.add(mem[0x060A])
        if 1 <= mem[VB + 2] <= 3:
            ch3.add(mem[VB + 1])
    e2 = engine.Engine(style, seed)
    while e2.sent_frame < f0 + 1500:
        e2.bar()
    bass2 = {ev[3] for ev in e2.out if ev[1] == 0 and ev[2] == engine.BASS}
    comp2 = {ev[3] for ev in e2.out if ev[1] == 0 and ev[2] == engine.COMP1}
    check(pair and pair <= bass2, f"mono: MONO>MONO pair plays the bass ({len(pair)} pitches)")
    check(ch3 and ch3 <= comp2, f"mono: MONO>MONO ch3 plays the chords ({len(ch3)} pitches)")
    call("jam_mtoggle")
    check(mem[0x0673] == 1 and list(mem[L("mapt"):L("mapt") + 24]) == list(mem[L("map_st"):L("map_st") + 24])
          and row20() == "M  MIX: STEREO>MONO", "mono: M switches back to STEREO>MONO")
bars = mem[EQ["JBARS"]] | mem[EQ["JBARS"] + 1] << 8
print(f"      {bars} bars composed while playing; slowest pump {worst} cycles "
      f"({worst / 29868:.1f} frames)")
sys.exit(0 if ok else 1)
