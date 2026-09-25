; py65 test build: the generator alone (test_jam.py drives it)
JRING    = $9800
JRINGSZ  = $0800
.include "jam.s"

.segment "JAMCODE"
jam_yield:                      ; (POKEY JAM redraws its panel here)
        rts
