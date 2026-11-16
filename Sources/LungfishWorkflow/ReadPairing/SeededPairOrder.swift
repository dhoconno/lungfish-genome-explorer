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
// same for any bucket count. Every bucket is read and unpacked into the
// same two buffers, because on macOS a freed block of tens of MiB stays in
// the footprint for a while: a fresh file buffer and entry array a bucket
// raised it by about half the staged text (FASTP-STAGING-MEMORY).

import Compression
import Darwin
import Foundation
import LungfishCore

public enum SeededPairOrder {

    /// The fixed seed every staging uses.
    public static let seed: UInt64 = 1

    /// The staging step as a run record names it.
    public static let stepDescription = "pairs staged in seeded random order"

    /// The staging step of single reads as a run record names it.
    public static let readsStepDescription = "reads staged in seeded random order"

    /// What a run record keeps of the staging.
    public struct Record: Codable, Sendable, Equatable {
        public let step: String
        public let seed: UInt64

        public init(step: String = SeededPairOrder.stepDescription, seed: UInt64 = SeededPairOrder.seed) {
            self.step = step
            self.seed = seed
        }

        /// The record of single reads staged one by one (trust session R2).
        public static var reads: Record { Record(step: SeededPairOrder.readsStepDescription) }

        public var provenanceValue: ParameterValue {
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
            // The bucket is unpacked into the buffer every bucket shares, read here in place and never copied.
            let length = try buckets.load(bucket)
            for entry in try entries(in: buckets.raw, count: length, bucket: bucket, seed: seed) {
                try output1.append(buckets.raw[entry.r1])
                try output2.append(buckets.raw[entry.r2])
            }
        }
        try output1.flush()
        try output2.flush()
        return pairs
    }

    /// Writes every record of `sources`, one file after another, to `sink` in the seeded order and returns the
    /// records written. It is the single-record form of ``write(_:r1:r2:scratch:seed:bucketCount:)``, so N reads
    /// are permuted the way N pairs are. `scratch` holds the bucket files while it runs and is removed before it
    /// returns.
    static func writeReads(
        _ sources: [URL],
        to sink: FileHandle,
        scratch: URL,
        seed: UInt64 = seed,
        bucketCount: Int? = nil
    ) throws -> Int {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: scratch)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let buckets = BucketFiles(directory: scratch, count: bucketCount ?? Self.bucketCount(for: sources))
        var reads = 0
        for url in sources {
            let reader = try FASTQRawLineReader(url: url)
            defer { reader.close() }
            let file = url.lastPathComponent
            var number = 0
            var finished = false
            // One autorelease pool a read, as for the pairs of ``write(_:r1:r2:scratch:seed:bucketCount:)``.
            while !finished {
                try autoreleasepool {
                    guard let record = try FASTQPairInterleaver.readRecord(from: reader, file: file, recordNumber: number + 1) else {
                        finished = true
                        return
                    }
                    number += 1
                    try buckets.append(key: key(of: UInt64(reads), seed: seed), index: UInt64(reads), joined(record), [])
                    reads += 1
                    if reads & 0x3FFF == 0 { try Task.checkCancellation() }
                }
            }
        }
        try buckets.flushAll()
        var output = Output(handle: sink)
        for bucket in 0..<buckets.count {
            try Task.checkCancellation()
            // The shared buffer, as in ``write(_:r1:r2:scratch:seed:bucketCount:)``.
            let length = try buckets.load(bucket)
            for entry in try entries(in: buckets.raw, count: length, bucket: bucket, seed: seed) {
                try output.append(buckets.raw[entry.r1])
            }
        }
        try output.flush()
        return reads
    }

    /// Hands each pair of `source` to `body` as two whole records with their newlines.
    private static func forEachPair(of source: Source, _ body: ([UInt8], [UInt8]) throws -> Void) throws {
        switch source {
        case .interleaved(let url):
            let reader = try FASTQRawLineReader(url: url)
            defer { reader.close() }
            let file = url.lastPathComponent
            var number = 0
            var finished = false
            // One autorelease pool a pair, so the Foundation objects of reading and checking it go back at once.
            while !finished {
                try autoreleasepool {
                    guard let record1 = try FASTQPairInterleaver.readRecord(from: reader, file: file, recordNumber: number + 1) else {
                        finished = true
                        return
                    }
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
            var finished = false
            // One autorelease pool a pair, as for an interleaved file.
            while !finished {
                try autoreleasepool {
                    let record1 = try next(reader1, r1, &count1)
                    let record2 = try next(reader2, r2, &count2)
                    if let record1, let record2 {
                        try body(joined(record1), joined(record2))
                        return
                    }
                    if record1 == nil && record2 == nil {
                        finished = true
                        return
                    }
                    while try next(reader1, r1, &count1) != nil {}
                    while try next(reader2, r2, &count2) != nil {}
                    throw StagingError.mateCountMismatch(r1Records: count1, r2Records: count2)
                }
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

    /// The pairs of one bucket's bytes, the first `count` of `raw`, sorted by key, then index.
    private static func entries(in raw: [UInt8], count: Int, bucket: Int, seed: UInt64) throws -> [Entry] {
        var entries: [Entry] = []
        var position = 0
        func field(_ width: Int) throws -> Int {
            guard position + width <= count else { throw StagingError.scratchDamaged(bucket: bucket) }
            let value = readInteger(raw, at: position, width: width)
            position += width
            return Int(value)
        }
        func range() throws -> Range<Int> {
            let length = try field(4)
            guard position + length <= count else { throw StagingError.scratchDamaged(bucket: bucket) }
            defer { position += length }
            return position..<position + length
        }
        while position < count {
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
    ///
    /// Packing, file reads and unpacking go through buffers this object keeps
    /// for the whole staging and makes no Foundation object a chunk. The
    /// macOS allocator keeps a freed block of tens of MiB in the footprint
    /// for a while, so a new file buffer and entry array a bucket raised the
    /// footprint by about half the staged text while what was in use stayed
    /// at one bucket (FASTP-MEM-b, measured by phase).
    private final class BucketFiles {
        let count: Int
        private let directory: URL
        private var buffers: [[UInt8]]
        private let flushBytes: Int
        /// One packed chunk, its 8 header bytes first, shared by every flush.
        private var chunk: [UInt8] = []
        /// The whole file of the bucket being read, shared by every bucket.
        private var file: [UInt8] = []
        /// The unpacked entries of the bucket being read, shared by every bucket. Only the first bytes that
        /// ``load(_:)`` returns are the bucket's.
        private(set) var raw: [UInt8] = []
        private let encodeScratch: UnsafeMutableRawPointer
        private let decodeScratch: UnsafeMutableRawPointer

        init(directory: URL, count: Int) {
            self.directory = directory
            self.count = count
            buffers = Array(repeating: [], count: count)
            flushBytes = max(64 << 10, min(1 << 20, (32 << 20) / count))
            encodeScratch = .allocate(byteCount: max(1, compression_encode_scratch_buffer_size(COMPRESSION_LZ4)), alignment: 16)
            decodeScratch = .allocate(byteCount: max(1, compression_decode_scratch_buffer_size(COMPRESSION_LZ4)), alignment: 16)
        }

        deinit {
            encodeScratch.deallocate()
            decodeScratch.deallocate()
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

        /// Writes one bucket's buffer as a packed chunk: its raw length, its packed length and the LZ4-packed bytes. The
        /// chunk is packed into a buffer every flush shares and appended to the bucket's file with POSIX calls.
        private func flush(_ bucket: Int) throws {
            let rawCount = buffers[bucket].count
            guard rawCount > 0 else { return }
            // LZ4 adds at most about 0.4% and a few block headers to bytes it cannot pack, so this room always holds it.
            let room = rawCount + rawCount / 8 + 4096
            if chunk.count < 8 + room {
                chunk = []
                chunk = Self.zeroed(8 + room + room / 8)
            }
            let scratch = encodeScratch
            let packedCount = buffers[bucket].withUnsafeBufferPointer { source in
                chunk.withUnsafeMutableBufferPointer { destination in
                    compression_encode_buffer(
                        destination.baseAddress! + 8, room, source.baseAddress!, rawCount, scratch, COMPRESSION_LZ4
                    )
                }
            }
            guard packedCount > 0 else { throw StagingError.scratchDamaged(bucket: bucket) }
            for shift in 0..<4 {
                chunk[shift] = UInt8(truncatingIfNeeded: rawCount >> (8 * shift))
                chunk[4 + shift] = UInt8(truncatingIfNeeded: packedCount >> (8 * shift))
            }
            let path = url(bucket).path
            let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw Self.posixError() }
            defer { Darwin.close(descriptor) }
            try chunk.withUnsafeBytes { bytes in
                var offset = 0
                while offset < 8 + packedCount {
                    let written = Darwin.write(descriptor, bytes.baseAddress! + offset, 8 + packedCount - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Self.posixError()
                    }
                    offset += written
                }
            }
            buffers[bucket].removeAll(keepingCapacity: true)
        }

        /// Unpacks `bucket` into ``raw`` and returns how many of its first bytes are the bucket's entries. Its file is
        /// read whole into a buffer every bucket shares and removed once read, and each chunk is unpacked straight into
        /// its place in ``raw``. A bucket no pair fell into has no file and no entries.
        func load(_ bucket: Int) throws -> Int {
            let path = url(bucket).path
            let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno == ENOENT { return 0 }
                throw StagingError.scratchDamaged(bucket: bucket)
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                Darwin.close(descriptor)
                throw StagingError.scratchDamaged(bucket: bucket)
            }
            let size = Int(status.st_size)
            if file.count < size {
                file = []
                file = Self.zeroed(size + size / 8)
            }
            let read = file.withUnsafeMutableBytes { bytes -> Int in
                var offset = 0
                while offset < size {
                    let count = Darwin.read(descriptor, bytes.baseAddress! + offset, size - offset)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    offset += count
                }
                return offset
            }
            Darwin.close(descriptor)
            unlink(path)
            guard read == size else { throw StagingError.scratchDamaged(bucket: bucket) }

            var expected = 0
            var position = 0
            while position + 8 <= size {
                let packedCount = Int(SeededPairOrder.readInteger(file, at: position + 4, width: 4))
                guard position + 8 + packedCount <= size else { break }
                expected += Int(SeededPairOrder.readInteger(file, at: position, width: 4))
                position += 8 + packedCount
            }
            if raw.count < expected {
                raw = []
                raw = Self.zeroed(expected + expected / 8)
            }
            let scratch = decodeScratch
            var filled = 0
            position = 0
            while position < size {
                guard position + 8 <= size else { throw StagingError.scratchDamaged(bucket: bucket) }
                let rawCount = Int(SeededPairOrder.readInteger(file, at: position, width: 4))
                let packedCount = Int(SeededPairOrder.readInteger(file, at: position + 4, width: 4))
                guard position + 8 + packedCount <= size, filled + rawCount <= expected else {
                    throw StagingError.scratchDamaged(bucket: bucket)
                }
                let start = position + 8
                let unpacked = file.withUnsafeBufferPointer { source in
                    raw.withUnsafeMutableBufferPointer { destination in
                        compression_decode_buffer(
                            destination.baseAddress! + filled, rawCount, source.baseAddress! + start, packedCount, scratch,
                            COMPRESSION_LZ4
                        )
                    }
                }
                guard unpacked == rawCount else { throw StagingError.scratchDamaged(bucket: bucket) }
                filled += rawCount
                position = start + packedCount
            }
            return filled
        }

        /// An array of `count` zero bytes, made with one fill rather than a loop of appends.
        private static func zeroed(_ count: Int) -> [UInt8] {
            [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
                if let base = buffer.baseAddress { memset(base, 0, count) }
                initialized = count
            }
        }

        /// The error of the POSIX call that just failed, as Foundation words it ("No space left on device").
        private static func posixError() -> Error {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
