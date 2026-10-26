import Foundation
import QuartzCore

/// 单次 session 的准备阶段；每个异步结果都必须通过当前状态门。
extension PlaybackSession {
    /// 走全局缓存的 prepare 入口。
    func prepare() async throws -> AssetMetadata {
        try await prepare(using: nil)
    }

    /// 准备解码、动态内容和渲染管线，但不自动开播。
    ///
    /// `suppliedMetadata` 非空时，复用该对象携带的不可变 vapc 布局，跳过 MP4/vapc
    /// 再解析，并把它写入全局 `AssetMetadataCache`。为空时走全局缓存：命中则复用，
    /// miss 则 inspection，同一 URL 的并发 miss 会合并为一次解析。
    ///
    /// 解码轨准备仍会执行。所有路径在取得 inspection 时、decoder prepare 后以及
    /// 返回 ready 前核对文件签名，避免首次检查或复用期间被替换的媒体进入渲染器。
    func prepare(using suppliedMetadata: AssetMetadata?) async throws -> AssetMetadata {
        // 一个 session 只有一项准备；其他等待者共享结果，停止后不能重新建立管线。
        if let preparationTask { return try await preparationTask.value }
        let task = Task { @MainActor in try await self.prepareBody(using: suppliedMetadata) }
        preparationTask = task
        defer { preparationTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    /// 执行实际准备，各暂停点之后确认 session 仍有接纳结果的资格。
    func prepareBody(using suppliedMetadata: AssetMetadata?) async throws -> AssetMetadata {
        try Task.checkCancellation()
        guard state == .idle else {
            if let metadata, state == .ready { return metadata }
            throw PlaybackError.cancelled
        }
        try options.validate()
        state = .preparing
        prepareStartedAt = CACurrentMediaTime()
        do {
            let inspectionStartedAt = CACurrentMediaTime()
            let inspection: InspectionResult
            if let suppliedMetadata {
                inspection = try AssetMetadataCache.reusableInspection(
                    from: suppliedMetadata,
                    for: url,
                    assetMode: options.assetMode
                )
                await AssetMetadataCache.shared.insert(suppliedMetadata, for: url, assetMode: options.assetMode)
            } else {
                let resolution = try await AssetMetadataCache.shared.resolve(
                    url: url,
                    inspector: inspector,
                    assetMode: options.assetMode
                )
                inspection = resolution.inspection
            }
            metricsSink?.record(.prepareStageDuration("inspection", CACurrentMediaTime() - inspectionStartedAt))
            try ensureActive()
            let frameSourceStartedAt = CACurrentMediaTime()
            let sourceMetadata = try await frameSource.prepare(using: inspection.frameSourceContext)
            metricsSink?.record(.prepareStageDuration("frame_source", CACurrentMediaTime() - frameSourceStartedAt))
            try ensureActive()
            // 首次检查也可能在 decoder 打开期间被替换，不能只给缓存命中的路径验签。
            try AssetMetadataCache.validateReusableFileSignature(inspection.metadata, for: url)
            guard approximatelyEqual(sourceMetadata.encodedVideoSize, inspection.metadata.encodedVideoSize),
                  sourceMetadata.codec == inspection.metadata.codec else {
                throw PlaybackError.invalidMP4(reason: "Inspector and decoder track descriptions disagree.")
            }
            let rendererStartedAt = CACurrentMediaTime()
            try await renderer.prepare(layer: metalLayer)
            metricsSink?.record(.prepareStageDuration("renderer", CACurrentMediaTime() - rendererStartedAt))
            try ensureActive()
            let dynamicStartedAt = CACurrentMediaTime()
            do {
                dynamicSnapshot = try await dynamicResolver.resolve(
                    sources: inspection.vapc.sources,
                    imagePlayback: options.dynamicImagePlaybackMode,
                    textOverflow: options.dynamicTextOverflowMode
                )
                metricsSink?.record(.dynamicResolveDuration(CACurrentMediaTime() - dynamicStartedAt))
                metricsSink?.record(.prepareStageDuration("dynamic_resolve", CACurrentMediaTime() - dynamicStartedAt))
            } catch {
                if (error as? PlaybackError)?.code == .dynamicContentTimeout {
                    metricsSink?.record(.dynamicTimeout)
                }
                throw error
            }
            try ensureActive()
            let dynamicUploadStartedAt = CACurrentMediaTime()
            try await renderer.prepareDynamic(dynamicSnapshot)
            metricsSink?.record(.prepareStageDuration("dynamic_upload", CACurrentMediaTime() - dynamicUploadStartedAt))
            try ensureActive()
            animatedPlayback.prepare(snapshot: dynamicSnapshot, renderer: renderer)
            marqueePlayback.prepare(
                snapshot: dynamicSnapshot,
                renderer: renderer,
                speed: options.marqueeSpeed,
                startDelay: options.marqueeStartDelay
            )
            try ensureActive()
            let audioStartedAt = CACurrentMediaTime()
            try await audioCoordinator.prepare(
                url: url,
                mode: options.audioMode,
                containsAudio: inspection.metadata.containsAudio
            )
            metricsSink?.record(.prepareStageDuration("audio", CACurrentMediaTime() - audioStartedAt))
            try ensureActive()
            // 首次检查和复用都覆盖动态内容/音频的异步窗口，文件改写后不能返回 ready。
            try AssetMetadataCache.validateReusableFileSignature(inspection.metadata, for: url)
            self.inspection = inspection
            metadata = inspection.metadata
            state = .ready
            metricsSink?.record(.prepareDuration(CACurrentMediaTime() - prepareStartedAt))
            onMetadata?(inspection.metadata)
            return inspection.metadata
        } catch {
            // 主动取消不伪装成解码失败；已发终态时 stop/fail 都是幂等的。
            if error is CancellationError || (error as? PlaybackError) == .cancelled {
                stop(reason: .cancelled)
            } else {
                fail(error)
            }
            throw error
        }
    }

}
