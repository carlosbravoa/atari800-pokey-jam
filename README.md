# POKEY JAM

Endless generated music for the Atari 8-bit. The 6502 composes the music
bar by bar while it plays, so it never repeats, needs no disk and never
ends. The screen is POKEY PLAYER's panel: voice meters with peak hold, the
notes and instruments each voice plays, and percussion LEDs.

It is inspired by Peter Langston's "riffology" generator in Lucasfilm's
*Ballblazer* (1984). A lead line is assembled from short riffs over chord
forms, with a bass, comping chords and drums generated alongside. POKEY JAM
has ten styles:

| Style | Sound |
|---|---|
| JAZZ | swing, walking bass, standards-style forms |
| BLUES | 12-bar shuffle, boogie bass, blues-scale licks |
| TECHNO | four on the floor, offbeat bass, 16th arpeggios, breakdowns |
| AMBIENT | slow pads, bells, long tones, no hurry |
| CHIP | 8-bit action: fast arps, octave bass, driving beat |
| ROCK | power chords, eighth-note drive, pentatonic leads |
| HIP HOP | boom-bap beat, deep bass, jazzy keys, a laid-back hook |
| GRID | a tribute to Ballblazer's Song of the Grid: its riffs over a G#-minor groove |
| FUNK | sixteenth-note grooves, slap bass, clavinet chops, one-chord vamps |
| BOSSA | clave-like guitar, root-fifth bass, soft lyrical lines |

## Run it

Download `POKEY-JAM.xex` from the [releases](../../releases) and load it
as a binary file with no DOS in memory:

- In an emulator ([Altirra](https://www.virtualdub.org/altirra.html) or
  [atari800](https://atari800.github.io/)): boot the file directly. Pick an
  NTSC 800XL or 130XE with 64 KB.
- On a real Atari: use your SD drive's or FujiNet's own `.xex` loader.

It runs on one POKEY. With a second POKEY (a stereo upgrade, or the stereo
option in the emulator) the parts spread over both chips.

## Keys

| Key | Does |
|---|---|
| `<` `>` | previous / next style |
| `RETURN` | a new tune in the current style |
| `R` | RANDOM on/off: each new tune picks its own style (`RANDOM` shows inverse while on) |
| `1`-`6` | mute / unmute a panel column: LEAD, LAYER/VOICE, DRUM, BASS, HARM, DRUM2 |
| `L` or `TAB` | the style list |
| `SPACE` | pause / resume |
| `ESC` | stop |

**Tip: for background music, press `1` to mute the lead, then `R` for
RANDOM, and leave it running.** The backing keeps going on its own and moves
from style to style, one tune at a time.

## Build from source

POKEY JAM is the composer (`jam.s`) running inside POKEY PLAYER's front end
and sound engine, so it builds against the
[POKEY SYNTH repo](https://github.com/carlosbravoa/atari800-pokey-synth)
checked out next to this one, as `../synth`.

You need [cc65](https://cc65.github.io/) (`ca65` and `ld65`), GNU make and
Python 3 with `py65`.

```bash
make                        # build/jam.xex (cc65 in ~/.local/bin, or: make CA65=ca65 LD65=ld65)
python3 test_jam.py         # the 6502 composer vs the Python model, byte for byte
python3 test_jamplayer.py   # the composer and the player together, no starved frames
```

- `styles.py` defines the styles: riffs, chord forms, bass, comping and
  drum patterns. `gen_tables.py` compiles them into `jamdata.inc`.
- `engine.py` is the reference composer in Python. `jam.s` matches it byte
  for byte, which the tests check.
- `gen.py STYLE` writes a take as a POKEY SYNTH `.psq` (like the files in
  `takes/`). `listen.py` plays one in the real player, over the Tang Nano
  20K board's PC link.

## The Ballblazer research

`re/BALLBLAZER_MUSIC.md` describes how Ballblazer's music driver works,
from reading its 6502 code and running it in an emulator. The tools in
`re/` (`extract.py`, `emulate.py`, `dis6502.py`) need your own dump of the
cartridge as `Ballblazer.rom`. The ROM and its disassembly are not included.
