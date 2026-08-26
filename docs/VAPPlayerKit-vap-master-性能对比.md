# VAPPlayerKit 与 vap-master 性能复核（优化后多素材）

## 结论先行

优化后在同一台 iPhone 12、两端 Release 签名构建下，warm prepare 已明显领先。这里同时使用了两类素材：

| 素材 | 阶段 | 指标 | VAPPlayerKit | vap-master | 结果 |
| --- | --- | --- | ---: | ---: | --- |
| demo.mp4 | cold | prepare API → ready | 30.00 ms | 34.09 ms | 新版快 12.0% |
| demo.mp4 | cold | API → 首次 GPU 提交 | 69.49 ms | 85.39 ms | 新版快 18.6% |
| demo.mp4 | warm 中位数 | prepare API → ready | 2.79 ms | 8.11 ms | 新版快 65.6% |
| demo.mp4 | warm 中位数 | API → 首次 GPU 提交 | 37.73 ms | 51.32 ms | 新版快 26.5% |
| 1.mp4（图片+文字替换） | cold | prepare API → ready | 38.01 ms | 48.73 ms | 新版快 22.0% |
| 1.mp4（图片+文字替换） | cold | API → 首次 GPU 提交 | 82.49 ms | 97.41 ms | 新版快 15.3% |
| 1.mp4（图片+文字替换） | warm 中位数 | prepare API → ready | 2.89 ms | 11.89 ms | 新版快 75.7% |
| 1.mp4（图片+文字替换） | warm 中位数 | API → 首次 GPU 提交 | 50.84 ms | 54.04 ms | 新版快 5.9% |

这说明优化方向是有效的：warm prepare 从此前约 10 ms 降到约 2.8–2.9 ms。原因是缓存现在不仅复用 vapc 文档，也复用 inspection 已加载的 AVAsset/video track；同时视频-only 素材不再提前编译动态 overlay pipeline。

本轮复测的两个素材 cold API→首帧都更快：demo.mp4 快 18.6%，含动态内容的 1.mp4 快 15.3%。但 cold 只有每个素材 1 个进程样本，因此不能写成所有设备、所有素材都无条件领先。

原来看到的“新版 cold prepare 156 ms、旧版 17 ms”不成立。旧版埋点原先在 hwd_loadMetalDataIfNeed 之前结束，把一段必须完成的 Metal 资源准备排除在外。

## 采集条件

- 设备：当前连接的 iPhone 12（设备名 iPhone 12da），iOS 26.5.2。
- 构建：两端均为 Release、真机签名安装。
- 素材：demo.mp4（1,519,065 bytes）和 1.mp4（4,858,621 bytes，图片 + 文字替换）。
- 每个素材报告 5 次：1 次进程 cold、4 次同进程 warm；每次播放窗口 2 秒。
- 每个素材都单独启动进程采集，避免第一个素材的进程级 Metal/cache 状态污染第二个素材。
- 首次安装后偶发出现“prepare 完成但 2 秒内无解码/渲染”的设备侧启动竞态，已通过 valid 字段剔除；最终报告两端均为 5/5 有效。
- 这不是重启设备或清空系统媒体/GPU 缓存后的 power-on cold；cold 指新进程第一次走该组件路径。
- 样本量适合工程趋势判断，不足以给出稳定的 P95。报告脚本因此不输出 P95。

原始数据和自动比较结果：

- [多素材总览](../BenchmarkResults/iphone12-20260826-optimized-multimedia-release/multi-comparison.md)
- [demo 对比](../BenchmarkResults/iphone12-20260826-optimized-multimedia-release/demo-comparison.md)
- [1.mp4 对比](../BenchmarkResults/iphone12-20260826-optimized-multimedia-release/1-comparison.md)
- [demo 新版原始 JSON](../BenchmarkResults/iphone12-20260826-optimized-multimedia-release/demo-vapplayerkit.json)
- [demo 旧版原始 JSON](../BenchmarkResults/iphone12-20260826-optimized-multimedia-release/demo-vap-master.json)
- [1.mp4 新版原始 JSON](../BenchmarkResults/iphone12-20260826-optimized-multimedia-release/1-vapplayerkit.json)
- [1.mp4 旧版原始 JSON](../BenchmarkResults/iphone12-20260826-optimized-multimedia-release/1-vap-master.json)
- [vap-master benchmark modifications](../BenchmarkResults/iphone12-20260826-1620-release-final/vap-master-benchmark-modifications.md)
- [compare_vap_benchmarks.py](../Scripts/compare_vap_benchmarks.py)

## 每个指标是否准确

| 指标 | 本次是否用于主结论 | 复核结论 |
| --- | --- | --- |
| prepare_api_to_ready_ms | 是 | 两边都从 benchmark API 调用开始，到 ready/prepare 事件到达 sink；包含异步 callback 调度，是本轮 prepare 主指标。 |
| prepare_ms | 否，仅诊断 | 两端实现内部耗时；新版从 session prepare 开始，旧版从旧实现的 prepare 起点开始，适合阶段分析，不作 headline 横向结论。 |
| play_to_first_frame_ms | 是 | 两边均从 play API 调用开始，到第一次 GPU/display 提交；这是最适合回答用户体验的指标。 |
| first_frame_ms | 否 | 新版内部起点是 session 进入 play，旧版起点是 API 调用，起点不同，不能横向比较。 |
| rendered | 否，仅诊断 | 新版统计 GPU 提交，旧版统计 legacy display 提交；可判断是否有渲染，但不是严格同义的吞吐指标。 |
| decoded | 否，仅诊断 | 新版是 AVAssetReader 产帧，旧版是 VideoToolbox 回调产帧；解码队列/预取策略不同。 |
| dropped | 否，仅诊断 | 本素材和 2 秒窗口两端都是 0，只说明本次没有触发丢帧。 |
| drawable_failures | 否，仅诊断 | 本次都是 0，不能推导高负载场景表现。 |
| decoder_rebuilds | 否，仅诊断 | 本次都是 0，不能推导后台恢复或 VT session 失效表现。 |
| session_finished | 否 | 采样读取后才调用 stop，不是稳定的 per-sample 指标，已排除。 |

## 为什么 Swift 重写版的 cold prepare 仍可能更慢

语言不是决定因素，prepare 做了多少工作才是决定因素。当前新版 PlaybackSession.prepare 依次包含：

1. MP4/vapc inspection；
2. 解码轨和 format description 检查；
3. Metal renderer/pipeline 准备；
4. 动态内容解析与纹理上传；
5. 音频协调器准备。

优化后新版 Release 阶段埋点如下：

| 素材 / 阶段 | cold | warm 中位数 |
| --- | ---: | ---: |
| demo inspection | 20.76 ms | 1.49 ms |
| demo frame source | 0.02 ms | 0.03 ms |
| demo renderer | 8.29 ms | 0.13 ms |
| 1.mp4 inspection | 27.22 ms | 1.55 ms |
| 1.mp4 frame source | 0.04 ms | 0.03 ms |
| 1.mp4 renderer | 6.44 ms | 0.13 ms |
| 1.mp4 dynamic resolve/upload | 0.11 ms | 0.06 ms |

`1.mp4` 新版 5 个样本均记录到非零 `dynamic_resolve` 和 `dynamic_upload`，且每个样本 `rendered > 0`、`dynamic_timeouts = 0`；因此这不是只走静态视频路径的结果。

优化前 warm frame source 约 7.10 ms；现在降到约 0.03 ms，说明缓存命中后 AVAsset/video track 已真正复用，而不是只复用 vapc JSON。

主要原因有三个：

- AssetInspector 为校验 MP4/vapc 加载 AVURLAsset 轨道信息；旧实现的 FrameSource.prepare 又单独加载一次。优化后 FrameSourceContext 直接复用 inspector 的 AVURLAsset/video track。
- MetalContext 现在先只准备视频 pipeline；有真实动态内容时，才在 prepareDynamic 阶段创建 overlay/punch pipeline。
- cold inspection 本身仍需做文件签名、MP4 box 和缓存校验；demo 约 20.76 ms，1.mp4 约 27.22 ms，这是当前 cold 的主要剩余成本。

旧版的流程是 MP4 parser/config manager 加载，然后使用 legacy renderer；它的资源边界和初始化策略不同。即使新版全部使用 Swift，也不会自动消除重复 metadata 查询或 pipeline 编译成本。

## 对技术方案总结的准确说法

基于优化后多素材数据可以保留以下优势：

- warm prepare：demo 快 65.6%，1.mp4 快 75.7%。
- 含图片/文字替换的 1.mp4：cold prepare 快 22.0%，cold API→首帧快 15.3%，warm API→首帧快 5.9%。
- 指标采集和边界定义更完整：能拆分 prepare、解码、GPU 提交、丢帧和 drawable failure。
- 生命周期和取消隔离更清晰；这不是本轮 2 秒吞吐表能直接证明的，需要结合功能/长循环测试。
- 本轮复测中两个素材的 cold API→首帧都更快；但它仍只是每个素材单次进程 cold 样本，不能宣传为所有设备、所有素材的无条件领先。

暂时不要写成：

- “所有设备、所有素材的 cold API → 首帧全面更快”：本轮只有两个素材、每个素材一个 cold 进程样本。
- “decoded/rendered 一定更高”：两端事件语义并不完全相同。
- “0 丢帧代表任何素材都不会丢帧”：本轮素材压力不足以证明这一点。

## 下一步最有价值的优化

当前剩余优化重点是 cold inspection（demo 20.76 ms、1.mp4 27.22 ms），后续可考虑缓存 MP4 box/signature 结果并继续验证文件变更安全性。动态素材路径已经验证了延迟 overlay pipeline 的收益；继续使用同一采集器，重点观察 prepare_stages_ms 和 API→首帧，不要只看平均 FPS。
