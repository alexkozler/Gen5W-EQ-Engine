#!/bin/bash
# PC tests for native/eqe_lab.c (the Lab's 48 kHz helper): link rates from a simulated
# /proc/asound, and the AudioSystem calls through stand-in libraries. Run from anywhere.
R=$(cd "$(dirname "$0")/../.." && pwd)
O=/tmp/eqelab
rm -rf $O; mkdir -p $O
SAN="-fsanitize=address,undefined -fno-sanitize-recover=undefined"
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }

gcc -std=c11 -O1 -g -Wall -Wextra -Werror $SAN -o $O/eqe_lab $R/native/eqe_lab.c -ldl || exit 1
gcc -std=c11 -O1 -g -fPIC -shared -DUTILS -o $O/libutils_fake.so $R/tests/lab/fake_audiosystem.c || exit 1
gcc -std=c11 -O1 -g -fPIC -shared -DMEDIA -o $O/libmedia_fake.so $R/tests/lab/fake_audiosystem.c || exit 1
gcc -std=c11 -O1 -g -fPIC -shared -DMEDIA -DNO_GET -o $O/libmedia_noget.so $R/tests/lab/fake_audiosystem.c || exit 1
export EQE_ASOUND=$O/asound EQE_UTILS_LIB=$O/libutils_fake.so EQE_MEDIA_LIB=$O/libmedia_fake.so FAKE_LOG=$O/calls.log
L=$O/asound/card0/pcm2p/sub0
mkdir -p $L $O/asound/card0/pcm0p/sub0
echo closed > $O/asound/card0/pcm0p/sub0/status
echo closed > $O/asound/card0/pcm0p/sub0/hw_params
link() {  # $1 rate (hw_params) $2 frames/s really taken $3 seconds since start $4 owner
    printf 'access: RW_INTERLEAVED\nformat: S16_LE\nsubformat: STD\nchannels: 2\nrate: %s (%s/1)\nperiod_size: 2048\nbuffer_size: 8192\n' $1 $1 > $L/hw_params
    awk -v f=$2 -v s=$3 -v o=$4 'BEGIN { printf "state: RUNNING\nowner_pid   : %d\ntrigger_time: 100.000000000\ntstamp      : %.9f\ndelay       : 6576\navail       : 1616\navail_max   : 6144\n-----\nhw_ptr      : %d\nappl_ptr    : %d\n", o, 100 + s, f * s, f * s + 6000 }' > $L/status.tmp
    mv $L/status.tmp $L/status
}

echo "== 1. one reading: frames since the link started"
link 44100 44100 81.3 4258
out=$($O/eqe_lab rate 0)
ok "44100 Hz link, 44100 frames/s, owner shown" "[ \"\$out\" = 'link pcm2p card0 state=RUNNING owner=4258 rate=44100 fps=44100.0' ]"

echo "== 2. two readings 300 ms apart (the counter keeps moving)"
link 48000 48000 10 4258
( sleep 0.15; link 48000 48000 10.5 4258 ) &
out=$($O/eqe_lab rate 300); wait
ok "48000 frames/s from the change between readings" "echo \"\$out\" | grep -q 'rate=48000 fps=48000.0\$'"
link 48000 44100 10 4258
( sleep 0.15; link 48000 44100 12 4258 ) &
out=$($O/eqe_lab rate 300); wait
ok "a link set to 48000 that takes 44100 frames/s is reported as such" "echo \"\$out\" | grep -q 'rate=48000 fps=44100.0\$'"

echo "== 3. the link restarted or stopped between readings"
link 44100 44100 50 4258
( sleep 0.15; link 44100 44100 2 4300 ) &
out=$($O/eqe_lab rate 300); wait
ok "new owner: no rate, marked restarted" "echo \"\$out\" | grep -q 'fps=0.0 restarted\$'"
link 44100 44100 50 4258
( sleep 0.15; echo closed > $L/status ) &
out=$($O/eqe_lab rate 300); wait
ok "closed: marked stopped" "echo \"\$out\" | grep -q 'fps=0.0 stopped\$'"
echo closed > $L/status
ok "nothing playing: link none" "[ \"\$($O/eqe_lab rate 100)\" = 'link none' ]"

echo "== 4. Android's settings, through the stand-in libraries"
: > $O/calls.log
out=$($O/eqe_lab set 101 sampling_rate=48000)
ok "set: one call, io and text as given, status printed" "[ \"\$out\" = 'status 0' ] && [ \"\$(cat $O/calls.log)\" = 'set io 101 \"sampling_rate=48000\"' ]"
out=$(FAKE_SET_STATUS=-22 $O/eqe_lab set 101 sampling_rate=48000)
ok "the driver's refusal comes back" "[ \"\$out\" = 'status -22' ]"
out=$($O/eqe_lab get 101 sampling_rate)
ok "get: answer printed" "[ \"\$out\" = 'answer sampling_rate=44100' ]"
: > $O/calls.log
$O/eqe_lab set 101 'sampling_rate=48000;x=$(reboot)' > $O/bad.txt 2>&1; rc=$?
ok "text other than plain key=value is refused, nothing sent" "[ $rc = 2 ] && [ ! -s $O/calls.log ]"
$O/eqe_lab set -5 sampling_rate=48000 > /dev/null 2>&1; rc=$?
ok "a bad io handle is refused" "[ $rc = 2 ] && [ ! -s $O/calls.log ]"
out=$(EQE_MEDIA_LIB=$O/libmedia_noget.so $O/eqe_lab get 101 sampling_rate); rc=$?
ok "a missing Android function: says which, does nothing" "[ $rc = 2 ] && echo \"\$out\" | grep -q 'EQE_LAB_ERR missing _ZN7android11AudioSystem13getParameters'"
out=$(EQE_MEDIA_LIB=$O/nothing.so $O/eqe_lab set 101 sampling_rate=48000); rc=$?
ok "Android's library missing: error, nothing sent" "[ $rc = 2 ] && echo \"\$out\" | grep -q 'EQE_LAB_ERR could not load' && [ ! -s $O/calls.log ]"

echo "== 5. check (for the car report): looks the functions up, calls nothing"
: > $O/calls.log
out=$($O/eqe_lab check); rc=$?
ok "all four found" "[ $rc = 0 ] && [ \"\$out\" = 'symbols 4 of 4' ] && [ ! -s $O/calls.log ]"
out=$(EQE_MEDIA_LIB=$O/libmedia_noget.so $O/eqe_lab check); rc=$?
ok "one missing: named, 3 of 4" "[ $rc = 2 ] && echo \"\$out\" | grep -q 'missing _ZN7android11AudioSystem13getParameters' && echo \"\$out\" | grep -q 'symbols 3 of 4'"

echo "== 6. umount (the driver watch while the audio server still has it open)"
$O/eqe_lab umount /data/local/tmp/x > $O/u.txt 2>&1; rc=$?
ok "a path that is not one of EQ Engine's mounts is refused" "[ $rc = 2 ]"
$O/eqe_lab umount $O/../x/system/lib/hw/audio.primary.tcc803x.so > $O/u.txt 2>&1; rc=$?
ok "a path with .. is refused" "[ $rc = 2 ]"
mkdir -p $O/root/system/lib/hw; touch $O/root/system/lib/hw/audio.primary.tcc803x.so
out=$($O/eqe_lab umount $O/root/system/lib/hw/audio.primary.tcc803x.so); rc=$?
ok "the driver file, not mounted here: tried, the error comes back" "[ $rc = 1 ] && echo \"\$out\" | grep -q '^failed: '"

echo "== 7. imports: a library's dynamic symbol table, read defensively (the car report's CarPlay probe)"
# The ARM libraries of the last build are the test inputs (read only). Damaged copies are made
# from the driver watch: each must fail with one error line, never with a sanitizer report.
DW=$R/native/out/eqe_drvwatch.so; EL=$R/native/out/libeqengine.so
imp() { timeout 10 $O/eqe_lab imports "$1" > $O/imp.txt 2> $O/imp.err; echo $? > $O/imp.rc; }
irc() { cat $O/imp.rc; }
clean() { ! grep -q -e AddressSanitizer -e LeakSanitizer -e 'runtime error' $O/imp.err; }
wellformed() { ! grep -v -E '^(needed|import|export) [!-~]+$' $O/imp.txt | grep -q .; }
oneerr() { [ "$(irc)" = 1 ] && [ "$(wc -l < $O/imp.txt)" = 1 ] && grep -q '^EQE_LAB_ERR imports: ' $O/imp.txt && clean; }
if [ ! -f $DW ] || [ ! -f $EL ]; then
    fail=$((fail+1)); echo "  FAIL native/out/eqe_drvwatch.so and libeqengine.so are needed (sh native/build.sh)"
else
imp $DW; cp $O/imp.txt $O/dw.txt
ok "driver watch: its needed libraries, imports and exports, one per line" "[ \"\$(irc)\" = 0 ] && clean && wellformed && grep -qx 'needed libdl.so' $O/imp.txt && grep -qx 'needed libc.so' $O/imp.txt && grep -qx 'import dlopen' $O/imp.txt && grep -qx 'import dlsym' $O/imp.txt && grep -qx 'export HMI' $O/imp.txt && [ \"\$(head -n1 $O/imp.txt)\" = 'needed libdl.so' ]"
ok "driver watch: undefined symbols are imports only, never exports" "! grep -qx 'export dlopen' $O/imp.txt && ! grep -qx 'import HMI' $O/imp.txt"
imp $EL
ok "EQ Engine's filter: needs liblog.so, imports memcpy, exports AELI and nothing else" "[ \"\$(irc)\" = 0 ] && clean && grep -qx 'needed liblog.so' $O/imp.txt && grep -qx 'import memcpy' $O/imp.txt && [ \"\$(grep '^export' $O/imp.txt)\" = 'export AELI' ]"
mkdir -p $O/elf
python3 - "$DW" "$O/elf" <<'PY' || { fail=$((fail+1)); echo "  FAIL making the damaged copies"; }
import os, random, struct, sys
src, out = sys.argv[1], sys.argv[2]
b = bytearray(open(src, "rb").read())
u32 = lambda o: struct.unpack_from("<I", b, o)[0]
phoff, phnum = u32(28), struct.unpack_from("<H", b, 44)[0]
ph = [struct.unpack_from("<8I", b, phoff + 32 * i) for i in range(phnum)]
dyn = next(p for p in ph if p[0] == 2)
def v2o(va):
    for p in ph:
        if p[0] == 1 and p[2] <= va < p[2] + p[4]: return va - p[2] + p[1]
    raise SystemExit("address not in the file")
tags = {}
for o in range(dyn[1], dyn[1] + dyn[4], 8):
    t, v = struct.unpack_from("<iI", b, o)
    if t == 0: break
    tags.setdefault(t, []).append((o, v))
def save(name, d): open(os.path.join(out, name), "wb").write(bytes(d))
def tagged(t, val=None, newtag=None):
    d = bytearray(b); o = tags[t][0][0]
    if newtag is not None: struct.pack_into("<i", d, o, newtag)
    if val is not None: struct.pack_into("<I", d, o + 4, val)
    return d
DEBUG = 21
save("gnuhash.so", tagged(4, newtag=DEBUG))                       # DT_HASH gone: count from DT_GNU_HASH
d = tagged(4, newtag=DEBUG); struct.pack_into("<i", d, tags[0x6ffffef5][0][0], DEBUG); save("nohash.so", d)
save("trunc40.so", b[:40]); save("trunc3000.so", b[:3000]); save("trunc_dyn.so", b[:dyn[1] + 20])
save("garbage.bin", random.Random(1).randbytes(8192))
d = bytearray(b); struct.pack_into("<I", d, 28, 0xfffffff0); save("phoff.so", d)
d = bytearray(b); struct.pack_into("<H", d, 44, 0xffff); save("phnum.so", d)
d = bytearray(b); struct.pack_into("<I", d, phoff + 32 * ph.index(dyn) + 16, 0xffffffff); save("dynsize.so", d)
save("strsz.so", tagged(10, 0x7fffffff)); save("strtab.so", tagged(5, 0xfffffff0)); save("symtab.so", tagged(6, 0xfffffff0))
save("needed.so", tagged(1, 0xffffff00)); save("syment.so", tagged(11, 24))
h = v2o(tags[4][0][1])
d = bytearray(b); struct.pack_into("<I", d, h + 4, 0xffffffff); save("nchain_huge.so", d)
d = bytearray(b); struct.pack_into("<I", d, h + 4, 900000); save("nchain_big.so", d)
st = v2o(tags[6][0][1])
d = bytearray(b); struct.pack_into("<I", d, st + 16, 0xffffff00); save("stname.so", d)
g = v2o(tags[0x6ffffef5][0][1])
d = tagged(4, newtag=DEBUG); struct.pack_into("<I", d, g, 0xffffffff); save("gnu_nbuckets.so", d)
nb, so, bl = struct.unpack_from("<3I", b, g)
d = tagged(4, newtag=DEBUG); struct.pack_into("<I", d, g + 16 + 4 * bl, 999999); save("gnu_bucket.so", d)
# a control character in a name ("dlopen" -> "dl\npen") must not start a line of its own
s = v2o(tags[5][0][1]); i = b.index(b"\0dlopen\0", s) + 3
d = bytearray(b); d[i] = 10; save("ctl.so", d)
# random damage anywhere in the file
r = random.Random(7)
for k in range(300):
    d = bytearray(b)
    for _ in range(r.randint(1, 8)):
        if r.random() < 0.5: o = r.randrange(len(d))
        else: o = r.randrange(dyn[1], min(len(d), dyn[1] + dyn[4]))
        d[o] = r.randrange(256)
    save("fuzz%03d.so" % k, d)
PY
imp $O/elf/gnuhash.so
ok "only a GNU hash table: the same symbols, counted from it" "[ \"\$(irc)\" = 0 ] && clean && cmp -s $O/imp.txt $O/dw.txt"
imp $O/elf/nohash.so
ok "no hash table at all: refused (the symbol count is not known)" "oneerr && grep -q 'no hash table' $O/imp.txt"
for f in trunc40 trunc3000 trunc_dyn garbage phoff phnum dynsize strsz strtab symtab needed syment nchain_huge nchain_big stname gnu_nbuckets gnu_bucket; do
    n=$f.so; [ $f = garbage ] && n=garbage.bin
    imp $O/elf/$n
    ok "damaged ($f): one error line, no sanitizer report: $(cat $O/imp.txt | head -n1)" "oneerr"
done
imp $O/elf/ctl.so
ok "a control character in a name is printed as ?" "[ \"\$(irc)\" = 0 ] && clean && wellformed && grep -qx 'import dl?pen' $O/imp.txt"
imp $O/eqe_lab
ok "a 64-bit ELF file (this PC's build): refused" "oneerr && grep -q 'not a 32-bit ELF' $O/imp.txt"
imp $O/elf
ok "a folder: refused" "oneerr && grep -q 'not a regular file' $O/imp.txt"
mkfifo $O/fifo; imp $O/fifo
ok "a pipe: refused without waiting for a writer" "oneerr"
imp $O/missing.so
ok "a missing file: refused" "oneerr && grep -q 'cannot open' $O/imp.txt"
fz_bad=0; fz_ok=0; fz_err=0
for f in $O/elf/fuzz*.so; do
    imp $f
    case "$(irc)" in
        0) if clean && wellformed; then fz_ok=$((fz_ok+1)); else fz_bad=$((fz_bad+1)); echo "       | ${f##*/}: $(head -c 300 $O/imp.err)"; fi ;;
        1) if oneerr; then fz_err=$((fz_err+1)); else fz_bad=$((fz_bad+1)); echo "       | ${f##*/}: $(head -c 300 $O/imp.err)"; fi ;;
        *) fz_bad=$((fz_bad+1)); echo "       | ${f##*/}: exit $(irc) $(head -c 300 $O/imp.err)" ;;
    esac
done
ok "300 randomly damaged copies: each read or refused cleanly ($fz_ok read, $fz_err refused)" "[ $fz_bad = 0 ]"
fi

echo "== (0.8.0) ns <pid> <program> [args]: in another process's mount namespace"
ns() { $O/eqe_lab ns "$@" > $O/ns.out 2> $O/ns.err; echo $? > $O/ns.rc; }
nsrc() { cat $O/ns.rc; }
ns x /bin/echo hi
ok "ns: a pid that is not a number: usage, nothing run" "[ \$(nsrc) = 2 ] && [ ! -s $O/ns.out ]"
ns 0 /bin/echo hi
ok "ns: pid 0: usage" "[ \$(nsrc) = 2 ]"
ns 1 echo hi
ok "ns: a program without an absolute path: usage" "[ \$(nsrc) = 2 ] && [ ! -s $O/ns.out ]"
ns 1 /bin/../bin/echo hi
ok "ns: a program path with ..: usage" "[ \$(nsrc) = 2 ]"
mkdir -p $O/proc/77
EQE_PROC=$O/proc ns 77 /bin/echo hi
ok "ns: the process has no mount namespace file: one 'ns failed' line, nothing run" "[ \$(nsrc) = 1 ] && [ \"\$(cat $O/ns.out)\" = 'ns failed: $O/proc/77/ns/mnt: No such file or directory' ]"
ns $$ /bin/echo hi
ok "ns: into this shell's own namespace: run there, or (without CAP_SYS_ADMIN) one 'ns failed: setns' line" "{ [ \$(nsrc) = 0 ] && [ \"\$(cat $O/ns.out)\" = hi ]; } || { [ \$(nsrc) = 1 ] && grep -q '^ns failed: setns /proc/$$/ns/mnt: ' $O/ns.out; }"

echo "lab helper: $pass passed, $fail failed"
[ $fail = 0 ]
