# Contributing

1. 打开 `VAPPlayerKit.xcworkspace`，不要只打开单个 example 工程后手动复制源码。
2. 公开 API 变更必须同时更新 Swift 类型和 `Sources/VAPPlayerKitObjC/include` 中的 header。
3. Objective-C 示例必须能编译；不要让 Swift-only 类型泄漏进 ObjC header。
4. 不要提交 `vap-master`、真实用户图片或签名文件。`Tests/Fixtures/VAP` 是测试与 Demo 共用样例，需要入库。
5. 提交前至少保证 Swift Package 能在目标 iOS SDK 上编译和测试；只有修改 Example 时才需要额外验证对应的示例工程。
