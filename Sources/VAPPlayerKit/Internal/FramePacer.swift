import Foundation
import QuartzCore

final class FramePacer: NSObject {
    private var displayLink: CADisplayLink?
    private var handler: (() -> Void)?

    func start(_ handler: @escaping () -> Void) {
        stop()
        self.handler = handler
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        handler = nil
    }

    @objc private func tick() {
        handler?()
    }

    deinit {
        displayLink?.invalidate()
    }
}
