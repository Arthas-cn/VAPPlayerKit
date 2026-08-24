# VAPPlayerKit

独立的 iOS VAP 播放组件。核心实现全部使用 Swift，通过 SPM 分发，并提供稳定的 Objective-C 调用入口。

本组件只负责本地 VAP 资源的解析、硬件解码、透明通道合成和播放生命周期。网络下载、业务缓存、图片库和播放队列不属于本仓库。

## 要求

- iOS 15+
- Swift 5.9+
- Xcode 15+

## 安装

在 Xcode 中添加 Swift Package，或在 `Package.swift` 中声明：

```swift
.package(url: "https://github.com/Arthas-cn/VAPPlayerKit.git", from: "0.1.0")
```

```swift
.product(name: "VAPPlayerKit", package: "VAPPlayerKit")
```

## Swift

```swift
import VAPPlayerKit

let player = PlayerView()
let options = PlaybackOptions.defaultOptions
options.loopCount = 1
player.play(url: fileURL, options: options)
```

需要先读取画布、时长或动态槽位时，可使用异步准备接口：

```swift
let metadata = try await player.prepare(url: fileURL, options: options)
print(metadata.canvasSize, metadata.dynamicSources)
if metadata.isReusableForPlayback {
    // 同一个本地文件未发生变化时，跳过重复的 MP4/vapc inspection。
    player.play(url: fileURL, metadata: metadata, options: options)
}
```

动态文字通常只需要按 tag 返回字符串：

```swift
func resolve(
    tag: String,
    source: SourceMetadata,
    completion: @escaping (DynamicContent?, Error?) -> Void
) {
    completion(.textReplacement(values[tag] ?? ""), nil)
}
```

`.textReplacement` 会使用 vapc source 声明的颜色、粗体标记和槽位尺寸，并自动计算能放入槽位的系统字号。vapc 本身不包含字体文件或精确 point size，因此无法还原原字体族和精确字号；需要完全指定字体时可使用 `.text(_:attributes:)`，或由 provider 按 tag 返回字体。未设置 provider，或 provider 对某个 tag 返回 `nil` / `.hidden` 时，该动态槽位按透明空内容处理，视频仍会正常准备和播放。

如果宿主需要按 tag 指定字体，可在 `DynamicContentProvider` 中实现 `font(forTag:)` 并返回 `UIFont`；返回 `nil` 时继续使用自动字号估算。自动估算最多缩小三次，仍放不下时由 UIKit 的 `byTruncatingTail` 模式截断。

兼容性说明：`.textReplacement` 是 public enum 的新 case，已有调用方若对 `DynamicContent` 使用 exhaustive `switch`，升级后必须补充该分支（或使用 `@unknown default`）。这是源码破坏性变更，已有正式版本应按 SemVer major 发布，并在迁移说明中列出该 switch 修改。

Metadata 复用会在解码轨准备前后校验稳定文件 identity、文件大小和修改时间；调用方仍应把本地资源视为不可变，在 prepare/play/stop 生命周期内不要替换或改写该路径。需要对不受信任的并发写入提供强一致性时，应先由宿主完成原子下载与缓存发布，再交给播放器。

## Objective-C

```objc
@import VAPPlayerKitObjC;

VPKPlayerView *playerView = [[VPKPlayerView alloc] initWithFrame:CGRectZero];
VPKPlaybackOptions *options = VPKPlaybackOptions.defaultOptions;
[playerView playWithURL:fileURL options:options];
```

Objective-C 也可以将同一 URL 的 `VPKAssetMetadata` 传给
`playWithURL:metadata:options:`；仅 `reusableForPlayback == YES` 的 metadata 可用于该优化入口。

`VPKPlayerViewDelegate` 提供开始、metadata、完成和失败回调；动态内容可通过
`VPKDynamicContentProvider` 注入。文字槽位在 completion 中返回 `replacementText`，
组件会使用与 Swift `.textReplacement` 相同的自动字号估算；图片槽位返回 `UIImage`。

Objective-C provider 也可实现可选的 `fontForTag:`，为文字 tag 指定 `UIFont`；未实现或返回 `nil` 时使用同样的自动估算和 UIKit 尾部截断策略。

## 支持范围

- 仅接受本地 `file://` MP4；网络下载、缓存和播放队列由宿主负责。
- H.264 / HEVC 视频轨，通过系统 `AVAssetReader` 输出 NV12 像素缓冲。
- `vapc` metadata v1 / v2，支持 AlphaLeft、AlphaRight、AlphaTop、AlphaBottom。
- 无 `vapc` 的旧格式按“左侧 Alpha、右侧 RGB、等宽画布”兼容。
- Metal 透明合成、PTS 时钟、固定容量帧缓冲、过期帧丢弃和多 session token 隔离。
- Swift typed 动态文字/图片，以及 Objective-C `UIImage` / 文字替换注入。
- 静音、MP4 内嵌音频和宿主管理外部音频三种策略。

动态 `imageURL` 只用于表达资源地址，组件不会发起网络请求；provider 应先下载并返回
`.image`。`.external` 音频模式表示视频组件不创建音频播放器，音频同步由宿主负责。

打开 `VAPPlayerKit.xcworkspace` 可同时编译 Swift Package、SwiftExample 和 ObjectiveCExample。

Swift 示例 App 会把 `Tests/Fixtures/VAP` 打进 Bundle，并在启动时自动扫描全部 MP4：

- 首页按文件展示素材清单，每行内嵌播放器并在可见时自动循环预览；负向 fixture 只显示错误标识。
- 点击素材进入 Playback Lab 后自动播放，也可继续验证 prepare / play / pause / resume / stop / clear、三种缩放、循环、音频、后台策略、动态内容及实时指标。
- Playback Lab 可运行单素材自动冒烟测试并导出诊断报告；首页工具栏可运行全部 Bundle 素材的真机批测，每个合法素材至少播放 `min(1 秒, 实际时长)`。

完整素材清单见 [`Tests/Fixtures/README.md`](Tests/Fixtures/README.md)。这些文件需要随仓库提交，供单元测试和 Demo 共用。

## 工程结构

```
Sources/VAPPlayerKit/          Swift 实现与公开 API
Sources/VAPPlayerKitObjC/      Objective-C header-only facade
Tests/                         单元测试
Tests/Fixtures/VAP/            提交到仓库的 VAP 样例（测试与 Demo 共用）
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

CI 同时编译 Swift 与 Objective-C 示例。发布前仍需按
[`VAPPlayerKit_SPM_ARCHITECTURE.md`](VAPPlayerKit_SPM_ARCHITECTURE.md) 执行真机、长循环和 Instruments 验收。
当前实现的性能边界、自动化证据、已知缺陷和优化优先级见
[`VAPPlayerKit_PERFORMANCE_EVALUATION.md`](VAPPlayerKit_PERFORMANCE_EVALUATION.md)。

Swift 示例还包含 `SwiftExampleUITests`，连接已签名真机后可运行：

```sh
xcodebuild \
  -workspace VAPPlayerKit.xcworkspace \
  -scheme SwiftExample \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  -allowProvisioningUpdates \
  test
```

该套件会核对 Bundle 扫描数量、播放生命周期和指标，执行 Fit / Fill / Stretch 自动矩阵，并逐个 prepare、实际播放全部合法素材，同时确认负向素材被拒绝。

## License

Apache License 2.0
