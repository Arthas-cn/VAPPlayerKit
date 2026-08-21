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
.package(url: "https://github.com/example/VAPPlayerKit.git", from: "0.1.0")
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

## Objective-C

```objc
@import VAPPlayerKitObjC;

VPKPlayerView *playerView = [[VPKPlayerView alloc] initWithFrame:CGRectZero];
VPKPlaybackOptions *options = VPKPlaybackOptions.defaultOptions;
[playerView playWithURL:fileURL options:options];
```

打开 `VAPPlayerKit.xcworkspace` 可同时编译 Swift Package、SwiftExample 和 ObjectiveCExample。

示例 App 会把 `Tests/Fixtures/VAP` 打进 Bundle。点 **Play Fixture** 即播放默认样例：

`e9b6b7196780ea5f64b9f05034571f12a96787278ed678c83141c7913af7318a.mp4`

完整清单见 [`Tests/Fixtures/README.md`](Tests/Fixtures/README.md)。这些文件需要随仓库提交，供单元测试和 Demo 共用。

## 工程结构

```
Sources/VAPPlayerKit/          Swift 实现与公开 API
Sources/VAPPlayerKitObjC/      Objective-C header-only facade
Tests/                         单元测试
Tests/Fixtures/VAP/            提交到仓库的 VAP 样例（测试与 Demo 共用）
Examples/SwiftExample          Swift 示例 App
Examples/ObjectiveCExample     Objective-C 示例 App
```

当前处于 Phase 0：SPM 工程、公开 API、Metal 资源和 ObjC facade 已就绪。解码、vapc 解析和完整播放闭环将在后续阶段接入。

## License

Apache License 2.0
