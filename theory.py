"""Music theory tables for the generator: scales, chords, roman numerals.

Everything is in semitones relative to the key's tonic. Notes use the
POKEY SYNTH numbering: 0 = C1 ... 95 = B8 (psq.note_name).
"""

# scale -> semitone steps from its root
SCALES = {
    "ionian":     [0, 2, 4, 5, 7, 9, 11],
    "dorian":     [0, 2, 3, 5, 7, 9, 10],
    "phrygian":   [0, 1, 3, 5, 7, 8, 10],
    "lydian":     [0, 2, 4, 6, 7, 9, 11],
    "mixolydian": [0, 2, 4, 5, 7, 9, 10],
    "aeolian":    [0, 2, 3, 5, 7, 8, 10],
    "locrian":    [0, 1, 3, 5, 6, 8, 10],
    "harmminor":  [0, 2, 3, 5, 7, 8, 11],
    "altered":    [0, 1, 3, 4, 6, 8, 10],
    "dimhw":      [0, 1, 3, 4, 6, 7, 9, 10],
    "wholetone":  [0, 2, 4, 6, 8, 10],
    "majpent":    [0, 2, 4, 7, 9],
    "minpent":    [0, 3, 5, 7, 10],
    "blues":      [0, 3, 5, 6, 7, 10],
    "bebopdom":   [0, 2, 4, 5, 7, 9, 10, 11],
    "chromatic":  list(range(12)),
}

# chord quality -> (chord tones, default chord-scale)
CHORDS = {
    "maj":  ([0, 4, 7],      "ionian"),
    "maj7": ([0, 4, 7, 11],  "ionian"),
    "6":    ([0, 4, 7, 9],   "ionian"),
    "7":    ([0, 4, 7, 10],  "mixolydian"),
    "min":  ([0, 3, 7],      "aeolian"),
    "m7":   ([0, 3, 7, 10],  "dorian"),
    "m6":   ([0, 3, 7, 9],   "dorian"),
    "m7b5": ([0, 3, 6, 10],  "locrian"),
    "dim":  ([0, 3, 6, 9],   "dimhw"),
    "sus":  ([0, 5, 7, 10],  "mixolydian"),
    "5":    ([0, 7],         "aeolian"),
    "7alt": ([0, 4, 10],     "altered"),
    "lyd":  ([0, 4, 7, 11],  "lydian"),
}

_NUM = {"I": 0, "II": 2, "III": 4, "IV": 5, "V": 7, "VI": 9, "VII": 11}


def roman(sym):
    """'bVII7' / 'ii7' / 'Imaj7' / 'iv' / 'viio' / 'iim7b5' -> (root, quality)

    Upper case = major triad, lower case = minor. A suffix picks the
    quality: 7 (dominant on upper, m7 on lower), maj7, 6, m7b5, o (dim),
    sus, 5 (power chord), alt, lyd.
    """
    s = sym
    shift = 0
    while s and s[0] in "b#":
        shift += -1 if s[0] == "b" else 1
        s = s[1:]
    n = 0
    while n < len(s) and s[n].upper() in "IV":
        n += 1
    num, suf = s[:n], s[n:]
    root = (_NUM[num.upper()] + shift) % 12
    lower = num.islower()
    if suf == "":
        q = "min" if lower else "maj"
    elif suf == "7":
        q = "m7" if lower else "7"
    elif suf == "6":
        q = "m6" if lower else "6"
    elif suf == "o":
        q = "dim"
    else:
        q = {"maj7": "maj7", "m7b5": "m7b5", "sus": "sus", "5": "5",
             "alt": "7alt", "lyd": "lyd"}[suf]
    return root, q


class Chord:
    def __init__(self, key, sym, scale_override=None):
        r, self.quality = roman(sym)
        self.sym = sym
        self.root = (key + r) % 12                 # pitch class
        self.tones, sc = CHORDS[self.quality]
        self.scale = SCALES[scale_override.get(self.quality, sc)
                            if scale_override else sc]

    def pcs(self):
        return {(self.root + t) % 12 for t in self.tones}

    def degree(self, d, base):
        """chord-scale degree d (0 = root) -> note, root taken at/above `base`"""
        n = len(self.scale)
        octv, i = divmod(d, n)
        root = base + ((self.root - base) % 12)
        return root + 12 * octv + self.scale[i]


def nearest(n, target, lo, hi):
    """move n by octaves toward target, staying inside lo..hi"""
    while n - target > 6 and n - 12 >= lo:
        n -= 12
    while target - n > 6 and n + 12 <= hi:
        n += 12
    while n < lo:
        n += 12
    while n > hi:
        n -= 12
    return n


def snap_to_chord(n, chord, prefer_up=False):
    """nearest chord tone to note n"""
    pcs = chord.pcs()
    for d in (0, 1, -1, 2, -2, 3, -3) if not prefer_up else (0, -1, 1, -2, 2, 3, -3):
        if (n + d) % 12 in pcs:
            return n + d
    return n
