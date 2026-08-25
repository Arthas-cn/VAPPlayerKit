import CryptoKit
import Foundation

/// 全局共享的 AssetMetadata 内存缓存。
///
/// 缓存只保存本组件解析出的、带有完整播放布局和文件签名的 metadata。
/// 这是进程内缓存，不持久化到磁盘，也不会缓存解码器或视频帧。
@objc(VPKAssetMetadataCache)
public final class AssetMetadataCache: NSObject {
    internal struct Resolution {
        let inspection: InspectionResult
        let reusedMetadata: AssetMetadata?
    }

    private struct Generation: Equatable {
        let global: UInt64
        let url: UInt64
    }

    private final class InFlight {
        let task: Task<InspectionResult, Error>
        let generation: Generation

        init(task: Task<InspectionResult, Error>, generation: Generation) {
            self.task = task
            self.generation = generation
        }
    }

    /// 所有 PlayerView 共享的缓存实例。
    @objc(sharedCache)
    public static let shared = AssetMetadataCache()

    private let cache = NSCache<NSString, AssetMetadata>()
    private let lock = NSLock()
    private var storedCountLimit = 15
    private var globalMutationGeneration: UInt64 = 0
    private var urlMutationGenerations: [String: UInt64] = [:]
    private var inFlight: [String: [InFlight]] = [:]

    /// 缓存最多保留的 metadata 数量，默认 20。
    /// 设置为 0 会禁用并清空缓存。
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

    private override init() {
        super.init()
        cache.countLimit = storedCountLimit
    }

    /// 清理全部 metadata。
    @objc(removeAll)
    public func removeAll() {
        lock.lock()
        globalMutationGeneration &+= 1
        cache.removeAllObjects()
        inFlight.removeAll()
        urlMutationGenerations.removeAll()
        lock.unlock()
    }

    /// 清理指定本地 URL 对应的 metadata。
    @objc(removeMetadataForURL:)
    public func remove(url: URL) {
        guard url.isFileURL else { return }
        let key = Self.key(for: url) as String
        lock.lock()
        if inFlight[key] != nil {
            urlMutationGenerations[key, default: 0] &+= 1
        }
        cache.removeObject(forKey: key as NSString)
        lock.unlock()
    }

    /// 从缓存读取 metadata。仅供组件内部的解析流程使用。
    internal func metadata(for url: URL) -> AssetMetadata? {
        guard url.isFileURL else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard storedCountLimit > 0 else { return nil }
        return cache.object(forKey: Self.key(for: url))
    }

    /// 写入组件解析出的可复用 metadata。手工构造的摘要对象不会进入缓存。
    internal func insert(_ metadata: AssetMetadata, for url: URL) {
        guard url.isFileURL,
              metadata.isReusableForPlayback,
              metadata.sourceURL == url.standardizedFileURL else {
            return
        }
        lock.lock()
        store(metadata, for: url)
        lock.unlock()
    }

    /// 解析同一 URL 时合并并发 miss，避免重复执行昂贵的 inspection。
    /// 缓存命中仍会校验文件签名；失效项会被丢弃后重新解析。
    internal func resolve(url: URL, inspector: AssetInspector) async throws -> Resolution {
        guard url.isFileURL else {
            let inspection = try await inspector.inspectDetails(url: url)
            return Resolution(inspection: inspection, reusedMetadata: nil)
        }

        while true {
            if let cachedMetadata = metadata(for: url) {
                do {
                    return Resolution(
                        inspection: try Self.reusableInspection(from: cachedMetadata, for: url),
                        reusedMetadata: cachedMetadata
                    )
                } catch {
                    removeIfCurrent(cachedMetadata, for: url)
                }
            }

            let key = Self.key(for: url) as String
            guard let flight = makeFlight(for: key, url: url, inspector: inspector) else {
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

    private func makeFlight(
        for key: String,
        url: URL,
        inspector: AssetInspector
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
            let inspection = try await inspector.inspectDetails(url: url)
            self?.storeIfCurrent(inspection.metadata, for: url, generation: generation)
            return inspection
        }
        let flight = InFlight(task: task, generation: generation)
        inFlight[key, default: []].append(flight)
        return flight
    }

    private func removeIfCurrent(_ metadata: AssetMetadata, for url: URL) {
        guard url.isFileURL else { return }
        let key = Self.key(for: url) as String
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

    internal static func reusableInspection(
        from metadata: AssetMetadata,
        for url: URL
    ) throws -> InspectionResult {
        guard metadata.sourceURL == url.standardizedFileURL,
              let document = metadata.playbackDocument else {
            throw PlaybackError.invalidVapc(
                reason: "AssetMetadata is not reusable or belongs to a different local URL."
            )
        }
        try validateReusableFileSignature(metadata, for: url)
        return InspectionResult(metadata: metadata, vapc: document)
    }

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

    private func store(_ metadata: AssetMetadata, for url: URL) {
        guard storedCountLimit > 0 else { return }
        cache.setObject(metadata, forKey: Self.key(for: url))
    }

    private func storeIfCurrent(
        _ metadata: AssetMetadata,
        for url: URL,
        generation: Generation
    ) {
        lock.lock()
        let currentGeneration = Generation(
            global: globalMutationGeneration,
            url: urlMutationGenerations[Self.key(for: url) as String, default: 0]
        )
        if currentGeneration == generation {
            store(metadata, for: url)
        }
        lock.unlock()
    }

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

    private static func key(for url: URL) -> NSString {
        let canonicalURL = url.standardizedFileURL
        let digest = SHA256.hash(data: Data(canonicalURL.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex as NSString
    }
}
