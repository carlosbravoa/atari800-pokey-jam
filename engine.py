#!/usr/bin/env python3
"""POKEY JAM streaming model: the generator exactly as the 6502 will run it.

    python3 engine.py STYLE [--seconds 150] [--seed N] [-o take.psq] [-v]

gen.py composed whole tunes at once. The Atari can't: it composes one bar
at a time, a little ahead of the music, forever. This module is that
machine, bar by bar, with 6502-shaped state and integer-only math, and it
is the reference the 6502 port must match event for event (py65 test).

Per bar the generator runs each voice's state machine over the bar's 48
ticks, producing notes (start tick, length, pitch). Then every event whose
frame is safely final (before the next bar's first frame minus the largest
release gap) is sorted and sent: here into a .psq, on the Atari into the
player's event ring.

Styles come from styles.py through compile_style(), which turns them into
the byte tables the 6502 build will also use (gen_tables.py, later).
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "synth"))
import psq  # noqa: E402

import styles as S  # noqa: E402
from theory import CHORDS, SCALES, roman  # noqa: E402
from gen import Rng, parse_riff  # noqa: E402

TPB, BAR = 12, 48
LEAD, BASS, COMP1, COMP2 = 0, 1, 2, 3
DRUMS = psq.DRUMS                       # kick snare hat open tom tom2 clap crash
DRUM_CH = [0, 0, 1, 1, 0, 0, 0, 1]
MAXGAP = 4                              # largest release gap, frames
PRESETS = psq.PRESETS


def prob(p):
    return int(p * 256)


# ---- style compiler: dicts -> byte-level tables ---------------------------
def compile_style(st):
    c = dict(name=st.get("name", ""))
    ov = st.get("scale_override") or {}
    c["beat"] = st["beat"]
    c["swing"] = st.get("swing", 0)
    c["keys"] = st["keys"]
    forms = []
    for f in st["forms"]:
        bars = []
        for b in f["bars"].split("|"):
            syms = b.split()
            step = BAR // len(syms)
            row = []
            for i, s in enumerate(syms):
                r, q = roman(s)
                tones, sc = CHORDS[q]
                row.append((i * step, r, tones, SCALES[ov.get(q, sc)]))
            bars.append(row)
        forms.append(dict(name=f["name"], bars=bars, plan=f.get("plan", "A"),
                          unit=f.get("unit", len(bars))))
    c["forms"] = forms
    c["riffs"] = [parse_riff(r) for r in st["riffs"]]
    L = st["lead"]
    c["lead"] = dict(range=L["range"], presets=[PRESETS.index(p) for p in L["presets"]],
                     gap=L.get("gap", 1), snap=int(L.get("snap", 2)),
                     key_scale=SCALES[L["key_scale"]] if L.get("key_scale") else None,
                     phrase=L.get("phrase", [2, 4]), breath=L.get("breath", [0, 6, 12, 18, 24]),
                     hook=L.get("hook"), hookp=prob(L.get("hookp", 0)))
    c["trade_preset"] = [PRESETS.index(p) for p in st.get("trade_preset", [])]
    B = st["bass"]
    c["bass"] = dict(range=B["range"], presets=[PRESETS.index(p) for p in B["presets"]],
                     gap=B.get("gap", 2), change=prob(B.get("change", 0.25)),
                     patterns=B.get("patterns", {}))
    C = st["comp"]
    c["comp"] = dict(range=C["range"], presets=[PRESETS.index(p) for p in C["presets"]],
                     gap=C.get("gap", 2), change=prob(C.get("change", 0.3)),
                     voicing=C.get("voicing", "triad"), patterns=C["patterns"])
    D = st["drums"]
    pats = {}
    for k, lst in D["patterns"].items():
        pats[k] = [[(DRUMS.index(d), [0 if ch == "." else 256 if ch == "x" else prob(int(ch) / 10)
                                      for ch in s]) for d, s in p.items()] for p in lst]
    fills = [[(DRUMS.index(d), [0 if ch == "." else 256 if ch == "x" else prob(int(ch) / 10)
                                for ch in s]) for d, s in f.items()] for f in D.get("fills", [])]
    c["drums"] = dict(patterns=pats, fills=fills, change=prob(D.get("change", 0.3)),
                      fill=prob(D.get("fill", 0.6)), split=bool(D.get("split")))
    secs = {}
    for k, s in st["sections"].items():
        d = dict(s)
        for p in ("repeat", "seq", "fast", "slow", "rest", "omit"):
            if p in d:
                d[p] = prob(d[p])
        lead, head = bool(s.get("lead")), k.startswith("head")
        # intensity: flat energy, or a solo's build (see ARC)
        d["build"] = bool(s.get("build", lead and not head and not s.get("trade")))
        d["energy"] = s.get("energy", 11 if head else 10 if lead else 9)
        d["quote"] = prob(s.get("quote", 0.2 if d["build"] else 0))
        d["resp"] = prob(s.get("resp", 0.2 if d["build"] else 0))
        d["trip"] = prob(s.get("trip", L.get("trip", 0.06)))
        d["dot"] = prob(s.get("dot", L.get("dot", 0.05)))
        secs[k] = d
    c["sections"] = secs
    c["arrangements"] = st["arrangements"]
    r, q = roman(st.get("final", "I"))
    c["final"] = (r, CHORDS[q][0])
    c["tail"] = st.get("tail", 2 * TPB)
    c["mix"] = list(st.get("mix", [0, 0, 0, 0]))
    c["mono"] = 1 if st.get("mono") == "lead" else 0
    return c


STYLE_NAMES = list(S.STYLES)
COMPILED = [compile_style(S.STYLES[k]) for k in STYLE_NAMES]
BUZZY = {PRESETS.index("BASS"), PRESETS.index("SYNTH")}   # poly4 lead waves
BUZZ_HI = 57            # buzz is within 12 cents up to A5, ~30 above
V8_LO, V8_HI = 24, 45   # 8-bit 64 kHz voices: within 3 cents up to A4
# intensity 0-15 per bar: a solo builds to a peak ~2/3 through, then settles
ARC = [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 15, 15, 14, 13, 12]
# the lead's volume cap for an intensity (Ballblazer's swell)
LVL = [8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15]


# ---- chords as the 6502 sees them ------------------------------------------
class Ch:
    __slots__ = ("id", "root", "tones", "scale", "mask", "smask")

    def __init__(self, cid, root, tones, scale):
        self.id, self.root, self.tones, self.scale = cid, root, tones, scale
        self.mask = sum(1 << ((root + t) % 12) for t in tones)
        self.smask = sum(1 << ((root + t) % 12) for t in scale)

    def degree(self, d, base):
        n = len(self.scale)
        octv, i = divmod(d, n)
        return base + ((self.root - base) % 12) + 12 * octv + self.scale[i]


def nearest(n, target, lo, hi):
    while n - target > 6 and n - 12 >= lo:
        n -= 12
    while target - n > 6 and n + 12 <= hi:
        n += 12
    while n < lo:
        n += 12
    while n > hi:
        n -= 12
    return n


def snap(n, ch):
    for d in (0, 1, -1, 2, -2, 3, -3):
        if ch.mask >> ((n + d) % 12) & 1:
            return n + d
    return n


class Note:
    __slots__ = ("t", "d", "n", "tr", "gap", "on", "ev")

    def __init__(self, t, d, n, tr, gap, on, ev):
        self.t, self.d, self.n, self.tr, self.gap, self.on, self.ev = t, d, n, tr, gap, on, ev


# event classes: the sort key after the frame (stable within a class)
K_CTL, K_OFF, K_ON, K_DRUM = 0, 1, 2, 3


# ---- the machine ------------------------------------------------------------
class Engine:
    def __init__(self, style, seed, verbose=False, random=False):
        self.random = random          # RANDOM on: each later tune picks a style
        self.first = True
        self.styn = STYLE_NAMES.index(style)
        self.st = COMPILED[self.styn]
        self.rng = Rng(seed)
        self.v = verbose
        self.frame0 = 0              # frame of the tune's tick 0
        self.last = [None] * 4       # per track: the note still open (off not queued)
        self.queue = []              # [frame, class, op, track, arg], creation order
        self.sent_frame = 0
        self.out = []                # (frame, op, track, arg)
        self.new_tune()

    # -- tune / section setup ------------------------------------------------------
    def new_tune(self):
        if self.random and not self.first:
            self.styn = self.rng.below(len(COMPILED))
            self.st = COMPILED[self.styn]
        self.first = False
        st, rng = self.st, self.rng
        self.key = rng.pick(st["keys"])
        lo, hi = st["beat"]
        self.beat = lo + rng.below(hi - lo + 1)
        sw = st["swing"]
        self.swing = sw if self.beat >= 22 else max(0, sw - 1)
        s = self.swing
        # frames from bar start for each tick 0..48 (swing: the off-beat 8th moves late)
        x6 = [r * (6 + s) if r < 6 else 6 * (6 + s) + (r - 6) * (6 - s) for r in range(12)]
        self.fb = [((t // 12) * 72 + x6[t % 12]) * self.beat // 72 for t in range(48)] + [4 * self.beat]
        self.form = rng.pick(st["forms"])
        self.flen = len(self.form["bars"])
        self.chords = []
        for bi, row in enumerate(self.form["bars"]):
            self.chords.append([(tk, Ch(bi * 2 + k, (self.key + r) % 12, tones, sc))
                                for k, (tk, r, tones, sc) in enumerate(row)])
        ks = st["lead"]["key_scale"]
        self.key_chord = Ch(255, self.key, [0, 4, 7], ks) if ks else None
        self.arr = rng.pick(st["arrangements"])
        L = st["lead"]
        self.inst = [rng.pick(L["presets"]), rng.pick(st["bass"]["presets"]),
                     rng.pick(st["comp"]["presets"])]
        self.inst.append(self.inst[2])
        self.tick = 0                # tune tick of the bar being generated
        for tr in range(4):
            self.ctl(0, psq.PRESET, tr, self.inst[tr])
        for tr in range(4):
            self.ctl(0, psq.LEVEL, tr, st["mix"][tr])
        self.lastlv = [m or 15 for m in st["mix"]]
        self.dyn = None             # the lead's swell level (set at the first bar)
        self.last_call = False      # the last phrase can be answered
        self.phr_riff = None        # first riff of the running phrase
        self.force = None           # a response opens with the call's motif
        self.resp = False           # this phrase is voice 4's answer
        self.rw = (0, 0)            # ... and its window (comp's voice 2 rests)
        self.quote = None           # this phrase quotes the theme
        self.set_lead_range(self.inst[0])
        self.lead_prev = None
        self.comp_last = [None, None]
        self.bass_last = None
        self.head = {}               # plan letter -> [(tick in unit, dur, note)]
        self.head_done = False
        self.sec_i = -1
        self.ending = 0              # 0 no, 1 = the final chord bar, 2 = tail
        if self.v:
            print(f"  tune: {STYLE_NAMES[self.styn]} key {psq.NAMES[self.key]} beat {self.beat}f "
                  f"({3600 // self.beat} bpm) swing {self.swing} form {self.form['name']} "
                  f"arr {' '.join(self.arr)} lead {PRESETS[self.inst[0]]}")
        self.next_section()

    def next_section(self):
        st, rng = self.st, self.rng
        self.sec_i += 1
        if self.sec_i >= len(self.arr):
            self.sec = None
            return
        name = self.arr[self.sec_i]
        self.sname = name
        cfg = self.cfg = st["sections"][name]
        self.nbars = cfg.get("bars", self.flen)
        self.sec0 = self.tick
        self.sbar = 0
        self.off = (self.flen - self.nbars % self.flen) % self.flen if cfg.get("from_end") else 0
        self.sec = name
        if cfg.get("lead_preset"):
            p = rng.pick(st["lead"]["presets"])
            self.ctl(self.tick, psq.PRESET, LEAD, p)
            self.set_lead_range(p)
        self.is_head = name.startswith("head")
        self.trade = bool(cfg.get("trade")) and bool(st["trade_preset"])
        # the lead's machine restarts at every section
        self.lt = self.tick          # next lead tick
        self.p_end = self.lt         # no phrase yet
        self.riff = None
        self.last_riff, self.last_tr = None, 0
        self.lnotes = []             # this section's lead notes (for omit/cadence)
        self.unit_rec = None
        # replaying the head: one letter per unit
        if cfg.get("lead") and self.trade:
            self.ctl(self.tick, psq.PRESET, COMP2, rng.pick(st["trade_preset"]))
        # pattern machines pick their first pattern at the section start
        self.bpat = self.cpat = self.dpat = None

    # -- chord lookup ---------------------------------------------------------------
    def chord_at(self, tick):
        rel = tick - self.sec0 + self.off * BAR
        row = self.chords[(rel // BAR) % self.flen]
        pos = rel % BAR
        cur = row[0][1]
        for t, c in row:
            if t <= pos:
                cur = c
        return cur

    def next_change(self, tick):
        c0 = self.chord_at(tick)
        t = (tick // 6 + 1) * 6
        while t < tick + 2 * BAR:
            c = self.chord_at(t)
            if c.id != c0.id:
                return t, c
            t += 6
        return t, self.chord_at(t)

    def lead_chord(self, t):
        return self.key_chord or self.chord_at(t)

    def cap(self):
        """the lead's target level: intensity, under the style's mix level"""
        return min(LVL[self.I], self.st["mix"][0] or 15)

    def set_level(self, t, tr, lv):
        if self.lastlv[tr] != lv:
            self.ctl(t, psq.LEVEL, tr, lv)
            self.lastlv[tr] = lv

    def lead_note(self, t, d, n):
        """a lead note: voice 4 takes it in trades and answers; swell + accents"""
        L = self.st["lead"]
        track, pn = LEAD, n
        if self.resp or (self.trade and ((t - self.sec0) // (4 * BAR)) % 2 == 1):
            track = COMP2                         # 8-bit voice: an octave down
            pn = nearest(n - 12, n - 12, V8_LO, V8_HI)
        self.set_level(t, track, min(15, self.dyn + (2 if t % 24 == 0 else 0)))
        nt = self.note(track, t, d, pn, L["gap"])
        self.lnotes.append(nt)
        if self.unit_rec is not None:
            self.unit_rec.append(nt)
        self.lead_prev = n

    def set_lead_range(self, preset):
        """buzzy lead waves go out of tune high up: keep them below A5"""
        lo, hi = self.st["lead"]["range"]
        self.lrange = (lo, min(hi, BUZZ_HI) if preset in BUZZY else hi)

    # -- keeping the lead in tune with the harmony ---------------------------------
    def next_real(self, tick):
        """the next chord change that changes the chord tones -> (tick, chord)"""
        c0 = self.chord_at(tick)
        t = (tick // 6 + 1) * 6
        while t < tick + 2 * BAR:
            c = self.chord_at(t)
            if c.mask != c0.mask:
                return t, c
            t += 6
        return None

    def allowed(self, n, ch):
        """in the chord's scale (or, for key-scale styles, the key's scale)"""
        m = ch.smask | (self.key_chord.smask if self.key_chord else 0)
        return m >> (n % 12) & 1

    def fits_until(self, t, d, n):
        """n started at t can last d: released early at a chord it clashes with"""
        cut = self.next_real(t)
        if cut and cut[0] < t + d and not (cut[1].mask >> (n % 12) & 1):
            return cut[0] - t
        return d

    # -- notes out ---------------------------------------------------------------------
    def note(self, track, t, d, n, gap):
        """a note on a monophonic track; it closes the track's previous one"""
        if self.last[track] is not None:
            self.close(self.last[track], t)
        on = self.fr(t)
        ev = [on, K_ON, psq.NOTE_ON, track, max(0, min(95, n))]
        self.queue.append(ev)
        nt = Note(t, d, ev[4], track, gap, on, ev)
        self.last[track] = nt
        return nt

    def close(self, nt, cut=None):
        """queue the note's off: at its end, or where the next note cuts it"""
        end = nt.t + nt.d
        if cut is not None and cut < end:
            end = cut
        off = max(nt.on + 1, self.fr(end) - nt.gap)
        self.queue.append([off, K_OFF, psq.NOTE_OFF, nt.tr, 0])
        self.last[nt.tr] = None

    def ctl(self, t, op, track, arg):
        self.queue.append([self.fr(t), K_CTL, op, track, arg])

    def drum(self, t, d, ch=None):
        self.queue.append([self.fr(t), K_DRUM, psq.DRUM,
                           DRUM_CH[d] if ch is None else ch, d])

    def fr(self, tick):
        b, r = divmod(tick, BAR)
        return self.frame0 + b * 4 * self.beat + self.fb[r]

    # -- one bar ---------------------------------------------------------------------------
    def bar(self):
        """generate one bar and flush every event that is now final"""
        if self.sec is None and self.ending == 0:
            self.end_bar()
        elif self.sec is not None:
            B0 = self.tick
            cfg = self.cfg
            self.I = ARC[self.sbar * 16 // self.nbars] if cfg["build"] else cfg["energy"]
            if self.dyn is None:
                self.dyn = self.cap()
            if cfg.get("lead"):
                if self.is_head:
                    self.head_bar(B0)
                else:
                    self.lead_bar(B0, B0 + BAR, self.sec0 + self.nbars * BAR)
            if cfg.get("bass"):
                self.bass_bar(B0, cfg["bass"])
            if cfg.get("comp") and not self.trade:
                self.comp_bar(B0, cfg["comp"])
            if cfg.get("drums"):
                self.drum_bar(B0, cfg["drums"])
            self.tick += BAR
            self.sbar += 1
            if self.sbar >= self.nbars:
                self.next_section()
        self.flush()
        if self.ending == 2:
            # the next tune starts where this one's tail ends
            end = self.fr(self.tick) + 0
            self.flush(final=True)
            self.frame0 = end
            self.new_tune()

    def end_bar(self):
        st = self.st
        t = self.tick
        r, tones = st["final"]
        root = (self.key + r) % 12
        ch = Ch(254, root, tones, SCALES["ionian"])
        L_lo, L_hi = self.lrange
        B_lo, _ = st["bass"]["range"]
        C_lo, _ = st["comp"]["range"]
        prev = self.lead_prev if self.lead_prev is not None else L_lo
        self.note(LEAD, t, BAR, nearest(ch.degree(0, L_lo), prev, L_lo, L_hi), 4)
        self.note(BASS, t, BAR, ch.degree(0, B_lo), 4)
        self.note(COMP1, t, BAR, ch.degree(2, C_lo), 4)
        self.note(COMP2, t, BAR, ch.degree(4, C_lo), 4)
        self.drum(t, 7)
        self.drum(t, 0)
        for k, lv in enumerate((12, 9, 6)):     # the last chord fades away
            for tr in range(4):
                self.ctl(t + 12 * (k + 1), psq.LEVEL, tr, min(lv, st["mix"][tr] or 15))
        self.tick += BAR + st["tail"]
        self.ending = 2

    # -- lead: riffology, one bar of the running phrase machine ------------------------------
    def lead_bar(self, B0, B1, s_end, track_of=None):
        rng, st = self.rng, self.st
        L, cfg = st["lead"], self.cfg
        lo, hi = self.lrange
        if self.lead_prev is None:
            self.lead_prev = (lo + hi) // 2
        while self.lt < B1:
            t = self.lt
            if t >= self.p_end:                        # a new phrase
                if t >= s_end:
                    return
                pb = rng.pick(cfg.get("phrase", L["phrase"]))
                self.p_end = min(s_end, (t // BAR + pb) * BAR)
                breath = rng.pick(cfg.get("breath", L["breath"]))
                self.p_stop = max(t + 6, self.p_end - breath)
                self.riff = None
                self.ph_first = len(self.lnotes)
                self.phrase_kind(t, pb)
            if t >= self.p_stop:                       # breathing: cadence, then wait
                self.cadence()
                self.lt = self.p_end
                continue
            rest = min(255, cfg["rest"] * (20 - self.I) // 10)   # loud: fewer rests
            if self.quote is not None:
                self.quote_note(t, B1, rest)
                continue
            if self.riff is None:
                self.start_riff(t)
            deg, semis, dur = self.riff[self.ri]
            self.ri += 1
            if self.speed == 1:
                dur = dur // 2
            elif self.speed == 2:
                dur = dur * 2
            if self.speed < 3:
                dur = max(3, dur // 3 * 3)
            elif self.speed == 3:
                dur = max(2, dur * 2 // 3)            # triplets across the beat
            else:
                dur = max(3, dur * 3 // 2)            # dotted: 3 against 4
            if deg is None or rng.byte() < rest:
                pass
            elif (self.lnotes and rng.byte() < cfg["omit"]
                  and self.lnotes[-1].t + self.lnotes[-1].d == t
                  and self.last[self.lnotes[-1].tr] is self.lnotes[-1]):
                ln = self.lnotes[-1]                      # dropped: the last one rings on
                if self.allowed(ln.n, self.chord_at(t)):  # ... if it still fits
                    ln.d += self.fits_until(t, dur, ln.n)
            else:
                c = self.lead_chord(t)
                n = c.degree(deg + self.tr, lo) + self.shift + semis
                if c.id != self.cprev:
                    n = nearest(n, self.lead_prev, lo, hi)
                    self.shift = n - semis - c.degree(deg + self.tr, lo)
                    self.cprev = c.id
                ch = self.chord_at(t)
                if L["snap"] and t % (24 if L["snap"] == 1 else TPB) == 0:
                    n = snap(n, ch)                       # strong beats: chord tones
                d = min(dur, self.p_stop - t)
                if d > 6 and not self.allowed(n, ch):
                    n = snap(n, ch)                       # no long notes off the scale
                n = nearest(n, n, lo, hi)
                d = self.fits_until(t, d, n)
                self.lead_note(t, d, n)
            self.lt = t + dur
            if self.ri >= len(self.riff):
                self.riff = None
            if self.lt >= self.p_stop:
                self.cadence()
                self.lt = self.p_end

    def start_riff(self, t):
        rng, cfg = self.rng, self.cfg
        lo, hi = self.lrange
        cap = self.cap()                        # the swell moves a step a riff
        if self.dyn < cap:
            self.dyn += 1
        elif self.dyn > cap:
            self.dyn -= 1
        if self.force is not None:              # an answer: the call's motif, moved
            ri, tr = self.force
            tr = max(-7, min(7, tr + rng.pick([-2, -1, 1, 2])))
            self.force = None
        elif (self.st["lead"]["hook"] is not None and self.phr_riff is None
              and rng.byte() < self.st["lead"]["hookp"]):
            ri, tr = self.st["lead"]["hook"], 0     # the style's signature opener
        elif self.last_riff is not None and rng.byte() < cfg["repeat"]:
            ri, tr = self.last_riff, self.last_tr
        elif self.last_riff is not None and rng.byte() < cfg["seq"]:
            ri, tr = self.last_riff, self.last_tr + rng.pick([-2, -1, 1, 2])
            tr = max(-7, min(7, tr))            # sequences can't wander off
        else:
            ri, tr = rng.below(len(self.st["riffs"])), 0
            if ri == self.last_riff:
                ri = (ri + 1) % len(self.st["riffs"])
        self.last_riff, self.last_tr = ri, tr
        if self.phr_riff is None:
            self.phr_riff = (ri, tr)
        self.riff, self.ri, self.tr = self.st["riffs"][ri], 0, tr
        self.speed = 0
        if rng.byte() < min(255, cfg["fast"] + max(0, self.I - 10) * 12):
            self.speed = 1
        elif rng.byte() < cfg["slow"]:
            self.speed = 2
        elif rng.byte() < cfg["trip"]:
            self.speed = 3
        elif rng.byte() < cfg["dot"]:
            self.speed = 4
        first = next((d for d, s, _ in self.riff if d is not None), 0)
        c = self.lead_chord(t)
        n0 = c.degree(first + tr, lo)
        climb = max(0, self.I - 10)             # loud: the line reaches up
        self.shift = nearest(n0, self.lead_prev + climb, lo, hi) - n0
        self.cprev = c.id

    def phrase_kind(self, t, pb):
        """a phrase: riffs (a call), voice 4's answer, or a quote of the theme"""
        rng, cfg, st = self.rng, self.cfg, self.st
        call, prev = self.last_call, self.phr_riff
        self.last_call, self.phr_riff = False, None
        self.quote, self.resp = None, False
        if self.trade or self.unit_rec is not None:
            self.last_call = True
            return
        if cfg["resp"] and call and prev is not None and rng.byte() < cfg["resp"]:
            self.resp = True
            self.rw = (t, self.p_end)
            self.ctl(t, psq.PRESET, COMP2, rng.pick(st["trade_preset"] or st["lead"]["presets"]))
            self.ctl(self.p_end, psq.PRESET, COMP2, self.inst[3])
            self.force = prev
            return
        letter = self.form["plan"][0]
        if cfg["quote"] and letter in self.head and self.head[letter] \
                and rng.byte() < cfg["quote"]:
            qb = rng.below(self.form["unit"])
            lo_t, hi_t = qb * BAR, (qb + pb) * BAR
            self.quote = [(tk - lo_t + t, dd, nn) for tk, dd, nn in self.head[letter]
                          if lo_t <= tk < hi_t]
            self.qi = 0
            if self.quote:
                lo, hi = self.lrange
                first = self.quote[0][2]
                self.qshift = nearest(first, self.lead_prev, lo, hi) - first
            return
        self.last_call = True

    def quote_note(self, t, B1, rest):
        """the next note of a quoted theme slice, re-harmonised"""
        L, rng = self.st["lead"], self.rng
        lo, hi = self.lrange
        if self.qi >= len(self.quote):
            self.lt = max(t, self.p_stop)             # quoted all: breathe
            return
        tq, dd, nn = self.quote[self.qi]
        if tq >= B1:
            self.lt = tq                              # next bar
            return
        if tq >= self.p_stop:
            self.lt = self.p_stop
            return
        self.qi += 1
        if rng.byte() >= rest:
            ch = self.chord_at(tq)
            n = nn + self.qshift
            if L["snap"] and tq % (24 if L["snap"] == 1 else TPB) == 0:
                n = snap(n, ch)
            d = min(dd, self.p_stop - tq)
            if d > 6 and not self.allowed(n, ch):
                n = snap(n, ch)
            n = nearest(n, n, lo, hi)
            d = self.fits_until(tq, d, n)
            self.lead_note(tq, d, n)
        self.lt = tq + dd
        if self.lt >= self.p_stop:
            self.cadence()
            self.lt = self.p_end

    def cadence(self):
        """the phrase's last note lands on a chord tone and rings on"""
        if len(self.lnotes) > self.ph_first and self.last[self.lnotes[-1].tr] is self.lnotes[-1]:
            nt = self.lnotes[-1]
            if any(e is nt.ev for e in self.queue):
                nt.n = nt.ev[4] = snap(nt.n, self.chord_at(nt.t))
            ring = max(nt.d, min(self.p_end - nt.t, nt.d + self.rng.pick([0, 6, 12, 24])))
            nt.d = max(nt.d, self.fits_until(nt.t, ring, nt.n))
            self.lead_prev = nt.n + (12 if nt.tr == COMP2 else 0)
        self.ph_first = len(self.lnotes)

    def head_bar(self, B0):
        """the theme: record each plan letter the first time, replay it after"""
        plan, unit = self.form["plan"], self.form["unit"]
        rel = B0 - self.sec0
        u, ub = divmod(rel // BAR, unit)
        letter = (plan * self.nbars)[u] if u < max(1, self.nbars // unit) else None
        if letter is None:
            return
        U0 = self.sec0 + u * unit * BAR
        if ub == 0:
            self.unit_letter = letter
            if letter in self.head:
                self.unit_rec = None
            else:
                self.unit_rec = []
                self.lt = self.p_end = U0
                self.riff = None
                self.last_riff, self.last_tr = None, 0
        if self.unit_rec is not None:
            self.lead_bar(B0, B0 + BAR, U0 + unit * BAR)
            if ub == unit - 1:
                self.head[letter] = [(n.t - U0, n.d, n.n) for n in self.unit_rec]
                self.unit_rec = None
        else:
            L = self.st["lead"]
            for tk, dd, nn in self.head[letter]:
                if ub * BAR <= tk < (ub + 1) * BAR:
                    t = U0 + tk
                    ch = self.chord_at(t)
                    if not self.key_chord and tk % TPB == 0:
                        nn = snap(nn, ch)
                    if dd > 6 and not self.allowed(nn, ch):
                        nn = snap(nn, ch)                 # repeated over other chords
                    dd = self.fits_until(t, dd, nn)
                    self.set_level(t, LEAD, min(15, self.dyn + (2 if t % 24 == 0 else 0)))
                    self.note(LEAD, t, dd, nn, L["gap"])
                    self.lead_prev = nn

    # -- bass ----------------------------------------------------------------------------------
    def bass_bar(self, B0, kind):
        rng, B = self.rng, self.st["bass"]
        lo, hi = B["range"]
        prev = self.bass_last if self.bass_last is not None else lo + 5
        gap = B["gap"]
        if kind == "walk":
            for beat in range(4):
                t = B0 + beat * TPB
                c = self.chord_at(t)
                nt, nc = self.next_change(t)
                root = nearest(c.degree(0, lo), prev, lo, hi)
                if beat == 0 or self.chord_at(t - TPB).id != c.id:
                    n = root if rng.byte() < prob(0.85) else nearest(c.degree(2, lo), prev, lo, hi)
                elif nt - t == TPB:
                    target = nearest(nc.degree(0, lo), prev, lo, hi)
                    n = target + rng.pick([-1, 1, -1, 1, 2, -2, -5])
                else:
                    target = nearest(nc.degree(0, lo), prev, lo, hi)
                    step = 1 if target > prev else -1
                    d = rng.pick([1, 2, 2])
                    cand = prev
                    for _ in range(d):
                        cand += step
                        while not c.smask >> (cand % 12) & 1:
                            cand += step
                    n = cand
                n = nearest(n, prev, lo, hi)
                self.note(BASS, t, TPB, n, gap)
                prev = n
        else:
            pats = B["patterns"][kind]
            if self.bpat is None:
                self.bpat = rng.pick(pats)
            if rng.byte() < B["change"]:
                self.bpat = rng.pick(pats)
            for tick, dur, code in self.bpat:
                t = B0 + tick
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
                elif code == "S":
                    n = c.degree(rng.pick([1, 2, 4, 6]), root - 1)
                else:
                    n = root + code
                self.note(BASS, t, dur, n, gap)
                prev = n
        self.bass_last = prev

    # -- comping ---------------------------------------------------------------------------------
    def comp_bar(self, B0, kind):
        rng, C = self.rng, self.st["comp"]
        lo, hi = C["range"]
        pats = C["patterns"][kind]
        if self.cpat is None:
            self.cpat = rng.pick(pats)
        if rng.byte() < C["change"]:
            self.cpat = rng.pick(pats)
        gap = C["gap"]
        for tick, dur, what in self.cpat:
            t = B0 + tick
            c = self.chord_at(t)
            tones = c.tones
            if C["voicing"] == "guide" and len(tones) >= 4:
                pair = [tones[1], tones[3]]
            elif C["voicing"] == "power":
                pair = [0, 7]
            else:
                pair = [tones[1], tones[2]]
            vs = []
            for i, iv in enumerate(pair):
                base = (c.root + iv) % 12
                ref = self.comp_last[i] if self.comp_last[i] is not None else (lo + hi) // 2 + 3 * i
                vs.append(nearest(lo + ((base - lo) % 12), ref, lo, hi))
            if vs[0] == vs[1]:
                vs[1] += 12 if vs[1] + 12 <= hi else -12
            vs.sort()
            self.comp_last = vs[:]
            if what == "arp":
                up = vs[0] + 12                           # 8-bit voice: stay low
                if up > hi:
                    up = vs[0] - 12 if vs[0] - 12 >= lo else vs[1]
                seq = [vs[0], vs[1], up, vs[1]]
                for k in range(dur // 3):
                    self.note(COMP1, t + 3 * k, 3, seq[k % 4], 1)
                continue
            self.note(COMP1, t, dur, vs[0], gap)
            if what != "1" and not (self.rw[0] <= t < self.rw[1]):
                self.set_level(t, COMP2, self.st["mix"][3] or 15)
                self.note(COMP2, t, dur, vs[1], gap)

    # -- drums ------------------------------------------------------------------------------------
    def drum_bar(self, B0, kind):
        rng, D, cfg = self.rng, self.st["drums"], self.cfg
        pats = D["patterns"][kind]
        bar = self.sbar
        if self.dpat is None:
            self.dpat = rng.pick(pats)
        if bar and bar % 4 == 0 and rng.byte() < D["change"]:
            self.dpat = rng.pick(pats)
        use = self.dpat
        last = (bar + 1) % 4 == 0 or bar == self.nbars - 1
        boost = (self.I - 10) * 6               # loud: more ghost notes and fills
        if last and D["fills"] and rng.byte() < min(255, D["fill"] + max(0, boost) * 3):
            fill = rng.pick(D["fills"])
            fd = dict(fill)
            use = [(d, s[:8] + [0] * 8) for d, s in self.dpat if d not in fd]
            use += [(d, dict(self.dpat).get(d, [0] * 16)[:8] + s[8:]) for d, s in fill]
        hits = []
        for d, s in use:
            for i, p in enumerate(s):
                if p and (p >= 256 or rng.byte() < max(1, min(254, p + boost))):
                    hits.append((i, d))
        chans = [DRUM_CH[d] for _, d in hits]
        if D["split"]:
            # a drum hit again within two 16ths goes to the other POKEY's drum
            # channel when that one is free: no choked repeats, and stereo
            busy, lastd = [0, 0], {}
            for step in range(16):
                for k, (i, d) in enumerate(hits):
                    if i != step:
                        continue
                    ch = DRUM_CH[d]
                    if d in lastd and i - lastd[d][0] <= 2 and lastd[d][1] == ch:
                        o = 1 - ch
                        if not (busy[o] >> i & 1) and not (i and busy[o] >> (i - 1) & 1):
                            ch = o
                    chans[k] = ch
                    busy[ch] |= 1 << i
                    lastd[d] = (i, ch)
        for (i, d), ch in zip(hits, chans):
            self.drum(B0 + i * 3, d, ch)
        if cfg.get("crash", True) and bar == 0:
            self.drum(B0, 7)

    # -- events out --------------------------------------------------------------------------------
    def flush(self, final=False):
        """send every event that can no longer change, in frame order"""
        for tr in range(4):
            nt = self.last[tr]
            if nt is not None and (final or nt.t + nt.d < self.tick):
                self.close(nt)
        H = self.fr(self.tick) - MAXGAP
        go = [e for e in self.queue if final or e[0] < H]
        self.queue = [e for e in self.queue if not (final or e[0] < H)]
        go.sort(key=lambda e: (e[0], e[1]))
        for f, _, op, tr, arg in go:
            assert f >= self.sent_frame, (f, self.sent_frame)
            self.sent_frame = f
            self.out.append((f, op, tr, arg))


def run(style, seconds, seed, verbose=False, random=False):
    e = Engine(style, seed, verbose, random)
    while e.sent_frame < seconds * 60:
        e.bar()
    return e


def to_psq(e, title):
    w = psq.Writer(title=title, mode=psq.STEREO, tracks=4, drums=2)
    for f, op, tr, arg in e.out:
        w.at(f, op, tr, arg)
    w.at(e.sent_frame + 1, psq.ALLOFF)
    return w


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("style")
    ap.add_argument("--seconds", type=int, default=150)
    ap.add_argument("--seed", type=int, default=1984)
    ap.add_argument("-o", "--out")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--random", action="store_true", help="later tunes pick any style")
    a = ap.parse_args()
    style = a.style.upper()
    e = run(style, a.seconds, a.seed, a.verbose, a.random)
    w = to_psq(e, f"JAM {style} {a.seed}")
    path = a.out or os.path.join(HERE, "takes", f"e_{style.lower()}_{a.seed}.psq")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    w.save(path)
    notes = sum(1 for x in e.out if x[1] == psq.NOTE_ON)
    hits = sum(1 for x in e.out if x[1] == psq.DRUM)
    print(f"{path}: {notes} notes, {hits} hits, {os.path.getsize(path)} bytes")


if __name__ == "__main__":
    main()
