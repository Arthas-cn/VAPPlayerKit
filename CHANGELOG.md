# Changelog

## Unreleased

### Added

- 安全的 ISO BMFF 顶层 box 与 `vapc` v1/v2 typed metadata 解析。
- H.264 / HEVC `AVAssetReader` 解码、PTS 时钟、bounded ring buffer 与丢帧策略。
- Metal NV12、packed Alpha 和动态附件合成，支持三种 UIView content mode。
- 可取消的播放 session、循环、前后台策略、指标回调和唯一终态。
- Swift / Objective-C 动态内容 provider 与内嵌音频策略。
- Swift Package Manager 产品、Objective-C facade、双语言示例和提交到仓库的回归样例。
- Parser、timing、buffer、renderer、Objective-C facade 和真实媒体解码测试。
- 自动扫描 Bundle 素材的 Swift 示例目录、完整 Playback Lab、诊断报告和全素材真机批测。
- SwiftExample 真机 UI 回归，覆盖播放生命周期、缩放矩阵以及合法/负向 fixture。

### Fixed

- 串行化 `AVAssetReader` 取消与 sample 读取，避免快速切换素材时并发销毁 reader。
- 在 Metal in-flight 资源释放后再销毁 texture cache；清屏由 `PlayerView` 同步隐藏 layer，首个成功渲染帧再恢复显示。

### Known limitations

- 仅处理本地文件；动态 `imageURL` 下载和 external audio 同步由宿主实现。
- 无 `vapc` 的旧格式只按左 Alpha / 右 RGB 的等宽布局兼容。
- 正式发布前仍需完成架构文档列出的真机长循环和 Instruments 验收。
