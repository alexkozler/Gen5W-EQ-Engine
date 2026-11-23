#!/usr/bin/env python3
"""The built CarPlay watch (ARM) exports JNI_OnLoad (it stands in for libCarPlayAndroid.so) and its check, nothing
else, needs only libdl, liblog, libm and libc (all in every app), and has no text relocations.

Usage: exports_test.py <eqe_cpwatch.so> <llvm-readelf>
"""
import subprocess
import sys

so, readelf = sys.argv[1], sys.argv[2]
want = {"JNI_OnLoad", "eqe_cpw_check"}
syms = subprocess.run([readelf, "--dyn-syms", "-W", so], capture_output=True, text=True, check=True).stdout
defined = set()
for line in syms.splitlines():
    f = line.split()
    # Num: Value Size Type Bind Vis Ndx Name
    if len(f) >= 8 and f[0].endswith(":") and f[6] != "UND" and f[4] in ("GLOBAL", "WEAK"):
        defined.add(f[7].split("@")[0])
dyn = subprocess.run([readelf, "-d", "-W", so], capture_output=True, text=True, check=True).stdout
needed = set()
for line in dyn.splitlines():
    if "(NEEDED)" in line:
        needed.add(line.split("[")[1].split("]")[0])
fails = 0


def ok(what, cond):
    global fails
    print("  %s %s" % ("ok  " if cond else "FAIL", what))
    if not cond:
        fails += 1


ok("exports exactly %s (got %s)" % (sorted(want), sorted(defined)), defined == want)
ok("needs only libdl, liblog, libm, libc (got %s)" % sorted(needed), needed <= {"libdl.so", "liblog.so", "libm.so", "libc.so"})
ok("no text relocations", "TEXTREL" not in dyn)
ok("soname eqe_cpwatch.so (not libtinyalsa.so: the linker tells loaded libraries apart by name)",
   "Library soname: [eqe_cpwatch.so]" in dyn)
sys.exit(1 if fails else 0)
