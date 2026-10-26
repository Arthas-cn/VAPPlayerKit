# VAPPlayerKit v2 架构与生命周期

本文说明当前 v2 工作树的真实分层与使用合同。对外示例见[中文 README](../README.md)与[English README](../README_en.md)，发布记录见[CHANGELOG](../CHANGELOG.md)。构建、自动测试和真机验证结果待维护者登记；本文不代表已发布版本或已通过验证。

## 1. 基线与边界

- Swift tools 6.4、Swift 6 language mode、iOS 26。
- 一个 Swift library product：`VAPPlayerKit`。没有 Objective-C facade、NSCopying 配置对象或旧 API 兼容层。
- SwiftUI 页面使用 `VAPPlayerView`；需要显式资源排空屏障的组件，通过 UIKit `PlayerView` 桥接。
- 只播放现存、持续可读的本地普通文件。支持 H.264/HEVC 视频轨，透明合成采用一个编码帧中的颜色与 Alpha 区域。
- 宿主负责下载、ZIP/config.json、关联资源准备、图片共享缓存、数据库、跨播放器并发调度和文件所有权。
- 本包不修改 App 全局 AVAudioSession，不建立 HTTP 服务或业务缓存，不提供原生 HEVC Alpha 或双文件透明视频接口。

正式依赖使用 `https://github.com/Arthas-cn/VAPPlayerKit.git` 的已核验 v2 revision/tag。历史 1.x tag 的接口不适用于本文；本地 package 路径仅用于开发联调。

## 2. 文件与职责

| 位置 | 职责 |
| --- | --- |
| `Public/PlayerView.swift` | MainActor UIKit 入口、当前 session、准备操作代次、退役 session 的排空所有权 |
| `Public/VAPPlayerView.swift`、`Public/VAPPlaybackRequest.swift` | SwiftUI 值输入与低频事件；业务不持有可变播放器对象 |
| `SwiftUI/VAPPlayerController.swift` | 稳定请求身份、展示门、播放意图、系统暂停与终态去重 |
| `SwiftUI/VAPPlayerTransport.swift` | 单请求 UIKit 桥、挂载容器及视图销毁后的清理 owner |
| `Public/PlaybackOptions.swift`、`Public/PackedAlphaLayout.swift` | 不可共享修改的值配置与明确的透明几何合同 |
| `Internal/AssetInspector.swift`、`MP4BoxReader.swift`、`VapcReader.swift` | 在并发执行器检查文件、轨道和布局，返回不可变结果 |
| `Public/AssetMetadata.swift`、`Public/AssetMetadataCache.swift` | 值摘要、文件来源凭证、进程内 LRU 与共享检查任务 |
| `Internal/PlaybackSession.swift` 及两个扩展 | 单次准备、播放、暂停、循环与终态；统一收口子系统 |
| `Internal/AVAssetReaderFrameSource.swift`、`FrameRingBuffer.swift` | 串行 reader、解码生产与有界缓冲，不触碰业务 UI |
| `Internal/MediaClock.swift`、`FramePacer.swift` | 媒体时间与 VSYNC 驱动，暂停时冻结时间轴 |
| `Internal/MetalRenderer.swift`、`Resources/Shaders/VPKShaders.metal` | NV12 转换、颜色/Alpha 采样、动态槽合成与 GPU 排空 |
| `Internal/DynamicResolver.swift`、`AnimatedDynamicPlayback.swift`、`MarqueeDynamicPlayback.swift` | 串行解析已准备内容，栅格化、动态图与跑马灯时间轴 |
| `Internal/AudioCoordinator.swift`、`AudioPlaybackRun.swift`、`AudioPlaybackDriver.swift` | 内嵌音轨就绪门、运行错误、定位结果和真实异步操作排空 |

这些目录是同一个 target 内的职责分组，不是独立发布模块。内部对象不进入 TCA State；宿主只保存请求 ID、URL、值配置与低频事件状态。

## 3. 对外 API

所有 UIKit 播放操作及动态 provider 位于 MainActor。`PlaybackOptions`、`AssetMetadata`、布局、SwiftUI 请求与事件为值类型；不能把可变 AVFoundation/Metal 对象传入业务状态。

| 入口 | 合同 |
| --- | --- |
| `PlayerView.inspect(url:options:) async throws -> AssetMetadata` | 检查本地文件和槽位，不建立播放 session、provider、音频或 GPU 管线 |
| `prepare(url:options:) async throws -> AssetMetadata` | 完成所有准备，不启动时间轴 |
| `prepare(url:metadata:options:) async throws -> AssetMetadata` | 校验来源后复用同文件、同模式的检查结果 |
| `play(url:options:)`、`play(url:metadata:options:)` | 首次播放；相同输入的 ready session 可复用，否则由入口拥有异步准备任务 |
| `pause()`、`resume()` | 保留位置；resume 不代替单独 prepare 之后的首次 play |
| `stop()`、`clear()` | 同步停止接纳新工作；clear 另外隐藏画面，底层清理仍可能未完成 |
| `clearAndWait() async` | 等待当前及已登记退役 session 的实际资源收尾，不删除源文件 |
| `isMuted` | 准备前及运行中可变的实例级静音期望值 |

`PlayerDelegate` 包括 `playerDidStart(_:)`、`player(_:didUpdate:)`、`playerDidFinish(_:reason:)` 和 `player(_:didFail:)`。delegate 为弱引用。准备成功与进入运行态不等于 GPU 已呈现首帧；finish/failure 与物理清理也不是同一个时刻。

`PlayerView.dynamicContentProvider` 是弱引用，接纳后的 session 强持有该 provider 至清理结束。`metricsSink` 是弱引用且接收方须遵守 Sendable/线程安全合同，指标可能从非主线程交付。

## 4. 模式与透明坐标

`PlaybackOptions.assetMode` 默认为 `.vap`，不是 `.automatic`。

| 模式 | 检查与渲染 |
| --- | --- |
| `.vap` | 读取 vapc；无 vapc 的旧 VAP 使用左 Alpha 的等分布局 |
| `.ordinaryVideo` | 完整编码帧作为画面；不读取 vapc、不探测透明布局 |
| `.packedAlpha(layout)` | 只使用调用方给定矩形；不读取 vapc、不探测、不自动切半 |
| `.automatic` | 优先 vapc；无 vapc 时探测旧拼接特征，证据不足则普通视频 |

`automatic` 可能读取少量视频帧用于判型，因此 `inspect` 不等于绝对没有解码成本。统一播放器已经知道资源类型时应传确定模式。

`PackedAlphaLayout(arrangement:colorRect:alphaRect:)` 使用 `VideoPixelRect(x:y:width:height:)` 整数像素区域。坐标原点是未应用视频轨 `preferredTransform` 的编码帧左上角：

- `.sideBySide` 要求左右区域沿横轴不相交；`.topBottom` 要求沿纵轴不相交。颜色可以位于任意一侧。
- 区域须正尺寸且完整位于编码帧内。不要求同尺寸、对半或偶数边界。
- 最终画布为颜色区域的尺寸；颜色与 Alpha 使用局部 UV 对应采样。
- Alpha 亮度为黑时透明，为白时不透明。
- 显式透明布局没有动态槽位。非法几何抛 `invalidAlphaLayout`，不降级成普通视频或 legacy 布局。

检查还限制文件大小、真实编码尺寸、JSON 与纹理预算，防止在解码/GPU 分配后才发现明显异常输入。当前检查上限为 2 GiB 文件、8192 像素单边、8,388,608 编码总像素；这些是内核保护值，不是上层下载协议。

## 5. 检查结果与缓存

`AssetMetadata` 提供编码尺寸、画布尺寸、Alpha 模式、时长、帧数、音轨存在性、codec、VAP 版本和 `dynamicSources`。槽位含 `tag`、`slotSize` 与真实 `kind`，上层无需根据 tag 名字猜图片/文字。

公开初始化器产生可展示、可测试的摘要，`isReusableForPlayback` 为 false。只有内核检查生成的 metadata 带有内部布局和文件来源凭证，可交给 `prepare(url:metadata:options:)`。凭证核对规范化路径、文件标识、文件大小、修改时间和完整 assetMode；它不是文件内容 hash。宿主必须保持源文件不可变，不能依靠调整时间戳来覆盖正在使用的文件。

`AssetMetadataCache.shared` 是 actor，默认最多 20 项。缓存键是本地 URL 与完整 assetMode，显式透明矩形参与键值。它只缓存解析快照，不保存纹理、reader、播放器或磁盘副本。

- 相同键的并发 miss 共用一次检查。
- 单个消费者取消不取消其他消费者的共享检查；该消费者也等待检查真实结束后再报告取消。
- `setCountLimit(_:)` 修改容量，0 禁用结果缓存；`remove(url:)` 失效某 URL 的全部模式；`removeAll()` 全部失效。
- 失效操作使旧检查失去回写资格，但不会强制停止已有检查或当前播放。
- 清 metadata 缓存不是文件删除许可，也不是资源排空屏障。

## 6. 准备与首次播放

典型顺序：

```text
宿主下载并持有不可变文件
    → inspect（可选，由宿主提前匹配动态槽）
    → prepare：检查/复用 → decoder track → renderer
               → provider 串行解析 → 动态纹理上传 → 音频 ready
    → ready
    → 首次 play
    → 首批视频帧 + 音频就绪 → 媒体时钟运行
    → pause / resume / 循环 / 终态
    → clearAndWait
    → 宿主可回收本次文件使用权
```

`PlayerView` 每次替换、停止、清空都会作废旧操作代次；异步结果不能启动已经被替换的画面。下一轮准备先等待已退役 session 排空。`prepare` 的任务由 session 持有，清理同时等待这项任务结束，避免 provider 或 metadata 检查仍未返回时先归还上层加载名额。

首次 play 接纳后，若准备期间收到 pause，保留首次启动意图而不短暂启动声音。只有显式 resume 且窗口、正尺寸和前台条件允许时才继续。单纯 prepare 后调用 resume 不开始第一次播放。

循环与挂起恢复会重新定位音频。音频定位拥有独立代次；旧 seek/rewind 回调不能改变新一轮 audioReady 或错误终态。暂停期间完成的当前定位可以登记 ready，但状态门会阻止时间轴在暂停状态启动。

## 7. 动态资源准备

`DynamicContentProvider` 的签名为：

```swift
func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent?
func font(forTag tag: String) -> UIFont?
```

第二个方法有返回 nil 的默认实现。可提供 `.image(UIImage)`、`.textReplacement(String)`、`.text(String, attributes: TextAttributes)` 或 `.hidden`；nil/hidden 都保留底图，不补默认头像或默认文字。

内核先检查全部槽位纹理预算，再串行请求 provider，避免一个上层准备名额派生大量并行图片解码。provider 应返回宿主已经准备好的数据；网络、SDWebImage 查询和业务资源匹配都在外层屏障完成。

当前每项动态内容截止时间为 8 秒。到期会请求取消并最终报告 `dynamicContentTimeout`，但 Swift 取消不能强杀任意 provider。未合作退出的 provider 会继续由操作表持有；prepare 与 `clearAndWait` 均等其真实返回，期间不得回收文件或名额。provider 内也不能等待同一播放器的 `clearAndWait`，因为清理正等它返回。

动态图能力通过宿主可选链接的 SDWebImage 运行时能力识别。`.still` 取首帧，`.animated` 可保留动态图 provider 并推进帧；可读 `PlaybackOptions.canPlayAnimatedDynamicImages` 判断能力。本包不下载图片，不创建或清理 SDWebImage 缓存。

文字采用 UIKit 栅格化，超宽时按 `.truncate` 或 `.marquee` 处理。纹理、动画帧和文字布局属于 session 资源，在最终排空中释放。

## 8. 音频与画面调度

`.embedded` 为默认音频策略；有音轨时，准备必须通过 asset 可播放与 `AVPlayerItem.readyToPlay` 两个条件。内部准备超时为 15 秒，运行期 item.failed、播放到末尾失败及 seek/rewind 的失败会阻止继续无声播放。`isMuted` 不改变请求身份，准备前设置和运行中切换都作用于当前内嵌音轨。

`.muted`、`.external`、`.disabled` 均不建立内嵌播放器；external 的出声与同步由宿主负责。所有模式都不接管 App 的 AVAudioSession。

解码在串行 reader 工作队列生产，ring buffer 提供有界背压。主状态机按媒体时间取到期帧，落后时允许丢帧；同一时刻不堆积多个未完成的逐帧 GPU 提交。自然循环结束要求解码完毕、缓冲及待呈现帧为空、当前渲染完成且媒体时间越过末帧，不能仅凭解码器 EOF 结束。

暂停冻结时钟和声音。离窗、后台或无有效尺寸时安全挂起；需要重建 reader 的恢复从保留的媒体时间继续。上层配置可关闭自动恢复，避免系统回前台覆盖业务队列的控制权。

## 9. 终态与真实排空

每个 session 的 finish/failure 互斥且最多一次。进入终态先封闭回调接纳门，再停止子系统，避免同步取消回调重入并改写原终态。

同步停止先禁止新工作：取消准备、停 pacer、取消 reader 和 provider、停动态图/文字、停止音频、dispose renderer。随后受管 teardown 依次等待：

1. 已开始的准备任务退出。
2. 动态 provider 真实返回。
3. reader 工作队列排空。
4. 音频 load/seek 及事件消费者退出。
5. renderer 与已提交 GPU 工作结束。

最后清空动态快照、检查结果及 provider 引用。底层停止 API 返回不等于异步回调已经返回，因此排空路径保留实际操作任务；取消等待本身不能提前释放它们。未显式清理的 UIKit/SwiftUI 宿主有受管退役 owner 兜底，任务结束后移除。

`clearAndWait` 只收口它接纳时的当前与退役资源，不赋予调用者阻止之后另一个业务调用创建新请求的权力。宿主应串行拥有同一个 PlayerView 的控制权，不应一边回收其文件一边从其他入口重新 play。

跨实例的全链路准备数 N、驻留数 P 与公平队列属于上层统一播放器。本包没有进程级加载调度器。上层必须持有对应额度到真实排空，不能在收到 finished/failed 或发出 cancel 的瞬间归还。

## 10. SwiftUI 合同

`VAPPlaybackRequest(id:url:options:)` 的 ID 表示一次不可复活的播放请求。URL/options 在同一 ID 下保持不变；改变资源、配置或重播要创建新 ID。不要在 body 每次重算时创建 UUID。

`VAPPlayerView` 接受 `resource`、`intent`、`controlRevision`、`isVisible`、`isMuted`、可选 `dynamicContentProvider` 和 `onEvent`。provider 与事件回调在接纳请求时固定，普通视图重算不会重新创建管线。

- 有效窗口、正数尺寸、活动场景满足后才开始准备。
- `.paused` 保留本请求；`.stopped`、不可见或 resource=nil 结束请求。
- 系统暂停解除后仍需 `.playing` 配合递增的 `controlRevision`，防止自动恢复抢占外部队列。
- 内核强制 `.suspend` 并关闭 `automaticallyResumesAfterSuspension`，恢复只走 SwiftUI 控制器。
- `isMuted` 可原位改变；可见性由宿主提供，不能把列表 onAppear 当成真实可见性。
- 每个事件带原 requestID；业务先核对身份，finished/failed 之后不再接纳该请求业务事件。

事件只有低频状态：等待展示、准备、ready、首次 started、paused、resumed 和终态。started 不是 GPU 首帧完成证明。终态可能早于资源排空，当前公开 SwiftUI 接口不提供 drain acknowledgment；需要严格文件 lease 屏障的统一资源层应通过 UIKit `clearAndWait` 桥接。

## 11. 验证范围

现有测试按四个 target 分组：

| target | 主要关注 |
| --- | --- |
| `VAPPlayerKitTests` | 配置、透明矩形、metadata 来源与失效、音频门/取消/定位、资源生命周期、SwiftUI 请求状态 |
| `VAPPlayerKitParserTests` | MP4/vapc 与旧拼接判型，正式 VAP fixtures |
| `VAPPlayerKitTimingTests` | 时钟、时间换算和缓冲节奏 |
| `VAPPlayerKitRendererTests` | 透明区域采样、shader 与渲染路径 |

音频和 SwiftUI 单元场景使用可控门与替身验证交错顺序；测试存在不等于构建或执行成功。v2 构建、全部自动测试、真机帧呈现与声音结果目前待登记。发布前需核实真实 VAP/普通视频/显式透明布局、动态图片文字、循环、前后台、快速替换、重复 clearAndWait，以及上层文件在 drain 之前未被删除。
