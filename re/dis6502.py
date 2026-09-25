#!/usr/bin/env python3
"""Tiny recursive-descent 6502 disassembler for the Ballblazer RE.
usage: dis.py BIN BASE ENTRY[,ENTRY...] [--out FILE] [--extra ADDR,...]
Code reached from entries is disassembled; everything else is dumped as .byte rows.
"""
import sys, argparse

# opcode table: (mnemonic, mode)
M = {}
def op(code, mn, mode): M[code] = (mn, mode)
tbl = """
00 brk imp;01 ora izx;05 ora zp;06 asl zp;08 php imp;09 ora imm;0a asl acc;0d ora abs;0e asl abs
10 bpl rel;11 ora izy;15 ora zpx;16 asl zpx;18 clc imp;19 ora aby;1d ora abx;1e asl abx
20 jsr abs;21 and izx;24 bit zp;25 and zp;26 rol zp;28 plp imp;29 and imm;2a rol acc;2c bit abs;2d and abs;2e rol abs
30 bmi rel;31 and izy;35 and zpx;36 rol zpx;38 sec imp;39 and aby;3d and abx;3e rol abx
40 rti imp;41 eor izx;45 eor zp;46 lsr zp;48 pha imp;49 eor imm;4a lsr acc;4c jmp abs;4d eor abs;4e lsr abs
50 bvc rel;51 eor izy;55 eor zpx;56 lsr zpx;58 cli imp;59 eor aby;5d eor abx;5e lsr abx
60 rts imp;61 adc izx;65 adc zp;66 ror zp;68 pla imp;69 adc imm;6a ror acc;6c jmp ind;6d adc abs;6e ror abs
70 bvs rel;71 adc izy;75 adc zpx;76 ror zpx;78 sei imp;79 adc aby;7d adc abx;7e ror abx
81 sta izx;84 sty zp;85 sta zp;86 stx zp;88 dey imp;8a txa imp;8c sty abs;8d sta abs;8e stx abs
90 bcc rel;91 sta izy;94 sty zpx;95 sta zpx;96 stx zpy;98 tya imp;99 sta aby;9a txs imp;9d sta abx
a0 ldy imm;a1 lda izx;a2 ldx imm;a4 ldy zp;a5 lda zp;a6 ldx zp;a8 tay imp;a9 lda imm;aa tax imp;ac ldy abs;ad lda abs;ae ldx abs
b0 bcs rel;b1 lda izy;b4 ldy zpx;b5 lda zpx;b6 ldx zpy;b8 clv imp;b9 lda aby;ba tsx imp;bc ldy abx;bd lda abx;be ldx aby
c0 cpy imm;c1 cmp izx;c4 cpy zp;c5 cmp zp;c6 dec zp;c8 iny imp;c9 cmp imm;ca dex imp;cc cpy abs;cd cmp abs;ce dec abs
d0 bne rel;d1 cmp izy;d5 cmp zpx;d6 dec zpx;d8 cld imp;d9 cmp aby;dd cmp abx;de dec abx
e0 cpx imm;e1 sbc izx;e4 cpx zp;e5 sbc zp;e6 inc zp;e8 inx imp;e9 sbc imm;ea nop imp;ec cpx abs;ed sbc abs;ee inc abs
f0 beq rel;f1 sbc izy;f5 sbc zpx;f6 inc zpx;f8 sed imp;f9 sbc aby;fd sbc abx;fe inc abx
"""
for ent in tbl.replace('\n', ';').split(';'):
    ent = ent.strip()
    if not ent: continue
    c, mn, mo = ent.split()
    op(int(c, 16), mn, mo)
SIZE = dict(imp=1, acc=1, imm=2, zp=2, zpx=2, zpy=2, izx=2, izy=2, rel=2, abs=3, abx=3, aby=3, ind=3)

HW = {0xD200:'AUDF1',0xD201:'AUDC1',0xD202:'AUDF2',0xD203:'AUDC2',0xD204:'AUDF3',0xD205:'AUDC3',
      0xD206:'AUDF4',0xD207:'AUDC4',0xD208:'AUDCTL',0xD20A:'RANDOM',0xD40B:'VCOUNT',0xD40A:'WSYNC',
      0xD500:'BANKSEL',0x0222:'VVBLKI',0x0224:'VVBLKD',0x0200:'VDSLST',0xD40E:'NMIEN',0xD01F:'CONSOL',
      0x0014:'RTCLOK+2',0xD20F:'SKCTL',0xD209:'KBCODE'}

def fmt(mem, base, a, mn, mo):
    b = mem[a-base+1] if SIZE[mo] > 1 else 0
    w = (mem[a-base+1] | mem[a-base+2] << 8) if SIZE[mo] == 3 else 0
    def nm(v, n=4):
        s = ('$%04X' if n == 4 else '$%02X') % v
        return s + (' {%s}' % HW[v] if v in HW else '')
    return {'imp':'', 'acc':'a', 'imm':'#$%02X' % b, 'zp':nm(b,2), 'zpx':'$%02X,x' % b, 'zpy':'$%02X,y' % b,
            'izx':'($%02X,x)' % b, 'izy':'($%02X),y' % b,
            'rel':'$%04X' % ((a + 2 + (b - 256 if b > 127 else b)) & 0xffff),
            'abs':nm(w), 'abx':nm(w)+',x', 'aby':nm(w)+',y', 'ind':'($%04X)' % w}[mo]

def trace(mem, base, entries):
    code = {}
    todo = list(entries)
    end = base + len(mem)
    while todo:
        a = todo.pop()
        while base <= a < end and a not in code:
            o = mem[a-base]
            if o not in M: break
            mn, mo = M[o]
            n = SIZE[mo]
            if a + n > end: break
            code[a] = (mn, mo, n)
            if mo == 'rel':
                b = mem[a-base+1]; todo.append((a + 2 + (b - 256 if b > 127 else b)) & 0xffff)
            if mn in ('jsr', 'jmp') and mo == 'abs':
                todo.append(mem[a-base+1] | mem[a-base+2] << 8)
            if mn in ('rts', 'rti', 'brk') or (mn == 'jmp'):
                break
            a += n
    return code

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('bin'); ap.add_argument('base'); ap.add_argument('entries')
    ap.add_argument('--out')
    a = ap.parse_args()
    mem = open(a.bin, 'rb').read()
    base = int(a.base, 16)
    ents = [int(x, 16) for x in a.entries.split(',') if x]
    code = trace(mem, base, ents)
    targets = set(ents)
    for adr, (mn, mo, n) in code.items():
        if mo == 'rel' or (mn in ('jsr', 'jmp') and mo == 'abs'):
            t = fmt(mem, base, adr, mn, mo).split()[0]
            targets.add(int(t[1:], 16))
    out = []
    a_ = base; end = base + len(mem)
    while a_ < end:
        if a_ in code:
            mn, mo, n = code[a_]
            lab = ('L%04X:' % a_) if a_ in targets else ''
            by = ' '.join('%02X' % mem[a_-base+i] for i in range(n))
            out.append('%-7s %04X  %-9s %s %s' % (lab, a_, by, mn, fmt(mem, base, a_, mn, mo)))
            if mn in ('rts', 'rti', 'jmp'): out.append('')
            a_ += n
        else:
            s = a_; row = []
            while a_ < end and a_ not in code and len(row) < 16:
                row.append(mem[a_-base]); a_ += 1
            lab = ('L%04X:' % s) if s in targets else ''
            out.append('%-7s %04X  .byte %s' % (lab, s, ','.join('$%02X' % x for x in row)))
    txt = '\n'.join(out) + '\n'
    if a.out: open(a.out, 'w').write(txt)
    else: sys.stdout.write(txt)

if __name__ == '__main__':
    main()
