#!/bin/bash
# Edge-case tests for xcorr_mt argument handling.
cd "$(dirname "$0")"
ORIG=/usr/local/GMTSAR/bin/xcorr
MT=../xcorr_mt

echo "=== clamp: -nproc 5000 > nlocs=1000 ==="
$MT master.PRM aligned.PRM -nx 20 -ny 50 -nproc 5000 > e_clamp.log 2>&1 || echo "exit=$?"
cmp -s freq_xcorr.dat ref_freq.dat && echo "clamp: BYTE-IDENTICAL" || echo "clamp: DIFFERS"

echo "=== env: OMP_NUM_THREADS=7 (no -nproc) ==="
OMP_NUM_THREADS=7 $MT master.PRM aligned.PRM -nx 20 -ny 50 > e_env.log 2>&1 || echo "exit=$?"
cmp -s freq_xcorr.dat ref_freq.dat && echo "env: BYTE-IDENTICAL" || echo "env: DIFFERS"

echo "=== invalid: -nproc 0 (fallback) ==="
$MT master.PRM aligned.PRM -nx 20 -ny 50 -nproc 0 > e_zero.log 2>&1 || echo "exit=$?"
cmp -s freq_xcorr.dat ref_freq.dat && echo "zero: BYTE-IDENTICAL" || echo "zero: DIFFERS"

echo "=== invalid: -nproc abc (fallback) ==="
$MT master.PRM aligned.PRM -nx 20 -ny 50 -nproc abc > e_abc.log 2>&1 || echo "exit=$?"
cmp -s freq_xcorr.dat ref_freq.dat && echo "abc: BYTE-IDENTICAL" || echo "abc: DIFFERS"

echo "=== -nproc wins over OMP_NUM_THREADS=3 ==="
OMP_NUM_THREADS=3 $MT master.PRM aligned.PRM -nx 20 -ny 50 -nproc 5 > e_win.log 2>&1 || echo "exit=$?"
grep -q "using 5 worker processes" e_win.log && echo "priority: -nproc honored" || echo "priority: NOT honored"

echo "=== missing arg: -nproc (expect die, exit!=0) ==="
$MT master.PRM aligned.PRM -nx 20 -ny 50 -nproc > e_miss.log 2>&1
[ $? -ne 0 ] && echo "missing-arg: died as expected" || echo "missing-arg: UNEXPECTED SUCCESS"

echo "=== usage shows -nproc ==="
$MT 2>&1 | grep -q "nproc" && echo "usage: -nproc documented" || echo "usage: MISSING"

echo "=== leftover part files? ==="
ls freq_xcorr.dat.part.* 2>/dev/null && echo "LEFTOVER PARTS" || echo "no part files left"

echo "=== DONE ==="
