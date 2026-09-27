#!/usr/bin/env python3
"""styles.py -> jamdata.inc: the style tables the 6502 generator reads.

    python3 gen_tables.py

Everything comes from engine.compile_style, the same compiled form the
Python model runs on, so the two can't disagree about the data.

Layouts (all lists are a count byte, then the items):
  style record  STYLE_* offsets below, then words (pointers)
  scale / tones .byte n, semitones...
  form          .byte flen, unit, plen, plan letters (0..), then per bar:
                .byte nch, then per chord: (tick/12)<<4 | root, quality
                (quality = index into qt_* : tones list + chord scale)
  riff          .byte n, then per note: degree ($80 rest), (semis+1)<<6 | ticks
  section       fixed record, SEC_* offsets
  bass pattern  .byte n, then (tick, ticks, code): code < $80 = semitones
                above the root, $80+ = R 5 L 8 3 7 A S
  comp pattern  .byte n, then (tick, ticks, what): 0 both 1 lower 2 arp
  drum pattern  .byte n, then per drum: id, 8 bytes = 16 4-bit odds (0 never,
                1-9 tenths, 10 always; jam.s expands them with dodds)
"""
import os

import engine as E
import styles as S

HERE = os.path.dirname(os.path.abspath(__file__))
BCODE = {"R": 0x80, "5": 0x81, "L": 0x82, "8": 0x83, "3": 0x84, "7": 0x85, "A": 0x86, "S": 0x87}
WHAT = {"2": 0, "1": 1, "arp": 2}
VOICING = {"triad": 0, "guide": 1, "power": 2}

# style record: byte fields, then word fields
BYTES = ["beat_lo", "beat_hi", "swing", "lead_lo", "lead_hi", "lead_gap", "snap",
         "bass_lo", "bass_hi", "bass_gap", "bass_change", "comp_lo", "comp_hi",
         "comp_gap", "comp_change", "voicing", "dr_change", "dr_fill", "final_root",
         "tail", "mix0", "mix1", "mix2", "mix3", "dsplit", "hook", "hookp"]
WORDS = ["keys", "forms", "riffs", "key_scale", "lead_presets", "trade_presets",
         "bass_presets", "comp_presets", "fills", "arrangements", "final_tones", "name"]
# section record
SEC_BYTES = ["bars", "flags", "repeat", "seq", "fast", "slow", "rest", "omit",
             "energy", "quote", "resp", "trip", "dot"]
SEC_WORDS = ["phrase", "breath", "bass", "comp", "drums"]
F_LEAD, F_HEAD, F_TRADE, F_FROMEND, F_LPRESET, F_CRASH, F_WALK, F_BUILD = \
    1, 2, 4, 8, 16, 32, 64, 128


# where each style's tables live (POKEY JAM's memory: JAMDATA $5000 area,
# JAMDATA2 the old scope buffer $1C00, JAMDATA3 after the pitch tables)
SEGMENT = {"GRID": "JAMDATA2", "FUNK": "JAMDATA", "BOSSA": "JAMDATA3"}


class Asm:
    def __init__(self):
        self.quals = []         # (tones label, scale label), shared by all styles
        self.segs = {}          # segment -> its lines
        self.pool = {}          # data tuple -> label (shared lists)
        self.n = 0
        self.use("JAMDATA")

    def use(self, seg):
        """later blocks go to this segment (a block shared with an earlier
        style stays where it was first put)"""
        self.lines = self.segs.setdefault(seg, [])

    def label(self, prefix):
        self.n += 1
        return f"{prefix}{self.n}"

    def data(self, prefix, rows):
        """rows: list of ('byte'|'word', [values]); dedups identical blocks"""
        key = tuple((k, tuple(v)) for k, v in rows)
        if key in self.pool:
            return self.pool[key]
        lab = self.label(prefix)
        self.pool[key] = lab
        self.lines.append(f"{lab}:")
        for k, v in rows:
            if v:
                self.lines.append(f"        .{k} " + ",".join(str(x) for x in v))
        return lab

    def blist(self, prefix, items):
        return self.data(prefix, [("byte", [len(items)] + [x & 255 for x in items])])

    def wlist(self, prefix, labels):
        return self.data(prefix, [("byte", [len(labels)]), ("word", labels)])


def drum_rows(pat):
    """count, then per drum: id + 16 odds packed two to a byte (4-bit codes)"""
    code = {0: 0, 256: 10}
    code.update({E.prob(k / 10): k for k in range(1, 10)})
    rows = [len(pat)]
    for d, odds in pat:
        rows.append(d)
        c = [code[p] for p in odds]
        rows += [c[i] << 4 | c[i + 1] for i in range(0, 16, 2)]
    return rows


def emit_style(a, name, c):
    tones = lambda t: a.blist("tn", t)          # noqa: E731
    scale = lambda s: a.blist("sc", s)          # noqa: E731
    forms = []
    for f in c["forms"]:
        letters = sorted(set(f["plan"]))
        rows = [len(f["bars"]), f["unit"], len(f["plan"])] + [letters.index(x) for x in f["plan"]]
        body = [("byte", rows)]
        slots = sum(len(bar) for bar in f["bars"])
        assert slots <= 70, f"{name} {f['name']}: {slots} chords (max 70)"
        for bar in f["bars"]:
            body.append(("byte", [len(bar)]))
            for tick, root, tn, sc in bar:
                assert tick % 12 == 0 and tick < 48
                q = (tones(tn), scale(sc))
                if q not in a.quals:
                    a.quals.append(q)
                body.append(("byte", [(tick // 12) << 4 | root, a.quals.index(q)]))
        forms.append(a.data("form", body))
    riffs = []
    for r in c["riffs"]:
        rows = [len(r)]
        for deg, semis, dur in r:
            assert -1 <= semis <= 1 and dur < 64, (name, deg, semis, dur)
            rows += [0x80 if deg is None else deg & 255, (semis + 1) << 6 | dur]
        riffs.append(a.data("riff", [("byte", rows)]))
    L, B, C, D = c["lead"], c["bass"], c["comp"], c["drums"]

    def bass_list(kind):
        if kind is None:
            return 0
        if kind == "walk":
            return 0
        out = []
        for p in B["patterns"][kind]:
            rows = [len(p)]
            for tick, dur, code in p:
                rows += [tick, dur, BCODE[code] if isinstance(code, str) else code]
            out.append(a.data("bp", [("byte", rows)]))
        return a.wlist("bpl", out)

    def comp_list(kind):
        if kind is None:
            return 0
        out = []
        for p in C["patterns"][kind]:
            rows = [len(p)]
            for tick, dur, what in p:
                rows += [tick, dur, WHAT[what]]
            out.append(a.data("cp", [("byte", rows)]))
        return a.wlist("cpl", out)

    def drum_list(kind):
        if kind is None:
            return 0
        return a.wlist("dpl", [a.data("dp", [("byte", drum_rows(p))]) for p in D["patterns"][kind]])

    secs = {}
    for sname, s in c["sections"].items():
        flags = 0
        flags |= F_LEAD if s.get("lead") else 0
        flags |= F_HEAD if sname.startswith("head") else 0
        flags |= F_TRADE if s.get("trade") and c["trade_preset"] else 0
        flags |= F_FROMEND if s.get("from_end") else 0
        flags |= F_LPRESET if s.get("lead_preset") else 0
        flags |= F_CRASH if s.get("crash", True) else 0
        flags |= F_WALK if s.get("bass") == "walk" else 0
        flags |= F_BUILD if s["build"] else 0
        by = [s.get("bars", 0), flags] + [s.get(p, 0) for p in
                                          ("repeat", "seq", "fast", "slow", "rest", "omit",
                                           "energy", "quote", "resp", "trip", "dot")]
        wo = [a.blist("ph", s.get("phrase", L["phrase"])),
              a.blist("br", s.get("breath", L["breath"])),
              bass_list(s.get("bass")), comp_list(s.get("comp")), drum_list(s.get("drums"))]
        secs[sname] = a.data("sec", [("byte", by), ("word", wo)])
    arrs = [a.wlist("arr", [secs[x] for x in arr]) for arr in c["arrangements"]]
    fills = [a.data("dp", [("byte", drum_rows(f))]) for f in D["fills"]]
    fr, ft = c["final"]
    bytes_ = dict(beat_lo=c["beat"][0], beat_hi=c["beat"][1], swing=c["swing"],
                  lead_lo=L["range"][0], lead_hi=L["range"][1], lead_gap=L["gap"],
                  snap=L["snap"], bass_lo=B["range"][0], bass_hi=B["range"][1],
                  bass_gap=B["gap"], bass_change=B["change"], comp_lo=C["range"][0],
                  comp_hi=C["range"][1], comp_gap=C["gap"], comp_change=C["change"],
                  voicing=VOICING[C["voicing"]], dr_change=D["change"], dr_fill=D["fill"],
                  final_root=fr, tail=c["tail"], mix0=c["mix"][0], mix1=c["mix"][1],
                  mix2=c["mix"][2], mix3=c["mix"][3], dsplit=int(D["split"]),
                  hook=255 if L["hook"] is None else L["hook"], hookp=L["hookp"])
    title = name.ljust(16)[:16]
    words = dict(keys=a.blist("key", c["keys"]), forms=a.wlist("fl", forms),
                 riffs=a.wlist("rl", riffs),
                 key_scale=scale(L["key_scale"]) if L["key_scale"] else 0,
                 lead_presets=a.blist("pr", L["presets"]),
                 trade_presets=a.blist("pr", c["trade_preset"]),
                 bass_presets=a.blist("pr", B["presets"]),
                 comp_presets=a.blist("pr", C["presets"]),
                 fills=a.wlist("fil", fills), arrangements=a.wlist("arl", arrs),
                 final_tones=tones(ft),
                 name=a.data("nm", [("byte", [ord(ch) - 32 for ch in title])]))
    a.lines.append(f"STY_{name.replace(' ', '_')}:")
    a.lines.append("        .byte " + ",".join(str(bytes_[k]) for k in BYTES))
    a.lines.append("        .word " + ",".join(str(words[k]) for k in WORDS))


def main():
    a = Asm()
    names = list(S.STYLES)
    for n in names:
        a.use(SEGMENT.get(n, "JAMDATA"))
        emit_style(a, n, E.compile_style(S.STYLES[n]))
    head = ["; generated by gen_tables.py from styles.py -- do not edit", ""]
    for i, k in enumerate(BYTES):
        head.append(f"ST_{k.upper():12s} = {i}")
    for i, k in enumerate(WORDS):
        head.append(f"ST_{k.upper():12s} = {len(BYTES) + 2 * i}")
    for i, k in enumerate(SEC_BYTES):
        head.append(f"SE_{k.upper():12s} = {i}")
    for i, k in enumerate(SEC_WORDS):
        head.append(f"SE_{k.upper():12s} = {len(SEC_BYTES) + 2 * i}")
    for k, v in dict(F_LEAD=F_LEAD, F_HEAD=F_HEAD, F_TRADE=F_TRADE, F_FROMEND=F_FROMEND,
                     F_LPRESET=F_LPRESET, F_CRASH=F_CRASH, F_WALK=F_WALK,
                     F_BUILD=F_BUILD).items():
        head.append(f"{k:15s} = {v}")
    head.append(f"NSTYLES         = {len(names)}")
    head += ["", "styles:     .word " + ",".join(f"STY_{n.replace(' ', '_')}" for n in names), ""]
    for nm, k in (("qt_tlo", 0), ("qt_thi", 0), ("qt_slo", 1), ("qt_shi", 1)):
        op = ".lobytes" if nm.endswith("lo") else ".hibytes"
        head.append(f"{nm}: {op} " + ",".join(q[k] for q in a.quals))
    head.append("")
    body = []
    for seg, lines in a.segs.items():
        body += ["", f'.segment "{seg}"'] + lines
    body += ["", '.segment "JAMDATA"']
    out = "\n".join(head + body) + "\n"
    open(os.path.join(HERE, "jamdata.inc"), "w").write(out)
    print(f"jamdata.inc: {len(names)} styles, {len(a.lines)} lines")


if __name__ == "__main__":
    main()
