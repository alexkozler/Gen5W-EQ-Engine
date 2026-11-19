#!/usr/bin/env python3
"""Checks a NEMESIS.data the way NEMESIS's own parser does (native/ini.c, native/meta.c), so a
package that NEMESIS would refuse ("invalid package metadata") fails the build instead.
Usage: check_meta.py <NEMESIS.data>"""
import re, sys

SHORT_MAX, DETAIL_MAX = 64, 256            # nemesis.h META_SHORT_MAX, META_DETAIL_MAX
SIZES = {"id": 96, "type": 80, "package-version": 32, "depends": 512, "os": 256, "models": 256}

def parse(text):
    # key=value; a value starting with '"' runs to the next unescaped '"' (\" and \\ escapes).
    sec, out, i, n = None, {}, 0, len(text)
    lines = text.replace("\r\n", "\n").replace("\r", "\n")
    pos = 0
    while pos < len(lines):
        end = lines.find("\n", pos)
        if end < 0: end = len(lines)
        line = lines[pos:end].strip()
        if line.startswith("[") and line.endswith("]"):
            sec = line[1:-1].strip(); pos = end + 1; continue
        if not line or line[0] in "#;" or "=" not in line:
            pos = end + 1; continue
        k = line.split("=", 1)[0].strip()
        vstart = lines.index("=", pos) + 1
        while vstart < len(lines) and lines[vstart] in " \t": vstart += 1
        if vstart < len(lines) and lines[vstart] == '"':
            j, buf = vstart + 1, []
            while True:
                if j >= len(lines): sys.exit("unterminated quoted value for %s" % k)
                c = lines[j]; j += 1
                if c == '"': break
                if c == "\\" and j < len(lines) and lines[j] in '"\\': c = lines[j]; j += 1
                buf.append(c)
            v = "".join(buf)
            end = lines.find("\n", j)
            if end < 0: end = len(lines)
        else:
            v = lines[vstart:end].rstrip()
        out[(sec, k)] = v
        pos = end + 1
    return out

m = parse(open(sys.argv[1], encoding="utf-8").read())
get = lambda k: m.get(("nemesis", k))
errs = []
if not get("id"): errs.append("missing id")
pv = get("package-version")
if pv and not re.fullmatch(r"\d+(\.\d+)*", pv): errs.append("package-version must be dotted numbers: %s" % pv)
if get("short-desc") and len(get("short-desc")) > SHORT_MAX: errs.append("short-desc is %d characters (max %d)" % (len(get("short-desc")), SHORT_MAX))
if get("detailed-desc") and len(get("detailed-desc")) > DETAIL_MAX: errs.append("detailed-desc is %d characters (max %d)" % (len(get("detailed-desc")), DETAIL_MAX))
for k, cap in SIZES.items():
    v = get(k)
    if v and len(v.encode()) >= cap: errs.append("%s is too long (%d bytes, max %d)" % (k, len(v.encode()), cap - 1))
if errs:
    sys.exit("NEMESIS.data would be refused: " + "; ".join(errs))
print("NEMESIS.data ok: short-desc %d/%d, detailed-desc %d/%d characters" % (
    len(get("short-desc") or ""), SHORT_MAX, len(get("detailed-desc") or ""), DETAIL_MAX))
