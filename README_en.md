# VAPPlayerKit v2

[简体中文](README.md) · [Architecture and lifecycle](docs/VAPPlayerKit_SPM_ARCHITECTURE.md) · [Changelog](CHANGELOG.md)

A local video effects package for **Swift 6.4 and iOS 26**. It provides `VAPPlayerView` for SwiftUI and `PlayerView` for UIKit, with AVFoundation decoding, Metal transparency composition, and VAP image/text replacement slots.

v2 has a new Swift API and one library product, `VAPPlayerKit`. There is no Objective-C facade or compatibility layer. The current version is **v2.0.0**. Historical 1.x tags do not contain these interfaces.

## Installation

Add this remote package URL in Xcode:

```text
https://github.com/Arthas-cn/VAPPlayerKit.git
```

Select **v2.0.0** or a compatible update, and declare the remote dependency:

```swift
.package(url: "https://github.com/Arthas-cn/VAPPlayerKit.git", from: "2.0.0")
```

Link the product to the consuming App target:

```swift
.product(name: "VAPPlayerKit", package: "VAPPlayerKit")
```

Use `import VAPPlayerKit`. The manifest requires Swift tools 6.4, Swift 6 language mode, and iOS 26. Metal shaders are package resources. Local package paths are suitable for development; release dependencies must use the remote repository.

## Ownership and scope

| Package | Host application |
| --- | --- |
| Local MP4/VAP inspection, decoding, buffering, rendering | Downloads, ZIP/config.json, persistent caches and databases |
| VAP, ordinary video and explicit packed Alpha layouts | Business format routing and resource preparation barriers |
| Embedded audio, looping, pause/resume and cleanup | Global AVAudioSession and external audio synchronization |
| Rendering prepared images and text into slots | Image downloads and shared SDWebImage caching |
| Per-player lifecycle | Global load/resident limits and business playback queues |

Only local regular files are accepted. Keep the file readable and immutable throughout inspection, preparation, playback, and cleanup. The package does not own or delete source files.

## Asset modes

`PlaybackOptions` is a `Sendable, Equatable` value. Each session uses the value accepted at creation.

| `assetMode` | Behavior |
| --- | --- |
| `.vap` (default) | Parse VAP; older files without vapc use a left-Alpha layout |
| `.ordinaryVideo` | Use the full encoded frame; skip vapc and transparency detection |
| `.packedAlpha(layout)` | Use the supplied color/Alpha rectangles without detection |
| `.automatic` | Prefer vapc, then probe legacy packed content; otherwise use ordinary video |

Choose an explicit mode when the format is already known. Business extensions, ZIP manifests, and protocol type routing belong to the host.

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

`loopCount` is the total number of iterations: 1 means once, 0 means infinite. Negative values fail. Layout accepts `.scaleAspectFit`, `.scaleAspectFill`, and `.scaleToFill`, based on the logical canvas.

## SwiftUI

Create and retain a stable request ID in your MainActor view state. Here, `fileURL` is a local file already prepared by the host:

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

Do not create a fresh UUID on every `body` evaluation. Keep the same ID while URL/options are unchanged; use a new ID for replacement, configuration changes, or replay. Changing immutable input under the same ID fails. A terminal ID cannot restart.

- Pause with `.paused`. Increment `controlRevision` for explicit play/pause/resume commands.
- After a system pause, submit `.playing` with a new control revision. Returning to the foreground alone does not resume.
- `.stopped`, `isVisible = false`, or `resource = nil` ends the request. Replay uses a new ID.
- `isMuted` can change without replacing the request.
- Supply actual visibility; a list's `onAppear` is not sufficient.
- The SwiftUI layer owns lifecycle control: it forces `.suspend` and disables automatic kernel resumption.

Events are `waitingForPresentation`, `preparing`, `ready`, `started`, `paused`, `resumed`, `finished`, and `failed`. `started` does not prove that a GPU frame has become visible. Each request has at most one terminal event. Provider and event callback are captured when the request is accepted.

Terminal events may arrive before physical cleanup finishes. Do not immediately delete or overwrite source files on `finished`/`failed`. Resource schedulers that require an explicit file-release barrier should integrate through UIKit's `PlayerView.clearAndWait()`.

## UIKit: inspect, prepare, play, drain

Run these calls on MainActor. `container` must belong to an active window and have positive dimensions:

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

`play(url:options:)` can also own preparation directly. `prepare` does not start playback; the first start uses `play`. `resume()` continues a session that has already started. A ready session with matching URL, metadata, and full options is reused for its first play.

`inspect` creates no playback session, dynamic provider, audio player, or GPU pipeline. Automatic classification may probe a few video frames. `metadata.dynamicSources` exposes actual tags, kinds, and slot sizes. Manually initialized `AssetMetadata` values are summaries with `isReusableForPlayback == false`, not reusable inspection credentials.

```swift
player.pause()
player.resume()
player.stop()

// 回收文件使用权或复用上层加载名额之前，等待真实排空。
await player.clearAndWait()
player.removeFromSuperview()
```

`stop()` immediately stops output and starts managed cleanup. `clear()` also hides the image. `clearAndWait()` waits for registered preparation, provider, decoder, audio, and GPU work. Cancelling the wait does not make those resources immediately safe to release.

`PlayerDelegate` is MainActor-isolated and exposes `playerDidStart`, `player(_:didUpdate:)`, `playerDidFinish(_:reason:)`, and `player(_:didFail:)`. Delegate, provider, and metrics properties on `PlayerView` are weak. The host retains them; an accepted session retains its provider until cleanup finishes.

## Explicit packed Alpha

This example uses a 1280×720 encoded frame, with 640×720 color on the left and Alpha on the right:

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

Coordinates are integer pixels from the top-left of the encoded frame, before the video track's `preferredTransform`. Use `.sideBySide` or `.topBottom`; rectangles must be disjoint along that axis and inside the encoded frame. Either side may contain color. Equal halves, equal dimensions, and even coordinates are not required. The canvas uses `colorRect` dimensions, and Alpha is sampled by corresponding local UV coordinates: white is opaque and black is transparent.

This mode does not expose VAP dynamic slots. It does not describe native HEVC Alpha or separate color/Alpha files. Invalid rectangles fail with `invalidAlphaLayout`; they are not silently converted to a guessed layout.

## Dynamic content

Implement MainActor `DynamicContentProvider.resolve(tag:source:) async throws -> DynamicContent?`. Use `inspect` to discover tags and prepare images/text before playback.

```swift
/// 只转交宿主已准备的内容，不在播放器中建立网络或缓存服务。
@MainActor
final class PreparedContent: DynamicContentProvider {
    /// 本次请求的覆盖快照。
    let values: [String: DynamicContent]

    /// 保存已经准备的内容。
    init(values: [String: DynamicContent]) { self.values = values }

    /// 未提供值时保留视频底图，不生成默认头像或文字。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent? {
        values[tag]
    }
}
```

Values are `.image(UIImage)`, `.textReplacement(String)`, `.text(String, attributes: TextAttributes)`, `.hidden`, or nil. Optional `font(forTag:)` returns a UIFont. Nil/hidden leaves the video background untouched.

Slots prepare sequentially. Provider errors fail preparation. The current per-slot deadline is 8 seconds; a timed-out provider is asked to cancel and remains owned until it actually returns. A non-cooperative provider can therefore delay cleanup. Do not await this same player's `clearAndWait()` inside its provider.

Animated image slots can consume compatible animated images when the host links SDWebImage. `.still` selects the first frame; `.animated` advances animation when available. Check `PlaybackOptions.canPlayAnimatedDynamicImages`. The package does not download images or create an SDWebImage cache. Text overflow supports `.truncate` and `.marquee`.

## Audio, metadata cache and verification

`audioMode` defaults to `.embedded`. Preparation waits for both playable asset and ready item; runtime audio errors fail playback. `isMuted` applies before preparation and during playback. `.muted`, `.external`, and `.disabled` create no embedded audio player. The App owns global AVAudioSession policy.

`AssetMetadataCache.shared` is an actor with a default limit of 20 entries. Its key includes local URL and the entire asset mode/layout. Reuse validates path, file identifier, size, and modification time. Use `setCountLimit(_:)`, `remove(url:)`, or `removeAll()` for maintenance. These operations do not delete source files, stop playback, or provide a cleanup barrier.

Validation: **172 executions** across 130 test declarations pass on iPhone 15 / iOS 26.2, including completed GPU first frames for all **27 valid fixtures** and real embedded audio preparation/seeking for `1/10/17`. **Seven UI tests** pass on the existing simulator. Physical-device XCUITest runner handshaking remains an environment limitation; see the [validation record](docs/v2.0.0-validation.md).

License: [Apache-2.0](LICENSE).
