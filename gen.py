#!/usr/bin/env python3
"""POKEY JAM reference generator: endless procedural music, Ballblazer style.

    python3 gen.py STYLE [--seconds 180] [--seed N] [-o out.psq] [-v]
    python3 gen.py --list

A PC-side model of the generator the Atari will run. It writes a POKEY SYNTH
.psq, so any take can be played in POKEY PLAYER (synth/audition flow) or
streamed with synth/pcplay.py. Algorithms stay 6502-shaped on purpose:
16-bit xorshift RNG, integer ticks, table-driven styles.

The idea (Peter Langston's "riffology", generalised):
  * a style is data: tempo range, swing, chord forms, a bank of short riffs,
    bass/comping/drum pattern banks, instruments, arrangement;
  * the lead strings riffs together at random, bending each on the fly
    (dropped notes, rests, double/half time, repeats, sequences), but the
    riffs are written in chord-scale degrees, so every riff follows the
    chord it lands on -- Ballblazer's riffs were one fixed key;
  * phrases breathe (2/4-bar phrases, cadence onto a chord tone), and each
    tune opens and closes with a generated "head" melody that repeats, so
    the music has themes and not only noodling;
  * bass, comping and drums are pattern walkers with the same randomness;
  * tunes chain forever: new key, tempo, instruments, form each time.

Timing: 12 ticks per beat, 48 per bar, on a straight grid; swing is applied
when ticks become frames (the off-beat eighth moves late).
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "synth"))
import psq  # noqa: E402

from theory import SCALES, Chord, nearest, snap_to_chord  # noqa: E402
import styles as S  # noqa: E402

TPB = 12
BAR = 48
DRUM = {n: i for i, n in enumerate(psq.DRUMS)}
DRUM_CH = {"kick": 0, "snare": 0, "tom": 0, "tom2": 0, "clap": 0,
           "hat": 1, "open": 1, "crash": 1}
LEAD, BASS, COMP1, COMP2 = 0, 1, 2, 3


class Rng:
    """16-bit xorshift (7, 9, 8) -- three shifts, trivial on a 6502"""

    def __init__(self, seed):
        self.s = (seed & 0xFFFF) or 0xACE1

    def byte(self):
        s = self.s
        s ^= (s << 7) & 0xFFFF
        s ^= s >> 9
        s ^= (s << 8) & 0xFFFF
        self.s = s
        return s & 0xFF

    def below(self, n):
        return (self.byte() * n) >> 8

    def chance(self, p):
        return self.byte() < int(p * 256)

    def pick(self, seq):
        return seq[self.below(len(seq))]

    def wpick(self, items, weights):
        t = sum(weights)
        r = (self.byte() * t) >> 8
        for it, w in zip(items, weights):
            if r < w:
                return it
            r -= w
        return items[-1]


# ---- riff notation --------------------------------------------------------
DUR = {"s": 3, "e": 6, "q": 12, "d": 18, "h": 24, "w": 48, "t": 4}


def parse_riff(text):
    """'e: 0 2 4 6/q 3b 2 r' -> [(deg or None, semis, ticks)]

    Degrees count the chord's scale from its root (0 = root, 7 = octave in a
    7-note scale). A trailing b/# moves the note a semitone down/up (for
    chromatic approach tones). /s /e /q /d /h /w set a note's length, a
    leading 'x:' sets the default. 'r' is a rest.
    """
    default = 6
    out = []
    for tok in text.split():
        if tok.endswith(":"):
            default = DUR[tok[:-1]]
            continue
        dur = default
        if "/" in tok:
            tok, d = tok.split("/")
            dur = DUR[d]
        if tok == "r":
            out.append((None, 0, dur))
            continue
        semis = 0
        while tok[-1] in "b#":
            semis += -1 if tok[-1] == "b" else 1
            tok = tok[:-1]
        out.append((int(tok), semis, dur))
    return out


# ---- output: ticks -> frames with swing, per tune --------------------------
class Out:
    def __init__(self):
        self.w = psq.Writer(title="", mode=psq.STEREO, tracks=4, drums=2)
        self.frame0 = 0          # frame where the current tune starts
        self.beat = 24           # frames per beat
        self.swing = 0           # ticks the off-beat eighth is late (0-3)
        self.notes = 0
        self.hits = 0

    def fr(self, tick):
        b, r = divmod(tick, TPB)
        s = self.swing
        if r < 6:
            x = r * (6 + s) / 6
        else:
            x = 6 + s + (r - 6) * (6 - s) / 6
        return self.frame0 + int((b * TPB + x) * self.beat / TPB)

    def note(self, track, tick, dur, n, gap=1):
        on, off = self.fr(tick), self.fr(tick + dur)
        off = max(on + 1, off - gap)
        self.w.note_on(on, track, max(0, min(95, n)))
        self.w.note_off(off, track)
        self.notes += 1

    def drum(self, tick, name):
        self.w.drum(self.fr(tick), DRUM[name], DRUM_CH[name])
        self.hits += 1

    def preset(self, tick, track, p):
        self.w.preset(self.fr(tick), track, p)


# ---- one tune ---------------------------------------------------------------
class Tune:
    """a tune = key + tempo + form + instruments, arranged into sections"""

    def __init__(self, st, rng, out, verbose=False):
        self.st, self.rng, self.out, self.v = st, rng, out, verbose
        self.key = rng.pick(st["keys"])
        lo, hi = st["beat"]
        out.beat = lo + rng.below(hi - lo + 1)
        sw = st.get("swing", 0)
        # real swing flattens as the tempo rises
        out.swing = sw if out.beat >= 22 else max(0, sw - 1)
        self.form = rng.pick(st["forms"])
        self.grid = self.parse_form(self.form["bars"])
        self.riffs = [parse_riff(r) for r in st["riffs"]]
        self.lead_last = None     # last lead note (for continuity)
        self.comp_last = [None, None]
        self.bass_last = None
        self.sec0 = 0             # tick where the current section starts
        self.off = 0              # form position at the section start
        ks = st["lead"].get("key_scale")
        self.key_chord = Chord(self.key, "I") if ks else None
        if ks:
            self.key_chord.scale = SCALES[ks]

    def parse_form(self, text):
        """'Imaj7 | vi7 | ii7 V7 | ...' -> per bar [(tick_in_bar, Chord)]"""
        bars = []
        for b in text.split("|"):
            syms = b.split()
            step = BAR // len(syms)
            bars.append([(i * step, Chord(self.key, s, self.st.get("scale_override")))
                         for i, s in enumerate(syms)])
        return bars

    def chord_at(self, tick):
        """chord sounding at a tune tick (form-wrapped from the section start)"""
        tick = tick - self.sec0 + self.off
        bar = self.grid[(tick // BAR) % len(self.grid)]
        pos = tick % BAR
        cur = bar[0][1]
        for t, c in bar:
            if t <= pos:
                cur = c
        return cur

    def next_change(self, tick):
        """tick of the next chord change after `tick` and the chord there"""
        c0 = self.chord_at(tick)
        t = (tick // 6 + 1) * 6
        while t < tick + 2 * BAR:
            c = self.chord_at(t)
            if c is not c0:
                return t, c
            t += 6
        return t, self.chord_at(t)

    def lead_chord(self, t):
        """the chord whose scale the riffs are read in"""
        return self.key_chord or self.chord_at(t)

    # -- lead: riffology ------------------------------------------------------
    def lead(self, t0, nbars, mode, cfg):
        """riffs strung into phrases from t0 for nbars; returns the notes

        mode 'solo' = full riffology; 'head' = calmer, motif-heavy (a theme)
        """
        rng, st = self.rng, self.st
        L = st["lead"]
        lo, hi = L["range"]
        end = t0 + nbars * BAR
        notes = []                            # (tick, dur, note)
        t = t0
        prev = self.lead_last if self.lead_last is not None else (lo + hi) // 2
        last_riff, last_tr = None, 0
        phrase_bars = cfg.get("phrase", L.get("phrase", [2, 4]))
        while t < end:
            pb = rng.pick(phrase_bars)
            p_end = min(end, (t // BAR + pb) * BAR)
            # breathe: the phrase stops a little before its end
            breath = rng.pick(cfg.get("breath", L.get("breath", [0, 6, 12, 18, 24])))
            p_stop = max(t + 6, p_end - breath)
            while t < p_stop:
                # which riff: repeat it, sequence it, or a fresh one
                if last_riff is not None and rng.chance(cfg["repeat"]):
                    ri, tr = last_riff, last_tr
                elif last_riff is not None and rng.chance(cfg["seq"]):
                    ri, tr = last_riff, last_tr + rng.pick([-2, -1, 1, 2])
                else:
                    ri, tr = rng.below(len(self.riffs)), 0
                    if ri == last_riff:
                        ri = (ri + 1) % len(self.riffs)
                last_riff, last_tr = ri, tr
                riff = self.riffs[ri]
                speed = 1
                if rng.chance(cfg["fast"]):
                    speed = 2
                elif rng.chance(cfg["slow"]):
                    speed = 0.5
                # octave: put the riff's first pitched note nearest `prev`
                first = next((d for d, s, _ in riff if d is not None), 0)
                c = self.lead_chord(t)
                n0 = c.degree(first + tr, lo)
                shift = nearest(n0, prev, lo, hi) - n0
                chord_prev = c
                for deg, semis, dur in riff:
                    dur = max(3, int(dur / speed) // 3 * 3)
                    if t >= p_stop:
                        break
                    if deg is None or rng.chance(cfg["rest"]):
                        t += dur
                        continue
                    if notes and rng.chance(cfg["omit"]) and notes[-1][0] + notes[-1][1] == t:
                        tk, dd, nn = notes[-1]             # drop: stretch the last
                        notes[-1] = (tk, dd + dur, nn)
                        t += dur
                        continue
                    c = self.lead_chord(t)
                    n = c.degree(deg + tr, lo) + shift + semis
                    if c is not chord_prev:
                        # new chord inside the riff: keep the line near
                        n = nearest(n, prev, lo, hi)
                        shift = n - semis - c.degree(deg + tr, lo)
                        chord_prev = c
                    if L.get("snap") and t % TPB == 0 and semis == 0:
                        n = snap_to_chord(n, self.chord_at(t))
                    n = nearest(n, n, lo, hi)
                    notes.append((t, min(dur, p_stop - t), n))
                    prev = n
                    t += dur
            # cadence: the phrase's last note lands on a chord tone and rings on
            if notes and notes[-1][0] >= t0:
                tk, dd, nn = notes[-1]
                nn = snap_to_chord(nn, self.chord_at(tk))
                ring = max(dd, min(p_end - tk, dd + rng.pick([0, 6, 12, 24])))
                notes[-1] = (tk, ring, nn)
                prev = nn
            t = p_end
        self.lead_last = prev
        return notes

    def make_head(self, t, n, cfg):
        """the tune's theme: one phrase per plan letter, repeated as planned

        -> [(tick in section, dur, note)] covering n bars
        """
        plan, unit = self.form.get("plan", "A"), self.form.get("unit", n)
        made, notes = {}, []
        for i, letter in enumerate((plan * n)[: max(1, n // unit)]):
            t1 = t + i * unit * BAR
            if letter not in made:
                ph = self.lead(t1, unit, "head", cfg)
                made[letter] = [(tk - t1, dd, nn) for tk, dd, nn in ph]
            for tk, dd, nn in made[letter]:
                if not self.key_chord and (tk % TPB == 0):
                    nn = snap_to_chord(nn, self.chord_at(t1 + tk))   # re-harmonise
                notes.append((tk + t1 - t, dd, nn))
        return notes

    def play_head(self, t, head):
        self.play_lead([(tk + t, dd, nn) for tk, dd, nn in head])

    def play_lead(self, notes, track=LEAD, gap=None):
        g = self.st["lead"].get("gap", 1) if gap is None else gap
        for tk, dd, nn in notes:
            self.out.note(track, tk, dd, nn, g)

    # -- bass -------------------------------------------------------------------
    def bass(self, t0, nbars, kind):
        rng, st = self.rng, self.st
        B = st["bass"]
        lo, hi = B["range"]
        prev = self.bass_last if self.bass_last is not None else lo + 5
        gap = B.get("gap", 2)
        if kind == "walk":
            for beat in range(nbars * 4):
                t = t0 + beat * TPB
                c = self.chord_at(t)
                nt, nc = self.next_change(t)
                root = nearest(c.degree(0, lo), prev, lo, hi)
                if (t - t0) % BAR == 0 or self.chord_at(t - TPB) is not c:
                    n = root if rng.chance(0.85) else nearest(c.degree(2, lo), prev, lo, hi)
                elif nt - t == TPB:
                    # last beat before the change: approach the next root
                    target = nearest(nc.degree(0, lo), prev, lo, hi)
                    n = target + rng.pick([-1, 1, -1, 1, 2, -2, 7 - 12])
                else:
                    # walk: a chord tone or the next scale step toward the target
                    target = nearest(nc.degree(0, lo), prev, lo, hi)
                    step = 1 if target > prev else -1
                    d = rng.pick([1, 2, 2])
                    cand = prev
                    for _ in range(d):
                        cand += step
                        while cand % 12 not in {(c.root + s) % 12 for s in c.scale}:
                            cand += step
                    n = cand
                n = nearest(n, prev, lo, hi)
                self.out.note(BASS, t, TPB, n, gap)
                prev = n
        else:
            pats = B["patterns"][kind]
            pat = rng.pick(pats)
            for bar in range(nbars):
                if rng.chance(B.get("change", 0.25)):
                    pat = rng.pick(pats)
                for tick, dur, code in pat:
                    t = t0 + bar * BAR + tick
                    c = self.chord_at(t)
                    root = nearest(c.degree(0, lo), prev if code != "R" else lo + 7, lo, hi)
                    if code == "R":
                        n = root
                    elif code == "5":
                        n = root + 7 if root + 7 <= hi else root - 5
                    elif code == "L":
                        n = root - 5 if root - 5 >= lo else root + 7
                    elif code == "8":
                        n = root + 12 if root + 12 <= hi else root
                    elif code == "3":
                        n = root + c.tones[1]
                    elif code == "7":
                        n = root + (c.tones[3] if len(c.tones) > 3 else 12) - 12 * (root + 10 > hi)
                    elif code == "A":
                        nt, nc = self.next_change(t)
                        n = nearest(nc.degree(0, lo), root, lo, hi) + rng.pick([-1, 1, -2])
                    elif code == "S":            # a scale step off the root
                        n = c.degree(rng.pick([1, 2, 4, 6]), root - 1)
                    else:
                        n = root
                    self.out.note(BASS, t, dur, n, gap)
                    prev = n
        self.bass_last = prev

    # -- comping: two voices, voice-led -------------------------------------------
    def comp(self, t0, nbars, kind):
        rng, st = self.rng, self.st
        C = st["comp"]
        lo, hi = C["range"]
        pats = C["patterns"][kind]
        pat = rng.pick(pats)
        gap = C.get("gap", 2)
        for bar in range(nbars):
            if rng.chance(C.get("change", 0.3)):
                pat = rng.pick(pats)
            for tick, dur, what in pat:
                t = t0 + bar * BAR + tick
                c = self.chord_at(t)
                tones = c.tones
                if C.get("voicing") == "guide" and len(tones) >= 4:
                    pair = [tones[1], tones[3]]          # 3rd and 7th
                elif C.get("voicing") == "power":
                    pair = [0, 7]
                else:
                    pair = [tones[1], tones[2]]
                vs = []
                for i, iv in enumerate(pair):
                    base = (c.root + iv) % 12
                    ref = self.comp_last[i] if self.comp_last[i] is not None else (lo + hi) // 2 + 3 * i
                    n = nearest(lo + ((base - lo) % 12), ref, lo, hi)
                    vs.append(n)
                if vs[0] == vs[1]:
                    vs[1] += 12 if vs[1] + 12 <= hi else -12
                vs.sort()
                self.comp_last = vs[:]
                if what == "arp":                        # arpeggio across the pair
                    seq = [vs[0], vs[1], vs[0] + 12, vs[1]]
                    for k in range(dur // 3):
                        self.out.note(COMP1, t + 3 * k, 3, seq[k % 4], 1)
                    continue
                self.out.note(COMP1, t, dur, vs[0], gap)
                if what != "1":
                    self.out.note(COMP2, t, dur, vs[1], gap)

    # -- drums ------------------------------------------------------------------
    def drums(self, t0, nbars, kind, fill_every=4, crash=True):
        rng, D = self.rng, self.st["drums"]
        pats = D["patterns"][kind]
        pat = rng.pick(pats)
        for bar in range(nbars):
            tb = t0 + bar * BAR
            if bar and bar % 4 == 0 and rng.chance(D.get("change", 0.3)):
                pat = rng.pick(pats)
            use = pat
            last = (bar + 1) % fill_every == 0 or bar == nbars - 1
            if last and D.get("fills") and rng.chance(D.get("fill", 0.6)):
                use = dict(pat)
                fill = rng.pick(D["fills"])
                for drum in list(use):
                    use[drum] = use[drum][:8] + "." * 8     # keep the first half
                for drum, s in fill.items():
                    use[drum] = use.get(drum, "." * 16)[:8] + s[8:]
            for drum, s in use.items():
                for i, ch in enumerate(s):
                    if ch == ".":
                        continue
                    p = 1.0 if ch == "x" else int(ch) / 10
                    if rng.chance(p):
                        self.out.drum(tb + i * 3, drum)
            if crash and bar == 0:
                self.out.drum(tb, "crash")

    # -- arrangement --------------------------------------------------------------
    def play(self, t_tune):
        """generate the whole tune from frame t_tune; returns its length in ticks"""
        st, rng, out = self.st, self.rng, self.out
        out.frame0 = t_tune
        L = st["lead"]
        flen = len(self.grid)
        arr = rng.pick(st["arrangements"])
        insts = {LEAD: rng.pick(L["presets"]), BASS: rng.pick(st["bass"]["presets"]),
                 COMP1: rng.pick(st["comp"]["presets"])}
        insts[COMP2] = insts[COMP1]
        for tr, p in insts.items():
            out.preset(0, tr, p)
        head = None
        t = 0
        if self.v:
            print(f"  tune: key {psq.NAMES[self.key]} beat {out.beat}f "
                  f"({3600 // out.beat} bpm) swing {out.swing} form {self.form['name']} "
                  f"arr {' '.join(arr)} lead {insts[LEAD]}")
        for sec in arr:
            cfg = st["sections"][sec]
            n = cfg.get("bars", flen)
            self.sec0 = t
            self.off = (flen - n % flen) % flen * BAR if cfg.get("from_end") else 0
            if cfg.get("lead_preset"):
                out.preset(t, LEAD, rng.pick(L["presets"]))
            if sec.startswith("head"):
                if head is None:
                    head = self.make_head(t, n, cfg)
                self.play_head(t, head)
            elif cfg.get("lead"):
                if cfg.get("trade") and st.get("trade_preset"):
                    # trading fours: the lead and voice 4 take turns
                    notes = self.lead(t, n, "solo", cfg)
                    out.preset(t, COMP2, rng.pick(st["trade_preset"]))
                    a = [x for x in notes if ((x[0] - t) // (4 * BAR)) % 2 == 0]
                    b = [x for x in notes if ((x[0] - t) // (4 * BAR)) % 2 == 1]
                    self.play_lead(a)
                    self.play_lead(b, track=COMP2)
                else:
                    self.play_lead(self.lead(t, n, "solo", cfg))
            if cfg.get("bass"):
                self.bass(t, n, cfg["bass"])
            if cfg.get("comp") and not cfg.get("trade"):
                self.comp(t, n, cfg["comp"])
            if cfg.get("drums"):
                self.drums(t, n, cfg["drums"], crash=cfg.get("crash", True))
            t += n * BAR
        # ending: one held tonic chord and a crash
        c = Chord(self.key, st.get("final", "I"))
        L_lo, L_hi = L["range"]
        B_lo, B_hi = st["bass"]["range"]
        out.note(LEAD, t, BAR, nearest(c.degree(0, L_lo), self.lead_last or L_lo, L_lo, L_hi), 4)
        out.note(BASS, t, BAR, c.degree(0, B_lo), 4)
        C_lo, _ = st["comp"]["range"]
        out.note(COMP1, t, BAR, c.degree(2, C_lo), 4)
        out.note(COMP2, t, BAR, c.degree(4, C_lo), 4)
        out.drum(t, "crash")
        out.drum(t, "kick")
        return t + BAR + st.get("tail", 2 * TPB)


def generate(style, seconds, seed, verbose=False):
    st = S.STYLES[style]
    rng = Rng(seed)
    out = Out()
    out.w.title = f"JAM {style} {seed}"
    frame = 0
    while frame < seconds * 60:
        tune = Tune(st, rng, out, verbose)
        ticks = tune.play(frame)
        frame = out.fr(ticks)
    out.w.at(frame, psq.ALLOFF)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("style", nargs="?")
    ap.add_argument("--seconds", type=int, default=180)
    ap.add_argument("--seed", type=int, default=1984)
    ap.add_argument("-o", "--out")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.list or not a.style:
        for k, v in S.STYLES.items():
            print(f"{k:10s} {v['blurb']}")
        return
    style = a.style.upper()
    out = generate(style, a.seconds, a.seed, a.verbose)
    path = a.out or os.path.join(HERE, "takes", f"{style.lower()}_{a.seed}.psq")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    out.w.save(path)
    size = os.path.getsize(path)
    print(f"{path}: {out.notes} notes, {out.hits} hits, {size} bytes")


if __name__ == "__main__":
    main()
