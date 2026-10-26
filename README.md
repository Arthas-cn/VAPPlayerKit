# VAPPlayerKit v2

[English](README_en.md) · [架构与生命周期](docs/VAPPlayerKit_SPM_ARCHITECTURE.md) · [变更记录](CHANGELOG.md)

面向 **Swift 6.4、iOS 26** 的本地视频特效播放包。提供 SwiftUI 的 `VAPPlayerView` 和 UIKit 的 `PlayerView`，使用 AVFoundation 解码、Metal 合成透明画面，支持 VAP 动态图片与文字槽位。

v2 是全新的 Swift API：只发布一个 `VAPPlayerKit` library product，没有 Objective-C facade、对象复制配置或旧 API 兼容层。当前文档对应 v2 工作树，发布版本与构建、测试、真机结果**待维护者验证和登记**；不要用历史 1.x tag 验证本文接口。

## 接入

在 Xcode 的 Add Package Dependencies 中使用远程仓库：

```text
https://github.com/Arthas-cn/VAPPlayerKit.git
```

选择已经发布并核验的 v2 revision/tag，再给实际使用它的 App target 添加 product：

```swift
.product(name: "VAPPlayerKit", package: "VAPPlayerKit")
```

代码使用 `import VAPPlayerKit`。要求 Swift tools 6.4、Swift 6 language mode、iOS 26；Metal shader 随 package 资源处理。正式依赖使用远程 URL，本地路径适合联调，不是发布配置。

## 资源职责

| 本包负责 | 宿主负责 |
| --- | --- |
| 本地 MP4/VAP 检查、解码、帧缓冲与 Metal 渲染 | HTTP 下载、ZIP/config.json、数据库和磁盘缓存 |
| 明确的 VAP、普通视频、显式透明布局 | 根据业务协议选择播放模式，不让内核猜业务类型 |
| 内嵌音轨、循环、暂停、恢复、停止和排空 | 全局 AVAudioSession、房间音频和外置音轨同步 |
| 已准备图片/文字的动态槽位合成 | 图片下载、SDWebImage 共享缓存、关联文件准备屏障 |
| 每个播放器自己的资源生命周期 | 跨播放器加载上限、驻留上限和业务播放队列 |

输入仅接受现存的本地普通文件。宿主须让文件在检查、准备、播放与异步清理期间保持可读且不可变；组件不取得文件所有权，也不删除源文件。

## 选择播放模式

`PlaybackOptions` 是 `Sendable, Equatable` 的 struct，初始化后可以修改自己的副本；每个 session 固定接纳时的值。

| `assetMode` | 行为 |
| --- | --- |
| `.vap`（默认） | 解析 VAP；无 vapc 的旧素材使用左侧 Alpha 布局 |
| `.ordinaryVideo` | 显示完整编码画面，不读取 vapc、不检测透明布局 |
| `.packedAlpha(layout)` | 完全采用给定颜色/Alpha 矩形，不读取 vapc、不启发式检测 |
| `.automatic` | 先解析 vapc；无 vapc 时探测旧拼接特征，无法确认则按普通视频 |

`automatic` 是显式可选策略。已知资源类型的统一播放器应传确定模式。文件名扩展名不替代本包的模式参数；ZIP、协议 type 与后缀路由由上层完成。

```swift
let options = PlaybackOptions(
    assetMode: .vap,
    loopCount: 1,
    contentMode: .scaleAspectFit,
    audioMode: .muted,
    automaticallyResumesAfterSuspension: false,
    dynamicImagePlaybackMode: .still
)
```

`loopCount` 为总次数：1 播一次，0 无限，负值失败。缩放支持 `.scaleAspectFit`、`.scaleAspectFill`、`.scaleToFill`，以逻辑画布计算。

## SwiftUI

在 MainActor 的 SwiftUI 视图中创建并保存稳定的请求身份，再把它传给播放外壳。下面的 `fileURL` 由宿主提前提供：

```swift
let request = VAPPlaybackRequest(
    id: UUID(),
    url: fileURL,
    options: PlaybackOptions(assetMode: .vap, audioMode: .muted)
)

VAPPlayerView(
    resource: request,
    intent: .playing,
    controlRevision: 0,
    isVisible: true,
    isMuted: false
) { event in
    // 先核对 event.requestID，再更新所属请求的业务状态。
}
.frame(width: 240, height: 240)
```

不要在每次 `body` 重算时生成新 UUID。请求的 URL/options 不变时保持同一 ID；换资源、改配置或重播时换 ID。同 ID 修改请求会失败；已经终态的 ID 不会复活。

- 暂停：`intent = .paused`；显式播放、暂停、恢复命令同时递增 `controlRevision`。
- 系统暂停结束后：传 `.playing` 并递增 `controlRevision`。仅恢复前台不会解除系统暂停。
- `intent = .stopped`、`isVisible = false` 或 `resource = nil` 都结束当前请求。再次播放使用新 ID。
- `isMuted` 可原位改变，不需要新请求。
- 宿主传入真实可见性；列表 `onAppear` 不等同于真正可见。
- SwiftUI 外壳固定接管挂起与恢复：内核 `backgroundPolicy = .suspend`，`automaticallyResumesAfterSuspension = false`。

低频事件为 `waitingForPresentation`、`preparing`、`ready`、`started`、`paused`、`resumed`、`finished`、`failed`。`started` 不是 GPU 已呈现首帧的证明；`finished` 与 `failed` 最多一个。普通重绘不重新准备，同 ID 的 provider 和事件回调在接纳时固定。

SwiftUI 的终态事件可以先于物理清理完成，不能据此立即删除或覆写文件。需要精确等待文件使用权归还的上层资源调度器，应通过 UIKit `PlayerView.clearAndWait()` 接入。

## UIKit：检查、准备、首次播放、排空

以下调用都在 MainActor 上执行；`container` 是已经加入有效窗口、具有正数尺寸的宿主。

```swift
let player = PlayerView(frame: container.bounds)
container.addSubview(player)
player.isMuted = true

let options = PlaybackOptions(
    assetMode: .vap,
    audioMode: .embedded,
    automaticallyResumesAfterSuspension: false
)
let metadata = try await PlayerView.inspect(url: fileURL, options: options)
try await player.prepare(url: fileURL, metadata: metadata, options: options)
player.play(url: fileURL, metadata: metadata, options: options)
```

也可直接调用 `player.play(url:options:)`，由播放器拥有准备任务。`prepare` 不启动时间轴；首次开始要调用 `play`，`resume()` 用于已经开始过的暂停/挂起会话。相同 URL、metadata 和完整配置的 ready 会话会被首次 `play` 复用。

`inspect` 返回 `AssetMetadata`，不创建播放 session、动态 provider、音频或 GPU 管线；`automatic` 模式可能为判型探测少量视频帧。`metadata.dynamicSources` 提供真实 tag、kind 和 slotSize。公开初始化器创建的 metadata 只是摘要，`isReusableForPlayback` 为 false；不能把它提交成已经检查的播放凭证。

```swift
player.pause()
player.resume()

// 终止的同步入口会立即停声；文件/GPU 等资源可能还在异步收尾。
player.stop()

// 回收文件使用权或复用上层加载名额之前，等待真实排空。
await player.clearAndWait()
player.removeFromSuperview()
```

`clear()` 同步隐藏并停止；`clearAndWait()` 等待已登记的准备、provider、解码、音频定位与 GPU 工作。取消这个等待不表示底层已经结束。自然结束、停止与失败可能先通知 delegate；严格资源回收仍须等待排空。

`PlayerDelegate` 在 MainActor 交付 `playerDidStart`、`player(_:didUpdate:)`、`playerDidFinish(_:reason:)`、`player(_:didFail:)`。delegate、`PlayerView.dynamicContentProvider`、metricsSink 属性是弱引用；宿主应持有它们，session 会将接纳的 provider 强持有至清理结束。

## 显式拼接透明视频

以下例子对应 1280×720 的编码帧：左侧 640×720 是颜色，右侧是 Alpha。

```swift
let layout = PackedAlphaLayout(
    arrangement: .sideBySide,
    colorRect: VideoPixelRect(x: 0, y: 0, width: 640, height: 720),
    alphaRect: VideoPixelRect(x: 640, y: 0, width: 640, height: 720)
)
let options = PlaybackOptions(
    assetMode: .packedAlpha(layout),
    audioMode: .embedded,
    automaticallyResumesAfterSuspension: false
)
```

- 矩形以未应用视频轨 `preferredTransform` 的编码帧左上角为原点，单位是整数像素。
- 左右用 `.sideBySide`，上下用 `.topBottom`；沿声明轴不相交，颜色可以在任意一侧。
- 不要求等分、同尺寸或偶数边界；两个区域均须完整位于编码帧内。最终画布取 `colorRect`。
- Alpha 亮度映射透明度：白不透明、黑透明；按局部 UV 对应采样。
- 显式布局不提供 VAP 动态槽，不支持用该模式描述原生 HEVC Alpha 或双文件透明视频。
- 参数错误返回 `invalidAlphaLayout`，不会静默改成普通视频或 legacy 对半布局。

## 动态内容

`DynamicContentProvider` 是 MainActor 的 async throws 协议。按 `inspect` 的 tag/kind 准备好图片与文字，再提供给内核；下载与共享图片缓存留在宿主。

```swift
/// 只转交宿主已准备的内容；没有覆盖值时保留视频底图。
@MainActor
final class PreparedContent: DynamicContentProvider {
    /// 本次请求的覆盖快照，不在 resolve 内修改。
    let values: [String: DynamicContent]

    /// 保存已经下载、解码或生成的内容。
    init(values: [String: DynamicContent]) { self.values = values }

    /// 返回当前 tag 的覆盖值；nil 表示不覆盖该槽。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent? {
        values[tag]
    }
}
```

可返回 `.image(UIImage)`、`.textReplacement(String)`、`.text(String, attributes: TextAttributes)`、`.hidden` 或 nil；可选 `font(forTag:)` 返回 UIFont。nil/hidden 不生成默认头像或默认文字，只保留视频底图。

动态项串行准备，provider 抛错会使准备失败。当前每项截止时间为 8 秒；超时请求取消，非合作 provider 仍会被持有并等待实际退出，不能把超时当成可提前删除其资源的信号。不要在 provider 中等待本播放器的 `clearAndWait()`，这会与正在等待 provider 的清理互相阻塞。

宿主链接 SDWebImage 并返回其动画图片时，可通过 `.animated` 推进动图槽位；`.still` 仅用首帧。`PlaybackOptions.canPlayAnimatedDynamicImages` 可检查运行时能力。本包没有 SDWebImage 下载依赖，也不创建图片缓存。文字超宽可选择 `.truncate` 或 `.marquee`。

## 音频、缓存与验证

`audioMode` 默认为 `.embedded`：准备等待 asset 可播放和 item.readyToPlay，运行期故障使播放失败；实例级 `isMuted` 在准备前及播放中都有效。`.muted`、`.external`、`.disabled` 不建立内嵌播放器。App 负责全局 AVAudioSession；本包不代替房间语音策略。

`AssetMetadataCache.shared` 是 actor，默认最多 20 项，键包含本地 URL 与完整 assetMode/透明布局。复用时校验路径、文件标识、大小、修改时间；源文件应保持不可变。可调用 `setCountLimit(_:)`、`remove(url:)`、`removeAll()`。清缓存不删文件、不停止播放器，也不是排空 API。

验证状态：**v2 构建、单元/集成测试与真机回归待验证登记**。已有测试覆盖布局、配置、metadata 失效、音频取消/定位、SwiftUI 生命周期及解析/渲染路径；测试存在不等于已经通过。发布前需补真实 fixture 的 prepare、首帧、透明背景、内嵌声音、循环、前后台及反复清理验证。

许可证：[Apache-2.0](LICENSE)。
