#!/usr/bin/env python3
"""Dump Ballblazer's "Song of the Grid" music data (riffs, phrases, instrument/note table,
drum machine, tempo list) from the cartridge image as readable notes.

Memory layout (see BALLBLAZER_MUSIC.md): the game's $4000-$7FFF RAM image is copied at
cold start from cart banks 4 and 5 (file 0x8000 / 0xA000); the music lives in bank 5,
RAM $6000-$7FFF == file 0xA000-0xBFFF.
"""
import math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROM = os.path.join(HERE, '..', 'Ballblazer.rom')
rom = open(ROM, 'rb').read()

def ram(addr, n=1):
    """read game RAM image ($4000-$7FFF from banks 4/5, $8000-$BFFF from banks 6/7)."""
    base = {0x4: 0x8000, 0x6: 0xA000, 0x8: 0xC000, 0xA: 0xE000}[(addr >> 12) & 0xE]
    off = base + (addr & 0x1FFF)
    return rom[off:off + n] if n > 1 else rom[off]

CLK = 63921.0          # NTSC 64 kHz POKEY base clock (AUDCTL=0, set at $7A19)
NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']

def hz_to_name(f):
    if f <= 0: return '---'
    m = 69 + 12 * math.log2(f / 440.0)
    n = int(round(m))
    cents = int(round((m - n) * 100))
    return '%s%d%+d' % (NAMES[n % 12], n // 12 - 1, cents)

def pure(audf):
    return CLK / (2 * (audf + 1))

def note_name(audf, audc=0xA0):
    dist = audc & 0xE0
    if dist in (0xA0, 0xE0):
        return hz_to_name(pure(audf))
    if dist == 0xC0:   # 4-bit poly sampled every N+1 ticks: period 15/gcd(N+1,15) samples ("buzzy bass")
        per = 15 // math.gcd(audf + 1, 15)
        return hz_to_name(CLK / (per * (audf + 1))) + '(poly4/%d)' % per
    if dist in (0x80, 0x00):
        return 'noise'
    return hz_to_name(pure(audf)) + '(dist%X)' % (dist >> 4)

# ---------------------------------------------------------------- tables
RIFFS = 0x7B75       # 32 riffs x 8 AUDF bytes, 0 = rest
TEMPOS = 0x7B6C      # frames-per-riff-note list, 0-terminated, cycled per "cycle"
INSTR = 0x7EBA       # 67 x (AUDF, AUDF-slide/frame (voice 1 only), AUDC)
N_INSTR = (0x7F83 - INSTR) // 3
DRUM_LEN, DRUM_F, DRUM_C = 0x7B27, 0x7B2E, 0x7B35   # 7-entry drum sound tables
DRUM_PAT = [0x7B3C, 0x7B4C, 0x7B5C]                  # 3 x 16-step patterns (drum ids)
PHRASES = {  # sequencer (bass/chord) phrases, selected by the phrase-end callback $7A4F
    'HOME ($7D40)': 0x7D40,
    'A ($7C75)': 0x7C75,
    'B ($7C99)': 0x7C99,
    'C ($7CC7)': 0x7CC7,
    'D ($7CF6)': 0x7CF6,
    'JINGLE-end-of-game? ($7DF3, via $75A5)': 0x7DF3,
    'JINGLE $7E50 (via $7584)': 0x7E50,
    'JINGLE $7E6D (via $758F)': 0x7E6D,
    'JINGLE $7E9E (via $759A)': 0x7E9E,
}

def instr(i):
    a = INSTR + 3 * i
    return ram(a), ram(a + 1), ram(a + 2)

def parse_phrase(addr):
    """record = dur, then up to 3 instrument indices (voice1..3) ended early by a byte>=$80.
    dur==0 ends the phrase. Returns list of (dur, [idx or None]*3)."""
    out = []
    while True:
        dur = ram(addr); addr += 1
        if dur == 0: break
        vs = [None, None, None]
        for v in range(3):
            b = ram(addr); addr += 1
            if b & 0x80: break
            vs[v] = b
        out.append((dur, vs))
    return out, addr

def fmt_instr(i):
    f, s, c = instr(i)
    return '#%02X[F=%02X C=%02X%s %s]' % (i, f, c, (' slide%+d' % (s - 256 if s > 127 else s)) if s else '',
                                        note_name(f, c))

def main():
    out = []
    p = out.append
    p('== Tempo list $7B6C (frames per lead note; advanced once per swell cycle) ==')
    t = []; a = TEMPOS
    while ram(a): t.append(ram(a)); a += 1
    p('  ' + ' '.join(str(x) for x in t))
    p('')
    p('== Riff table $7B75: 32 riffs x 8 notes (AUDF, pure tone $Ax, 64 kHz; 00 = rest) ==')
    for r in range(32):
        b = [ram(RIFFS + r * 8 + i) for i in range(8)]
        p('  riff %2d $%04X: %s | %s' % (r, RIFFS + r * 8, ' '.join('%02X' % x for x in b),
                                        ' '.join(note_name(x) if x else 'rest' for x in b)))
    p('')
    p('== Instrument/note table $7EBA: %d x (AUDF, slide, AUDC) ==' % N_INSTR)
    for i in range(N_INSTR):
        f, s, c = instr(i)
        p('  #%02X: AUDF=%02X slide=%02X AUDC=%02X  %s' % (i, f, s, c, note_name(f, c)))
    p('')
    for name, a in PHRASES.items():
        recs, end = parse_phrase(a)
        tot = sum(d for d, _ in recs)
        p('== Phrase %s .. $%04X, %d frames ==' % (name, end - 1, tot))
        t = 0
        for d, vs in recs:
            p('  t=%4d dur=%3d  v1:%-40s v2:%-34s v3:%s' % (t, d,
              fmt_instr(vs[0]) if vs[0] is not None else '-',
              fmt_instr(vs[1]) if vs[1] is not None else '-',
              fmt_instr(vs[2]) if vs[2] is not None else '-'))
            t += d
        p('')
    p('== Drum machine (in-game, $77E9): 16 steps x 6 frames ==')
    for i in range(7):
        L, F, C = ram(DRUM_LEN + i), ram(DRUM_F + i), ram(DRUM_C + i)
        p('  drum %d: start-vol/len=%d AUDF=%02X dist=%02X' % (i, L, F, C))
    for k, a in enumerate(DRUM_PAT):
        p('  pattern %d $%04X: %s' % (k, a, ' '.join(str(ram(a + i)) for i in range(16))))
    txt = '\n'.join(out) + '\n'
    sys.stdout.write(txt)

if __name__ == '__main__':
    main()
