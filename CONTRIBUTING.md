# Contributing

1. 打开 `VAPPlayerKit.xcworkspace`，不要只打开单个 example 工程后手动复制源码。
2. 公开 API 变更必须同时更新 Swift 类型和 `Sources/VAPPlayerKitObjC/include` 中的 header。
3. Objective-C 示例必须能编译；不要让 Swift-only 类型泄漏进 ObjC header。
4. 不要提交 `vap-master`、业务资源、用户图片或签名文件。
5. 提交前至少保证 Swift Package 与两个 Example App 能在 iOS Simulator 上编译。
