import CoreMedia
import Foundation
import QuartzCore
import Testing
@testable import VAPPlayerKit

/// 覆盖旧元数据在播放入口的身份校验，包括路径、文件替换和 decoder 准备期间的改写。
@MainActor
struct PlaybackMetadataValidationTests {
    /// 其他 URL 的检查结果必须拒绝复用，手工构造的摘要也没有可播放凭证。
    @Test func rejectsDifferentURLAndManualSummary() async throws {
        let sourceURL = VAPFixture.defaultPlayableURL
        let metadata = try await AssetInspector().inspect(url: sourceURL)
        let differentURL = try #require(VAPFixture.playableURLs.first { $0 != sourceURL })
        let player = PlayerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        await #expect {
            try await player.prepare(url: differentURL, metadata: metadata)
        } throws: { error in
            (error as? PlaybackError)?.code == .invalidVapc
        }
        await player.clearAndWait()

        let manual = AssetMetadata(
            encodedVideoSize: metadata.encodedVideoSize,
            canvasSize: metadata.canvasSize,
            alphaMode: metadata.alphaMode,
            frameCount: metadata.frameCount,
            duration: metadata.duration,
            containsAudio: metadata.containsAudio,
            codec: metadata.codec
        )
        #expect(!manual.isReusableForPlayback)
    }

    /// 检查后修改文件时间，应在复用元数据的入口报 invalidMP4。
    @Test func rejectsChangedFileSignature() async throws {
        let fixture = try MetadataPlaybackFixture()
        defer { fixture.remove() }
        let metadata = try await AssetInspector().inspect(url: fixture.url)
        #expect(metadata.isReusableForPlayback)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: fixture.url.path
        )

        let player = PlayerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        await #expect {
            try await player.prepare(url: fixture.url, metadata: metadata)
        } throws: { error in
            (error as? PlaybackError)?.code == .invalidMP4
        }
        // 文件删除必须晚于准备和清理的真实结束，避免把测试清理变成另一场文件竞态。
        await player.clearAndWait()
    }

    /// 初次身份校验通过后，decoder 准备期间发生的文件改写仍须被第二次校验拦截。
    @Test func rejectsFileChangedDuringDecoderPreparation() async throws {
        let fixture = try MetadataPlaybackFixture()
        defer { fixture.remove() }
        let metadata = try await AssetInspector().inspect(url: fixture.url)
        let frameSource = MutatingMetadataFrameSource(
            metadata: FrameSourceMetadata(
                encodedVideoSize: metadata.encodedVideoSize,
                codec: metadata.codec
            )
        ) {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: 60)],
                ofItemAtPath: fixture.url.path
            )
        }
        let session = PlaybackSession(
            url: fixture.url,
            options: .init(),
            metalLayer: CAMetalLayer(),
            dynamicProvider: nil,
            frameSource: frameSource
        )
        await #expect {
            try await session.prepare(using: metadata)
        } throws: { error in
            (error as? PlaybackError)?.code == .invalidMP4
        }
        await session.clearAndWait()
    }

    /// 缓存 miss 的首次检查也必须在 decoder 改写文件后拒绝，不能只校验复用路径。
    @Test func freshInspectionRejectsFileChangedDuringDecoderPreparation() async throws {
        let fixture = try MetadataPlaybackFixture()
        defer { fixture.remove() }
        // 独占 URL 保证共享缓存没有命中；直接 inspector 只取 mock 轨道摘要，不填充缓存。
        let metadata = try await AssetInspector().inspect(url: fixture.url)
        let frameSource = MutatingMetadataFrameSource(
            metadata: FrameSourceMetadata(
                encodedVideoSize: metadata.encodedVideoSize,
                codec: metadata.codec
            )
        ) {
            // 改写发生在 session 自己的首次 inspection 返回后，精确控制待验证的竞态窗口。
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: 60)],
                ofItemAtPath: fixture.url.path
            )
        }
        let session = PlaybackSession(
            url: fixture.url,
            options: .init(),
            metalLayer: CAMetalLayer(),
            dynamicProvider: nil,
            frameSource: frameSource
        )
        await #expect {
            try await session.prepare()
        } throws: { error in
            (error as? PlaybackError)?.code == .invalidMP4
        }
        await session.clearAndWait()
    }

    /// 路径、大小和修改时间相同但文件身份已替换时，旧元数据仍必须失效。
    @Test func rejectsSameSizeAndDateReplacement() async throws {
        let fixture = try MetadataPlaybackFixture()
        defer { fixture.remove() }
        let metadata = try await AssetInspector().inspect(url: fixture.url)
        let expectedDate = try #require(metadata.sourceModificationDate)
        let expectedSize = try #require(metadata.sourceFileSize)
        let expectedIdentifier = try #require(metadata.sourceFileIdentifier)
        let replacementURL = fixture.directory.appendingPathComponent("replacement.mp4")

        // 先复制再替换，保证内容字节数不变，同时为替换文件建立新的文件身份。
        try FileManager.default.copyItem(at: VAPFixture.defaultPlayableURL, to: replacementURL)
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.moveItem(at: replacementURL, to: fixture.url)
        try FileManager.default.setAttributes([.modificationDate: expectedDate], ofItemAtPath: fixture.url.path)
        let values = try fixture.url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey
        ])
        #expect(Int64(try #require(values.fileSize)) == expectedSize)
        let actualDate = try #require(values.contentModificationDate)
        // 模拟器文件系统可能量化 setAttributes 写入的时间；生产签名校验仍保持严格相等。
        #expect(abs(actualDate.timeIntervalSince1970 - expectedDate.timeIntervalSince1970) <= 1)
        #expect(values.fileResourceIdentifier as? Data != expectedIdentifier)

        let player = PlayerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        await #expect {
            try await player.prepare(url: fixture.url, metadata: metadata)
        } throws: { error in
            (error as? PlaybackError)?.code == .invalidMP4
        }
        await player.clearAndWait()
    }
}

/// 每个身份校验用例独占的素材副本，不改动 bundle 中的共享 fixture。
private struct MetadataPlaybackFixture: Sendable {
    /// 独占临时目录，同时存放待播放文件和替换文件。
    let directory: URL
    /// 已复制的有效 VAP 文件，测试可以修改其身份或内容。
    let url: URL

    /// 创建独立目录并复制合法素材；文件系统失败时直接抛错。
    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vap-metadata-playback-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("asset.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: VAPFixture.defaultPlayableURL, to: url)
        } catch {
            // 初始化失败不会执行调用方 defer，必须在这里清除已创建的目录。
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// 排空被测 session 后删除独占目录；清理失败不掩盖原始测试结果。
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// 仅在 prepare 执行文件改写的不可变解码替身，不创建生产队列或媒体对象。
private final class MutatingMetadataFrameSource: FrameSource {
    /// 与 inspection 一致的轨道摘要，排除尺寸不符导致失败的干扰。
    private let metadata: FrameSourceMetadata
    /// 同步修改测试文件的操作；Sendable 保证它能跨隔离域执行。
    private let mutation: @Sendable () throws -> Void

    /// 指定轨道摘要和准备期间的文件修改动作。
    init(metadata: FrameSourceMetadata, mutation: @escaping @Sendable () throws -> Void) {
        self.metadata = metadata
        self.mutation = mutation
    }

    /// 完成指定文件改写后返回轨道摘要；文件系统错误向上传递。
    func prepare() async throws -> FrameSourceMetadata {
        try mutation()
        return metadata
    }

    /// 本替身只用于准备阶段的拒绝路径，不生产视频帧。
    func startProducing(
        to buffer: FrameRingBuffer,
        token: SessionToken,
        startTime: CMTime,
        frameIndexOffset: Int,
        didProduce: @escaping @Sendable (Int) -> Void,
        completion: @escaping @Sendable (Result<Void, PlaybackError>) -> Void
    ) {
        // 被测流程必须在 prepare 拒绝，进入生产阶段说明校验边界失效。
        Issue.record("文件身份已变更的 session 不应开始生产视频帧")
    }

    /// 替身没有后台工作，暂停不会改变文件改写行为。
    func pause() {}

    /// 替身没有后台工作，恢复无需提交额外任务。
    func resume() {}

    /// 所有操作都在 prepare 返回前结束，取消无需异步释放资源。
    func cancel() {}
}
