// FASTQDerivativeFileIO.swift - Pointer-based FASTQ derivative datasets
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit

// MARK: - Orient Map File I/O

/// Reads and writes `orient-map.tsv` files used by orient derivative bundles.
public enum FASTQOrientMapFile {

    /// Writes orientation records to a TSV file. Format: `readID\torientation\n`
    /// where orientation is "+" (forward) or "-" (reverse complemented).
    ///
    /// - Precondition: Each record's orientation must be "+" or "-".
    public static func write(_ records: [(readID: String, orientation: String)], to url: URL) throws {
        try FASTQAtomicFileWriter.write(to: url) { handle in
            for record in records {
                precondition(record.orientation == "+" || record.orientation == "-",
                             "Orientation must be + or -, got \(record.orientation)")
                guard let data = "\(record.readID)\t\(record.orientation)\n"
                    .data(using: .utf8) else { continue }
                handle.write(data)
            }
        }
    }

    /// Loads orientation records from a TSV file into a dictionary keyed by read ID.
    /// Values are "+" (already forward) or "-" (was reverse complemented).
    public static func load(from url: URL) throws -> [String: String] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var orientations: [String: String] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t")
            guard fields.count >= 2 else { continue }
            let readID = String(fields[0])
            let orientation = String(fields[1])
            guard orientation == "+" || orientation == "-" else { continue }
            orientations[readID] = orientation
        }
        return orientations
    }

    /// Returns the set of read IDs that need reverse complementing.
    public static func loadRCReadIDs(from url: URL) throws -> Set<String> {
        let content = try String(contentsOf: url, encoding: .utf8)
        var rcIDs: Set<String> = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t")
            guard fields.count >= 2, fields[1] == "-" else { continue }
            rcIDs.insert(String(fields[0]))
        }
        return rcIDs
    }

    /// Returns the set of forward-oriented read IDs ("+").
    public static func loadForwardReadIDs(from url: URL) throws -> Set<String> {
        let content = try String(contentsOf: url, encoding: .utf8)
        var fwdIDs: Set<String> = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t")
            guard fields.count >= 2, fields[1] == "+" else { continue }
            fwdIDs.insert(String(fields[0]))
        }
        return fwdIDs
    }
}

// MARK: - Trim Position Record

/// A single read's trim boundaries, referencing positions in the root FASTQ sequence.
public struct FASTQTrimRecord: Sendable, Equatable {
    /// Normalized read identifier.
    public let readID: String
    /// Mate number: 0 = single-end/unknown, 1 = R1, 2 = R2.
    public let mate: Int
    /// 0-based inclusive start position in the original sequence.
    public let trimStart: Int
    /// Exclusive end position in the original sequence.
    public let trimEnd: Int

    public init(readID: String, mate: Int = 0, trimStart: Int, trimEnd: Int) {
        precondition(trimStart >= 0, "trimStart must be non-negative")
        precondition(trimEnd >= 0, "trimEnd must be non-negative")
        precondition(trimEnd >= trimStart, "trimEnd (\(trimEnd)) must be >= trimStart (\(trimStart))")
        self.readID = readID
        self.mate = mate
        self.trimStart = trimStart
        self.trimEnd = trimEnd
    }

    /// The length of the trimmed subsequence.
    public var trimmedLength: Int { max(0, trimEnd - trimStart) }
}

// MARK: - Trim Position File I/O

/// Reads and writes `trim-positions.tsv` files used by trim derivative bundles.
///
/// **Format v2** (current): `#format lungfish-trim-v2\nread_id\tmate\ttrim_start\ttrim_end\n`
/// - Absolute coordinates: trimStart/trimEnd are positions in the ROOT sequence.
/// - Mate-aware: mate column (0=single, 1=R1, 2=R2).
///
/// **Format v1** (legacy): `read_id\ttrim_5p\ttrim_3p\n` or 4-column `read_id\tmate\ttrim_5p\ttrim_3p\n`
/// - Relative offsets: trim_5p/trim_3p are bases removed from each end.
/// - Detected by absence of `#format` header line.
public enum FASTQTrimPositionFile {

    public static let formatHeader = "#format lungfish-trim-v2"

    /// Writes trim records in v2 format with `#format` header and mate column.
    /// Uses atomic write (tmp file + rename) and streaming FileHandle writes.
    public static func write(_ records: [FASTQTrimRecord], to url: URL) throws {
        try FASTQAtomicFileWriter.write(to: url) { handle in
            if let headerData = "\(formatHeader)\nread_id\tmate\ttrim_start\ttrim_end\n".data(using: .utf8) {
                handle.write(headerData)
            }
            for record in records {
                guard let data = "\(record.readID)\t\(record.mate)\t\(record.trimStart)\t\(record.trimEnd)\n"
                    .data(using: .utf8) else { continue }
                handle.write(data)
            }
        }
    }

    /// Loads trim records from a TSV file into a dictionary keyed by bare read ID.
    /// Auto-detects v1 vs v2 format via `#format` header.
    /// For PE data, the last mate's entry wins (use `loadRecords` for full fidelity).
    /// Records with invalid ranges are skipped.
    public static func load(from url: URL) throws -> [String: (start: Int, end: Int)] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var positions: [String: (Int, Int)] = [:]
        let isV2 = content.hasPrefix(formatHeader)

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") || line.hasPrefix("read_id") { continue }
            let fields = line.split(separator: "\t")
            if isV2 {
                // v2: read_id, mate, trim_start, trim_end
                guard fields.count >= 4,
                      let start = Int(fields[2]),
                      let end = Int(fields[3]),
                      start >= 0, end >= 0, end > start else { continue }
                positions[String(fields[0])] = (start, end)
            } else if fields.count >= 3,
                      let start = Int(fields[1]),
                      let end = Int(fields[2]),
                      start >= 0, end >= 0, end > start {
                positions[String(fields[0])] = (start, end)
            }
        }
        return positions
    }

    /// Loads trim records as an array (preserving order).
    /// Auto-detects v1 vs v2 format.
    public static func loadRecords(from url: URL) throws -> [FASTQTrimRecord] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var records: [FASTQTrimRecord] = []
        let isV2 = content.hasPrefix(formatHeader)

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") || line.hasPrefix("read_id") { continue }
            let fields = line.split(separator: "\t")
            if isV2 {
                guard fields.count >= 4,
                      let mate = Int(fields[1]),
                      let start = Int(fields[2]),
                      let end = Int(fields[3]),
                      start >= 0, end >= 0, end > start else { continue }
                records.append(FASTQTrimRecord(readID: String(fields[0]), mate: mate, trimStart: start, trimEnd: end))
            } else if fields.count >= 3,
                      let start = Int(fields[1]),
                      let end = Int(fields[2]),
                      start >= 0, end >= 0, end > start {
                records.append(FASTQTrimRecord(readID: String(fields[0]), trimStart: start, trimEnd: end))
            }
        }
        return records
    }

    /// Composes two sets of trim positions.
    ///
    /// When a trim-of-trim chain exists, child positions are relative to the parent's
    /// trimmed sequence. This computes absolute positions relative to the root FASTQ.
    ///
    /// - Parameters:
    ///   - parent: Trim positions from the parent operation (absolute, relative to root).
    ///   - child: Trim positions from the child operation (relative to parent's trimmed output).
    /// - Returns: Composed absolute positions for reads present in both sets.
    public static func compose(
        parent: [String: (start: Int, end: Int)],
        child: [String: (start: Int, end: Int)]
    ) -> [String: (start: Int, end: Int)] {
        var result: [String: (start: Int, end: Int)] = [:]
        for (readID, childPos) in child {
            guard let parentPos = parent[readID] else { continue }
            let absoluteStart = parentPos.start + childPos.start
            let absoluteEnd = min(parentPos.start + childPos.end, parentPos.end)
            guard absoluteEnd > absoluteStart else { continue }
            result[readID] = (absoluteStart, absoluteEnd)
        }
        return result
    }
}
