# POKEY JAM: the composer (jam.s) inside POKEY PLAYER's front-end (../synth)
CA65   := $(HOME)/.local/bin/ca65
LD65   := $(HOME)/.local/bin/ld65
SYNTH  := ../synth

all: build/jam.xex

jamdata.inc: gen_tables.py styles.py engine.py theory.py
	python3 gen_tables.py

build/jam.xex: jam.s jamglue.s jamdata.inc atari-jam.cfg $(SYNTH)/player.s \
               $(SYNTH)/engine.inc $(SYNTH)/tables.inc $(SYNTH)/scope.inc
	@mkdir -p build
	cd $(SYNTH) && $(CA65) -g -D JAM -I ../music-gen -o ../music-gen/build/jam.o player.s
	$(LD65) -C atari-jam.cfg -Ln build/jam.lbl -m build/jam.map -o $@ build/jam.o
	@ls -l $@

test: jamdata.inc
	python3 test_jam.py

deploy: build/jam.xex
	cd $(SYNTH) && python3 deploy.py --xex ../music-gen/build/jam.xex

clean:
	rm -rf build

.PHONY: all test deploy clean
