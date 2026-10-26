import Foundation
import Synchronization

/// 非隔离析构可安全访问的资源所有者；锁只保护句柄移交，不在锁内执行取消或业务清理。
/// 避免依赖 iOS 26.2 的 isolated deinit executor hop，问题见 https://github.com/swiftlang/swift/issues/88036。
final class PlaybackLifetimeOwner: Sendable {
    /// 只在 MainActor 操作播放器对象；闭包可安全移交，不能捕获正在析构的宿主本身。
    typealias Cleanup = @MainActor @Sendable () -> Void

    /// 尚未移交的句柄快照；NotificationCenter token 只在锁内保存或独占取出后注销。
    private struct Resources {
        /// 当前对象的最后清理动作；nil 表示已经移交或无需清理。
        var cleanup: Cleanup?
        /// 宿主发起的准备任务；析构时只发取消，真实排空仍交给 session。
        var task: Task<Void, Never>?
        /// 需要显式注销的 Foundation 观察句柄，取出后不再被共享访问。
        var observations: [PlaybackObservationToken] = []
    }

    /// 所有可变资源通过 Mutex 独占，类本身不需要 unchecked Sendable 或 unsafe 隔离逃逸。
    private let resources = Mutex(Resources())

    /// 创建空 owner，不建立系统观察或异步任务。
    init() {}

    /// 重复析构收尾会取到空快照，不再次清理已移交的对象。
    nonisolated deinit { cancelAndScheduleCleanup() }

    /// 更新当前对象的兜底清理；nil 表示正常路径已把旧资源交给其他受管 owner。
    func replaceCleanup(_ cleanup: Cleanup?) {
        resources.withLock { $0.cleanup = cleanup }
    }

    /// 保存当前准备任务句柄；调用者正常替换任务时仍负责先请求旧任务取消。
    func replaceTask(_ task: Task<Void, Never>?) {
        resources.withLock { $0.task = task }
    }

    /// 接收观察句柄的唯一注销所有权，调用方之后不再保存或移除同一 token。
    func retainObservation(_ observation: any NSObjectProtocol) {
        // 先把 Foundation 不标注 Sendable 的不透明句柄封装好，锁闭包只捕获可安全传递的包装。
        let token = PlaybackObservationToken(observation)
        resources.withLock { $0.observations.append(token) }
    }

    /// 正常 stop 在 MainActor 同步清理，保留立即停声和取消系统操作的语义。
    @MainActor
    func cleanupNow() {
        takeCleanupAfterCancellation()?()
    }

    /// 任意执行器都可取消 Sendable 任务并解除通知，再让主队列移交播放器清理。
    func cancelAndScheduleCleanup() {
        // 没有清理动作时不额外排队；显式 stop/clear 后的析构保持为空操作。
        guard let cleanup = takeCleanupAfterCancellation() else { return }
        // 主队列持有已分离的闭包至执行，不捕获宿主、不假定析构发生在 MainActor。
        DispatchQueue.main.async { cleanup() }
    }

    /// 原子取走全部资源后在锁外取消/注销，防止取消处理器重入同一 owner 导致死锁。
    private func takeCleanupAfterCancellation() -> Cleanup? {
        let owned = resources.withLock { state in
            let owned = state
            state = Resources()
            return owned
        }
        owned.task?.cancel()
        for observation in owned.observations {
            observation.remove()
        }
        return owned.cleanup
    }
}

/// Foundation 观察 token 只作为不可变的不透明标识使用，不读取其可变对象状态。
/// unchecked 仅补足 NSObjectProtocol 的标注缺口：注销通过线程安全的 NotificationCenter，
/// 调用次数由 PlaybackLifetimeOwner 的 Mutex 取走快照保证，原始句柄不向外暴露。
private struct PlaybackObservationToken: @unchecked Sendable {
    /// 只供 removeObserver 使用的系统标识；包装内不向它发送其他消息或修改属性。
    private let rawValue: any NSObjectProtocol

    /// 接收已交给 lifetime owner 的 token，不额外注册观察，也不转移业务对象隔离。
    init(_ rawValue: any NSObjectProtocol) {
        self.rawValue = rawValue
    }

    /// 由唯一取出此包装的清理快照注销观察；不要求调用线程为 MainActor。
    func remove() {
        NotificationCenter.default.removeObserver(rawValue)
    }
}

/// 析构后仍存活的主线程排空登记表；每项结束后删除，避免无人持有的异步清理。
@MainActor
enum PlaybackRetirementOwner {
    /// 尚未实际排空的独立任务；UUID 不与业务请求或缓存身份混用。
    private static var tasks: [UUID: Task<Void, Never>] = [:]

    /// 接管 UIKit 宿主遗留的 session，先停止，再保持到完整准备与 GPU 排空。
    static func retire(_ session: PlaybackSession) {
        session.stop(reason: .cancelled)
        retain { await session.clearAndWait() }
    }

    /// 接管协调器遗留的音轨运行，保持到 load、seek、事件消费者全部结束。
    static func retire(_ run: AudioPlaybackRun) {
        run.stop()
        retain { await run.stopAndWait() }
    }

    /// 在创建任务的同一 MainActor 调用中登记所有权，完成后原子移除自身身份。
    private static func retain(_ cleanup: @escaping @MainActor @Sendable () async -> Void) {
        let id = UUID()
        tasks[id] = Task { @MainActor in
            await cleanup()
            tasks[id] = nil
        }
    }
}
