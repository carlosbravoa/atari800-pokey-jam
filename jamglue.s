; ---------------------------------------------------------------------------
; POKEY JAM glue: the generator (jam.s) behind POKEY PLAYER's panel.
;
; Included by synth/player.s when built with -D JAM (see music-gen/Makefile).
; The player's sequencer reads the event ring exactly as it reads a song in
; the bank; the main loop keeps the ring topped up one bar at a time.
;
;   styles are the player's "songs": the catalog at CAT is built from the
;   style names, so 1-9, < >, RETURN (new jam) and the song list all work;
;   RETURN on the same style = a new seed = a new performance.
;   1-6 mute/unmute the panel's columns (the label goes inverse): their
;   note-ons and hits are skipped at the sequencer, the composer goes on.
;   M, one POKEY only: the mix, STEREO>MONO or MONO>MONO (row 20)
;   R switches RANDOM on/off (the word goes inverse in the key line): the
;   music goes on, and each tune after the current one picks a style. The
;   title follows the style you hear, switching when its tune starts.
;
; Ring handshake (the VBI never sees a half-written bar):
;   JCOM   write pointer committed after each whole bar (main thread)
;   JCV    the VBI's copy, refreshed only while JBUSY = 0
;   the sequencer stalls (JSTARVE) if it ever catches up with JCV
; ---------------------------------------------------------------------------

JRING    = $9C00        ; 1 KB event ring
JRINGSZ  = $0400
JLOW     = 384          ; generate another bar when less than this is queued

JCOM     = $06E0        ; 2
JCV      = $06E2        ; 2
JBUSY    = $06E4
JSTARVE  = $06E5
JBARS    = $06E6        ; 2: bars generated (liveness)
JSTYLE   = $06E8        ; style playing
JUSED    = $06E9        ; 2: bytes queued at the last pump (peek)
JSEEDP   = $06EB        ; 2: this performance's seed (peek / replay)
JTPEND   = $06ED        ; a tune in another style is on its way
JTSTY    = $06EE        ;  ... that style
JGSTY    = $06EF        ; style being composed
JTLEFT   = $06F5        ; 2: ring bytes still to play before it starts
JVPP     = $06F7        ; 2: VP at the last pump
RNDCOL   = 32           ; "RANDOM" in the key line
JMUTE    = $06FC        ; voices muted (bit per panel column: LEAD VOICE DRUM
                        ;  BASS HARM DRUM2), set by keys 1-6
JMUTED   = $06FD        ; ... as the VBI has applied them
JREL     = $06FE        ; VBI scratch: columns to release
JLC      = $06FF        ; jam_labels' column
JMONO    = $057E        ; frames in a row that read like one POKEY
JHW      = $057F        ; the machine really has a second POKEY. With two it
                        ;  plays stereo; with one, STEREO picks the mix (M):
                        ;  1 STEREO>MONO (both driven, POKEY2's part wins),
                        ;  0 MONO>MONO (map_jmono, every drum on ch4)
RNDROW   = 22
JYF      = $06F9        ; frame the panel was last drawn from a yield
JVS      = $06FA        ; 2: VP snapshot in jam_pump

.include "jam.s"

.segment "XEXHDR5"              ; the style tables in the old scope buffer
.import __JD2_START__, __JD2_LAST__
        .word __JD2_START__
        .word __JD2_LAST__-1

.segment "CODE"                 ; (the player's MAIN: room since the scope went)

; the catalog: count, then per style title(16) ptr(2) pstep(2) min sec mode spare
; song_load's stream setup: A = style -> a fresh performance in the ring
jam_start:
        sta JSTYLE
        lda RANDOM              ; a new seed every time
        sta JSEED
        sta JSEEDP
        lda RANDOM
        sta JSEED+1
        sta JSEEDP+1
        lda JSTYLE
        sta JGSTY
        jsr jam_init
        lda #0
        sta JTPEND
        jsr jam_bar
        jsr jam_bar
        lda #0
        sta JBARS
        sta JBARS+1
        sta JSTARVE
        jsr jam_commit
        lda JCOM
        sta JCV
        lda JCOM+1
        sta JCV+1
        lda #<JRING
        sta VP
        sta SPTR
        lda #>JRING
        sta VP+1
        sta SPTR+1
        lda #<JRING
        sta JVPP
        lda #>JRING
        sta JVPP+1
        rts

jam_commit:
        lda #1
        sta JBUSY
        lda JWP
        sta JCOM
        lda JWP+1
        sta JCOM+1
        lda #0
        sta JBUSY
        rts

; main loop: one more bar when the ring runs low; the title's timing
jam_pump:
        jsr jam_monocheck
        lda PLAYING
        bne @go
        rts
@go:
@rd:    lda VP                  ; VP is the VBI's: read it without a tear
        sta JVS
        ldx VP+1
        lda VP
        cmp JVS
        bne @rd
        stx JVS+1
        lda JTPEND              ; a new style on its way: count down what
        beq @q                  ;  the sequencer played since the last pass
        sec
        lda JVS
        sbc JVPP
        sta PT3
        lda JVS+1
        sbc JVPP+1
        and #>(JRINGSZ-1)
        sta PT4
        sec
        lda JTLEFT
        sbc PT3
        sta JTLEFT
        lda JTLEFT+1
        sbc PT4
        sta JTLEFT+1
        bcc @now
        ora JTLEFT
        bne @q
@now:   lda #0
        sta JTPEND
        lda JTSTY
        jsr jam_show
@q:     lda JVS
        sta JVPP
        lda JVS+1
        sta JVPP+1
        jsr queued              ; JUSED = (JCOM - VP) mod JRINGSZ
        cmp #>JLOW
        bcc @gen
        bne @x
        lda JUSED
        cmp #<JLOW
        bcs @x
@gen:   jsr jam_labels          ; (the panel may have reprinted them)
        jsr jam_bar
        jsr jam_commit
        inc JBARS
        bne @s
        inc JBARS+1
@s:     lda styn                ; a tune in another style begins after
        cmp JGSTY               ;  everything queued so far
        beq @x
        sta JGSTY
        sta JTSTY
        jsr queued
        sta JTLEFT+1
        lda JUSED
        sta JTLEFT
        lda #1
        sta JTPEND
@x:     rts

queued:                         ; JVS = VP -> JUSED, A = hi byte
        sec
        lda JCOM
        sbc JVS
        sta JUSED
        lda JCOM+1
        sbc JVS+1
        and #>(JRINGSZ-1)
        sta JUSED+1
        rts

; VBI, before the sequencer's clock: C clear = stall this frame
jam_vbi_ok:
        jsr jam_release
        lda JBUSY
        bne @c
        lda JCOM
        sta JCV
        lda JCOM+1
        sta JCV+1
@c:     lda JSTARVE
        beq @ok
        lda VP                  ; starved: wait for data, then take the delta
        cmp JCV
        bne @fed
        lda VP+1
        cmp JCV+1
        beq @no
@fed:   lda #0
        sta JSTARVE
        jsr sq_delta
@ok:    sec
        rts
@no:    clc
        rts

; seq_next, before reading the next delta: C set = nothing there yet
jam_empty:
        lda VP
        cmp JCV
        bne @y
        lda VP+1
        cmp JCV+1
        bne @y
        lda #1
        sta JSTARVE
        sec
        rts
@y:     clc
        rts

; the composer's safe points: a new frame since the last draw -> draw the
; panel (drawing only: keys wait for the main loop)
jam_yield:
        php
        pha
        lda RTCLOK+2
        cmp JYF
        beq @x
        sta JYF
        lda PLAYING             ; not while a style is being set up,
        beq @x
        lda liston              ;  nor under the song list
        bne @x
        txa
        pha
        tya
        pha
        jsr draw_all
        pla
        tay
        pla
        tax
@x:     pla
        plp
        rts

; ---------------------------------------------------------------------------
; voices on/off (CODE2: the player's MAIN is full)
.segment "CODE2"

; the sequencer's dispatch: X = command -> C set = skip it (muted)
jam_mute:
        lda mutebit,x
        and JMUTE
        beq @on
        sec
        rts
@on:    clc
        rts
; per command: the column a note-on / hit belongs to (offs always pass)
;             0 lead on, 1 off, 2 bass on, 3 off, 4 harm on, 5 off,
;             6 drum, 7 drum2, 8-13 control, 14 voice 4 on, 15 off, 16-20
mutebit:    .byte 1,0,8,0,16,0,4,32,0,0,0,0,0,0,2,0,0,0,0,0,0

; key: X = 0-9 from the number row -> 1-6 toggle a column
jam_key:
        cpx #6
        bcs @x
        jsr jcolbit
        eor JMUTE
        sta JMUTE
        jmp jam_labels
@x:     rts
colbit:     .byte 1,2,4,8,16,32
colbit_mo:  .byte 1,8,4,0,0,0           ; mono: BASS (lead cmds) CHORD (voice 0) DRUM

; A = the JMUTE bit of panel column X (X kept)
jcolbit:
        lda STEREO
        beq @m
        lda colbit,x
        rts
@m:     lda colbit_mo,x
        rts

; the labels above the columns: inverse while muted (also redone each pump:
; the panel reprints LAYER/VOICE)
jam_labels:
        lda #5
        sta JLC
@c:     ldx JLC
        lda JHW                 ; one POKEY: half the columns are blank
        bne @c1
        lda STEREO
        beq @sr
        cpx #3                  ;  STEREO>MONO: the left three
        bcc @nx
        bcs @c1
@sr:    cpx #3                  ;  MONO>MONO: the right three
        bcs @nx
@c1:    lda labcol,x
        tay
        lda labw,x
        sta PT4
        jsr jcolbit
        and JMUTE
        sta PT3
@l:     lda SCREEN+14*40,y
        and #$7F
        ldx PT3
        beq @o
        ora #$80
@o:     sta SCREEN+14*40,y
        iny
        dec PT4
        bne @l
@nx:    dec JLC
        bpl @c
        rts
labcol:     .byte 3,9,15,21,27,33
labw:       .byte 4,5,4,4,4,5

; VBI: a column just muted lets its sounding note go
jam_release:
        lda JMUTE
        tax
        eor JMUTED
        and JMUTE               ; newly muted
        stx JMUTED
        beq @x
        sta JREL                ; (the VBI keeps off main-thread zero page)
        lsr JREL                ; bit 0: the lead
        bcc @v4
        lda #0
        sta GATE
        lda ESTATE
        beq @v4
        lda #4
        sta ESTATE
@v4:    lsr JREL                 ; bit 1: voice 4
        bcc @d
        ldx #V3X
        jsr lv_off
@d:     lsr JREL                ; drums: short, they end by themselves
        lsr JREL                 ; bit 3: bass
        bcc @h
        ldx #0
        jsr lv_off
@h:     lsr JREL                 ; bit 4: harm
        bcc @x
        ldx #VBS
        jsr lv_off
@x:     rts

; ---------------------------------------------------------------------------
.segment "JAMCODE"
; one POKEY: the lead's 16-bit pair plays the BASS (an 8-bit channel can't
; reach bass notes in tune), ch3 the comping, ch4 every drum. The lead and
; voice 4 are dropped: the backing band is what sounds best. psq op/track ->
; command, index = op*4 + track (tracks: lead, bass, comp, voice 4)
map_jmono:
        .byte $FF,0,2,$FF, $FF,1,3,$FF, 6,6,6,6, $FF,8,9,$FF
        .byte $FF,$FF,$FF,$FF, $FF,17,18,$FF

; ---------------------------------------------------------------------------
; the style list, title, RANDOM flag, panel mode (JAMCODE: the MAIN is full)
.segment "JAMCODE"
.assert 1 + NSTYLES * 24 <= $100, error, "the style list outgrew $0480-$057F"
; One POKEY or two, POKEY JAM plays its stereo arrangement. On a one-POKEY
; machine $D21x folds onto POKEY1 and the second POKEY's part, written last in
; every VBI, wins: bass, chords and the second drum part, no lead -- the mono
; mix, by design. So a wrong detection can't change the sound: STEREO stays 1
; for the engine and JHW only tells the panel what the machine is.
jam_catalog:
        lda #1                  ; FLUTE's vibrato: +-13 cents, not +-27 (the
        sta live+2*PSTRIDE+6    ;  factory depth reads as out of tune on a lead)
        lda STEREO              ; startup's detect_stereo: the machine
        sta JHW
        lda #1
        sta STEREO
        jsr jam_panel           ; (the panel was drawn for the machine)
        lda #0                  ; RANDOM starts off, every voice on
        sta jrand
        sta JMUTE
        sta JMUTED
        jsr jam_rflag
        lda #NSTYLES
        sta CAT
        lda #<(CAT+1)
        sta PT1
        lda #>(CAT+1)
        sta PT2
        ldx #0
@s:     stx PT3
        txa
        jsr style_name
        ldy #0
@t:     lda (GP),y
        sta (PT1),y
        iny
        cpy #16
        bne @t
        lda #0                  ; stream pointer (unused)
        sta (PT1),y
        iny
        sta (PT1),y
        iny
        lda #$FF                ; progress step: never
        sta (PT1),y
        iny
        sta (PT1),y
        iny
        lda #0                  ; length 00:00 (endless)
        sta (PT1),y
        iny
        sta (PT1),y
        iny
        lda #1                  ; stereo layout (the player folds for mono)
        sta (PT1),y
        iny
        lda #0
        sta (PT1),y
        clc
        lda PT1
        adc #24
        sta PT1
        bcc @n
        inc PT2
@n:     ldx PT3
        inx
        cpx #NSTYLES
        bne @s
        rts

style_name:                     ; A = style -> GP = its 16-char name
        asl a
        tay
        lda styles,y
        sta GP
        lda styles+1,y
        sta GP+1
        ldy #ST_NAME
        lda (GP),y
        pha
        iny
        lda (GP),y
        sta GP+1
        pla
        sta GP
        rts

; R: RANDOM on/off -- the music goes on; the next tune rolls the dice
jam_rtoggle:
        lda jrand
        eor #1
        sta jrand
        ; fall through
jam_rflag:                      ; "RANDOM" in the key line: inverse while on
        ldx #5
@c:     lda SCREEN+RNDROW*40+RNDCOL,x
        and #$7F
        ldy jrand
        beq @o
        ora #$80
@o:     sta SCREEN+RNDROW*40+RNDCOL,x
        dex
        bpl @c
        rts

; the title and the style number follow the tune you hear
jam_show:                       ; A = style
        sta SONGN
        sta JSTYLE
        jsr style_name
        ldy #15
@t:     lda (GP),y
        ora #$80
        sta SCREEN+40+2,y
        dey
        bpl @t
        jmp draw_songno


.segment "JAMCODE"
; the machine: detect_stereo at startup, then every frame the same read test
; (one POKEY reads the same KBCODE/SKSTAT through $D2x9/$D2xF and $D21x) --
; a stereo setting switched off shows up on the panel by itself.
jam_monocheck:                  ; main loop: really one POKEY? (the panel)
        lda JHW
        beq @x
        lda KBCODE              ; the same chip twice reads the same: 30
        cmp KBCODE+$10          ;  frames of that and the panel says MONO
        bne @no                 ;  (the sound already is the mono mix)
        lda SKSTAT
        cmp SKSTAT+$10
        bne @no
        inc JMONO
        lda JMONO
        cmp #30
        bcc @x
        lda #0
        sta JHW
        jmp jam_panel
@no:    lda #0
        sta JMONO
@x:     rts

jam_panel:                      ; redraw the panel for STEREO / MONO
        lda #0
        ldx #39
@c:     sta SCREEN+14*40,x      ; the column labels
        dex
        bpl @c
        ldx #5
@s:     sta SCREEN+2*40+16,x    ; STEREO / MONO
        dex
        bpl @s
        jsr draw_static
        jsr jam_rflag
        jsr jam_labels
        ; fall through
jam_blank:                      ; one POKEY: MONO, and only the meters that
        lda JHW                 ;  sound, and the mix on row 20
        beq @one
        rts
@one:   lda STEREO
        bne @fold
        ldx #19                 ; MONO>MONO: BASS CHORD DRUM on the left
        lda #0
@r:     sta SCREEN+5*40+20,x
        sta SCREEN+6*40+20,x
        sta SCREEN+7*40+20,x
        sta SCREEN+8*40+20,x
        sta SCREEN+9*40+20,x
        sta SCREEN+10*40+20,x
        sta SCREEN+11*40+20,x
        sta SCREEN+12*40+20,x
        sta SCREEN+13*40+20,x
        sta SCREEN+14*40+20,x
        dex
        bpl @r
        ldx #mix_mm-mix_sm
        jmp mixline
@fold:  ldx #2                  ; STEREO>MONO: POKEY1's part is overwritten
                                ;  every frame -- BASS HARM DRUM2 on the right
        lda #$FF
@d:     sta vusrc,x
        dex
        bpl @d
        ldx #19
        lda #0
@b:     sta SCREEN+5*40,x
        sta SCREEN+6*40,x
        sta SCREEN+7*40,x
        sta SCREEN+8*40,x
        sta SCREEN+9*40,x
        sta SCREEN+10*40,x
        sta SCREEN+11*40,x
        sta SCREEN+12*40,x
        sta SCREEN+13*40,x
        sta SCREEN+14*40,x
        dex
        bpl @b
        ldx #3
@m:     lda mono_txt,x
        sta SCREEN+2*40+16,x
        dex
        bpl @m
        lda #0
        sta SCREEN+2*40+20
        sta SCREEN+2*40+21
        ldx #0
mixline:                        ; X = the text's offset -> row 20
        ldy #0
@t:     lda mix_sm,x
        sta SCREEN+20*40+10,y
        inx
        iny
        cpy #19
        bne @t
        rts
mono_txt:   .byte 'M'-32,'O'-32,'N'-32,'O'-32
.macro SC str                   ; text as screen codes
        .repeat .strlen(str), I
        .byte .strat(str, I) - 32
        .endrep
.endmacro
mix_sm:     SC "M  MIX: STEREO>MONO"
mix_mm:     SC "M  MIX: MONO>MONO  "

; M, one POKEY: switch the mix while it plays. STEREO>MONO: the stereo
; arrangement, POKEY2's part winning (bass, chords, the second drum part).
; MONO>MONO: bass on the 16-bit pair, chords on ch3, every drum on ch4.
; No lead in either.
jam_mtoggle:
        lda JHW
        bne @x                  ; two POKEYs: nothing to switch
        jsr hush
        lda STEREO
        eor #1
        sta STEREO
        beq @mm
        ldy #23                 ; -> STEREO>MONO
@a:     lda map_st,y
        sta mapt,y
        dey
        bpl @a
        lda inst                ; each voice its sound and level again
        jsr set_preset
        ldx #0
        lda inst+1
        jsr lv_load
        ldx #VBS
        lda inst+2
        jsr lv_load
        ldx #V3X
        lda inst+3
        jsr lv_load
        ldx #3
@l:     lda jlastlv,x           ; lead, bass, chords, voice 4 = MIXL, MIXV..+2
        sta MIXL,x
        dex
        bpl @l
        jmp jam_panel
@mm:    ldy #23                 ; -> MONO>MONO
@b:     lda map_jmono,y
        sta mapt,y
        dey
        bpl @b
        lda inst+1              ; the bass's sound on the pair,
        jsr set_preset
        ldx #0                  ;  the chords' on ch3
        lda inst+2
        jsr lv_load
        lda jlastlv+1
        sta MIXL
        lda jlastlv+2
        sta MIXV
        jmp jam_panel
@x:     rts
