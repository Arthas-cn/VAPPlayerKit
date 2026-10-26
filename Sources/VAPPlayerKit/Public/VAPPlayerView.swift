import SwiftUI

/// 稳定的 SwiftUI 播放入口；内部桥接 UIKit 内核，不下载资源或管理全局音频会话。
@MainActor
public struct VAPPlayerView: View {
    /// 当前窗口场景状态，不使用全进程屏幕状态推断可见性。
    @Environment(\.scenePhase) private var scenePhase
    /// nil 表示清空；相同 ID 的不可变内容必须保持一致。
    private let resource: VAPPlaybackRequest?
    /// 业务播放意图，与系统暂停分别保存。
    private let intent: VAPPlaybackIntent
    /// 显式控制命令版本；普通 SwiftUI 重绘不应递增。
    private let controlRevision: UInt64
    /// false 终结请求，恢复可见需要新请求 ID。
    private let isVisible: Bool
    /// 即时静音状态，准备开始之前就传给内核。
    private let isMuted: Bool
    /// 每个新请求接纳时强持有的 provider；同 ID 重绘不会替换它。
    private let dynamicContentProvider: (any DynamicContentProvider)?
    /// 低频事件接收者；在 MainActor 的后续工作项交付，避免重入 SwiftUI 更新。
    private let onEvent: @MainActor (VAPPlaybackEvent) -> Void

    /// 创建播放外壳；resource 的本地文件须保持可读直到请求结束并排空。
    /// 同 ID 不可改 URL/options；系统暂停后以 playing 加递增 controlRevision 恢复。
    /// 内核自动恢复被关闭，backgroundPolicy 固定为 suspend；其他播放配置保持原值。
    public init(
        resource: VAPPlaybackRequest?,
        intent: VAPPlaybackIntent = .playing,
        controlRevision: UInt64 = 0,
        isVisible: Bool = true,
        isMuted: Bool = false,
        dynamicContentProvider: (any DynamicContentProvider)? = nil,
        onEvent: @escaping @MainActor (VAPPlaybackEvent) -> Void
    ) {
        self.resource = resource
        self.intent = intent
        self.controlRevision = controlRevision
        self.isVisible = isVisible
        self.isMuted = isMuted
        self.dynamicContentProvider = dynamicContentProvider
        self.onEvent = onEvent
    }

    /// 使用稳定 representable 身份转交输入；布局由外部 SwiftUI 容器决定。
    public var body: some View {
        // 所有格式状态都留在同一个宿主中，不能随 intent 切换不同 View 分支。
        VAPPlayerRepresentable(
            resource: resource,
            intent: intent,
            controlRevision: controlRevision,
            isVisible: isVisible,
            isMuted: isMuted,
            isSceneActive: scenePhase == .active,
            dynamicContentProvider: dynamicContentProvider,
            onEvent: onEvent
        )
    }
}

/// UIKit 宿主的 SwiftUI 桥接层；Coordinator 在普通重绘间持有同一控制器。
@MainActor
private struct VAPPlayerRepresentable: UIViewRepresentable {
    /// 本次外部输入；nil 表示结束并清空。
    let resource: VAPPlaybackRequest?
    /// 当前业务动作，不直接传给内核绕过控制器。
    let intent: VAPPlaybackIntent
    /// 显式控制版本，用来识别恢复系统暂停的命令。
    let controlRevision: UInt64
    /// 宿主声明的实际可见性。
    let isVisible: Bool
    /// 当前静音值，允许同 ID 更新。
    let isMuted: Bool
    /// 当前 SwiftUI 场景是否 active。
    let isSceneActive: Bool
    /// 新请求接纳时固定的动态内容提供者。
    let dynamicContentProvider: (any DynamicContentProvider)?
    /// 当前请求接纳时固定的业务事件回调。
    let onEvent: @MainActor (VAPPlaybackEvent) -> Void

    /// 创建稳定控制器，此时不创建播放器、不准备文件。
    func makeCoordinator() -> VAPPlayerController {
        VAPPlayerController()
    }

    /// 创建透明容器并绑定观察，真实播放器要等展示条件满足才创建。
    func makeUIView(context: Context) -> VAPSwiftUIHost {
        let host = VAPSwiftUIHost()
        context.coordinator.attach(to: host)
        return host
    }

    /// 转交值变化；相同请求的重绘不会创建第二个会话。
    func updateUIView(_ uiView: VAPSwiftUIHost, context: Context) {
        context.coordinator.update(
            resource: resource,
            intent: intent,
            controlRevision: controlRevision,
            isVisible: isVisible,
            isMuted: isMuted,
            isSceneActive: isSceneActive,
            dynamicContentProvider: dynamicContentProvider,
            onEvent: onEvent
        )
        uiView.refreshAvailability()
    }

    /// 同步禁止迟到播放，异步清理由独立 registry 强持有到真实结束。
    static func dismantleUIView(_ uiView: VAPSwiftUIHost, coordinator: VAPPlayerController) {
        coordinator.dismantle()
        uiView.controller = nil
    }
}
