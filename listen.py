#!/usr/bin/env python3
"""Play one generated take in the real POKEY PLAYER on the board.

    python3 listen.py STYLE [--seed N] [--seconds S]    # generate, then play
    python3 listen.py takes/jazz_1984.psq               # play a file

Builds synth/player.s with -D AUDITION (one-song bank) and hot-swaps it on,
exactly like synth/audition.py play. The bank holds 20 KB, so long takes are
cut by gen.py's --seconds.
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SYNTH = os.path.join(HERE, "..", "synth")
sys.path.insert(0, SYNTH)
import gen_songbank  # noqa: E402

import gen  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("what")
ap.add_argument("--seed", type=int, default=1984)
ap.add_argument("--seconds", type=int, default=150)
a = ap.parse_args()
if a.what.endswith(".psq"):
    path = os.path.abspath(a.what)
else:
    style = a.what.upper()
    out = gen.generate(style, a.seconds, a.seed, verbose=True)
    path = os.path.join(HERE, "takes", f"{style.lower()}_{a.seed}.psq")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    out.w.save(path)
    print(f"{path}: {out.notes} notes, {out.hits} hits, {os.path.getsize(path)} bytes")
os.makedirs(os.path.join(SYNTH, "build"), exist_ok=True)
gen_songbank.build([path], out=os.path.join(SYNTH, "build", "audition.bin"))
ca, ld = os.path.expanduser("~/.local/bin/ca65"), os.path.expanduser("~/.local/bin/ld65")
subprocess.run([ca, "-D", "AUDITION", "-o", "build/audition.o", "player.s"], cwd=SYNTH, check=True)
subprocess.run([ld, "-C", "atari-player.cfg", "-o", "build/audition.xex", "build/audition.o"],
               cwd=SYNTH, check=True)
subprocess.run([sys.executable, "deploy.py", "--xex", "build/audition.xex"], cwd=SYNTH, check=True)
print(f"playing {os.path.basename(path)}")
