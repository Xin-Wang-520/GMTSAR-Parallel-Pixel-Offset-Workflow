# CPU-Parallel GMTSAR Pixel-Offset Workflow

**Author:** Wang Xin  
**Date:** 2026-09-20  
**Affiliation:** University of Science and Technology of China (USTC)  
**Contact:** xinw11@mail.ustc.edu.cn

**Language / 语言：** [English](#english) · [中文说明](#中文)

---

# English

**[跳转到中文说明](#中文)**

## 1. Overview

This directory provides a staged workflow for CPU-parallel pixel-offset
tracking with GMTSAR. It installs and calls `xcorr_mt`, prepares a separate
offset workspace, recommends a sampling grid from PRM metadata, runs the
cross-correlation with progress reporting, creates geocoded range/azimuth
products, and optionally filters the final grids.

The stock GMTSAR `xcorr` and `make_a_offset.csh` are not overwritten.
`make_a_offset_mt.csh` adapts the stock driver at runtime and redirects only
its internal cross-correlation command to `xcorr_mt`.

```text
Run0  Install/check xcorr_mt and make_a_offset_mt.csh
  ↓
Run1  Prepare offset/SLC, offset/topo, and one pair directory
  ↓
Run2  Read PRMs and save recommended sampling parameters
  ↓
Run3  Run CPU-parallel cross-correlation with progress reporting
  ↓
Run4  Build range/azimuth metre grids, PDF maps, and Google Earth KMZ files
  ↓
Run5  Apply configurable median + Gaussian filtering
```

The scripts do not require the older `run_offset_mt.sh` helper.

## 2. Scripts and execution convention

| Script | Purpose |
|---|---|
| `run0_install_xcorr_mt.sh` | Install or verify `xcorr_mt` and its wrapper |
| `run1_prepare_offset.sh` | Create an isolated offset workspace with symbolic links |
| `run2_recommend_grid.sh` | Recommend `nx/ny` and write `offset_run.conf` |
| `run3_run_offset.sh` | Run parallel tracking with progress and logging |
| `run4_make_range_azimuth_grids_and_plots.sh` | Build geocoded component grids and maps |
| `run5_filter_offset_grids.sh` | Filter the two geocoded metre grids |

All stages use the same safety convention:

```bash
./runN_script.sh       # preview only
./runN_script.sh 1     # execute the previewed operation
```

Existing results are protected. `--replace` is required to rerun the same
stage over the same output directory.

After a stage completes successfully, Run1 through Run4 print the preview and
execution commands for the next stage. Run5 prints a workflow-complete message
and examples for testing another filter without overwriting the current one.

## 3. Requirements and input data

Required software:

- Bash and C shell;
- GMTSAR with `xcorr` and `make_a_offset.csh`;
- GMT with `gmt` and `gmt-config`;
- `gcc`, `find`, and `install`;
- `gmtsar.h` and `libgmtsar.a`;
- LAPACK, BLAS, TIFF, and math libraries;
- `zip` for KMZ creation;
- Linux `setsid` and `pgrep` for Run3 process/progress management.

Conda is optional. Run0 can use a Conda environment or a system installation
available through the current `PATH`.

Expected project layout:

```text
PROJECT/
├── SLC/
│   ├── MASTER.PRM
│   ├── MASTER.SLC
│   ├── ALIGNED.PRM
│   └── ALIGNED.SLC
├── topo/
│   ├── dem.grd
│   └── trans.dat
├── intf_all/
│   └── PAIR_NAME/
└── offset/
    ├── run0_install_xcorr_mt.sh
    ├── run1_prepare_offset.sh
    ├── run2_recommend_grid.sh
    ├── run3_run_offset.sh
    ├── run4_make_range_azimuth_grids_and_plots.sh
    └── run5_filter_offset_grids.sh
```

The PRMs must contain valid `num_rng_bins`, `num_valid_az`, `SLC_file`, `PRF`,
`SC_vel`, `earth_radius`, `SC_height`, and `rng_samp_rate` values. LED files may
remain with the source data, but these stages primarily use PRM, SLC,
`trans.dat`, and `dem.grd`. Run1 and Run2 expect one offset pair and exactly two
PRM files under `PROJECT/SLC`.

## 4. Run0: install the CPU-parallel program

```bash
./run0_install_xcorr_mt.sh       # preview
./run0_install_xcorr_mt.sh 1     # install
```

Run0 installs these commands without replacing stock GMTSAR programs:

```text
$HOME/bin/xcorr_mt
$HOME/bin/make_a_offset_mt.csh
```

### Conda mode

The current Conda environment is used by default. `base` is supported when it
contains the required development files; a dedicated GMTSAR environment is
recommended but not mandatory.

```bash
conda activate YOUR_GMTSAR_ENV
./run0_install_xcorr_mt.sh 1

# Select without prior activation
./run0_install_xcorr_mt.sh 1 --env YOUR_GMTSAR_ENV
```

### System mode without Conda

Without Conda, Run0 automatically checks the current `PATH` and installation
prefixes associated with `xcorr`, `make_a_offset.csh`, and `gmt-config`.

```bash
./run0_install_xcorr_mt.sh --system
./run0_install_xcorr_mt.sh 1 --system
```

For a nonstandard GMTSAR build tree:

```bash
GMTSAR_DEV_ROOT=/path/to/GMTSAR \
./run0_install_xcorr_mt.sh 1 --system
```

The preview reports resolved paths for `xcorr`, `make_a_offset.csh`,
`gmt-config`, `gcc`, `gmtsar.h`, and `libgmtsar.a`.

### Source acquisition and offline installation

This workflow repository includes `xcorr_mt-source` as a Git submodule pinned
to the upstream `Jazz-0626/xcorr_mt` repository. Clone the complete workflow
with:

```bash
git clone --recurse-submodules \
  git@github.com:Xin-Wang-520/GMTSAR-Parallel-Pixel-Offset-Workflow.git
```

If the workflow was cloned without submodules:

```bash
git submodule update --init --recursive
```

Run0 searches for `xcorr_mt.c` in this order:

1. `offset/xcorr_mt-source/xcorr_mt.c`;
2. `$HOME/src/xcorr_mt/xcorr_mt.c`;
3. clone <https://github.com/Jazz-0626/xcorr_mt>.

If the server cannot access GitHub, download and extract the repository on
another computer, then upload it so this file exists:

```text
PROJECT/offset/xcorr_mt-source/xcorr_mt.c
```

Then rerun Run0. An arbitrary source directory can be supplied with:

```bash
./run0_install_xcorr_mt.sh 1 --source-dir /path/to/xcorr_mt
```

Use `1 --replace` only for an intentional rebuild.

## 5. Run1: prepare the offset workspace

### Before Run1

For the standard no-argument workflow, first create `PROJECT/offset`, copy all
Run scripts into it, and run Run1 from that directory:

```bash
PROJECT=/path/to/your/project
mkdir -p "$PROJECT/offset"
cp run{0,1,2,3,4,5}_*.sh "$PROJECT/offset/"
cd "$PROJECT/offset"
chmod +x run{0,1,2,3,4,5}_*.sh
```

The parent project must already contain `SLC/`, `topo/`, and normally one pair
under `intf_all/`. Before creating anything, the Run1 preview verifies:

- exactly two PRM files under `PROJECT/SLC`;
- the `SLC_file` named by each PRM exists under `PROJECT/SLC`;
- both PRMs contain valid and matching `num_rng_bins/num_valid_az` values;
- `PROJECT/topo/dem.grd` and `PROJECT/topo/trans.dat` exist;
- the pair and planned offset paths.

If any required input is missing, Run1 stops without creating the workspace.

```bash
./run1_prepare_offset.sh
./run1_prepare_offset.sh 1
```

Run1 detects the single pair under `PROJECT/intf_all`, creates
`offset/intf/PAIR_NAME`, and creates links without copying large SLC files:

```text
offset/SLC  -> ../SLC
offset/topo -> ../topo
```

Explicit project/pair syntax:

```bash
./run1_prepare_offset.sh PROJECT_DIR PAIR_NAME
./run1_prepare_offset.sh 1 PROJECT_DIR PAIR_NAME
```

## 6. Run2: recommend and save the sampling grid

```bash
./run2_recommend_grid.sh       # inspect PRMs and preview
./run2_recommend_grid.sh 1     # save offset_run.conf
```

Run2 reports image dimensions, SLC names, integer/subpixel shifts, recommended
`nx/ny`, total point count, centre spacing, integer `x_inc/y_inc`, search
arguments, internal window size, and CPU worker count.

The default target is approximately 4.8 million samples, following the PRM
image aspect ratio and rounding `nx/ny` to the nearest 100. Default search
arguments are `16 16`, corresponding to an internal `32 × 32` pixel window.
Allowed values in each direction are `16`, `32`, `64`, `128`, and `256`.

```bash
./run2_recommend_grid.sh 32 32
./run2_recommend_grid.sh 1 32 32
```

Optional overrides:

```bash
export OFFSET_TARGET_POINTS=4800000
export OFFSET_GRID_ROUND=100
export OFFSET_XSEARCH=16
export OFFSET_YSEARCH=16
export OFFSET_NPROC=32
./run2_recommend_grid.sh 1
```

Run2 only writes `offset_run.conf`; it does not start correlation.

## 7. Run3: run parallel offset tracking

```bash
./run3_run_offset.sh       # preview exact command
./run3_run_offset.sh 1     # start calculation
```

Run3 reads `offset_run.conf`, exports `XCORR_NPROC` and
`OMP_NUM_THREADS=1`, calls `$HOME/bin/make_a_offset_mt.csh`, writes a
timestamped log, and reports approximate progress every 30 seconds.

The current environment and `PATH` are used by default. To request a specific
Conda environment:

```bash
export CONDA_ENV_NAME=YOUR_GMTSAR_ENV
./run3_run_offset.sh 1
```

Change the refresh interval or intentionally rerun:

```bash
export OFFSET_PROGRESS_SECONDS=10
./run3_run_offset.sh 1

./run3_run_offset.sh 1 --replace
```

The principal raw result is:

```text
offset/intf/PAIR_NAME/azi_offset/freq_xcorr.dat
```

Relevant columns:

```text
1  range coordinate
2  range offset (pixels)
3  azimuth coordinate
4  azimuth offset (pixels)
5  SNR
```

## 8. Run4: create range and azimuth products

```bash
./run4_make_range_azimuth_grids_and_plots.sh
./run4_make_range_azimuth_grids_and_plots.sh 1
```

Defaults:

```text
minimum SNR:              10
maximum absolute offset:  5 pixels per component
aggregation factor:       4
output mode:              compact
```

Aggregation affects only Run4 post-processing; it never reruns or modifies
`freq_xcorr.dat`.

| Factor | Meaning |
|---:|---|
| `1` | Original offset-sample density; maximum detail and noise |
| `4` | Balanced default for detail, noise, and file size |
| `12` | Coarser overview with less small-scale detail |

```bash
./run4_make_range_azimuth_grids_and_plots.sh --factor 1
./run4_make_range_azimuth_grids_and_plots.sh 1 --factor 1

export RUN4_MIN_SNR=10
export RUN4_MAX_ABS_OFFSET=5
export RUN4_AGGREGATE_FACTOR=4
```

Run4 uses SNR as the block-median weight, geocodes both components with
`trans.dat`, and converts pixels to metres:

```text
azimuth metres = azimuth pixels × ground velocity / PRF
range metres   = range pixels × c / (2 × rng_samp_rate)
```

Range is the native slant-range component, not ground range or a complete LOS
inversion. Azimuth is the along-track component.

Compact outputs under `azi_offset/offset_components`:

```text
azimuth_offset_ll_m.grd
range_offset_ll_m.grd
azimuth_offset_ll.pdf
range_offset_ll.pdf
azimuth_offset_ll_google.png/.kml/.kmz
range_offset_ll_google.png/.kml/.kmz
README_outputs.txt
```

Each KMZ includes a transparent overlay and a separate vertical colorbar.
Use `--keep-intermediate` for point tables, radar/pixel grids, XYZ, and CPT
files. Intentional replacement:

```bash
./run4_make_range_azimuth_grids_and_plots.sh 1 --factor 4 --replace
```

## 9. Run5: filter the metre grids

Run5 reads the two Run4 grids:

```text
offset_components/azimuth_offset_ll_m.grd
offset_components/range_offset_ll_m.grd
```

It does not modify them. Processing order:

```text
optional clipping → spherical median → light spherical Gaussian
                  → optional resampling → GRD/PDF/KMZ
```

```bash
./run5_filter_offset_grids.sh       # preview all choices
```

Run5 checks that both GRD geometries match, converts their geographic
increments to approximate metres at the centre latitude, and uses the larger
east-west/north-south cell dimension:

```text
physical filter width = reference cell size × filter cell count
```

Recommended profiles:

| Profile | Median full diameter | Gaussian full width | Use |
|---|---:|---:|---|
| `mild` | 3 cells | 6 cells | Preserve more detail |
| `balanced` | 5 cells | 6 cells | Recommended default |
| `strong` | 7 cells | 12 cells | Stronger overview smoothing |

```bash
./run5_filter_offset_grids.sh 1 --profile mild
./run5_filter_offset_grids.sh 1 --profile balanced
./run5_filter_offset_grids.sh 1 --profile strong
```

Custom positive-integer sizes:

```bash
./run5_filter_offset_grids.sh \
  --median-cells 4 --gaussian-cells 8

./run5_filter_offset_grids.sh 1 \
  --median-cells 4 --gaussian-cells 8
```

The default clip is ±10 m; `--clip-m 0` disables clipping. Input spacing is
preserved unless `--spacing` is supplied.

```bash
./run5_filter_offset_grids.sh 1 --clip-m 5
./run5_filter_offset_grids.sh 1 --clip-m 0
./run5_filter_offset_grids.sh 1 --spacing 0.002
```

Each configuration gets a separate directory:

```text
offset_components/filtered/
├── mild_m3_g6_clip10_preserve/
├── balanced_m5_g6_clip10_preserve/
├── strong_m7_g12_clip10_preserve/
└── custom_m4_g8_clip10_preserve/
```

Each directory contains two filtered GRDs, two PDFs, two Google Earth KMZs,
and `README_outputs.txt`. Only an identical rerun requires `--replace`.

## 10. Minimal end-to-end example

Run from `PROJECT/offset`:

```bash
./run0_install_xcorr_mt.sh
./run0_install_xcorr_mt.sh 1

./run1_prepare_offset.sh
./run1_prepare_offset.sh 1

./run2_recommend_grid.sh
./run2_recommend_grid.sh 1

./run3_run_offset.sh
./run3_run_offset.sh 1

./run4_make_range_azimuth_grids_and_plots.sh
./run4_make_range_azimuth_grids_and_plots.sh 1 --factor 4

./run5_filter_offset_grids.sh
./run5_filter_offset_grids.sh 1 --profile balanced
```

## 11. Interpretation and cautions

- Runtime grows approximately with `nx × ny`.
- More workers are not always faster; memory bandwidth and storage I/O matter.
- Stronger aggregation/filtering reduces noise but also removes spatial detail.
- Filtering improves continuity but cannot make poor correlations reliable.
- Compare raw and filtered grids, stable terrain, SNR choices, and ascending/
  descending observations before interpretation.
- Range and azimuth are observation-coordinate components, not automatically
  east/north/vertical displacement.

## 12. Upstream software

- `xcorr_mt`: <https://github.com/Jazz-0626/xcorr_mt>
- GMTSAR: <https://github.com/gmtsar/gmtsar>

---

# 中文

**[Back to English](#english)**

## 1. 工作流简介

本目录提供一套基于 GMTSAR 的 CPU 并行像素偏移流程。它可以安装并调用
`xcorr_mt`，建立独立 offset 工作区，从 PRM 自动推荐采样点数，显示互相关进度，
生成距离向和方位向地理编码结果，并对最终 GRD 进行可配置滤波。

这套流程不会覆盖 GMTSAR 原版 `xcorr` 和 `make_a_offset.csh`。
`make_a_offset_mt.csh` 只在运行时把原版驱动内部的 `xcorr` 调用替换为
`xcorr_mt`。

```text
Run0  安装/检查 xcorr_mt 和 make_a_offset_mt.csh
  ↓
Run1  建立 offset/SLC、offset/topo 和一个日期对目录
  ↓
Run2  读取 PRM 并保存推荐采样参数
  ↓
Run3  运行 CPU 并行互相关并显示进度
  ↓
Run4  生成距离向/方位向米制 GRD、PDF 和 Google Earth KMZ
  ↓
Run5  进行可配置的中值+高斯滤波
```

这些脚本不再依赖旧的 `run_offset_mt.sh`。

## 2. 脚本和运行规则

| 脚本 | 作用 |
|---|---|
| `run0_install_xcorr_mt.sh` | 安装或检查 CPU 并行程序和包装脚本 |
| `run1_prepare_offset.sh` | 用软链接建立独立 offset 工作区 |
| `run2_recommend_grid.sh` | 推荐 `nx/ny` 并保存 `offset_run.conf` |
| `run3_run_offset.sh` | 并行运行、显示进度并记录日志 |
| `run4_make_range_azimuth_grids_and_plots.sh` | 生成地理编码双分量网格和地图 |
| `run5_filter_offset_grids.sh` | 滤波两个地理编码米制网格 |

统一运行规则：

```bash
./runN_script.sh       # 只预览
./runN_script.sh 1     # 执行刚才预览的操作
```

已有结果默认受到保护，重做同一输出时必须明确使用 `--replace`。

每个阶段成功完成后，Run1 至 Run4 会自动显示下一阶段的预览和执行命令；Run5
会显示流程完成提示，并给出不覆盖当前结果的其他滤波方案示例。

## 3. 环境和输入数据

软件要求：Bash、C shell、GMTSAR、GMT、`gmt-config`、`gcc`、`find`、
`install`、`gmtsar.h`、`libgmtsar.a`、LAPACK、BLAS、TIFF、`zip`，以及
Run3 所需的 Linux `setsid` 和 `pgrep`。Conda 不是必需条件。

工程结构：

```text
PROJECT/
├── SLC/
│   ├── MASTER.PRM
│   ├── MASTER.SLC
│   ├── ALIGNED.PRM
│   └── ALIGNED.SLC
├── topo/
│   ├── dem.grd
│   └── trans.dat
├── intf_all/
│   └── PAIR_NAME/
└── offset/
    ├── run0_install_xcorr_mt.sh
    ├── run1_prepare_offset.sh
    ├── run2_recommend_grid.sh
    ├── run3_run_offset.sh
    ├── run4_make_range_azimuth_grids_and_plots.sh
    └── run5_filter_offset_grids.sh
```

PRM 需要包含有效的 `num_rng_bins`、`num_valid_az`、`SLC_file`、`PRF`、
`SC_vel`、`earth_radius`、`SC_height` 和 `rng_samp_rate`。本流程主要使用
PRM、SLC、`trans.dat`、`dem.grd`；LED 可以保留但不是这些阶段的主要输入。
Run1/Run2 要求只处理一个日期对，并且 `PROJECT/SLC` 中正好有两个 PRM。

## 4. Run0：安装 CPU 并行程序

```bash
./run0_install_xcorr_mt.sh       # 预览
./run0_install_xcorr_mt.sh 1     # 安装
```

安装结果：

```text
$HOME/bin/xcorr_mt
$HOME/bin/make_a_offset_mt.csh
```

使用当前 Conda 环境或明确指定环境：

```bash
conda activate YOUR_GMTSAR_ENV
./run0_install_xcorr_mt.sh 1

./run0_install_xcorr_mt.sh 1 --env YOUR_GMTSAR_ENV
```

`base` 中依赖齐全时也可以使用；推荐独立 GMTSAR 环境，但不强制。

无 Conda 或需要强制检查当前系统安装时：

```bash
./run0_install_xcorr_mt.sh --system
./run0_install_xcorr_mt.sh 1 --system
```

非标准 GMTSAR 编译目录：

```bash
GMTSAR_DEV_ROOT=/path/to/GMTSAR \
./run0_install_xcorr_mt.sh 1 --system
```

预览会显示 `xcorr`、`make_a_offset.csh`、`gmt-config`、`gcc`、`gmtsar.h`、
`libgmtsar.a` 的实际路径。

### 源码获取和离线安装

本工作流把 `xcorr_mt-source` 作为 Git submodule，链接并固定到上游
`Jazz-0626/xcorr_mt` 的对应版本。完整克隆命令：

```bash
git clone --recurse-submodules \
  git@github.com:Xin-Wang-520/GMTSAR-Parallel-Pixel-Offset-Workflow.git
```

如果普通克隆时没有下载子模块：

```bash
git submodule update --init --recursive
```

Run0 按以下顺序查找源码：

1. `offset/xcorr_mt-source/xcorr_mt.c`；
2. `$HOME/src/xcorr_mt/xcorr_mt.c`；
3. 从 <https://github.com/Jazz-0626/xcorr_mt> 下载。

服务器无法连接 GitHub 时，手动下载并上传，使下列文件存在：

```text
PROJECT/offset/xcorr_mt-source/xcorr_mt.c
```

然后重新执行 Run0。也可以使用：

```bash
./run0_install_xcorr_mt.sh 1 --source-dir /path/to/xcorr_mt
```

## 5. Run1：准备 offset 工作区

### Run1 之前必须确认

标准无参数流程需要先建立 `PROJECT/offset`，把 Run0–Run5 脚本复制进去，并从
这个目录运行：

```bash
PROJECT=/path/to/your/project
mkdir -p "$PROJECT/offset"
cp run{0,1,2,3,4,5}_*.sh "$PROJECT/offset/"
cd "$PROJECT/offset"
chmod +x run{0,1,2,3,4,5}_*.sh
```

上一级工程必须已经有 `SLC/`、`topo/`，通常还应在 `intf_all/` 下有一个日期对。
Run1 在创建任何目录或链接前会检查并显示：

- `PROJECT/SLC` 中是否正好有两个 PRM；
- 每个 PRM 的 `SLC_file` 指向的 SLC 是否真实存在；
- 两个 PRM 的 `num_rng_bins/num_valid_az` 是否有效且一致；
- `PROJECT/topo/dem.grd` 和 `PROJECT/topo/trans.dat` 是否存在；
- 日期对和计划创建的 offset 路径。

缺少任何必要输入时，Run1 会停止，不会建立不完整的工作区。

```bash
./run1_prepare_offset.sh
./run1_prepare_offset.sh 1
```

Run1 自动识别 `PROJECT/intf_all` 下唯一的日期对，建立
`offset/intf/PAIR_NAME`，并创建：

```text
offset/SLC  -> ../SLC
offset/topo -> ../topo
```

不会复制大体积 SLC。明确指定工程和日期对：

```bash
./run1_prepare_offset.sh PROJECT_DIR PAIR_NAME
./run1_prepare_offset.sh 1 PROJECT_DIR PAIR_NAME
```

## 6. Run2：推荐并保存采样网格

```bash
./run2_recommend_grid.sh       # 预览PRM和参数
./run2_recommend_grid.sh 1     # 保存offset_run.conf
```

Run2 显示影像尺寸、SLC 名称、整数/亚像素位移、推荐 `nx/ny`、总点数、中心
间距、整数 `x_inc/y_inc`、搜索参数、内部窗口和进程数。

默认目标约480万个点，保持 PRM 影像比例，并将 `nx/ny` 取到最接近的整百。
默认 `16 16` 对应内部 `32 × 32` 像素窗口。每个方向可以选择
`16/32/64/128/256`：

```bash
./run2_recommend_grid.sh 32 32
./run2_recommend_grid.sh 1 32 32
```

可选覆盖参数：

```bash
export OFFSET_TARGET_POINTS=4800000
export OFFSET_GRID_ROUND=100
export OFFSET_XSEARCH=16
export OFFSET_YSEARCH=16
export OFFSET_NPROC=32
./run2_recommend_grid.sh 1
```

Run2 只保存配置，不开始计算。

## 7. Run3：运行并行互相关

```bash
./run3_run_offset.sh       # 预览完整命令
./run3_run_offset.sh 1     # 开始计算
```

Run3 读取 `offset_run.conf`，设置 `XCORR_NPROC` 和 `OMP_NUM_THREADS=1`，
调用 `$HOME/bin/make_a_offset_mt.csh`，保存带时间戳的日志，并默认每30秒显示
近似完成点数和百分比。

默认使用当前环境和 `PATH`。需要指定 Conda 环境时：

```bash
export CONDA_ENV_NAME=YOUR_GMTSAR_ENV
./run3_run_offset.sh 1
```

```bash
export OFFSET_PROGRESS_SECONDS=10
./run3_run_offset.sh 1

./run3_run_offset.sh 1 --replace
```

主要结果：

```text
offset/intf/PAIR_NAME/azi_offset/freq_xcorr.dat
```

其中第1/2列是距离坐标/偏移，第3/4列是方位坐标/偏移，第5列是 SNR。

## 8. Run4：生成距离向和方位向产品

```bash
./run4_make_range_azimuth_grids_and_plots.sh
./run4_make_range_azimuth_grids_and_plots.sh 1
```

默认采用 SNR>10、各分量±5像素限制、聚合系数4和精简输出。

| 系数 | 含义 |
|---:|---|
| `1` | 原始采样密度，细节和噪声最多 |
| `4` | 默认推荐，细节、噪声、文件大小较均衡 |
| `12` | 更粗的概览，细节较少 |

聚合只影响 Run4，不会重新计算或修改 `freq_xcorr.dat`。

```bash
./run4_make_range_azimuth_grids_and_plots.sh 1 --factor 1

export RUN4_MIN_SNR=10
export RUN4_MAX_ABS_OFFSET=5
export RUN4_AGGREGATE_FACTOR=4
```

米制转换：

```text
方位向米数 = 方位向像素偏移 × 地面速度 / PRF
距离向米数 = 距离向像素偏移 × c / (2 × rng_samp_rate)
```

距离向是斜距分量，不是地距或完整 LOS 反演；方位向是沿轨分量。

精简输出：

```text
azimuth_offset_ll_m.grd
range_offset_ll_m.grd
azimuth_offset_ll.pdf
range_offset_ll.pdf
azimuth_offset_ll_google.png/.kml/.kmz
range_offset_ll_google.png/.kml/.kmz
README_outputs.txt
```

每个 KMZ 都包含透明地理叠加层和独立竖直 colorbar。保留中间文件时添加
`--keep-intermediate`；替换已有结果：

```bash
./run4_make_range_azimuth_grids_and_plots.sh 1 --factor 4 --replace
```

## 9. Run5：滤波米制网格

输入：

```text
offset_components/azimuth_offset_ll_m.grd
offset_components/range_offset_ll_m.grd
```

Run5 不修改 Run4 原始结果。处理顺序：

```text
可选裁剪 → 球面中值滤波 → 轻度球面高斯滤波
         → 可选重采样 → GRD/PDF/KMZ
```

```bash
./run5_filter_offset_grids.sh       # 预览全部方案和实际米数
```

Run5 检查两个 GRD 网格结构是否一致，在中心纬度把经纬度增量换算为米，并取
东西向/南北向中较大的网格尺寸：

```text
滤波物理宽度 = 参考网格尺寸 × 滤波网格数
```

| 方案 | 中值完整直径 | 高斯完整宽度 | 用途 |
|---|---:|---:|---|
| `mild` | 3格 | 6格 | 保留更多细节 |
| `balanced` | 5格 | 6格 | 默认推荐 |
| `strong` | 7格 | 12格 | 更强的概览平滑 |

```bash
./run5_filter_offset_grids.sh 1 --profile mild
./run5_filter_offset_grids.sh 1 --profile balanced
./run5_filter_offset_grids.sh 1 --profile strong
```

自定义正整数滤波格数：

```bash
./run5_filter_offset_grids.sh \
  --median-cells 4 --gaussian-cells 8

./run5_filter_offset_grids.sh 1 \
  --median-cells 4 --gaussian-cells 8
```

默认裁剪范围为±10米，`--clip-m 0` 关闭裁剪；默认保持原网格分辨率：

```bash
./run5_filter_offset_grids.sh 1 --clip-m 5
./run5_filter_offset_grids.sh 1 --clip-m 0
./run5_filter_offset_grids.sh 1 --spacing 0.002
```

每组参数保存在独立目录：

```text
offset_components/filtered/
├── mild_m3_g6_clip10_preserve/
├── balanced_m5_g6_clip10_preserve/
├── strong_m7_g12_clip10_preserve/
└── custom_m4_g8_clip10_preserve/
```

每个目录包含两个滤波 GRD、两个 PDF、两个 Google Earth KMZ 和
`README_outputs.txt`。不同配置可同时保存；只有相同配置重跑才需要 `--replace`。

## 10. 最简完整示例

在 `PROJECT/offset` 中运行：

```bash
./run0_install_xcorr_mt.sh
./run0_install_xcorr_mt.sh 1

./run1_prepare_offset.sh
./run1_prepare_offset.sh 1

./run2_recommend_grid.sh
./run2_recommend_grid.sh 1

./run3_run_offset.sh
./run3_run_offset.sh 1

./run4_make_range_azimuth_grids_and_plots.sh
./run4_make_range_azimuth_grids_and_plots.sh 1 --factor 4

./run5_filter_offset_grids.sh
./run5_filter_offset_grids.sh 1 --profile balanced
```

## 11. 解释和注意事项

- 运行时间大致随 `nx × ny` 增加；
- CPU 进程并非越多越快，内存带宽和磁盘 I/O 也会限制速度；
- 聚合/滤波越强，噪声越少，但空间细节也越少；
- 滤波只能改善连续性，不能把低质量相关点变成可靠位移；
- 地学解释前应比较原始/滤波结果、稳定区、SNR 阈值以及升降轨观测；
- 距离向和方位向是观测坐标分量，不会自动成为东西、南北、垂直位移。

## 12. 上游软件

- `xcorr_mt`：<https://github.com/Jazz-0626/xcorr_mt>
- GMTSAR：<https://github.com/gmtsar/gmtsar>
