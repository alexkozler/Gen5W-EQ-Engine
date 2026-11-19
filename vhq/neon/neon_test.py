#!/usr/bin/env python3
"""Runs Android 4.4's converter kernel (filterCoefficient<2>, extracted verbatim) as ARM code under
an emulator, in the three forms Android may be built with, using EQ Engine's tables:
  k0.bin  plain C      k1.bin  ARM scalar assembly      k2.bin  NEON assembly
Each result is compared with an exact model of the C code. The NEON loads carry 128-bit alignment
hints: the emulator faults on a misaligned address, which is checked too.
Usage: neon_test.py <vhq_tables.h>"""
import re
import sys
import os
import random
from unicorn import Uc, UcError, UC_ARCH_ARM, UC_MODE_ARM
from unicorn import arm_const as A

if sys.argv[1] == "android":
    # Android's own high-quality tables (8 taps, 7 bits), for comparison
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../third_party/aosp-af/AudioResamplerSinc.cpp")).read()
    def table(name):
        body = src.split(name + "[] __attribute__ ((aligned (32))) = {", 1)[1].split("};", 1)[0]
        return [x - (1 << 32) if x >= 1 << 31 else x for x in (int(v, 16) for v in re.findall(r"0x[0-9a-fA-F]+", body))]
    H, BITS = 8, 7
    down, up = table("AudioResamplerSinc::mFirCoefsDown"), table("AudioResamplerSinc::mFirCoefsUp")
else:
    hdr = open(sys.argv[1]).read()
    H = int(re.search(r"VHQ_HALF_NUM_COEFS (\d+)", hdr).group(1))
    BITS = int(re.search(r"VHQ_COEFS_BITS (\d+)", hdr).group(1))
    down = [int(x) for x in re.findall(r"-?\d+", hdr.split("vhq_down[", 1)[1].split("};", 1)[0].split("=", 1)[1])]
    up = [int(x) for x in re.findall(r"-?\d+", hdr.split("vhq_up[", 1)[1].split("};", 1)[0].split("=", 1)[1])]
L = 1 << BITS
assert len(down) == (L + 1) * H and len(up) == (L + 1) * H

M32 = 0xffffffff


def s32(x):
    x &= M32
    return x - (1 << 32) if x & 0x80000000 else x


def model(coefs, phase, frames, present, volL, volR, out, asm=False):
    """Exact model of the C path (USE_INLINE_ASSEMBLY false); asm=True models the ARM scalar
    assembly, whose volume step (smultb) multiplies only the top 16 bits of the sum."""
    cShift = 30 - BITS
    cMask = ((1 << BITS) - 1) << cShift
    pShift = 30 - BITS - 15
    pMask = ((1 << 15) - 1) << pShift
    ONE = cMask | pMask
    iP = (phase & cMask) >> cShift
    lP = (phase & pMask) >> pShift
    neg = (ONE - phase) & M32
    iN = (neg & cMask) >> cShift
    lN = (neg & pMask) >> pShift
    iP *= H
    iN *= H
    l = r = 0
    for i in range(H):
        for base, lerp, fr in ((iP, lP, present - i), (iN, lN, present + 1 + i)):
            c0 = coefs[base + i]
            c1 = coefs[base + i + H]
            sinc = s32(c0 + ((s32((c1 - c0) << 1) * lerp) >> 16))
            sl, sr = frames[fr]
            l = s32(l + ((sinc * sl) >> 16))
            r = s32(r + ((sinc * sr) >> 16))
    if asm:
        return [s32(out[0] + 2 * ((l >> 16) * volL)), s32(out[1] + 2 * ((r >> 16) * volR))]
    return [s32(out[0] + 2 * ((l * volL) >> 16)), s32(out[1] + 2 * ((r * volR) >> 16))]


CODE, DATA, STACK, STOP = 0x10000, 0x100000, 0x700000, 0x30000
TAB, SAMP, OUT, ARGS = DATA, DATA + 0x60000, DATA + 0x70000, DATA + 0x70100


def emulator(binfile):
    mu = Uc(UC_ARCH_ARM, UC_MODE_ARM)
    mu.ctl_set_cpu_model(A.UC_CPU_ARM_CORTEX_A15)
    mu.mem_map(CODE, 0x10000)
    mu.mem_map(STOP, 0x1000)
    mu.mem_map(DATA, 0x100000)
    mu.mem_map(STACK - 0x10000, 0x20000)
    mu.mem_write(CODE, open(binfile, "rb").read())
    mu.reg_write(A.UC_ARM_REG_C1_C0_2, mu.reg_read(A.UC_ARM_REG_C1_C0_2) | (0xf << 20))  # VFP/NEON access
    mu.reg_write(A.UC_ARM_REG_FPEXC, 0x40000000)
    return mu


def put32(mu, addr, vals):
    mu.mem_write(addr, b"".join((v & M32).to_bytes(4, "little") for v in vals))


def call(mu, tab_addr, phase, frames, present, volL, volR, out0):
    # samples: stereo int16, the frame "present" at SAMP + 4 * present
    mu.mem_write(SAMP, b"".join(((a & 0xffff) | ((b & 0xffff) << 16)).to_bytes(4, "little") for a, b in frames))
    put32(mu, OUT, out0)
    vRL = (volL & 0xffff) | ((volR & 0xffff) << 16)
    # struct Args { out, phase, samples, coefs, vRL, volL<<16, volR<<16, coefsBits, halfNumCoefs }
    put32(mu, ARGS, [OUT, phase, SAMP + 4 * present, tab_addr, vRL, volL << 16, volR << 16, BITS, H])
    mu.reg_write(A.UC_ARM_REG_R0, ARGS)
    mu.reg_write(A.UC_ARM_REG_SP, STACK)
    mu.reg_write(A.UC_ARM_REG_LR, STOP)
    mu.emu_start(CODE, STOP, count=200000)
    o = mu.mem_read(OUT, 8)
    return [s32(int.from_bytes(o[0:4], "little")), s32(int.from_bytes(o[4:8], "little"))]


random.seed(5)
fails = 0
for v, name in ((0, "plain C"), (1, "ARM scalar assembly"), (2, "NEON assembly")):
    mu = emulator("k%d.bin" % v)
    worst = 0.0
    n = 0
    for tname, tab in (("down", down), ("up", up)):
        put32(mu, TAB, tab)
        for trial in range(250):
            phase = random.randrange(0, 1 << 30)
            if trial < 4:
                phase = [0, (1 << 30) - 1, 1 << 29, 12345][trial]
            frames = [(random.randint(-32768, 32767), random.randint(-32768, 32767)) for _ in range(4 * H)]
            if trial % 5 == 0:  # full-scale signs lined up with the taps: the largest possible sum
                frames = [(32767 if (i % 2) else -32768, -32768 if (i % 2) else 32767) for i in range(4 * H)]
            present = 2 * H + random.randrange(0, 3)   # any frame offset: samples are only 4-byte aligned
            vol = random.choice([0x1000, 0x0800, 0x0fff, 0x0001])
            out0 = [random.randint(-1 << 28, 1 << 28), random.randint(-1 << 28, 1 << 28)]
            want = model(tab, phase, frames, present, vol, vol, out0, asm=(v == 1))
            try:
                got = call(mu, TAB, phase, frames, present, vol, vol, out0)
            except UcError as e:
                print("  FAIL %s %s: emulator stopped: %s" % (name, tname, e))
                fails += 1
                break
            # NEON rounds (vqrdmulh) where C truncates. Output units: full scale = 2^27 x volume/0x1000.
            d = max(abs(got[0] - want[0]), abs(got[1] - want[1]))
            worst = max(worst, d)
            n += 1
            if v < 2 and d != 0:
                print("  FAIL %s differs from the model: got %s want %s" % (name, got, want))
                fails += 1
                break
            if v == 2 and d > 2 ** 27 * 1e-5:
                print("  FAIL %s %s: got %s want %s (difference %d)" % (name, tname, got, want, d))
                fails += 1
                break
    print("%-20s %d calls, %s" % (name, n, "bit-exact with the model" if worst == 0
                                   else "largest difference %d = %.1f dB below full scale" % (worst, 20 * __import__("math").log10(worst / 2 ** 27))))

# a misaligned table must fault in the NEON form (proves alignment is enforced by the emulator)
mu = emulator("k2.bin")
put32(mu, TAB + 4, down)
try:
    call(mu, TAB + 4, 1 << 28, [(1, 1)] * (4 * H), 2 * H, 0x1000, 0x1000, [0, 0])
    print("misaligned table: no fault (the emulator does not check alignment; result not conclusive)")
except UcError as e:
    print("misaligned table: faults as expected (%s), so the aligned runs above prove the layout is right" % e)
print("all good" if fails == 0 else "%d FAILURES" % fails)
sys.exit(1 if fails else 0)
