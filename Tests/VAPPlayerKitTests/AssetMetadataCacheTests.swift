import CoreGraphics
import Foundation
import Testing
@testable import VAPPlayerKit

/// 验证完整布局身份、缓存失效交错与共享检查的物理完成边界；每例使用独立缓存/临时目录。
struct AssetMetadataCacheTests {
    /// 同一检查结果可复用为等值快照，完整模式不同则必须重新检查。
    @Test func cachedResultUsesValueIdentityAndFullMode() async throws {
        let fixture = try MetadataFileFixture()
        defer { fixture.remove() }
        let cache = AssetMetadataCache()
        let original = try fixture.inspection()
        let first = try await cache.resolve(url: fixture.url, assetMode: .vap) { original }
        let second = try await cache.resolve(url: fixture.url, assetMode: .vap) {
            Issue.record("An unchanged cached file should not be inspected again.")
            return original
        }
        #expect(first.inspection.metadata == second.inspection.metadata)
        #expect(first.reusedMetadata == nil)
        #expect(second.reusedMetadata == original.metadata)

        let ordinary = try fixture.inspection(assetMode: .ordinaryVideo)
        let third = try await cache.resolve(url: fixture.url, assetMode: .ordinaryVideo) { ordinary }
        #expect(third.reusedMetadata == nil)
        #expect(third.inspection.metadata.inspectionID != first.inspection.metadata.inspectionID)
    }

    /// 同 URL 的不同透明矩形各自缓存，remove(url:) 一次清除所有布局。
    @Test func layoutsHaveSeparateEntriesAndURLWideInvalidation() async throws {
        let fixture = try MetadataFileFixture()
        defer { fixture.remove() }
        let cache = AssetMetadataCache()
        let firstMode = fixture.packedMode(colorWidth: 5)
        let secondMode = fixture.packedMode(colorWidth: 7)
        let first = try fixture.inspection(assetMode: firstMode)
        let second = try fixture.inspection(assetMode: secondMode)
        await cache.insert(first.metadata, for: fixture.url, assetMode: firstMode)
        await cache.insert(second.metadata, for: fixture.url, assetMode: secondMode)
        #expect(await cache.metadata(for: fixture.url, assetMode: firstMode) == first.metadata)
        #expect(await cache.metadata(for: fixture.url, assetMode: secondMode) == second.metadata)
        #expect {
            try AssetMetadataCache.reusableInspection(from: first.metadata, for: fixture.url, assetMode: secondMode)
        } throws: { error in
            (error as? PlaybackError)?.code == .invalidVapc
        }
        await cache.remove(url: fixture.url)
        #expect(await cache.metadata(for: fixture.url, assetMode: firstMode) == nil)
        #expect(await cache.metadata(for: fixture.url, assetMode: secondMode) == nil)
    }

    /// 失效后启动的新检查获胜；旧检查迟到结束不能回写或删除新一代结果。
    @Test(arguments: CacheInvalidation.allCases)
    private func staleFlightCannotOverwriteNewInspection(_ invalidation: CacheInvalidation) async throws {
        let fixture = try MetadataFileFixture()
        defer { fixture.remove() }
        let cache = AssetMetadataCache()
        let gate = InspectionGate()
        let old = try fixture.inspection()
        let current = try fixture.inspection()
        let first = Task {
            try await cache.resolve(url: fixture.url, assetMode: .vap) {
                await gate.run(returning: old)
            }
        }
        await gate.waitUntilStarted()
        await invalidation.apply(to: cache, url: fixture.url)
        let second = try await cache.resolve(url: fixture.url, assetMode: .vap) { current }
        await gate.release()
        let oldResult = try await first.value
        #expect(oldResult.inspection.metadata == old.metadata)
        #expect(second.inspection.metadata == current.metadata)
        #expect(await cache.metadata(for: fixture.url) == current.metadata)
    }

    /// 一个消费者取消不取消共享检查；其 CancellationError 只能在实际检查结束后返回。
    @Test func cancellationKeepsSharedWorkAliveUntilCompletion() async throws {
        let fixture = try MetadataFileFixture()
        defer { fixture.remove() }
        let cache = AssetMetadataCache()
        let gate = InspectionGate()
        let original = try fixture.inspection()
        let cancelled = Task {
            try await cache.resolve(url: fixture.url, assetMode: .vap) {
                await gate.run(returning: original)
            }
        }
        await gate.waitUntilStarted()
        cancelled.cancel()
        let survivor = Task {
            try await cache.resolve(url: fixture.url, assetMode: .vap) {
                Issue.record("Cancelling one waiter must not discard the existing flight.")
                return original
            }
        }
        await gate.release()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let result = try await survivor.value
        #expect(result.inspection.metadata == original.metadata)
        #expect(await gate.runCount == 1)
        #expect(await cache.metadata(for: fixture.url) == original.metadata)
    }

    /// 容量按最近使用淘汰；设为零后禁止写入，重新启用也没有旧缓存残留。
    @Test func capacityUsesLRUAndZeroDisablesStorage() async throws {
        let fixture = try MetadataFileFixture()
        defer { fixture.remove() }
        let cache = AssetMetadataCache(countLimit: 2)
        let modes = [fixture.packedMode(colorWidth: 3), fixture.packedMode(colorWidth: 5), fixture.packedMode(colorWidth: 7)]
        let first = try fixture.inspection(assetMode: modes[0])
        let second = try fixture.inspection(assetMode: modes[1])
        let third = try fixture.inspection(assetMode: modes[2])
        await cache.insert(first.metadata, for: fixture.url, assetMode: modes[0])
        await cache.insert(second.metadata, for: fixture.url, assetMode: modes[1])
        _ = await cache.metadata(for: fixture.url, assetMode: modes[0])
        await cache.insert(third.metadata, for: fixture.url, assetMode: modes[2])
        #expect(await cache.metadata(for: fixture.url, assetMode: modes[0]) == first.metadata)
        #expect(await cache.metadata(for: fixture.url, assetMode: modes[1]) == nil)
        await cache.setCountLimit(0)
        await cache.insert(first.metadata, for: fixture.url, assetMode: modes[0])
        #expect(await cache.metadata(for: fixture.url, assetMode: modes[0]) == nil)
        await cache.setCountLimit(2)
        #expect(await cache.metadata(for: fixture.url, assetMode: modes[2]) == nil)
    }

    /// 手工摘要即使字段完整，也没有可播放 provenance，不能进入缓存或绕过 inspection。
    @Test func manualSummaryIsNeverReusable() async throws {
        let fixture = try MetadataFileFixture()
        defer { fixture.remove() }
        let cache = AssetMetadataCache()
        let summary = AssetMetadata(
            encodedVideoSize: CGSize(width: 40, height: 20),
            canvasSize: CGSize(width: 20, height: 20),
            alphaMode: .left,
            frameCount: 1,
            duration: 1,
            containsAudio: false,
            codec: "h264"
        )
        #expect(summary.isReusableForPlayback == false)
        await cache.insert(summary, for: fixture.url)
        #expect(await cache.metadata(for: fixture.url) == nil)
        #expect {
            try AssetMetadataCache.reusableInspection(from: summary, for: fixture.url)
        } throws: { error in
            (error as? PlaybackError)?.code == .invalidVapc
        }
    }

    /// 同路径文件被另一 inode 替换，即使大小/日期相同，缓存仍必须重新检查。
    @Test func replacementWithSameSizeAndDateInvalidatesMetadata() async throws {
        let fixture = try MetadataFileFixture()
        defer { fixture.remove() }
        let cache = AssetMetadataCache()
        let original = try fixture.inspection()
        await cache.insert(original.metadata, for: fixture.url)
        let expectedDate = try #require(original.metadata.sourceModificationDate)
        let replacement = fixture.directory.appendingPathComponent("replacement.mp4")
        try Data("fixture".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.moveItem(at: replacement, to: fixture.url)
        try FileManager.default.setAttributes([.modificationDate: expectedDate], ofItemAtPath: fixture.url.path)
        #expect {
            try AssetMetadataCache.validateReusableFileSignature(original.metadata, for: fixture.url)
        } throws: { error in
            (error as? PlaybackError)?.code == .invalidMP4
        }
        let updated = try fixture.inspection()
        let result = try await cache.resolve(url: fixture.url, assetMode: .vap) { updated }
        #expect(result.reusedMetadata == nil)
        #expect(result.inspection.metadata == updated.metadata)
    }

    /// 实际 fixture 的只读检查结果可以经过全局相同解析路径命中，不创建 renderer 或播放器。
    @Test func realInspectionCanBeReusedWithoutPlayback() async throws {
        let cache = AssetMetadataCache()
        let url = VAPFixture.defaultPlayableURL
        let first = try await cache.resolve(url: url, inspector: AssetInspector())
        let second = try await cache.resolve(url: url, inspector: AssetInspector())
        #expect(first.inspection.metadata.isReusableForPlayback)
        #expect(second.reusedMetadata == first.inspection.metadata)
        #expect(first.inspection.metadata == second.inspection.metadata)
    }
}

/// 三种需要阻止旧 flight 回写的宿主操作，用同一交错覆盖各入口。
private enum CacheInvalidation: CaseIterable, Sendable {
    /// 只使当前文件及其全部布局失效。
    case removeURL
    /// 清空所有缓存并更换全局代次。
    case removeAll
    /// 禁用后重新启用，旧任务仍不能回到新一代缓存。
    case disableAndReenable

    /// 在旧检查挂起期间执行失效，不取消其已经拥有的文件工作。
    func apply(to cache: AssetMetadataCache, url: URL) async {
        switch self {
        // 单 URL 移除必须覆盖全部布局身份。
        case .removeURL:
            await cache.remove(url: url)
        // 全清使所有当前 flight 失去回写资格。
        case .removeAll:
            await cache.removeAll()
        // 容量恢复不等于恢复禁用前的缓存代次。
        case .disableAndReenable:
            await cache.setCountLimit(0)
            await cache.setCountLimit(20)
        }
    }
}

/// 提供真实磁盘身份与轻量合成 metadata；不伪装为视频解码测试。
private struct MetadataFileFixture: Sendable {
    /// 当前用例独占目录，测试结束整体回收。
    let directory: URL
    /// 非空普通文件，只用于签名/缓存竞态测试。
    let url: URL

    /// 建立唯一目录和短文件，文件系统失败使当前测试立即失败。
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vap-cache-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("asset.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
    }

    /// 产生不同颜色宽度的合法配置，证明完整布局参与缓存身份。
    func packedMode(colorWidth: Int) -> PlaybackAssetMode {
        .packedAlpha(PackedAlphaLayout(
            arrangement: .sideBySide,
            colorRect: VideoPixelRect(x: 0, y: 0, width: colorWidth, height: 11),
            alphaRect: VideoPixelRect(x: 20, y: 0, width: 13, height: 9)
        ))
    }

    /// 以当前磁盘身份建立可信的内部测试结果，保留模式与实际渲染布局一致。
    func inspection(assetMode: PlaybackAssetMode = .vap) throws -> InspectionResult {
        let encodedSize = CGSize(width: 40, height: 20)
        let colorRect: CGRect
        let alphaRect: CGRect
        let alphaMode: AlphaMode
        let resolvedMode: ResolvedAssetMode
        switch assetMode {
        // 显式透明测试直接沿用原始矩形，验证缓存不会对参数降维。
        case let .packedAlpha(layout):
            colorRect = layout.colorRect.cgRect
            alphaRect = layout.alphaRect.cgRect
            alphaMode = try layout.validatedAlphaMode(in: encodedSize)
            resolvedMode = .vap
        // 普通测试文档使用全帧且无透明区域。
        case .ordinaryVideo:
            colorRect = CGRect(origin: .zero, size: encodedSize)
            alphaRect = .zero
            alphaMode = .none
            resolvedMode = .ordinaryVideo
        // 自动/显式 VAP 的合成测试值统一使用左 Alpha，真实检测另由 fixture 测试覆盖。
        case .automatic, .vap:
            colorRect = CGRect(x: 20, y: 0, width: 20, height: 20)
            alphaRect = CGRect(x: 0, y: 0, width: 20, height: 20)
            alphaMode = .left
            resolvedMode = .vap
        }
        let document = VapcDocument(
            assetMode: resolvedMode, version: 0, canvasSize: colorRect.size,
            alphaMode: alphaMode, frameCount: 1, framesPerSecond: 1,
            encodedVideoSize: encodedSize, rgbRect: colorRect, alphaRect: alphaRect,
            sources: [], frames: [:]
        )
        let metadata = AssetMetadata(
            document: document, duration: 1, containsAudio: false, codec: "h264",
            sourceSignature: try AssetMetadata.SourceSignature.read(from: url),
            sourceAssetMode: assetMode, frameSourceContext: nil
        )
        return InspectionResult(metadata: metadata, vapc: document, frameSourceContext: nil)
    }

    /// 尽力清除本用例目录，不影响其他并行测试。
    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 可控的真实工作门；测试只在明确收到开始信号后失效/取消，不依赖 sleep。
private actor InspectionGate {
    /// 实际进入检查操作的次数，用于断言共享 flight 没有重复工作。
    private(set) var runCount = 0
    /// 检查开始前等待信号的测试 continuation。
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    /// 模拟未结束的实际检查任务，放行前不能返回。
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    /// 是否已经放行，避免先 release 再 await 时丢失信号。
    private var released = false

    /// 标记真实检查已开始并等待测试放行，返回预设的不可变结果。
    func run(returning inspection: InspectionResult) async -> InspectionResult {
        runCount += 1
        let starts = startWaiters
        startWaiters.removeAll()
        for waiter in starts { waiter.resume() }
        // 保留不合作取消工作，验证宿主不会把取消标记当成物理结束。
        if !released {
            await withCheckedContinuation { finishWaiters.append($0) }
        }
        return inspection
    }

    /// 等到检查确实进入，已进入时立即返回。
    func waitUntilStarted() async {
        // 开始信号是持久状态，不靠瞬时事件或调度先后猜测。
        guard runCount == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    /// 放行全部实际检查任务，重复调用为空操作。
    func release() {
        released = true
        let finishes = finishWaiters
        finishWaiters.removeAll()
        for waiter in finishes { waiter.resume() }
    }
}
