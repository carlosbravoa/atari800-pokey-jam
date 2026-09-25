#!/usr/bin/env python3
"""Run Ballblazer's real music driver (6502 code from the cartridge) in py65, frame by frame,
and log what it generates ("Song of the Grid", title/menu mode).

  python3 emulate.py [--seconds 60] [--seed 1] [--demo] [--regs] > log.txt

Per frame we call the VBI sound routine $7682 exactly like the game's VBI does ($4E12),
after one call to the music init $7A0D (as at $4C3D). RANDOM ($D20A) is stubbed with a
seeded PRNG; writes to AUDF1-4/AUDC1-4/AUDCTL are captured. $A1 (game mode) = $01 = menu,
so the in-game drum machine is muted, exactly as on the title screen.

Output: driver-level events (phrase choice, riff choice, tempo/loudness) and per-channel
note-on events decoded from the register stream. --regs also dumps raw registers per frame.
"""
import argparse, math, os, random, sys
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory

HERE = os.path.dirname(os.path.abspath(__file__))
rom = open(os.path.join(HERE, '..', 'Ballblazer.rom'), 'rb').read()

CLK = 63921.0
NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
PHRASE_NAMES = {0x7D40: 'HOME', 0x7C75: 'A', 0x7C99: 'B', 0x7CC7: 'C', 0x7CF6: 'D',
                0x7DF3: 'END', 0x7E50: 'J1', 0x7E6D: 'J2', 0x7E9E: 'J3'}

def hz_name(f):
    m = 69 + 12 * math.log2(f / 440.0); n = int(round(m))
    return '%s%d' % (NAMES[n % 12], n // 12 - 1)

def pitch(audf, audc):
    d = audc & 0xE0
    n1 = audf + 1
    if d in (0xA0, 0xE0):
        return hz_name(CLK / (2 * n1))
    if d == 0xC0:  # poly4 sampled every (N+1) 64k ticks; period 15/gcd(N+1,15) samples
        per = 15 // math.gcd(n1, 15)
        return hz_name(CLK / (per * n1)) + '~' if per > 1 else 'dc'
    return 'noise%02X' % audf

def build_memory(rng):
    mem = ObservableMemory()
    img = rom[0x8000:0x10000]          # banks 4,5,6,7 -> $4000-$BFFF
    for i, b in enumerate(img):
        mem._subject[0x4000 + i] = b
    mem.subscribe_to_read([0xD20A], lambda a: rng.randrange(256))
    regs = [0] * 9
    def w(a, v):
        regs[a - 0xD200] = v
    mem.subscribe_to_write(range(0xD200, 0xD209), w)
    flags = {'phrase': False}
    def cb(a, v):            # $7B14 writes the phrase-end callback -> a new phrase was chosen
        flags['phrase'] = True
    mem.subscribe_to_write([0x13DB], cb)
    return mem, regs, flags

def call(mpu, addr, limit=200000):
    """JSR addr with a sentinel return address; run until it returns."""
    sentinel = 0xFFF0
    mpu.memory._subject[sentinel] = 0xEA
    ret = sentinel - 1
    mpu.memory[0x100 + mpu.sp] = (ret >> 8) & 0xFF; mpu.sp = (mpu.sp - 1) & 0xFF
    mpu.memory[0x100 + mpu.sp] = ret & 0xFF; mpu.sp = (mpu.sp - 1) & 0xFF
    mpu.pc = addr
    n = 0
    while mpu.pc != sentinel:
        mpu.step(); n += 1
        if n > limit:
            raise RuntimeError('runaway at $%04X' % mpu.pc)
    return n

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seconds', type=float, default=60)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--demo', action='store_true', help='set $B8 (attract/demo flag) before init')
    ap.add_argument('--regs', action='store_true', help='dump raw POKEY registers every frame')
    a = ap.parse_args()

    rng = random.Random(a.seed)
    mem, regs, flags = build_memory(rng)
    mpu = MPU(memory=mem)
    mpu.sp = 0xFF
    m = mem._subject
    m[0xA1] = 0x01                     # game mode: menu / title screen
    if a.demo: m[0xB8] = 1
    call(mpu, 0x7A0D)                  # music init (as at $4C3D)

    out = sys.stdout.write
    out('# Ballblazer music driver emulation: seed=%d seconds=%g demo=%s\n' % (a.seed, a.seconds, a.demo))
    out('# frame  time  | driver events / ch1..ch4 note-ons  (ch1-3 = sequencer bass/chords/perc, '
        'ch4 = lead riff, ch3 also carries the lead echo)\n')
    frames = int(a.seconds * 60)
    prev = [(0, 0)] * 4
    prev_ptr = None
    prev_tempo = m[0x14D6]
    for fr in range(frames):
        # state before the frame
        ptr_before = m[0xD9] | m[0xDA] << 8
        riffpos_before = m[0x14DD]
        call(mpu, 0x7682)
        ev = []
        ptr = m[0xD9] | m[0xDA] << 8
        if flags['phrase'] and ptr in PHRASE_NAMES:
            flags['phrase'] = False
            ev.append('PHRASE %s (run=%02X loud=%d target=%d saw=%d)' % (
                PHRASE_NAMES[ptr], m[0x14E3], m[0x14D7], m[0x14D9], m[0x14DA]))
        prev_ptr = ptr
        if m[0x14D6] != prev_tempo:
            ev.append('TEMPO %d frames/note' % m[0x14D6]); prev_tempo = m[0x14D6]
        rp = m[0x14DD]
        if rp != riffpos_before and rp & 7 == 0:
            ev.append('next RIFF %d (loud=%d echo=%d)' % (rp >> 3, m[0x14D7], m[0x14D8]))
        elif rp == 0x59 and riffpos_before != 0x59:
            ev.append('RIFF 11 (phrase opener)')
        call_prev = None
        for ch in range(4):
            f, c = regs[2 * ch], regs[2 * ch + 1]
            pf, pc = prev[ch]
            vol, pvol = c & 15, pc & 15
            if vol and (f != pf or (c & 0xF0) != (pc & 0xF0) or vol > pvol):
                ev.append('ch%d %s(F=%02X C=%02X)' % (ch + 1, pitch(f, c), f, c))
            prev[ch] = (f, c)
        if a.regs:
            ev.append('regs ' + ' '.join('%02X%02X' % (regs[2*i], regs[2*i+1]) for i in range(4)))
        if ev:
            out('%6d %6.2f  %s\n' % (fr, fr / 60.0, ' | '.join(ev)))

if __name__ == '__main__':
    main()
