// RNASeqCellMapGenes.swift - The gene pass of a cell map, gene_values from the parent's matrices (Phase 5.5 lane CM-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `gene_values` holds one gene-major row a Gene Expression feature (`docs/formats/rnaseq-cell-map.md`, Gene values), which
// is a transpose of the parent's cell-ordered matrices. Held in memory the transpose takes 8 B an entry, 8.2 GB at X5, so
// it spills to disk (SWIFT OBJECT 1, 5.5 O8). One pass over each matrix appends (feature, cell, UMIs) to about 64 bucket
// files by feature range, each range holding about a 64th of the entries by `features.cells`. Then each bucket in turn is
// read back, every entry is placed by the `features.cells` offsets, and each gene is encoded and written. Memory is one
// batch of the matrix, one write buffer a bucket and one bucket's entries. The bucket files sit in the writer's stage on
// the destination volume and go with the stage on a cancel or a failure, and the pass removes each once it is placed.

import Foundation
import LungfishCore
import LungfishIO

public enum RNASeqCellMapGenes {
    public static let bucketTarget = 64
    /// A bucket record is a feature within its range (2 B), a cell id (4 B) and the UMIs (2 B, or 6 B past 65,534).
    public static let temporaryBytesPerEntry: Int64 = 8
    /// The estimate of `gene_values` for an entry: a cell id of 1 or 2 bytes, UMIs of 1 or 2 and a float32 of 4, with
    /// SQLite's page overhead.
    public static let outputBytesPerEntry: Int64 = 8
    /// The estimate for one coordinate row of `coordinates`, a key of three numbers and a REAL, with page overhead.
    public static let outputBytesPerCoordinate: Int64 = 40

    /// The facts of one pass that the record and the X5 measure name.
    public struct Summary: Equatable, Sendable {
        public var cells: Int
        public var geneExpressionFeatures: Int
        /// The not-host features among the Gene Expression features.
        public var notHostFeatures: Int
        /// The features of each other type, left out of `gene_values` (5.5 G1).
        public var otherTypes: [String: Int]
        public var entries: Int
        public var buckets: Int
        /// The bytes the bucket files held after the first pass, the peak of the pass's temporary files.
        public var temporaryBytes: Int64
        /// The bytes of the `cell_ids`, `umis` and `normalised` blobs, and of the first two alone (5.5 O8).
        public var blobBytesWithNormalised: Int64
        public var blobBytesWithoutNormalised: Int64
    }

    /// The steps a caller observes, each after it is done.
    public enum Step: Equatable, Sendable { case spilled, placed(bucket: Int) }

    /// One matrix of the parent, already checked against its sha256, and the id of its first cell in the map.
    struct Matrix {
        var url: URL
        var path: String
        var firstCell: Int
        var columns: Int
    }

    /// The temporary bytes of the pass and the estimated bytes of a cell map, from the matrices' entries, the number of
    /// coordinate values and the cells. The writer checks their sum against the volume's free space before it writes.
    public static func estimate(entries: Int, coordinateValues: Int, cells: Int) -> (temporary: Int64, output: Int64) {
        let temporary = Int64(entries) * temporaryBytesPerEntry
        let output = Int64(entries) * outputBytesPerEntry + Int64(coordinateValues) * outputBytesPerCoordinate + Int64(cells) * 128 + (1 << 20)
        return (temporary, output)
    }

    struct Bucket {
        var first: Int   // index into the Gene Expression features
        var end: Int
        var entries: Int
    }

    /// Ranges of the Gene Expression features, each holding at most a 64th of the entries (a lone feature above that
    /// holds a bucket by itself) and at most 65,535 features, so a feature within its range fits in 2 bytes.
    static func buckets(cellsOfFeature: [Int]) -> [Bucket] {
        let total = cellsOfFeature.reduce(0, +)
        let target = max(1, (total + bucketTarget - 1) / bucketTarget)
        var found: [Bucket] = []
        var current = Bucket(first: 0, end: 0, entries: 0)
        for (index, cells) in cellsOfFeature.enumerated() {
            if current.end > current.first, current.entries + cells > target || current.end - current.first == Int(UInt16.max) {
                found.append(current)
                current = Bucket(first: index, end: index, entries: 0)
            }
            current.end = index + 1
            current.entries += cells
        }
        if current.end > current.first { found.append(current) }
        return found
    }

    /// Runs the pass and writes one `gene_values` row a Gene Expression feature through `writer`, in feature order.
    static func run(
        matrices: [Matrix], features: [RNASeqCellsDatabase.Feature], cellUMIs: [UInt64], notHost: Set<String>,
        spill: URL, writer: RNASeqCellMapDatabaseWriter, observe: (Step) throws -> Void
    ) throws -> Summary {
        let geneExpression = features.filter { $0.type == RNASeqPseudobulk.geneExpression }
        var otherTypes: [String: Int] = [:]
        for feature in features where feature.type != RNASeqPseudobulk.geneExpression { otherTypes[feature.type, default: 0] += 1 }
        let buckets = buckets(cellsOfFeature: geneExpression.map(\.cells))
        var bucketOfRow = [Int32](repeating: -1, count: features.count + 1)
        var localOfRow = [UInt16](repeating: 0, count: features.count + 1)
        for (number, bucket) in buckets.enumerated() {
            for index in bucket.first..<bucket.end {
                let row = geneExpression[index].feature
                guard row >= 1, row <= features.count else {
                    throw RNASeqResultError.invalidTable(path: RNASeqCellsDatabase.filename, reason: "its features are not numbered 1 to \(features.count)")
                }
                bucketOfRow[row] = Int32(number)
                localOfRow[row] = UInt16(index - bucket.first)
            }
        }
        try FileManager.default.createDirectory(at: spill, withIntermediateDirectories: false)
        let files = buckets.indices.map { spill.appendingPathComponent("bucket-\($0)") }
        let temporaryBytes = try spillEntries(matrices, files: files, cellCount: cellUMIs.count, bucketOfRow: bucketOfRow, localOfRow: localOfRow)
        try observe(.spilled)

        var summary = Summary(
            cells: cellUMIs.count, geneExpressionFeatures: geneExpression.count,
            notHostFeatures: geneExpression.filter { notHost.contains($0.id) }.count, otherTypes: otherTypes,
            entries: 0, buckets: buckets.count, temporaryBytes: temporaryBytes, blobBytesWithNormalised: 0, blobBytesWithoutNormalised: 0)
        for (number, bucket) in buckets.enumerated() {
            try place(bucket, file: files[number], features: Array(geneExpression[bucket.first..<bucket.end]), cellUMIs: cellUMIs,
                      writer: writer, summary: &summary)
            try FileManager.default.removeItem(at: files[number])
            try observe(.placed(bucket: number))
        }
        try FileManager.default.removeItem(at: spill)
        return summary
    }

    /// The first pass: every entry of a Gene Expression feature, appended to its bucket's file. Returns the bytes written.
    private static func spillEntries(
        _ matrices: [Matrix], files: [URL], cellCount: Int, bucketOfRow: [Int32], localOfRow: [UInt16]
    ) throws -> Int64 {
        let flushAt = 1 << 17
        var handles: [FileHandle] = []
        defer { for handle in handles { try? handle.close() } }
        for file in files {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw RNASeqResultWriterError.cannotCreate(file.lastPathComponent)
            }
            handles.append(try FileHandle(forWritingTo: file))
        }
        var buffers = files.map { _ -> [UInt8] in
            var buffer: [UInt8] = []
            buffer.reserveCapacity(flushAt + 16)
            return buffer
        }
        var written: Int64 = 0
        func flush(_ bucket: Int) throws {
            guard !buffers[bucket].isEmpty else { return }
            try handles[bucket].write(contentsOf: buffers[bucket])
            written += Int64(buffers[bucket].count)
            buffers[bucket].removeAll(keepingCapacity: true)
        }
        for matrix in matrices {
            let reader = try MatrixMarketReader(url: matrix.url)
            defer { reader.close() }
            guard reader.size.rows == bucketOfRow.count - 1, reader.size.columns == matrix.columns else {
                throw RNASeqResultError.invalidTable(path: matrix.path, reason: "its size line differs from the counts of cells.sqlite")
            }
            var batch = MatrixMarketBatch(capacity: 1 << 16)
            while try reader.next(&batch) {
                try Task.checkCancellation()
                let rows = batch.rows
                let columns = batch.columns
                let values = batch.values
                for index in 0..<values.count where values[index] > 0 {
                    let bucket = Int(bucketOfRow[rows[index]])
                    guard bucket >= 0 else { continue }
                    let cell = UInt32(matrix.firstCell + columns[index] - 1)
                    let local = localOfRow[rows[index]]
                    let umis = values[index]
                    guard umis <= UInt64(UInt32.max) else {
                        throw RNASeqResultError.invalidTable(path: matrix.path, reason: "an entry holds \(umis) UMIs, past the 32 bits a count of one gene in one cell takes")
                    }
                    buffers[bucket].append(UInt8(truncatingIfNeeded: local))
                    buffers[bucket].append(UInt8(truncatingIfNeeded: local >> 8))
                    for shift in stride(from: 0, to: 32, by: 8) { buffers[bucket].append(UInt8(truncatingIfNeeded: cell >> UInt32(shift))) }
                    if umis < 0xFFFF {
                        buffers[bucket].append(UInt8(truncatingIfNeeded: umis))
                        buffers[bucket].append(UInt8(truncatingIfNeeded: umis >> 8))
                    } else {
                        buffers[bucket].append(0xFF)
                        buffers[bucket].append(0xFF)
                        for shift in stride(from: 0, to: 32, by: 8) { buffers[bucket].append(UInt8(truncatingIfNeeded: umis >> UInt64(shift))) }
                    }
                    if buffers[bucket].count >= flushAt { try flush(bucket) }
                }
            }
        }
        for bucket in files.indices { try flush(bucket) }
        for handle in handles { try handle.synchronize() }
        return written
    }

    /// The second step for one bucket: read its file back, place each entry by the `features.cells` offsets, then encode
    /// and write each gene. A feature whose entries differ from `features.cells` or `features.total` is refused.
    private static func place(
        _ bucket: Bucket, file: URL, features: [RNASeqCellsDatabase.Feature], cellUMIs: [UInt64],
        writer: RNASeqCellMapDatabaseWriter, summary: inout Summary
    ) throws {
        var offsets = [Int](repeating: 0, count: features.count + 1)
        for (index, feature) in features.enumerated() { offsets[index + 1] = offsets[index] + feature.cells }
        var cursor = Array(offsets.dropLast())
        var cells = [UInt32](repeating: 0, count: offsets[features.count])
        var umis = [UInt32](repeating: 0, count: offsets[features.count])
        func mismatch(_ feature: RNASeqCellsDatabase.Feature) -> RNASeqResultError {
            .invalidTable(path: RNASeqCellsDatabase.filename, reason: "the matrices give the feature \(feature.id) other entries than its row in cells.sqlite counts")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var pending: [UInt8] = []
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            try Task.checkCancellation()
            pending.append(contentsOf: chunk)
            var at = 0
            while pending.count - at >= 8 {
                let local = Int(pending[at]) | Int(pending[at + 1]) << 8
                var cell: UInt32 = 0
                for byte in 0..<4 { cell |= UInt32(pending[at + 2 + byte]) << UInt32(8 * byte) }
                var value = UInt32(pending[at + 6]) | UInt32(pending[at + 7]) << 8
                var length = 8
                if value == 0xFFFF {
                    guard pending.count - at >= 12 else { break }
                    value = 0
                    for byte in 0..<4 { value |= UInt32(pending[at + 8 + byte]) << UInt32(8 * byte) }
                    length = 12
                }
                guard local < features.count else { throw mismatch(features[features.count - 1]) }
                guard cursor[local] < offsets[local + 1] else { throw mismatch(features[local]) }
                cells[cursor[local]] = cell
                umis[cursor[local]] = value
                cursor[local] += 1
                at += length
            }
            pending.removeFirst(at)
            return true
        }) {}
        guard pending.isEmpty else {
            throw RNASeqResultError.unreadableFile(path: file.lastPathComponent, reason: "the gene pass's temporary file ends inside an entry")
        }
        let cellCount = cellUMIs.count
        for (index, feature) in features.enumerated() {
            guard cursor[index] == offsets[index + 1] else { throw mismatch(feature) }
            var range = Array(offsets[index]..<offsets[index + 1])
            if zip(range, range.dropFirst()).contains(where: { cells[$0] >= cells[$1] }) {
                range.sort { cells[$0] < cells[$1] }
                guard !zip(range, range.dropFirst()).contains(where: { cells[$0] == cells[$1] }) else {
                    throw RNASeqResultError.invalidTable(path: RNASeqCellsDatabase.filename, reason: "a matrix lists the feature \(feature.id) twice for one cell")
                }
            }
            var total: UInt64 = 0
            var umiBytes: [UInt8] = []
            var normalised: [Float] = []
            normalised.reserveCapacity(range.count)
            var counts: [UInt64] = []
            counts.reserveCapacity(range.count)
            for position in range {
                let cell = Int(cells[position])
                guard cell >= 1, cell <= cellCount, cellUMIs[cell - 1] > 0 else { throw mismatch(feature) }
                let value = UInt64(umis[position])
                total += value
                counts.append(value)
                RNASeqCellMap.appendLEB128(value, to: &umiBytes)
                normalised.append(RNASeqCellMap.normalised(umis: value, cellUMIs: cellUMIs[cell - 1]))
            }
            guard total == UInt64(feature.total) else { throw mismatch(feature) }
            let cellIDs = RNASeqCellMap.encodeCellIDs(range.lazy.map { cells[$0] })
            let floatBytes = RNASeqCellMap.encodeFloats(normalised)
            let umiBounds = RNASeqCellMap.bounds(nonZero: counts, cells: cellCount)
            let floatBounds = RNASeqCellMap.bounds(nonZero: normalised, cells: cellCount)
            try writer.addGeneValues(.init(
                feature: feature.feature, cells: range.count, cellIDs: cellIDs, umis: umiBytes, normalised: floatBytes,
                umisBounds: umiBounds, normalisedBounds: floatBounds))
            summary.entries += range.count
            summary.blobBytesWithoutNormalised += Int64(cellIDs.count + umiBytes.count)
            summary.blobBytesWithNormalised += Int64(cellIDs.count + umiBytes.count + floatBytes.count)
        }
    }
}
