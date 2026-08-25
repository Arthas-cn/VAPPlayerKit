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
        var offset: UInt64 = 0
        let fileSize = UInt64(data.count)
        while offset < fileSize {
            guard boxes.count < Self.maximumBoxCount else {
                throw PlaybackError.invalidMP4(reason: "MP4 contains too many top-level boxes.")
            }
            guard fileSize - offset >= UInt64(Self.regularHeaderSize) else {
                throw PlaybackError.invalidMP4(reason: "Truncated MP4 box header at offset \(offset).")
            }

            let offsetInt = Int(offset)
            let firstHeader = Data(data[offsetInt..<(offsetInt + Self.regularHeaderSize)])
            let extendedHeader: Data?
            if readUInt32(firstHeader, at: 0) == 1 {
                guard fileSize - offset >= UInt64(Self.extendedHeaderSize) else {
                    throw PlaybackError.invalidMP4(reason: "Truncated extended box header at offset \(offset).")
                }
                extendedHeader = Data(data[(offsetInt + Self.regularHeaderSize)..<(offsetInt + Self.extendedHeaderSize)])
            } else {
                extendedHeader = nil
            }

            let header = try parseHeader(firstHeader, extendedHeader: extendedHeader, at: offset)
            let boxSize = header.boxSize == 0 ? fileSize - offset : header.boxSize
            try validate(boxSize: boxSize, headerSize: header.headerSize, type: header.type, offset: offset, fileSize: fileSize)
            boxes.append(makeBox(type: header.type, offset: offset, boxSize: boxSize, headerSize: header.headerSize))
            offset += boxSize
        }
        return boxes
    }

    /// Scans only top-level box headers from a file. Box payloads are skipped with `seek`.
    func topLevelBoxes(inFile url: URL, fileSize: UInt64) throws -> [Box] {
        guard url.isFileURL else {
            throw PlaybackError.invalidURL
        }
        guard fileSize <= UInt64(Int.max) else {
            throw PlaybackError.invalidMP4(reason: "File is too large for this platform.")
        }
        guard fileSize >= UInt64(Self.regularHeaderSize) else {
            throw PlaybackError.invalidMP4(reason: "File is shorter than an MP4 box header.")
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try topLevelBoxes(in: handle, fileSize: fileSize)
        } catch let error as PlaybackError {
            throw error
        } catch {
            throw PlaybackError.invalidMP4(reason: "File cannot be read.")
        }
    }

    /// Reads one previously discovered box payload without mapping or loading the rest of the file.
    func readPayload(of box: Box, inFile url: URL) throws -> Data {
        guard url.isFileURL else {
            throw PlaybackError.invalidURL
        }
        guard box.payloadRange.lowerBound >= 0, box.payloadRange.count >= 0 else {
            throw PlaybackError.invalidMP4(reason: "Invalid box payload range.")
        }
        guard box.payloadRange.count > 0 else {
            return Data()
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try readExactly(
                from: handle,
                at: UInt64(box.payloadRange.lowerBound),
                count: box.payloadRange.count,
                failureReason: "Box \(box.type) payload is truncated."
            )
        } catch let error as PlaybackError {
            throw error
        } catch {
            throw PlaybackError.invalidMP4(reason: "File cannot be read.")
        }
    }

    private struct ParsedHeader {
        let type: String
        let headerSize: Int
        let boxSize: UInt64
    }

    private func topLevelBoxes(in handle: FileHandle, fileSize: UInt64) throws -> [Box] {
        var boxes: [Box] = []
        var offset: UInt64 = 0
        while offset < fileSize {
            guard boxes.count < Self.maximumBoxCount else {
                throw PlaybackError.invalidMP4(reason: "MP4 contains too many top-level boxes.")
            }
            guard fileSize - offset >= UInt64(Self.regularHeaderSize) else {
                throw PlaybackError.invalidMP4(reason: "Truncated MP4 box header at offset \(offset).")
            }

            let firstHeader = try readExactly(
                from: handle,
                at: offset,
                count: Self.regularHeaderSize,
                failureReason: "Truncated MP4 box header at offset \(offset)."
            )
            let extendedHeader: Data?
            if readUInt32(firstHeader, at: 0) == 1 {
                guard fileSize - offset >= UInt64(Self.extendedHeaderSize) else {
                    throw PlaybackError.invalidMP4(reason: "Truncated extended box header at offset \(offset).")
                }
                extendedHeader = try readExactly(
                    from: handle,
                    at: offset + UInt64(Self.regularHeaderSize),
                    count: Self.regularHeaderSize,
                    failureReason: "Truncated extended box header at offset \(offset)."
                )
            } else {
                extendedHeader = nil
            }

            let header = try parseHeader(firstHeader, extendedHeader: extendedHeader, at: offset)
            let boxSize = header.boxSize == 0 ? fileSize - offset : header.boxSize
            try validate(boxSize: boxSize, headerSize: header.headerSize, type: header.type, offset: offset, fileSize: fileSize)
            boxes.append(makeBox(type: header.type, offset: offset, boxSize: boxSize, headerSize: header.headerSize))
            offset += boxSize
        }
        return boxes
    }

    private func parseHeader(_ firstHeader: Data, extendedHeader: Data?, at offset: UInt64) throws -> ParsedHeader {
        let shortSize = readUInt32(firstHeader, at: 0)
        let typeData = firstHeader[4..<8]
        guard let type = String(data: typeData, encoding: .isoLatin1), type.utf8.count == 4 else {
            throw PlaybackError.invalidMP4(reason: "Invalid box type at offset \(offset).")
        }

        switch shortSize {
        case 0:
            return ParsedHeader(type: type, headerSize: Self.regularHeaderSize, boxSize: 0)
        case 1:
            guard let extendedHeader, extendedHeader.count == Self.regularHeaderSize else {
                throw PlaybackError.invalidMP4(reason: "Truncated extended box header for \(type).")
            }
            let extendedSize = readUInt64(extendedHeader, at: 0)
            guard extendedSize <= UInt64(Int.max) else {
                throw PlaybackError.invalidMP4(reason: "Box \(type) is too large for this platform.")
            }
            return ParsedHeader(type: type, headerSize: Self.extendedHeaderSize, boxSize: extendedSize)
        default:
            return ParsedHeader(type: type, headerSize: Self.regularHeaderSize, boxSize: UInt64(shortSize))
        }
    }

    private func validate(boxSize: UInt64, headerSize: Int, type: String, offset: UInt64, fileSize: UInt64) throws {
        guard boxSize >= UInt64(headerSize), boxSize <= fileSize - offset else {
            throw PlaybackError.invalidMP4(reason: "Box \(type) exceeds its parent boundary.")
        }
        guard offset <= UInt64(Int.max), boxSize <= UInt64(Int.max) - offset else {
            throw PlaybackError.invalidMP4(reason: "Box \(type) is too large for this platform.")
        }
    }

    private func makeBox(type: String, offset: UInt64, boxSize: UInt64, headerSize: Int) -> Box {
        let start = Int(offset)
        let end = start + Int(boxSize)
        return Box(
            type: type,
            range: start..<end,
            payloadRange: (start + headerSize)..<end
        )
    }

    private func readExactly(from handle: FileHandle, at offset: UInt64, count: Int, failureReason: String) throws -> Data {
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw PlaybackError.invalidMP4(reason: failureReason)
            }
            return data
        } catch let error as PlaybackError {
            throw error
        } catch {
            throw PlaybackError.invalidMP4(reason: "File cannot be read.")
        }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
