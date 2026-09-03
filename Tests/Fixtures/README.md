# VAP 测试与 Demo 资源

本目录是仓库内**唯一**的 VAP 样例资源根。单元测试、SwiftExample、ObjectiveCExample 都使用这里的文件，需要随仓库提交，不要加入 `.gitignore`。

路径：`Tests/Fixtures/VAP/`

Demo 通过 Xcode folder reference 把该目录打进 App Bundle，运行时用：

```swift
Bundle.main.url(
    forResource: "<编号>",
    withExtension: "mp4",
    subdirectory: "VAP"
)
```

默认 Demo 播放文件（体积最小的合法 H.264）：

`18.mp4`

文件按 `1.mp4` 到 `21.mp4` 编号，另有 `movie.mp4`；`home.mp4` 是普通 H.264 MP4，
`nationalDayEffect.mp4` 是无 `vapc` 的 legacy packed VAP，便于逐项回归。

## 清单

`1.mp4` 到 `21.mp4` 加 `movie.mp4` 共 22 项；其中 `2.mp4` 与 `9.mp4` 是服务端返回的
AccessDenied XML（并非 MP4），作为解析失败的负向样例。`home.mp4` 是无 `vapc` 的普通视频，
必须按完整画面完成 inspect、视频解码和真机首帧渲染。若目录中存在 `u1.mp4`、`u2.mp4`、
`u3.mp4`，它们同样是 AccessDenied XML 负向样例。其余合法 VAP 也必须完成 inspect、视频解码和真机首帧渲染。

| 编号 | 类型 | 回归要求 |
| --- | --- | --- |
| `1, 3, 4, 7, 10, 14, 15, 17, 20, 21` | vapc 动态图片 + 文字 | 解析、完整解码、动态 RGBA8 texture 上传、真机首帧 |
| `5, 8, 12, 13, 19` | vapc 动态图片（部分多槽位） | 解析、完整解码、动态 texture、真机首帧 |
| `6, 11, 16, 18` | legacy packed VAP | legacy 布局、完整解码、真机首帧；`18` 为默认素材 |
| `movie.mp4` | 旧版最小 VAPC + packed VAP | VAPC 缺少 `v/f` 时从媒体轨道推导帧数，并完成解码和真机首帧 |
| `home.mp4` | 普通 H.264 MP4，无 `vapc` | 完整编码画面、无 Alpha、完整解码和真机首帧 |
| `nationalDayEffect.mp4` | 无 `vapc` 的 legacy packed VAP | 自动识别左 Alpha/右 RGB、完整解码和真机首帧 |
| `2, 9` | AccessDenied XML | 必须明确解析失败且不崩溃 |

编码尺寸是 packed 视频物理分辨率，不是 vapc 逻辑画布。后续 parser 落地后应在测试里核对 `encodedVideoSize` 与 `canvasSize`。
