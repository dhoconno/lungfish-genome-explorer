// SeededPairOrder.swift - Write read pairs in a fixed-seed random order with bounded memory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The import clumps a bundle's reads (clumpify `reorder groups=auto`), so
// similar reads sit together at the head of the file. A tool that samples
// the head of its input, as fastp does when it guesses the adapter, then
// sees an unfair sample (trust session F5, ruling BIO-F5-READ-ORDER). This
// helper writes the pairs sorted by a seeded hash of each pair's index, so
// every run gives the same order and mates stay together.
//
// Memory stays bounded. Pairs are spilled, compressed, to bucket files by
// the high bits of their key, and each bucket is sorted in memory and
// written in turn. A bucket holds one range of keys, so the order is the
// same for any bucket count.

import Foundation
import LungfishCore

public enum SeededPairOrder {

    /// The fixed seed every staging uses.
    public static let seed: UInt64 = 1

    /// The staging step as a run record names it.
    public static let stepDescription = "pairs staged in seeded random order"

    /// What a run record keeps of the staging.
    public struct Record: Codable, Sendable, Equatable {
        public let step: String
        public let seed: UInt64

        public init(step: String = SeededPairOrder.stepDescription, seed: UInt64 = SeededPairOrder.seed) {
            self.step = step
            self.seed = seed
        }

        var provenanceValue: ParameterValue {
            .dictionary(["step": .string(step), "seed": .integer(Int(truncatingIfNeeded: seed))])
        }
    }

    /// Where the pairs come from.
    public enum Source: Sendable {
        /// One file whose records alternate R1, R2.
        case interleaved(URL)
        /// Two files read in step.
        case separate(r1: URL, r2: URL)
    }

    public enum StagingError: Error, LocalizedError, Equatable {
        case mateCountMismatch(r1Records: Int, r2Records: Int)
        case scratchDamaged(bucket: Int)

        public var errorDescription: String? {
            switch self {
            case .mateCountMismatch(let r1Records, let r2Records):
                return "its R1 file holds \(r1Records) reads and its R2 file holds \(r2Records)"
            case .scratchDamaged(let bucket):
                return "the scratch file \(bucket) of the read staging could not be read back, so nothing was staged"
            }
        }
    }

    /// The sort key of pair `index`, SplitMix64 of the seed and the index.
    static func key(of index: UInt64, seed: UInt64) -> UInt64 {
        var z = seed &+ (index &+ 1) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// The order the pairs `0..<count` are written in.
    static func order(count: Int, seed: UInt64 = seed) -> [Int] {
        (0..<count).sorted { (key(of: UInt64($0), seed: seed), $0) < (key(of: UInt64($1), seed: seed), $1) }
    }

    /// The bucket of `key` among `count`, monotone in the key.
    static func bucket(of key: UInt64, count: Int) -> Int {
        Int(((key >> 32) &* UInt64(count)) >> 32)
    }

    /// Enough buckets that one holds about 64 MiB of reads, at most 512.
    static func bucketCount(for urls: [URL]) -> Int {
        let estimate = urls.reduce(0) { total, url in
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
            return total + (url.pathExtension.lowercased() == "gz" ? size * 4 : size)
        }
        let target = 64 << 20
        return min(max(1, (estimate + target - 1) / target), 512)
    }

    /// Writes every pair of `source` to `sink1` and `sink2` in the seeded
    /// order and returns the pairs written. `scratch` holds the bucket files
    /// while it runs and is removed before it returns. An interleaved file
    /// whose neighbours are not mates throws what
    /// `FASTQPairInterleaver.deinterleave` throws.
    static func write(
        _ source: Source,
        r1 sink1: FileHandle,
        r2 sink2: FileHandle,
        scratch: URL,
        seed: UInt64 = seed,
        bucketCount: Int? = nil
    ) throws -> Int {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: scratch)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let urls: [URL]
        switch source {
        case .interleaved(let url): urls = [url]
        case .separate(let r1, let r2): urls = [r1, r2]
        }
        let buckets = BucketFiles(directory: scratch, count: bucketCount ?? Self.bucketCount(for: urls))
        var pairs = 0
        try forEachPair(of: source) { record1, record2 in
            try buckets.append(key: key(of: UInt64(pairs), seed: seed), index: UInt64(pairs), record1, record2)
            pairs += 1
            if pairs & 0x3FFF == 0 { try Task.checkCancellation() }
        }
        try buckets.flushAll()
        var output1 = Output(handle: sink1)
        var output2 = Output(handle: sink2)
        for bucket in 0..<buckets.count {
            try Task.checkCancellation()
            let raw = try buckets.load(bucket)
            for entry in try entries(in: raw, bucket: bucket, seed: seed) {
                try output1.append(raw[entry.r1])
                try output2.append(raw[entry.r2])
            }
        }
        try output1.flush()
        try output2.flush()
        return pairs
    }

    /// Hands each pair of `source` to `body` as two whole records with their newlines.
    private static func forEachPair(of source: Source, _ body: ([UInt8], [UInt8]) throws -> Void) throws {
        switch source {
        case .interleaved(let url):
            let reader = try FASTQRawLineReader(url: url)
            defer { reader.close() }
            let file = url.lastPathComponent
            var number = 0
            while let record1 = try FASTQPairInterleaver.readRecord(from: reader, file: file, recordNumber: number + 1) {
                number += 1
                guard let record2 = try FASTQPairInterleaver.readRecord(from: reader, file: file, recordNumber: number + 1) else {
                    throw FASTQPairInterleaver.InterleaveError.mateCountMismatch(
                        r1File: file, r1Records: number / 2 + 1, r2File: file, r2Records: number / 2
                    )
                }
                number += 1
                let name1 = FASTQPairInterleaver.headerText(record1[0])
                let name2 = FASTQPairInterleaver.headerText(record2[0])
                guard FASTQPairInterleaver.recordedMates(name1, name2) == .mates else {
                    throw FASTQPairInterleaver.InterleaveError.mateNameMismatch(
                        recordNumber: number / 2, r1File: file, r1Name: name1, r2File: file, r2Name: name2
                    )
                }
                try body(joined(record1), joined(record2))
            }
        case .separate(let r1, let r2):
            let reader1 = try FASTQRawLineReader(url: r1)
            defer { reader1.close() }
            let reader2 = try FASTQRawLineReader(url: r2)
            defer { reader2.close() }
            var count1 = 0
            var count2 = 0
            func next(_ reader: FASTQRawLineReader, _ url: URL, _ count: inout Int) throws -> [[UInt8]]? {
                let record = try FASTQPairInterleaver.readRecord(from: reader, file: url.lastPathComponent, recordNumber: count + 1)
                if record != nil { count += 1 }
                return record
            }
            while true {
                let record1 = try next(reader1, r1, &count1)
                let record2 = try next(reader2, r2, &count2)
                if let record1, let record2 {
                    try body(joined(record1), joined(record2))
                    continue
                }
                if record1 == nil && record2 == nil { return }
                while try next(reader1, r1, &count1) != nil {}
                while try next(reader2, r2, &count2) != nil {}
                throw StagingError.mateCountMismatch(r1Records: count1, r2Records: count2)
            }
        }
    }

    private static func joined(_ lines: [[UInt8]]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(lines.reduce(lines.count) { $0 + $1.count })
        for line in lines {
            bytes += line
            bytes.append(0x0A)
        }
        return bytes
    }

    private struct Entry {
        let key: UInt64
        let index: UInt64
        let r1: Range<Int>
        let r2: Range<Int>
    }

    /// The pairs of one bucket's bytes, sorted by key, then index.
    private static func entries(in raw: [UInt8], bucket: Int, seed: UInt64) throws -> [Entry] {
        var entries: [Entry] = []
        var position = 0
        func field(_ width: Int) throws -> Int {
            guard position + width <= raw.count else { throw StagingError.scratchDamaged(bucket: bucket) }
            let value = readInteger(raw, at: position, width: width)
            position += width
            return Int(value)
        }
        func range() throws -> Range<Int> {
            let length = try field(4)
            guard position + length <= raw.count else { throw StagingError.scratchDamaged(bucket: bucket) }
            defer { position += length }
            return position..<position + length
        }
        while position < raw.count {
            let index = UInt64(try field(8))
            entries.append(Entry(key: key(of: index, seed: seed), index: index, r1: try range(), r2: try range()))
        }
        entries.sort { ($0.key, $0.index) < ($1.key, $1.index) }
        return entries
    }

    private static func appendInteger(_ value: UInt64, width: Int, to bytes: inout [UInt8]) {
        for shift in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(shift)))) }
    }

    private static func readInteger(_ bytes: [UInt8], at offset: Int, width: Int) -> UInt64 {
        (0..<width).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }

    /// Buffered writes of whole records to one staged file.
    private struct Output {
        let handle: FileHandle
        var buffer: [UInt8] = []

        mutating func append(_ bytes: ArraySlice<UInt8>) throws {
            buffer += bytes
            if buffer.count >= 4 << 20 { try flush() }
        }

        mutating func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    /// The bucket files of one staging. Each is a run of chunks, each chunk
    /// a raw length, a packed length and the LZ4-packed entries.
    private final class BucketFiles {
        let count: Int
        private let directory: URL
        private var buffers: [[UInt8]]
        private let flushBytes: Int

        init(directory: URL, count: Int) {
            self.directory = directory
            self.count = count
            buffers = Array(repeating: [], count: count)
            flushBytes = max(64 << 10, min(1 << 20, (32 << 20) / count))
        }

        private func url(_ bucket: Int) -> URL {
            directory.appendingPathComponent("bucket-\(bucket)")
        }

        func append(key: UInt64, index: UInt64, _ record1: [UInt8], _ record2: [UInt8]) throws {
            let bucket = SeededPairOrder.bucket(of: key, count: count)
            SeededPairOrder.appendInteger(index, width: 8, to: &buffers[bucket])
            SeededPairOrder.appendInteger(UInt64(record1.count), width: 4, to: &buffers[bucket])
            buffers[bucket] += record1
            SeededPairOrder.appendInteger(UInt64(record2.count), width: 4, to: &buffers[bucket])
            buffers[bucket] += record2
            if buffers[bucket].count >= flushBytes { try flush(bucket) }
        }

        func flushAll() throws {
            for bucket in 0..<count { try flush(bucket) }
        }

        private func flush(_ bucket: Int) throws {
            guard !buffers[bucket].isEmpty else { return }
            let packed = try (Data(buffers[bucket]) as NSData).compressed(using: .lz4) as Data
            var chunk: [UInt8] = []
            SeededPairOrder.appendInteger(UInt64(buffers[bucket].count), width: 4, to: &chunk)
            SeededPairOrder.appendInteger(UInt64(packed.count), width: 4, to: &chunk)
            chunk += packed
            let file = url(bucket)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: chunk)
            buffers[bucket].removeAll(keepingCapacity: true)
        }

        /// The raw entries of `bucket`. Its file is removed once read.
        func load(_ bucket: Int) throws -> [UInt8] {
            let file = url(bucket)
            guard let data = FileManager.default.contents(atPath: file.path) else { return [] }
            try? FileManager.default.removeItem(at: file)
            let bytes = [UInt8](data)
            var raw: [UInt8] = []
            var position = 0
            while position < bytes.count {
                guard position + 8 <= bytes.count else { throw StagingError.scratchDamaged(bucket: bucket) }
                let rawCount = Int(SeededPairOrder.readInteger(bytes, at: position, width: 4))
                let packedCount = Int(SeededPairOrder.readInteger(bytes, at: position + 4, width: 4))
                guard position + 8 + packedCount <= bytes.count else { throw StagingError.scratchDamaged(bucket: bucket) }
                let packed = Data(bytes[(position + 8)..<(position + 8 + packedCount)])
                let unpacked = try (packed as NSData).decompressed(using: .lz4) as Data
                guard unpacked.count == rawCount else { throw StagingError.scratchDamaged(bucket: bucket) }
                raw += unpacked
                position += 8 + packedCount
            }
            return raw
        }
    }
}
