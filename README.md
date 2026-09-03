# VAPPlayerKit

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/iOS-15%2B-lightgrey.svg)](#要求)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](#要求)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](#安装)

**简体中文** | [English](README_en.md)

独立的 iOS VAP（Video Animation Player）播放组件。核心全部用 Swift 实现，通过 Swift Package Manager 分发，并提供稳定的 Objective-C 调用入口。

当前稳定版本：`1.0.4`

它播放的是与 [Tencent VAP](https://github.com/Tencent/vap) 相同的本地 MP4 素材：硬件解码、透明通道合成、vapc 融合动画（用户名、头像等动态槽位）。下载、业务缓存和播放队列不属于本仓库，由宿主自己完成。

```swift
import VAPPlayerKit

let player = PlayerView()
let options = PlaybackOptions.defaultOptions
options.loopCount = 1
player.play(url: fileURL, options: options)
```

## 为什么不用官方 QGVAPlayer

[Tencent VAP](https://github.com/Tencent/vap)（iOS 侧即 `QGVAPlayer`）定义了 VAP 格式与配套工具，素材仍然用它的 [VapTool](https://github.com/Tencent/vap/tree/master/tool) 制作。官方仓库已经**停止维护**，并引导用户转向腾讯云商业方案。

VAPPlayerKit **不是** QGVAPlayer 的 Swift 翻译，也不是对旧 API 的封装。它在对照最新官方源码的格式与行为后，用 Swift 重写了解析、解码、时钟、Metal 合成和生命周期，专门作为可独立发布的 iOS 播放内核。

| | Tencent VAP / QGVAPlayer | VAPPlayerKit |
| --- | --- | --- |
| 维护状态 | 官方已停止维护 | 独立开源，面向现代 iOS |
| 实现语言 | Objective-C | Swift，Objective-C 通过 `VPK*` facade 调用 |
| 公开 API | `UIView+VAP` category，任意 view 都能播 | 独立 `PlayerView` / `VPKPlayerView`，不污染 UIView |
| 分发 | 拷贝源码、子工程、CocoaPods | Swift Package Manager；Metal shader 随 package 资源编译 |
| 最低系统 | iOS 8 | iOS 15（只走 Metal，不再保留 OpenGL） |
| 解码 / 合成 | VideoToolbox + Metal / OpenGL | 系统 `AVAssetReader` 硬解 NV12 + Metal 透明合成 |
| 生命周期 | 全局解码线程池、全局 FPS 调度 | 每次播放独立 session + token，快速切资源不会串回调 |
| 回调线程 | 文档标明多数回调在**子线程** | 全部主线程；每个 session 终态最多一次 |
| 循环语义 | `repeatCount` 表示**额外重复次数**（`0` 播 1 次） | `loopCount` 表示**总次数**（`1` 播 1 次，`0` 无限循环） |
| 音频 | `setMute:` | `muted` / `embedded` / `external` / `disabled` |
| 动态内容 | 字符串 tag + 图片 URL 回调 | 类型化 `DynamicContent`；文字可自动字号、截断或跑马灯 |
| 动图槽位 | 宿主自行处理 | 可选：宿主链接 SDWebImage 后播放 GIF / 动画 WebP，组件本身不依赖该库 |
| 准备阶段 | 直接播放 | `prepare` / `play` 可拆分；进程内 metadata 缓存 |
| 错误模型 | 泛化 `NSError` | 统一 `VPKPlaybackError` 域与阶段信息 |
| 可观测性 | 自定义 logger | 可选 `MetricsSink`（prepare、首帧、丢帧等） |
| 平台 | Android / iOS / Web | **仅 iOS 播放器**；素材工具仍用官方 VapTool |

相对 QGVAPlayer，本组件刻意不做的事情：

- 不兼容 `playHWDMP4:`、`repeatCount`、`QG*` / `HWD*` 符号。
- 不内置点击热区、长按手势；宿主用 UIKit 加在 `PlayerView` 上即可。
- 不覆盖 Android / Web；跨端请继续使用官方实现或各自平台方案。
- 不内置 HTTP 下载、ZIP 解压、礼物队列或图片库。

CocoaPods 集成官方库时，需要手动把 Metal shader 加进工程，否则着色器进不了 `default.metallib`。VAPPlayerKit 把 shader 作为 SPM 资源处理，接入时没有这一步。

## 功能

- 本地 `file://` MP4：H.264 / HEVC，系统硬解输出 NV12。
- `vapc` metadata v1 / v2；Alpha 布局支持 Left / Right / Top / Bottom。
- 无 `vapc` 的旧 packed 素材自动探测 Alpha/RGB 等尺寸区域，支持左、右、上、下四种布局，无需再调 `enableOldVersion`。
- Metal 合成：YUV → RGB、Alpha 解包、融合动画 mask overlay。
- PTS 媒体时钟、固定容量帧缓冲、落后丢帧；不按屏幕刷新率盲目推进视频。
- 播放控制：`prepare`、`play`、`pause`、`resume`、`stop`、`clear`。
- 缩放：`scaleAspectFit` / `scaleAspectFill` / `scaleToFill`，按 vapc **逻辑画布**而不是编码分辨率。
- 后台 / 离屏：挂起并保留进度，或直接停止。
- 动态图片、动态文字；文字可自动适配槽位，溢出截断或跑马灯。
- 静音、MP4 内嵌音轨、宿主外部音频三种可用策略。
- Swift 与 Objective-C 双 API；事件、错误、options 语义对齐。
- 进程内 `AssetMetadataCache`，相同未变化的本地文件跳过重复解析。

## 要求

- iOS 15+
- Swift 5.9+
- Xcode 15+

## 安装

在 Xcode 中：File → Add Package Dependencies，填入：

```text
https://github.com/Arthas-cn/VAPPlayerKit.git
```

或在 `Package.swift` 中声明：

```swift
.package(url: "https://github.com/Arthas-cn/VAPPlayerKit.git", from: "1.0.4")
```

```swift
.product(name: "VAPPlayerKit", package: "VAPPlayerKit")
```

Swift 工程 `import VAPPlayerKit`。Objective-C 工程 `@import VAPPlayerKitObjC;`（或 `#import <VAPPlayerKitObjC/VPKPlayerKitObjC.h>`）。产品会同时带上 Swift 实现与 ObjC header facade。

## 快速开始

### Swift

```swift
import VAPPlayerKit

let player = PlayerView()
player.delegate = self
player.dynamicContentProvider = self

let options = PlaybackOptions.defaultOptions
// 默认 automatic：播放器内部识别普通 MP4 / VAP，上层只传 URL
options.assetMode = .automatic
options.loopCount = 1          // 播一次；2 播两次；0 无限循环
options.audioMode = .embedded  // 默认即内嵌音轨；静音用 .muted
player.play(url: fileURL, options: options)
```

`PlaybackOptions` 必须在 `play` / `prepare` 前设置。session 会持有一份拷贝，播放中途改原对象不会影响当前播放。

需要先拿画布尺寸、时长或动态槽位时，用异步准备接口：

```swift
let metadata = try await player.prepare(url: fileURL, options: options)
print(metadata.canvasSize, metadata.duration, metadata.dynamicSources)

if metadata.isReusableForPlayback {
    // 同一个本地文件未变化时，跳过重复的 MP4 / vapc inspection
    player.play(url: fileURL, metadata: metadata, options: options)
}
```

常用回调：

```swift
func playerDidStart(_ player: PlayerView) {}
func player(_ player: PlayerView, didUpdate metadata: AssetMetadata) {}
func playerDidFinish(_ player: PlayerView, reason: FinishReason) {}
func player(_ player: PlayerView, didFail error: Error) {}
```

全部在主线程。`finish` 与 `fail` 互斥，每个 session 只会走其中一个。

### Objective-C

```objc
@import VAPPlayerKitObjC;

VPKPlayerView *playerView = [[VPKPlayerView alloc] initWithFrame:CGRectZero];
playerView.delegate = self;
playerView.dynamicContentProvider = self;

VPKPlaybackOptions *options = VPKPlaybackOptions.defaultOptions;
options.loopCount = 1;
[playerView playWithURL:fileURL options:options];
```

也可以把同一 URL 的 `VPKAssetMetadata` 传给 `playWithURL:metadata:options:`。仅 `reusableForPlayback == YES` 的对象可用于该优化入口。

`VPKPlayerViewDelegate` 提供开始、metadata、完成和失败回调，同样都在主线程。

## 播放配置

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `assetMode` | `.automatic` | 自动识别普通 MP4 / VAP；也可强制 `.vap` 或 `.ordinaryVideo` |
| `loopCount` | `1` | 总播放次数。`0` 无限循环。负值会被钳制为 `1`。**不要把旧 `repeatCount` 原样传入。** |
| `contentMode` | `.scaleAspectFit` | 按 `canvasSize` 缩放 |
| `audioMode` | `.embedded` | `.muted` / `.embedded` / `.external` / `.disabled` |
| `clearsAfterFinish` | `true` | 结束后是否隐藏当前画面 |
| `backgroundPolicy` | `.suspend` | 进后台或离开 window 时挂起或停止 |
| `dynamicImagePlaybackMode` | `.animated` | 槽位动图；探测不到 SDWebImage 时始终静图 |
| `dynamicTextOverflowMode` | `.truncate` | `.truncate` 尾部截断，`.marquee` 跑马灯 |
| `marqueeSpeed` | `80` | 跑马灯速度，pt/s |
| `marqueeStartDelay` | `0.6` | 每个滚动周期开头的停顿，秒 |

`.external` 表示组件不创建音频播放器，音画同步由宿主负责。`.disabled` 忽略音轨，但 metadata 仍可能报告 `containsAudio`。

`assetMode` 默认为 `.automatic`：包含 `vapc` 的文件按 VAP 处理；没有 `vapc` 的文件会严格按媒体时长的 20%、50%、70% 依次抽取一帧检查旧 packed VAP 特征，命中后立即停止并自动识别左、右、上、下 Alpha 布局，三帧都无法确认时按普通 MP4 的完整画面处理。普通视频的 metadata 使用完整编码尺寸，`alphaMode` 为 `.none`、`isVAP` 为 `false`。

没有 `vapc` 且三点特征与旧 packed VAP 冲突的极少数文件，可以显式设置 `.ordinaryVideo`；已知的旧无 `vapc` packed VAP 可以显式设置 `.vap`。组件仍只接受本地 `file://` URL，远程 URL 由宿主下载并落盘后再传入。

## 动态融合内容

vapc 里的 source 会在 `AssetMetadata.dynamicSources` 中给出 tag、槽位尺寸和类型（图片 / 文字）。组件**不会**根据 tag 字符串猜测类型，也不会发网络请求。

### Swift

```swift
func resolve(
    tag: String,
    source: SourceMetadata,
    completion: @escaping (DynamicContent?, Error?) -> Void
) {
    switch source.kind {
    case .text:
        completion(.textReplacement(values[tag] ?? ""), nil)
    case .image:
        completion(.image(images[tag]!), nil)
    }
}
```

`completion` 必须且只能调用一次。

| `DynamicContent` | 用途 |
| --- | --- |
| `.textReplacement(String)` | 只换文案。使用 vapc 声明的颜色、粗体和槽位尺寸，自动估算能放入槽位的系统字号 |
| `.text(_:attributes:)` | 完全指定字体和颜色 |
| `.image(UIImage)` | 已解码图片，组件按槽位预缩放。图片请先由宿主下载后再返回此 case |
| `.hidden` | 本轮不渲染该槽位 |

vapc 不含字体文件或精确 point size，因此 `.textReplacement` 无法还原原字体族和精确字号。需要按 tag 指定字体时，实现 `font(forTag:)` 返回 `UIFont`；返回 `nil` 则继续自动估算。

自动估算最多缩小三次，仍放不下时默认 `byTruncatingTail`。设为 `.marquee` 后改为从右向左滚动；文字能放下时始终静态居中。跑马灯跟随 pause / suspend，与视频 `loopCount` 无关。循环间隙固定 25 pt。超长文字超出纹理预算时回退截断。

未设置 provider，或对某个 tag 返回 `nil` / `.hidden` 时，该槽位按透明空内容处理，视频仍会正常准备和播放。

图片槽位始终传 `UIImage`。宿主若自行链接 [SDWebImage](https://github.com/SDWebImage/SDWebImage)，并传入 `SDAnimatedImage`（`animatedImageFrameCount > 1`），组件会按 `dynamicImagePlaybackMode` 播放动图；动画 WebP 还需注册 `SDWebImageWebPCoder`。可用 `PlaybackOptions.canPlayAnimatedDynamicImages` 查询运行时是否探测到 SDWebImage。动图循环跟随当前 VAP session，结束或停止时停掉。

兼容性：`.textReplacement` 是 public enum 的新 case；`.imageURL` 已移除（组件不下载 URL，请先下载再返回 `.image`）。已有调用方若对 `DynamicContent` 做 exhaustive `switch`，升级后必须补 `.textReplacement` 并去掉 `.imageURL`（或使用 `@unknown default`）。这是源码破坏性变更，应按 SemVer major 发布。

### Objective-C

```objc
- (void)resolveTag:(NSString *)tag
            source:(VPKSourceMetadata *)source
        completion:(void (^)(UIImage *, NSString *, NSError *))completion {
    if (source.kind == VPKDynamicSourceKindText) {
        completion(nil, self.values[tag] ?: @"", nil);
        return;
    }
    completion(self.images[tag], nil, nil);
}
```

文字槽位返回 `replacementText`，行为与 Swift `.textReplacement` 相同。图片槽位返回 `UIImage`。可选实现 `fontForTag:`。

## Metadata 缓存

组件会自动使用全局 `AssetMetadataCache` 复用相同本地 URL 的解析结果，默认最多 20 条。缓存只存在于当前进程，遇到文件 identity、大小或修改时间变化时会丢弃旧值并重新解析。

```swift
AssetMetadataCache.shared.countLimit = 32
AssetMetadataCache.shared.remove(url: fileURL)
AssetMetadataCache.shared.removeAll()
```

Objective-C：`VPKAssetMetadataCache.sharedCache`。容量设为 `0` 会禁用并清空缓存。

Metadata 复用会在解码轨准备前后校验稳定文件 identity、大小和修改时间。调用方仍应把本地资源视为不可变，在 prepare / play / stop 期间不要替换或改写该路径。不受信任的并发写入应先由宿主完成原子下载与缓存发布，再交给播放器。

## 可观测性

可选实现 `MetricsSink`，接入自己的 APM。组件默认不打印业务 URL 或图片数据。

```swift
player.metricsSink = self

func record(_ event: MetricsEvent) {
    // prepareDuration / firstFrameDuration / droppedFrame / sessionFinished ...
}
```

Swift 错误为 `PlaybackError`，Objective-C 为 `NSError`，域均为 `com.vapplayerkit.playback`。

## 支持范围

**接受**

- 本地 `file://` MP4
- H.264 / HEVC
- vapc v1 / v2 与四种 Alpha 布局
- 无 vapc 的旧 packed 布局（自动识别左 / 右 / 上 / 下 Alpha）
- 融合动画中的图片、文字槽位及视频内 mask

**不负责**

- 网络 URL、HTTP 下载、重试、鉴权
- ZIP 解压、磁盘业务缓存、播放队列
- 绑定某个图片库（SDWebImage 仅为运行时可选探测）
- 礼物、房间、优先级调度等业务概念
- Android、Web、素材制作（请用 [VapTool](https://github.com/Tencent/vap/tree/master/tool)）

## 示例

打开 `VAPPlayerKit.xcworkspace`，可同时编译 Swift Package、SwiftExample 和 ObjectiveCExample。

Swift 示例会把 `Tests/Fixtures/VAP` 打进 Bundle，启动时扫描全部 MP4：

- 首页按文件列出素材，可见时自动循环预览（列表预览强制静音）；负向 fixture 只显示错误标识。
- 点击进入 Playback Lab 后自动播放，默认为无限循环、内嵌音频、槽位动图和文字跑马灯。可验证 prepare / play / pause / resume / stop / clear、三种缩放、循环、音频、后台策略、槽位静图/动图、文字截断/跑马灯，以及实时指标。
- Swift Demo 引入 SDWebImage 与 SDWebImageWebPCoder，可播 GIF / 动画 WebP；Objective-C Demo 不引入这两个库，同样资源只显示静图。
- Playback Lab 可跑单素材自动冒烟并导出诊断报告；首页可跑全部 Bundle 素材的真机批测。

完整素材清单见 [`Tests/Fixtures/README.md`](Tests/Fixtures/README.md)。这些文件随仓库提交，供单元测试和 Demo 共用。

## 工程结构

```text
Sources/VAPPlayerKit/          Swift 实现与公开 API
Sources/VAPPlayerKitObjC/      Objective-C header-only facade
Tests/                         单元测试
Tests/Fixtures/VAP/            提交到仓库的 VAP 样例
Examples/SwiftExample          Swift 示例 App
Examples/ObjectiveCExample     Objective-C 示例 App
```

## 验证

```sh
xcodebuild \
  -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme VAPPlayerKit \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

发布门槛是 Swift Package 能够在目标 iOS SDK 上编译和测试；Swift / Objective-C 示例、真机、长循环和 Instruments 属于维护者的可选验证。发布前清单见 [`VAPPlayerKit_SPM_ARCHITECTURE.md`](VAPPlayerKit_SPM_ARCHITECTURE.md)；性能边界与已知限制见 [`VAPPlayerKit_PERFORMANCE_EVALUATION.md`](VAPPlayerKit_PERFORMANCE_EVALUATION.md)。

在 iPhone 12 真机对比本地 `vap-master`：按四项核心指标综合计算，从准备播放到首帧进入 GPU 的核心链路平均耗时降低约 30%；冷启动提升约 17%，热启动提升约 43%，其中热启动准备阶段提升约 66%～76%。普通素材和图文替换素材均有提升。

连接已签名真机后可跑 `SwiftExampleUITests`：

```sh
xcodebuild \
  -workspace VAPPlayerKit.xcworkspace \
  -scheme SwiftExample \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  -allowProvisioningUpdates \
  test
```

该套件会核对 Bundle 扫描数量、播放生命周期和指标，执行 Fit / Fill / Stretch 矩阵，并逐个 prepare、实际播放全部合法素材，同时确认负向素材被拒绝。

## 从 QGVAPlayer 迁移

1. 用 `PlayerView` 替换任意 `UIView` + `playHWDMP4:`。
2. `repeatCount` 换成 `loopCount`：旧值 `0` 对应新值 `1`，旧值 `n` 对应新值 `n + 1`，无限循环用 `0`。
3. `setMute:` 换成 `options.audioMode = .muted` 或 `.embedded`。
4. `contentForVapTag:` / `loadVapImageWithURL:` 换成 `DynamicContentProvider`；图片请先下载再返回 `.image`。
5. 把原先在子线程处理的 UI 逻辑移回主线程——新回调已经在主线程。
6. 手势、下载器、播放队列留在宿主，不要期望播放器代劳。

## License

[Apache License 2.0](LICENSE)

VAP 格式与官方播放器 [Tencent VAP](https://github.com/Tencent/vap) 使用 MIT License。本仓库是独立实现，不包含、不重新分发官方 iOS 源码。
