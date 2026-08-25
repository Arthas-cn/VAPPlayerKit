import Foundation
import QuartzCore

/// 仅用于 VSYNC 采样的 package-private pacer。不注册宿主 target，不按 FPS 建全局桶。
///
/// 对照 `vap-master` 的全局 decode thread pool / FPS dispatcher：这里只服务当前 session。
final class FramePacer: NSObject {
    /// 绑定主 run loop 的 display link。stop 时必须 invalidate。
    private var displayLink: CADisplayLink?
    /// 每次 VSYNC 回调。由当前 session 注入。
    private var handler: (() -> Void)?

    /// 在主 run loop 的 `.common` 模式采样。重复 start 会先停掉旧 link。
    func start(_ handler: @escaping () -> Void) {
        stop()
        self.handler = handler
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// token 失效或 session stop 时必须立刻移除订阅。
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        handler = nil
    }

    /// 每次 VSYNC 只询问当前 media time，不按刷新次数盲目消费视频帧。
    @objc private func tick() {
        handler?()
    }

    /// stop / deinit 时必须 invalidate，避免 display link 继续回调已释放的 session。
    deinit {
        displayLink?.invalidate()
    }
}
