// FASTQBatchImporterUnpairedReadsConformanceTests.swift - A joined run keeps every pair and unpaired read through clumpify
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// A run's pairs and its reads without a mate import as one file, each R1
/// record beside its R2 record and the unpaired reads after them (lane F9).
/// With storage optimization on, BBTools clumpify reorders that file. The
/// pairs are clumped with `interleaved=t` and the unpaired reads on their
/// own, so no mate is parted from its partner and no read is lost. No test
/// sent a joined file through clumpify before (finding F9-N6).
///
/// A real-tool suite. Its name puts it in the conformance tier, and it skips
/// when a managed tool is missing, as FASTQBatchImporterRecipeIntegrationTests
/// does, or fails under LUNGFISH_REQUIRE_TOOLS=1.
final class FASTQBatchImporterUnpairedReadsConformanceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-unpaired-clumpify")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAJoinedRunKeepsEveryPairAdjacentAndEveryUnpairedReadThroughClumpify() async throws {
        try await requireManagedTools([.clumpify, .pigz, .seqkit])
        let run = "SRR9100001"
        let pairedSpots = Array(1...40)
        let unpairedSpots = Array(41...52)
        let files = try writeRun(run, pairedSpots: pairedSpots, unpairedSpots: unpairedSpots)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let samples = FASTQBatchImporter.detectPairs(from: files)
        XCTAssertEqual(samples.map { $0.unpaired?.lastPathComponent }, ["\(run).fastq"], "the three files are one sample")

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: samples,
            config: FASTQBatchImporter.ImportConfig(
                projectDirectory: project,
                platform: .given(.illumina),
                qualityBinning: QualityBinningScheme.none,
                optimizeStorage: true,
                clumpingTool: .bbtools,
                threads: 2
            )
        )

        XCTAssertEqual(result.completed, 1, "Errors: \(result.errors)")
        let bundle = project.appendingPathComponent("Imports/\(run).lungfishfastq", isDirectory: true)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertEqual(metadata.ingestion?.isClumpified, true, "clumpify.sh reordered the file")
        XCTAssertEqual(metadata.readClassification?.pairedReadCount, pairedSpots.count * 2)
        XCTAssertEqual(metadata.readClassification?.unpairedReadCount, unpairedSpots.count)

        // Read the stored file in order. Each record is half of an adjacent
        // pair, by the rule every tool pairs by, or one unpaired read.
        let headers = try FASTQReadLayoutClassifier.readHeaders(from: fastq, limit: 1_000).headers
        XCTAssertEqual(headers.count, pairedSpots.count * 2 + unpairedSpots.count, "no read is lost")
        var adjacentPairs: [Int] = []
        var singleReads: [Int] = []
        var index = 0
        while index < headers.count {
            if index + 1 < headers.count, FASTQReadLayoutClassifier.areMates(headers[index], headers[index + 1]) {
                adjacentPairs.append(Self.spot(of: headers[index]))
                index += 2
            } else {
                singleReads.append(Self.spot(of: headers[index]))
                index += 1
            }
        }
        XCTAssertEqual(adjacentPairs.sorted(), pairedSpots, "every pair stays adjacent")
        XCTAssertEqual(singleReads.sorted(), unpairedSpots, "every unpaired read survives clumping")
        XCTAssertEqual(
            try FASTQPairInterleaver.countMixed(interleaved: fastq),
            FASTQPairInterleaver.MixedCounts(pairs: pairedSpots.count, unpaired: unpairedSpots.count)
        )
    }

    // MARK: - Helpers

    private func requireManagedTools(_ tools: [NativeTool]) async throws {
        for tool in tools {
            guard (try? await NativeToolRunner.shared.toolPath(for: tool)) != nil else {
                try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is not available")
            }
        }
    }

    /// Writes one run as fasterq-dump names it, with the same read ID for
    /// both mates of a spot and 100 bases a read, long enough for clumpify's
    /// 31-base k-mers.
    private func writeRun(_ run: String, pairedSpots: [Int], unpairedSpots: [Int]) throws -> [URL] {
        let folder = root.appendingPathComponent("download-\(run)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ spots: [Int], mate: Int) throws -> URL {
            let url = folder.appendingPathComponent(name)
            let text = spots.map { spot in
                let bases = Self.bases(seed: spot * 2 + mate)
                return "@\(run).\(spot) \(spot) length=\(bases.count)\n\(bases)\n+\n\(String(repeating: "I", count: bases.count))\n"
            }.joined()
            try Data(text.utf8).write(to: url)
            return url
        }
        return [
            try write("\(run)_1.fastq", pairedSpots, mate: 0),
            try write("\(run)_2.fastq", pairedSpots, mate: 1),
            try write("\(run).fastq", unpairedSpots, mate: 0),
        ]
    }

    /// The spot number of a header written by ``writeRun(_:pairedSpots:unpairedSpots:)``.
    private static func spot(of header: String) -> Int {
        Int(header.split(separator: " ")[1]) ?? -1
    }

    /// 100 pseudo-random bases, the same for the same seed.
    private static func bases(seed: Int) -> String {
        var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1
        let alphabet: [Character] = ["A", "C", "G", "T"]
        return String((0..<100).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return alphabet[Int((state >> 33) % 4)]
        })
    }
}
