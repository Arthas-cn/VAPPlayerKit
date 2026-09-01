# VAPPlayerKit

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/iOS-15%2B-lightgrey.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](#requirements)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](#installation)

[简体中文](README.md) | **English**

A standalone iOS player for VAP (Video Animation Player). The core is Swift, distributed via Swift Package Manager, with a stable Objective-C facade.

Current stable version: `1.0.0`

It plays the same local MP4 assets as [Tencent VAP](https://github.com/Tencent/vap): hardware decode, alpha compositing, and vapc fusion overlays (user names, avatars, and other dynamic slots). Networking, business caches, and play queues are out of scope — the host owns those.

```swift
import VAPPlayerKit

let player = PlayerView()
let options = PlaybackOptions.defaultOptions
options.loopCount = 1
player.play(url: fileURL, options: options)
```

## Why not official QGVAPlayer

[Tencent VAP](https://github.com/Tencent/vap) (iOS: `QGVAPlayer`) defined the VAP container and the [VapTool](https://github.com/Tencent/vap/tree/master/tool) authoring pipeline. That repository is **unmaintained**; Tencent now points users at a commercial cloud product.

VAPPlayerKit is **not** a Swift translation of QGVAPlayer, and it does not wrap the old API. After using the latest official sources only as a format/behavior reference, it reimplements parsing, decode, clocks, Metal compositing, and session lifetime as an iOS playback kernel that can ship on its own.

| | Tencent VAP / QGVAPlayer | VAPPlayerKit |
| --- | --- | --- |
| Maintenance | Officially unmaintained | Independent open-source iOS player |
| Language | Objective-C | Swift, with a `VPK*` Objective-C facade |
| Public API | `UIView+VAP` category on any view | Dedicated `PlayerView` / `VPKPlayerView`; no UIView pollution |
| Distribution | Copy sources, subproject, CocoaPods | Swift Package Manager; Metal shaders ship as package resources |
| Minimum OS | iOS 8 | iOS 15 (Metal only, no OpenGL fallback) |
| Decode / compose | VideoToolbox + Metal / OpenGL | System `AVAssetReader` hardware decode to NV12 + Metal |
| Lifetime | Global decode thread pool and FPS dispatcher | Isolated session + token per playback; fast switches do not leak callbacks |
| Callback threads | Most delegates run on a **background** thread | Main thread only; at most one terminal event per session |
| Loop semantics | `repeatCount` is **extra repeats** (`0` plays once) | `loopCount` is **total plays** (`1` plays once, `0` loops forever) |
| Audio | `setMute:` | `muted` / `embedded` / `external` / `disabled` |
| Dynamic content | String tags + image-URL callback | Typed `DynamicContent`; auto type size, truncate, or marquee |
| Animated slots | Host-defined | Optional: GIF / animated WebP when the host links SDWebImage; the kit does not depend on it |
| Prepare | Play immediately | Split `prepare` / `play`; in-process metadata cache |
| Errors | Generic `NSError` | Shared `VPKPlaybackError` domain and stage |
| Observability | Custom logger | Optional `MetricsSink` (prepare, first frame, drops, …) |
| Platforms | Android / iOS / Web | **iOS player only**; keep using official VapTool for authoring |

Intentionally not ported from QGVAPlayer:

- No compatibility with `playHWDMP4:`, `repeatCount`, or `QG*` / `HWD*` symbols.
- No built-in tap/long-press hit testing; add UIKit gestures on `PlayerView`.
- No Android / Web player; use the official implementations or other platform stacks.
- No HTTP downloader, ZIP unpacker, gift queue, or image library.

CocoaPods integration of the official library requires manually adding Metal shaders to the app target, or they never land in `default.metallib`. VAPPlayerKit compiles shaders as SPM resources, so that step is gone.

## Features

- Local `file://` MP4: H.264 / HEVC, system hardware decode to NV12.
- `vapc` metadata v1 / v2; Alpha layouts Left / Right / Top / Bottom.
- Legacy packed files without `vapc` are accepted as left-Alpha / right-RGB equal split. No `enableOldVersion` flag.
- Metal compositing: YUV → RGB, packed Alpha unpack, fusion-animation mask overlays.
- PTS media clock, bounded frame buffer, drop-late-frames. Video is not advanced by display refresh rate.
- Controls: `prepare`, `play`, `pause`, `resume`, `stop`, `clear`.
- Scaling: `scaleAspectFit` / `scaleAspectFill` / `scaleToFill` against the vapc **logical canvas**, not encoded resolution.
- Background / off-screen: suspend and keep progress, or stop.
- Dynamic images and text; text can auto-fit the slot, truncate, or marquee.
- Mute, embedded MP4 audio, or host-managed external audio.
- Swift and Objective-C APIs with aligned events, errors, and options.
- In-process `AssetMetadataCache` so unchanged local files skip repeat inspection.

## Requirements

- iOS 15+
- Swift 5.9+
- Xcode 15+

## Installation

In Xcode: File → Add Package Dependencies, then:

```text
https://github.com/Arthas-cn/VAPPlayerKit.git
```

Or in `Package.swift`:

```swift
.package(url: "https://github.com/Arthas-cn/VAPPlayerKit.git", from: "1.0.0")
```

```swift
.product(name: "VAPPlayerKit", package: "VAPPlayerKit")
```

Swift: `import VAPPlayerKit`. Objective-C: `@import VAPPlayerKitObjC;` (or `#import <VAPPlayerKitObjC/VPKPlayerKitObjC.h>`). The product includes both the Swift implementation and the ObjC header facade.

## Quick start

### Swift

```swift
import VAPPlayerKit

let player = PlayerView()
player.delegate = self
player.dynamicContentProvider = self

let options = PlaybackOptions.defaultOptions
options.loopCount = 1          // play once; 2 plays twice; 0 loops forever
options.audioMode = .embedded  // default; use .muted to silence
player.play(url: fileURL, options: options)
```

Set `PlaybackOptions` before `play` / `prepare`. The session keeps a copy; mutating the original later does not affect the active playback.

To read canvas size, duration, or dynamic slots first:

```swift
let metadata = try await player.prepare(url: fileURL, options: options)
print(metadata.canvasSize, metadata.duration, metadata.dynamicSources)

if metadata.isReusableForPlayback {
    // Skip MP4 / vapc inspection when the same local file has not changed
    player.play(url: fileURL, metadata: metadata, options: options)
}
```

Callbacks:

```swift
func playerDidStart(_ player: PlayerView) {}
func player(_ player: PlayerView, didUpdate metadata: AssetMetadata) {}
func playerDidFinish(_ player: PlayerView, reason: FinishReason) {}
func player(_ player: PlayerView, didFail error: Error) {}
```

All run on the main thread. `finish` and `fail` are mutually exclusive; a session emits at most one of them.

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

You can pass a `VPKAssetMetadata` previously produced for the same URL to `playWithURL:metadata:options:`. Only objects with `reusableForPlayback == YES` are valid for that path.

`VPKPlayerViewDelegate` reports start, metadata, finish, and failure — also on the main thread.

## Playback options

| Field | Default | Meaning |
| --- | --- | --- |
| `loopCount` | `1` | Total plays. `0` loops forever. Negative values clamp to `1`. **Do not pass old `repeatCount` values unchanged.** |
| `contentMode` | `.scaleAspectFit` | Scales against `canvasSize` |
| `audioMode` | `.embedded` | `.muted` / `.embedded` / `.external` / `.disabled` |
| `clearsAfterFinish` | `true` | Hide the current frame when finished |
| `backgroundPolicy` | `.suspend` | Suspend or stop when backgrounded / removed from a window |
| `dynamicImagePlaybackMode` | `.animated` | Animated slot images; still frames if SDWebImage is absent |
| `dynamicTextOverflowMode` | `.truncate` | `.truncate` or `.marquee` |
| `marqueeSpeed` | `80` | Marquee speed in pt/s |
| `marqueeStartDelay` | `0.6` | Pause at the start of each scroll cycle, in seconds |

`.external` means the kit creates no audio player; the host owns A/V sync. `.disabled` ignores the audio track, though metadata may still report `containsAudio`.

## Dynamic fusion content

vapc sources appear on `AssetMetadata.dynamicSources` with tag, slot size, and kind (image / text). The kit does **not** infer kind from the tag string, and it never issues network requests.

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

Call `completion` exactly once.

| `DynamicContent` | Use |
| --- | --- |
| `.textReplacement(String)` | Replace copy only. Uses vapc color, bold flag, and slot size to estimate a system font that fits |
| `.text(_:attributes:)` | Fully specified font and color |
| `.image(UIImage)` | Already-decoded image; the kit pre-scales to the slot. The host must download first, then return this case |
| `.hidden` | Skip this slot for the current session |

vapc does not embed a font file or an exact point size, so `.textReplacement` cannot restore the original family or size. Implement `font(forTag:)` to supply a `UIFont`; return `nil` to keep auto-sizing.

Auto-sizing shrinks at most three times, then defaults to `byTruncatingTail`. `.marquee` scrolls right-to-left when the string is wider than the slot; text that fits stays statically centered. Marquee clocks follow pause / suspend and are independent of video `loopCount`. The loop gap is a fixed 25 pt. Strings that exceed the texture budget fall back to truncation.

If no provider is set, or a tag returns `nil` / `.hidden`, that slot is treated as transparent empty content. Video still prepares and plays.

Image slots always take `UIImage`. If the host links [SDWebImage](https://github.com/SDWebImage/SDWebImage) and passes `SDAnimatedImage` (`animatedImageFrameCount > 1`), the kit honors `dynamicImagePlaybackMode`. Animated WebP also needs `SDWebImageWebPCoder`. Check `PlaybackOptions.canPlayAnimatedDynamicImages` for runtime detection. Animated loops follow the VAP session and stop with it.

Compatibility: `.textReplacement` is a new public enum case; `.imageURL` has been removed (the kit does not download URLs — fetch first, then return `.image`). Existing exhaustive `switch`es on `DynamicContent` must add `.textReplacement` and drop `.imageURL` (or use `@unknown default`). That is a source-breaking change and should ship as a SemVer major.

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

Text slots return `replacementText` (same behavior as Swift `.textReplacement`). Image slots return `UIImage`. Optionally implement `fontForTag:`.

## Metadata cache

A process-wide `AssetMetadataCache` reuses inspection results for the same local URL. Default capacity is 20. The cache lives in memory only and is dropped when file identity, size, or modification date changes.

```swift
AssetMetadataCache.shared.countLimit = 32
AssetMetadataCache.shared.remove(url: fileURL)
AssetMetadataCache.shared.removeAll()
```

Objective-C: `VPKAssetMetadataCache.sharedCache`. Setting capacity to `0` disables and clears the cache.

Reuse validates a stable file identity, size, and modification date around decoder prepare. Treat the local file as immutable for the prepare / play / stop lifetime. For untrusted concurrent writers, the host should publish an atomic download/cache result before handing the path to the player.

## Observability

Optionally implement `MetricsSink` and forward events to your APM. The kit does not log business URLs or image bytes by default.

```swift
player.metricsSink = self

func record(_ event: MetricsEvent) {
    // prepareDuration / firstFrameDuration / droppedFrame / sessionFinished ...
}
```

Swift errors are `PlaybackError`; Objective-C uses `NSError`. The domain is `com.vapplayerkit.playback` in both languages.

## Support matrix

**In scope**

- Local `file://` MP4
- H.264 / HEVC
- vapc v1 / v2 and four Alpha layouts
- Legacy packed layout without vapc (left Alpha / right RGB)
- Fusion-animation image/text slots and in-video masks

**Out of scope**

- Network URLs, HTTP download, retry, auth
- ZIP extraction, on-disk business cache, play queues
- A hard dependency on any image library (SDWebImage is runtime-detected only)
- Gift, room, or priority-scheduler concepts
- Android, Web, or authoring (use [VapTool](https://github.com/Tencent/vap/tree/master/tool))

## Examples

Open `VAPPlayerKit.xcworkspace` to build the Swift package, SwiftExample, and ObjectiveCExample together.

The Swift sample copies `Tests/Fixtures/VAP` into the app bundle and scans every MP4 at launch:

- The catalog lists each asset and auto-loops a muted preview while visible. Negative fixtures show an error badge only.
- Playback Lab starts automatically with infinite loop, embedded audio, animated slots, and text marquee. Use it to exercise prepare / play / pause / resume / stop / clear, the three content modes, looping, audio, background policy, still vs animated slots, truncate vs marquee, and live metrics.
- SwiftExample links SDWebImage and SDWebImageWebPCoder so GIF / animated WebP play. ObjectiveCExample does not, so the same assets show still frames.
- Playback Lab can run a single-asset smoke test and export a diagnostics report. The catalog can batch-test every bundled asset on a real device.

See [`Tests/Fixtures/README.md`](Tests/Fixtures/README.md) for the asset list. Those files are committed and shared by unit tests and demos.

## Layout

```text
Sources/VAPPlayerKit/          Swift implementation and public API
Sources/VAPPlayerKitObjC/      Objective-C header-only facade
Tests/                         Unit tests
Tests/Fixtures/VAP/            Checked-in VAP samples
Examples/SwiftExample          Swift sample app
Examples/ObjectiveCExample     Objective-C sample app
```

## Verification

```sh
xcodebuild \
  -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme VAPPlayerKit \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

The release gate is that the Swift package builds and tests against the target iOS SDK. The Swift / Objective-C examples, device runs, long loops, and Instruments checks are optional maintainer validation. Release checks live in [`VAPPlayerKit_SPM_ARCHITECTURE.md`](VAPPlayerKit_SPM_ARCHITECTURE.md). Performance bounds and known limits: [`VAPPlayerKit_PERFORMANCE_EVALUATION.md`](VAPPlayerKit_PERFORMANCE_EVALUATION.md).

On an iPhone 12, compared with the local `vap-master` implementation, the core path from prepare to the first GPU submission is about 30% faster on average across four key metrics. Cold-start performance improves by about 17%, warm-start performance by about 43%, and warm preparation by about 66–76%. Both regular assets and image/text replacement assets show gains.

With a signed device attached, run `SwiftExampleUITests`:

```sh
xcodebuild \
  -workspace VAPPlayerKit.xcworkspace \
  -scheme SwiftExample \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  -allowProvisioningUpdates \
  test
```

That suite checks bundle scan counts, playback lifetime and metrics, runs a Fit / Fill / Stretch matrix, prepares and actually plays every valid asset, and asserts that negative assets are rejected.

## Migrating from QGVAPlayer

1. Replace any `UIView` + `playHWDMP4:` with `PlayerView`.
2. Map `repeatCount` to `loopCount`: old `0` → new `1`, old `n` → new `n + 1`, infinite loop → `0`.
3. Replace `setMute:` with `options.audioMode = .muted` or `.embedded`.
4. Replace `contentForVapTag:` / `loadVapImageWithURL:` with `DynamicContentProvider`. Download images first, then return `.image`.
5. Move UI work off background queues — new callbacks already arrive on the main thread.
6. Keep gestures, downloaders, and play queues in the host.

## License

[Apache License 2.0](LICENSE)

The VAP format and the official player [Tencent VAP](https://github.com/Tencent/vap) are MIT licensed. This repository is an independent implementation and does not include or redistribute the official iOS sources.
