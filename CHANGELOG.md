# Changelog

## 1.0.0 — 2026-09-01

首个正式版本。

- 通过 Swift Package Manager 提供 `VAPPlayerKit` 和 Objective-C facade。
- 支持 iOS 15+、H.264/HEVC、packed Alpha 合成、VAPC 动态图片与文字槽位。
- 支持 prepare/play/pause/resume/stop/clear、后台策略、音频策略和 metadata 缓存。
- 修复旧版最小 VAPC 缺少 `info.v` / `info.f` 时无法 inspection 和播放的问题。
- 补充 `movie.mp4` fixture，并在 iPhone 12 真机完成全部合法素材的 prepare、解码和首帧回归。
- 移除不属于 SPM 消费者要求的 GitHub Actions CI；发布验证由维护者本地执行。
