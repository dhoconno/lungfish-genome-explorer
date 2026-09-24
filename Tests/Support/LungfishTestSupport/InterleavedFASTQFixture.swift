// InterleavedFASTQFixture.swift - Small interleaved paired-end FASTQ fixtures
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Paired imports are stored as ONE interleaved FASTQ (mate 2 directly after
// mate 1). Real bundles name mates three ways: identically (no suffix, no
// description), with `/1` `/2` suffixes, or with Casava ` 1:N:0:X` fields.
// Every pair-aware operation must keep mates together for all three, so the
// tests share this generator instead of each rolling its own.

import Foundation
import LungfishIO
import LungfishWorkflow
import XCTest

public enum InterleavedFASTQFixture {
    /// How the two mates of a fragment are named.
    public enum MateNaming: String, CaseIterable, Sendable {
        /// `@frag7` twice. The HG002 case that broke every name-based guess.
        case identical
        /// `@frag7/1` then `@frag7/2`.
        case slashSuffix
        /// `@frag7 1:N:0:ACGT` then `@frag7 2:N:0:ACGT`.
        case casava
    }

    /// Sequences for one pair. Defaults to distinct, high-complexity reads.
    public typealias PairSequences = @Sendable (_ pairIndex: Int) -> (mate1: String, mate2: String)

    /// The fragment name shared by both mates of pair `index`.
    public static func fragmentName(_ index: Int) -> String {
        "frag\(index)"
    }

    /// The header line (without `@`) for one mate.
    public static func header(pairIndex: Int, mate: Int, naming: MateNaming) -> String {
        let name = fragmentName(pairIndex)
        switch naming {
        case .identical: return name
        case .slashSuffix: return "\(name)/\(mate)"
        case .casava: return "\(name) \(mate):N:0:ACGT"
        }
    }

    /// Deterministic pseudo-random 60-base reads, distinct per pair and mate.
    public static func defaultSequences(_ pairIndex: Int) -> (mate1: String, mate2: String) {
        (deterministicSequence(seed: UInt64(pairIndex) * 2 + 1),
         deterministicSequence(seed: UInt64(pairIndex) * 2 + 2))
    }

    /// A 60-base sequence derived from `seed` with a small LCG, so fixtures
    /// stay identical across runs without touching a global RNG.
    public static func deterministicSequence(seed: UInt64, length: Int = 60) -> String {
        let alphabet: [Character] = ["A", "C", "G", "T"]
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        var bases: [Character] = []
        bases.reserveCapacity(length)
        for _ in 0..<length {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bases.append(alphabet[Int((state >> 33) & 3)])
        }
        return String(bases)
    }

    /// FASTQ text for `pairCount` interleaved pairs.
    public static func fastqText(
        pairCount: Int,
        naming: MateNaming,
        sequences: PairSequences? = nil
    ) -> String {
        var lines: [String] = []
        lines.reserveCapacity(pairCount * 8)
        for index in 0..<pairCount {
            let pair = sequences?(index) ?? defaultSequences(index)
            for (mate, sequence) in [(1, pair.mate1), (2, pair.mate2)] {
                lines.append("@" + header(pairIndex: index, mate: mate, naming: naming))
                lines.append(sequence)
                lines.append("+")
                lines.append(String(repeating: "I", count: sequence.count))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes a loose interleaved FASTQ.
    public static func write(
        pairCount: Int,
        naming: MateNaming,
        sequences: PairSequences? = nil,
        to url: URL
    ) throws {
        try fastqText(pairCount: pairCount, naming: naming, sequences: sequences)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes a `.lungfishfastq` bundle holding one interleaved FASTQ whose
    /// `.lungfish-meta.json` sidecar records `pairingMode`.
    ///
    /// - Returns: the bundle directory and the FASTQ inside it.
    @discardableResult
    public static func writeBundle(
        named name: String,
        in directory: URL,
        pairCount: Int,
        naming: MateNaming,
        pairingMode: IngestionMetadata.PairingMode = .interleaved,
        sequences: PairSequences? = nil
    ) throws -> (bundleURL: URL, fastqURL: URL) {
        let bundleURL = directory.appendingPathComponent(
            "\(name).\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("\(name).fastq")
        try write(pairCount: pairCount, naming: naming, sequences: sequences, to: fastqURL)
        let metadata = PersistedFASTQMetadata(
            ingestion: IngestionMetadata(pairingMode: pairingMode, originalFilenames: ["\(name).fastq"])
        )
        FASTQMetadataStore.save(metadata, for: fastqURL)
        return (bundleURL, fastqURL)
    }

    /// Reads every record of a FASTQ (plain or gzip).
    public static func readRecords(at url: URL) async throws -> [FASTQRecord] {
        var records: [FASTQRecord] = []
        let reader = FASTQReader(validateSequence: false)
        for try await record in reader.records(from: url) {
            records.append(record)
        }
        return records
    }

    /// The fragment key of a record, so mates compare equal in every naming style.
    public static func fragmentKey(_ record: FASTQRecord) -> String {
        IlluminaAmpliconPairMerger.fragmentKey(identifier: record.identifier, description: record.description)
    }

    /// The set of fragment keys present in `records`.
    public static func fragmentKeys(_ records: [FASTQRecord]) -> Set<String> {
        Set(records.map(fragmentKey))
    }

    /// Asserts that `records` is a whole-pairs interleaved output: even count,
    /// every record directly followed by its mate, and no fragment appearing
    /// as a lone orphan or more than once as a pair.
    public static func assertWholePairs(
        _ records: [FASTQRecord],
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let context = message()
        XCTAssertEqual(
            records.count % 2, 0,
            "Expected an even record count (whole pairs only), found \(records.count). \(context)",
            file: file, line: line
        )
        var seen: [String: Int] = [:]
        var index = 0
        while index + 1 < records.count {
            let key1 = fragmentKey(records[index])
            let key2 = fragmentKey(records[index + 1])
            XCTAssertEqual(
                key1, key2,
                "Records \(index)/\(index + 1) must be mates of one fragment, found '\(records[index].identifier)' next to '\(records[index + 1].identifier)'. \(context)",
                file: file, line: line
            )
            seen[key1, default: 0] += 1
            index += 2
        }
        let duplicated = seen.filter { $0.value > 1 }.keys.sorted()
        XCTAssertTrue(
            duplicated.isEmpty,
            "Fragments emitted more than once as a pair: \(duplicated.prefix(5)). \(context)",
            file: file, line: line
        )
    }
}
