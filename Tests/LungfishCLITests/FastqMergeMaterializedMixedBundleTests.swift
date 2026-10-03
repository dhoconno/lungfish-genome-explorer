// FastqMergeMaterializedMixedBundleTests.swift - A large materialized merge bundle is never paired by position
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A PE merge bundle (`fullMixed`) materializes to one file with every pair
// first, then the merged reads. The layout scan reads the first 100,000
// records, so a bundle with more pair records than that looked strictly
// interleaved, and `fastq merge` on the materialized file (the Operations
// dialog runs it on a scratch copy with no bundle beside it) handed the
// merged reads to bbmerge as positional pairs (D2, Phase 1.5 lane A7). The
// materializer now writes a sidecar beside such a file recording its merged
// reads, so the scan says mixed and `fastq merge` splits it by read name.
//
// The bundle's pairs are interleaved with reformat.sh and merged with
// bbmerge, so the test skips when the managed BBTools are missing.

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class FastqMergeMaterializedMixedBundleTests: XCTestCase {
    private var root: URL!

    /// 100,002 pair records, past the 100,000-record scan.
    private static let pairCount = 50_001
    private static let merged: [(id: String, sequence: String)] = [
        ("m1", "TTTTTTTTTTGGGGGGGGGGCCCCCCCCCCAAAAAAAAAATTTTTTTTTTGGGGGGGGGG"),
        ("m2", "GGGGGGGGGGTTTTTTTTTTAAAAAAAAAACCCCCCCCCCGGGGGGGGGGTTTTTTTTTT"),
        ("m3", "CCCCCCCCCCAAAAAAAAAAGGGGGGGGGGTTTTTTTTTTCCCCCCCCCCAAAAAAAAAA"),
    ]

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "merge-materialized-mixed")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func write(_ records: [(id: String, sequence: String)], to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer = ""
        for record in records {
            buffer += "@\(record.id)\n\(record.sequence)\n+\n\(String(repeating: "I", count: record.sequence.count))\n"
            if buffer.utf8.count > 1 << 20 {
                handle.write(Data(buffer.utf8))
                buffer = ""
            }
        }
        handle.write(Data(buffer.utf8))
    }

    /// A deterministic 80-base sequence for read `index` of mate `mate`.
    private static func sequence(_ index: Int, mate: Int) -> String {
        var state = UInt64(index * 2 + mate) &* 6364136223846793005 &+ 1442695040888963407
        let bases: [Character] = ["A", "C", "G", "T"]
        return String((0..<80).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return bases[Int((state >> 33) % 4)]
        })
    }

    private func makeMergeBundle() throws -> URL {
        let bundle = root.appendingPathComponent("Project.lungfish/Imports/merged.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try write((0..<Self.pairCount).map { ("p\($0) 1:N:0:1", Self.sequence($0, mate: 1)) },
                  to: bundle.appendingPathComponent("unmerged_R1.fastq"))
        try write((0..<Self.pairCount).map { ("p\($0) 2:N:0:1", Self.sequence($0, mate: 2)) },
                  to: bundle.appendingPathComponent("unmerged_R2.fastq"))
        try write(Self.merged, to: bundle.appendingPathComponent("merged.fastq"))
        let classification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: Self.merged.count),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: Self.pairCount),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: Self.pairCount),
        ])
        let operation = FASTQDerivativeOperation(kind: .pairedEndMerge)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "merged",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "merged.fastq",
                payload: .fullMixed(classification),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: Self.pairCount * 2 + 3, baseCount: 1),
                pairingMode: .interleaved,
                readClassification: classification,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    /// Before the fix the scratch file scanned strictly interleaved, and
    /// bbmerge paired m1 with m2 by position. The scan now says mixed, and
    /// `fastq merge` passes m1 to m3 through unchanged.
    func testMergeOfALargeMaterializedMergeBundleSplitsByNameAndPassesMergedReadsThrough() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.reformat),
              await NativeToolRunner.shared.isToolAvailable(.bbmerge) else {
            try ToolAvailability.skipOrFail("managed BBTools (reformat.sh, bbmerge.sh) are not installed")
        }
        let bundle = try makeMergeBundle()
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let materialized = try await FASTQCLIMaterializer(runner: .shared).materialize(bundleURL: bundle, tempDirectory: scratch)

        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [materialized])
        XCTAssertEqual(resolution.layout, .mixedMergedAndPairs, resolution.reason)

        let output = root.appendingPathComponent("remerged.fastq")
        try await FastqMergeSubcommand.parse([materialized.path, "-o", output.path]).run()

        var passedThrough: [String: String] = [:]
        var mergedIDCount = 0
        for try await record in FASTQReader(validateSequence: false).records(from: output) {
            if record.identifier.hasPrefix("m") {
                mergedIDCount += 1
                passedThrough[record.identifier] = record.sequence
            }
        }
        XCTAssertEqual(mergedIDCount, 3, "each merged read passes through once")
        for read in Self.merged {
            XCTAssertEqual(passedThrough[read.id], read.sequence, "\(read.id) is unchanged, never paired")
        }
    }
}
