// MappingInputInspection.swift - Shared FASTQ inspection for mapper compatibility
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Compression
import Foundation

public struct MappingInputInspection: Sendable, Equatable {
    public let readClass: MappingReadClass?
    public let observedMaxReadLength: Int?
    public let mixedReadClasses: Bool

    public init(
        readClass: MappingReadClass?,
        observedMaxReadLength: Int?,
        mixedReadClasses: Bool
    ) {
        self.readClass = readClass
        self.observedMaxReadLength = observedMaxReadLength
        self.mixedReadClasses = mixedReadClasses
    }

    public static func inspect(urls: [URL]) -> MappingInputInspection {
        var detectedClasses: Set<MappingReadClass> = []
        var maxReadLength = 0

        for url in urls {
            if let readClass = MappingReadClass.detect(fromFASTQ: url) {
                detectedClasses.insert(readClass)
            }
            maxReadLength = max(maxReadLength, observedReadLength(fromFASTQ: url) ?? 0)
        }

        return MappingInputInspection(
            readClass: detectedClasses.count == 1 ? detectedClasses.first : nil,
            observedMaxReadLength: maxReadLength > 0 ? maxReadLength : nil,
            mixedReadClasses: detectedClasses.count > 1
        )
    }

    private static func observedReadLength(fromFASTQ url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32_768), !data.isEmpty else { return nil }

        let text: String?
        if data.count >= 2, data[0] == 0x1F, data[1] == 0x8B {
            text = decompressGzipPrefix(data: data).flatMap { String(data: $0, encoding: .utf8) }
        } else {
            text = String(data: data, encoding: .utf8)
        }

        guard let text else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var longest = 0
        var lineIndex = 0
        for line in lines {
            if lineIndex % 4 == 1 {
                longest = max(longest, line.count)
            }
            lineIndex += 1
        }
        return longest > 0 ? longest : nil
    }

    private static func decompressGzipPrefix(data: Data) -> Data? {
        guard data.count > 10 else { return nil }
        var offset = 10
        let flags = data[3]
        if flags & 0x04 != 0, data.count > offset + 2 {
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < data.count else { return nil }

        let compressed = data.subdata(in: offset..<data.count)
        let bufferSize = 32_768
        var output = Data(count: bufferSize)
        let size: Int = compressed.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                guard let srcPtr = src.baseAddress, let dstPtr = dst.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstPtr.assumingMemoryBound(to: UInt8.self), bufferSize,
                    srcPtr.assumingMemoryBound(to: UInt8.self), compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard size > 0 else { return nil }
        return output.prefix(size)
    }
}
