# VAPPlayerKit：基于 Swift + SPM 的全新 VAP 播放组件架构

> 目标：构建一个可以独立发布到 GitHub 的 VAP 播放组件。实现全部使用 Swift，提供 Swift 原生 API，同时提供稳定的 Objective-C 调用入口。不兼容旧 VAP API，不依赖任何业务项目、下载器、图片库或全局播放调度器。

## 0. 设计信息

| 项目 | 决策 |
| --- | --- |
| Package 名称 | VAPPlayerKit |
| Swift Module | VAPPlayerKit |
| Objective-C 符号前缀 | VPK |
| 最低系统 | iOS 15 |
| 核心实现 | Swift |
| GPU Shader | Metal |
| Objective-C 支持 | Swift 的 @objc API + header-only facade，无 Objective-C 实现文件 |
| 旧 API 兼容 | 不提供 |
| 网络、下载、缓存 | 不属于本组件 |
| 播放输入 | 本地 file URL；可扩展为受控的数据源协议 |
| 推荐解码路径 | VideoToolbox + Metal |
| 备用验证路径 | AVPlayerItemVideoOutput 或 AVAssetReaderTrackOutput |
| 本地参考源码 | `vap-master/`（gitignore，仅本地对照，不入库、不复制进 package） |

## 0.1 本地参考源码：`vap-master`

仓库根目录的 `vap-master/` 是 **Tencent VAP / QGVAPlayer** 的完整参考实现，用于对照 VAP 容器格式、Alpha 布局、vapc/vapx 元数据、VideoToolbox 硬解和 Metal 合成行为。它**不是**本组件的实现来源，也不是依赖。

使用规则：

- 只读对照。实现时查阅格式与边界行为，不把旧代码翻译进 `Sources/`。
- 已写入 `.gitignore`，不提交、不随 GitHub 发布。
- 不复用 `UIView+VAP` category、`QG`/`HWD` 前缀、`repeatCount` 额外重复次数语义、全局 FPS dispatcher，以及 KVC 私有字段。
- 公开 API、线程模型、错误域和资源定位全部以本文档和 `Sources/VAPPlayerKit` 为准。

目录对照：

| 参考路径 | 用途 |
| --- | --- |
| `vap-master/Introduction.md` | VAP 格式、压缩率和能力说明 |
| `vap-master/iOS/QGVAPlayer/QGVAPlayer/Classes/` | 旧 iOS 播放器对象图 |
| `vap-master/iOS/QGVAPlayer/QGVAPlayer/Classes/UIView+VAP.h` | 旧公开 API（category + delegate） |
| `vap-master/iOS/QGVAPlayer/QGVAPlayer/Classes/MP4Parser/` | MP4 box / sample table 解析 |
| `vap-master/iOS/QGVAPlayer/QGVAPlayer/Classes/Controllers/Decoders/` | VideoToolbox 硬解 |
| `vap-master/iOS/QGVAPlayer/QGVAPlayer/Classes/Views/Metal/` | Metal / vapx 合成 |
| `vap-master/iOS/QGVAPlayer/QGVAPlayer/Shaders/` | 旧 Metal shader |
| `vap-master/iOS/QGVAPlayerDemo/` | Objective-C 调用方式对照 |
| `vap-master/iOS/QGVAPlayerDemoSwift/` | 旧 Swift demo 对照 |
| `vap-master/tool/` | vapc/vapx 工具与 JSON 描述 |
| `vap-master/Android/` | 跨端行为对照，不迁入 iOS package |

旧类型到新类型的职责映射（命名不兼容，只对照职责）：

| vap-master | VAPPlayerKit |
| --- | --- |
| `UIView+VAP` / `QGVAPWrapView` | `PlayerView` / `VPKPlayerView` |
| `HWDMP4PlayDelegate` | `PlayerDelegate` / `VPKPlayerDelegate` |
| `playHWDMP4:repeatCount:` | `play(url:options:)` + `PlaybackOptions.loopCount` |
| `HWDMP4EBOperationType` | `BackgroundPolicy` |
| `contentForVapTag:` / `loadVapImageWithURL:` | `DynamicContentProvider` |
| `QGVAPConfigModel` / `QGVAPConfigManager` | `AssetMetadata` / `AssetInspector` / `VapcReader` |
| `QGMP4Parser` / `QGMP4Box` | `AssetInspector`（MP4 解析阶段） |
| `QGMP4FrameHWDecoder` | `VideoToolboxFrameSource` |
| `QGAnimatedImageBufferManager` | `FrameRingBuffer` |
| `QGAnimatedImageDecodeThreadPool` / 全局 FPS 桶 | `FramePacer`（仅当前 session，禁止全局 dispatcher） |
| `QGHWDMetalRenderer` / `QGVAPMetalRenderer` | `MetalRenderer` |
| `QGHWDShaders.metal` | `Sources/VAPPlayerKit/Resources/Shaders/VPKShaders.metal` |
| `QGMP4AnimatedImageFrame` | `DecodedFrame` |
| `setMute:` | `AudioMode` |

## 1. 这次重写的架构边界

VAPPlayerKit 是一个独立的媒体基础组件，不是任何宿主项目的播放器适配层。

组件内部只负责：

- 读取和校验 VAP 视频及 vapc/vapx 元数据。
- 硬件解码视频 sample。
- 按媒体时间线管理帧缓冲和丢帧。
- 将 packed RGB/Alpha 视频合成为透明画面。
- 解析并渲染动态图片、文字和其他 VAP source。
- 按明确策略处理音频、暂停、恢复、循环和生命周期。
- 提供 Swift API、Objective-C API、错误模型、测试工具和可观测性。

组件明确不负责：

- HTTP 下载、重试、鉴权和业务缓存。
- ZIP 解压和业务资源目录管理。
- 网络图片加载或绑定某个图片库。
- 礼物、头像框、房间、动画队列等业务概念。
- 业务层的播放优先级、资源淘汰和并发调度。
- 兼容旧 UIView category、旧 delegate、旧 repeatCount 或旧私有类型。
- 依赖宿主项目中的单例、全局 FPS dispatcher 或 KVC 私有字段。

宿主应用只需完成三件事：

1. 将自己的资源下载和缓存结果转换为本地 file URL。
2. 通过 typed dynamic provider 提供动态图片、文字等内容。
3. 监听组件事件，并决定何时播放、暂停、停止和释放。

这条边界是核心设计。它让组件可以单独编译、测试、发布，也避免把宿主业务的不稳定性带进解码和渲染核心。

## 2. 命名策略

原始 VAP 生态中存在较多全局类型、UIView category、私有 QG 前缀和含义不清的播放参数。新组件不复用这些命名。

推荐命名：

| 层级 | 命名 |
| --- | --- |
| GitHub 仓库 | VAPPlayerKit |
| Swift module | VAPPlayerKit |
| Swift 类型 | PlayerView、PlaybackOptions、AssetMetadata |
| 内部 Swift 类型 | PlaybackSession、AssetInspector、FrameSource、MetalRenderer |
| Objective-C 类型 | VPKPlayerView、VPKPlaybackOptions、VPKAssetMetadata |
| Objective-C 协议 | VPKPlayerDelegate、VPKDynamicContentProvider |
| Objective-C 错误码 | VPKPlaybackErrorCode |
| 资源前缀 | VPK |
| 私有目录 | Sources/VAPPlayerKit/Internal |

Swift 类型由 module 命名空间隔离，因此 Swift 调用可以保持自然：

~~~swift
import VAPPlayerKit

let player = PlayerView()
let options = PlaybackOptions()
~~~

Objective-C 调用使用 VPK 前缀，避免与旧 VAP 类型发生符号和语义混淆：

~~~objc
@import VAPPlayerKitObjC;

VPKPlayerView *playerView = [[VPKPlayerView alloc] initWithFrame:CGRectZero];
VPKPlaybackOptions *options = [[VPKPlaybackOptions alloc] init];
~~~

不做以下兼容：

- 不提供旧类型的 typealias。
- 不保留旧方法名的转发方法。
- 不使用旧的 repeatCount “额外重复次数”语义。
- 不把旧私有对象通过 KVC 暴露出来。
- 不让新组件内部类继续沿用旧播放器的对象图。

## 3. VAP 播放本质

VAP 通常不是普通的透明 MP4。

一个 VAP 视频帧可能包含：

- 同一 YUV 视频纹理中的 RGB 区域和 Alpha 区域。
- AlphaLeft、AlphaRight、AlphaTop 或 AlphaBottom 布局。
- vapc 中定义的逻辑画布尺寸。
- 动态图片、文字、字体、source rect、层级和混合参数。
- 可选的音频轨或外置音频配置。
- legacy 资源中缺失 vapc 时的默认布局规则。

因此，直接交给 AVPlayerLayer 只能显示 packed 视频，不能自动完成透明通道拆分和 VAP 合成。

“原生播放”在本方案中指使用 Apple 原生媒体底层能力：

- VideoToolbox：硬件解码和 CVPixelBuffer 输出。
- CoreMedia：sample、PTS、duration、CMTime 和媒体时间线。
- Metal：YUV 转换、Alpha 拆分和动态 source 合成。
- AVFoundation：资产检查、音频能力，以及可选的 native frame source。
- CADisplayLink：只作为 VSYNC 采样点，不负责定义视频 FPS。

### 3.1 解码后端选择

新组件抽象 VPKFrameSource，不让公开 API 依赖具体解码实现。

| 后端 | 优点 | 局限 | 规划 |
| --- | --- | --- | --- |
| AVPlayerLayer | 接入最简单 | 不能处理 packed Alpha 和动态合成 | 不采用 |
| AVPlayerItemVideoOutput | Apple 原生时钟和音频同步较好 | 逐帧控制、缓冲和取帧行为受 AVPlayer 影响 | Phase 0 对照验证，可作为可选后端 |
| AVAssetReaderTrackOutput | 原生解析、PTS 和 CVPixelBuffer，代码量较少 | 需要自己管理时钟、循环和音频同步 | 可作为稳定性基线 |
| VideoToolbox + 受限 MP4 sample reader | 控制力、吞吐和丢帧策略最好 | parser、VT teardown 和错误处理复杂 | 默认生产后端 |

默认生产设计使用 VideoToolbox，但只把 VPKFrameSource 的协议暴露给 PlaybackSession。Phase 0 必须用同一组 fixture 对照 AVPlayerItemVideoOutput 和 AVAssetReaderTrackOutput；如果 native backend 在 60/120 Hz、H.264/HEVC、Alpha 合成和快速循环下满足要求，可以优先选择更简单的后端。不能因为“代码更少”就跳过真机性能和帧准确性验证。

## 4. 总体架构

~~~text
Host Application
        |
        | local file URL + typed dynamic provider
        v
VAPPlayerKit.PlayerView
        |
        v
PlaybackSession
   |       |        |        |        |        |
   |       |        |        |        |        +-- AudioCoordinator
   |       |        |        |        +----------- DynamicResolver
   |       |        |        +-------------------- MetalRenderer
   |       |        +----------------------------- FrameRingBuffer
   |       +-------------------------------------- FrameSource
   +---------------------------------------------- AssetInspector
        ^
        |
   MediaClock / FramePacer
~~~

职责必须单向流动：

- PlayerView 只处理 UIKit、公开控制和宿主生命周期。
- PlaybackSession 只管理一次播放的状态和所有权。
- AssetInspector 只输出不可变 metadata。
- FrameSource 只产生带 PTS 的 decoded frame。
- FrameRingBuffer 只负责有限容量、顺序和背压。
- MediaClock 只决定“现在应该显示哪一帧”。
- MetalRenderer 只接收不可变 render snapshot 和 GPU 资源。
- DynamicResolver 只负责动态内容准备，不进入视频解码线程。
- AudioCoordinator 只负责明确的音频策略，不反向控制视频状态。

## 5. Swift 模块设计

### 5.1 PlayerView

公开的 UIView 子类，作为宿主唯一需要持有的播放视图。

负责：

- 主线程上的 prepare、play、pause、resume、stop、clear。
- bounds、contentsScale、drawableSize 和 content mode。
- 将 UIKit 生命周期转换为 session 的 suspend/resume。
- 持有当前 PlaybackSession 的强引用和旧 session 的取消句柄。
- 将所有事件统一转发到主线程。

不负责：

- 解析 MP4。
- 创建 VTDecompressionSession。
- 访问动态图片网络。
- 读取内部 frame。
- 直接操作 session 的私有状态。

### 5.2 PlaybackSession

每一次 play 都创建一个全新的 session，不复用上一次 session 的 decoder、clock、buffer 或动态资源状态。

建议状态：

~~~text
idle
  -> preparing
  -> ready
  -> playing <-> paused
  -> suspended
  -> finished
  -> stopping
  -> failed
~~~

状态不变量：

- 一个 session 只能有一个终态事件。
- stopping、finished、failed 不再回到 playing。
- 新资源播放时，旧 session 先取消并进入 stopping，再创建新 session。
- 每一个异步操作都携带 session token。
- token 不匹配的 parser、decode、image、audio、Metal callback 全部丢弃。
- finish、fail、stop、cancel 的语义必须区分，不能用一个 isFinish 布尔值覆盖。

### 5.3 AssetInspector

将文件和 VAP 配置转换为不可变 AssetMetadata。

metadata 至少包含：

- encodedVideoSize：实际视频编码尺寸。
- canvasSize：逻辑画布尺寸。
- alphaMode：left、right、top、bottom。
- codec：H.264 或 HEVC。
- frameCount。
- duration。
- 每个 sample 的 PTS、DTS 和 presentation duration，或可等价恢复这些信息的数据。
- hasAudio。
- vapVersion。
- 动态 source 的 tag、slot size、source rect、层级和参数。

解析器要求：

- 只在后台线程运行。
- 所有 box 的起始位置、长度、父 box 边界先校验，再做 offset 和整数换算。
- sample table、NAL size、JSON 长度和 source rect 必须有上限。
- 缺少 moov、视频轨、decoder description 或必需 vapc 时返回明确错误。
- legacy no-vapc 资源只能通过明确的 fallback 规则解析，不能根据尺寸无限猜测。
- 解析结果不包含 NSFileHandle、可变 JSON、parser cursor 或其他线程状态。
- metadata 可按 file fingerprint 缓存，但缓存不能持有 session、UIView 或 pixel buffer。

### 5.4 FrameSource

FrameSource 是解码后端的内部协议：

~~~swift
protocol FrameSource {
    func prepare() async throws -> FrameSourceMetadata
    func startProducing(to buffer: FrameRingBuffer, token: SessionToken)
    func pause()
    func cancel()
}
~~~

生产后端的职责：

- 使用单个有序 decode pipeline 提交 sample。
- 检查 CMBlockBuffer、CMSampleBuffer、VT session 和所有 OSStatus。
- 将 CVPixelBuffer 包装为带 token、PTS、duration 的 immutable decoded frame。
- 在 buffer 满时停止生产，形成背压。
- decoder queue 上完成 drain、invalidate 和资源释放。
- 对 kVTInvalidSessionErr 只允许有限次数的重建。
- 超过重建次数、硬解不支持、坏 NAL 或格式错误时进入明确错误，不无限重试。

不要让 FrameSource：

- 触碰 UIView、CALayer 或 delegate。
- 在回调中读取当前 session 的可变 frame。
- 把旧 session 的 CVPixelBuffer 发送到新 session。
- 通过 sleep 模拟视频播放。

### 5.5 FrameRingBuffer

使用固定容量 ring buffer，不使用“NSMutableArray 加 sort”作为主路径。

建议：

- 默认容量 4 至 6 帧。
- 高端设备和大尺寸视频可以配置 8 帧，但必须受内存上限约束。
- producer 和 consumer 各自拥有清晰的线程职责。
- frame 按 PTS 单调入队。
- buffer 满时暂停 sample 提交。
- buffer 空时允许短暂等待，但不能阻塞主线程。
- 播放落后时丢弃过期帧，只显示最后一个 due frame。
- stop 时先阻止新生产，再完成 decoder teardown，最后清空 buffer。

### 5.6 MediaClock 与 FramePacer

媒体时钟属于 session，不属于宿主应用的全局对象。

播放规则：

1. 优先使用 sample 的真实 presentation timestamp 和 duration。
2. 使用 CACurrentMediaTime 或 mach_continuous_time 建立 monotonic host clock。
3. pause 时冻结媒体时间，resume 时重新计算 host time offset。
4. 每次 VSYNC 只查询当前 media time，不把屏幕刷新率当成视频 FPS。
5. 尚未到时间的帧保持当前画面。
6. 到时间的帧按 PTS 消费。
7. 落后超过阈值时丢弃历史帧，优先显示最新可用帧。
8. 不使用平均 FPS 覆盖 sample duration。

FramePacer 可以在同一个 run loop 中内部复用 display link，但它必须是 package-private：

- 不注册宿主 target。
- 不按 FPS 创建全局桶。
- 不暴露 addTarget/removeTarget。
- 不持有业务对象。
- session token 失效后立即移除订阅。
- 只有当前可见且 window 有效的 session 参与采样。

这与应用级全局媒体 dispatcher 的设计不同。公共库内部只保留满足帧采样所需的最小机制。

## 6. Metal 渲染设计

### 6.1 MetalRenderer

MetalRenderer 接收：

- CVPixelBuffer 或 CVMetalTexture。
- immutable AssetMetadata。
- 当前动态内容 snapshot。
- 主线程转换出的 RenderSnapshot。

渲染步骤：

1. 从 YUV pixel buffer 创建 Y/UV texture。
2. 按 alphaMode 计算 RGB 和 Alpha 区域。
3. 在 shader 中完成 YUV 到 RGB 的转换。
4. 结合 VAP source rect 和动态纹理完成合成。
5. 输出 premultiplied alpha 到 CAMetalLayer。
6. 按 canvasSize 计算 AspectFit、AspectFill 或 ScaleToFill viewport。

不能使用 encodedVideoSize 直接决定宿主布局。packed video 的物理尺寸和逻辑画布尺寸必须分开。

### 6.2 GPU 资源生命周期

- `MetalContext` 在 package 内线程安全共享 MTLDevice、MTLLibrary、两条 render pipeline、CVMetalTextureCache 和默认 MTLCommandQueue；Y/UV texture 创建、cache flush 与 in-flight 计数共用一把锁。renderer 只保留当前 session 的动态纹理、snapshot、drawable 与 in-flight references。独立 command queue 仅作为诊断对照策略。
- MTLTexture、pixel buffer、dynamic snapshot 和 per-frame buffer 属于当前 render submission。
- command buffer 完成前，相关 CPU/GPU 资源必须保持有效。
- attachment 的 vertex buffer 和参数 buffer 使用预分配 ring allocator 或 sub-allocation。
- 禁止每帧 malloc、创建新的 MTLBuffer 或编译 shader pipeline。
- nextDrawable 为 nil、drawableSize 为零、Metal device 不可用时进入可恢复状态。
- renderer dispose 必须等待或关联 command buffer completion；只能通过 `MetalContext` 在无 in-flight submission 时做节流 flush，不能直接 flush 或释放仍被其他 session 使用的共享 texture cache。
- render queue 不能直接读取 UIView 的 bounds、window、traitCollection 或其他 UIKit 可变状态。

### 6.3 Shader 与 SPM 资源

Shader 放在 VAPPlayerKit target 的 Resources 中，由 Swift 使用 Bundle.module 定位。

禁止：

- 使用 main bundle 假设。
- 使用工作目录相对路径。
- 将 shader 文件散落在宿主项目。
- 让 Objective-C facade 负责资源定位。

第一次播放前可以异步预热 shader function 和 pipeline。pipeline 未就绪时保持 preparing，不阻塞主线程。

## 7. 动态内容和音频

### 7.1 Typed Dynamic Content

动态内容不使用字符串猜测类型，定义明确的数据模型：

~~~swift
public enum DynamicContent {
    case text(String, attributes: TextAttributes)
    case textReplacement(String)
    case image(UIImage)
    case hidden
}
~~~

`textReplacement` 服务于宿主只提供 tag/value 的常见场景：使用 vapc source 的颜色、粗体标记和 slot 约束，自动选择可放入槽位的系统字号。vapc 不包含字体文件或精确 point size，因此不能承诺恢复原字体族或精确字号；有严格排版要求时可使用 `text(_:attributes:)`，或由 provider 按 tag 返回字体。

图片槽位只接受已解码的 `UIImage`。组件不提供 `imageURL`，也不发网络请求；宿主应先下载再返回 `.image`。

宿主可在 `DynamicContentProvider.font(forTag:)` 中按 tag 提供字体。提供字体时组件保持该字体；未提供时自动字号最多缩小三次，仍无法放入槽位则使用 UIKit 的 `byTruncatingTail` 模式截断。

`.textReplacement` 扩展了 public enum，`.imageURL` 已移除，二者对 exhaustive switch 都是源码破坏性变更；从已发布版本升级时必须按 SemVer major 交付并提供迁移说明，调用方需要处理 `.textReplacement`、去掉 `.imageURL`，或使用 `@unknown default`。

没有 provider，或 provider 对某个 tag 返回 `nil` / `.hidden`，都固化为透明空槽位；动态内容缺省不得阻止视频准备或播放。provider 明确返回 error 或超过 timeout 仍按错误模型处理。

公开 resolver 只表达“请求什么”和“完成什么”，不关心网络实现：

~~~swift
public protocol DynamicContentProvider: AnyObject {
    func resolve(
        tag: String,
        source: SourceMetadata,
        completion: @escaping (DynamicContent?, Error?) -> Void
    )

    func font(forTag tag: String) -> UIFont?
}
~~~

准备阶段必须等待：

1. vapc 解析完成。
2. 必需动态 tag 全部完成、失败或超时。
3. 动态图片按 source slot 的像素尺寸预缩放。
4. dynamic snapshot 固化。
5. renderer 和 pipeline ready。

每个请求必须带 session token。超时、取消、provider 释放和失败都必须调用且只能调用一次 completion。

动态缓存 key 至少包含：

- asset fingerprint。
- tag。
- slot size。
- content hash。
- display scale。
- renderer version。

头像圆角、裁剪和业务特殊处理属于 provider 或预处理阶段，不放进每帧 Metal 路径。

### 7.2 AudioCoordinator

音频是显式策略，不允许播放器内部偷偷决定是否播放：

- muted：不创建音频资源。
- embedded：播放视频内置音频，并与 session pause/resume/stop 绑定。
- external：只发出音频事件，由宿主决定播放器。
- disabled：完全忽略音频轨，但 metadata 仍可报告 containsAudio。

如果第一版只服务于静音透明特效，可以关闭音频路径；如果支持音频，必须独立验证：

- 首帧启动时机。
- pause/resume 后的时间偏差。
- 循环边界是否重复或丢失音频。
- 音频 session 中断和后台恢复。
- 多实例同时播放时的音频 session policy。

AVAudioPlayer 可以作为简单伴奏实现，但不能宣称 sample-level A/V sync。严格同步场景应使用 host-time 调度的 AVAudioEngine/AVAudioPlayerNode，并把同步误差加入验收指标。

## 8. Swift API 设计

Swift API 是唯一的 canonical API。所有公开类型都放在 VAPPlayerKit module 下。

~~~swift
import UIKit

public enum AlphaMode: Int, Sendable {
    case left
    case right
    case top
    case bottom
}

public enum AudioMode: Int, Sendable {
    case muted
    case embedded
    case external
    case disabled
}

public final class PlaybackOptions: NSObject, NSCopying {
    public var loopCount: Int
    public var contentMode: UIView.ContentMode
    public var audioMode: AudioMode
    public var clearsAfterFinish: Bool
    public var backgroundPolicy: BackgroundPolicy

    public static var defaultOptions: PlaybackOptions { get }
}

public final class AssetMetadata: NSObject {
    public let encodedVideoSize: CGSize
    public let canvasSize: CGSize
    public let alphaMode: AlphaMode
    public let frameCount: Int
    public let duration: TimeInterval
    public let containsAudio: Bool
    public let codec: String
    public var isReusableForPlayback: Bool { get }
}

@MainActor
public protocol PlayerDelegate: AnyObject {
    func playerDidStart(_ player: PlayerView)
    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata)
    func playerDidFinish(_ player: PlayerView, reason: FinishReason)
    func player(_ player: PlayerView, didFail error: Error)
}

@MainActor
public final class PlayerView: UIView {
    public weak var delegate: PlayerDelegate?
    public weak var dynamicContentProvider: DynamicContentProvider?

    public func prepare(
        url: URL,
        options: PlaybackOptions
    ) async throws -> AssetMetadata

    public func prepare(
        url: URL,
        metadata: AssetMetadata,
        options: PlaybackOptions
    ) async throws -> AssetMetadata

    public func play(
        url: URL,
        options: PlaybackOptions
    )

    public func play(
        url: URL,
        metadata: AssetMetadata,
        options: PlaybackOptions
    )

    public func pause()
    public func resume()
    public func stop()
    public func clear()
}
~~~

API 语义：

- loopCount 是总播放次数；1 表示播放一次，2 表示播放两次，0 表示无限循环。
- prepare 不自动播放。
- play 可以直接触发 prepare；如果资源已经准备好则复用 metadata。
- metadata 优化入口只接受本组件为同一标准化本地 URL 解析出的、仍与稳定文件 identity、文件大小和修改时间匹配的对象；手工构造、不同 URL 或已变更文件会失败。它在解码轨准备前后复核文件签名，并校验轨道尺寸和 codec，避免以摘要数据绕过媒体有效性检查。源文件在 prepare/play/stop 生命周期内必须保持不可变；需要抵御不受信任的同 inode 并发改写时，应由宿主先完成原子缓存发布，或未来改为同一文件描述符驱动 inspection 与 decode。
- stop 一定取消当前 session。
- clear 释放当前画面和可回收资源。
- 所有 UIKit 和控制方法要求主线程。
- 所有 delegate 回调主线程且每个终态最多一次。
- Error 使用 Swift Error；Objective-C 侧统一转换为 NSError domain 和 VPKPlaybackErrorCode。
- 不公开 PTS buffer、VT session、Metal texture、旧 VAP frame 类型或内部队列。

## 9. Objective-C 调用设计

实现全部使用 Swift，但必须把 Objective-C 支持作为一等验收目标，而不是最后补一个桥接。

### 9.1 Swift 侧约束

需要暴露给 Objective-C 的 Swift 类型必须：

- 使用 public。
- 继承 NSObject 或 UIKit 基类，或使用 @objc enum/protocol。
- 只使用 Objective-C 可表示的类型：NSString、NSURL、NSNumber、NSArray、NSDictionary、NSError、CGSize、CGRect、UIViewContentMode。
- 不把泛型、associatedtype、Swift struct、Result、async/await 直接放进 ObjC API。
- 使用 @objc(VPK...) 固定导出的 Objective-C 符号名。
- 使用 weak delegate。
- 对所有 optional delegate 方法检查 respondsToSelector。

Swift 实现示意：

~~~swift
@objc(VPKPlayerView)
@MainActor
public final class PlayerView: UIView {
    @objc public weak var objcDelegate: VPKPlayerDelegate?
    @objc public weak var objcDynamicProvider: VPKDynamicContentProvider?

    @objc(prepareWithURL:completion:)
    public func prepare(
        url: URL,
        completion: @escaping (AssetMetadata?, NSError?) -> Void
    ) {
        // Swift 内部转 async session，最终只回调一次。
    }
}
~~~

Swift 原生调用可以使用 async/await 和 typed Error；Objective-C 调用使用 completion + NSError。两套入口共享同一套 PlaybackSession，不允许维护两套播放逻辑。

### 9.2 Header-only facade

Swift Package Manager 的 target 不能在同一个 target 中混合 Swift 和 Objective-C 源文件。因此：

- VAPPlayerKit target 100% 使用 Swift。
- VAPPlayerKitObjC target 只包含公开 Objective-C header 和 module map，不包含 .m 实现。
- Swift 类通过 @objc(VPK...) 导出运行时符号。
- header facade 只声明这些符号，避免 Objective-C 使用者依赖生成 header 的具体路径。
- Swift 和 header 的 API 签名必须在发布前通过 Objective-C demo 编译验证；这属于维护者本地验收，不是 SPM 使用者的运行时要求。

示意目录：

~~~text
Sources/VAPPlayerKitObjC/include/
  VPKPlayerKitObjC.h
  VPKPlayerView.h
  VPKPlaybackOptions.h
  VPKAssetMetadata.h
  VPKPlayerDelegate.h
~~~

Objective-C header 示意：

~~~objc
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VPKPlaybackErrorCode) {
    VPKPlaybackErrorCodeInvalidAsset = 1,
    VPKPlaybackErrorCodeUnsupportedCodec,
    VPKPlaybackErrorCodeDecoderFailed,
    VPKPlaybackErrorCodeDynamicContentTimeout,
    VPKPlaybackErrorCodeMetalUnavailable,
    VPKPlaybackErrorCodeCancelled
};

@class VPKPlayerView;
@class VPKPlaybackOptions;
@class VPKAssetMetadata;

@protocol VPKPlayerDelegate <NSObject>
@optional
- (void)playerViewDidStart:(VPKPlayerView *)playerView;
- (void)playerView:(VPKPlayerView *)playerView
    didResolveMetadata:(VPKAssetMetadata *)metadata;
- (void)playerView:(VPKPlayerView *)playerView
    didFailWithError:(NSError *)error;
- (void)playerViewDidFinish:(VPKPlayerView *)playerView;
@end

@interface VPKPlaybackOptions : NSObject <NSCopying>
@property(nonatomic, assign) NSInteger loopCount;
@property(nonatomic, assign) UIViewContentMode contentMode;
@property(nonatomic, assign) BOOL muted;
@property(nonatomic, assign) BOOL clearsAfterFinish;
@end

@interface VPKAssetMetadata : NSObject
@property(nonatomic, readonly, getter=isReusableForPlayback) BOOL reusableForPlayback;
@end

@interface VPKPlayerView : UIView
@property(nonatomic, weak, nullable) id<VPKPlayerDelegate> delegate;

- (void)prepareWithURL:(NSURL *)URL
               options:(VPKPlaybackOptions *)options
            completion:(void (^)(VPKAssetMetadata * _Nullable metadata,
                                 NSError * _Nullable error))completion;
- (void)prepareWithURL:(NSURL *)URL
              metadata:(VPKAssetMetadata *)metadata
               options:(VPKPlaybackOptions *)options
            completion:(void (^)(VPKAssetMetadata * _Nullable result,
                                 NSError * _Nullable error))completion;
- (void)playWithURL:(NSURL *)URL
            options:(VPKPlaybackOptions *)options;
- (void)playWithURL:(NSURL *)URL
           metadata:(VPKAssetMetadata *)metadata
            options:(VPKPlaybackOptions *)options;
- (void)pause;
- (void)resume;
- (void)stop;
- (void)clear;
@end

NS_ASSUME_NONNULL_END
~~~

header-only facade 不是 Objective-C 核心。它只是让公开库可以被现有 Objective-C 应用稳定调用，所有真正的状态机、解码、渲染和资源释放仍然只有一份 Swift 实现。

## 10. SPM 目录和 Package.swift

建议仓库结构：

~~~text
VAPPlayerKit/
├── Package.swift
├── Sources/
│   ├── VAPPlayerKit/
│   │   ├── Public/
│   │   │   ├── PlayerView.swift
│   │   │   ├── PlaybackOptions.swift
│   │   │   ├── AssetMetadata.swift
│   │   │   ├── PlayerDelegate.swift
│   │   │   └── DynamicContentProvider.swift
│   │   ├── Internal/
│   │   │   ├── PlaybackSession.swift
│   │   │   ├── AssetInspector.swift
│   │   │   ├── VapcReader.swift
│   │   │   ├── FrameSource.swift
│   │   │   ├── VideoToolboxFrameSource.swift
│   │   │   ├── AVPlayerOutputFrameSource.swift
│   │   │   ├── FrameRingBuffer.swift
│   │   │   ├── MediaClock.swift
│   │   │   ├── FramePacer.swift
│   │   │   ├── MetalContext.swift
│   │   │   ├── MetalRenderer.swift
│   │   │   ├── DynamicResolver.swift
│   │   │   └── AudioCoordinator.swift
│   │   └── Resources/
│   │       └── Shaders/
│   └── VAPPlayerKitObjC/
│       └── include/
│           ├── VPKPlayerKitObjC.h
│           ├── VPKPlayerView.h
│           ├── VPKPlaybackOptions.h
│           └── VPKAssetMetadata.h
├── Tests/
│   ├── VAPPlayerKitTests/
│   ├── VAPPlayerKitTimingTests/
│   ├── VAPPlayerKitParserTests/
│   ├── VAPPlayerKitRendererTests/
│   ├── VAPPlayerKitObjCTests/
│   └── Fixtures/
│       └── VAP/                 提交到仓库的 VAP 样例，测试与 Demo 共用
├── Examples/
│   ├── SwiftExample/
│   └── ObjectiveCExample/
├── README.md
├── LICENSE
├── CONTRIBUTING.md
├── CHANGELOG.md
└── AGENTS.md                 工程协作与验证规则
~~~

Package.swift 示意：

~~~swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VAPPlayerKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "VAPPlayerKit",
            targets: [
                "VAPPlayerKit",
                "VAPPlayerKitObjC"
            ]
        )
    ],
    targets: [
        .target(
            name: "VAPPlayerKit",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("UIKit"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .target(
            name: "VAPPlayerKitObjC",
            path: "Sources/VAPPlayerKitObjC",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "VAPPlayerKitTests",
            dependencies: ["VAPPlayerKit"]
        )
    ]
)
~~~

header-only target、Swift symbols、资源 bundle 和 Objective-C demo 必须在真实 Xcode fixture 中验证。不能仅根据 Package.swift 文字推断一定可用。

## 11. 线程、生命周期和取消模型

线程规则：

| 工作 | 线程 |
| --- | --- |
| PlayerView、UIView、CAMetalLayer 生命周期 | MainActor |
| prepare、MP4 metadata、vapc 解析 | parser queue |
| VT sample 提交和 decoder callback | decoder serial queue |
| FrameRingBuffer | 明确的 producer/consumer 队列 |
| Metal command encoding | render queue |
| delegate / completion | MainActor |
| audio session 控制 | MainActor 或专用 audio queue |

不要把所有工作都放进 Swift actor：

- 高频 decoded frame 经过 actor 可能引入不必要的调度开销。
- VT callback 来自系统线程，必须通过明确的 session queue 收敛。
- actor 适合保护低频配置状态，不应成为每帧 GPU 数据的唯一通道。
- 对跨队列的 CVPixelBuffer 只使用有明确 retain/release 语义的 Frame 对象。
- 不要为了消除编译器警告而滥用 @unchecked Sendable；每一个使用点都要说明所有权和队列约束。

停止顺序：

1. 在 MainActor 递增 session token。
2. 停止 FramePacer，阻止新的 render tick。
3. 取消 dynamic provider、parser 和 frame source。
4. 在 decoder queue 上完成 VT teardown。
5. 等待 command buffer completion 或交给 GPU completion 回收。
6. 停止 audio。
7. 清空 frame buffer 和 dynamic snapshot。
8. 发送一次停止或失败结果，释放 session。

页面脱离 window、后台、屏幕锁定、Metal drawable 暂不可用都不能直接当作播放完成。它们进入 suspended；是否保留进度由 BackgroundPolicy 决定。

## 12. 性能和稳定性目标

### 性能目标

- 主线程不执行 MP4 parser、VT decode、图片解码、图片缩放和 pipeline 编译。
- 不用 sleep 推进播放。
- 不按显示刷新次数盲目消费视频帧。
- decoded frame 数量始终受 ring buffer 上限约束。
- shader、pipeline、CVMetalTextureCache 和 immutable dynamic texture 可以跨 session 复用。
- 每帧不创建临时 MTLBuffer、UIImage 或 JSON 对象。
- 播放落后时丢过期帧，保持 UI 响应。
- 离屏和后台 session 不继续无意义地 decode/render。
- 多实例时可按并发上限拒绝、延迟或降级低优先级 session。

### 稳定性不变量

- stop 后不再出现 start、finish 或 fail 的旧回调。
- 每个 session 只有一个终态事件。
- A 资源的任何异步结果不能污染 B 资源。
- 所有 OSStatus、文件读取、box 边界和 Metal 状态都有错误分支。
- decoder 失败不会无限重试。
- dynamic completion 有且只有一次。
- command buffer 未完成时 GPU 资源不会被释放。
- view dealloc 后没有 timer、display link、notification、audio、VT callback 或 block 继续持有 session。
- 不暴露可变内部对象，避免宿主修改 parser、frame 或 renderer 状态。

## 13. 错误模型和可观测性

错误统一为一个错误域，并区分可恢复和不可恢复：

~~~text
VPKPlaybackError.invalidURL
VPKPlaybackError.fileNotFound
VPKPlaybackError.invalidMP4
VPKPlaybackError.invalidVapc
VPKPlaybackError.unsupportedCodec
VPKPlaybackError.decoderCreationFailed
VPKPlaybackError.decoderFailed
VPKPlaybackError.dynamicContentTimeout
VPKPlaybackError.metalUnavailable
VPKPlaybackError.drawableUnavailable
VPKPlaybackError.cancelled
VPKPlaybackError.audioFailed
~~~

错误信息必须包含：

- error code。
- asset fingerprint，不包含用户隐私路径。
- session id。
- 当前阶段：inspect、prepare、decode、render、audio。
- 原始 OSStatus 或 CMTime 信息。
- 是否可以重试。

建议提供可选的 MetricsSink：

~~~swift
public protocol MetricsSink: AnyObject {
    func record(_ event: MetricsEvent)
}
~~~

Metrics 至少统计：

- prepare duration。
- first frame duration。
- decoded frame count。
- rendered frame count。
- dropped frame count。
- decoder rebuild count。
- dynamic resolve duration and timeout count。
- Metal drawable failure count。
- peak ring buffer count。
- session finish reason。

日志默认关闭或使用轻量级 os.Logger，不在公开库中输出宿主业务内容、URL query 或动态图片数据。

## 14. 测试和公开发布验收

### 14.1 单元测试

- H.264、HEVC、无 audio、带 audio。
- AlphaLeft、AlphaRight、AlphaTop、AlphaBottom。
- vapc 缺失、未知版本、非法 JSON、非法 source rect。
- box size、offset、sample table、NAL size 的边界数据。
- 恒定 FPS、可变 sample duration、非整数 FPS、duration 为零。
- loopCount 为 1、2、0。
- 快速 play/stop/play 和 A/B 资源切换。
- 旧 token 的 parser、decode、dynamic、audio、Metal callback。
- AspectFit、AspectFill、ScaleToFill。
- prepare 取消、动态超时、provider dealloc。
- command buffer 尚未完成时 stop/dispose。

### 14.2 真机测试

- iPhone H.264 VAP 和 HEVC VAP。
- 60 Hz、120 Hz。
- 24、25、30、60 FPS。
- 连续循环 30 分钟。
- 多实例同时 prepare/play。
- 页面 push/pop、view 移出和回到 window。
- 前后台切换、屏幕旋转、bounds 为零。
- 快速 dealloc。
- 静音、embedded audio、external audio。
- 失败资源和损坏资源不能崩溃。

### 14.3 Objective-C 验收

GitHub 仓库必须同时包含：

- SwiftExample。
- ObjectiveCExample。
- Objective-C 对 public header 的编译测试。
- Objective-C 调用 prepare/play/pause/resume/stop/clear 的运行测试。
- Objective-C delegate 主线程和终态唯一性测试。

### 14.4 Instruments

- Time Profiler：主线程没有 parser、decode、图片缩放和 pipeline 编译长任务。
- Core Animation：主线程卡顿时允许丢帧，但不加速、不永久停住。
- Metal System Trace：没有 pipeline 重复编译和 command buffer 泄漏。
- Allocations/Leaks：反复创建销毁 session 后内存可回收。
- Energy Log：离屏和后台不继续 decode/render。
- Thread Sanitizer：队列、token、buffer 和生命周期没有数据竞争。

### 14.5 GitHub 发布清单

- README 只描述通用 VAPPlayerKit，不出现任何宿主项目名称、业务对象或本地绝对路径。
- 提供 LICENSE、版本策略、CHANGELOG 和迁移说明。
- 测试与 Demo 使用仓库内 `Tests/Fixtures/VAP/` 的样例（清单见该目录 README）。非法 XML 伪装 mp4 作为负向 fixture。不要把这批资源加入 gitignore。
- 不提交真实用户图片、内网地址、签名文件和缓存。
- 发布前本地至少执行 Swift 编译、Swift 单元测试，并在涉及对应代码时验证 Objective-C demo 和 Metal resource。
- 使用 SemVer；破坏公开 API 时升级 major。
- 每次 release 记录支持的 iOS、codec、VAP metadata version 和已知限制。

## 15. 实施阶段

### Phase 0：纯 Swift SPM 和 ObjC fixture

- 创建 VAPPlayerKit Swift target。
- 创建 header-only VAPPlayerKitObjC target。
- 验证 Bundle.module、Metal shader、Swift symbols 和 Objective-C header facade。
- 同一仓库同时编译 SwiftExample 和 ObjectiveCExample。
- 对照验证 AVPlayerItemVideoOutput、AVAssetReaderTrackOutput 和 VideoToolbox frame source。

### Phase 1：本地视频最小闭环

- 只支持本地 file URL。
- 支持 H.264/HEVC、四种 Alpha 布局和 Metal 输出。
- 暂不加入动态内容和音频。
- 验证 encodedVideoSize、canvasSize、PTS、duration、finish。

### Phase 2：完整 session

- 加入 bounded FrameRingBuffer。
- 加入 monotonic MediaClock 和 FramePacer。
- 加入 pause/resume/stop/cancel、token 和错误模型。
- 完成快速切换、window 生命周期和 Metal teardown。

### Phase 3：动态内容和音频

- 加入 typed DynamicContentProvider。
- 加入等待组、超时、取消和预缩放缓存。
- 加入 muted/embedded/external audio policy。
- 完成多实例和音视频同步测试。

### Phase 4：公开发布

- 完成 Objective-C demo、README、license 和 fixture license。
- 运行真机和 Instruments 验收。
- 以 SemVer `1.0.0` 发布，记录已支持和未支持的 VAP 变体。
- `1.0.0` 起承诺当前公开 API 的稳定性；后续破坏性变更必须升级 major。

## 16. 最终决策

一步到位的实现方式是：

1. 核心、公开 Swift API、状态机、parser、解码、buffer、时钟、Metal、动态内容和音频全部使用 Swift。
2. 使用 VAPPlayerKit module 和 VPK Objective-C 符号前缀，与旧 VAP 命名体系区分。
3. Objective-C 支持通过 @objc 导出 + header-only facade 完成，不编写 Objective-C 播放实现。
4. 生产后端默认采用 VideoToolbox + Metal；AVPlayerItemVideoOutput 和 AVAssetReaderTrackOutput 只作为 Phase 0 的 native 对照后端，是否采用由真机 fixture 和 Instruments 决定。
5. 播放由 session media clock 驱动，不使用宿主全局 FPS dispatcher。
6. package 只负责正确播放本地 VAP 资源，网络、缓存、动态内容提供和业务播放策略由宿主注入。
7. 不迁就任何旧 API，不把旧播放器代码复制进新 package。

这不是旧 VAP 的 Swift 翻译，而是一个以 session、PTS、bounded buffer、Metal resource ownership 和可测试公开接口为核心的全新 Swift 播放组件。

## 17. 参考资料

- 本地参考实现：仓库根目录 `vap-master/`（详见 [0.1 本地参考源码：vap-master](#01-本地参考源码vap-master)）。只对照格式与行为，不复制旧 API。
- [Apple：Importing Swift into Objective-C](https://developer.apple.com/documentation/swift/importing-swift-into-objective-c)
- [Swift Package Manager：Package targets](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/target/)
- [Swift Package Manager：Creating C language targets](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/creatingclanguagetargets/)
