# Contributing

1. 使用 Swift 6.4、Swift 6 language mode、iOS 26。打开 `VAPPlayerKit.xcworkspace`，示例仅保留 SwiftExample。
2. v2 只维护 Swift API；公开值模型、SwiftUI 入口和 UIKit 内核的行为同时更新文档与测试，不增加 Objective-C 兼容层。
3. 本地视频输入保持不可变，直到 `clearAndWait()` 真正完成。下载、ZIP、图片缓存和跨播放器队列由宿主负责。
4. 手写声明和测试场景使用中文 `///`，关键状态与取消分支使用 `//` 说明约束；按职责拆文件，不用删注释压缩体量。
5. fixture 取自 `Tests/Fixtures/VAP`，随仓库提交。不要提交真实用户图片、签名文件或凭据。
6. 纯 SPM 测试在 iOS 模拟器运行。真机执行全部单元测试使用 SwiftExample 的 SwiftExampleTests 宿主；该目标复用同一测试源码与 App 内 fixture，不假设设备能读取主机 #filePath。
7. 构建与测试选择实际可用设备，不硬编码某款 iPhone。示例测试命令中的 `<DEVICE_UDID>` 需替换为当前连接设备：

```sh
xcodebuild -project Examples/SwiftExample/SwiftExample.xcodeproj \
  -scheme SwiftExample -destination 'platform=iOS,id=<DEVICE_UDID>' \
  -only-testing:SwiftExampleTests test
```

完成播放器/素材改动后，继续运行 `SwiftExampleUITests/testEveryBundledFixtureOnDevice` 与 `testCatalogCountMatchesRowsAndPlaybackLifecycle`，确认真实解码、首帧呈现和退出清理。签名由维护者自己的 Team 配置，不提交本地证书或描述文件。发布记录要区分编译、逻辑测试、GPU 像素断言和设备 UI 回归，不把其中一项代替其余项。
