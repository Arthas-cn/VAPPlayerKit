import UIKit

/// 控制器依赖的窄播放能力；只隔离 UIKit 内核，便于确定性验证状态与排空顺序。
@MainActor
protocol VAPPlayerTransport: AnyObject {
    /// 由当前请求独占的渲染视图，宿主只负责尺寸与挂载。
    var view: UIView { get }
    /// 内核即时静音值，准备前即可设置。
    var isMuted: Bool { get set }
    /// 准备本地请求，不开始播放；失败或取消原样抛出。
    func prepare(_ request: VAPPlaybackRequest) async throws
    /// 首次启动已经准备的相同请求。
    func play(_ request: VAPPlaybackRequest)
    /// 同步停下当前时间轴，不释放已准备内容。
    func pause()
    /// 仅用于已经启动过的请求恢复，不代替首次 play。
    func resume()
    /// 禁止后续业务回调并等待全部内核工作排空。
    func clearAndWait() async
}

/// 内核产生的少量控制事件；只在 MainActor 内传递，不携带可变 metadata。
enum VAPTransportEvent {
    /// 内核确认已进入运行态。
    case started
    /// 内核会话结束，原因决定自然完成还是取消。
    case finished(FinishReason)
    /// 内核报告不可恢复错误，由控制器映射为值错误。
    case failed(any Error)
}

/// 单请求 UIKit 播放桥；强持有 provider 与 delegate，自身不管理 SwiftUI 身份。
@MainActor
final class VAPViewTransport: VAPPlayerTransport, PlayerDelegate {
    /// 当前请求独占的内核，绝不跨请求重用迟到 delegate。
    private let player = PlayerView()
    /// 内核 provider 为弱引用，因此由本桥保留到物理清理结束。
    private let provider: (any DynamicContentProvider)?
    /// 事件转交闭包；clear 开始先清空，屏蔽清理产生的结束通知。
    private var onEvent: (@MainActor (VAPTransportEvent) -> Void)?

    /// 绑定本请求固定的 provider 和事件接收者，不开始读取资源。
    init(
        provider: (any DynamicContentProvider)?,
        onEvent: @escaping @MainActor (VAPTransportEvent) -> Void
    ) {
        self.provider = provider
        self.onEvent = onEvent
        player.delegate = self
        player.dynamicContentProvider = provider
    }

    /// 向宿主暴露本请求视图，不移交播放器所有权。
    var view: UIView { player }

    /// 直接应用静音，不因静音切换改变播放身份或进度。
    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    /// 等待实际 prepare 完成，metadata 仍由内核持有。
    func prepare(_ request: VAPPlaybackRequest) async throws {
        _ = try await player.prepare(url: request.url, options: request.options)
    }

    /// 首次调用 play 复用已经准备的相同 URL/options。
    func play(_ request: VAPPlaybackRequest) {
        player.play(url: request.url, options: request.options)
    }

    /// 保留内核时间轴位置并立即暂停声音。
    func pause() {
        player.pause()
    }

    /// 恢复已运行过的内核；是否允许恢复由控制器决定。
    func resume() {
        player.resume()
    }

    /// 先封闭回调，再等待内核排空，最终解除弱 provider/delegate 关联。
    func clearAndWait() async {
        onEvent = nil
        player.delegate = nil
        await player.clearAndWait()
        player.dynamicContentProvider = nil
    }

    /// 转交实际运行态，首次 started 去重由控制器完成。
    func playerDidStart(_ player: PlayerView) {
        onEvent?(.started)
    }

    /// metadata 回调不代表 GPU 与音频准备完成，必须等待 prepare 返回才发 ready。
    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata) {
        // 解析完成早于完整准备，因此这里故意不推进 SwiftUI 状态。
    }

    /// 转交内核终态；控制器先检查请求代次再结算。
    func playerDidFinish(_ player: PlayerView, reason: FinishReason) {
        onEvent?(.finished(reason))
    }

    /// 转交当前请求的错误，公开事件不直接保留任意 Error。
    func player(_ player: PlayerView, didFail error: any Error) {
        onEvent?(.failed(error))
    }
}

/// 只负责挂载与尺寸通知的透明宿主，不在 layout 回调内直接 prepare 或 play。
@MainActor
final class VAPSwiftUIHost: UIView {
    /// Coordinator 拥有控制器；宿主反向引用保持弱，避免相互保留。
    weak var controller: VAPPlayerController?

    /// 创建空透明容器，不创建 Metal 资源。
    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
    }

    /// 此容器仅供 SwiftUI 程序化创建，不支持 storyboard。
    required init?(coder: NSCoder) {
        return nil
    }

    /// 新窗口可能改变屏幕 scale 与可呈现性，统一通知控制器复核门条件。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshAvailability()
    }

    /// 子视图跟随当前 bounds；布局变化不重新创建播放器。
    override func layoutSubviews() {
        super.layoutSubviews()
        for child in subviews {
            child.frame = bounds
        }
        refreshAvailability()
    }

    /// 宿主真实入窗且尺寸有效时才允许进行有成本的准备。
    func refreshAvailability() {
        let isAvailable = window != nil
            && bounds.width.isFinite && bounds.height.isFinite
            && bounds.width > 0 && bounds.height > 0
        controller?.setPresentationAvailable(isAvailable)
    }

    /// 将新请求视图放入同一个宿主，首帧准备前先给予有效尺寸。
    func install(_ view: UIView) {
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
    }
}

/// SwiftUI 视图释放后的清理所有者；任务结束即移除，不依赖 deinit 发起工作。
@MainActor
enum VAPSwiftUIRetirementRegistry {
    /// 尚未物理排空的清理任务；只有 MainActor 可以添加与移除。
    private static var tasks: [UUID: Task<Void, Never>] = [:]

    /// 强持有清理闭包直到退出；返回句柄供仍存活的控制器等待。
    static func retain(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor in
            await operation()
            tasks[id] = nil
        }
        tasks[id] = task
        return task
    }
}
