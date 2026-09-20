# xcorr_mt — multi-process drop-in replacement for GMTSAR `xcorr`

`xcorr_mt` accelerates the GMTSAR 2-D cross-correlation program `xcorr` (used by
`align.csh`, `p2p_processing.csh`, `align_batch.csh`, `align_ALOS*.csh`,
`make_a_offset.csh`, …) by splitting its independent measurement grid over
multiple worker **processes** — while producing **byte-identical** output
(`freq_xcorr.dat` / `time_xcorr.dat`) compared to the stock single-process
`xcorr`.

- **Drop-in replacement**: same CLI, same input/output format — just change the
  command name in your scripts.
- **Byte-identical results**: verified on real Sentinel-1 IW SLC data
  (25024×12188) for `-freq` / `-time` / `-real` / `.grd` modes, including
  4000-point dense grids; downstream `fitoffset.csh` alignment parameters are
  line-by-line identical.
- **Zero GMTSAR modifications**: builds against the unmodified `libgmtsar.a`
  and GMT libraries; the original `xcorr` stays untouched.
- **Auto parallel**: uses `cores − 2` workers by default; override with
  `-nproc N` or `OMP_NUM_THREADS`.

![Coherence (corr) map on real Sentinel-1 data](doc/figs/fig4_corr_map.png)

*Correlation-quality field (radar coordinates, SLC amplitude backdrop) from a
Sentinel-1 IW2 pair — left/right: two window configurations; outputs are
byte-identical between `xcorr` and `xcorr_mt`.*

## Performance

Measured on a 20-core machine, Sentinel-1 IW2 pair, 1000-point grid
(`-nx 20 -ny 50`):

| Parameters | stock `xcorr` | `xcorr_mt` (auto, 18 workers) | Speedup |
|---|---|---|---|
| `-xsearch 128 -ysearch 256` (align.csh non-ERS) | 657 s | **128 s** | **5.1×** |
| `-xsearch 128 -ysearch 128` (p2p non-TOPS) | 354 s | **79 s** | **4.5×** |
| `-xsearch 128 -ysearch 128`, 40×100 = 4000 pts | 1365 s | **319 s** | **4.3×** |

![Timing and speedup](doc/figs/fig1_timing.png)

## Requirements

- Linux with `fork()` (any modern distro)
- A built **GMTSAR 6.x** tree (provides `gmtsar/libgmtsar.a` and headers) and
  GMT development files (`gmt-config`, `libgmt`)
- gcc, make

## Build & install

```bash
git clone https://github.com/Jazz-0626/xcorr_mt.git
cd xcorr_mt
make                      # override GMTSAR_HOME if yours differs:
                          # make GMTSAR_HOME=/opt/GMTSAR
sudo cp xcorr_mt /usr/local/GMTSAR/bin/   # or anywhere on your PATH
```

## Usage

Replace `xcorr` with `xcorr_mt` — nothing else changes:

```csh
# align.csh / p2p_processing.csh, before:
xcorr $master.PRM $aligned.PRM -xsearch 128 -ysearch 128 -nx 20 -ny 50
# after:
xcorr_mt $master.PRM $aligned.PRM -xsearch 128 -ysearch 128 -nx 20 -ny 50
```

Worker-count precedence: `-nproc N` > `OMP_NUM_THREADS` > automatic
(online cores − 2, min 1). Count is capped at online cores and at the number of
measurement points.

Memory note: each worker holds its own data patches
(≈ 2 × `num_rng_bins` × `npy` × 8 bytes, e.g. ~0.2–0.4 GB for a Sentinel-1
subswath), so total memory scales with the worker count.

## How it works

Each correlation location is fully independent and results are written in grid
order. `xcorr_mt` forks N workers after parsing the inputs, assigns each a
contiguous block of locations, lets each compute with the **same unmodified
GMT/GMTSAR numerical code**, then concatenates the per-worker outputs in order.
Because the FFT and correlation kernels are untouched, results are
byte-identical, not just numerically equivalent.

## Verification

Full real-data verification (md5 checksums, determinism analysis, fitoffset
end-to-end comparison, dense-grid tests, field maps): see
[doc/REPORT_xcorr_mt.md](doc/REPORT_xcorr_mt.md)
([PDF](doc/REPORT_xcorr_mt.pdf)).

![1000 vs 4000 point density](doc/figs/fig6_dense_corr.png)

## 中文摘要

`xcorr_mt` 是 GMTSAR `xcorr` 的多进程加速版:fork 多进程分块处理测点网格,
输出与原版**逐字节一致**(真实 Sentinel-1 数据验证,含 4000 点密集网格),
20 核机器上约 **4.3–5.1×** 加速。用法:脚本中把 `xcorr` 改为 `xcorr_mt` 即可,
默认自动使用 `核数−2` 个进程,可用 `-nproc N` 或 `OMP_NUM_THREADS` 控制。
不改动 GMTSAR 任何源码,编译时链接未修改的 `libgmtsar.a`。
详细验证报告见 `doc/REPORT_xcorr_mt.md`(中文)。

## License

GPL v3 — derived from GMTSAR `xcorr.c` (© GMTSAR authors). See
[LICENSE](LICENSE). The original GMTSAR project:
https://github.com/gmtsar/gmtsar
