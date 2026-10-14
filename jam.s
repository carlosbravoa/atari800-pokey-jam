; ---------------------------------------------------------------------------
; POKEY JAM generator: endless procedural music, composed live, bar by bar.
;
; A line-for-line port of engine.py (the reference model): the same RNG,
; the same decisions in the same order, the same event stream. test_jam.py
; runs this in py65 and compares its output with engine.py byte for byte.
;
; Interface (main thread only; nothing here runs in the VBI):
;   jam_init   A = style, JSEED = seed    start a fresh performance
;   jam_bar                               compose one bar, send what's final
; The composer calls jam_yield (the caller's, registers kept) at safe points
; -- every note, drum hit and sort pass -- so a front-end can keep its screen
; moving while a busy bar is composed.
; Output: .psq body bytes (delta, op<<4|track, arg) written through JWP into
; the ring JRING..JRING+JRINGSZ-1 (wraps). The caller keeps it drained.
;
; Notes are carried biased by 72 (BIAS) so intermediate pitches below C1 stay
; positive bytes; x mod 12 is unchanged by the bias.
; ---------------------------------------------------------------------------

.segment "JAMDATA"
.include "jamdata.inc"

BIAS     = 72
TPB      = 12
BARL     = 48
MAXGAP   = 4
K_CTL    = 0
K_OFF    = 1
K_ON     = 2
K_DRUM   = 3
LEAD     = 0
BASS     = 1
COMP1    = 2
COMP2    = 3
NSLOT    = 72               ; chord slots: 70 for the form (gen_tables checks)
KEYCH    = 70               ; chord slot: the key chord (key_scale styles)
ENDCH    = 71               ; chord slot: the final chord
NOSLOT   = $FF
BUZZHI   = 57               ; buzzy lead waves: top note (psq)
V8LO     = 24               ; 8-bit 64 kHz voices: in tune up to A4
V8HI     = 40               ; ... usable up to E4; fix8 also skips C#4/D#4

; ---- zero page (main thread; $B0-$DF) ------------------------------------
JWP      = $B0              ; 2: ring write pointer
STYP      = $B2              ; 2: style record
GP       = $B4              ; 2: general pointer
GP2      = $B6              ; 2
GP3      = $B8              ; 2
T0       = $BA              ; scratch
T1       = $BB
T2       = $BC
T3       = $BD
DVD      = $BE              ; 2: dividend / quotient
ML       = $C0              ; multiply low byte
FR       = $C1              ; 3: fr() result
FT       = $C4              ; 2: fr()/chord_at() tick argument
NB       = $C6              ; degree(): base
NN       = $C7              ; note work
NLO      = $C8              ; range for nearest()
NHI      = $C9
NTG      = $CA              ; nearest() target
RIFFP    = $CB              ; 2: current riff
PATP     = $CD              ; 2: current pattern
SECP     = $CF              ; 2: current section record
FORMP    = $D1              ; 2: form
TK       = $D3              ; 2: a tick (note start)
TD       = $D5              ; 2: a length
TG       = $D7              ; note gap
TR       = $D8              ; note track
T4       = $D9
T5       = $DA
T6       = $DB
T7       = $DC
T8       = $DD

.segment "JAMBSS"
JSEED:   .res 2             ; seed for jam_init
rs:      .res 2             ; RNG state
styn:    .res 1
key:     .res 1
beat:    .res 1
bar4:    .res 1             ; 4 * beat: frames per bar
swing:   .res 1
frame0:  .res 3             ; frame of the tune's tick 0
flen:    .res 1
unit:    .res 1
plen:    .res 1
barslot: .res 64            ; first chord slot of each bar
barnch:  .res 64
ch_tick: .res NSLOT
ch_root: .res NSLOT
ch_tlo:  .res NSLOT           ; tones list
ch_thi:  .res NSLOT
ch_slo:  .res NSLOT           ; scale list
ch_shi:  .res NSLOT
ch_mlo:  .res NSLOT           ; chord-tone mask (bit = pitch class)
ch_mhi:  .res NSLOT
ch_smlo: .res NSLOT           ; scale mask
ch_smhi: .res NSLOT
haskc:   .res 1             ; the style reads riffs in the key's scale
arrp:    .res 2
inst:    .res 4
tick:    .res 2             ; tune tick of the bar being generated
secn:    .res 1             ; section index (sec_i)
secon:   .res 1             ; a section is running (sec != None)
ending:  .res 1
nbars:   .res 1
sec0:    .res 2
sbar:    .res 1
offt:    .res 2             ; off * 48
sflags:  .res 1
; lead machine
lpv:     .res 1             ; lead_prev valid
lprev:   .res 1
lt:      .res 2
p_end:   .res 2
p_stop:  .res 2
s_end:   .res 2
bnext:   .res 2             ; B1
riffon:  .res 1             ; a riff is running
ri:      .res 1
rilen:   .res 1
rtr:     .res 1             ; transpose (signed)
shift:   .res 1             ; signed
speed:   .res 1
cprev:   .res 1
lrv:     .res 1             ; last_riff valid
lriff:   .res 1
ltr:     .res 1
nlead:   .res 1             ; lnotes non-empty
lntr:    .res 1             ; lnotes[-1]: its track and serial
lnser:   .res 2
phhas:   .res 1             ; a note since the phrase began
; comp / bass
cvld:     .res 2             ; comp_last valid, per voice
clast:      .res 2             ; comp_last
blv:     .res 1
blast:   .res 1
bpatv:   .res 1
cpatv:   .res 1
dpatv:   .res 1
bpat:    .res 2
cpat:    .res 2
dpat:    .res 2
; head
hrec:    .res 1             ; recording a unit
hhave:   .res 4             ; per plan letter: recorded
hstart:  .res 4             ; per letter: first record
hcount:  .res 4
hletter: .res 1
hu0:     .res 2             ; U0
hfirst:  .res 2             ; serial of the unit's first note
hn:      .res 1             ; records used
HMAX     = 160              ; theme records (a letter is ~40 notes; overflow drops)
hr_t0:   .res HMAX          ; tick in unit
hr_t1:   .res HMAX
hr_d0:   .res HMAX
hr_d1:   .res HMAX
hr_n:    .res HMAX
hr_ser0: .res HMAX
hr_ser1: .res HMAX
; notes still open, per track
lo_open: .res 4
lo_t0:   .res 4
lo_t1:   .res 4
lo_d0:   .res 4
lo_d1:   .res 4
lo_n:    .res 4             ; clamped, biased
lo_gap:  .res 4
lo_on0:  .res 4
lo_on1:  .res 4
lo_on2:  .res 4
lo_ev:   .res 4             ; queue index of its on event ($FF sent)
lo_s0:   .res 4             ; serial
lo_s1:   .res 4
serial:  .res 2
; event queue
QMAX     = 255
qn:      .res 1
qf0:     .res 256
qf1:     .res 256
qf2:     .res 256
qa:      .res 256
hf:      .res 3             ; flush horizon
sent:    .res 3             ; frame of the last event sent
fin:     .res 1             ; final flush
; drum work
duse:    .res 8*17          ; up to 8 drums: id + 16 odds
fbuf:    .res 1+8*17        ; the fill, unpacked
dnum:    .res 1
tmp16:   .res 2
tmp16b:  .res 2
nc_t:    .res 2             ; next_change result tick
nc_c:    .res 1             ;  ... and chord
vs0:     .res 1
vs1:     .res 1
dg_d:    .res 1             ; degree()
dg_n:    .res 1
dg_o:    .res 1
dg_s:    .res 1
dg_t:    .res 1
sn_n:    .res 1             ; snap()
sn_i:    .res 1
sn_v:    .res 1
cl_x:    .res 1             ; close()
cl_a:    .res 1
cl_o:    .res 3
cutt:    .res 2
nc_c0:   .res 1             ; next_change()
nc_s:    .res 2
nc_l:    .res 2
rdur:    .res 1             ; the riff note's full length
wn:      .res 1             ; bass note being placed
dd:      .res 1             ; drum()
dch:     .res 1
jrand:   .res 1             ; RANDOM on: each tune after the first picks a style
ntfirst: .res 1             ; new_tune is the performance's first
lhi:     .res 1             ; the lead's top note (buzzy presets: lower)
nr_s:    .res 2             ; next_real()
nr_t:    .res 2
nr_c:    .res 1
nr_m0:   .res 1
nr_m1:   .res 1
nr_l:    .res 2
fu_d:    .res 2             ; fits_until()
fu_n:    .res 1
fu_e:    .res 2
aup:     .res 1             ; arp: the third step
npre:    .res 1
nrc_v:   .res 1             ; next_real cache: valid
nrc_a:   .res 2             ;  queried at
nrc_t:   .res 2             ;  the change found
nrc_c:   .res 1
nrc_f:   .res 1             ;  1 = found a change (else: none up to nrc_t)
ca_v:    .res 1             ; chord_at cache: valid
ca_rs:   .res 2             ;  section-relative tick where its bar starts
ca_bar:  .res 1             ;  that bar in the form
ca_rel:  .res 2

.segment "JAMBSS4"             ; intensity, swell, phrase kinds
intens:  .res 1             ; this bar's intensity 0-15
dyn:     .res 1             ; the lead's swell level
dynv:    .res 1
jlastlv:  .res 4             ; LEVEL last sent per track
cp_t:    .res 1
resteff: .res 1             ; rest odds at this intensity
lcall:   .res 1             ; the last phrase can be answered
phrv:    .res 1             ; phr_ri/phr_tr: first riff of the running phrase
phr_ri:  .res 1
phr_tr:  .res 1
pk_call: .res 1
pk_prev: .res 1
pk_ri:   .res 1
pk_tr:   .res 1
forcev:  .res 1             ; an answer opens with the call's motif
force_ri: .res 1
force_tr: .res 1
resp:    .res 1             ; this phrase is voice 4's answer
rw0:     .res 2             ; ... its window: comp's voice 2 rests
rw1:     .res 2
qon:     .res 1             ; this phrase quotes the theme
q_ptr:   .res 1
q_end:   .res 1
qoff:    .res 2
qshift:  .res 1
qlo:     .res 2
qhi:     .res 2
qdd:     .res 2
qch:     .res 1
pbv:     .res 1
dboost:  .res 1             ; drum odds shift at this intensity (signed)

.segment "JAMBSS5"             ; $0700-$08FF: the loader's while loading only
qk:      .res 256
qc:      .res 256

.segment "JAMBSS3"             ; the bar's drum hits ($0A40: the synth's key log)
DHMAX    = 64
dhn:     .res 1
dh_s:    .res DHMAX         ; step
dh_d:    .res DHMAX         ; drum
dh_c:    .res DHMAX         ; channel
dbz0:    .res 2             ; steps each channel is busy
dbz1:    .res 2
ld_s:    .res 8             ; per drum: its last step ($FF none), channel
ld_c:    .res 8

.segment "JAMBSS2"             ; flush's sort buffers (low RAM)
hookf:   .res 1             ; start_riff: the hook was chosen (no nudging)
rfirst:  .res 1             ; the riff's first pitched degree
nd_i:    .res 1             ; chord-tone nudge: offset index
quiet:   .res 1             ; a solo: its first and last bar are silent (0/1)
phq:     .res 2             ; new_phrase: t div 48
f8n:     .res 1             ; fix8
fb:      .res 49            ; frames from bar start per tick
plan:    .res 16
qsel:    .res 256
sel:     .res 256
sout:    .res 256
cnt:     .res 256

.segment "JAMCODE"

; ===========================================================================
; arithmetic
; ---------------------------------------------------------------------------
rng_byte:                       ; xorshift16 (7, 9, 8); A = low byte
        lda rs+1
        lsr a
        lda rs
        ror a
        eor rs+1
        sta rs+1
        ror a
        eor rs
        sta rs
        eor rs+1
        sta rs+1
        lda rs
        rts

mul8:                           ; A * X -> A:ML (hi:lo)
        sta T0
        stx T1
        lda #0
        sta ML
        ldx #8
@l:     asl ML
        rol a
        asl T0
        bcc @n
        clc
        pha
        lda ML
        adc T1
        sta ML
        pla
        adc #0
@n:     dex
        bne @l
        rts

below:                          ; A = n -> A = (rng * n) >> 8
        pha
        jsr rng_byte
        tax
        pla
        jmp mul8

div16:                          ; DVD / A -> DVD quotient, A remainder
        sta T0
        lda #0
        ldx #16
@l:     asl DVD
        rol DVD+1
        rol a
        bcs @s
        cmp T0
        bcc @n
@s:     sbc T0
        inc DVD
@n:     dex
        bne @l
        rts

pick:                           ; (GP) = count, items -> A = random item
        ldy #0
        lda (GP),y
        jsr below
        tay
        iny
        lda (GP),y
        rts

pickw:                          ; (GP) = count, words -> GP = random word
        ldy #0
        lda (GP),y
        jsr below
        asl a
        tay
        iny
        lda (GP),y
        tax
        iny
        lda (GP),y
        sta GP+1
        stx GP
        rts

stw:                            ; GP = word at (STYP)+Y
        lda (STYP),y
        sta GP
        iny
        lda (STYP),y
        sta GP+1
        rts

; ---- ticks -> frames: FR = frame0 + (FT div 48) * bar4 + fb[FT mod 48] ----
fr:
        lda FT
        sta DVD
        lda FT+1
        sta DVD+1
        lda #BARL
        jsr div16
        tax
        lda fb,x
        clc
        adc frame0
        sta FR
        lda frame0+1
        adc #0
        sta FR+1
        lda frame0+2
        adc #0
        sta FR+2
        lda DVD                 ; + q * bar4 (q 16-bit)
        ldx bar4
        jsr mul8
        pha
        lda ML
        clc
        adc FR
        sta FR
        pla
        adc FR+1
        sta FR+1
        bcc @a
        inc FR+2
@a:     lda DVD+1
        beq @x
        ldx bar4
        jsr mul8
        pha
        lda ML
        clc
        adc FR+1
        sta FR+1
        pla
        adc FR+2
        sta FR+2
@x:     rts

; ===========================================================================
; chords
; ---------------------------------------------------------------------------
chord_at:                       ; FT = tune tick -> X = chord slot
        sec
        lda FT
        sbc sec0
        sta DVD
        lda FT+1
        sbc sec0+1
        sta DVD+1
        clc
        lda DVD
        adc offt
        sta DVD
        sta ca_rel
        lda DVD+1
        adc offt+1
        sta DVD+1
        sta ca_rel+1
        lda ca_v                ; the bar asked last, or the one after?
        beq @div
        sec
        lda DVD
        sbc ca_rs
        sta T2
        lda DVD+1
        sbc ca_rs+1
        bne @div
        lda T2
        cmp #BARL
        bcc @hit
        cmp #2*BARL
        bcs @div
        sec
        sbc #BARL
        sta T2
        clc
        lda ca_rs
        adc #BARL
        sta ca_rs
        bcc @nb
        inc ca_rs+1
@nb:    ldy ca_bar
        iny
        cpy flen
        bcc @nb2
        ldy #0
@nb2:   sty ca_bar
        jmp @hit
@div:   lda #BARL
        jsr div16
        sta T2                  ; pos in bar
        sec
        lda ca_rel
        sbc T2
        sta ca_rs
        lda ca_rel+1
        sbc #0
        sta ca_rs+1
        lda flen
        jsr div16
        sta ca_bar              ; bar in form
        lda #1
        sta ca_v
@hit:   ldy ca_bar
        ldx barslot,y
        lda barnch,y
        sta T3
@f:     dec T3
        beq @x
        lda ch_tick+1,x
        cmp T2
        beq @n
        bcs @x
@n:     inx
        bne @f
@x:     rts

lead_chord:                     ; FT -> X: the key chord, or the chord there
        lda haskc
        bne *+5
        jmp chord_at
        ldx #KEYCH
        rts

; degree: X = slot, A = signed degree, NB = base -> A = note (biased)
; root taken at/above NB: NB + ((root - NB) mod 12) + 12*octave + scale[i]
degree:
        sta dg_d
        lda ch_slo,x
        sta GP3
        lda ch_shi,x
        sta GP3+1
        ldy #0
        lda (GP3),y
        sta dg_n                ; scale length
        lda #0
        sta dg_o                ; octave * 12 (signed)
        lda dg_d
        bpl @pos
@neg:   clc                     ; d < 0: add n until >= 0, an octave down each
        adc dg_n
        pha
        lda dg_o
        sec
        sbc #12
        sta dg_o
        pla
        bmi @neg
        jmp @idx
@pos:   cmp dg_n
        bcc @idx
        sbc dg_n
        pha
        lda dg_o
        clc
        adc #12
        sta dg_o
        pla
        jmp @pos
@idx:   tay
        iny
        lda (GP3),y
        sta dg_s                ; scale[i]
        ldy NB                  ; (root - base) mod 12
        lda mod12,y
        sta dg_t
        lda ch_root,x
        sec
        sbc dg_t
        bcs @p
        adc #12
@p:     clc
        adc NB
        clc
        adc dg_o
        clc
        adc dg_s
        rts

; nearest: A = n, NTG = target, NLO/NHI = range -> A
nearest:
        sta NN
@d:     lda NTG                 ; while n - target > 6 and n - 12 >= lo
        clc
        adc #7
        bcs @u
        cmp NN
        beq @d1
        bcs @u
@d1:    lda NLO
        clc
        adc #12
        bcs @u
        cmp NN
        beq @d2
        bcs @u
@d2:    lda NN
        sec
        sbc #12
        sta NN
        jmp @d
@u:     lda NN                  ; while target - n > 6 and n + 12 <= hi
        clc
        adc #7
        bcs @lo
        cmp NTG
        beq @u1
        bcs @lo
@u1:    lda NN
        clc
        adc #12
        bcs @lo
        cmp NHI
        beq @u2
        bcs @lo
@u2:    lda NN
        clc
        adc #12
        sta NN
        jmp @u
@lo:    lda NN                  ; while n < lo: += 12
        cmp NLO
        bcs @hi
        adc #12
        sta NN
        jmp @lo
@hi:    lda NHI                 ; while n > hi: -= 12
        cmp NN
        bcs @x
        lda NN
        sec
        sbc #12
        sta NN
        jmp @hi
@x:     lda NN
        rts

; clamp to itself: nearest(n, n, lo, hi)
clampr:
        sta NTG
        jmp nearest

; snap: A = note, X = slot -> A = nearest chord tone (0 +1 -1 +2 -2 +3 -3)
snap:
        sta sn_n
        ldy #0
@t:     sty sn_i
        lda sn_n
        clc
        adc sdelta,y
        sta sn_v
        tay
        lda mod12,y
        tay
        lda bitlo,y
        and ch_mlo,x
        bne @hit
        lda bithi,y
        and ch_mhi,x
        bne @hit
        ldy sn_i
        iny
        cpy #7
        bne @t
        lda sn_n
        rts
@hit:   lda sn_v
        rts
sdelta: .byte 0,1,$FF,2,$FE,3,$FD

inscale:                        ; A = note, X = slot -> Z clear if in the scale
        tay
        lda mod12,y
        tay
        lda bitlo,y
        and ch_smlo,x
        bne @x
        lda bithi,y
        and ch_smhi,x
@x:     rts

; next_change: FT = tick -> nc_t, nc_c (X)
next_change:
        lda FT
        sta nc_s
        lda FT+1
        sta nc_s+1
        jsr chord_at
        stx nc_c0
        lda nc_s                ; tt = (t div 6 + 1) * 6
        sta DVD
        lda nc_s+1
        sta DVD+1
        lda #6
        jsr div16
        inc DVD
        bne @m
        inc DVD+1
@m:     lda DVD                 ; *6 = *4 + *2
        asl a
        sta nc_t
        lda DVD+1
        rol a
        sta nc_t+1
        lda nc_t
        asl a
        sta nc_l
        lda nc_t+1
        rol a
        sta nc_l+1
        clc
        lda nc_t
        adc nc_l
        sta nc_t
        lda nc_t+1
        adc nc_l+1
        sta nc_t+1
        clc                     ; limit = t + 96
        lda nc_s
        adc #96
        sta nc_l
        lda nc_s+1
        adc #0
        sta nc_l+1
@lp:    lda nc_t
        cmp nc_l
        lda nc_t+1
        sbc nc_l+1
        bcs @end
        lda nc_t
        sta FT
        lda nc_t+1
        sta FT+1
        jsr chord_at
        cpx nc_c0
        bne @got
        clc
        lda nc_t
        adc #6
        sta nc_t
        bcc @lp
        inc nc_t+1
        bne @lp
@end:   lda nc_t
        sta FT
        lda nc_t+1
        sta FT+1
        jsr chord_at
@got:   stx nc_c
        lda nc_s                ; FT back to t
        sta FT
        lda nc_s+1
        sta FT+1
        rts

; ===========================================================================
; events
; ---------------------------------------------------------------------------
qpush:                          ; FR, T0 = class, T1 = cmd, T2 = arg -> X = index
        ldx qn
        lda FR
        sta qf0,x
        lda FR+1
        sta qf1,x
        lda FR+2
        sta qf2,x
        lda T0
        sta qk,x
        lda T1
        sta qc,x
        lda T2
        sta qa,x
        inc qn
        rts

; note: TR = track, TK = tick, TD = length, A = note (biased), TG = gap
note:
        jsr jam_yield
        pha
        ldx TR
        lda lo_open,x
        beq @o
        lda TK
        sta cutt
        lda TK+1
        sta cutt+1
        lda #1
        jsr close               ; cut at TK
@o:     lda TK
        sta FT
        lda TK+1
        sta FT+1
        jsr fr
        pla                     ; clamp to C1..B8
        cmp #BIAS
        bcs @c1
        lda #BIAS
@c1:    cmp #BIAS+96
        bcc @c2
        lda #BIAS+95
@c2:    ldx TR
        sta lo_n,x
        sec
        sbc #BIAS
        sta T2
        lda #K_ON
        sta T0
        lda TR
        sta T1                  ; NOTE_ON = op 0
        jsr qpush
        txa
        ldx TR
        sta lo_ev,x
        lda #1
        sta lo_open,x
        lda TK
        sta lo_t0,x
        lda TK+1
        sta lo_t1,x
        lda TD
        sta lo_d0,x
        lda TD+1
        sta lo_d1,x
        lda TG
        sta lo_gap,x
        lda FR
        sta lo_on0,x
        lda FR+1
        sta lo_on1,x
        lda FR+2
        sta lo_on2,x
        inc serial
        bne @s
        inc serial+1
@s:     lda serial
        sta lo_s0,x
        lda serial+1
        sta lo_s1,x
        rts

; close: X = track; A = 1: cut at tmp16 (if earlier than the end)
close:
        stx cl_x
        sta cl_a
        clc                     ; end = t + d
        lda lo_t0,x
        adc lo_d0,x
        sta FT
        lda lo_t1,x
        adc lo_d1,x
        sta FT+1
        lda cl_a
        beq @e
        lda cutt                ; cut < end -> end = cut
        cmp FT
        lda cutt+1
        sbc FT+1
        bcs @e
        lda cutt
        sta FT
        lda cutt+1
        sta FT+1
@e:     jsr fr
        ldx cl_x                ; off = max(on + 1, fr(end) - gap)
        sec
        lda FR
        sbc lo_gap,x
        sta FR
        lda FR+1
        sbc #0
        sta FR+1
        lda FR+2
        sbc #0
        sta FR+2
        clc
        lda lo_on0,x
        adc #1
        sta cl_o
        lda lo_on1,x
        adc #0
        sta cl_o+1
        lda lo_on2,x
        adc #0
        sta cl_o+2
        lda FR                  ; FR < on+1 -> on+1
        cmp cl_o
        lda FR+1
        sbc cl_o+1
        lda FR+2
        sbc cl_o+2
        bcs @k
        lda cl_o
        sta FR
        lda cl_o+1
        sta FR+1
        lda cl_o+2
        sta FR+2
@k:     lda #K_OFF
        sta T0
        txa
        ora #$10
        sta T1
        lda #0
        sta T2
        jsr qpush
        ldx cl_x
        lda #0
        sta lo_open,x
        rts

ctl:                            ; FT = tick, T1 = cmd, T2 = arg (FT kept)
        lda T1
        pha
        lda T2
        pha
        jsr fr
        pla
        sta T2
        pla
        sta T1
        lda #K_CTL
        sta T0
        jmp qpush

preset_now:                     ; X = track, A = preset: at `tick`
        sta T2
        txa
        ora #$30
        sta T1
        lda tick
        sta FT
        lda tick+1
        sta FT+1
        jmp ctl

drum:                           ; FT = tick, A = drum (its own channel)
        tax
        ldy drumch,x
drumx:                          ; ... Y = channel
        jsr jam_yield
        sta dd
        sty dch
        jsr fr
        lda dd
        sta T2
        lda dch
        ora #$20
        sta T1
        lda #K_DRUM
        sta T0
        jmp qpush
drumch: .byte 0,0,1,1,0,0,0,1

; ===========================================================================
; flush: send every event that can no longer change, in (frame, class) order
; ---------------------------------------------------------------------------
flush:                          ; fin = 1: everything
        ldx #0
@c:     stx T8
        lda lo_open,x
        beq @cn
        lda fin
        bne @clast
        clc                     ; t + d < tick ?
        lda lo_t0,x
        adc lo_d0,x
        sta tmp16b
        lda lo_t1,x
        adc lo_d1,x
        sta tmp16b+1
        lda tmp16b
        cmp tick
        lda tmp16b+1
        sbc tick+1
        bcs @cn
@clast:    lda #0
        jsr close
@cn:    ldx T8
        inx
        cpx #4
        bne @c
        lda tick                ; H = fr(tick) - MAXGAP
        sta FT
        lda tick+1
        sta FT+1
        jsr fr
        sec
        lda FR
        sbc #MAXGAP
        sta hf
        lda FR+1
        sbc #0
        sta hf+1
        lda FR+2
        sbc #0
        sta hf+2
        ldx #0                  ; select
        ldy #0
@s:     cpx qn
        beq @sd
        lda fin
        bne @take
        lda qf0,x
        cmp hf
        lda qf1,x
        sbc hf+1
        lda qf2,x
        sbc hf+2
        bcc @take
        lda #0
        sta qsel,x
        inx
        bne @s
@take:  lda #1
        sta qsel,x
        txa
        sta sel,y
        iny
        inx
        bne @s
@sd:    sty T8                  ; m
        cpy #0
        beq @nosort
        lda #<qk                ; LSD radix: class, then frame bytes
        ldx #>qk
        jsr rpass
        lda #<qf0
        ldx #>qf0
        jsr rpass
        lda #<qf1
        ldx #>qf1
        jsr rpass
        lda #<qf2
        ldx #>qf2
        jsr rpass
        ldy #0                  ; emit
@e:     sty T7
        ldx sel,y
        jsr emit
        ldy T7
        iny
        cpy T8
        bne @e
@nosort:
        ldx #0                  ; compact the rest; remap open notes' events
        ldy #0
@k:     cpx qn
        beq @kd
        lda qsel,x
        bne @drop
        lda qf0,x
        sta qf0,y
        lda qf1,x
        sta qf1,y
        lda qf2,x
        sta qf2,y
        lda qk,x
        sta qk,y
        lda qc,x
        sta qc,y
        lda qa,x
        sta qa,y
        stx T0
        sty T1
        ldx #3
@r:     lda lo_ev,x
        cmp T0
        bne @r2
        lda T1
        sta lo_ev,x
@r2:    dex
        bpl @r
        ldx T0
        iny
        inx
        bne @k
@drop:  stx T0
        ldx #3
@d:     lda lo_ev,x
        cmp T0
        bne @d2
        lda #$FF
        sta lo_ev,x
@d2:    dex
        bpl @d
        ldx T0
        inx
        bne @k
@kd:    sty qn
        rts

; one stable counting-sort pass of sel[0..m) by the byte array at A/X
rpass:
        jsr jam_yield
        sta GP
        stx GP+1
        ldx #0
        txa
@z:     sta cnt,x
        inx
        bne @z
        ldy #0
@h:     sty T6
        lda sel,y
        tay
        lda (GP),y
        tax
        inc cnt,x
        ldy T6
        iny
        cpy T8
        bne @h
        ldx #0                  ; counts -> start positions
        lda #0
@p:     ldy cnt,x
        sta cnt,x
        sty T6
        clc
        adc T6
        inx
        bne @p
        ldy #0
@o:     sty T6
        lda sel,y
        sta T5
        tay
        lda (GP),y
        tax
        ldy cnt,x
        inc cnt,x
        lda T5
        sta sout,y
        ldy T6
        iny
        cpy T8
        bne @o
        ldy #0
@c:     lda sout,y
        sta sel,y
        iny
        cpy T8
        bne @c
        rts

emit:                           ; X = queue entry -> ring bytes
        jsr jam_yield
        sec                     ; delta = frame - sent (24-bit)
        lda qf0,x
        sbc sent
        sta T0
        lda qf1,x
        sbc sent+1
        sta T1
        lda qf2,x
        sbc sent+2
        sta T2
        lda qf0,x
        sta sent
        lda qf1,x
        sta sent+1
        lda qf2,x
        sta sent+2
@big:   lda T2                  ; while delta > 254: 255, delta -= 255
        ora T1
        bne @255
        lda T0
        cmp #255
        bcc @d
@255:   lda #255
        jsr put
        sec
        lda T0
        sbc #255
        sta T0
        lda T1
        sbc #0
        sta T1
        lda T2
        sbc #0
        sta T2
        jmp @big
@d:     lda T0
        jsr put
        lda qc,x
        jsr put
        lda qc,x
        and #$F0
        cmp #$10                ; NOTE_OFF: no argument
        beq @x
        lda qa,x
        jsr put
@x:     rts

put:                            ; A -> ring (keeps X)
        ldy #0
        sta (JWP),y
        inc JWP
        bne @x
        inc JWP+1
        lda JWP+1
        cmp #>(JRING+JRINGSZ)
        bne @x
        lda #>JRING
        sta JWP+1
@x:     rts

; ===========================================================================
; the tune
; ---------------------------------------------------------------------------
jam_init:                       ; A = style (jrand: the caller's switch)
        jsr set_style
        lda #1
        sta ntfirst
        lda JSEED
        ora JSEED+1
        bne @s
        lda #$E1
        sta rs
        lda #$AC
        sta rs+1
        bne @q
@s:     lda JSEED
        sta rs
        lda JSEED+1
        sta rs+1
@q:     lda #0
        sta qn
        sta sent
        sta sent+1
        sta sent+2
        sta frame0
        sta frame0+1
        sta frame0+2
        sta serial
        sta serial+1
        ldx #3
@o:     sta lo_open,x
        dex
        bpl @o
        lda #<JRING
        sta JWP
        lda #>JRING
        sta JWP+1
        ; fall through

new_tune:
        lda ntfirst             ; RANDOM: the next tune, any style
        bne @k
        lda jrand
        beq @k
        lda #NSTYLES
        jsr below
        jsr set_style
@k:     lda #0
        sta ntfirst
        ldy #ST_KEYS
        jsr stw
        jsr pick
        sta key
        ldy #ST_BEAT_HI         ; beat = lo + below(hi - lo + 1)
        lda (STYP),y
        ldy #ST_BEAT_LO
        sec
        sbc (STYP),y
        clc
        adc #1
        jsr below
        ldy #ST_BEAT_LO
        clc
        adc (STYP),y
        sta beat
        asl a
        asl a
        sta bar4
        ldy #ST_SWING
        lda (STYP),y
        ldx beat
        cpx #22
        bcs @sw
        sec
        sbc #1
        bcs @sw
        lda #0
@sw:    sta swing
        jsr make_fb
        ldy #ST_FORMS
        jsr stw
        jsr pickw
        lda GP
        sta FORMP
        lda GP+1
        sta FORMP+1
        jsr make_chords
        ldy #ST_ARRANGEMENTS
        jsr stw
        jsr pickw
        lda GP
        sta arrp
        lda GP+1
        sta arrp+1
        ldy #ST_LEAD_PRESETS
        jsr stw
        jsr pick
        sta inst
        ldy #ST_BASS_PRESETS
        jsr stw
        jsr pick
        sta inst+1
        ldy #ST_COMP_PRESETS
        jsr stw
        jsr pick
        sta inst+2
        sta inst+3
        lda #0
        sta tick
        sta tick+1
        ldx #0
@pr:    stx T8
        lda inst,x
        jsr preset_now
        ldx T8
        inx
        cpx #4
        bne @pr
        ldx #0                  ; the style's mix levels
@mx:    stx T8
        txa
        clc
        adc #ST_MIX0
        tay
        lda (STYP),y
        sta T2
        txa
        ora #$50                ; LEVEL = op 5
        sta T1
        lda #0
        sta FT
        sta FT+1
        jsr ctl
        ldx T8
        inx
        cpx #4
        bne @mx
        ldx #3                  ; levels as sent (0 = full = 15)
@ll:    txa
        clc
        adc #ST_MIX0
        tay
        lda (STYP),y
        bne @l1
        lda #15
@l1:    sta jlastlv,x
        dex
        bpl @ll
        lda #0
        sta dynv
        sta lcall
        sta phrv
        sta forcev
        sta resp
        sta qon
        sta rw0
        sta rw0+1
        sta rw1
        sta rw1+1
        lda inst
        jsr set_lead_range
        lda #0
        sta lpv
        sta cvld
        sta cvld+1
        sta blv
        sta hhave
        sta hhave+1
        sta hhave+2
        sta hhave+3
        sta hn
        sta ending
        lda #$FF
        sta secn
        jmp next_section

set_style:                      ; A = style -> styn, STYP
        sta styn
        asl a
        tay
        lda styles,y
        sta STYP
        lda styles+1,y
        sta STYP+1
        rts

set_lead_range:                 ; A = lead preset -> lhi
        pha
        ldy #ST_LEAD_HI
        lda (STYP),y
        sta lhi
        pla
        cmp #4                  ; BASS and SYNTH are poly4 buzz: out of tune
        beq @b                  ;  above A5
        cmp #6
        bne @x
@b:     lda lhi
        cmp #BUZZHI+1
        bcc @x
        lda #BUZZHI
        sta lhi
@x:     rts

make_fb:                        ; fb[t] = ((t div 12)*72 + x6[t mod 12]) * beat div 72
        ldx #0
@t:     stx T8
        txa
        ldy #0                  ; t div 12, t mod 12
@d:     cmp #12
        bcc @r
        sbc #12
        iny
        bne @d
@r:     sta T7                  ; r
        tya
        ldx #72
        jsr mul8                ; (t div 12) * 72 -> A:ML
        sta DVD+1
        lda ML
        sta DVD
        lda T7                  ; x6 = r*(6+s) | 36+6s + (r-6)*(6-s)
        cmp #6
        bcs @late
        lda swing
        clc
        adc #6
        tax
        lda T7
        jsr mul8
        lda ML
        jmp @add
@late:  lda #6
        sec
        sbc swing
        tax
        lda T7
        sec
        sbc #6
        jsr mul8
        lda swing
        asl a
        sta T6
        asl a
        clc
        adc T6                  ; 6s
        adc #36
        clc
        adc ML
@add:   clc
        adc DVD
        sta DVD
        bcc @m
        inc DVD+1
@m:     lda DVD                 ; * beat (16 x 8)
        ldx beat
        jsr mul8
        sta T6
        lda ML
        sta T5
        lda DVD+1
        ldx beat
        jsr mul8
        lda ML
        clc
        adc T6
        sta DVD+1
        lda T5
        sta DVD
        lda #72
        jsr div16
        ldx T8
        lda DVD
        sta fb,x
        inx
        cpx #48
        beq *+5
        jmp @t
        lda bar4
        sta fb+48
        rts

make_chords:                    ; the form -> chord slots, transposed to key
        lda #0
        sta ca_v
        sta nrc_v
        ldy #0
        lda (FORMP),y
        sta flen
        iny
        lda (FORMP),y
        sta unit
        iny
        lda (FORMP),y
        sta plen
        ldx #0
@pl:    iny
        lda (FORMP),y
        sta plan,x
        inx
        cpx plen
        bne @pl
        iny
        tya
        clc
        adc FORMP
        sta GP
        lda FORMP+1
        adc #0
        sta GP+1
        ldx #0                  ; slot
        lda #0
        sta T8                  ; bar
@bar:   ldy T8
        txa
        sta barslot,y
        ldy #0
        lda (GP),y
        ldy T8
        sta barnch,y
        sta T7
        jsr gp_inc
@ch:    ldy #0                  ; (tick/12)<<4 | root, quality
        lda (GP),y
        pha
        and #$0F
        clc
        adc key
        cmp #12
        bcc @k
        sbc #12
@k:     sta ch_root,x
        pla
        lsr a                   ; tick = (b >> 4) * 12
        lsr a
        and #$3C                ;  (= (b >> 4) * 4)
        sta T6
        asl a
        clc
        adc T6
        sta ch_tick,x
        iny
        lda (GP),y
        tay
        lda qt_tlo,y
        sta ch_tlo,x
        lda qt_thi,y
        sta ch_thi,x
        lda qt_slo,y
        sta ch_slo,x
        lda qt_shi,y
        sta ch_shi,x
        jsr masks
        lda #2
        jsr gp_add
        inx
        dec T7
        bne @ch
        inc T8
        lda T8
        cmp flen
        bne @bar
        ldy #ST_KEY_SCALE       ; the key chord
        lda (STYP),y
        iny
        ora (STYP),y
        sta haskc
        beq @x
        ldx #KEYCH
        lda key
        sta ch_root,x
        ldy #ST_KEY_SCALE
        lda (STYP),y
        sta ch_slo,x
        iny
        lda (STYP),y
        sta ch_shi,x
        lda #<kc_tones
        sta ch_tlo,x
        lda #>kc_tones
        sta ch_thi,x
        jsr masks
@x:     rts

gp_inc: lda #1
gp_add: clc
        adc GP
        sta GP
        bcc @x
        inc GP+1
@x:     rts

masks:                          ; slot X: chord-tone and scale masks
        lda ch_tlo,x
        sta GP2
        lda ch_thi,x
        sta GP2+1
        jsr mask_of
        lda T5
        sta ch_mlo,x
        lda T6
        sta ch_mhi,x
        lda ch_slo,x
        sta GP2
        lda ch_shi,x
        sta GP2+1
        jsr mask_of
        lda T5
        sta ch_smlo,x
        lda T6
        sta ch_smhi,x
        rts

mask_of:                        ; (GP2) list of intervals, root of slot X -> T5/T6
        lda #0
        sta T5
        sta T6
        ldy #0
        lda (GP2),y
        sta T4
@m:     iny
        lda (GP2),y
        clc
        adc ch_root,x
        sty T3
        tay
        lda mod12,y
        tay
        lda bitlo,y
        ora T5
        sta T5
        lda bithi,y
        ora T6
        sta T6
        ldy T3
        dec T4
        bne @m
        rts

next_section:
        inc secn
        lda arrp
        sta GP
        lda arrp+1
        sta GP+1
        lda secn
        ldy #0
        cmp (GP),y
        bcc @go
        lda #0
        sta secon
        rts
@go:    asl a                   ; cfg = arr[secn]
        tay
        iny
        lda arrp
        sta GP
        lda arrp+1
        sta GP+1
        lda (GP),y
        sta SECP
        iny
        lda (GP),y
        sta SECP+1
        lda #1
        sta secon
        lda #0                  ; the chord grid moves: forget cached answers
        sta nrc_v
        sta ca_v
        ldy #SE_FLAGS
        lda (SECP),y
        sta sflags
        ldy #SE_BARS
        lda (SECP),y
        bne @b
        lda flen
@b:     sta nbars
        lda tick
        sta sec0
        lda tick+1
        sta sec0+1
        lda #0
        sta sbar
        sta offt
        sta offt+1
        lda sflags
        and #F_FROMEND
        beq @o
        lda nbars               ; off = (flen - nbars mod flen) mod flen
@m:     cmp flen
        bcc @m2
        sbc flen
        bcs @m
@m2:    sta T0
        lda flen
        sec
        sbc T0
        cmp flen
        bcc @m3
        lda #0
@m3:    ldx #BARL
        jsr mul8
        sta offt+1
        lda ML
        sta offt
@o:     lda sflags
        and #F_LPRESET
        beq @nl
        ldy #ST_LEAD_PRESETS
        jsr stw
        jsr pick
        sta npre
        ldx #LEAD
        jsr preset_now
        lda npre
        jsr set_lead_range
@nl:    lda #0                  ; a solo (lead, not the theme, 3+ bars):
        sta quiet               ;  its first and last bar are silent
        lda sflags
        and #F_LEAD|F_HEAD
        cmp #F_LEAD
        bne @nq
        lda nbars
        cmp #3
        bcc @nq
        inc quiet
@nq:    lda quiet               ; the lead machine restarts (a solo: after a bar)
        ldx #BARL
        jsr mul8
        lda ML
        clc
        adc tick
        sta lt
        sta p_end
        lda tick+1
        adc #0
        sta lt+1
        sta p_end+1
        lda #0
        sta riffon
        sta lrv
        sta ltr
        sta nlead
        sta hrec
        sta bpatv
        sta cpatv
        sta dpatv
        lda sflags
        and #F_LEAD
        beq @x
        lda sflags
        and #F_TRADE
        beq @x
        ldy #ST_TRADE_PRESETS
        jsr stw
        jsr pick
        ldx #COMP2
        jsr preset_now
@x:     rts

; ===========================================================================
; one bar
; ---------------------------------------------------------------------------
jam_bar:
        lda secon
        bne @sec
        lda ending
        beq *+5
        jmp @fl
        jsr end_bar
        jmp @fl
@sec:   jsr intensity
        lda sflags
        and #F_LEAD
        beq @nl
        lda sflags
        and #F_HEAD
        beq @solo
        jsr head_bar
        jmp @nl
@solo:  clc                     ; lead_bar(B0, B0 + 48, sec0 + nbars * 48)
        lda tick
        adc #BARL
        sta bnext
        lda tick+1
        adc #0
        sta bnext+1
        lda nbars
        sec
        sbc quiet
        ldx #BARL
        jsr mul8
        sta s_end+1
        lda ML
        clc
        adc sec0
        sta s_end
        lda s_end+1
        adc sec0+1
        sta s_end+1
        jsr lead_bar
@nl:    ldy #SE_BASS
        lda (SECP),y
        iny
        ora (SECP),y
        bne @b
        lda sflags
        and #F_WALK
        beq @nb
@b:     jsr bass_bar
@nb:    ldy #SE_COMP
        lda (SECP),y
        iny
        ora (SECP),y
        beq @nc
        lda sflags
        and #F_TRADE
        bne @nc
        jsr comp_bar
@nc:    ldy #SE_DRUMS
        lda (SECP),y
        iny
        ora (SECP),y
        beq @nd
        jsr drum_bar
@nd:    clc
        lda tick
        adc #BARL
        sta tick
        bcc @t
        inc tick+1
@t:     inc sbar
        lda sbar
        cmp nbars
        bcc @fl
        jsr next_section
@fl:    lda #0
        sta fin
        jsr flush
        lda ending
        cmp #2
        bne @x
        lda tick                ; the next tune starts where the tail ends
        sta FT
        lda tick+1
        sta FT+1
        jsr fr
        lda FR
        pha
        lda FR+1
        pha
        lda FR+2
        pha
        lda #1
        sta fin
        jsr flush
        pla
        sta frame0+2
        pla
        sta frame0+1
        pla
        sta frame0
        jmp new_tune
@x:     rts

end_bar:
        ldx #ENDCH              ; the final chord: key + final root, ionian
        ldy #ST_FINAL_ROOT
        lda (STYP),y
        clc
        adc key
        cmp #12
        bcc @r
        sbc #12
@r:     sta ch_root,x
        lda #<sc_ionian
        sta ch_slo,x
        lda #>sc_ionian
        sta ch_shi,x
        lda tick
        sta TK
        lda tick+1
        sta TK+1
        lda #BARL
        sta TD
        lda #0
        sta TD+1
        lda #4
        sta TG
        jsr lead_range
        lda lpv
        beq @p0
        lda lprev
        jmp @p1
@p0:    lda NLO
@p1:    sta NTG
        lda NLO
        sta NB
        lda #0
        ldx #ENDCH
        jsr degree
        jsr nearest
        ldx #LEAD
        stx TR
        jsr note
        ldy #ST_BASS_LO
        jsr rbase
        lda #0
        ldx #ENDCH
        jsr degree
        ldx #BASS
        stx TR
        jsr note
        ldy #ST_COMP_LO
        jsr rbase
        lda NB
        sta NLO
        lda #2
        ldx #ENDCH
        jsr degree
        jsr fix8
        ldx #COMP1
        stx TR
        jsr note
        lda #4
        ldx #ENDCH
        jsr degree
        jsr fix8
        ldx #COMP2
        stx TR
        jsr note
        lda tick
        sta FT
        lda tick+1
        sta FT+1
        lda #7
        jsr drum
        lda #0
        jsr drum
        lda #0                  ; the last chord fades: 12 9 6, a beat apart
        sta T7
@fd:    lda T7                  ; FT = tick + 12 * (k + 1)
        clc
        adc #1
        asl a
        asl a
        sta T6
        asl a
        clc
        adc T6
        clc
        adc tick
        sta FT
        lda tick+1
        adc #0
        sta FT+1
        ldx #0
@ft:    stx T8
        txa
        clc
        adc #ST_MIX0
        tay
        lda (STYP),y
        bne @fm
        lda #15
@fm:    ldy T7
        cmp fades,y
        bcc @fl
        lda fades,y
@fl:    sta T2
        txa
        ora #$50
        sta T1
        jsr ctl
        ldx T8
        inx
        cpx #4
        bne @ft
        inc T7
        lda T7
        cmp #3
        bne @fd
        ldy #ST_TAIL            ; tick += 48 + tail
        lda (STYP),y
        clc
        adc #BARL
        adc tick
        sta tick
        bcc @t
        inc tick+1
@t:     lda #2
        sta ending
        rts

rbase:                          ; NB = biased range low at (STYP),Y
        lda (STYP),y
        clc
        adc #BIAS
        sta NB
        rts

; fix8: A = a held 8-bit comping note (biased), NLO = the range low -> A: at
; most E4, and not C#4/D#4 (5-11 cents off on the 64 kHz channel; the octave
; below, down to the C3 floor, is within 4 cents)
fix8:
        sta f8n
@w:     lda f8n
        cmp #V8HI+BIAS+1
        bcc @b
        sec
        sbc #12
        cmp NLO
        bcc @b                  ; can't drop within the range: keep
        sta f8n
        jmp @w
@b:     lda f8n
        cmp #37+BIAS
        beq @bad
        cmp #39+BIAS
        bne @x
@bad:   sec
        sbc #12
        cmp #V8LO+BIAS
        bcs @x
        lda f8n
@x:     rts

lead_range:                     ; NLO/NHI = the lead's range (biased)
        ldy #ST_LEAD_LO
        lda (STYP),y
        clc
        adc #BIAS
        sta NLO
        lda lhi
        clc
        adc #BIAS
        sta NHI
        rts

; ===========================================================================
; the lead: riffology
; ---------------------------------------------------------------------------
; lead_bar: lt runs up to bnext (B1); phrases end by s_end
lead_bar:
        jsr lead_range
        ldy #SE_REST            ; rest odds * (20 - I) / 10, at most 255
        lda (SECP),y
        tax
        lda #20
        sec
        sbc intens
        jsr mul8
        sta DVD+1
        lda ML
        sta DVD
        lda #10
        jsr div16
        lda DVD+1
        beq @r1
        lda #255
        bne @r2
@r1:    lda DVD
@r2:    sta resteff
        lda lpv
        bne @lp
        lda NLO                 ; (lo + hi) // 2
        clc
        adc NHI
        ror a
        sta lprev
        lda #1
        sta lpv
@lp:    lda lt                  ; while lt < B1
        cmp bnext
        lda lt+1
        sbc bnext+1
        bcc @go
        rts
@go:    lda lt                  ; t >= p_end: a new phrase
        cmp p_end
        lda lt+1
        sbc p_end+1
        bcc @inph
        lda lt
        cmp s_end
        lda lt+1
        sbc s_end+1
        bcc @np
        rts
@np:    jsr new_phrase
@inph:  lda lt                  ; t >= p_stop: breathe
        cmp p_stop
        lda lt+1
        sbc p_stop+1
        bcc @play
        jsr cadence
        lda p_end
        sta lt
        lda p_end+1
        sta lt+1
        jmp @lp
@play:  lda qon                 ; quoting the theme
        beq @rf
        jsr quote_note
        jmp @lp
@rf:    lda riffon
        bne @r
        lda lt                  ; a riff starts on an eighth: a cross-rhythm
        sta DVD                 ;  riff ends off the grid, the next waits
        lda lt+1
        sta DVD+1
        lda #6
        jsr div16
        cmp #0
        beq @rs
        inc DVD                 ; lt = (q + 1) * 6
        bne @r6
        inc DVD+1
@r6:    lda DVD
        asl a
        sta lt
        lda DVD+1
        rol a
        sta lt+1
        lda lt                  ; *2 -> *6: + *4
        asl a
        sta tmp16
        lda lt+1
        rol a
        sta tmp16+1
        clc
        lda lt
        adc tmp16
        sta lt
        lda lt+1
        adc tmp16+1
        sta lt+1
        jmp @lp
@rs:    jsr start_riff
@r:     jsr riff_note
        lda lt                  ; lt >= p_stop: cadence, wait for p_end
        cmp p_stop
        lda lt+1
        sbc p_stop+1
        bcs *+5
        jmp @lp
        jsr cadence
        lda p_end
        sta lt
        lda p_end+1
        sta lt+1
        jmp @lp

new_phrase:
        ldy #SE_PHRASE          ; pb
        lda (SECP),y
        sta GP
        iny
        lda (SECP),y
        sta GP+1
        jsr pick
        sta T8
        sta pbv
        lda lt                  ; p_end = min(s_end, (t div 48 + pb) * 48)
        sta DVD
        lda lt+1
        sta DVD+1
        lda #BARL
        jsr div16
        lda DVD
        sta phq
        lda DVD+1
        sta phq+1
        clc
        lda DVD
        adc T8
        sta DVD
        bcc @q
        inc DVD+1
@q:     lda DVD
        ldx #BARL
        jsr mul8
        sta p_end+1
        lda ML
        sta p_end
        lda DVD+1
        beq @q2
        ldx #BARL
        jsr mul8
        lda ML
        clc
        adc p_end+1
        sta p_end+1
@q2:
        lda s_end
        cmp p_end
        lda s_end+1
        sbc p_end+1
        bcs @e
        lda s_end
        sta p_end
        lda s_end+1
        sta p_end+1
@e:     lda sflags
        and #F_HEAD
        beq @solo
        ldy #SE_BREATH          ; the theme: p_stop = max(t + 6, p_end - breath)
        lda (SECP),y
        sta GP
        iny
        lda (SECP),y
        sta GP+1
        jsr pick
        sta T8
        sec
        lda p_end
        sbc T8
        sta p_stop
        lda p_end+1
        sbc #0
        sta p_stop+1
        jmp @mx
@solo:  lda pbv                 ; a solo phrase talks, then listens: rest =
        lsr a                   ;  pick(pb/2, pb/2, max(1, pb/2 - 1)) bars
        sta T8
        lda #3
        jsr below
        cmp #2
        bne @rk
        lda T8
        sec
        sbc #1
        bne @rs
        lda #1
        bne @rs
@rk:    lda T8
@rs:    sta T7                  ; rest
        lda pbv                 ; p_stop = min(p_end, (q + pb - rest) * 48)
        sec
        sbc T7
        clc
        adc phq
        sta DVD
        lda phq+1
        adc #0
        sta DVD+1
        lda DVD
        ldx #BARL
        jsr mul8
        sta p_stop+1
        lda ML
        sta p_stop
        lda DVD+1
        beq @ps
        ldx #BARL
        jsr mul8
        lda ML
        clc
        adc p_stop+1
        sta p_stop+1
@ps:    lda p_end
        cmp p_stop
        lda p_end+1
        sbc p_stop+1
        bcs @mx
        lda p_end
        sta p_stop
        lda p_end+1
        sta p_stop+1
@mx:    clc                     ; ... and at least t + 6
        lda lt
        adc #6
        sta tmp16
        lda lt+1
        adc #0
        sta tmp16+1
        lda p_stop
        cmp tmp16
        lda p_stop+1
        sbc tmp16+1
        bcs @s
        lda tmp16
        sta p_stop
        lda tmp16+1
        sta p_stop+1
@s:     lda #0
        sta riffon
        sta phhas
        jmp phrase_kind

start_riff:
        lda #0
        sta hookf
        jsr cap                 ; the swell moves a step a riff
        cmp dyn
        beq @fc
        bcc @dn
        inc dyn
        bne @fc
@dn:    dec dyn
@fc:    lda forcev              ; an answer: the call's motif, moved
        beq @nf
        lda #0
        sta forcev
        lda force_ri
        sta lriff
        lda force_tr
        sta ltr
        jmp @pk
@nf:    lda phrv                ; the style's hook opens a phrase
        bne @nh
        ldy #ST_HOOK
        lda (STYP),y
        cmp #$FF
        beq @nh
        jsr rng_byte
        ldy #ST_HOOKP
        cmp (STYP),y
        bcs @nh
        ldy #ST_HOOK
        lda (STYP),y
        ldx #0
        inc hookf
        jmp @set
@nh:    lda lrv
        beq @new
        jsr rng_byte            ; repeat
        ldy #SE_REPEAT
        cmp (SECP),y
        bcs @sq
        lda lriff
        ldx ltr
        jmp @set
@sq:    jsr rng_byte            ; sequence
        ldy #SE_SEQ
        cmp (SECP),y
        bcs @new
@pk:    lda #4
        jsr below
        tax
        lda ltr
        clc
        adc seqd,x
        bmi @neg
        cmp #8
        bcc @ok
        lda #7
        bne @ok
@neg:   cmp #$F9
        bcs @ok
        lda #$F9
@ok:    tax
        lda lriff
        jmp @set
@new:   ldy #ST_RIFFS
        jsr stw
        ldy #0
        lda (GP),y
        sta T8
        jsr below
        ldx lrv
        beq @nw
        cmp lriff
        bne @nw
        clc
        adc #1
        cmp T8
        bcc @nw
        lda #0
@nw:    ldx #0
@set:   sta lriff
        stx rtr
        ldy #ST_RIFFS           ; RIFFP = riffs[lriff]
        jsr stw
        lda lriff
        asl a
        tay
        iny
        lda (GP),y
        sta RIFFP
        iny
        lda (GP),y
        sta RIFFP+1
        ldy #0
        sty ri
        lda (RIFFP),y
        sta rilen
        ldy #1                  ; the first pitched degree (else 0)
        ldx rilen
@f:     lda (RIFFP),y
        cmp #$80
        bne @fd
        iny
        iny
        dex
        bne @f
        lda #0
@fd:    sta rfirst
        lda hookf               ; the riff opens on a chord tone: move it by
        bne @ndn                ;  scale steps (0 +1 -1 +2 -2) until it does
        lda lt
        sta FT
        lda lt+1
        sta FT+1
        jsr lead_range
        lda NLO
        sta NB
        lda #0
        sta nd_i
@nl:    ldx nd_i
        lda rfirst
        clc
        adc rtr
        clc
        adc ndoff,x
        pha
        jsr lead_chord          ; (clobbers A)
        pla
        jsr degree
        pha
        jsr chord_at
        pla
        jsr istone
        bne @ndh
        inc nd_i
        lda nd_i
        cmp #5
        bne @nl
        beq @ndn
@ndh:   ldx nd_i
        lda rtr
        clc
        adc ndoff,x
        sta rtr
@ndn:   lda rtr
        sta ltr
        ldy phrv                ; the phrase's first riff (a call's motif)
        bne @pv
        lda lriff
        sta phr_ri
        lda rtr
        sta phr_tr
        inc phrv
@pv:    lda #1
        sta lrv
        sta riffon
        lda #0
        sta speed
        lda intens              ; fast odds + max(0, I - 10) * 12
        sec
        sbc #10
        bcs @fi
        lda #0
@fi:    asl a
        asl a
        sta T0
        asl a
        clc
        adc T0
        ldy #SE_FAST
        clc
        adc (SECP),y
        bcc @fe
        lda #255
@fe:    sta T0
        jsr rng_byte
        cmp T0
        bcs @sl
        lda #1
        sta speed
        bne @sp
@sl:    jsr rng_byte
        ldy #SE_SLOW
        cmp (SECP),y
        bcs @tp
        lda #2
        sta speed
        bne @sp
@tp:    jsr rng_byte            ; triplets across the beat
        ldy #SE_TRIP
        cmp (SECP),y
        bcs @dt
        lda #3
        sta speed
        bne @sp
@dt:    jsr rng_byte            ; dotted: 3 against 4
        ldy #SE_DOT
        cmp (SECP),y
        bcs @sp
        lda #4
        sta speed
@sp:    lda rfirst
        clc
        adc rtr
        pha
        lda lt
        sta FT
        lda lt+1
        sta FT+1
        jsr lead_chord
        stx cprev
        lda NLO
        sta NB
        pla
        jsr degree              ; n0
        sta T8
        lda intens              ; loud: the line reaches up
        sec
        sbc #10
        bcs @cl
        lda #0
@cl:    clc
        adc lprev
        sta NTG
        lda T8
        jsr nearest
        sec
        sbc T8
        sta shift
        rts
seqd:   .byte $FE,$FF,1,2
ndoff:  .byte 0,1,$FF,2,$FE

riff_note:                      ; one note of the riff at t = lt
        lda ri                  ; Y -> note record (2 bytes)
        asl a
        tay
        iny
        lda (RIFFP),y
        sta T4                  ; deg ($80 rest)
        iny
        lda (RIFFP),y           ; (semis + 1) << 6 | dur
        pha
        rol a                   ; semis = top two bits - 1
        rol a
        rol a
        and #3
        sec
        sbc #1
        sta T5
        pla
        and #$3F                ; dur
        ldx speed
        beq @d3
        cpx #1
        bne @s2
        lsr a
        jmp @d3
@s2:    cpx #2
        bne @s3
        asl a
        jmp @d3
@s3:    cpx #3
        bne @s4
        asl a                   ; triplets: dur * 2 // 3, at least 2
        ldx #0
@t3:    cmp #3
        bcc @t4
        sbc #3
        inx
        bne @t3
@t4:    txa
        cmp #2
        bcs @dk
        lda #2
        bne @dk
@s4:    sta T6                  ; dotted: dur * 3 // 2, at least 3
        asl a
        clc
        adc T6
        lsr a
        cmp #3
        bcs @dk
        lda #3
        bne @dk
@d3:    ldx #0                  ; dur // 3 * 3, at least 3
@dv:    cmp #3
        bcc @dd
        sbc #3
        inx
        bne @dv
@dd:    txa
        sta T6
        asl a
        adc T6
        cmp #3
        bcs @dk
        lda #3
@dk:    sta TD
        sta rdur
        lda #0
        sta TD+1
        inc ri
        lda lt
        sta TK
        lda lt+1
        sta TK+1
        lda T4                  ; rest?
        cmp #$80
        bne *+5
        jmp @adv
        jsr rng_byte
        cmp resteff
        bcs *+5
        jmp @adv
        lda nlead               ; omit? (lnotes non-empty)
        bne *+5
        jmp @pitch
        jsr rng_byte
        ldy #SE_OMIT
        cmp (SECP),y
        bcs @pitch
        ldx lntr                ; ... last note ends here and is still open
        lda lo_open,x
        beq @pitch
        lda lo_s0,x
        cmp lnser
        bne @pitch
        lda lo_s1,x
        cmp lnser+1
        bne @pitch
        clc
        lda lo_t0,x
        adc lo_d0,x
        sta tmp16
        lda lo_t1,x
        adc lo_d1,x
        cmp lt+1
        bne @pitch
        lda tmp16
        cmp lt
        bne @pitch
        lda lt                  ; dropped: the last note rings on, if it fits
        sta FT
        lda lt+1
        sta FT+1
        jsr chord_at
        ldy lntr
        lda lo_n,y
        jsr allowed
        beq @adv
        lda TD
        sta fu_d
        lda #0
        sta fu_d+1
        ldy lntr
        lda lo_n,y
        jsr fits_until
        ldx lntr
        clc
        lda lo_d0,x
        adc fu_d
        sta lo_d0,x
        lda lo_d1,x
        adc fu_d+1
        sta lo_d1,x
        jsr rec_patch
        jmp @adv
@pitch: jsr lead_pitch
@adv:   clc                     ; lt = t + dur
        lda TK
        adc rdur
        sta lt
        lda TK+1
        adc #0
        sta lt+1
        lda ri
        cmp rilen
        bcc @x
        lda #0
        sta riffon
@x:     rts

lead_pitch:                     ; T4 = deg, T5 = semis, TK = t, TD = dur
        lda lt
        sta FT
        lda lt+1
        sta FT+1
        jsr lead_chord
        stx T7
        lda NLO
        sta NB
        lda T4
        clc
        adc rtr
        jsr degree
        clc
        adc shift
        clc
        adc T5
        sta T8                  ; n
        ldx T7
        cpx cprev
        beq @same
        lda lprev               ; new chord: keep the line near
        sta NTG
        lda T8
        jsr nearest
        sta T8
        ldx T7
        stx cprev
        lda T4
        clc
        adc rtr
        jsr degree
        sta T6
        lda T8                  ; shift = n - semis - degree
        sec
        sbc T5
        sec
        sbc T6
        sta shift
@same:  lda lt                  ; the chord sounding now
        sta FT
        lda lt+1
        sta FT+1
        jsr chord_at
        stx T7
        ldy #ST_SNAP            ; strong beats land on chord tones
        lda (STYP),y
        beq @ns
        cmp #1
        beq @s24
        lda #TPB
        bne @sd
@s24:   lda #24
@sd:    pha
        lda lt
        sta DVD
        lda lt+1
        sta DVD+1
        pla
        jsr div16
        cmp #0
        bne @ns
        ldx T7
        lda T8
        jsr snap
        sta T8
@ns:    sec                     ; length min(dur, p_stop - t)
        lda p_stop
        sbc lt
        sta tmp16
        lda p_stop+1
        sbc lt+1
        bne @ln
        lda tmp16
        cmp TD
        bcs @ln
        sta TD
@ln:    ldx T7                  ; off the scale: only a short, written
        lda T8                  ;  approach tone may stay
        jsr allowed
        bne @sc
        lda T5
        beq @lc
        lda TD
        cmp #7
        bcc @sc
@lc:    ldx T7
        lda T8
        jsr snap
        sta T8
@sc:    lda T8
        jsr clampr
        sta T8
        lda lt                  ; released early at a chord it clashes with
        sta FT
        lda lt+1
        sta FT+1
        lda TD
        sta fu_d
        lda TD+1
        sta fu_d+1
        lda T8
        jsr fits_until
        lda fu_d
        sta TD
        lda fu_d+1
        sta TD+1
        jmp lead_note

; lead_note: TK = t, TD = length, T8 = note -> voice 4 in trades and answers
; (an octave down, in tune), swell level + accent, note, lnotes bookkeeping
lead_note:
        lda T8
        sta T6                  ; the pitch played
        ldx #LEAD
        lda resp
        bne @v4
        lda sflags              ; trading: odd 4-bar blocks go to voice 4
        and #F_TRADE
        beq @tr
        sec
        lda TK
        sbc sec0
        sta DVD
        lda TK+1
        sbc sec0+1
        sta DVD+1
        lda #4*BARL
        jsr div16
        lda DVD
        and #1
        beq @tr
@v4:    lda #V8LO+BIAS          ; 8-bit voice: an octave down, kept in tune
        sta NLO
        lda #V8HI+BIAS
        sta NHI
        lda T8
        sec
        sbc #12
        jsr clampr
        sta T6
        jsr lead_range
        ldx #COMP2
@tr:    stx TR
        lda TK
        sta FT
        lda TK+1
        sta FT+1
        jsr accent
        ldx TR
        jsr set_level
        ldy #ST_LEAD_GAP
        lda (STYP),y
        sta TG
        lda T6
        jsr note
        ldx TR                  ; lnotes.append; the unit's record too
        stx lntr
        lda lo_s0,x
        sta lnser
        lda lo_s1,x
        sta lnser+1
        lda #1
        sta nlead
        sta phhas
        lda hrec
        beq @nr
        jsr rec_add
@nr:    lda T8
        sta lprev
        rts

; ---- harmony guards --------------------------------------------------------
istone:                         ; A = note, X = slot -> Z clear if a chord tone
        tay
        lda mod12,y
        tay
        lda bitlo,y
        and ch_mlo,x
        bne @x
        lda bithi,y
        and ch_mhi,x
@x:     rts

allowed:                        ; A = note, X = slot -> Z clear if in its scale
        sta fu_n                ;  (or in the key's scale, key-scale styles)
        jsr inscale
        bne @x
        lda haskc
        beq @x
        ldx #KEYCH
        lda fu_n
        jsr inscale
@x:     rts

; next_real: FT = tick -> C set, nr_t / nr_c: the next change of chord tones
next_real:
        lda nrc_v               ; cached: a query at a <= t < u knows [a, u)
        beq @miss               ;  holds one chord
        lda FT
        cmp nrc_a
        lda FT+1
        sbc nrc_a+1
        bcc @miss
        lda FT
        cmp nrc_t
        lda FT+1
        sbc nrc_t+1
        bcs @miss
        lda nrc_f
        beq @resume
        lda nrc_t               ; the change found (it is < t + 96)
        sta nr_t
        lda nrc_t+1
        sta nr_t+1
        lda nrc_c
        sta nr_c
        sec
        rts
@resume:                        ; nothing changes before u: scan from there
        lda FT
        sta nr_s
        lda FT+1
        sta nr_s+1
        lda nrc_t
        sta nr_t
        lda nrc_t+1
        sta nr_t+1
        lda nrc_a               ; same chord as at a
        sta FT
        lda nrc_a+1
        sta FT+1
        jsr chord_at
        lda ch_mlo,x
        sta nr_m0
        lda ch_mhi,x
        sta nr_m1
        jmp @lim
@miss:  lda FT
        sta nr_s
        lda FT+1
        sta nr_s+1
        jsr chord_at
        lda ch_mlo,x
        sta nr_m0
        lda ch_mhi,x
        sta nr_m1
        lda nr_s                ; tt = (t div 6 + 1) * 6
        sta DVD
        lda nr_s+1
        sta DVD+1
        lda #6
        jsr div16
        inc DVD
        bne @m
        inc DVD+1
@m:     lda DVD
        asl a
        sta nr_t
        lda DVD+1
        rol a
        sta nr_t+1
        lda nr_t
        asl a
        sta nr_l
        lda nr_t+1
        rol a
        sta nr_l+1
        clc
        lda nr_t
        adc nr_l
        sta nr_t
        lda nr_t+1
        adc nr_l+1
        sta nr_t+1
        lda nr_s                ; a fresh cache starts here
        sta nrc_a
        lda nr_s+1
        sta nrc_a+1
@lim:   clc                     ; limit = t + 96
        lda nr_s
        adc #96
        sta nr_l
        lda nr_s+1
        adc #0
        sta nr_l+1
@lp:    lda nr_t
        cmp nr_l
        lda nr_t+1
        sbc nr_l+1
        bcs @none
        lda nr_t
        sta FT
        lda nr_t+1
        sta FT+1
        jsr chord_at
        lda ch_mlo,x
        cmp nr_m0
        bne @got
        lda ch_mhi,x
        cmp nr_m1
        bne @got
        clc
        lda nr_t
        adc #6
        sta nr_t
        bcc @lp
        inc nr_t+1
        bne @lp
@none:  lda nr_t                ; one chord from a up to here
        sta nrc_t
        lda nr_t+1
        sta nrc_t+1
        lda #0
        sta nrc_f
        lda #1
        sta nrc_v
        jsr @back
        clc
        rts
@got:   stx nr_c
        stx nrc_c
        lda nr_t
        sta nrc_t
        lda nr_t+1
        sta nrc_t+1
        lda #1
        sta nrc_f
        sta nrc_v
        jsr @back
        sec
        rts
@back:  lda nr_s
        sta FT
        lda nr_s+1
        sta FT+1
        rts

; fits_until: FT = start tick, fu_d = length, A = note -> fu_d, cut at the
; next change of chord tones if the note isn't one of the new chord's
fits_until:
        sta fu_n
        jsr next_real
        bcc @x
        clc
        lda FT
        adc fu_d
        sta fu_e
        lda FT+1
        adc fu_d+1
        sta fu_e+1
        lda nr_t                ; change at or after the end: fine
        cmp fu_e
        lda nr_t+1
        sbc fu_e+1
        bcs @x
        ldx nr_c
        lda fu_n
        jsr istone
        bne @x
        sec
        lda nr_t
        sbc FT
        sta fu_d
        lda nr_t+1
        sbc FT+1
        sta fu_d+1
@x:     rts

cadence:                        ; the phrase's last note lands on a chord tone
        lda phhas
        bne *+5
        jmp @x
        ldx lntr
        lda lo_open,x
        bne *+5
        jmp @x
        lda lo_s0,x
        cmp lnser
        beq *+5
        jmp @x
        lda lo_s1,x
        cmp lnser+1
        beq *+5
        jmp @x
        lda lo_ev,x             ; its on event still queued: re-pitch
        cmp #$FF
        beq @ring
        lda lo_t0,x
        sta FT
        lda lo_t1,x
        sta FT+1
        stx T8
        jsr chord_at
        ldy T8
        lda lo_n,y
        jsr snap
        ldx T8
        sta lo_n,x
        ldy lo_ev,x
        sec
        sbc #BIAS
        sta qa,y
@ring:  lda #4                  ; ring = max(d, min(p_end - t, d + pick))
        jsr below
        tay
        ldx lntr
        clc
        lda lo_d0,x
        adc ringd,y
        sta tmp16
        lda lo_d1,x
        adc #0
        sta tmp16+1
        sec
        lda p_end
        sbc lo_t0,x
        sta tmp16b
        lda p_end+1
        sbc lo_t1,x
        sta tmp16b+1
        lda tmp16b              ; min
        cmp tmp16
        lda tmp16b+1
        sbc tmp16+1
        bcs @m
        lda tmp16b
        sta tmp16
        lda tmp16b+1
        sta tmp16+1
@m:     lda tmp16               ; ring = max with d
        cmp lo_d0,x
        lda tmp16+1
        sbc lo_d1,x
        bcs @r1
        lda lo_d0,x
        sta tmp16
        lda lo_d1,x
        sta tmp16+1
@r1:    lda tmp16               ; d = max(d, fits_until(t, ring, n))
        sta fu_d
        lda tmp16+1
        sta fu_d+1
        lda lo_t0,x
        sta FT
        lda lo_t1,x
        sta FT+1
        lda lo_n,x
        jsr fits_until
        ldx lntr
        lda fu_d
        cmp lo_d0,x
        lda fu_d+1
        sbc lo_d1,x
        bcc @k
        lda fu_d
        sta lo_d0,x
        lda fu_d+1
        sta lo_d1,x
@k:     jsr rec_patch
        ldx lntr
        lda lo_n,x
        cpx #COMP2              ; a traded note sounded an octave down
        bne @lp
        clc
        adc #12
@lp:    sta lprev
@x:     lda #0
        sta phhas
        rts
ringd:  .byte 0,6,12,24

.segment "JAMCODE2"             ; (room in the player's MAIN)
rec_add:                        ; X = track of the new lead note -> the record
        ldy hn
        cpy #HMAX
        bcs @x
        sec
        lda lo_t0,x
        sbc hu0
        sta hr_t0,y
        lda lo_t1,x
        sbc hu0+1
        sta hr_t1,y
        lda lo_d0,x
        sta hr_d0,y
        lda lo_d1,x
        sta hr_d1,y
        lda lo_n,x
        sta hr_n,y
        lda lo_s0,x
        sta hr_ser0,y
        lda lo_s1,x
        sta hr_ser1,y
        inc hn
        ldy hletter
        tya
        tax
        inc hcount,x
@x:     rts

rec_patch:                      ; lnotes[-1] changed: fix its record if in this unit
        lda hrec
        beq @x
        ldy hn
        beq @x
        dey
        lda hr_ser0,y
        cmp lnser
        bne @x
        lda hr_ser1,y
        cmp lnser+1
        bne @x
        ldx hletter             ; only the unit being recorded
        lda hcount,x
        beq @x
        ldx lntr
        lda lo_d0,x
        sta hr_d0,y
        lda lo_d1,x
        sta hr_d1,y
        lda lo_n,x
        sta hr_n,y
@x:     rts

.segment "JAMCODE"

; ---- the head: record each plan letter once, replay it after -------------
head_bar:
        lda sbar                ; u, ub = divmod(sbar, unit)
        sta DVD
        lda #0
        sta DVD+1
        lda unit
        jsr div16
        sta T8                  ; ub
        lda nbars               ; u < max(1, nbars div unit) ?
        ldx #0
@q:     cmp unit
        bcc @qd
        sbc unit
        inx
        bne @q
@qd:    txa
        bne @q1
        lda #1
@q1:    cmp DVD
        beq @none
        bcs @ok
@none:  rts
@ok:    lda DVD                 ; letter = plan[u mod plen]
@lm:    cmp plen
        bcc @lm2
        sbc plen
        bcs @lm
@lm2:   tax
        lda plan,x
        sta hletter
        lda DVD                 ; U0 = sec0 + u * unit * 48
        ldx unit
        jsr mul8
        lda ML
        ldx #BARL
        jsr mul8
        sta hu0+1
        lda ML
        clc
        adc sec0
        sta hu0
        lda hu0+1
        adc sec0+1
        sta hu0+1
        lda T8
        bne @mid
        ldx hletter             ; a unit starts: record it, or replay it
        lda hhave,x
        beq @rec
        lda #0
        sta hrec
        beq @mid
@rec:   lda #1
        sta hrec
        lda hn
        sta hstart,x
        lda #0
        sta hcount,x
        lda hu0
        sta lt
        sta p_end
        lda hu0+1
        sta lt+1
        sta p_end+1
        lda #0
        sta riffon
        sta lrv
        sta ltr
@mid:   lda hrec
        beq @play
        clc                     ; lead_bar(B0, B0 + 48, U0 + unit * 48)
        lda tick
        adc #BARL
        sta bnext
        lda tick+1
        adc #0
        sta bnext+1
        lda unit
        ldx #BARL
        jsr mul8
        sta s_end+1
        lda ML
        clc
        adc hu0
        sta s_end
        lda s_end+1
        adc hu0+1
        sta s_end+1
        lda T8
        pha
        jsr lead_bar
        pla
        clc
        adc #1
        cmp unit
        bne @x
        ldx hletter             ; the unit is done: keep it
        lda #1
        sta hhave,x
        lda #0
        sta hrec
@x:     rts
@play:  lda T8                  ; replay notes with ub*48 <= tk < (ub+1)*48
        ldx #BARL
        jsr mul8
        sta tmp16b+1
        lda ML
        sta tmp16b
        ldx hletter
        lda hcount,x
        sta T7
        beq @x
        lda hstart,x
        sta T6
@pn:    ldy T6
        lda hr_t0,y
        sec
        sbc tmp16b
        sta T0
        lda hr_t1,y
        sbc tmp16b+1
        beq *+5
        jmp @skip
        lda T0
        cmp #BARL
        bcc *+5
        jmp @skip
        clc                     ; t = U0 + tk
        lda hu0
        adc hr_t0,y
        sta TK
        lda hu0+1
        adc hr_t1,y
        sta TK+1
        lda hr_d0,y
        sta TD
        lda hr_d1,y
        sta TD+1
        lda hr_n,y
        sta T8
        lda TK                  ; the chord it now plays over
        sta FT
        lda TK+1
        sta FT+1
        jsr chord_at
        stx T5
        lda haskc               ; re-harmonise on the beat
        bne @lg
        ldy T6
        lda hr_t0,y
        sta DVD
        lda hr_t1,y
        sta DVD+1
        lda #TPB
        jsr div16
        cmp #0
        bne @lg
        ldx T5
        lda T8
        jsr snap
        sta T8
@lg:    ldx T5                  ; off its scale: snap (no written approach here)
        lda T8
        jsr allowed
        bne @nsn
        ldx T5
        lda T8
        jsr snap
        sta T8
@nsn:   lda TK                  ; released early at a clashing chord
        sta FT
        lda TK+1
        sta FT+1
        lda TD
        sta fu_d
        lda TD+1
        sta fu_d+1
        lda T8
        jsr fits_until
        lda fu_d
        sta TD
        lda fu_d+1
        sta TD+1
        lda TK
        sta FT
        lda TK+1
        sta FT+1
        jsr accent
        ldx #LEAD
        jsr set_level
        ldy #ST_LEAD_GAP
        lda (STYP),y
        sta TG
        lda #LEAD
        sta TR
        lda T8
        jsr note
        ldx #LEAD
        lda lo_n,x
        sta lprev
        lda #1
        sta lpv
@skip:  inc T6
        dec T7
        beq *+5
        jmp @pn
        rts

; ===========================================================================
; bass
; ---------------------------------------------------------------------------
bass_range:
        ldy #ST_BASS_LO
        lda (STYP),y
        clc
        adc #BIAS
        sta NLO
        iny
        lda (STYP),y
        clc
        adc #BIAS
        sta NHI
        rts

bass_bar:
        jsr bass_range
        lda blv
        bne @p
        lda NLO
        clc
        adc #5
        sta blast
@p:     ldy #ST_BASS_GAP
        lda (STYP),y
        sta TG
        lda #BASS
        sta TR
        lda sflags
        and #F_WALK
        beq @pat
        jmp walk_bar
@pat:   ldy #SE_BASS            ; patterns
        lda (SECP),y
        sta GP
        iny
        lda (SECP),y
        sta GP+1
        lda bpatv
        bne @c
        jsr pick_pat
        sta bpat
        stx bpat+1
        lda #1
        sta bpatv
@c:     jsr rng_byte
        ldy #ST_BASS_CHANGE
        cmp (STYP),y
        bcs @go
        ldy #SE_BASS
        lda (SECP),y
        sta GP
        iny
        lda (SECP),y
        sta GP+1
        jsr pick_pat
        sta bpat
        stx bpat+1
@go:    lda bpat
        sta PATP
        lda bpat+1
        sta PATP+1
        ldy #0
        lda (PATP),y
        sta T7                  ; entries
        lda #1
        sta T6                  ; Y of the entry
bloop:  ldy T6
        lda (PATP),y            ; t = B0 + tick
        clc
        adc tick
        sta TK
        lda tick+1
        adc #0
        sta TK+1
        iny
        lda (PATP),y
        sta TD
        lda #0
        sta TD+1
        iny
        lda (PATP),y
        sta T5                  ; code
        lda TK
        sta FT
        lda TK+1
        sta FT+1
        jsr chord_at
        stx T4                  ; c
        lda blast               ; root = nearest(degree(0), prev | lo + 7)
        ldy T5
        cpy #$80
        bne @rt
        lda NLO
        clc
        adc #7
@rt:    sta NTG
        lda NLO
        sta NB
        lda #0
        ldx T4
        jsr degree
        jsr nearest
        sta T8                  ; root
        lda T5
        bmi @code
        clc                     ; int: root + semitones
        adc T8
        jmp bput
@code:  and #$7F
        asl a
        tax
        lda bcode+1,x
        pha
        lda bcode,x
        pha
        rts
bput:   sta wn
        lda T6
        pha
        lda T7
        pha
        lda wn
        jsr note
        pla
        sta T7
        pla
        sta T6
        lda wn
        sta blast
        lda #1
        sta blv
        lda T6
        clc
        adc #3
        sta T6
        dec T7
        beq *+5
        jmp bloop
        rts
bcode:  .word bc_r-1, bc_5-1, bc_l-1, bc_8-1, bc_3-1, bc_7-1, bc_a-1, bc_s-1
bc_r:   lda T8
        jmp bput
bc_5:   lda T8                  ; root + 7 <= hi ? root + 7 : root - 5
        clc
        adc #7
        cmp NHI
        beq @k
        bcc @k
        lda T8
        sec
        sbc #5
@k:     jmp bput
bc_l:   lda T8                  ; root - 5 >= lo ? root - 5 : root + 7
        sec
        sbc #5
        cmp NLO
        bcs @k
        lda T8
        clc
        adc #7
@k:     jmp bput
bc_8:   lda T8
        clc
        adc #12
        cmp NHI
        beq @k
        bcc @k
        lda T8
@k:     jmp bput
bc_3:   ldx T4
        lda ch_tlo,x
        sta GP3
        lda ch_thi,x
        sta GP3+1
        ldy #2
        lda (GP3),y
        clc
        adc T8
        jmp bput
bc_7:   ldx T4                  ; root + (tones[3] | 12) - 12 * (root + 10 > hi)
        lda ch_tlo,x
        sta GP3
        lda ch_thi,x
        sta GP3+1
        ldy #0
        lda (GP3),y
        cmp #4
        bcc @n12
        ldy #4
        lda (GP3),y
        jmp @a
@n12:   lda #12
@a:     clc
        adc T8
        sta T3
        lda T8
        clc
        adc #10
        cmp NHI
        beq @k
        bcc @k
        lda T3
        sec
        sbc #12
        sta T3
@k:     lda T3
        jmp bput
bc_a:   jsr next_change         ; nearest(next root, root) + pick(-1 1 -2)
        lda T8
        sta NTG
        lda NLO
        sta NB
        lda #0
        ldx nc_c
        jsr degree
        jsr nearest
        sta T3
        lda #3
        jsr below
        tax
        lda T3
        clc
        adc bca,x
        jmp bput
bca:    .byte $FF,1,$FE
bc_s:   lda #4                  ; degree(pick(1 2 4 6), root - 1)
        jsr below
        tax
        lda T8
        sec
        sbc #1
        sta NB
        lda bcs_,x
        ldx T4
        jsr degree
        jmp bput
bcs_:   .byte 1,2,4,6

pick_pat:                       ; (GP) word list -> A/X = random pattern
        jsr pickw
        lda GP
        ldx GP+1
        rts

walk_bar:                       ; four beats of walking bass
        lda #0
        sta T7                  ; beat
@b:     lda T7                  ; t = B0 + beat * 12
        asl a
        asl a
        sta T0
        asl a
        clc
        adc T0
        adc tick
        sta TK
        lda tick+1
        adc #0
        sta TK+1
        lda #TPB
        sta TD
        lda #0
        sta TD+1
        lda TK
        sta FT
        lda TK+1
        sta FT+1
        jsr chord_at
        stx T4                  ; c
        jsr next_change         ; nc_t, nc_c
        lda blast               ; root = nearest(degree(c, 0), prev)
        sta NTG
        lda NLO
        sta NB
        lda #0
        ldx T4
        jsr degree
        jsr nearest
        sta T8
        lda T7
        beq @first
        sec                     ; chord_at(t - 12) != c ?
        lda TK
        sbc #TPB
        sta FT
        lda TK+1
        sbc #0
        sta FT+1
        jsr chord_at
        cpx T4
        bne @first
        sec                     ; nt - t == 12 ?
        lda nc_t
        sbc TK
        sta T0
        lda nc_t+1
        sbc TK+1
        bne @walk
        lda T0
        cmp #TPB
        bne @walk
        jsr tgt                 ; approach the next root
        lda #7
        jsr below
        tax
        lda T3
        clc
        adc wapp,x
        jmp @put
@first: jsr rng_byte            ; root (85%) or the third
        cmp #217
        bcs @third
        lda T8
        jmp @put
@third: lda blast
        sta NTG
        lda NLO
        sta NB
        lda #2
        ldx T4
        jsr degree
        jsr nearest
        jmp @put
@walk:  jsr tgt                 ; scale steps toward the next root
        ldx #1
        lda T3
        cmp blast
        beq @dn
        bcs @up
@dn:    ldx #$FF
@up:    stx T5                  ; step
        lda #3
        jsr below
        tax
        lda wd,x
        sta T6                  ; d
        lda blast
        sta T3                  ; cand
@st:    lda T3
        clc
        adc T5
        sta T3
        ldx T4
        jsr inscale
        beq @st
        dec T6
        bne @st
        lda T3
@put:   sta NN                  ; n = nearest(n, prev)
        lda blast
        sta NTG
        lda NN
        jsr nearest
        sta wn
        lda T7
        pha
        lda wn
        jsr note
        pla
        sta T7
        lda wn
        sta blast
        lda #1
        sta blv
        inc T7
        lda T7
        cmp #4
        beq @x
        jmp @b
@x:     rts
wapp:   .byte $FF,1,$FF,1,2,$FE,$FB
wd:     .byte 1,2,2

tgt:                            ; T3 = nearest(degree(next chord, 0), prev)
        lda blast
        sta NTG
        lda NLO
        sta NB
        lda #0
        ldx nc_c
        jsr degree
        jsr nearest
        sta T3
        rts

; ===========================================================================
; comping
; ---------------------------------------------------------------------------
comp_bar:
        ldy #ST_COMP_LO
        lda (STYP),y
        clc
        adc #BIAS
        sta NLO
        iny
        lda (STYP),y
        clc
        adc #BIAS
        sta NHI
        ldy #SE_COMP
        lda (SECP),y
        sta GP
        iny
        lda (SECP),y
        sta GP+1
        lda cpatv
        bne @c
        jsr pick_pat
        sta cpat
        stx cpat+1
        lda #1
        sta cpatv
@c:     jsr rng_byte
        ldy #ST_COMP_CHANGE
        cmp (STYP),y
        bcs @go
        ldy #SE_COMP
        lda (SECP),y
        sta GP
        iny
        lda (SECP),y
        sta GP+1
        jsr pick_pat
        sta cpat
        stx cpat+1
@go:    lda cpat
        sta PATP
        lda cpat+1
        sta PATP+1
        ldy #0
        lda (PATP),y
        sta T7
        lda #1
        sta T6
@e:     ldy T6
        lda (PATP),y
        clc
        adc tick
        sta TK
        lda tick+1
        adc #0
        sta TK+1
        iny
        lda (PATP),y
        sta TD
        lda #0
        sta TD+1
        iny
        lda (PATP),y
        sta T5                  ; what
        lda T6
        pha
        lda T7
        pha
        jsr comp_hit
        pla
        sta T7
        pla
        clc
        adc #3
        sta T6
        dec T7
        bne @e
        rts

comp_hit:
        lda TK
        sta FT
        lda TK+1
        sta FT+1
        jsr chord_at
        stx T4
        lda ch_tlo,x
        sta GP3
        lda ch_thi,x
        sta GP3+1
        ldy #ST_VOICING         ; the pair of intervals
        lda (STYP),y
        cmp #1
        bne @nt
        ldy #0
        lda (GP3),y
        cmp #4
        bcc @tri
        ldy #2                  ; guide tones: 3rd and 7th
        lda (GP3),y
        sta T0
        ldy #4
        lda (GP3),y
        sta T1
        jmp @vo
@nt:    cmp #2
        beq @pow
        cmp #3
        bne @tri
        ldy #0                  ; shell: 5th and 7th (no 3rd: a blues
        lda (GP3),y             ;  soloist's b3 is free); triads: root, 5th
        cmp #4
        bcc @pow
        ldy #3
        lda (GP3),y
        sta T0
        ldy #4
        lda (GP3),y
        sta T1
        jmp @vo
@pow:   lda #0
        sta T0
        lda #7
        sta T1
        jmp @vo
@tri:   ldy #2
        lda (GP3),y
        sta T0
        iny
        lda (GP3),y
        sta T1
@vo:    ldx #0                  ; each voice: nearest to its last
@v:     stx T3
        lda T0,x
        ldx T4
        clc
        adc ch_root,x
        tay
        lda mod12,y             ; base pc
        sta T2
        ldy NLO                 ; lo + ((base - lo) mod 12)
        lda mod12,y
        sta dg_t
        lda T2
        sec
        sbc dg_t
        bcs @bp
        adc #12
@bp:    clc
        adc NLO
        sta T2
        ldx T3                  ; ref
        lda cvld,x
        beq @def
        lda clast,x
        jmp @r
@def:   lda NLO
        clc
        adc NHI
        ror a
        cpx #0
        beq @r
        clc
        adc #3
@r:     sta NTG
        lda T2
        jsr nearest
        ldx T3
        sta vs0,x
        inx
        cpx #2
        bne @v
        lda vs0                 ; equal -> move the upper an octave
        cmp vs1
        bne @so
        clc
        adc #12
        cmp NHI
        beq @up
        bcc @up
        lda vs1
        sec
        sbc #12
        jmp @st
@up:    lda vs1
        clc
        adc #12
@st:    sta vs1
@so:    lda vs1                 ; sort
        cmp vs0
        bcs @sd
        ldx vs0
        sta vs0
        stx vs1
@sd:    lda vs0
        sta clast
        lda vs1
        sta clast+1
        lda #1
        sta cvld
        sta cvld+1
        lda vs0                 ; both comping voices are 8-bit
        jsr fix8
        sta vs0
        lda vs1
        jsr fix8
        sta vs1
        ldy #ST_COMP_GAP
        lda (STYP),y
        sta TG
        lda T5
        cmp #2
        beq @arp
        lda #COMP1
        sta TR
        lda vs0
        jsr note
        lda T5
        cmp #1
        beq @x
        lda TK                  ; voice 4 answering: no second voice
        cmp rw0
        lda TK+1
        sbc rw0+1
        bcc @v2
        lda TK
        cmp rw1
        lda TK+1
        sbc rw1+1
        bcc @x
@v2:    lda TK
        sta FT
        lda TK+1
        sta FT+1
        ldy #ST_MIX3
        lda (STYP),y
        bne @m3
        lda #15
@m3:    ldx #COMP2
        jsr set_level
        lda #COMP2
        sta TR
        lda vs1
        jmp note
@x:     rts
@arp:   lda TD                  ; dur // 3 sixteenths: v0 v1 v0+12 v1
        ldx #0
@a3:    cmp #3
        bcc @a4
        sbc #3
        inx
        bne @a3
@a4:    stx T7
        cpx #0
        beq @x
        lda vs0                 ; the third step: an octave up if it fits
        clc
        adc #12
        cmp #V8HI+BIAS
        beq @au
        bcc @au
        lda vs0
        sec
        sbc #12
        bcc @av
        cmp NLO
        bcs @au
@av:    lda vs1
@au:    sta aup
        lda #0
        sta T6
        lda #3
        sta TD
        lda #1
        sta TG
        lda #COMP1
        sta TR
@al:    lda T6
        and #3
        tax
        lda vs0
        cpx #1
        bne @a5
        lda vs1
@a5:    cpx #3
        bne @a6
        lda vs1
@a6:    cpx #2
        bne @a7
        lda aup
@a7:    jsr note
        clc
        lda TK
        adc #3
        sta TK
        bcc @a8
        inc TK+1
@a8:    inc T6
        dec T7
        bne @al
        rts

; ===========================================================================
; drums
; ---------------------------------------------------------------------------
drum_bar:
        ldy #SE_DRUMS
        lda (SECP),y
        sta GP
        iny
        lda (SECP),y
        sta GP+1
        lda dpatv
        bne @c
        jsr pick_pat
        sta dpat
        stx dpat+1
        lda #1
        sta dpatv
@c:     lda sbar                ; bar and bar % 4 == 0 and rng < change
        beq @k
        and #3
        bne @k
        jsr rng_byte
        ldy #ST_DR_CHANGE
        cmp (STYP),y
        bcs @k
        ldy #SE_DRUMS
        lda (SECP),y
        sta GP
        iny
        lda (SECP),y
        sta GP+1
        jsr pick_pat
        sta dpat
        stx dpat+1
@k:     lda dpat                ; use = the pattern
        sta PATP
        lda dpat+1
        sta PATP+1
        jsr use_pat
        lda sbar                ; the phrase's last bar: maybe a fill
        clc
        adc #1
        and #3
        beq @last
        ldx sbar
        inx
        cpx nbars
        bne @play
@last:  ldy #ST_FILLS
        jsr stw
        ldy #0
        lda (GP),y
        beq @play
        lda dboost              ; fill odds + max(0, boost) * 3
        bpl @fb
        lda #0
@fb:    sta T0
        asl a
        clc
        adc T0
        ldy #ST_DR_FILL
        clc
        adc (STYP),y
        bcc @fb2
        lda #255
@fb2:   sta T0
        jsr rng_byte
        cmp T0
        bcs @play
        ldy #ST_FILLS
        jsr stw
        jsr pickw
        lda GP                  ; unpack it: fbuf = count, then entries
        sta PATP
        lda GP+1
        sta PATP+1
        lda #<(fbuf+1)
        sta GP3
        lda #>(fbuf+1)
        sta GP3+1
        jsr expand
        sta fbuf
        lda #<fbuf
        sta GP2
        lda #>fbuf
        sta GP2+1
        jsr use_fill
@play:  lda #0
        sta dhn
        sta T7                  ; drum index in use
@d:     lda T7
        cmp dnum
        beq @cr
        asl a                   ; *17
        asl a
        asl a
        asl a
        adc T7
        sta T6
        tax
        lda duse,x
        sta T5                  ; drum id
        lda #0
        sta T4                  ; step
@s:     lda T6
        clc
        adc T4
        tax
        lda duse+1,x
        beq @n
        cmp #255
        beq @hit
        ldx dboost              ; odds + boost, kept in 1..254
        bmi @neg
        clc
        adc dboost
        bcs @hi
        cmp #255
        bcc @ok
@hi:    lda #254
        bne @ok
@neg:   clc
        adc dboost
        bcc @lo                 ; went below 0
        bne @ok
@lo:    lda #1
@ok:    sta T3
        jsr rng_byte
        cmp T3
        bcs @n
@hit:   ldx dhn                 ; collect: step, drum
        cpx #DHMAX
        bcs @n
        lda T4
        sta dh_s,x
        lda T5
        sta dh_d,x
        tay
        lda drumch,y
        sta dh_c,x
        inc dhn
@n:     inc T4
        lda T4
        cmp #16
        bne @s
        inc T7
        bne @d
@cr:    ldy #ST_DSPLIT
        lda (STYP),y
        beq @em
        jsr dsplit
@em:    ldx #0                  ; send them, in the order they were rolled
@e:     cpx dhn
        beq @cr2
        stx T7
        lda dh_s,x              ; t = B0 + step * 3
        sta T3
        asl a
        adc T3
        clc
        adc tick
        sta FT
        lda tick+1
        adc #0
        sta FT+1
        lda dh_c,x
        tay
        lda dh_d,x
        jsr drumx
        ldx T7
        inx
        bne @e
@cr2:   lda sflags
        and #F_CRASH
        beq @x
        lda sbar
        bne @x
        lda tick
        sta FT
        lda tick+1
        sta FT+1
        lda #7
        jmp drum
@x:     rts

use_pat:                        ; (PATP) -> duse, dnum
        lda #<duse
        sta GP3
        lda #>duse
        sta GP3+1
        jsr expand
        sta dnum
        rts

; expand: packed pattern (PATP) -> 17-byte drum entries at (GP3); A = count
; packed: count, then per drum: id, 8 bytes of two 4-bit odds (step 2i in the
; high nibble), odds 0 never, 1-9 tenths, 10 always
expand:
        ldy #0
        lda (PATP),y
        sta T0                  ; drums left
        pha
        lda #1
        sta T1                  ; source index
        lda #0
        sta T2                  ; dest index
@d:     lda T0
        beq @x
        ldy T1
        lda (PATP),y
        ldy T2
        sta (GP3),y
        inc T1
        inc T2
        lda #8
        sta T3
@b:     ldy T1
        lda (PATP),y
        pha
        lsr a
        lsr a
        lsr a
        lsr a
        tax
        lda dodds,x
        ldy T2
        sta (GP3),y
        iny
        pla
        and #$0F
        tax
        lda dodds,x
        sta (GP3),y
        iny
        sty T2
        inc T1
        dec T3
        bne @b
        dec T0
        jmp @d
@x:     pla
        rts

; fill (GP2): drums not in the fill keep their first half (second half
; silent); then each fill drum: the pattern's first half + the fill's second
use_fill:
        lda dnum
        sta T8                  ; pattern drums (duse holds the pattern)
        ldx #0                  ; copy the pattern aside into cnt
@cp:    lda duse,x
        sta cnt,x
        inx
        cpx #8*17
        bne @cp
        lda #0
        sta dnum
        sta T7                  ; pattern drum index
@pd:    lda T7
        cmp T8
        beq @fd
        jsr pd_off              ; X = its offset in cnt
        lda cnt,x
        jsr in_fill
        bcs @nx                 ; the fill has it
        jsr d_new               ; Y = new entry offset
        ldx T0
        lda cnt,x
        sta duse,y
        lda #8
        sta T6
@h1:    inx
        iny
        lda cnt,x
        sta duse,y
        dec T6
        bne @h1
        lda #8
        sta T6
        lda #0
@h2:    iny
        sta duse,y
        dec T6
        bne @h2
@nx:    inc T7
        bne @pd
@fd:    ldy #0                  ; fill drums
        lda (GP2),y
        sta T5
        lda #1
        sta T4                  ; Y into the fill
@fl:    lda T5
        beq @x
        jsr d_new
        sty T3
        ldy T4
        lda (GP2),y
        ldy T3
        sta duse,y
        jsr pat_has             ; X = offset in cnt, or C clear
        ldy T3
        bcc @z
        lda #8
        sta T6
@f1:    inx
        iny
        lda cnt,x
        sta duse,y
        dec T6
        bne @f1
        jmp @f2
@z:     lda #8
        sta T6
        lda #0
@f0:    iny
        sta duse,y
        dec T6
        bne @f0
@f2:    lda #8                  ; the fill's second half
        sta T6
        lda T4
        clc
        adc #9
        sta T4
@f3:    sty T3
        ldy T4
        lda (GP2),y
        ldy T3
        iny
        sta duse,y
        inc T4
        dec T6
        bne @f3
        dec T5
        jmp @fl
@x:     rts

pd_off:                         ; T7 -> X = T7 * 17 (also T0)
        lda T7
        asl a
        asl a
        asl a
        asl a
        clc
        adc T7
        sta T0
        tax
        rts

d_new:                          ; Y = offset of a new duse entry
        lda dnum
        asl a
        asl a
        asl a
        asl a
        clc
        adc dnum
        tay
        inc dnum
        rts

in_fill:                        ; A = drum -> C set if the fill (GP2) has it
        sta T2
        ldy #0
        lda (GP2),y
        sta T3
        ldy #1
@l:     lda T3
        beq @no
        lda (GP2),y
        cmp T2
        beq @yes
        tya
        clc
        adc #17
        tay
        dec T3
        jmp @l
@no:    clc
        rts
@yes:   sec
        rts

pat_has:                        ; A = drum -> X = offset in cnt, C set if found
        sta T2
        ldx #0
        lda T8
        sta T1
@l:     lda T1
        beq @no
        lda cnt,x
        cmp T2
        beq @yes
        txa
        clc
        adc #17
        tax
        dec T1
        jmp @l
@no:    clc
        rts
@yes:   sec
        rts

; ===========================================================================
.segment "JAMCODE2"             ; (POKEY JAM: the player's MAIN)
intensity:                      ; I for this bar; the swell starts at its cap
        lda sflags
        and #F_BUILD
        beq @en
        lda sbar                ; ARC[sbar * 16 // nbars]
        sta DVD
        lda #0
        sta DVD+1
        ldx #4
@m:     asl DVD
        rol DVD+1
        dex
        bne @m
        lda nbars
        jsr div16
        ldx DVD
        lda arc16,x
        jmp @s
@en:    ldy #SE_ENERGY
        lda (SECP),y
@s:     sta intens
        sec                     ; drum odds shift: (I - 10) * 6
        sbc #10
        sta T0
        asl a
        clc
        adc T0
        asl a
        sta dboost
        lda dynv
        bne @x
        jsr cap
        sta dyn
        lda #1
        sta dynv
@x:     rts

cap:                            ; A = min(LVL[I], the style's lead mix level)
        ldx intens
        lda lvl16,x
        sta cp_t
        ldy #ST_MIX0
        lda (STYP),y
        beq @f
        cmp cp_t
        bcc @x
@f:     lda cp_t
@x:     rts

set_level:                      ; A = level, X = track, FT = tick
        cmp jlastlv,x
        beq @x
        sta jlastlv,x
        sta T2
        txa
        ora #$50
        sta T1
        jmp ctl
@x:     rts

accent:                         ; TK -> A = min(15, dyn + 2 on beats 1 and 3)
        lda TK
        sta DVD
        lda TK+1
        sta DVD+1
        lda #24
        jsr div16
        cmp #0
        bne @n
        lda dyn
        clc
        adc #2
        cmp #13                 ; the lead peaks at 12: a guest in the band
        bcc @x
        lda #12
        rts
@n:     lda dyn
@x:     rts

; dsplit: a drum hit again within two 16ths goes to the other POKEY's drum
; channel when that one is free at this step and the one before
dsplit:
        lda #0
        sta dbz0
        sta dbz0+1
        sta dbz1
        sta dbz1+1
        ldx #7
        lda #$FF
@l:     sta ld_s,x
        dex
        bpl @l
        lda #0
        sta T4                  ; step
@st:    ldx #0
@k:     cpx dhn
        beq @ns
        lda dh_s,x
        cmp T4
        bne @nk
        ldy dh_d,x              ; same drum within two steps, same channel?
        lda ld_s,y
        cmp #$FF
        beq @set
        lda T4
        sec
        sbc ld_s,y
        cmp #3
        bcs @set
        lda ld_c,y
        cmp dh_c,x
        bne @set
        eor #1                  ; the other channel: free now and a step ago?
        sta T3
        jsr busy_at
        bne @set
        lda dh_c,x
        eor #1
        sta dh_c,x
@set:   jsr mark
        ldy dh_d,x
        lda T4
        sta ld_s,y
        lda dh_c,x
        sta ld_c,y
@nk:    inx
        bne @k
@ns:    inc T4
        lda T4
        cmp #16
        bne @st
        rts

busy_at:                        ; T3 = channel -> Z clear if busy at T4 or T4-1
        stx T2
        lda T4
        jsr bit16
        bne @x
        lda T4
        beq @x
        sec
        sbc #1
        jsr bit16
@x:     php
        ldx T2
        plp
        rts

bit16:                          ; A = step, T3 = channel -> A = that bit (Z)
        tay
        lda T3
        bne @c1
        cpy #8
        bcs @h0
        lda bitlo,y
        and dbz0
        rts
@h0:    lda bitlo-8,y
        and dbz0+1
        rts
@c1:    cpy #8
        bcs @h1
        lda bitlo,y
        and dbz1
        rts
@h1:    lda bitlo-8,y
        and dbz1+1
        rts

mark:                           ; X = hit: its channel busy at its step
        ldy T4
        lda dh_c,x
        bne @m1
        cpy #8
        bcs @a
        lda bitlo,y
        ora dbz0
        sta dbz0
        rts
@a:     lda bitlo-8,y
        ora dbz0+1
        sta dbz0+1
        rts
@m1:    cpy #8
        bcs @b
        lda bitlo,y
        ora dbz1
        sta dbz1
        rts
@b:     lda bitlo-8,y
        ora dbz1+1
        sta dbz1+1
        rts

; phrase_kind: after new_phrase -- riffs (a call), voice 4's answer, or a
; quote of the theme's first letter
phrase_kind:
        lda lcall
        sta pk_call
        lda phrv
        sta pk_prev
        lda phr_ri
        sta pk_ri
        lda phr_tr
        sta pk_tr
        lda #0
        sta lcall
        sta phrv
        sta qon
        sta resp
        lda sflags
        and #F_TRADE
        beq *+5
        jmp @call
        lda hrec
        beq *+5
        jmp @call
        ldy #SE_RESP            ; an answer?
        lda (SECP),y
        beq @q
        lda pk_call
        beq @q
        lda pk_prev
        beq @q
        jsr rng_byte
        ldy #SE_RESP
        cmp (SECP),y
        bcs @q
        lda #1
        sta resp
        lda lt
        sta rw0
        lda lt+1
        sta rw0+1
        lda p_end
        sta rw1
        lda p_end+1
        sta rw1+1
        ldy #ST_TRADE_PRESETS   ; its own sound (else one of the lead's)
        jsr stw
        ldy #0
        lda (GP),y
        bne @tp
        ldy #ST_LEAD_PRESETS
        jsr stw
@tp:    jsr pick
        sta T2
        lda #$30|COMP2
        sta T1
        lda lt
        sta FT
        lda lt+1
        sta FT+1
        jsr ctl
        lda p_end               ; voice 4 goes back to comping after it
        sta FT
        lda p_end+1
        sta FT+1
        lda #$30|COMP2
        sta T1
        lda inst+3
        sta T2
        jsr ctl
        lda #1
        sta forcev
        lda pk_ri
        sta force_ri
        lda pk_tr
        sta force_tr
        rts
@q:     ldy #SE_QUOTE           ; a quote?
        lda (SECP),y
        bne *+5
        jmp @call
        ldx plan
        lda hhave,x
        bne *+5
        jmp @call
        lda hcount,x
        bne *+5
        jmp @call
        jsr rng_byte
        ldy #SE_QUOTE
        cmp (SECP),y
        bcc *+5
        jmp @call
        lda unit                ; qb: a bar of the theme
        jsr below
        pha
        ldx #BARL               ; lo = qb * 48, hi = (qb + pb) * 48
        jsr mul8
        sta qlo+1
        lda ML
        sta qlo
        pla
        clc
        adc pbv
        ldx #BARL
        jsr mul8
        sta qhi+1
        lda ML
        sta qhi
        sec                     ; qoff = t - lo
        lda lt
        sbc qlo
        sta qoff
        lda lt+1
        sbc qlo+1
        sta qoff+1
        ldx plan                ; the records in [lo, hi)
        lda hstart,x
        sta q_ptr
        clc
        adc hcount,x
        sta T7                  ; end of the letter
@f1:    ldy q_ptr
        cpy T7
        beq @f2
        lda hr_t0,y
        cmp qlo
        lda hr_t1,y
        sbc qlo+1
        bcs @f2
        inc q_ptr
        bne @f1
@f2:    lda q_ptr
        sta q_end
@f3:    ldy q_end
        cpy T7
        beq @f4
        lda hr_t0,y
        cmp qhi
        lda hr_t1,y
        sbc qhi+1
        bcs @f4
        inc q_end
        bne @f3
@f4:    lda #1
        sta qon
        ldy q_ptr
        cpy q_end
        beq @x
        lda lprev               ; the quote's octave: its first note near the line
        sta NTG
        lda hr_n,y
        sta T8
        jsr nearest
        sec
        sbc T8
        sta qshift
@x:     rts
@call:  lda #1
        sta lcall
        rts

; quote_note: the next note of the quoted slice, re-harmonised
quote_note:
        lda q_ptr
        cmp q_end
        bcc @have
        lda p_stop              ; quoted all: breathe
        sta lt
        lda p_stop+1
        sta lt+1
        rts
@have:  ldy q_ptr
        clc                     ; tq = its tick + qoff
        lda hr_t0,y
        adc qoff
        sta TK
        lda hr_t1,y
        adc qoff+1
        sta TK+1
        lda TK                  ; tq >= B1: next bar
        cmp bnext
        lda TK+1
        sbc bnext+1
        bcc @b
        lda TK
        sta lt
        lda TK+1
        sta lt+1
        rts
@b:     lda TK                  ; tq >= p_stop: breathe
        cmp p_stop
        lda TK+1
        sbc p_stop+1
        bcc @go
        lda p_stop
        sta lt
        lda p_stop+1
        sta lt+1
        rts
@go:    inc q_ptr
        lda hr_d0,y
        sta qdd
        lda hr_d1,y
        sta qdd+1
        lda hr_n,y
        clc
        adc qshift
        sta T8
        jsr rng_byte
        cmp resteff
        bcs *+5
        jmp @skip
        lda TK
        sta FT
        lda TK+1
        sta FT+1
        jsr chord_at
        stx qch
        ldy #ST_SNAP            ; strong beats land on chord tones
        lda (STYP),y
        beq @ns
        cmp #1
        beq @s24
        lda #TPB
        bne @sd
@s24:   lda #24
@sd:    pha
        lda TK
        sta DVD
        lda TK+1
        sta DVD+1
        pla
        jsr div16
        cmp #0
        bne @ns
        ldx qch
        lda T8
        jsr snap
        sta T8
@ns:    sec                     ; d = min(dd, p_stop - tq)
        lda p_stop
        sbc TK
        sta TD
        lda p_stop+1
        sbc TK+1
        sta TD+1
        lda qdd
        cmp TD
        lda qdd+1
        sbc TD+1
        bcs @ln
        lda qdd
        sta TD
        lda qdd+1
        sta TD+1
@ln:    ldx qch                 ; off its scale: snap
        lda T8
        jsr allowed
        bne @sc
        ldx qch
        lda T8
        jsr snap
        sta T8
@sc:    lda T8
        jsr clampr
        sta T8
        lda TK
        sta FT
        lda TK+1
        sta FT+1
        lda TD
        sta fu_d
        lda TD+1
        sta fu_d+1
        lda T8
        jsr fits_until
        lda fu_d
        sta TD
        lda fu_d+1
        sta TD+1
        jsr lead_note
@skip:  clc                     ; lt = tq + dd
        lda TK
        adc qdd
        sta lt
        lda TK+1
        adc qdd+1
        sta lt+1
        lda lt
        cmp p_stop
        lda lt+1
        sbc p_stop+1
        bcc @x
        jsr cadence
        lda p_end
        sta lt
        lda p_end+1
        sta lt+1
@x:     rts


; ===========================================================================
.segment "JAMDATA"
sc_ionian:  .byte 7,0,2,4,5,7,9,11
kc_tones:   .byte 3,0,4,7
arc16:      .byte 5,6,7,8,9,10,11,12,13,14,15,15,15,14,13,12   ; a solo's build
lvl16:      .byte 7,7,8,8,8,9,9,10,10,10,11,11,11,12,12,12     ; swell cap per I
fades:      .byte 12,9,6
bitlo:      .byte 1,2,4,8,16,32,64,128,0,0,0,0
bithi:      .byte 0,0,0,0,0,0,0,0,1,2,4,8
dodds:      .byte 0,25,51,76,102,128,153,179,204,230,255   ; 4-bit odds -> byte
.segment "JAMDATA3"             ; (POKEY JAM: after the pitch tables)
mod12:      .repeat 256, I
            .byte I .mod 12
            .endrep
