# VAP 测试与 Demo 资源

本目录是仓库内**唯一**的 VAP 样例资源根。单元测试、SwiftExample、ObjectiveCExample 都使用这里的文件，需要随仓库提交，不要加入 `.gitignore`。

路径：`Tests/Fixtures/VAP/`

Demo 通过 Xcode folder reference 把该目录打进 App Bundle，运行时用：

```swift
Bundle.main.url(
    forResource: "<hash>",
    withExtension: "mp4",
    subdirectory: "VAP"
)
```

默认 Demo 播放文件（体积最小的合法 H.264）：

`e9b6b7196780ea5f64b9f05034571f12a96787278ed678c83141c7913af7318a.mp4`

文件名保持内容 hash，便于和外部资源表对齐。

## 清单

| 文件（hash.mp4） | 大小 | 编码尺寸 | 时长 | 编码 | 用途 |
| --- | ---: | --- | ---: | --- | --- |
| `e9b6b7196780ea5f64b9f05034571f12a96787278ed678c83141c7913af7318a.mp4` | 92 KB | 560×280 | 3.0s | H.264 | **Demo 默认**、小尺寸回归 |
| `7baddbcf47e6ff61198efc3857145ab521e0d836c4ec474e106457eb87fcf774.mp4` | 275 KB | 1024×288 | 3.0s | H.264 | 宽画布 |
| `ae57c02340479f25d135c9d8c37db6a1f9291c44482ecca0cc21fdd22252700d.mp4` | 422 KB | 880×688 | 5.7s | H.264 | 中等画布 |
| `af47b0240315c9ccf27d6979ad0982243cd3724b7d809dc67f9095008a84dde6.mp4` | 435 KB | 1024×288 | 3.0s | H.264 + AAC | 带音频 |
| `ed10b8132647ec3179b70f569531ad9bc749f57aeae5c11f5a9cf5fecdea4e35.mp4` | 513 KB | 1136×1344 | 4.0s | H.264 | 竖版 |
| `30f726180edb3f9678571999dd51dff00b3a6cf02cc1fd431beabef47f33bfb1.mp4` | 526 KB | 1136×1344 | 4.0s | H.264 | 竖版 |
| `6e5864ff3feb6ed929ba059c01931d15f2fe3866abe941b95112562f4546387b.mp4` | 530 KB | 1136×1344 | 4.0s | H.264 | 竖版 |
| `a6e2efbe6256d235aa77a65afc45242014f491de99799c63506f956cb3394fcb.mp4` | 635 KB | 752×688 | 3.0s | H.264 | 中等画布 |
| `5577d7c4de0e0099e62a8faa64a0fb7f59fbede821128c2d5dc8014ab9bda8b8.mp4` | 774 KB | 864×432 | 4.0s | H.264 + AAC | 横版带音频 |
| `5944d120bae8c9f255c68ed893e585a8cdff332dbd1f3c94c3e9e1241ab1e573.mp4` | 1.7 MB | 1136×1344 | 5.0s | H.264 | 竖版 |
| `2d4b1f2a4750f31cc6640bc2c9b464821bb520f04f195b21221204acdcc58277.mp4` | 1.8 MB | 752×688 | 8.4s | H.264 | 中等时长 |
| `aca3747f6e4ffa133140c336f62d13817c2172ca708af65ceab9961718fa9bf5.mp4` | 1.8 MB | 752×688 | 8.4s | H.264 | 中等时长 |
| `2a835e65238ba609b81e28f008409bdc2d015dc4d4278aac4872515bf75a7d9e.mp4` | 2.0 MB | 752×688 | 11.3s | H.264 | 较长 |
| `d0239acd013de7c02769a923aa59ee87e8146a1810ff29369a8e7c275f90b68e.mp4` | 4.0 MB | 1136×1344 | 11.3s | H.264 + AAC | 大尺寸带音频 |
| `f9ae9f6602eb8ebcfee499cbeb6d369ae016b62ac3a97c1e02b6ef843ace0c1f.mp4` | 4.2 MB | 1136×1344 | 11.3s | H.264 + AAC | 大尺寸带音频 |
| `f3c7783080da1b1b022225a77c3ca4f77d7fea8a368a9c858619762b34220682.mp4` | 4.2 MB | 1136×1344 | 11.3s | H.264 + AAC | 大尺寸带音频 |
| `1292fd6d3ea731a701f344809f741d94e8cf41812eea1d6dcf448880be47280f.mp4` | 4.5 MB | 1136×1344 | 11.3s | H.264 + AAC | 大尺寸带音频 |
| `19fe61bfdb42437dc230a5e2e9faa7f92da146e310ebbb3ab59c679590b48b42.mp4` | 4.6 MB | 1136×1344 | 11.3s | H.264 + AAC | 大尺寸带音频 |
| `0ce3b79c81171ed42e5b2e0e3fb2f9b09346d2d255b1884a60e59ddd8cb2cedc.mp4` | 4.6 MB | 1136×1344 | 11.3s | H.264 + AAC | 大尺寸带音频 |
| `0f691eda3e82a2808e38f34be2e80efde45d4b66084a7e3e80cbd7a9a209c23d.mp4` | 243 B | — | — | 非法（AccessDenied XML） | **负向**：损坏资源，解析必须失败且不崩溃 |
| `38c168451bbfe1b792e84067260011202452d7b04ac762a0c2c0d1e0acd2377f.mp4` | 263 B | — | — | 非法（AccessDenied XML） | **负向**：损坏资源，解析必须失败且不崩溃 |

编码尺寸是 packed 视频物理分辨率，不是 vapc 逻辑画布。后续 parser 落地后应在测试里核对 `encodedVideoSize` 与 `canvasSize`。
