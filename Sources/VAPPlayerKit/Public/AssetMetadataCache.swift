import CryptoKit
import Foundation

/// 全局共享的 `AssetMetadata` 进程内内存缓存。
///
/// 播放准备阶段最昂贵的一步是 MP4 / vapc inspection。相同本地 URL 被多个
/// `PlayerView` 连续或并发播放时，本缓存复用组件自己解析出的、带完整播放布局
/// 和文件签名的 metadata，避免重复解析。
///
/// 设计约束：
/// - 只缓存本组件解析出的可复用对象；宿主手工构造的摘要 metadata 不会入缓存。
/// - 只接受本地 `file://` URL；网络资源由宿主自行下载后再交给播放器。
/// - 只存在于当前进程内存，不写磁盘，也不缓存解码器、sample buffer 或 GPU 资源；仅保留 AVFoundation 元数据上下文。
/// - 命中后仍会校验文件 identity、大小和修改时间；签名变化会丢弃旧值并重新解析。
/// - 所有 `PlayerView` 共享同一个实例；公开 API 线程安全。
@objc(VPKAssetMetadataCache)
public final class AssetMetadataCache: NSObject {
    /// `resolve` 的内部结果：始终携带可播放的 inspection，并标明是否来自缓存复用。
    ///
    /// `reusedMetadata != nil` 时，调用方应在解码轨准备前后再次校验文件签名，
    /// 防止 inspection 到 decoder prepare 之间文件被替换。
    internal struct Resolution {
        /// 本次播放使用的 inspection 结果（metadata + vapc 布局）。
        let inspection: InspectionResult
        /// 命中缓存时为被复用的同一 metadata 实例；本次重新解析则为 `nil`。
        let reusedMetadata: AssetMetadata?
    }

    /// 用于判断「进行中的 inspection 是否仍然有效」的代数。
    ///
    /// `removeAll()` 或把 `countLimit` 设为 0 会递增全局代数；对某个 URL 的
    /// `remove(url:)` 在该 URL 仍有 in-flight 任务时会递增 URL 代数。
    /// in-flight 任务完成写入前会对比代数，过期结果不会污染缓存。
    private struct Generation: Equatable {
        /// 全局清空 / 禁用次数。
        let global: UInt64
        /// 该 URL 被主动移除的次数。
        let url: UInt64
    }

    /// 同一规范化 URL 上正在进行的 inspection。
    ///
    /// 多个并发 `resolve` 共享同一个 `Task`，避免 cache miss 时重复执行昂贵解析。
    /// 代数不同的 in-flight 不能互相复用：旧任务的结果可能已被宿主主动失效。
    private final class InFlight {
        /// 实际执行 `AssetInspector.inspectDetails` 的异步任务。
        let task: Task<InspectionResult, Error>
        /// 任务创建时捕获的缓存代数。
        let generation: Generation

        init(task: Task<InspectionResult, Error>, generation: Generation) {
            self.task = task
            self.generation = generation
        }
    }

    /// 所有 `PlayerView` 共享的缓存实例。宿主也可直接读写容量或主动清理。
    @objc(sharedCache)
    public static let shared = AssetMetadataCache()

    /// 以规范化 URL 的 SHA-256 为键存放可复用 metadata。
    ///
    /// `NSCache` 在内存压力下可能自行驱逐对象，因此命中失败必须能回退到重新解析。
    private let cache = NSCache<NSString, AssetMetadata>()
    /// 保护容量、代数和 in-flight 表。`NSCache` 自身线程安全，但这些附属状态不是。
    private let lock = NSLock()
    /// 宿主可见的容量上限。`0` 表示禁用缓存；与 `NSCache.countLimit` 分离，
    /// 因为 `NSCache` 把 `0` 解释为「无限制」。
    private var storedCountLimit = 20
    /// 全局清空或禁用时递增，使所有未完成 inspection 的写入失效。
    private var globalMutationGeneration: UInt64 = 0
    /// 按缓存键记录该 URL 被主动移除的次数。无 in-flight 时不必保留条目。
    private var urlMutationGenerations: [String: UInt64] = [:]
    /// 每个缓存键上、按代数分组的进行中 inspection。同一代数只保留一条可共享任务。
    private var inFlight: [String: [InFlight]] = [:]

    /// 缓存最多保留的 metadata 数量，默认 20。
    ///
    /// 设置为 `0` 会立即禁用并清空缓存，进行中的 inspection 结果也不会再写入。
    /// 负值会被钳制为 `0`。底层 `NSCache.countLimit` 最少为 1，避免被当成无限制。
    @objc public var countLimit: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedCountLimit
        }
        set {
            lock.lock()
            storedCountLimit = max(0, newValue)
            cache.countLimit = max(1, storedCountLimit)
            if storedCountLimit == 0 {
                globalMutationGeneration &+= 1
                cache.removeAllObjects()
                inFlight.removeAll()
                urlMutationGenerations.removeAll()
            }
            lock.unlock()
        }
    }

    /// 单例专用。外部应使用 `shared`，不要再创建独立实例。
    private override init() {
        super.init()
        cache.countLimit = storedCountLimit
    }

    /// 清空全部 metadata，并使所有进行中的 inspection 写入失效。
    @objc(removeAll)
    public func removeAll() {
        lock.lock()
        globalMutationGeneration &+= 1
        cache.removeAllObjects()
        inFlight.removeAll()
        urlMutationGenerations.removeAll()
        lock.unlock()
    }

    /// 移除指定本地 URL 对应的 metadata。
    ///
    /// 非文件 URL 会被忽略。若该 URL 仍有 in-flight inspection，会递增 URL 代数，
    /// 避免稍后把已失效的解析结果重新写回缓存。
    @objc(removeMetadataForURL:)
    public func remove(url: URL) {
        guard url.isFileURL else { return }
        lock.lock()
        for assetMode in Self.cacheAssetModes {
            let key = Self.key(for: url, assetMode: assetMode) as String
            if inFlight[key] != nil {
                urlMutationGenerations[key, default: 0] &+= 1
            }
            cache.removeObject(forKey: key as NSString)
        }
        lock.unlock()
    }

    /// 从缓存读取 metadata。仅供组件内部解析 / 测试使用。
    ///
    /// 禁用缓存、非文件 URL 或未命中时返回 `nil`。返回值仍需调用方做文件签名校验。
    internal func metadata(
        for url: URL,
        assetMode: PlaybackAssetMode = .automatic
    ) -> AssetMetadata? {
        guard url.isFileURL else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard storedCountLimit > 0 else { return nil }
        return cache.object(forKey: Self.key(for: url, assetMode: assetMode))
    }

    /// 写入组件解析出的可复用 metadata。
    ///
    /// 必须同时满足：本地文件 URL、`isReusableForPlayback == true`、
    /// `sourceURL` 与入参 URL 的规范化路径一致。手工摘要对象不会进入缓存。
    internal func insert(
        _ metadata: AssetMetadata,
        for url: URL,
        assetMode: PlaybackAssetMode = .automatic
    ) {
        guard url.isFileURL,
              metadata.isReusableForPlayback,
              metadata.sourceURL == url.standardizedFileURL else {
            return
        }
        lock.lock()
        store(metadata, for: url, assetMode: assetMode)
        lock.unlock()
    }

    /// 解析或复用指定 URL 的 inspection。
    ///
    /// 流程：
    /// 1. 非文件 URL 不走缓存，直接交给 inspector。
    /// 2. 命中缓存时校验文件签名；失效则丢弃该项并进入下一步。
    /// 3. cache miss 时合并同一 URL、同一代数上的并发请求，只执行一次 inspection。
    /// 4. 若 `makeFlight` 返回 `nil`（例如刚被另一线程写入），循环重试读缓存。
    internal func resolve(
        url: URL,
        inspector: AssetInspector,
        assetMode: PlaybackAssetMode = .automatic
    ) async throws -> Resolution {
        guard url.isFileURL else {
            let inspection = try await inspector.inspectDetails(url: url, assetMode: assetMode)
            return Resolution(inspection: inspection, reusedMetadata: nil)
        }

        while true {
            if let cachedMetadata = metadata(for: url, assetMode: assetMode) {
                do {
                    return Resolution(
                        inspection: try Self.reusableInspection(
                            from: cachedMetadata,
                            for: url,
                            assetMode: assetMode
                        ),
                        reusedMetadata: cachedMetadata
                    )
                } catch {
                    removeIfCurrent(cachedMetadata, for: url, assetMode: assetMode)
                }
            }

            let key = Self.key(for: url, assetMode: assetMode) as String
            guard let flight = makeFlight(
                for: key,
                url: url,
                inspector: inspector,
                assetMode: assetMode
            ) else {
                continue
            }
            do {
                let inspection = try await flight.task.value
                finish(key: key, flight: flight)
                return Resolution(inspection: inspection, reusedMetadata: nil)
            } catch {
                finish(key: key, flight: flight)
                throw error
            }
        }
    }

    /// 为当前代数创建或复用一条 in-flight inspection。
    ///
    /// 返回 `nil` 表示此时缓存里已经有对象，调用方应回到 `resolve` 循环再读一次。
    /// 这样可以消化「检查缓存」和「创建任务」之间被其他线程写入的竞态。
    private func makeFlight(
        for key: String,
        url: URL,
        inspector: AssetInspector,
        assetMode: PlaybackAssetMode
    ) -> InFlight? {
        lock.lock()
        defer { lock.unlock() }
        let generation = Generation(
            global: globalMutationGeneration,
            url: urlMutationGenerations[key, default: 0]
        )
        if let existing = inFlight[key]?.first(where: { $0.generation == generation }) {
            return existing
        }
        if storedCountLimit > 0,
           cache.object(forKey: key as NSString) != nil {
            return nil
        }
        let task = Task { [weak self] in
            let inspection = try await inspector.inspectDetails(url: url, assetMode: assetMode)
            self?.storeIfCurrent(
                inspection.metadata,
                for: url,
                assetMode: assetMode,
                generation: generation
            )
            return inspection
        }
        let flight = InFlight(task: task, generation: generation)
        inFlight[key, default: []].append(flight)
        return flight
    }

    /// 仅当缓存里仍是这份 metadata 时才移除，避免误删后来写入的更新值。
    private func removeIfCurrent(
        _ metadata: AssetMetadata,
        for url: URL,
        assetMode: PlaybackAssetMode
    ) {
        guard url.isFileURL else { return }
        let key = Self.key(for: url, assetMode: assetMode) as String
        lock.lock()
        guard cache.object(forKey: key as NSString) === metadata else {
            lock.unlock()
            return
        }
        if inFlight[key] != nil {
            urlMutationGenerations[key, default: 0] &+= 1
        }
        cache.removeObject(forKey: key as NSString)
        lock.unlock()
    }

    /// 把可复用 metadata 还原为 playback 所需的 `InspectionResult`。
    ///
    /// 会校验 URL 归属、内部 vapc 布局是否存在，以及磁盘上的文件签名是否仍匹配。
    /// 手工摘要或来自其他路径的 metadata 会抛出 `invalidVapc`。
    internal static func reusableInspection(
        from metadata: AssetMetadata,
        for url: URL,
        assetMode: PlaybackAssetMode = .automatic
    ) throws -> InspectionResult {
        guard metadata.sourceURL == url.standardizedFileURL,
              let document = metadata.playbackDocument else {
            throw PlaybackError.invalidVapc(
                reason: "AssetMetadata is not reusable or belongs to a different local URL."
            )
        }
        guard matches(document: document, requestedAssetMode: assetMode) else {
            throw PlaybackError.invalidVapc(
                reason: "AssetMetadata was prepared with a different asset mode."
            )
        }
        try validateReusableFileSignature(metadata, for: url)
        return InspectionResult(
            metadata: metadata,
            vapc: document,
            frameSourceContext: metadata.frameSourceContext
        )
    }

    /// 校验缓存 / 复用 metadata 是否仍对应磁盘上的同一份本地文件。
    ///
    /// 比较 `NSURLFileResourceIdentifierKey`（文件 identity）、大小和修改时间。
    /// identity 变化说明路径被替换成了另一个 inode；仅大小或时间变化则视为内容被改写。
    /// 签名字段缺失时拒绝复用，强制重新解析。
    internal static func validateReusableFileSignature(
        _ metadata: AssetMetadata,
        for url: URL
    ) throws {
        guard metadata.sourceURL == url.standardizedFileURL else {
            throw PlaybackError.invalidVapc(
                reason: "AssetMetadata is not reusable or belongs to a different local URL."
            )
        }
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        guard values.isRegularFile == true,
              let expectedSize = metadata.sourceFileSize,
              let actualSize = values.fileSize,
              let expectedDate = metadata.sourceModificationDate,
              let actualDate = values.contentModificationDate,
              let expectedIdentifier = metadata.sourceFileIdentifier,
              let actualIdentifier = values.fileResourceIdentifier as? Data else {
            throw PlaybackError.invalidMP4(reason: "AssetMetadata file signature is unavailable.")
        }
        if expectedIdentifier != actualIdentifier {
            throw PlaybackError.invalidMP4(reason: "AssetMetadata is stale because the file identity changed.")
        }
        if expectedSize != Int64(actualSize) {
            throw PlaybackError.invalidMP4(reason: "AssetMetadata is stale because the file size changed.")
        }
        if expectedDate != actualDate {
            throw PlaybackError.invalidMP4(reason: "AssetMetadata is stale because the file changed.")
        }
    }

    /// 在已持有 `lock` 的前提下写入缓存。容量为 0 时直接忽略。
    private func store(
        _ metadata: AssetMetadata,
        for url: URL,
        assetMode: PlaybackAssetMode
    ) {
        guard storedCountLimit > 0 else { return }
        cache.setObject(metadata, forKey: Self.key(for: url, assetMode: assetMode))
    }

    /// inspection 完成后，仅当代数未变化时才写入，避免覆盖宿主主动清理后的空缓存。
    private func storeIfCurrent(
        _ metadata: AssetMetadata,
        for url: URL,
        assetMode: PlaybackAssetMode,
        generation: Generation
    ) {
        lock.lock()
        let currentGeneration = Generation(
            global: globalMutationGeneration,
            url: urlMutationGenerations[Self.key(for: url, assetMode: assetMode) as String, default: 0]
        )
        if currentGeneration == generation {
            store(metadata, for: url, assetMode: assetMode)
        }
        lock.unlock()
    }

    /// 从 in-flight 表移除已结束的任务。该键没有剩余任务时一并丢掉 URL 代数，避免字典膨胀。
    private func finish(key: String, flight: InFlight) {
        lock.lock()
        guard var flights = inFlight[key] else {
            lock.unlock()
            return
        }
        flights.removeAll { $0 === flight }
        if flights.isEmpty {
            inFlight.removeValue(forKey: key)
            urlMutationGenerations.removeValue(forKey: key)
        } else {
            inFlight[key] = flights
        }
        lock.unlock()
    }

    private static func matches(
        document: VapcDocument,
        requestedAssetMode: PlaybackAssetMode
    ) -> Bool {
        switch requestedAssetMode {
        case .automatic:
            return true
        case .vap:
            return document.assetMode == .vap
        case .ordinaryVideo:
            return document.assetMode == .ordinaryVideo
        }
    }

    /// 用规范化 `file://` URL 的 SHA-256 作为缓存键。
    ///
    /// 标准化路径可合并 `/foo/../bar` 这类等价写法；哈希避免把完整路径明文作为键，
    /// 也避免超长路径带来的字典开销。
    private static let cacheAssetModes: [PlaybackAssetMode] = [
        .automatic,
        .vap,
        .ordinaryVideo
    ]

    private static func key(
        for url: URL,
        assetMode: PlaybackAssetMode
    ) -> NSString {
        let canonicalURL = url.standardizedFileURL
        let source = "\(canonicalURL.absoluteString)#asset-mode=\(assetMode.rawValue)"
        let digest = SHA256.hash(data: Data(source.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex as NSString
    }
}
