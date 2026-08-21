import Foundation

/// 只读取 VAP 检查阶段需要的顶层 ISO BMFF box。
///
/// 每次推进前都验证 header、扩展长度和父边界，避免损坏文件触发整数溢出或越界切片。
struct MP4BoxReader {
    struct Box: Equatable {
        let type: String
        let range: Range<Int>
        let payloadRange: Range<Int>
    }

    private static let regularHeaderSize = 8
    private static let extendedHeaderSize = 16
    private static let maximumBoxCount = 100_000

    func topLevelBoxes(in data: Data) throws -> [Box] {
        guard data.count >= Self.regularHeaderSize else {
            throw PlaybackError.invalidMP4(reason: "File is shorter than an MP4 box header.")
        }

        var boxes: [Box] = []
        var offset = 0
        while offset < data.count {
            guard boxes.count < Self.maximumBoxCount else {
                throw PlaybackError.invalidMP4(reason: "MP4 contains too many top-level boxes.")
            }
            guard data.count - offset >= Self.regularHeaderSize else {
                throw PlaybackError.invalidMP4(reason: "Truncated MP4 box header at offset \(offset).")
            }

            let shortSize = Int(readUInt32(data, at: offset))
            let typeData = data[(offset + 4)..<(offset + 8)]
            guard let type = String(data: typeData, encoding: .isoLatin1), type.utf8.count == 4 else {
                throw PlaybackError.invalidMP4(reason: "Invalid box type at offset \(offset).")
            }

            let headerSize: Int
            let boxSize: Int
            switch shortSize {
            case 0:
                headerSize = Self.regularHeaderSize
                boxSize = data.count - offset
            case 1:
                guard data.count - offset >= Self.extendedHeaderSize else {
                    throw PlaybackError.invalidMP4(reason: "Truncated extended box header for \(type).")
                }
                let extendedSize = readUInt64(data, at: offset + 8)
                guard extendedSize <= UInt64(Int.max) else {
                    throw PlaybackError.invalidMP4(reason: "Box \(type) is too large for this platform.")
                }
                headerSize = Self.extendedHeaderSize
                boxSize = Int(extendedSize)
            default:
                headerSize = Self.regularHeaderSize
                boxSize = shortSize
            }

            guard boxSize >= headerSize, boxSize <= data.count - offset else {
                throw PlaybackError.invalidMP4(reason: "Box \(type) exceeds its parent boundary.")
            }
            let end = offset + boxSize
            boxes.append(Box(
                type: type,
                range: offset..<end,
                payloadRange: (offset + headerSize)..<end
            ))
            offset = end
        }
        return boxes
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
