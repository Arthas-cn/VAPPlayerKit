# 优化后多素材性能对比

设备：iPhone 12，iOS 26.5.2；两端均为 Release 签名真机包；每个素材 1 次进程 cold + 4 次 warm；每个样本播放 2 秒；两端均 5/5 有效。

“API → 首次 GPU 提交”是 CPU 发起播放到第一笔 command buffer 提交，不是最终屏幕光子呈现。

| 素材 | 阶段 | 指标 | VAPPlayerKit | vap-master | 新版收益 |
| --- | --- | --- | ---: | ---: | ---: |
| demo.mp4 | cold | API → ready | 30.00 ms | 34.09 ms | +12.0% |
| demo.mp4 | cold | API → 首次 GPU 提交 | 69.49 ms | 85.39 ms | +18.6% |
| demo.mp4 | warm 中位数 | API → ready | 2.79 ms | 8.11 ms | +65.6% |
| demo.mp4 | warm 中位数 | API → 首次 GPU 提交 | 37.73 ms | 51.32 ms | +26.5% |
| 1.mp4（图片+文字替换） | cold | API → ready | 38.01 ms | 48.73 ms | +22.0% |
| 1.mp4（图片+文字替换） | cold | API → 首次 GPU 提交 | 82.49 ms | 97.41 ms | +15.3% |
| 1.mp4（图片+文字替换） | warm 中位数 | API → ready | 2.89 ms | 11.89 ms | +75.7% |
| 1.mp4（图片+文字替换） | warm 中位数 | API → 首次 GPU 提交 | 50.84 ms | 54.04 ms | +5.9% |

## 优化后的阶段证据

- demo warm frame_source：约 0.03 ms；优化前约 7.10 ms。
- 1.mp4 warm frame_source：约 0.03 ms；优化前同样避免了重复 AVAsset track/format description 查询。
- demo 没有动态内容时，warm renderer 约 0.13 ms，动态 overlay pipeline 不再在基础 renderer prepare 中提前编译。
- 1.mp4 的报告每次都包含非零 dynamic_resolve 与 dynamic_upload；warm 中位数约 0.014 ms + 0.054 ms，动态素材仍可正常渲染，5/5 样本有效。

逐素材原始报告和完整诊断见同目录下的 demo-comparison.md、1-comparison.md 及四份 JSON。
