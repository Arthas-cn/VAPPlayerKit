import Foundation
import UIKit

enum ResolvedDynamicContent: @unchecked Sendable {
    case image(UIImage)
    case hidden
}

struct DynamicSnapshot: @unchecked Sendable {
    let contents: [String: ResolvedDynamicContent]

    static let empty = DynamicSnapshot(contents: [:])
}

/// 准备动态图片 / 文字。不进入视频解码线程，不发网络请求。
@MainActor
final class DynamicResolver {
    weak var provider: DynamicContentProvider?
    weak var objcProvider: ObjCDynamicContentProvider?
    private var generation: UInt64 = 0
    private var activeGates: [UUID: DynamicResolutionGate] = [:]

    func resolve(sources: [VapcSource], timeout: TimeInterval = 8) async throws -> DynamicSnapshot {
        generation &+= 1
        let currentGeneration = generation
        guard !sources.isEmpty else { return .empty }
        var totalBytes = 0
        for source in sources {
            guard
                let bytes = DynamicTextureLimits.byteCount(for: source.slotSize),
                bytes <= DynamicTextureLimits.maximumBytesPerTexture,
                totalBytes <= DynamicTextureLimits.maximumBytesPerSession - bytes
            else {
                throw PlaybackError.invalidVapc(reason: "Dynamic source textures exceed the allocation budget.")
            }
            totalBytes += bytes
        }
        guard provider != nil || objcProvider != nil else {
            return DynamicSnapshot(contents: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, .hidden) }))
        }

        return try await withThrowingTaskGroup(of: (String, ResolvedDynamicContent).self) { group in
            for source in sources {
                group.addTask { @MainActor [weak self] in
                    guard let self, self.generation == currentGeneration else {
                        throw PlaybackError.cancelled
                    }
                    let content = try await self.resolveOne(source, timeout: timeout, generation: currentGeneration)
                    return (source.id, content)
                }
            }
            var result: [String: ResolvedDynamicContent] = [:]
            for try await (id, content) in group {
                result[id] = content
            }
            return DynamicSnapshot(contents: result)
        }
    }

    func cancel() {
        generation &+= 1
        let gates = activeGates.values
        activeGates.removeAll()
        for gate in gates {
            gate.finish(.failure(PlaybackError.cancelled))
        }
    }

    private func resolveOne(_ source: VapcSource, timeout: TimeInterval, generation: UInt64) async throws -> ResolvedDynamicContent {
        let metadata = SourceMetadata(tag: source.tag, slotSize: source.slotSize)
        let gate = DynamicResolutionGate()
        let gateID = UUID()
        activeGates[gateID] = gate
        defer { activeGates[gateID] = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                if let provider {
                    provider.resolve(tag: source.tag, source: metadata) { content, error in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == generation else {
                                gate.finish(.failure(PlaybackError.cancelled))
                                return
                            }
                            if let error {
                                gate.finish(.failure(error))
                            } else {
                                let resolved = await self.materialize(content ?? .hidden, source: source)
                                guard self.generation == generation else {
                                    gate.finish(.failure(PlaybackError.cancelled))
                                    return
                                }
                                gate.finish(.success(resolved))
                            }
                        }
                    }
                } else if let objcProvider {
                    objcProvider.resolveTag(source.tag, source: metadata) { [weak self] image, error in
                        Task { @MainActor in
                            guard let self, self.generation == generation else {
                                gate.finish(.failure(PlaybackError.cancelled))
                                return
                            }
                            if let error {
                                gate.finish(.failure(error))
                            } else if let image {
                                let resolved = await self.materialize(.image(image), source: source)
                                guard self.generation == generation else {
                                    gate.finish(.failure(PlaybackError.cancelled))
                                    return
                                }
                                gate.finish(.success(resolved))
                            } else {
                                gate.finish(.success(.hidden))
                            }
                        }
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000))
                    gate.finish(.failure(PlaybackError.dynamicContentTimeout))
                }
            }
        } onCancel: {
            gate.finish(.failure(PlaybackError.cancelled))
        }
    }

    private func materialize(_ content: DynamicContent, source: VapcSource) async -> ResolvedDynamicContent {
        // All branches use UIKit drawing. Serializing them on this @MainActor avoids a
        // physical-device deadlock between concurrent image and TextKit renderers.
        switch content {
        case .hidden, .imageURL:
            return .hidden
        case .image(let image):
            return .image(Self.resized(image, source: source))
        case .text(let text, let attributes):
            return .image(Self.rasterizedText(text, attributes: attributes, source: source))
        }
    }

    private static func rasterizedText(
        _ text: String,
        attributes textAttributes: TextAttributes,
        source: VapcSource
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: source.slotSize, format: format).image { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: textAttributes.font,
                .foregroundColor: textAttributes.color,
                .paragraphStyle: paragraph
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let bounds = attributed.boundingRect(
                with: source.slotSize,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            attributed.draw(at: CGPoint(
                x: max(0, (source.slotSize.width - bounds.width) / 2),
                y: max(0, (source.slotSize.height - bounds.height) / 2)
            ))
        }
    }

    private static func resized(_ image: UIImage, source: VapcSource) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: source.slotSize, format: format).image { _ in
            let target: CGRect
            if source.fitType == "centerFull", image.size.width > 0, image.size.height > 0 {
                let scale = max(source.slotSize.width / image.size.width, source.slotSize.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                target = CGRect(
                    x: (source.slotSize.width - size.width) / 2,
                    y: (source.slotSize.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
            } else {
                target = CGRect(origin: .zero, size: source.slotSize)
            }
            image.draw(in: target)
        }
    }
}

private final class DynamicResolutionGate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ResolvedDynamicContent, Error>?
    private var result: Result<ResolvedDynamicContent, Error>?
    private var completed = false

    func install(_ continuation: CheckedContinuation<ResolvedDynamicContent, Error>) {
        let pending: Result<ResolvedDynamicContent, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func finish(_ result: Result<ResolvedDynamicContent, Error>) {
        let continuation: CheckedContinuation<ResolvedDynamicContent, Error>? = lock.withLock {
            guard !completed else { return nil }
            completed = true
            guard let continuation = self.continuation else {
                self.result = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
