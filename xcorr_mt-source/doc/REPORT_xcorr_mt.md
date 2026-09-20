# xcorr_mt(多进程版 xcorr)替换 GMTSAR 原版 xcorr:真实数据验证报告

- 日期:2026-07-18(2026-07-19 更新:新增雷达坐标系场图、nx/ny 讨论与 4000 点加密实证)
- 测试数据:2026 大柴旦项目 Asc_172 轨 **IW2 子带**(S1D 20260611 / 20260623,SLC 25024×12188,`SAT_baseline` 预置 rshift=20 / ashift=-2),取自 `/media/tjz/xpg/xcorr_cc_align_test/`
- 测试机:20 核 CPU / 31 GB RAM,GMTSAR 6.6 `/usr/local/GMTSAR`
- 被测程序:`/usr/local/GMTSAR/bin/xcorr_mt`(源码 `~/tools/xcorr_mt/`,fork 多进程分块;数值内核 100% 复用 `libgmtsar.a` 与 GMT FFT,**未改动 GMTSAR 任何源码**)
- 测试现场:`/media/tjz/xpg/Byteswarm/20260717K3Test/real_test/`(`run_real.sh` / `run_verify.sh` 可复现)

## 一、总结论

**可以替换。** 在 align.csh 非 ERS 分支(`-xsearch 128 -ysearch 256`)与 p2p_processing.csh 非 TOPS 分支(`-xsearch 128 -ysearch 128`)两组实参、1000 个测点上:

- 输出 `freq_xcorr.dat` 与原版 **逐字节一致**(md5 相同,含 4000 点密集网格 4000/4000 全等)——唯一例外是 1/1000 个失相干歧义点(corr=14.95<18),其不确定性来自**原版自身的未初始化内存读取**,并非并行引入的计算错误,且被 fitoffset 阈值过滤,**端到端 fitoffset 配准参数两组参数下均逐行一致**;
- 默认自动模式(核数−2 = 18 进程)加速 **4.5×–5.1×**(657s→128s、354s→79s),无需任何参数;
- 脚本内替换仅需把命令名 `xcorr` 改为 `xcorr_mt`,**一行改动,其余参数原样保留**。

## 二、替换写法

```csh
# p2p_processing.csh:512,514 / align.csh:81,83 等所有调用点,原:
xcorr $master.PRM $aligned.PRM -xsearch 128 -ysearch 128 -nx 20 -ny 50
# 改为(自动按 核数-2 并行,无需加任何参数):
xcorr_mt $master.PRM $aligned.PRM -xsearch 128 -ysearch 128 -nx 20 -ny 50
```

进程数优先级:`-nproc N` > 环境变量 `OMP_NUM_THREADS` > 自动(在线核数−2,保底 1);上限钳制为在线核数与测点数。

## 三、逐字节一致性(md5 校验)

### 配置 A:align.csh 非 ERS 分支(-xsearch 128 -ysearch 256 -nx 20 -ny 50,1000 点)

| 运行 | md5 | 与原版 |
|---|---|---|
| 原版 xcorr(基准,连跑两遍) | `4dae12e1…78761` | 自身逐字节一致 |
| xcorr_mt -nproc 1 / 4 / 8 / 18 / 自动 | `4dae12e1…78761` | **逐字节一致** |
| xcorr_mt -nproc 12(第 1 次) | `a024c712…b924b8` | 1/1000 行不同 |
| xcorr_mt -nproc 12(第 2 次) | `08fcb53e…31d12` | 同一行,第三组数值 |

### 配置 B:p2p_processing.csh 非 TOPS 分支(-xsearch 128 -ysearch 128 -nx 20 -ny 50,1000 点)

| 运行 | 与原版 |
|---|---|
| xcorr_mt -nproc 12 / 18 / 自动 | **逐字节一致**(`cmp` 通过,md5 `a0352e42…3c01f9`) |

### 唯一分歧点(配置 A 第 584 点,x=5782 y=7264)的机制与证据链

| 运行 | xoff | yoff | corr |
|---|---|---|---|
| 原版(两遍)/ mt -nproc 1 / 4 / 8 / 18 / 自动 | -2.500 | 255.000 | 14.95 |
| mt -nproc 12 第 1 次 | -4.469 | 251.062 | 14.95 |
| mt -nproc 12 第 2 次 | -4.781 | 254.938 | 14.95 |

机制:相关峰紧贴方位向搜索窗边缘(yoff_int=255,ysearch=256)时,`highres_corr.c:31-38` 的 `k<0` 下界保护会跳过 `md` 数组 8 行中的 3 行(24/64 个值)**而不初始化**,这些堆残留值随后进入 FFT 过采样插值。单进程原版每次运行 malloc 历史相同,所以输出"稳定";fork 多进程各 worker 历史不同,在 corr=14.95 这种相关面近乎平坦的失相干点上,垃圾值可翻转插值面的亚像素 argmax。证据链:

1. 原版连跑两遍 → 逐字节一致(原版自身确定);
2. xcorr_mt `-nproc 1`(与原版相同的逐点历史)→ 逐字节一致(并行代码路径零误差);
3. mt -nproc 12 两次运行给出**第三组**数值 → 该点输出依赖内存历史,非确定性计算;
4. 同一现象在 xcorr_cc(GPU 版)测试报告中亦有记录(竞争峰选峰翻转)。

**下游影响:无。** 该点 corr=14.95 低于 fitoffset 过滤阈值(corr≥18,见图 3 虚线),其空间位置见图 4 右图红圈——位于低相干斑块内,正是阈值过滤的对象;两组参数下 `fitoffset.csh` 端到端输出均逐行一致(见第六节)。

## 四、性能(同机、顺序运行、wall 计时)

![耗时与加速比](figs/fig1_timing.png)

| 配置 | 原版 | mt 4 | mt 8 | mt 12 | mt 18 | mt 自动(18) |
|---|---|---|---|---|---|---|
| A:128/256(1000 点) | 657 s | 204 s(3.2×) | 152 s(4.3×) | 139 s(4.7×) | 133 s(4.9×) | **128 s(5.1×)** |
| B:128/128(1000 点) | 354 s | — | — | 82 s(4.3×) | 78 s(4.5×) | **79 s(4.5×)** |
| B:128/128(4000 点) | 1365 s | — | — | — | — | **319 s(4.3×)** |

说明:

- 计时口径为 wall-clock;原版自身报告的 CPU 时间为 1242 s(配置 A),即原版经 GMT FFT 内部线程已占用约 1.9 核,表内加速比是相对原版 wall 的净加速;
- 扩展性在 8 进程后边际递减(FFT 为内存带宽密集型,且各 worker 的 GMT FFT 仍带少量内部线程);`核数−2` 的默认值接近本机拐点;
- 内存:每 worker 持有 d1+d2 ≈ 2×25024×npy×8 B,配置 A(npy=1024)约 410 MB/worker(18 进程 ≈ 7.4 GB),配置 B(npy=512)约 205 MB/worker(18 进程 ≈ 3.7 GB)。

## 五、实测相干场与偏移场(雷达坐标系)

测点本身是规则网格(`get_locations` 等间距),无需插值即可直接成图;背景为主影像 SLC 幅度(方位向 12:1、距离向 16:1 抽取,对数拉伸)。本目录无 `trans.dat`(地理编码查找表需 intf 全流程生成),故图为雷达坐标系。

### 5.1 相干场 corr 地图

![corr 地图](figs/fig4_corr_map.png)

- 左:配置 B(128/128,与原版逐字节一致);右:配置 A(128/256),红圈为第 584 号分歧点;
- 相干场空间格局清晰:低相干斑块(暗色,corr<20)对应幅度背景中的水体/裸地,高相干区(黄绿色,corr>60)覆盖大部分稳定地表;
- 分歧点位于低相干斑块内——它不是"并行算错",而是失相干位置固有的峰选择歧义(见第三节),且被 fitoffset 阈值过滤。

### 5.2 偏移场地图(配置 B,与原版逐字节一致)

![偏移场地图](figs/fig5_offset_maps.png)

- 距离向偏移场呈光滑的距离向趋势(约 19.7→21.4 px),正是 `stretch_r` 的物理来源;方位向偏移场绝大部分 ≈1 px;
- 场上少量离群块(深红/深蓝)全部对应图 4 中的低相干斑块,由 fitoffset 的 corr≥18 阈值滤除。

### 5.3 corr 分布与过滤阈值

![corr 分布](figs/fig3_corr_hist.png)

- 96.5% 的测点 corr≥18;阈值线左侧的 3.5% 与图 4 暗色斑块一一对应。

## 六、下游端到端(fitoffset.csh 3 3 freq_xcorr.dat 18)

| 参数 | 原版链 | xcorr_mt 链 | 差 |
|---|---|---|---|
| rshift | 19 | 19 | 0 |
| sub_int_r | 0.4082 | 0.4082 | 0 |
| stretch_r | 6.09833e-05 | 6.09833e-05 | 0 |
| a_stretch_r | 1.22466e-05 | 1.22466e-05 | 0 |
| ashift | 0 | 0 | 0 |
| sub_int_a | 0.559936 | 0.559936 | 0 |
| stretch_a | -1.11483e-06 | -1.11483e-06 | 0 |
| a_stretch_a | 5.16397e-06 | 5.16397e-06 | 0 |

配置 A、B 的 `fitoffset.csh` 完整输出文件均逐字节一致(`cmp` 通过)。配准参数与此前 xcorr_cc 报告同数据结果(rshift=19, sub_int_r≈0.41, sub_int_a≈0.56)吻合。

## 七、nx/ny 测点数与配准精度的关系(讨论)

### 7.1 GMTSAR 全部脚本中 xcorr 的实际用量

| 脚本 | 参数 | 点数 | 场景 |
|---|---|---|---|
| `align_batch.csh` | -nx 15 -ny 30 | 450 | 二次配准 |
| `align.csh` / `p2p_processing.csh`(ERS/ENVI/ALOS/CSK/LT1/通用) | -nx 20 -ny 50 | **1000(标准)** | 绝大多数传感器配准 |
| `align_ALOS_SLC.csh` | -nx 32 -ny 64 | 2048 | ALOS 配准 |
| `align_ALOS2_SCAN.csh` / `p2p_ALOS2_SCAN_SLC.csh` | -nx 32 -ny 128 | 4096 | ScanSAR 特例 |
| `make_a_offset.csh` | 用户传入 | 可变 | POT 偏移追踪(非配准) |

### 7.2 对配准,1000 点不少

- fitoffset 的任务是"compute **2-6** alignment parameters"(rshift / stretch_r / a_stretch_r / ashift / stretch_a / a_stretch_a),即配准模型只有 **2~6 个有效自由度**的低阶多项式趋势;
- 本数据 1000 点过滤后剩 965 个有效点,超定比约 **160 倍**;参数精度由单点亚像素测量(ri=2 + interp=16,标称 ~1/16 px)与稳健拟合决定,点数不是瓶颈;
- ALOS2 ScanSAR 用 4096 点并非"精度需要",而是 burst 结构使方位向偏移场**不是光滑低阶场**,必须密集方位采样 + 中值滤波;
- 点数与窗口互相制约:`x_inc=(m_nx−2(xsearch+nx_corr))/(nxl+3)`、`y_inc=(m_ny−2(ysearch+ny_corr))/(nyl+1)`——窗口越大,留给测点的边界越少。

### 7.3 什么场景才需要加密

- **POT / 形变场产品**(make_a_offset.csh 类):偏移场本身是产品,空间分辨率=点间距,加密是真需求;代价为计算量线性增长,这正是 xcorr_mt 的意义所在;
- 加密后落入 burst 边界/水体的失相干点比例上升,corr≥18 过滤更关键;
- 4000 点(40×100)加密实证(逐字节一致性、fitoffset 参数对比)见 7.4。

### 7.4 加密实证:4000 点(40×100,128/128 窗口)对比 1000 点

- **逐字节一致性**:4000/4000 点全部逐字节一致(md5 `3eeb83a7…e58e56`),密集网格同样通过;
- **耗时**:原版 1365 s → xcorr_mt 自动(18 进程)319 s,**4.3×**;
- **配准参数(fitoffset.csh 3 3,同窗口同阈值)**:

| 参数 | 1000 点 | 4000 点 | 差 |
|---|---|---|---|
| rshift | 19 | 19 | 0 |
| sub_int_r | 0.4034 | 0.4042 | +0.0008 px |
| stretch_r | 6.1141e-05 | 6.10474e-05 | -9.4e-08(0.15%) |
| a_stretch_r | 1.24873e-05 | 1.2375e-05 | -1.1e-07 |
| ashift | 0 | 0 | 0 |
| sub_int_a | 0.564249 | 0.55775 | -0.0065 px |
| stretch_a | -1.05007e-06 | -8.66395e-07 | +1.8e-07 |
| a_stretch_a | 3.55724e-06 | 4.5287e-06 | +9.7e-07 |

点数 ×4,配准参数变化最大 **0.0065 px**(亚毫米到厘米级形变当量,远低于 InSAR 可测信号)——**1000 点对配准已饱和**的论断得到实测证实。

- **加密的真正收益在场分辨率**(POT 视角):图 6 可见 4000 点的相干场能解析出 1000 点无法分辨的谷地/道路条带;

![密度对比](figs/fig6_dense_corr.png)

![4000 点偏移场](figs/fig7_dense_offsets.png)

## 八、鲁棒性(合成数据阶段已验证,真实数据复用同一代码路径)

- 模式覆盖:`-freq`(默认)/ `-time` / `-real`(float) / `.grd`(netCDF)输入,均逐字节一致;
- 边界:`-nproc` 超核数或超测点数自动钳制;`OMP_NUM_THREADS` 生效且优先级低于 `-nproc`;非法值(`0`/非数字)回退;`-nproc` 缺参按原风格报错退出;
- 故障语义:任一 worker 失败则整体非零退出且**不产出半成品 .dat**(优于原版——原版会留下截断文件);临时分块文件自清理,无残留;
- 非 2 的幂分块(如 1000 点 ÷ 7 进程)验证通过。

## 九、注意事项

1. `-v` 逐点 verbose 行在多进程下行序不保证(仅 stdout 日志,不影响 .dat);
2. 进程数增加内存线性增长(见第四节),内存紧张时显式 `-nproc` 降核;
3. stdout 的 `elapsed time` 在 xcorr_mt 为 wall-clock(原版为 CPU 时间),格式不变;
4. 第三节所述失相干歧义点的不确定性为原版固有属性(单进程"稳定"只是同一历史下的表象);若日后希望根治,可在 `highres_corr.c` 将跳过的 `md` 元素置零——但那样会与原版在这些点上产生差异,故本次刻意保持与原版完全一致;
5. 原版 `xcorr` 未做任何改动,随时可回退;xcorr_mt 卸载即删除 `/usr/local/GMTSAR/bin/xcorr_mt`。

## 附:复现命令

```bash
cd /media/tjz/xpg/Byteswarm/20260717K3Test/real_test
bash run_real.sh     # 配置 A:原版基准 + mt 各进程数 + fitoffset
bash run_verify.sh   # 确定性验证(原版两遍/mt 单进程/mt12 复跑)+ 配置 B
bash run_dense.sh    # 4000 点密集网格(约 28 分钟)
/home/tjz/miniconda3/envs/gbispy/bin/python make_figs_mt.py    # 图 1-3
/home/tjz/miniconda3/envs/gbispy/bin/python make_maps.py       # 图 4-5(雷达坐标系场图)
/home/tjz/miniconda3/envs/gbispy/bin/python make_dense_maps.py # 图 6-7(4000 点场图)
/home/tjz/miniconda3/envs/paperimg/bin/python md2pdf_mt.py     # 重新渲染 HTML/PDF
```
