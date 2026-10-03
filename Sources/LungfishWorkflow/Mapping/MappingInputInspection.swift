// MappingInputInspection.swift - Shared FASTQ inspection for mapper compatibility
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Compression
import Foundation
import LungfishIO

public struct MappingInputInspection: Sendable, Equatable {
    public let readClass: MappingReadClass?
    public let observedMaxReadLength: Int?
    public let mixedReadClasses: Bool
    public let hasUnclassifiedFASTQInputs: Bool
    public let sequenceFormat: SequenceFormat?
    public let mixedSequenceFormats: Bool

    public init(
        readClass: MappingReadClass?,
        observedMaxReadLength: Int?,
        mixedReadClasses: Bool,
        hasUnclassifiedFASTQInputs: Bool = false,
        sequenceFormat: SequenceFormat?,
        mixedSequenceFormats: Bool
    ) {
        self.readClass = readClass
        self.observedMaxReadLength = observedMaxReadLength
        self.mixedReadClasses = mixedReadClasses
        self.hasUnclassifiedFASTQInputs = hasUnclassifiedFASTQInputs
        self.sequenceFormat = sequenceFormat
        self.mixedSequenceFormats = mixedSequenceFormats
    }

    public static func inspect(urls: [URL]) -> MappingInputInspection {
        var detectedClasses: Set<MappingReadClass> = []
        var detectedFormats: Set<SequenceFormat> = []
        var unclassifiedFASTQCount = 0
        var maxReadLength = 0

        for url in urls {
            guard let resolvedInput = resolveSequenceInput(for: url) else {
                continue
            }
            detectedFormats.insert(resolvedInput.format)

            switch resolvedInput.format {
            case .fastq:
                if let readClass = MappingReadClass.detect(fromInputURL: url) {
                    detectedClasses.insert(readClass)
                } else {
                    unclassifiedFASTQCount += 1
                }
                let metadata = FASTQMetadataStore.load(for: resolvedInput.url)
                let cachedLength = cachedMaxReadLength(from: metadata)
                let observedLength = observedReadLength(fromFASTQ: resolvedInput.url)
                maxReadLength = max(maxReadLength, cachedLength ?? observedLength ?? 0)
            case .fasta:
                maxReadLength = max(maxReadLength, observedSequenceLength(fromFASTA: resolvedInput.url) ?? 0)
            }
        }

        return MappingInputInspection(
            readClass: detectedClasses.count == 1 ? detectedClasses.first : nil,
            observedMaxReadLength: maxReadLength > 0 ? maxReadLength : nil,
            mixedReadClasses: detectedClasses.count > 1,
            hasUnclassifiedFASTQInputs: unclassifiedFASTQCount > 0,
            sequenceFormat: detectedFormats.count == 1 ? detectedFormats.first : nil,
            mixedSequenceFormats: detectedFormats.count > 1
        )
    }

    public var mixesDetectedAndUnclassifiedReadClasses: Bool {
        readClass != nil && hasUnclassifiedFASTQInputs
    }

    /// The read class FASTQ inputs of unknown platform default to, from the
    /// longest read: ONT reads over 1,000 bases, short reads up to 600. Nil
    /// when a read class is known, the inputs mix classes, or the length says
    /// neither. Only a default, never a gate.
    public var lengthDefaultReadClass: MappingReadClass? {
        guard readClass == nil, !mixedReadClasses, sequenceFormat != .fasta,
              let observedMaxReadLength else { return nil }
        if observedMaxReadLength > 1_000 { return .ontReads }
        if observedMaxReadLength <= 600 { return .illuminaShortReads }
        return nil
    }

    /// One sentence naming inputs whose recorded platform contradicts their
    /// reads (imported before platform inference), or nil.
    public static func suspectLabelNote(for urls: [URL]) -> String? {
        let suspects = urls.compactMap { url -> String? in
            guard let check = PlatformLabelCheck.check(inputURL: url), check.isSuspect else { return nil }
            return "\(url.deletingPathExtension().lastPathComponent): \(check.reasons.joined(separator: " "))"
        }
        guard !suspects.isEmpty else { return nil }
        return "The recorded read type may be wrong. \(suspects.joined(separator: " ")) The preset follows the recorded read type. Check the bundle in the Inspector."
    }

    private struct ResolvedSequenceInput: Sendable, Equatable {
        let url: URL
        let format: SequenceFormat
    }

    private static func resolveSequenceInput(for inputURL: URL) -> ResolvedSequenceInput? {
        guard let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) else {
            return nil
        }
        guard let format = SequenceInputResolver.inputSequenceFormat(for: inputURL)
            ?? SequenceFormat.from(url: resolvedURL) else {
            return nil
        }
        return ResolvedSequenceInput(url: resolvedURL, format: format)
    }

    private static func observedReadLength(fromFASTQ url: URL) -> Int? {
        guard let text = readPrefixText(from: url, byteCount: 32_768) else { return nil }
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

    private static func cachedMaxReadLength(from metadata: PersistedFASTQMetadata?) -> Int? {
        let candidates = [
            metadata?.computedStatistics?.maxReadLength,
            metadata?.seqkitStats?.maxLen,
        ].compactMap { $0 }.filter { $0 > 0 }

        return candidates.max()
    }

    private static func observedSequenceLength(fromFASTA url: URL) -> Int? {
        guard let text = readPrefixText(from: url, byteCount: 32_768) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var longest = 0
        var currentLength = 0

        for line in lines {
            if line.hasPrefix(">") {
                longest = max(longest, currentLength)
                currentLength = 0
            } else {
                currentLength += line.count
            }
        }

        longest = max(longest, currentLength)
        return longest > 0 ? longest : nil
    }

    private static func readPrefixText(from url: URL, byteCount: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteCount), !data.isEmpty else { return nil }

        if data.count >= 2, data[0] == 0x1F, data[1] == 0x8B {
            guard let decompressed = decompressGzipPrefix(data: data) else { return nil }
            return String(data: decompressed, encoding: .utf8)
        }

        return String(data: data, encoding: .utf8)
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
