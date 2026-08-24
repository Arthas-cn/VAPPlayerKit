# VAPPlayerKit 性能评估

## 1. 结论

当前实现已具备可投入常规透明动效场景的基础：媒体 inspection 和视频解码不占用 MainActor，解码帧数量有固定上限，渲染使用 Metal，播放生命周期由独立 session 和 token 隔离，动态纹理有明确内存预算，停止后能够自动验证核心资源释放。

它还不是“完成所有性能验收”的版本。跨 session 的 MetalContext 共享已经落地并经过模拟器与 iPhone 12 多实例实测；剩余优先项是减少列表多实例同时 prepare 的峰值，以及用 Instruments 和长循环真机测试补足 CPU、GPU、峰值内存与能耗数据。本文区分已经由代码/自动测试证明的事实和仍需实测的目标，不用模拟器结果代替真机性能结论。

## 2. 当前播放路径

```text
本地 MP4
  -> AssetInspector（MP4 顶层 box、vapc、AVFoundation 轨道）
  -> AssetMetadata + 不可变 VapcDocument
  -> AVAssetReaderFrameSource（系统 H.264/HEVC 解码，NV12）
  -> FrameRingBuffer（默认 6 帧、满时背压）
  -> PTS / CADisplayLink 调度（落后时丢弃过期帧）
  -> MetalRenderer（YUV、packed Alpha、动态纹理合成）
  -> CAMetalLayer
```

动态文字和图片在 prepare 阶段预栅格化/预缩放并上传为纹理，不在逐帧渲染路径创建 `UIImage`。每次播放创建独立 `PlaybackSession`，旧异步回调通过 session token 与 operation generation 隔离。

## 3. 已实现的性能与稳定性措施

### 3.1 CPU 与调度

- `AssetInspector.inspectDetails` 是非 actor 隔离的 async 方法；当前 Swift 语言模式下按 SE-0338 在 generic executor 执行。AVFoundation 轨道读取使用 async load，视频解码在独立 frame-source queue 执行。发布验收仍应以 Time Profiler/signpost 确认主线程没有 parser 长任务。
- 播放时钟按媒体 PTS 消费帧，不按屏幕刷新率盲目推进视频；落后时一次消费多帧并只渲染最新到期帧。
- `FrameRingBuffer` 默认容量为 6。生产者在满缓冲时等待，`stop` 会取消等待并唤醒解码队列。
- 每一轮循环重建 `AVAssetReader`，避免复用已结束 reader 的非法状态。
- 离开 window 或进入后台时按 `BackgroundPolicy` suspend/stop，避免明确可见性丢失后继续无意义播放。

### 3.2 内存与输入边界

- MP4 inspection 上限为 2 GiB；MP4 顶层 box 数量上限为 100,000。
- vapc JSON 上限为 8 MiB，画布/槽位单边上限为 16,384 px，source 上限为 256，frame 上限为 100,000，每帧 attachment 上限为 256。
- RGBA 动态纹理单张预算为 64 MiB、单 session 合计预算为 128 MiB；解析、预处理和 Metal 上传三处都会校验。
- 默认 6 个 NV12 解码帧的像素面理论占用约为 `encodedWidth × encodedHeight × 1.5 × 6` 字节，另有 `CVPixelBuffer` 对齐、IOSurface 和 AVFoundation 内部开销。例如 1920×1080 的六帧裸像素约 17.8 MiB，不能将其当作进程真实增量。
- `AssetMetadata` 可复用入口避免为同一未变化文件重复读取 MP4 顶层 box 和解析 vapc。复用在解码轨准备前后校验标准化 URL、稳定文件 identity、文件大小、修改时间，并再次核对解码轨尺寸和 codec。源文件生命周期内仍须由宿主保持不可变；真正基于同一打开文件身份的强一致性需要后续统一 inspection/decode 文件描述符。

### 3.3 GPU 与资源所有权

- 视频保持 NV12，在 shader 内完成 YUV 转 RGB、Alpha 解包和动态 attachment 合成，避免先转换整帧 RGBA 的额外 CPU 拷贝。
- `CAMetalLayer.framebufferOnly = true`，渲染目标保持最小用途。
- `InFlightFrameResources` 持有 pixel buffer 和 `CVMetalTexture`，直到 command buffer completion 后才释放。
- `MetalContext` 在 package 级线程安全地缓存 device、shader library、两条 pipeline 和 `CVMetalTextureCache`；Y/UV texture 创建与 cache flush 都经过同一把锁。renderer dispose 等待已提交 command buffer、释放本 session 引用后才请求 idle flush；当任一 renderer 仍有 in-flight submission 时不会触碰共享 cache，并按 60 个完成 submission 或 2 秒节流清理。
- command queue 默认按 package 共享。独立 queue 仍保留为诊断/对照策略，便于在不同 GPU 上复测，不影响 renderer 的 per-session 状态隔离。

### 3.4 已有可观测性

`MetricsSink` 已覆盖 prepare、首帧、解码/渲染/丢帧数量、dynamic resolve、drawable failure、ring buffer 峰值及结束原因。该接口适合宿主接入性能平台，但目前仓库没有自动生成跨机型基准曲线。

## 4. 本次验证证据

截至 2026-08-24，本次改动新增并通过以下自动化验证：

- 纯字符串动态文字按 vapc 颜色/字重绘制，并把字号限制在原 slot 内。
- 未设置动态 provider，或 provider 返回 `nil` 时，所有动态槽位解析为透明隐藏，prepare 不失败。
- 同一 URL 的可复用 metadata 跳过 `AssetInspector` 再解析；不同 URL 和手工摘要 metadata 被拒绝。
- 真实 fixture 完成 prepare、启动解码并进入播放时间线后执行 stop，弱引用自动确认 `PlaybackSession`、`AVAssetReaderFrameSource`、`MetalRenderer` 均释放。
- `PlayerView` 注册应用生命周期通知后销毁，弱引用自动确认通知闭包不反向持有播放器。
- SwiftExample 与 ObjectiveCExample 在 iOS 模拟器目标编译通过。
- 完整 package 单元测试在 iOS 模拟器通过 50/50；SwiftExample 的原 3 项 smoke/batch UI tests 与新增 2 项 queue UI tests 均已在连接的真机通过（分别记录，合计 5/5 test case 证据）。每种策略的基准 test case 都启动 3 个独立 app 进程；每次 2 秒窗口要求 12 个 `PlayerView` 各至少渲染 5 帧、后 1 秒仍有新增帧、无 session failure 和 drawable failure。
- MetalContext 对照压测（12 renderer）：每种策略的 sequential 与 concurrent 两轮各使用 12 renderer；模拟器共享策略只构建 1 份 context/1 个 queue，独立策略只构建 1 份 context 但两轮合计创建 24 个 queue。并发 prepare 计时是在同一 context 已由 sequential pass warm-up 后测量，不代表冷启动；模拟器曾测得 shared `0.57 ms`、per-renderer `4.15 ms`。
- iPhone 12（iOS 26.5.2）最终真机 queue 基准为每策略 3 次 fresh-process；每次都是 12 个播放器、2 秒窗口、每 player 至少 5 帧且后 1 秒仍有新增帧，并通过 `status=PASS`（两种策略各 3/3）。最终摘要如下：

  | 策略 | concurrent prepare median | range（3 次） | rendered 总量 range | dropped 总量 range | session/drawable failure |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | shared | 41.20 ms | 40.61–45.95 ms | 547–561 | 4–8 | 0 / 0 |
  | perRenderer | 40.69 ms | 39.86–45.26 ms | 548–562 | 1–6 | 0 / 0 |

- 选择 shared 作为生产默认：它把 12 renderer 的 command queue 从 24 个降为 1 个，且最终真机 per-player floor、渲染总量与 perRenderer 基本相当；本轮 perRenderer 的 dropped 范围较低，但时延/帧数区间重叠，3 次运行不足以宣称稳定的性能优劣。需要优先压低丢帧时可用 `-vap-metal-command-queue-policy=perRenderer` 做诊断/场景化覆盖；后续应以更多设备和 Metal System Trace 决定是否切换默认。

资源释放测试能发现确定性 retain cycle，但不能替代 Allocations/Leaks：系统媒体与 Metal 驱动可能保留缓存，进程 RSS 也可能不会立即下降。因此“对象可释放”和“长循环没有常驻内存增长”必须分别验收。

## 5. 当前缺陷与优化机会

### P0：发布前必须补齐的验证

1. **真机长循环和多实例内存曲线尚未量化。** 需要用 Allocations/Leaks 对 prepare/play/stop/deinit 重复至少 1,000 次，并运行 30 分钟循环；记录稳定后的 live bytes、dirty memory 和增长斜率。
2. **尚无 GPU 基准。** 需要用 Metal System Trace 验证 command buffer 时长、drawable starvation、纹理缓存命中及 60/120 Hz 屏幕下的 GPU 占用。
3. **尚无明确性能门槛。** 建议按代表机型/素材建立 prepare P50/P95、首帧 P50/P95、平均丢帧率、峰值内存和能耗阈值，CI 只做功能回归，定期真机任务做性能回归。

### P1：高收益实现优化

1. **Metal 对象按 session 重建。** 已由线程安全的 package 级 `MetalContext` 解决：device、library、pipeline state、texture cache 和默认 command queue 跨 session 共享；12 实例模拟器/真机压力数据见第 4 节。后续仍可用 Metal System Trace 补充不同 GPU 家族的 command buffer 时延曲线。
2. **列表多播放器没有全局并发预算。** 示例只限制为可见 cell，但快速滚动仍可能同时解析、解码并创建多个 renderer。组件可增加可选 session scheduler，按可见性/优先级限制并发 prepare 与 decode；宿主也应在 `didEndDisplaying` 立即 stop。
3. **inspection 仍映射整个文件。** `Data(mappedIfSafe:)` 通常是虚拟内存映射，但仍扫描顶层 box，并用 `subdata` 提取 vapc。可改为 `FileHandle`/区域映射仅读 box header 和 vapc payload，降低超大文件地址空间与页错误压力。
4. **动态 timeout Task 不会在成功后立即取消。** gate 保证不会重复完成，但每个 tag 的 sleep task 最长存活 8 秒。可保存 timeout task 并在 gate 首次完成时 cancel，减少大量动态 source 同时 prepare 时的短期任务数量。

### P2：场景化改进

1. **metadata 复用仅限内存对象和同一路径。** 这是有意的安全边界：`AssetMetadata` 内含不可公开的完整帧布局，不能序列化后跨进程使用。若业务需要磁盘缓存，应设计版本化 `AssetInspectionCache`，以内容哈希或 inode/size/mtime fingerprint 校验，并保持内部 document 不可变。
2. **纯字符串无法精确还原字体。** vapc 只有颜色、粗体标记和槽位，没有字体文件或精确字号。`.textReplacement` 只能自动 fit 系统字体；要品牌字体或固定排版必须用 `.text(_:attributes:)`，或扩展资源格式显式携带字体描述。
3. **嵌入音频不是 sample-level 同步。** 当前音频协调适合普通动效；对口型或严格同步场景应改为基于 host time 的音频调度，并记录 A/V drift。
4. **解码后端依赖 `AVAssetReaderTrackOutput`。** 实现简单且走系统解码，但没有直接控制 VideoToolbox session、像素池和 sample 提交。只有在真机数据证明 reader 创建或循环成本成为瓶颈时，才值得引入更复杂的 VideoToolbox backend。
5. **文字栅格化在 MainActor。** 这是为规避并发 UIKit/TextKit 绘制在真机上的死锁；动态 source 很多或纹理很大时可能增加 prepare 的主线程负担。可评估 CoreText + `CGContext` 的纯后台实现，前提是保持跨系统版本一致性。

## 6. 建议性能验收矩阵

| 维度 | 最低覆盖 |
| --- | --- |
| 设备 | 一台最低支持系统设备、一台 60 Hz 主流设备、一台 120 Hz 设备 |
| 编码 | H.264、HEVC；24/25/30/60 fps；带/不带音频 |
| Alpha | Left、Right、Top、Bottom；legacy 无 vapc |
| 尺寸 | 小图标、720p、1080p；至少一个接近纹理预算的动态素材 |
| 生命周期 | 单次、快速 A/B 切换、1,000 次创建销毁、30 分钟循环、前后台、push/pop |
| 并发 | 1、4、8 个可见播放器，快速滚动反复复用 cell |
| 指标 | prepare/首帧 P50/P95、CPU、GPU、丢帧率、峰值/稳定内存、能耗、A/V drift |

## 7. 推荐执行顺序

1. 先完成 P0 真机基线，保存 Instruments trace 和原始指标。
2. 已完成共享 `MetalContext`；后续只需在新 GPU 家族上复用同一素材矩阵确认 command queue 策略。
3. 增加多实例 scheduler，在列表 1/4/8 实例下验证吞吐、首帧和滚动流畅度。
4. 将 inspection 改为区间读取，并以大文件 prepare 数据验证收益。
5. 最后评估 CoreText 后台文字栅格化和自定义 VideoToolbox backend；没有测量瓶颈时不增加复杂度。

## 8. 复现命令

```sh
xcodebuild -workspace VAPPlayerKit.xcworkspace \
  -scheme VAPPlayerKit \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  test

xcodebuild -workspace VAPPlayerKit.xcworkspace \
  -scheme SwiftExample \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  test
```

每次性能改动应同时附：设备/系统/构建配置、素材名和编码参数、重复次数、冷/热启动定义、原始数据及相对基线变化。仅报告“平均 FPS”不足以证明首帧、峰值内存、掉帧尖峰或资源回收质量。
