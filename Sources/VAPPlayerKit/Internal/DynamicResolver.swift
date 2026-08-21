import Foundation

/// 准备动态图片 / 文字纹理。不进入视频解码线程，不发网络请求。
///
/// 对照 `vap-master` 把 tag 内容和图片下载塞进 delegate 的方式；这里由宿主 `DynamicContentProvider` 注入。
final class DynamicResolver {
    /// 当前 session 的 Swift provider。弱引用，释放后应走失败/取消路径。
    weak var provider: DynamicContentProvider?

    /// 取消未完成的等待组。每个 completion 仍必须恰好调用一次。
    func cancel() {}
}
