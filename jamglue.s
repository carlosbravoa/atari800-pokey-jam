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
JMLAY    = $057F        ; one POKEY: 0 BAND (bass on the pair, chords on ch3),
                        ;  1 LEAD (lead on the pair, bass on ch3); M flips it
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
        jsr jam_layout          ; one POKEY: the style's layout
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
        lda labcol,x
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
        dec JLC
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
jam_catalog:
        jsr jam_blank           ; (the panel is up: mono shows 3 meters)
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
        lda JMLAY
        pha
        jsr jam_layout          ; (styn: the composer is on this style now)
        pla
        ldx STEREO              ; (stereo: layouts don't apply)
        bne @l
        cmp JMLAY
        beq @l
        jsr jam_relayout
@l:     lda JSTYLE
        jsr style_name
        ldy #15
@t:     lda (GP),y
        ora #$80
        sta SCREEN+40+2,y
        dey
        bpl @t
        jmp draw_songno


.segment "CODE"
; the machine: the second POKEY is checked once, at startup (detect_stereo's
; RANDOM-freeze test gave false "stereo" when re-run mid-performance on a
; mono board). While a key is held, stereo switched off shows: POKEY2 has no
; keyboard, so if $D21F follows POKEY1's key bit the chips are mirrored.
jam_monocheck:                  ; main loop: stereo gone while playing?
        lda STEREO
        beq @x
        lda SKSTAT
        and #4
        bne @x                  ; no key held: nothing to compare
        lda SKSTAT+$10
        and #4
        bne @x                  ; POKEY2's key bit stays up: really stereo
        lda #0                  ; mono now: a fresh jam in mono
        sta STEREO
        jsr jam_panel
        lda SONGN
        jmp song_load
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
jam_blank:                      ; mono: no meters where nothing can sound
        lda STEREO
        bne @x
        ldx #19
        lda #0
@b:     sta SCREEN+5*40+20,x
        sta SCREEN+6*40+20,x
        sta SCREEN+7*40+20,x
        sta SCREEN+8*40+20,x
        sta SCREEN+9*40+20,x
        sta SCREEN+10*40+20,x
        sta SCREEN+11*40+20,x
        sta SCREEN+12*40+20,x
        sta SCREEN+13*40+20,x
        dex
        bpl @b
@x:     rts

; ---------------------------------------------------------------------------
; one POKEY: two layouts (JAMCODE)
.segment "JAMCODE"
jam_layout:                     ; the current style's default
        ldy #ST_MONO
        lda (STYP),y
        sta JMLAY
        rts

; song_load (mono): the layout's command map -> mapt; labels and the M line
jam_monomap:
        ldy #23
        lda JMLAY
        bne @l
@b:     lda map_jmono,y
        sta mapt,y
        dey
        bpl @b
        bmi @t
@l:     lda map_jlead,y
        sta mapt,y
        dey
        bpl @l
@t:     ldx #0                  ; labels + "M MONO MIX: LEAD/BAND" (row 20)
        lda JMLAY
        beq @t2
        ldx #mtx_lead-mtx_band
@t2:    ldy #0
@t3:    lda mtx_band,x
        cmp #$FF
        beq @t4
        sta SCREEN+20*40+10,y
        inx
        iny
        bne @t3
@t4:    ldx #0
        lda JMLAY
        beq @t5
        ldx #lab_lead-lab_band
@t5:    ldy #0
@t6:    lda lab_band,x
        sta SCREEN+14*40+3,y
        inx
        iny
        cpy #11
        bne @t6
        rts

; M: switch the layout while it plays
jam_mtoggle:
        lda STEREO
        bne @x
        lda JMLAY
        eor #1
        sta JMLAY
        jsr hush
        jmp jam_relayout
@x:     rts

; a layout change mid-performance: map, sounds and levels for the pair and ch3
jam_relayout:
        jsr jam_monomap
        lda JMLAY
        beq @band
        lda inst                ; LEAD: the lead's sound on the pair,
        jsr set_preset
        ldx #0                  ;  a plucked PIANO for the 8-bit bass
        lda #0
        jsr lv_load
        lda jlastlv
        sta MIXL
        lda jlastlv+1
        sta MIXV
        jmp jam_labels
@band:  lda inst+1              ; BAND: the bass's sound on the pair,
        jsr set_preset
        ldx #0                  ;  the comping's on ch3
        lda inst+2
        jsr lv_load
        lda jlastlv+1
        sta MIXL
        lda jlastlv+2
        sta MIXV
        jmp jam_labels

; LEAD layout map: psq op/track -> command (index op*4 + track)
map_jlead:
        .byte 0,2,$FF,$FF, 1,3,$FF,$FF, 6,6,6,6, 8,$FF,$FF,$FF
        .byte $FF,$FF,$FF,$FF, 17,18,$FF,$FF
.macro SC str                   ; text as screen codes
        .repeat .strlen(str), I
        .byte .strat(str, I) - 32
        .endrep
.endmacro
mtx_band:   SC "M  MONO MIX: BAND "
            .byte $FF
mtx_lead:   SC "M  MONO MIX: LEAD "
            .byte $FF
lab_band:   SC "BASS  CHORD"
lab_lead:   SC "LEAD  BASS "
