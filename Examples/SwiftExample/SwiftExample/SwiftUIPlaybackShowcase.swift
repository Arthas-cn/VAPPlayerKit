import Foundation
import SwiftUI
import VAPPlayerKit

/// 使用正式本地 fixture 验证 v2 SwiftUI 入口、显式透明布局与即时控制。
@MainActor
struct SwiftUIPlaybackShowcase: View {
    /// 目录中真实的左 Alpha 样本；nil 时只报告资源缺失，不伪造路径。
    let fixture: VAPFixture?
    /// 当前不可变请求；每次重播或改模式都创建新 ID。
    @State private var request: VAPPlaybackRequest? = nil
    /// 当前播放意图，与 VAPPlayerView 的系统暂停分别处理。
    @State private var intent: VAPPlaybackIntent = .playing
    /// 用户显式动作版本；普通重绘保持不变。
    @State private var controlRevision: UInt64 = 0
    /// 即时静音值，不需要更换请求或重新准备。
    @State private var isMuted = true
    /// 离页显式结束请求，不能靠页面视图缓存维持音频。
    @State private var isVisible = true
    /// true 合成显式 Alpha；false 显示完整编码帧作对照。
    @State private var usesPackedAlpha = true
    /// 背景明暗用于观察透明区域是否仍残留黑底。
    @State private var usesLightBackground = false
    /// 只显示当前请求的最近低频事件。
    @State private var status = "等待本地样本"

    /// 保存真实目录扫描结果，不在初始化时读取媒体或创建播放器。
    init(fixture: VAPFixture?) {
        self.fixture = fixture
    }

    /// 预览与控制保持同一稳定身份，切换意图不会重建播放器容器。
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("SwiftUI · 显式透明视频")
                    .font(.title2.bold())
                Text(fixture?.fileName ?? "Bundle 中缺少 alpha_left_moive.mp4")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                // 棋盘属于播放器下层，透明区域透出底色而不是由内核填黑。
                ZStack {
                    SwiftUICheckerboard(isLight: usesLightBackground)
                    VAPPlayerView(
                        resource: request,
                        intent: intent,
                        controlRevision: controlRevision,
                        isVisible: isVisible,
                        isMuted: isMuted,
                        onEvent: receive
                    )
                }
                .frame(height: 260)
                .clipShape(.rect(cornerRadius: 16))
                Text(status)
                    .font(.callout.monospaced())
                    .accessibilityIdentifier("swiftui.status")
                Text("编码帧 1504×448；颜色 [752,0,752,448]；Alpha [0,0,752,448]。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 对照模式改变资源配置，所以生成新请求，不能原位修改同一 ID。
                Toggle("显式 Alpha 合成（关闭查看原始拼接）", isOn: $usesPackedAlpha)
                    .accessibilityIdentifier("swiftui.packedAlpha")
                    .onChange(of: usesPackedAlpha) { replay() }
                Toggle("静音", isOn: $isMuted)
                    .accessibilityIdentifier("swiftui.mute")
                Toggle("浅色棋盘", isOn: $usesLightBackground)
                    .accessibilityIdentifier("swiftui.lightBackground")
                // 控制按钮只发送意图；暂停与恢复不会另建 UIKit 播放器。
                HStack {
                    Button("重播", systemImage: "play.fill", action: replay)
                        .accessibilityIdentifier("swiftui.replay")
                    Button("暂停", systemImage: "pause.fill") { control(.paused) }
                        .accessibilityIdentifier("swiftui.pause")
                    Button("恢复", systemImage: "playpause.fill") { control(.playing) }
                        .accessibilityIdentifier("swiftui.resume")
                    Button("停止", systemImage: "stop.fill") { control(.stopped) }
                        .accessibilityIdentifier("swiftui.stop")
                }
                .buttonStyle(.bordered)
                .disabled(fixture == nil)
                Text("退出或停止后请点重播。回前台后点恢复，不会自动解除系统暂停。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("SwiftUI 播放")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 首次显示才创建请求；后续状态变化由明确的按钮处理。
            if request == nil { replay() }
        }
        .onDisappear {
            // UIKit 导航页面退出时明确结束，不依赖 deinit 再创建清理任务。
            isVisible = false
            intent = .stopped
        }
    }

    /// 使用已验证样本的固定矩形构建新请求；缺资源时不开始播放。
    private func replay() {
        guard let fixture else {
            // 不能用猜测的 Bundle URL 把缺失资源伪装成播放失败。
            status = "缺少正式本地样本，未发起播放"
            return
        }
        let layout = PackedAlphaLayout(
            arrangement: .sideBySide,
            colorRect: VideoPixelRect(x: 752, y: 0, width: 752, height: 448),
            alphaRect: VideoPixelRect(x: 0, y: 0, width: 752, height: 448)
        )
        let options = PlaybackOptions(
            assetMode: usesPackedAlpha ? .packedAlpha(layout) : .ordinaryVideo,
            loopCount: 0,
            audioMode: .embedded,
            automaticallyResumesAfterSuspension: false
        )
        isVisible = true
        intent = .playing
        controlRevision &+= 1
        status = "准备本地样本"
        request = VAPPlaybackRequest(id: UUID(), url: fixture.url, options: options)
    }

    /// 发送用户动作并递增版本，用来区分显式恢复与普通 SwiftUI 重绘。
    private func control(_ newIntent: VAPPlaybackIntent) {
        intent = newIntent
        controlRevision &+= 1
    }

    /// 只接纳当前身份的事件，旧请求迟到结束不能覆盖新请求的状态。
    private func receive(_ event: VAPPlaybackEvent) {
        // 旧请求清理结束的事件可能晚于重播，不能覆盖新请求的状态。
        guard event.requestID == request?.id else { return }
        switch event.kind {
        // 宿主未入窗或零尺寸时不误显示为正在解码。
        case .waitingForPresentation: status = "等待窗口与有效尺寸"
        // prepare 阶段尚未开始时间轴。
        case .preparing: status = "正在准备"
        // ready 不代表肉眼已看见首帧。
        case .ready: status = "准备完成"
        // 首次运行态与后续恢复分开显示。
        case .started: status = "播放中"
        // 暂停保留具体原因，便于验证系统门没有被覆盖。
        case .paused(let reason): status = "已暂停：\(reason)"
        // 恢复沿用原请求与播放位置。
        case .resumed: status = "已恢复"
        // 终态 ID 不再复活，界面提示重播。
        case .finished(let reason): status = "已结束：\(reason)，可点重播"
        // 错误是可展示的纯值，不访问内部 UIKit 对象。
        case .failed(let error): status = "失败：\(error)"
        }
    }
}

/// SwiftUI 预览专用棋盘，显示透明合成后的背景透出效果。
private struct SwiftUICheckerboard: View {
    /// 浅色模式让黑底残留更容易被发现。
    let isLight: Bool

    /// 按当前容器尺寸绘制固定大小格子，不读取全局屏幕信息。
    var body: some View {
        // Canvas 在一个视图内绘制格子，避免为背景创建数百个子视图。
        Canvas { context, size in
            let side: CGFloat = 20
            let rows = Int(ceil(size.height / side))
            let columns = Int(ceil(size.width / side))
            for row in 0..<rows {
                for column in 0..<columns {
                    let alternates = (row + column).isMultiple(of: 2)
                    let brightness: Double = isLight ? (alternates ? 0.95 : 0.75) : (alternates ? 0.2 : 0.1)
                    let rectangle = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
                    context.fill(Path(rectangle), with: .color(Color(white: brightness)))
                }
            }
        }
    }
}
