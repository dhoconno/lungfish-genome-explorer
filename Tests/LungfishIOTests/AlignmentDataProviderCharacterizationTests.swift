// AlignmentDataProviderCharacterizationTests.swift - Pins viewer query output on the sarscov2 fixture
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import LungfishCore
@testable import LungfishIO
import LungfishTestSupport

/// Pins the parsed output of every samtools query the read viewer makes, run
/// through a real managed samtools on `Tests/Fixtures/sarscov2`.
///
/// The expected values were recorded on the code that spawned samtools with
/// `Process()`, before the queries moved to ToolProcess (Phase 2.2 lane 3B1,
/// finding R7), so the move cannot change what the viewer shows. They are
/// bound to samtools 1.24, and the test skips on any other version.
final class AlignmentDataProviderCharacterizationTests: XCTestCase {
    private static let contig = "MT192765.1"
    private static let contigLength = 29_829
    private static let pinnedSamtoolsVersion = "samtools 1.24"

    func testViewerQueriesMatchTheRecordedOutput() async throws {
        let provider = try makeProvider()
        var actual: [String: String] = [:]

        let whole = try await provider.fetchReads(chromosome: Self.contig, start: 0, end: Self.contigLength)
        actual["fetchReads.whole"] = Self.summary(whole)
        let filtered = try await provider.fetchReads(
            chromosome: Self.contig, start: 1_000, end: 8_000, minMapQ: 30, readGroups: ["1"]
        )
        actual["fetchReads.filtered"] = Self.summary(filtered)

        actual["countReads.whole"] = String(try await provider.countReads(chromosome: Self.contig, start: 0, end: Self.contigLength))
        actual["countReads.region"] = String(try await provider.countReads(chromosome: Self.contig, start: 5_000, end: 15_000, minMapQ: 20))
        actual["countUniqueReads.whole"] = String(try await provider.countUniqueReads(chromosome: Self.contig, start: 0, end: Self.contigLength))

        let depth = try await provider.fetchDepth(chromosome: Self.contig, start: 0, end: Self.contigLength)
        actual["fetchDepth.whole"] = Self.summary(depth)
        let depthFiltered = try await provider.fetchDepth(
            chromosome: Self.contig, start: 2_000, end: 20_000, minMapQ: 30, minBaseQ: 20
        )
        actual["fetchDepth.filtered"] = Self.summary(depthFiltered)
        let pipelineDepth = try await provider.fetchReadFilterDepth(
            chromosome: Self.contig, start: 0, end: Self.contigLength,
            excludeFlags: 0x904, minMapQ: 0, readGroups: ["1"]
        )
        actual["fetchReadFilterDepth.readGroup"] = Self.summary(pipelineDepth)

        let capped = try await provider.fetchDepthCappedReads(
            chromosome: Self.contig, start: 0, end: Self.contigLength, maxDisplayedDepth: 3
        )
        actual["fetchDepthCappedReads"] = Self.summary(capped.reads)
            + " total=\(capped.estimatedTotalReads) estimated=\(capped.isEstimated)"
            + " truncated=\(capped.transportTruncated) calls=\(capped.samtoolsCalls)"

        let sketch = try await provider.fetchReadSketch(
            chromosome: Self.contig, start: 0, end: Self.contigLength, targetReads: 50
        )
        actual["fetchReadSketch"] = Self.summary(sketch.reads)
            + " total=\(sketch.estimatedTotalReads) subsampled=\(sketch.isSubsampled) truncated=\(sketch.transportTruncated)"

        actual["fetchIdxstats"] = Self.digest(try await provider.fetchIdxstats())
        actual["fetchFlagstat"] = Self.digest(try await provider.fetchFlagstat())
        // `samtools view -H` appends its own @PG line naming the fixture's
        // absolute path, which differs between checkouts.
        let header = try await provider.fetchHeader()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !($0.hasPrefix("@PG") && $0.contains("view -H")) }
            .joined(separator: "\n")
        actual["fetchHeader"] = Self.digest(header)

        let consensus = try await provider.fetchConsensus(
            AlignmentConsensusRequest(
                chromosome: Self.contig, start: 100, end: 2_000,
                filters: AlignmentConsensusFilters(
                    minimumDepth: 1, minimumMapQ: 0, minimumBaseQuality: 0, excludedFlags: 0x904, readGroups: []
                ),
                mode: .bayesian, useAmbiguity: false, insertionPolicy: .omit, deletionPolicy: .n
            )
        )
        actual["fetchConsensus"] = "\(consensus.sequence.count) \(Self.digest(consensus.sequence))"
            + " lowDepth=\(consensus.allLowDepth)"
            + " stages=\(consensus.executionRecords.map { "\($0.stage.rawValue):\($0.exitStatus.map(String.init) ?? "nil")" }.joined(separator: ","))"

        if actual != Self.expected {
            let lines = actual.keys.sorted().map { "\"\($0)\": \"\(actual[$0]!)\"," }
            XCTFail("Viewer query output changed. Actual values:\n" + lines.joined(separator: "\n"))
        }
    }

    // MARK: - Expected values (recorded on the Process() implementation)

    private static let expected: [String: String] = [
        "countReads.region": "80",
        "countReads.whole": "197",
        "countUniqueReads.whole": "197",
        "fetchConsensus": "1900 4f9b92604c7e284345eabd45 lowDepth=false stages=view:0,index:0,consensus:0,depth:0",
        "fetchDepth.filtered": "9019 sum=18515 00280ed672f0a75a55ec4c98",
        "fetchDepth.whole": "12853 sum=27401 a633579d9f7e45830892aede",
        "fetchDepthCappedReads": "127 9f73da9330daeacbac2b3c64 total=195 estimated=true truncated=false calls=6",
        "fetchFlagstat": "1b7aea864cf98cbd8d7803ab",
        "fetchHeader": "465bde70124666656ef95ac4",
        "fetchIdxstats": "236009d9761b529ae3effc48",
        "fetchReadFilterDepth.readGroup": "12853 sum=27401 a633579d9f7e45830892aede",
        "fetchReadSketch": "49 8c725dd43e853f40c1b22e91 total=197 subsampled=true truncated=false",
        "fetchReads.filtered": "35 82ae2a8185a9385d8ebbc114",
        "fetchReads.whole": "197 3bf5fd1990c28233980920f5",
    ]

    // MARK: - Helpers

    private func makeProvider() throws -> AlignmentDataProvider {
        let samtools = try Self.realSamtools()
        let fixtures = CLITestBinaryResolver.repositoryRoot(containing: #filePath)
            .appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
        let bam = fixtures.appendingPathComponent("test.paired_end.sorted.bam")
        return AlignmentDataProvider(
            alignmentPath: bam.path,
            indexPath: bam.path + ".bai",
            samtoolsPath: samtools
        )
    }

    /// The managed samtools of the Preview root, which is where this Mac
    /// installs tools, then whatever the test support locator finds.
    static func realSamtools() throws -> String {
        let preview = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lungfish/conda/envs/samtools/bin/samtools").path
        let candidates = [ProcessInfo.processInfo.environment["LUNGFISH_TEST_SAMTOOLS"], preview, BamFixtureBuilder.locateSamtools()]
        guard let path = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            try ToolAvailability.skipOrFail("A real samtools is required to characterize the viewer queries")
        }
        let version = try ProcessRunner.run(URL(fileURLWithPath: path), ["--version"], timeout: 30)
        let firstLine = version.stdout.split(separator: "\n").first.map(String.init) ?? ""
        guard firstLine == pinnedSamtoolsVersion else {
            try ToolAvailability.skipOrFail("The recorded values are for \(pinnedSamtoolsVersion), found \(firstLine)")
        }
        return path
    }

    private static func summary(_ reads: [AlignedRead]) -> String {
        let text = reads.map { read in
            [
                read.name, String(read.flag), read.chromosome, String(read.position), String(read.mapq),
                read.cigar.map { "\($0)" }.joined(), read.sequence, read.qualities.map(String.init).joined(separator: ","),
                read.mateChromosome ?? "-", read.matePosition.map(String.init) ?? "-", String(read.insertSize),
                read.readGroup ?? "-",
            ].joined(separator: "\t")
        }.joined(separator: "\n")
        return "\(reads.count) \(digest(text))"
    }

    private static func summary(_ points: [DepthPoint]) -> String {
        let text = points.map { "\($0.chromosome)\t\($0.position)\t\($0.depth)" }.joined(separator: "\n")
        return "\(points.count) sum=\(points.reduce(0) { $0 + $1.depth }) \(digest(text))"
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
