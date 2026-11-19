#!/usr/bin/env python3
"""Runs the driver watch's ARM forwarders (out/eqe_drvwatch.so) in an emulated ARM CPU (Unicorn):
with the slot empty a forwarder must return 0 with the stack untouched; with a target in the
slot it must arrive there with r0-r3, the return address and the stack unchanged.
Usage: tramp_test.py <eqe_drvwatch.so> <llvm-readelf>"""
import struct, subprocess, sys
from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM
from unicorn.arm_const import UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3, UC_ARM_REG_SP, UC_ARM_REG_LR

so, R = sys.argv[1], sys.argv[2]
data = open(so, 'rb').read()
BASE = 0x100000
segs = []
for l in subprocess.check_output([R, "-lW", so], text=True).splitlines():
    p = l.split()
    if p and p[0] == "LOAD":
        off, va, _, fsz, msz = [int(x, 16) for x in p[1:6]]
        segs.append((off, va, fsz, msz))
mu = Uc(UC_ARCH_ARM, UC_MODE_ARM)
top = max(va + msz for _, va, _, msz in segs)
mu.mem_map(BASE, (top + 0xfff) & ~0xfff)
for off, va, fsz, msz in segs:
    mu.mem_write(BASE + va, data[off:off + fsz])
names = [l.strip() for l in open(sys.argv[3] if len(sys.argv) > 3 else __file__.replace("drvtest/tramp_test.py", "drvwatch_exports.txt"))]
syms = {}
for l in subprocess.check_output([R, "--dyn-syms", "-W", so], text=True).splitlines():
    p = l.split()
    if len(p) >= 8 and p[3] == "FUNC" and p[6] != "UND":
        syms[p[7]] = int(p[1], 16)
TGT = 0x900000
mu.mem_map(TGT, 0x1000)
mu.mem_write(TGT, struct.pack("<5I", 0xe59fc008, 0xe88c400f, 0xe3a00055, 0xe12fff1e, TGT + 0x100))
STK = 0xa00000
mu.mem_map(STK - 0x10000, 0x20000)
RET = 0xb00000
mu.mem_map(RET, 0x1000)
mu.mem_write(RET, struct.pack("<I", 0xe320f000))
fails = 0
for name in names:
    if name not in syms:
        print("  FAIL %s is not exported" % name)
        fails += 1
        continue
    f = BASE + syms[name]
    slot = f + 12 + struct.unpack("<i", bytes(mu.mem_read(f + 28, 4)))[0]
    for target in (0, TGT):
        mu.mem_write(slot, struct.pack("<I", target))
        mu.mem_write(TGT + 0x100, b"\0" * 20)
        regs = [0x11111111, 0x22222222, 0x33333333, 0x44444444]
        for r, v in zip([UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3], regs):
            mu.reg_write(r, v)
        mu.reg_write(UC_ARM_REG_SP, STK)
        mu.reg_write(UC_ARM_REG_LR, RET)
        mu.emu_start(f, RET, count=50)
        r0, sp = mu.reg_read(UC_ARM_REG_R0), mu.reg_read(UC_ARM_REG_SP)
        if target == 0:
            ok = r0 == 0 and sp == STK
        else:
            rec = struct.unpack("<5I", bytes(mu.mem_read(TGT + 0x100, 20)))
            ok = list(rec[:4]) == regs and rec[4] == RET and r0 == 0x55 and sp == STK
        fails += not ok
        if not ok:
            print("  FAIL %s (slot %s)" % (name, "empty" if target == 0 else "set"))
print("%d forwarders checked twice each, %d failed" % (len(names), fails))
sys.exit(1 if fails else 0)
