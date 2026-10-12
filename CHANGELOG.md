# Changelog

## 1.0.6 — 2026-10-12

- 识别无 `vapc`、左右拼接且垂直错位的旧 packed VAP（`7878.mp4`）：Alpha 在右，画布取两半重叠区域。
- 收紧错位识别：轮廓相关至少 0.85、相对对齐增益至少 0.40，RGB 半幅必须有彩色，另一维轮廓也要对齐，避免半灰半彩的普通分屏被裁成 VAP。
- 补充错位正例、横切面不匹配的普通分屏反例，以及素材清单和 Demo 目录断言。
- 验证：模拟器上的检测回归、`7878` inspection 和已有 fixture inspection 通过。真机 UI 回归因设备锁定未执行。

## 1.0.5 — 2026-09-09

- 修复无 `vapc` 的左右 packed VAP 因顶部黑边产生多个候选而被误识别为普通视频的问题，新增 `alpha_left_moive.mp4` 回归素材。
- 优先检查左 Alpha，唯一强相关候选优先于弱候选；多个强候选或多个弱候选仍保持不确定，避免误裁剪普通灰度视频。
- 排除纯黑平坦区域的弱证据，保持 20% / 50% / 70% 单帧探测顺序和 NV12 直接采样。
- 补充四方向黑边/灰边、重复灰度与普通视频反例、素材清单及 Demo 分类断言。
- 验证：iOS 构建通过，73 项解析器/核心测试通过，iPhone 12 全部合法素材首帧及目录/播放生命周期回归通过。

## 1.0.4 — 2026-09-03

- 无 `vapc` 的自动识别严格按媒体时长 20%、50%、70% 依次抽取单帧，命中即停止，三帧都未命中才按普通 MP4 处理。
- 补充 `movie01.mp4` 和 `movie02.mp4` 回归素材、解析测试及 iPhone 12 真机首帧/播放生命周期验证。

## 1.0.3 — 2026-09-03

- 修复首帧为空黑的无 `vapc` legacy packed VAP（`nation.mp4`）被误识别为普通 MP4。
- 在有限首段样本内识别 packed 特征，避免扫描完整视频，同时保持普通 MP4 默认使用完整画面。
- 补充 `nation.mp4` fixture、metadata inspection、目录清单及 iPhone 12 真机回归。

## 1.0.2 — 2026-09-03

- 修复无 `vapc` 的 legacy packed VAP 被误识别为普通 MP4 的问题。
- 自动识别左、右、上、下四种 Alpha/RGB packed 布局，并保持 metadata 与渲染矩形一致。
- 补充 `nationalDayEffect.mp4` 回归素材、解析测试和 iPhone 12 真机播放回归。

## 1.0.0 — 2026-09-01

首个正式版本。

- 通过 Swift Package Manager 提供 `VAPPlayerKit` 和 Objective-C facade。
- 支持 iOS 15+、H.264/HEVC、packed Alpha 合成、VAPC 动态图片与文字槽位。
- 支持 prepare/play/pause/resume/stop/clear、后台策略、音频策略和 metadata 缓存。
- 修复旧版最小 VAPC 缺少 `info.v` / `info.f` 时无法 inspection 和播放的问题。
- 补充 `movie.mp4` fixture，并在 iPhone 12 真机完成全部合法素材的 prepare、解码和首帧回归。
- 移除不属于 SPM 消费者要求的 GitHub Actions CI；发布验证由维护者本地执行。
