#!/usr/bin/env python3
"""Song of the Grid, re-performed from the Ballblazer cartridge's own data.

    python3 ballblazer.py [--seconds 240] [--seed N] [--demo] [-o out.psq]

A frame-by-frame port of the cart's music driver (re/BALLBLAZER_MUSIC.md,
section 4) that writes a POKEY SYNTH .psq instead of POKEY registers:
the real 32 riffs, tempo list, HOME/A/B/C/D backing phrases, riff pick,
note omission, swell (loudness chase), phrase-run logic and the one-step
echo. RANDOM is the gen.Rng xorshift, so a seed replays a performance.

Mapping onto the player's voices: backing v1 (buzzy bass) -> track 1,
v2 -> track 2, v3 -> track 3 (voice 4), lead -> track 0; noise hits ->
drums. The echo takes track 3 when v3 is silent, as ch3's "loudest wins"
did. psq has no per-note volume, so the swell only decides when the lead
sounds (its note length follows the decay, `loud` frames).
"""
import argparse
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "re"))
import extract as X  # noqa: E402  (reads the ROM)

import gen  # noqa: E402

CLK = 63921.0
TEMPOS = [6, 4, 6, 9, 6, 3, 6, 12]
PH = {k: X.parse_phrase(a)[0] for k, a in
      dict(HOME=0x7D40, A=0x7C75, B=0x7C99, C=0x7CC7, D=0x7CF6).items()}
RIFFS = [X.ram(X.RIFFS + i) for i in range(256)]
NOISE_DRUM = {0x03: "hat", 0x0A: "snare", 0x1E: "open"}


def psq_note(audf, audc=0xA0):
    """POKEY 64 kHz AUDF (pure, or poly4 buzz) -> psq note (0 = C1)"""
    if audc & 0xE0 == 0xC0:
        per = 15 // math.gcd(audf + 1, 15)
        f = CLK / (per * (audf + 1))
    else:
        f = CLK / (2 * (audf + 1))
    midi = 69 + 12 * math.log2(f / 440.0)
    return max(0, round(midi) - 24)


def perform(seconds, seed, demo=False):
    rng = gen.Rng(seed)
    out = gen.Out()
    out.w.title = f"SONG OF THE GRID"
    out.beat, out.swing = 12, 0            # 1 tick = 1 frame (fr(t) = t)
    w = out
    for tr, p in ((0, "PIANO"), (1, "BASS"), (2, "ORGAN"), (3, "ORGAN")):
        w.preset(0, tr, p)

    # driver state (names follow the pseudocode)
    loud = echo_loud = target = saw = 0
    ramp_every = False
    run = 0
    tempo_i = 0
    tempo = TEMPOS[0]
    if demo:
        target = saw = 0x20
        ramp_every = True
    phrase, rec_i, seq_cd = None, 0, 1
    lead_cd, lead_pos = 1, 11 * 8
    lead_note = None                       # AUDF sounding, and its note-on frame / env
    lead_on = None
    echo_note_audf = None
    vo = [None, None, None]                # backing: (instr, start frame) per voice
    echo_on = None                         # (frame, note, env) of the echo on track 3

    def start_phrase(name):
        nonlocal phrase, rec_i, seq_cd, lead_cd, lead_pos
        phrase, rec_i, seq_cd = name, 0, 1
        lead_cd, lead_pos = 1, 11 * 8

    def loudness_step():
        nonlocal loud, echo_loud, ramp_every
        if loud == target:
            ramp_every = False
        elif loud < target:
            echo_loud = loud // 2 + 1
            loud += 1
        elif run >= 0:
            echo_loud = min(echo_loud, loud)
            loud -= 1

    def phrase_end():
        nonlocal target, saw, run, tempo_i, tempo
        if target == 0:
            if loud != 0:
                if run < 0:
                    return cont_run()
                return start_phrase("HOME")
            tempo_i = (tempo_i + 1) % len(TEMPOS)
            tempo = TEMPOS[tempo_i]
        saw += 6
        if saw >= 64:
            saw = 0
        target = min(saw, 32)
        if run < 0:
            return cont_run()
        a = 2 * loud + 16
        if a < rng.byte():
            return start_phrase("HOME")
        run = -2 if a < rng.byte() else -4
        return cont_run()

    def cont_run():
        nonlocal run
        run += 1
        r = rng.byte() & 7
        if run >= 0:
            r += 4
        start_phrase("A" if r < 3 else "B" if r < 6 else "C" if r < 9 else "D")

    def v_off(v, f):
        if vo[v] is not None:
            w.w.note_off(f, v + 1)
            vo[v] = None

    def echo_off(f):
        nonlocal echo_on
        if echo_on is not None:
            w.w.note_off(f, 3)
            echo_on = None

    start_phrase("HOME")
    for f in range(seconds * 60):
        # -- backing sequencer
        seq_cd -= 1
        if seq_cd == 0:
            recs = PH[phrase]
            if rec_i >= len(recs):
                phrase_end()
                recs = PH[phrase]
            dur, ins = recs[rec_i]
            rec_i += 1
            seq_cd = dur
            for v in range(3):
                i = ins[v]
                if i is None:
                    v_off(v, f)
                    continue
                audf, _, audc = X.instr(i)
                if audc & 0xE0 in (0x80, 0x00):          # noise = a drum hit
                    v_off(v, f)
                    w.w.drum(f, gen.DRUM[NOISE_DRUM.get(audf, "hat")],
                             gen.DRUM_CH[NOISE_DRUM.get(audf, "hat")])
                    w.hits += 1
                    continue
                if vo[v] is not None and vo[v][0] == i:
                    continue                             # same instrument: keeps sounding
                v_off(v, f)
                if v == 2:
                    echo_off(f)
                w.w.note_on(f, v + 1, psq_note(audf, audc))
                w.notes += 1
                vo[v] = (i, f)
        # -- lead
        if tempo:
            lead_cd -= 1
            if lead_cd == 0:
                if ramp_every:
                    loudness_step()
                lead_cd = tempo
                prev_audf, prev_env = lead_note, lead_on
                p = 0 if lead_pos & 3 == 0 else 16
                if p < rng.byte():
                    a = RIFFS[lead_pos]
                    if lead_on is not None:
                        w.w.note_off(f, 0)
                        lead_on = None
                    lead_note = a
                    if a and loud >> 2:
                        w.w.note_on(f, 0, psq_note(a))
                        w.notes += 1
                        lead_on = f + loud                 # decays out after `loud` frames
                    # echo: the previous step's note, one step late, on ch3 if free
                    if prev_audf and echo_loud >> 2 and vo[2] is None:
                        echo_off(f)
                        w.w.note_on(f, 3, psq_note(prev_audf))
                        echo_on = f + echo_loud
                lead_pos += 1
                if lead_pos & 7 == 0:
                    loudness_step()
                    lead_pos = rng.byte() & 0xF8
        if lead_on is not None and f >= lead_on:
            w.w.note_off(f, 0)
            lead_on = None
        if echo_on is not None and f >= echo_on:
            echo_off(f)
    w.w.at(seconds * 60, gen.psq.ALLOFF)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=240)
    ap.add_argument("--seed", type=int, default=1984)
    ap.add_argument("--demo", action="store_true", help="start loud (attract mode)")
    ap.add_argument("-o", "--out")
    a = ap.parse_args()
    out = perform(a.seconds, a.seed, a.demo)
    path = a.out or os.path.join(HERE, "takes", f"ballblazer_{a.seed}.psq")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    out.w.save(path)
    print(f"{path}: {out.notes} notes, {out.hits} hits, {os.path.getsize(path)} bytes")


if __name__ == "__main__":
    main()
