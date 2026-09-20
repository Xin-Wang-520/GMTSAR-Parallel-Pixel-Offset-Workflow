#!/usr/bin/env python3
"""Generate synthetic SLC pairs + minimal PRM files for xcorr_mt testing."""
import numpy as np
import os

PRM_TMPL = """SLC_file = {slc}
num_rng_bins = {nx}
num_patches = 1
num_valid_az = {ny}
rshift = {rshift}
ashift = {ashift}
PRF = {prf}
"""


def make_complex_pair(nx, ny, dx, dy, seed):
    rng = np.random.default_rng(seed)
    re = rng.standard_normal((ny, nx)) * 800.0
    im = rng.standard_normal((ny, nx)) * 800.0
    m = np.empty((ny, nx, 2), dtype=np.float64)
    m[:, :, 0] = re
    m[:, :, 1] = im
    ms = np.clip(np.round(m), -30000, 30000).astype("<i2")  # little-endian short pairs
    a = np.zeros_like(ms)
    a[dy:, dx:, :] = ms[:-dy, :-dx, :]
    return ms.reshape(ny, 2 * nx), a.reshape(ny, 2 * nx)


def write_prm(name, slc, nx, ny, rshift=0, ashift=0, prf=2000.0):
    with open(name, "w") as f:
        f.write(PRM_TMPL.format(slc=slc, nx=nx, ny=ny, rshift=rshift, ashift=ashift, prf=prf))


def make_float_pair(nx, ny, dx, dy, seed):
    rng = np.random.default_rng(seed)
    m = np.abs(rng.standard_normal((ny, nx))).astype("<f4") * 1000.0
    a = np.zeros_like(m)
    a[dy:, dx:] = m[:-dy, :-dx]
    return m, a


os.chdir(os.path.dirname(os.path.abspath(__file__)))

# --- small config: default search windows (xsearch=64), -nx 20 -ny 50 ---
nx, ny, dx, dy = 4096, 1500, 3, 2
m, a = make_complex_pair(nx, ny, dx, dy, seed=1234)
m.tofile("master.slc")
a.tofile("aligned.slc")
write_prm("master.PRM", "master.slc", nx, ny)
write_prm("aligned.PRM", "aligned.slc", nx, ny, rshift=1, ashift=2)

# --- big config: align.csh windows (-xsearch 128 -ysearch 128), timing test ---
nxb, nyb = 6144, 2048
mb, ab = make_complex_pair(nxb, nyb, dx, dy, seed=5678)
mb.tofile("masterB.slc")
ab.tofile("alignedB.slc")
write_prm("masterB.PRM", "masterB.slc", nxb, nyb)
write_prm("alignedB.PRM", "alignedB.slc", nxb, nyb, rshift=1, ashift=2)

# --- float pair for -real (format 1) and .grd (format 2) tests ---
mf, af = make_float_pair(nx, ny, dx, dy, seed=999)
mf.tofile("master.flt")
af.tofile("aligned.flt")

print("generated: master/aligned .slc + .PRM (small & big), master/aligned .flt")
