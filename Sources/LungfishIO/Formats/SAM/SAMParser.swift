// SAMParser.swift - Parser for SAM text output from samtools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - SAMParser

/// Parses SAM text output (from `samtools view`) into `AlignedRead` records.
///
/// This parser handles the standard 11-column SAM format plus optional auxiliary tags.
/// It is designed to process the stdout of `samtools view` calls, parsing one read per line.
///
/// ## Performance
///
/// Parsing is done line-by-line with minimal allocations. For a typical region fetch
/// of ~2,000 reads, parsing completes in under 10ms.
///
/// ## Example
///
/// ```swift
/// let result = try await NativeToolRunner.shared.run(tool: .samtools, arguments: ["view", bamPath, region])
/// let reads = SAMParser.parse(result.stdout, maxReads: 10_000)
/// ```
public enum SAMParser {

    // MARK: - Header Parsing

    /// A read group from the SAM @RG header line.
    public struct ReadGroup: Sendable {
        public let id: String
        public let sample: String?
        public let library: String?
        public let platform: String?
        public let platformUnit: String?
        public let center: String?
        public let description: String?
    }

    /// Parses @RG header lines from SAM header text.
    ///
    /// - Parameter headerText: Full SAM header (lines starting with @)
    /// - Returns: Array of parsed read groups
    public static func parseReadGroups(from headerText: String) -> [ReadGroup] {
        var groups: [ReadGroup] = []

        for line in headerText.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("@RG") else { continue }

            var id: String?
            var sample: String?
            var library: String?
            var platform: String?
            var platformUnit: String?
            var center: String?
            var description: String?

            let fields = line.split(separator: "\t")
            for field in fields.dropFirst() {
                let parts = field.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let tag = parts[0]
                let value = String(parts[1])

                switch tag {
                case "ID": id = value
                case "SM": sample = value
                case "LB": library = value
                case "PL": platform = value
                case "PU": platformUnit = value
                case "CN": center = value
                case "DS": description = value
                default: break
                }
            }

            if let id {
                groups.append(ReadGroup(
                    id: id, sample: sample, library: library,
                    platform: platform, platformUnit: platformUnit,
                    center: center, description: description
                ))
            }
        }

        return groups
    }

    // MARK: - Program Record Parsing

    /// A program record from the SAM @PG header line.
    public struct ProgramRecord: Sendable {
        /// Program ID (required).
        public let id: String
        /// Program name.
        public let name: String?
        /// Program version.
        public let version: String?
        /// Command line used to run the program.
        public let commandLine: String?
        /// ID of the previous program in the chain.
        public let previousProgram: String?
    }

    /// Parses @PG header lines from SAM header text.
    public static func parseProgramRecords(from headerText: String) -> [ProgramRecord] {
        var records: [ProgramRecord] = []

        for line in headerText.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("@PG") else { continue }

            var id: String?
            var name: String?
            var version: String?
            var commandLine: String?
            var previousProgram: String?

            let fields = line.split(separator: "\t")
            for field in fields.dropFirst() {
                let parts = field.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let tag = parts[0]
                let value = String(parts[1])

                switch tag {
                case "ID": id = value
                case "PN": name = value
                case "VN": version = value
                case "CL": commandLine = value
                case "PP": previousProgram = value
                default: break
                }
            }

            if let id {
                records.append(ProgramRecord(
                    id: id, name: name, version: version,
                    commandLine: commandLine, previousProgram: previousProgram
                ))
            }
        }

        return records
    }

    /// A header line from the SAM @HD record.
    public struct HeaderRecord: Sendable {
        /// Format version.
        public let version: String?
        /// Sorting order.
        public let sortOrder: String?
        /// Grouping of alignments.
        public let groupOrder: String?
    }

    /// Parses the @HD header line from SAM header text.
    public static func parseHeaderRecord(from headerText: String) -> HeaderRecord? {
        for line in headerText.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("@HD") else { continue }

            var version: String?
            var sortOrder: String?
            var groupOrder: String?

            let fields = line.split(separator: "\t")
            for field in fields.dropFirst() {
                let parts = field.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let tag = parts[0]
                let value = String(parts[1])

                switch tag {
                case "VN": version = value
                case "SO": sortOrder = value
                case "GO": groupOrder = value
                default: break
                }
            }

            return HeaderRecord(version: version, sortOrder: sortOrder, groupOrder: groupOrder)
        }
        return nil
    }

    /// Counts the number of @SQ (sequence/reference) lines in the header.
    public static func referenceSequenceCount(from headerText: String) -> Int {
        headerText.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("@SQ") }
            .count
    }

    /// A reference sequence from the SAM @SQ header line.
    public struct ReferenceSequence: Sendable {
        /// Sequence name (SN tag).
        public let name: String
        /// Sequence length (LN tag).
        public let length: Int64
        /// MD5 checksum (M5 tag, if present).
        public let md5: String?
        /// Assembly identifier (AS tag, if present).
        public let assembly: String?
        /// URI of the sequence (UR tag, if present).
        public let uri: String?
        /// Species (SP tag, if present).
        public let species: String?
    }

    /// Parses @SQ header lines into reference sequence records.
    ///
    /// - Parameter headerText: Full SAM header text
    /// - Returns: Array of reference sequences with names, lengths, and optional metadata
    public static func parseReferenceSequences(from headerText: String) -> [ReferenceSequence] {
        var sequences: [ReferenceSequence] = []

        for line in headerText.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("@SQ") else { continue }

            var name: String?
            var length: Int64?
            var md5: String?
            var assembly: String?
            var uri: String?
            var species: String?

            let fields = line.split(separator: "\t")
            for field in fields.dropFirst() {
                let parts = field.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let tag = parts[0]
                let value = String(parts[1])

                switch tag {
                case "SN": name = value
                case "LN": length = Int64(value)
                case "M5": md5 = value
                case "AS": assembly = value
                case "UR": uri = value
                case "SP": species = value
                default: break
                }
            }

            if let name, let length {
                sequences.append(ReferenceSequence(
                    name: name, length: length, md5: md5,
                    assembly: assembly, uri: uri, species: species
                ))
            }
        }

        return sequences
    }

    // MARK: - Read Parsing

    /// Parses SAM text into an array of aligned reads.
    ///
    /// Skips header lines (starting with @) and unmapped reads.
    /// Returns up to `maxReads` records.
    ///
    /// - Parameters:
    ///   - samText: SAM-formatted text (one alignment per line)
    ///   - maxReads: Maximum number of reads to return (default 10,000)
    /// - Returns: Array of parsed aligned reads
    public static func parse(_ samText: String, maxReads: Int = 10_000) -> [AlignedRead] {
        var reads: [AlignedRead] = []
        reads.reserveCapacity(min(maxReads, 2000))

        for line in samText.split(separator: "\n", omittingEmptySubsequences: true) {
            if reads.count >= maxReads { break }
            guard !line.hasPrefix("@") else { continue }

            if let read = parseLine(line) {
                reads.append(read)
            }
        }

        return reads
    }

    /// Parses a single SAM alignment line into an AlignedRead.
    ///
    /// - Parameter line: A single SAM record line (tab-delimited, 11+ fields)
    /// - Returns: The parsed read, or nil if the line is malformed or the read is unmapped
    public static func parseLine(_ line: some StringProtocol) -> AlignedRead? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 11 else { return nil }

        // Field 0: QNAME (read name)
        let name = String(fields[0])

        // Field 1: FLAG
        guard let flag = UInt16(fields[1]) else { return nil }

        // Skip unmapped reads
        if flag & 0x4 != 0 { return nil }

        // Field 2: RNAME (chromosome)
        let chromosome = String(fields[2])
        guard chromosome != "*" else { return nil }

        // Field 3: POS (1-based) → convert to 0-based
        guard let pos1Based = Int(fields[3]), pos1Based > 0 else { return nil }
        let position = pos1Based - 1

        // Field 4: MAPQ
        let mapq = UInt8(fields[4]) ?? 0

        // Field 5: CIGAR
        guard let cigar = CIGAROperation.parse(String(fields[5])) else { return nil }

        // Field 6: RNEXT (mate chromosome)
        let rnext = String(fields[6])
        let mateChromosome: String?
        if rnext == "*" || rnext == "=" {
            mateChromosome = rnext == "=" ? chromosome : nil
        } else {
            mateChromosome = rnext
        }

        // Field 7: PNEXT (mate position, 1-based) → 0-based
        let matePosition: Int?
        if let pnext = Int(fields[7]), pnext > 0 {
            matePosition = pnext - 1
        } else {
            matePosition = nil
        }

        // Field 8: TLEN (insert size)
        let insertSize = Int(fields[8]) ?? 0

        // Field 9: SEQ ("*" means unavailable sequence)
        let sequence = fields[9] == "*" ? "" : String(fields[9])

        // Field 10: QUAL (Phred+33 encoded)
        let qualString = fields[10]
        let qualities: [UInt8]
        if qualString == "*" {
            qualities = []
        } else {
            qualities = qualString.utf8.map { UInt8(max(0, Int($0) - 33)) }
        }

        // Optional tags (fields 11+)
        var readGroup: String?
        var mdTag: String?
        var editDistance: Int?
        var supplementaryAlignments: String?
        var numHits: Int?
        var strandTag: String?

        for i in 11..<fields.count {
            let tag = fields[i]
            if tag.hasPrefix("RG:Z:") {
                readGroup = String(tag.dropFirst(5))
            } else if tag.hasPrefix("MD:Z:") {
                mdTag = String(tag.dropFirst(5))
            } else if tag.hasPrefix("NM:i:") {
                editDistance = Int(tag.dropFirst(5))
            } else if tag.hasPrefix("SA:Z:") {
                supplementaryAlignments = String(tag.dropFirst(5))
            } else if tag.hasPrefix("NH:i:") {
                numHits = Int(tag.dropFirst(5))
            } else if tag.hasPrefix("XS:A:") {
                strandTag = String(tag.dropFirst(5))
            }
        }

        return AlignedRead(
            name: name,
            flag: flag,
            chromosome: chromosome,
            position: position,
            mapq: mapq,
            cigar: cigar,
            sequence: sequence,
            qualities: qualities,
            mateChromosome: mateChromosome,
            matePosition: matePosition,
            insertSize: insertSize,
            readGroup: readGroup,
            mdTag: mdTag,
            editDistance: editDistance,
            supplementaryAlignments: supplementaryAlignments,
            numHits: numHits,
            strandTag: strandTag
        )
    }
}
