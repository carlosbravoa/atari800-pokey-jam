#!/usr/bin/env python3
"""py65: POKEY JAM as a whole (player front-end + composer), no Atari.

    python3 test_jamplayer.py [--seconds 120] [--style N] [--mono]

Boots build/jam.xex, loads a style and runs VBI + main-loop passes frame by
frame. Checks: the ring never starves, the sequencer plays exactly the
events engine.py composes for the same seed, and how long the composer
holds up a main-loop pass. --mono runs it on a one-POKEY machine: the bass
must sound on the lead's 16-bit pair, the comping on ch3, and nothing from
the lead, voice 4 or POKEY2.
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
mem[0x0673] = 0 if a.mono else 1
# POKEY JAM re-detects the machine at every song load; py65's RANDOM is a
# constant (it would always look mono), so detection answers the mode tested
d = L("detect_stereo")
mem[d:d + 6] = [0xA9, 0 if a.mono else 1, 0x8D, 0x73, 0x06, 0x60]   # lda #m / sta STEREO / rts
# (its writes to SKCTL land on SKSTAT in py65: no key is held, on either chip)
mem[0xD20F] = mem[0xD21F] = 0xFF
call("draw_static")
call("song_load", a.style)
seed = mem[0x06EB] | mem[0x06EC] << 8
style = (list(styles.STYLES) + ["RANDOM"])[a.style]
print(f"style {style}, seed {seed:#06x}")

frames = a.seconds * 60
NOTE, VB, SH = 0x060A, 0x0B40, 0x0B78
seen = dict(lead=set(), lpre=set(), v0=set(), vpre=set())
loud, p2 = [0, 0, 0], False
mapt = list(mem[L("mapt"):L("mapt") + 24])
lead_lay = styles.STYLES[style].get("mono") == "lead"     # one POKEY: LEAD or BAND layout
if a.mono:
    want_map = "map_jlead" if lead_lay else "map_jmono"
    check(mapt == list(mem[L(want_map):L(want_map) + 24]),
          f"mono: the {'LEAD' if lead_lay else 'BAND'} layout's map is loaded")
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
        if 1 <= mem[NOTE + 1] <= 3:
            seen["lead"].add(mem[NOTE])
            seen["lpre"].add(mem[0x0600])
            loud[0] |= mem[SH + 3] & 15
        if 1 <= mem[VB + 2] <= 3:
            seen["v0"].add(mem[VB + 1])
            seen["vpre"].add(mem[VB])
        loud[1] |= mem[SH + 5] & 15
        loud[2] |= mem[SH + 7] & 15
        p2 |= any(mem[SH + 0x10 + r] & 15 for r in (1, 3, 5, 7))

e = engine.Engine(style, seed)
while e.sent_frame < frames + 600:
    e.bar()
want = sum(1 for ev in e.out if ev[0] < frames - 1 and (ev[1] >= 14 or mapt[ev[1] * 4 + (ev[2] & 3)] != 0xFF))
check(starved == 0, f"the ring never starved ({starved} starved frames)")
check(abs(executed - want) <= 8, f"sequencer played {executed} events, engine.py composed {want} "
      f"before frame {frames}")
if a.mono:
    P = engine.PRESETS
    pair_tr, ch3_tr = (engine.LEAD, engine.BASS) if lead_lay else (engine.BASS, engine.COMP1)
    pair_notes = {ev[3] for ev in e.out if ev[1] == 0 and ev[2] == pair_tr}
    ch3_notes = {ev[3] for ev in e.out if ev[1] == 0 and ev[2] == ch3_tr}
    st = styles.STYLES[style]
    names = ("lead", "bass") if lead_lay else ("bass", "comping")
    check(seen["lead"] and seen["lead"] <= pair_notes,
          f"mono: the 16-bit pair plays only {names[0]} notes ({len(seen['lead'])} pitches)")
    check(seen["v0"] and seen["v0"] <= ch3_notes,
          f"mono: ch3 plays only {names[1]} notes ({len(seen['v0'])} pitches)")
    pair_ok = set(st["lead"]["presets"]) if lead_lay else set(st["bass"]["presets"])
    ch3_ok = {"PIANO"} if lead_lay else set(st["comp"]["presets"])
    check({P[i] for i in seen["lpre"]} <= pair_ok,
          f"mono: pair sound {sorted(P[i] for i in seen['lpre'])}")
    check({P[i] for i in seen["vpre"]} <= ch3_ok,
          f"mono: ch3 sound {sorted(P[i] for i in seen['vpre'])}")
    drums = any(ev[1] == 2 and ev[0] < frames - 1 for ev in e.out)
    check(loud[0] and loud[1] and (loud[2] or not drums) and not p2, f"mono: ch1+2, ch3, ch4 sound; POKEY2 silent (vol {loud}, p2 {p2})")
    for x, want_bit in ((1, 8), (3, 0)):
        before = mem[0x06FC]
        m.x = x
        call("jam_key")
        check(mem[0x06FC] ^ before == want_bit, f"mono: key {x + 1} toggles mute bit {want_bit}")
        m.x = x
        call("jam_key")
bars = mem[EQ["JBARS"]] | mem[EQ["JBARS"] + 1] << 8
print(f"      {bars} bars composed while playing; slowest pump {worst} cycles "
      f"({worst / 29868:.1f} frames)")
sys.exit(0 if ok else 1)
