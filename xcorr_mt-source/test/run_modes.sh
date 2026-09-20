#!/bin/bash
# Mode coverage tests for xcorr_mt vs original xcorr.
cd "$(dirname "$0")"
ORIG=/usr/local/GMTSAR/bin/xcorr
MT=../xcorr_mt
fail=0

check() { # $1=label $2=file $3=ref
  if cmp -s "$2" "$3"; then echo "$1: BYTE-IDENTICAL"; else echo "$1: DIFFERS"; fail=1; fi
}

echo "=== -time mode (96 pts, uneven chunks) ==="
$ORIG master.PRM aligned.PRM -time -nx 8 -ny 12 -xsearch 32 -ysearch 32 > t_orig.log 2>&1 || { echo "orig -time FAILED"; exit 1; }
mv time_xcorr.dat ref_time.dat
for n in 1 4 7; do
  $MT master.PRM aligned.PRM -time -nx 8 -ny 12 -xsearch 32 -ysearch 32 -nproc $n > t_mt_$n.log 2>&1 || echo "mt -time nproc=$n exit=$?"
  check "time nproc=$n" time_xcorr.dat ref_time.dat
done

echo "=== -real mode (float, via PRM) ==="
$ORIG masterF.PRM alignedF.PRM -real -nx 20 -ny 50 > r_orig.log 2>&1 || { echo "orig -real FAILED"; exit 1; }
mv freq_xcorr.dat ref_real.dat
for n in 1 7 20; do
  $MT masterF.PRM alignedF.PRM -real -nx 20 -ny 50 -nproc $n > r_mt_$n.log 2>&1 || echo "mt -real nproc=$n exit=$?"
  check "real nproc=$n" freq_xcorr.dat ref_real.dat
done

echo "=== .grd mode (netCDF, format 2) ==="
$ORIG master.grd aligned.grd -nx 20 -ny 50 > g_orig.log 2>&1 || { echo "orig grd FAILED"; exit 1; }
mv freq_xcorr.dat ref_grd.dat
for n in 1 7 20; do
  $MT master.grd aligned.grd -nx 20 -ny 50 -nproc $n > g_mt_$n.log 2>&1 || echo "mt grd nproc=$n exit=$?"
  check "grd nproc=$n" freq_xcorr.dat ref_grd.dat
done

echo "=== big config, align.csh params (-xsearch 128 -ysearch 128) ==="
$ORIG masterB.PRM alignedB.PRM -xsearch 128 -ysearch 128 -nx 20 -ny 50 > b_orig.log 2>&1 || { echo "orig big FAILED"; exit 1; }
mv freq_xcorr.dat ref_big.dat
for n in 1 7 20; do
  $MT masterB.PRM alignedB.PRM -xsearch 128 -ysearch 128 -nx 20 -ny 50 -nproc $n > b_mt_$n.log 2>&1 || echo "mt big nproc=$n exit=$?"
  check "big nproc=$n" freq_xcorr.dat ref_big.dat
done

echo "=== DONE (fail=$fail) ==="
exit $fail
