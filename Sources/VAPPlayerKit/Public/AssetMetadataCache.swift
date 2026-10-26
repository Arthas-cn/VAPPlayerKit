import Foundation

/// 进程内的 metadata 缓存；actor 独占容量、LRU 与共享检查任务，不保存播放器或磁盘副本。
public actor AssetMetadataCache {
    /// 完整解析结果与是否命中缓存；复用值仍须在 decoder 准备前后核对文件身份。
    internal struct Resolution: Sendable {
        /// 本次使用的不可变 metadata、布局与纯值解码来源信息。
        let inspection: InspectionResult
        /// 缓存命中时的原始快照；新解析或等待共享检查时为 nil。
        let reusedMetadata: AssetMetadata?
    }

    /// 缓存身份包含完整布局，防止同一视频在不同矩形配置下串用。
    private struct Key: Hashable {
        /// 规范化本地文件路径，不包含网络下载身份。
        let url: URL
        /// 精确模式，packedAlpha 的全部整数参数参与 Hashable。
        let assetMode: PlaybackAssetMode
    }

    /// 一次共享检查；由等待它的 resolve 调用持有到真正完成，不随单个消费者取消。
    private struct Flight {
        /// 唯一任务身份，移除或替换后旧完成不得动到新任务。
        let id: UUID
        /// 创建时的全局失效代次；removeAll/禁用缓存会改变它。
        let generation: UUID
        /// 执行后台解析的任务句柄，不在 actor 内同步解析媒体。
        let task: Task<InspectionResult, Error>
    }

    /// 默认所有 PlayerView 共用此实例；宿主也可建立互不干扰的独立缓存。
    public static let shared = AssetMetadataCache()
    /// 最多保留的结果数，0 表示禁用结果缓存；通过 setCountLimit 修改。
    public private(set) var countLimit: Int
    /// 已验证后可复用的快照；容量受 countLimit 限制。
    private var entries: [Key: AssetMetadata] = [:]
    /// 从最旧到最近访问的顺序，与 entries 一一对应。
    private var accessOrder: [Key] = []
    /// 当前可共享的检查任务；失效移除只阻止复用，不冒充物理取消完成。
    private var inFlight: [Key: Flight] = [:]
    /// 全局失效标识，用 UUID 避免递增计数溢出或复用旧代次。
    private var generation = UUID()

    /// 创建独立缓存；默认最多 20 个结果，负容量按 0 处理，不读取文件。
    public init(countLimit: Int = 20) {
        self.countLimit = max(0, countLimit)
    }

    /// 设置容量并立即淘汰超额结果；0 同时使旧检查的回写失效，不取消已有消费者。
    public func setCountLimit(_ countLimit: Int) {
        self.countLimit = max(0, countLimit)
        // 禁用必须清空并换代，随后重新启用也不能接纳禁用前的旧完成。
        if self.countLimit == 0 {
            removeAll()
        } else {
            // 减小正容量只淘汰闲置 metadata，不改变正在运行的检查身份。
            trimToLimit()
        }
    }

    /// 清空全部结果并阻止现有检查回写；已有等待者仍会等到真实检查结束。
    public func removeAll() {
        generation = UUID()
        entries.removeAll()
        accessOrder.removeAll()
        inFlight.removeAll()
    }

    /// 移除此 URL 的所有模式/矩形缓存，并使相应旧检查失去回写资格。
    public func remove(url: URL) {
        // 非本地 URL 从不进入此缓存，无需建立无用失效记录。
        guard url.isFileURL else { return }
        let canonicalURL = url.standardizedFileURL
        entries = entries.filter { $0.key.url != canonicalURL }
        accessOrder.removeAll { $0.url == canonicalURL }
        inFlight = inFlight.filter { $0.key.url != canonicalURL }
    }

    /// 读取已有快照；不读磁盘，调用方在复用时仍需做签名校验。
    internal func metadata(for url: URL, assetMode: PlaybackAssetMode = .vap) -> AssetMetadata? {
        // 容量为零禁止命中，但并发 resolve 仍可合并同一时刻的检查。
        guard url.isFileURL, countLimit > 0 else { return nil }
        let key = Key(url: url.standardizedFileURL, assetMode: assetMode)
        // 未命中不会建立占位缓存，保持访问表和实际条目一致。
        guard let metadata = entries[key] else { return nil }
        touch(key)
        return metadata
    }

    /// 写入组件签发且模式匹配的快照；手工摘要、不同路径或不同布局直接忽略。
    internal func insert(_ metadata: AssetMetadata, for url: URL, assetMode: PlaybackAssetMode = .vap) {
        // provenance 必须一致；不能把一份 metadata 放到另一模式的缓存键下。
        guard url.isFileURL, metadata.isReusableForPlayback,
              metadata.sourceURL == url.standardizedFileURL,
              metadata.sourceAssetMode == assetMode else { return }
        let key = Key(url: url.standardizedFileURL, assetMode: assetMode)
        // 显式插入是更新值，旧检查完成不能再覆盖这一份结果。
        inFlight.removeValue(forKey: key)
        store(metadata, for: key)
    }

    /// 命中则校验文件，否则合并同 URL/完整模式的检查；取消者仍等待共享检查真实退出。
    internal func resolve(
        url: URL,
        inspector: AssetInspector,
        assetMode: PlaybackAssetMode = .vap
    ) async throws -> Resolution {
        try await resolve(url: url, assetMode: assetMode) {
            try await inspector.inspectDetails(url: url, assetMode: assetMode)
        }
    }

    /// 注入一次检查操作的内部入口，测试可用确定性门控制失效/完成交错，无需 sleep。
    internal func resolve(
        url: URL,
        assetMode: PlaybackAssetMode,
        operation: @escaping @Sendable () async throws -> InspectionResult
    ) async throws -> Resolution {
        try Task.checkCancellation()
        // 网络资源由宿主下载，缓存不能先为非法 URL 建立 flight。
        guard url.isFileURL else { throw PlaybackError.invalidURL }
        let key = Key(url: url.standardizedFileURL, assetMode: assetMode)
        // 缓存命中也必须检查当前文件签名，不能只凭 URL 返回过去的布局。
        if let cached = metadata(for: url, assetMode: assetMode) {
            do {
                let inspection = try Self.reusableInspection(from: cached, for: url, assetMode: assetMode)
                return Resolution(inspection: inspection, reusedMetadata: cached)
            } catch {
                // 文件已变化：只移除本次看到的快照，后续重新检查真实文件。
                removeCachedValue(cached, for: key)
            }
        }

        let flight: Flight
        if let existing = inFlight[key] {
            // 同代的所有消费者共享工作，不把某一方取消传播到其他消费者。
            flight = existing
        } else {
            // actor 在第一个 await 前登记任务；实际重工作由 inspector 的 @concurrent 承担。
            flight = Flight(id: UUID(), generation: generation, task: Task { try await operation() })
            inFlight[key] = flight
        }

        do {
            let inspection = try await flight.task.value
            finish(flight, for: key, result: inspection.metadata)
            // 先完成真实收尾再报告消费者取消，避免宿主提前释放其 N/文件 lease。
            try Task.checkCancellation()
            return Resolution(inspection: inspection, reusedMetadata: nil)
        } catch {
            // 失败与取消均按同一 flight 身份收口，不能清除后来启动的新任务。
            finish(flight, for: key, result: nil)
            throw error
        }
    }

    /// 从完整快照恢复内部布局；验证完整模式和当前文件身份，失败抛 PlaybackError。
    nonisolated internal static func reusableInspection(
        from metadata: AssetMetadata,
        for url: URL,
        assetMode: PlaybackAssetMode = .vap
    ) throws -> InspectionResult {
        // 手工摘要没有 provenance，或参数改变了任意一个透明矩形时，都不能跳过检查。
        guard metadata.isReusableForPlayback,
              metadata.sourceURL == url.standardizedFileURL,
              metadata.sourceAssetMode == assetMode,
              let document = metadata.playbackDocument else {
            throw PlaybackError.invalidVapc(reason: "AssetMetadata is not reusable for this file and asset mode.")
        }
        try validateReusableFileSignature(metadata, for: url)
        return InspectionResult(metadata: metadata, vapc: document, frameSourceContext: metadata.frameSourceContext)
    }

    /// 在 decoder 准备前后核对路径、inode、大小和修改时间，拒绝被替换或改写的文件。
    nonisolated internal static func validateReusableFileSignature(_ metadata: AssetMetadata, for url: URL) throws {
        // 缺失签名或不同 URL 不能当作“只少了一点摘要信息”继续播放。
        guard let expected = metadata.sourceSignature, expected.url == url.standardizedFileURL else {
            throw PlaybackError.invalidVapc(reason: "AssetMetadata has no matching local file identity.")
        }
        let actual = try AssetMetadata.SourceSignature.read(from: url)
        // 整体比较包含稳定文件标识，能识别大小/日期被对齐的替换文件。
        guard expected == actual else {
            throw PlaybackError.invalidMP4(reason: "AssetMetadata is stale because the local file changed.")
        }
    }

    /// 只移除仍对应这次读取的旧值，保持后来插入的新快照不受影响。
    private func removeCachedValue(_ metadata: AssetMetadata, for key: Key) {
        // 值身份变化意味着已有更新结果，不再删除。
        guard entries[key]?.inspectionID == metadata.inspectionID else { return }
        entries.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
    }

    /// 完成当前 flight；只有唯一身份与代次都匹配时才能收口并回写结果。
    private func finish(_ flight: Flight, for key: Key, result: AssetMetadata?) {
        // 失效/新任务已替换此 flight：旧完成只返回给原等待者，不动新缓存。
        guard flight.generation == generation, inFlight[key]?.id == flight.id else { return }
        inFlight.removeValue(forKey: key)
        // 失败没有值；解析结果必须有完整且匹配的 provenance 才可缓存。
        guard let result, result.isReusableForPlayback,
              result.sourceURL == key.url, result.sourceAssetMode == key.assetMode else { return }
        store(result, for: key)
    }

    /// 在容量允许时写入并更新 LRU；不持有当前播放实例。
    private func store(_ metadata: AssetMetadata, for key: Key) {
        // 禁用只禁止保存结果，不中断已经被消费者拥有的检查工作。
        guard countLimit > 0 else { return }
        entries[key] = metadata
        touch(key)
        trimToLimit()
    }

    /// 将键移到最近使用位置，避免重复条目膨胀访问列表。
    private func touch(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    /// 只保留容量内最近使用的快照；丢弃 metadata 不会停止任何播放会话。
    private func trimToLimit() {
        while entries.count > countLimit, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}
