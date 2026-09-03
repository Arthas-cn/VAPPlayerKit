# VAPPlayerKit 工程规则

本文件是本仓库的协作规则。修改源码、测试、Demo 或 VAP 素材时都必须遵守。

## 项目边界

- 这是一个 iOS 15+、Swift 5.9+ 的 Swift Package；核心播放链路依赖 AVFoundation、VideoToolbox/Metal 和 UIKit。
- VAP MP4 的编码尺寸（`videoW`/`videoH`）是 packed 视频的物理尺寸，VAPC 的 `w`/`h` 是逻辑画布尺寸；两者不能混用。
- `Tests/Fixtures/VAP/` 是测试和 Demo 共用的正式素材目录。素材可能是标准 VAPC、无 VAPC 的旧 packed VAP，或用于负向测试的非 MP4 文件。

## VAPC / MP4 分析规则

- 遇到“某个 MP4 不能播放”时，先检查 MP4 顶层 box、`ftyp`/`moov`、视频轨道、编码格式、尺寸、时长、帧率和 `vapc` JSON，再判断问题是在 inspection、解码还是 Metal 渲染阶段。
- 不要假设所有 `vapc.info` 都包含 `v` 和 `f`。旧版最小 VAPC 可能只保存布局字段；只有在 `v` 与 `f` **同时缺失**且媒体轨道能提供有效帧数时，才走 legacy fallback。
- 只缺少 `v` 或只缺少 `f` 属于损坏的结构化 metadata，必须报错，不能静默降级。所有 fallback 帧数都要有限、为正且受上限保护。
- 无 VAPC 的旧 packed VAP 使用等尺寸 Alpha/RGB 区域，Alpha 可能在左、右、上或下；自动检测必须把方向和 legacy 布局一起确定，不能检测成功后固定写死方向。显式 legacy 覆盖仍以左 Alpha 为兼容默认；不要通过任意默认帧数猜测播放长度。
- `PlaybackOptions.assetMode` 默认是 automatic：有 `vapc` 时按 VAP；无 `vapc` 时严格按媒体时长的 20%、50%、70% 依次抽取单帧检查 packed 特征，命中即停止，三帧都未命中才按普通视频完整画面处理。普通视频的 `canvasSize == encodedVideoSize`、`alphaMode == .none`。
- 旧无 VAPC packed VAP 与普通 MP4 在容器层面不存在绝对可区分标记；启发式误判时可显式使用 `.vap` 或 `.ordinaryVideo`。不要把 URL 扩展名当成格式标记。
- 解析 metadata 成功不等于可以播放。修复后至少要验证 AVAssetReader/硬解、首帧上传和真机渲染；macOS 主机上的媒体解码结果不能替代 iPhone 设备结果。
- 测试新素材时更新 fixture 清单、数量断言和 Demo UI 测试，避免目录扫描成功但回归用例漏测。

## 保留用户改动

- 开始工作先执行 `git status --short`，识别并保留用户已有的 staged、unstaged 和未跟踪文件。
- 不要用 `git reset --hard`、`git checkout --` 或批量覆盖工程文件来“清理”环境。只修改本任务涉及的文件；工程文件中的无关用户改动必须原样保留。
- 提交到仓库的 fixture 不要加入 `.gitignore`，也不要为了绕过解析问题重编码或替换原始测试素材，除非用户明确要求修复素材本身。

## Xcode 构建与测试

- 常规 iOS 编译使用 `Examples/SwiftExample/SwiftExample.xcodeproj` 和 `SwiftExample` scheme。重复构建时使用固定临时目录并跳过包更新，例如：

  ```sh
  xcodebuild \
    -project Examples/SwiftExample/SwiftExample.xcodeproj \
    -scheme SwiftExample \
    -destination 'generic/platform=iOS' \
    -derivedDataPath /private/tmp/vap-ios-dd \
    -clonedSourcePackagesDirPath /private/tmp/vap-spm \
    -skipPackageUpdates \
    build
  ```

- 正确的参数名是 `-clonedSourcePackagesDirPath`；不要使用不存在的 `-clonedSourcePackagesPath`。
- 区分冷启动、包解析、增量编译、签名安装和 XCTest/UI 自动化耗时。首次 `xcodebuild` 慢不代表 Swift 编译慢；`-quiet` 会隐藏过程，诊断时应保留日志和退出码。
- 真机测试先用 `xcrun devicectl list devices` 获取当前连接设备的 UDID，不要假定设备名称或固定 UDID。设备测试需要安装、启动、签名和 XCTest，耗时明显高于 Xcode 的热增量编译。
- 真机 UI 测试在用户已授权时可使用 `-allowProvisioningUpdates` 自动取得测试 runner profile；若签名失败，报告签名/配置问题，不要把它误判为播放器代码失败。
- 本项目素材回归的最低真机验证为：

  - `SwiftExampleUITests/SwiftExampleUITests/testEveryBundledFixtureOnDevice`：逐个 prepare、解码并验证全部合法 fixture 首帧。
  - `SwiftExampleUITests/SwiftExampleUITests/testCatalogCountMatchesRowsAndPlaybackLifecycle`：核对目录数量、列表预览及详情页播放生命周期。

- 任何编译错误都应修复类型/API 根因；不要通过强制解包、关闭警告或降低测试覆盖来掩盖错误。完成后至少执行一次构建，并针对播放器或素材变更执行相关真机回归。
- 本组件只接受本地 `file://` 资源；远程资源下载、缓存和网络重试由宿主负责，不在播放内核中实现。

## 报告结果

- 最终说明根因、修改文件、实际执行的命令/测试和结果；明确区分“编译通过”“metadata inspection 通过”和“真机首帧播放通过”。
- 若测试因设备离线、签名、依赖下载或环境问题未执行，必须单独说明，不得写成测试通过。
