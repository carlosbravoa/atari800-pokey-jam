# Ballblazer (Atari 8-bit, 64 KB XEGS cart): the "riffology" music generator, reverse-engineered

Source: `../Ballblazer.rom` (65536 bytes). Everything below comes from reading the 6502 code and
from running the cartridge's own driver in py65 (`emulate.py`).

- **[V]** = VERIFIED: read in the code, and/or seen in emulation of the real routine.
- **[I]** = INFERRED: interpretation (musical analysis, game-state meaning, acoustics).

Files in this directory:

| file | what |
|---|---|
| `dis6502.py` | small recursive-descent disassembler (`python3 dis6502.py BIN BASE ENTRY,...`) |
| `bank_*.bin` | raw 8 KB banks (file offset in name) |
| `game_4000.bin` / `game_4000.s` | game RAM/cart image `$4000-$BFFF` (banks 4,5,6,7) and its disassembly |
| `music_driver_7584.s` | only the sound/music driver part (`$7584-$7F8E`) |
| `bank0_6000.s` | bank 0 = the Lucasfilm intro program (run from the cart INIT vector) |
| `extract.py` → `tables.txt` | dumps every music table as notes |
| `emulate.py` | runs the real driver frame by frame and logs phrases, riffs, tempo, loudness and note-ons |
| `sample_log_180s_seed1.txt`, `sample_log_60s_demo_seed7.txt` | sample output |

---------------------------------------------------------------------------------------------

## 1. Cartridge / memory map  [V]

A 64 KB XEGS-style cart: eight 8 KB banks, bank = file offset / 0x2000. Banks 1-3 (file
0x2000-0x7FFF) are all `$FF`. The last bank (file 0xE000) is fixed at `$A000-$BFFF`. A write to
`$D500` selects the bank that shows at `$8000-$9FFF`. The only `STA $D500` writes are in the fixed bank
(`$BC20-$BC75`).

Trailer (`$BFFA`): RUN=`$BC33`, flags `$00`, opts `$04`, INIT=`$BC20`. `$BFF9` holds a real
`JMP $BC33`, which the intro uses as its exit.

Boot sequence:
1. **INIT `$BC20`**: selects bank 0, copies it to RAM `$6000-$7FFF` (copy loop `$BC77`), then runs
   `JMP $7FFD` → `JMP $6B26`. That is the **Lucasfilm Games logo / intro animation**, not the music
   generator. It has its own VBI at `$6B70`, a 16-step drum machine on ch1 (`$6B9E`, the same drum
   tables as the game, see §7), SFX on ch2, and a 16-bit ch3+4 sweep. A console key or the end of
   the intro jumps to `$BFF9`.
2. **RUN `$BC33`**: selects bank 4 and copies it to RAM `$4000-$5FFF`, then bank 5 to RAM
   `$6000-$7FFF`, then selects bank 6 (permanent, at `$8000-$9FFF`) and runs `JMP $4C00` (game main).

So the running game is a flat image: `$4000-$7FFF` RAM (banks 4+5), `$8000-$9FFF` bank 6, and
`$A000-$BFFF` bank 7.

**The music generator lives in bank 5, i.e. RAM `$7584-$7F8E` (file 0xB584-0xBF8E).**
`RAM addr = file offset - 0xA000 + 0x6000` for this bank.

Hooks:
- `$4C00` main: `JSR $7A0D` (music init) at `$4C3D`. The immediate VBI vector goes to `$4C8D`, then
  to `$4CAB`. That calls the per-frame game VBI `$4CBE`, which ends with **`JSR $7682` at `$4E12`, once
  per frame (60 Hz)**. `$7682` is the whole sound system: music sequencer, riff lead, drum machine,
  SFX mixer and the POKEY register write-out at `$79B4`.
- `$7A0D` is called again at `$4D77` / `$4EFE` (back to menu). `JMP $764A` at `$4F38` turns the lead
  off when a match starts (`$14D6=0`). `$75A5` (from `$4E58`, `$5011`) plays the end cadence
  `$7DF3` with fade-out. `$7584`, `$758F` and `$759A` start the jingles.
- `AUDCTL` is written only at `$7A19` (value 0): **64 kHz clock, four independent 8-bit channels.**
  NTSC pure tone f = 63921 / (2·(AUDF+1)).
- `RANDOM $D20A` in the music code: `$7792` (note omission), `$77B2` (riff choice), `$7812/$781A`
  (drums), `$7AA4/$7AA9/$7AB7` (phrase choice).

## 2. Driver architecture  [V]

Every frame, `$7682` does the following:
1. It clears the channel "claim" shadows `$F1,$F2,$F4,$F5,$F7,$F8,$FA,$FB` (AUDC and volume per channel).
2. **Sequencer** (`$7694-$7760`): plays the accompaniment phrase at `($D9)`. It has 3 voices, each
   bound to a channel: v1→ch1, v2→ch2, v3→ch3.
3. **Lead riff player** (`$7761-$77B8`): steps the riff note every `$14D6` frames.
4. Player-specific SFX (`$77BB-$77E6`) and the **drum machine** (`$77E9-$7839`). The drums only reach
   ch4 when `$A1` bit 7 is set and the sequencer is idle (`$13DD<0`), i.e. in-game and not on the title.
5. SFX sources (`$785A-$7964`), then the **lead** (`$7967`, ch4) and its **echo** (`$7982`, ch3).
6. Write-out of `$F9/$FA`→ch1, `$F6/$F7`→ch2, `$F3/$F4`→ch3 and `$F0/$F1`→ch4 (`$79B4`).

Each source claims a channel only if its volume ≥ the volume already claimed this frame
(`CMP $Fx / BCC skip`). That is a **loudest-wins priority mixer**, which lets SFX, drums and music
share 4 voices without explicit allocation.

### Key variables  [V]
| addr | meaning |
|---|---|
| `$D9/$DA` | phrase pointer. `$13DD` = byte index in the phrase (`$FF` = idle). `$13DE` = frames left in the current record |
| `$13DB/$13DC` | phrase-end callback (`$7A4F` for the song, `$77BB` = stop, used for jingles) |
| `$13DF/$13E0/$13E1` | v1 AUDF / AUDF slide per frame / AUDC (only v1 slides) |
| `$13E2,$13E4` / `$13E5,$13E7` | v2 / v3 AUDF, AUDC |
| `$14D6` | lead tempo = frames per riff note (0 = lead off). `$14DC` = countdown |
| `$14DD` | lead position = riff·8 + note (0..255) |
| `$14E0` / `$14E1` | lead AUDF / echo AUDF (= the previous step's lead note) |
| `$14DE` / `$14DF` | lead / echo envelope counters (volume = counter>>2, −1 per frame) |
| `$14D7` | lead loudness (envelope start value, 0..32). `$14D8` = echo loudness |
| `$14D9` | loudness target (0..32). `$14DA` = sawtooth that drives it |
| `$14DB` | "ramp every note" flag (demo mode / fade-out) |
| `$14E2` | index into the tempo list. `$14E3` = phrase-run counter (negative = inside a run) |
| `$14D0/$14D1/$14D2` | drum step timer (6 frames) / step 0..15 / random-substitution mask `$15` |
| `$D6/$D7/$D8` | drum volume counter / AUDC distortion / AUDF |

## 3. Data tables  [V]  (full dump in `tables.txt`)

| RAM | file | contents |
|---|---|---|
| `$7B27`,`$7B2E`,`$7B35` | 0xBB27.. | drum sounds 0-6: length/start volume, AUDF, distortion |
| `$7B3C`,`$7B4C`,`$7B5C` | 0xBB3C.. | three 16-step drum patterns (drum ids) |
| `$7B6C` | 0xBB6C | **lead tempo list**, 0-terminated: `6 4 6 9 6 3 6 12` frames/note |
| `$7B75` | 0xBB75 | **32 riffs × 8 notes**, raw AUDF bytes (pure tone), `00` = rest |
| `$7C75`,`$7C99`,`$7CC7`,`$7CF6` | | accompaniment phrases **A, B, C, D** (2 bars = 192 frames each) |
| `$7D40` | | phrase **HOME** (4 bars = 384 frames) |
| `$7DF3` | | END cadence (HOME bars 1, 2, 4 plus a noise sweep), used by `$75A5` |
| `$7E50`,`$7E6D`,`$7E9E` | | game jingles (fixed, non-generative) |
| `$7EBA` | 0xBEBA | **instrument/note table**, 67 × (AUDF, slide, AUDC) |

**Riff note encoding**: one byte = the literal AUDF value. There is no scale-degree indirection and
no transposition. The lead always uses AUDC `$A0|vol` (pure tone).

**Phrase encoding** (`$76A4-$772D`): a phrase is a list of records `dur, n1, [n2, [n3]]`.
- `dur` is in frames; `dur = 0` ends the phrase and calls the callback.
- Each `n` is an index into `$7EBA`. The first byte ≥ `$80` (always `$FF`) ends the record early,
  and the remaining voices are silent (AUDC=0).
- So `dur, $FF` is a rest, and 3 notes need no terminator.
- Voices are gated organ tones: they keep constant AUDC (volume) for the whole `dur`, with no decay.
  Decays are written out explicitly as notes with lower volume (e.g. `#38→#37→#36` = the same E
  bass at volume 8, 6, 4).
- The 16-bit index `$13DD` is rebased into `$D9/$DA` when it passes 127.

**Instrument table**: the AUDC high nibble selects the timbre:
- `$A` = pure tone (chords, stabs)
- `$C` = 4-bit-poly buzz (all bass notes)
- `$8` = noise (hi-hat/snare hits embedded in the phrases)

Only instruments `#01` (noise, slide −3), `#28` (+16) and `#2F` (+4) use the per-frame AUDF slide,
and only in jingles.

### Riffs (AUDF → pitch at 63921/(2(N+1)) Hz; every pitch is ≈+10..+30 cents sharp, i.e. the tune is in G#)
```
 0 98 7F 71 6B 5A 50 4B 3F  G#3 B3  C#4 D4  F4  G4  G#4 B4
 1 98 7F 65 54 4B 3F 32 2A  G#3 B3  D#4 F#4 G#4 B4  D#5 F#5
 2 4B 43 3F 38 35 32 35 3F  G#4 A#4 B4  C#5 D5  D#5 D5  B4
 3 4B 47 43 3F 3B 38 35 32  G#4 A4  A#4 B4  C5  C#5 D5  D#5
 4 4B 47 43 3F 32 35 38 3F  G#4 A4  A#4 B4  D#5 D5  C#5 B4
 5 4B 3F 32 25 2A 35 3F 54  G#4 B4  D#5 G#5 F#5 D5  B4  F#4
 6 4B 3F 32 2A 21 25 32 32  G#4 B4  D#5 F#5 A#5 G#5 D#5 D#5
 7 4B 3F 35 43 38 2F 35 3F  G#4 B4  D5  A#4 C#5 E5  D5  B4
 8 25 32 3F 4B 2A 35 3F 4B  G#5 D#5 B4  G#4 F#5 D5  B4  G#4
 9 50 4B 00 2A 00 35 00 3F  G4  G#4 --  F#5 --  D5  --  B4
10 50 4B 43 3F 35 32 27 25  G4  G#4 A#4 B4  D5  D#5 G5  G#5
11 43 4B 43 3F 43 4B 43 3F  A#4 G#4 A#4 B4  A#4 G#4 A#4 B4   <- phrase-opener riff
12 43 4B 43 3F 38 3F 38 35  A#4 G#4 A#4 B4  C#5 B4  C#5 D5
13 38 32 2A 32 3F 3F 38 25  C#5 D#5 F#5 D#5 B4  B4  C#5 G#5
14 21 1F 25 32 2A 21 25 25  A#5 B5  G#5 D#5 F#5 A#5 G#5 G#5
15 3F 50 4B 2A 2F 2C 35 32  B4  G4  G#4 F#5 E5  F5  D5  D#5
16 3F 38 3F 43 3F 43 4B 4B  B4  C#5 B4  A#4 B4  A#4 G#4 G#4
17 1F 21 25 2A 2C 32 35 3F  B5  A#5 G#5 F#5 F5  D#5 D5  B4
18 71 6B 54 6B 71 7F 87 7F  C#4 D4  F#4 D4  C#4 B3  A#3 B3
19 38 3F 4B 3F 32 35 38 3F  C#5 B4  G#4 B4  D#5 D5  C#5 B4
20 38 3F 38 35 38 3F 38 35  C#5 B4  C#5 D5  C#5 B4  C#5 D5
21 38 32 2A 32 3F 3F 38 25  C#5 D#5 F#5 D#5 B4  B4  C#5 G#5   (== riff 13)
22 38 35 25 38 38 3F 3F 32  C#5 D5  G#5 C#5 C#5 B4  B4  D#5
23 71 6B 54 5F 6B 43 50 5F  C#4 D4  F#4 E4  D4  A#4 G4  E4
24 35 32 4B 43 3F 50 4B 4B  D5  D#5 G#4 A#4 B4  G4  G#4 G#4
25 35 32 38 3F 43 4B 50 4B  D5  D#5 C#5 B4  A#4 G#4 G4  G#4
26 35 35 25 38 38 3F 4B 4B  D5  D5  G#5 C#5 C#5 B4  G#4 G#4
27 32 4B 3F 50 43 54 5A 65  D#5 G#4 B4  G4  A#4 F#4 F4  D#4
28 5F 4B 35 38 65 54 3F 4B  E4  G#4 D5  C#5 D#4 F#4 B4  G#4
29 2A 32 38 43 35 3F 4B 4B  F#5 D#5 C#5 A#4 D5  B4  G#4 G#4
30 2A 32 38 2C 3F 3F 4B 4B  F#5 D#5 C#5 F5  B4  B4  G#4 G#4
31 2C 32 2C 2A 2C 32 2C 2A  F5  D#5 F5  F#5 F5  D#5 F5  F#5
```
[I] Almost every riff is in the **G# blues scale** (G# B C# D D# F#). A#, A, G, E and F appear as
passing or neighbour tones. Many riffs start and end on a G#-minor chord tone (G#, B, D#), and many
end on a repeated G#. Riffs 13 and 21 are identical, so there are 31 distinct riffs.

## 4. The generative algorithm — pseudocode  [V]

```
INIT ($7A0D):
  AUDCTL=0; loud=0 ($14D7); echoLoud=0; target=0 ($14D9); saw=0 ($14DA); rampEveryNote=0
  run=0 ($14E3); tempoIdx=$FF; drumStep=$FF; drumTimer=1
  if demoFlag($B8): target=saw=rampEveryNote=$20         ; attract mode starts loud at once
  tempo ($14D6) = TEMPOS[0] (=6); drumRandMask=$15
  start_phrase(HOME)

start_phrase(p):  ($7B04)
  seqPtr=p; seqIdx=0; seqCountdown=1; callback=$7A4F
  leadEnv=0; leadCountdown=1; leadPos = 11*8          ; every phrase restarts the lead on riff 11

EVERY FRAME ($7682):
  clear channel claims
  -- accompaniment sequencer --
  if seqIdx>=0 and --seqCountdown==0:
     rec = next record; if rec.dur==0: seqIdx=$FF; jmp callback  (song: PHRASE_END, then continue)
     seqCountdown=rec.dur; v1..v3 = INSTR[n] or silent
  v1.audf += v1.slide; claim ch1/ch2/ch3 with v1/v2/v3 (volume = AUDC&15)
  -- lead --
  if tempo != 0 and --leadCountdown==0:
     if rampEveryNote: loudness_step()
     leadCountdown = tempo
     echoNote = leadNote                               ; echo = previous step's note
     p = (leadPos & 3)==0 ? 0 : 16                     ; strong beats almost never skipped
     if p < RANDOM:                                    ; else OMIT: the old note keeps decaying
        leadNote = RIFFS[leadPos]; leadEnv = loud; echoEnv = echoLoud
     leadPos++
     if (leadPos & 7)==0:                              ; end of riff
        loudness_step()
        leadPos = RANDOM & $F8                         ; uniform random riff 0..31, no constraints
  drums (in-game only, §7); SFX
  if leadEnv:  v=leadEnv; leadEnv--; if leadNote: claim ch4 with (leadNote, $A0 | v>>2)
  if echoEnv:  if echoNote: claim ch3 with (echoNote, $A0 | echoEnv>>2); echoEnv--
  write shadows to AUDF1-4/AUDC1-4

loudness_step() ($79DD):             ; moves loud one unit toward target
  if loud==target: rampEveryNote=0
  elif loud<target: echoLoud = loud/2 + 1; loud++
  elif run>=0 (not inside a phrase run):  echoLoud=min(echoLoud,loud); loud--

PHRASE_END callback ($7A4F):
  if target==0:
     if loud!=0:                                       ; still fading out
        if run<0: goto CONTINUE_RUN else start_phrase(HOME); return
     tempoIdx = next in TEMPOS (wrap at 0)             ; lead silent -> new tempo
     tempo = TEMPOS[tempoIdx]
  saw += 6; if saw>=64: saw=0
  target = min(saw, 32)                                ; 6,12,18,24,30,32,32,32,32,32,0,...
  if run<0: goto CONTINUE_RUN
  A = 2*loud + 16                                      ; 16..80
  if A < RANDOM: start_phrase(HOME); return            ; P(leave HOME) = (A+1)/256 = 6.6%..32%
  run = (A < RANDOM) ? -2 : -4                         ; P(4-phrase run) = (A+1)/256
CONTINUE_RUN:
  run++
  r = RANDOM & 7; if run>=0 (last phrase of the run): r += 4
  start_phrase( r<3 ? A : r<6 ? B : r<9 ? C : D )
```

Derived facts [V, from code and confirmed in the emulation log]:
- **Riff choice**: uniform over 32 at each riff boundary (`RANDOM & $F8`). There is no memory of the
  previous riff and no dependence on the chord. The first riff of every phrase is forced to riff 11
  (a recognisable hook).
- **Note omission**: on notes 0 and 4 of a riff, P = 1/256. On the other six notes,
  P = 17/256 ≈ 6.6%. An omitted note isn't replaced by silence: the previous pitch keeps ringing on
  its decaying envelope. Riff 9 contains written rests (`00`).
- **Lead envelope**: pluck/decay. The volume starts at `loud>>2` (max 8) and drops by 1 every 4
  frames, so a note at full loudness lasts 32 frames (~0.53 s) if not retriggered. Staccato comes
  from the tempo, not from gating.
- **Echo**: ch3 replays the lead delayed by one step, at about half loudness. Musically this is a
  canon at one 16th. It is heard only when ch3's accompaniment voice is quieter.
- **Speed**: the tempo is fixed for a whole "swell" (see below) and cycles through `6 4 6 9 6 3 6 12`
  frames per note. The accompaniment is always 6 frames per 16th (150 BPM). So the lead is:
  - 6: in 16ths, in sync
  - 3: in 32nds
  - 12: in 8ths
  - 4: sextuplet feel (3 lead notes per 2 sixteenths)
  - 9: dotted-16th polyrhythm (2 against 3)
- **Dynamics ("swell")**: `target` follows a sawtooth over phrases (+6 per phrase, capped at 32,
  dropping to 0 after 10 phrases). `loud` chases it at only ±1 per riff. The lead therefore fades in
  over ~1 min, sits at full level, then fades out completely. Only then does the tempo change. At
  tempo 6 a full cycle is ≈ 89 s (log: fade-in from 0 s, fade-out 64-89 s, tempo 4 from 89.6 s,
  back to 6 at 166 s).
- **Form**: the rhythm section alternates **HOME** (4 bars) with occasional runs of the 2-bar
  **variation phrases**. Runs get likelier as the lead gets louder: 6.6% when quiet, 32% at full.
  - A run is 2 phrases, or 4 with probability (A+1)/256.
  - Non-final phrases of a run are A 3/8, B 3/8, C 2/8.
  - The final phrase ("turnaround") is B 2/8, C 3/8, D 3/8.
  - During a run the lead never gets quieter. While the lead fades out, only HOME plays.

## 5. Harmony, bass, drums, channels  [V for data, I for musical reading]

Channels (music mode):

| channel | role |
|---|---|
| ch1 | v1: the bass (poly4 "C" distortion) and some noise hits |
| ch2 | v2: chord tones (pure) and noise hits |
| ch3 | v3: third chord tone or noise hit; otherwise the lead echo |
| ch4 | the riff lead |

**Bass pitch with distortion `$C` [I, acoustics]**: POKEY's 4-bit poly (period 15) is sampled every
(N+1) 64 kHz ticks. So the waveform period is 15/gcd(N+1, 15) samples, and the pitch is
f = 63921 / ((N+1)·15/gcd(N+1,15)).
- Example: `$51` → G#1 (52 Hz). `$A1` (N+1=162, divisible by 3) → period 5 → D#2.
- Treat these assignments as good hypotheses to confirm by ear. They give a coherent root–fifth
  G# minor bass line.

**HOME** (16th = 6 frames, bar = 96 frames). Beats are in 8ths.
```
bar1: G#1 . D#2 . [F#3+B3+snare] . G#1 . . . D#2 . [E2 + noise] . [B2 + G#3] .      (G#m)
bar2: same but ends [C#2 + noise] . B1                                          (G#m, walk down)
bar3: = bar1
bar4: [C#2+G#3+F4] held | [B1+F#3+D#4] held | E1+B2+E4, E1+B2+D4 | E1+G#3+B3 decaying 8→6→4
      = C# major (IV) → B major (III) → E – E7 (VI) → back to G#m                     (G# dorian)
```
The variation phrases are 2 bars each:
- A: sparse, with G#1 and hat/snare. The turnaround is D#2+F#3 then C#2+F#3+A#3.
- B: adds B1+F#3+D#4 (B major) and G#1+D#3+B3. Ends on D#2 + A#4/F#3.
- C: sparse, ending on a walking bass F#2-F#2-E2-C#2-A#1.
- D: a busy chromatic walking bass: G#1 G#1 G#1 A1 A#1 A#1 B1 A#1 A1 | G#1 D#2 F1 F1 F2 F2 F#1 F#2 A#1 A#1 G2.

"Drums" in the song are the noise instruments `#00` (`$8A`, AUDF `$0A`) and `#02` (AUDF `$03`).
They are written into the phrases on beat 2, beat 4 and similar positions. They're not generated.

[I] The key insight is that harmony and melody are decoupled by construction. The accompaniment is
a fixed, looping, bluesy groove, and all 32 riffs live in one blues scale (G# blues), mostly starting
and ending on tonic-chord tones. So any riff over any bar "fits", and no chord-aware selection is
needed. The chords used (G#m, C#, B, E) are all diatonic to G# dorian, which the blues scale sits on.

## 6. Structure above riffs; title vs in-game  [V]
- Hierarchy:
  - note: `tempo` frames
  - riff: 8 notes; random, except riff 11 opens each phrase
  - phrase: HOME = 384 frames, A-D = 192 frames
  - run: 2 or 4 variation phrases
  - swell cycle: fade in, hold, fade out, next tempo; about 1-1.5 min
  - tempo list: 8 cycles, ≈ 12 min before the tempo sequence repeats
- There is no "ending" in the generative song. `$75A5` (called when a match ends / on the result
  screen [I]) swaps in the fixed END cadence `$7DF3` with callback "stop". It also sets
  target=0 and rampEveryNote=1, so the lead fades out one step per note.
- **Song of the Grid** is this generator running with `$A1=1` (title/menu). In a match, `$764A`
  zeroes the lead tempo, and the sequencer only plays jingles. The **in-game rhythm** is the drum
  machine below (§7), audible only when `$A1` bit 7 is set and no jingle is playing.
- Demo/attract flag `$B8≠0` at init: the lead starts at full loudness, ramping every note instead of
  every riff (`emulate.py --demo`).

## 7. The drum machine (in-game `$77E9`; also in the intro `$6B9E`)  [V]
- 16 steps × 6 frames.
- Each step takes a drum id from pattern `$7B3C`, overridden by `$7B4C` if `$0D==0` and by `$7B5C`
  if `$21==0` ([I] per-player state). The intro picks between the three patterns at random, 50/50
  twice.
- With P = 1/8 (`RANDOM & $15 == 0`), a random value 0-15 replaces the step:
  - 0-6: that drum instead (0 = silence)
  - 7-15: the scheduled drum, accented (+3 length/volume)
- A drum is a noise burst: volume counter starts at `len` and drops by 1 per frame. AUDC = `dist|vol`
  on ch4.
- Drum sounds (len, AUDF, dist):
  - 1 = (4, `$FF`, noise): low thump
  - 2 = (3, 2, `$40`)
  - 3 = (6, 3, noise): snare
  - 4 = (5, 2, noise)
  - 5 = (3, 4, noise): hat
  - 6 = (3, `$0A`, noise)
- Patterns:
  - `$7B3C` = `3 5 4 5 4 4 5 5 4 5 4 5 4 4 5 5`
  - `$7B4C` = `1 5 2 6 5 4 4 5 2 4 5 2 4 5 6 4`
  - `$7B5C` = `1 5 6 5 6 4 6 5 4 5 6 5 6 4 6 6`

## 8. Worth copying for a new 6502 generator [I]
1. **Scale-safe riff bank + fixed groove**: guarantees consonance with zero harmonic logic. For
   other styles, swap in a riff bank per scale (one per mode/key) and a groove per style. The
   selection code stays identical.
2. **Signature riff at phrase start** (riff 11): gives identity and "the tune" feeling amid randomness.
3. **Weighted omission by metric position** (strong beats kept, weak beats dropped 6.6%): rhythmic
   variety that never loses the pulse. Omission = sustain, not silence.
4. **Tempo as a per-section multiplier** against a fixed-tempo band (16th, 8th, 32nd, 2:3, 3:2):
   huge variety from one table of 8 bytes. Change tempo only when the lead is silent.
5. **Slow loudness chase** (±1 per riff toward a sawtooth target): long-form dynamics, fade-ins and
   fade-outs for free. Also couple the form to it: the louder the lead, the likelier a departure from
   HOME. Energy and harmonic motion rise together.
6. **Runs with a forced turnaround**: the last phrase of a run is biased to cadential phrases (+4 on
   the random index).
7. **One-step echo on a spare channel**: a cheap canon/thickening.
8. **Loudest-wins channel mixer**: SFX, drums, music and echo share 4 voices with no allocator.
9. Envelopes as data (repeated notes at decreasing AUDC) keep the sequencer trivial.

Cost: the music-relevant code (sequencer + lead + loudness + phrase callback + init) is about 0.6 KB of the 1.4 KB sound driver `$7584-$7B26`. The data is
256 B of riffs, 8 B of tempos, about 450 B of phrases and 201 B of instruments.

## 9. Verification notes
- `emulate.py` loads banks 4-7 at `$4000-$BFFF` and calls `$7A0D` once, then `$7682` once per frame,
  with `$A1=1`. RANDOM is a seeded Python PRNG.
- The logs show the exact behaviour described in §4:
  - HOME at frame 0 with lead loudness 0
  - loudness +6 per HOME phrase, capped by the target sequence 6, 12, 18, ...
  - runs `B→C`, `A→C` and `C,A,B,C` with run counters `FF`, `FD`, `FE`
  - fade-out 32→24→16→8→0 over HOME phrases, then `TEMPO 4`, later `TEMPO 6`
  - riff 11 at every phrase start
- Not checked on real hardware: the cart is a 64 KB banked image that the PC-link RAM injection
  can't run as-is. Bass pitch names for distortion `$C` are an acoustic model, not a measurement.
