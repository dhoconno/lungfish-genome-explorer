// FASTQCLIMaterializerDerivedRootTests.swift - A virtual child of a merge bundle reads the merge bundle's reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A PE merge bundle (`fullMixed`) or a deinterleaved bundle (`fullPaired`)
// holds its reads as files of its own. A virtual child of it (a subset, a
// trim, demultiplexed reads) recorded the raw import as its root, and its
// read-ID list names merged fragments, which the raw import holds as two
// short mates. Materializing the child returned raw mates instead of the
// merged reads (D1, Phase 1.5 lane A7). The materializer now reads such a
// child from its nearest physical ancestor, the merge bundle materialized
// (pairs interleaved, then merged reads, then single reads), whether the
// child records that bundle as its root or, written earlier, the raw import.
//
// Subsets run seqkit, so the tests skip when the managed seqkit is missing.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class FASTQCLIMaterializerDerivedRootTests: XCTestCase {
    private var root: URL!
    private var fixture: MergeBundleOverRawRootFixture!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "materializer-derived-root")
        fixture = try MergeBundleOverRawRootFixture(project: root.appendingPathComponent("Project.lungfish", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func requireTools() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed (subsets are materialized with it)")
        }
    }

    private func materialize(_ bundle: URL) async throws -> URL {
        let directory = root.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await FASTQCLIMaterializer(runner: .shared).materialize(bundleURL: bundle, tempDirectory: directory)
    }

    /// A subset written before lane A7 (parent the merge bundle, root the raw
    /// import) of the three merged fragments. Before the fix it materialized
    /// 6 raw mates of 20 bases. It holds the 3 merged reads of 30 bases.
    func testALegacySubsetOfAMergeBundleMaterializesMergedReadsNotRawMates() async throws {
        try await requireTools()
        let subset = try fixture.legacySubset(named: "long", readIDs: MergeBundleOverRawRootFixture.mergedFragments)

        let records = try MergeBundleOverRawRootFixture.records(in: try await materialize(subset))
        XCTAssertEqual(records.map(\.id), MergeBundleOverRawRootFixture.mergedFragments)
        XCTAssertEqual(records.map(\.sequence), Array(repeating: MergeBundleOverRawRootFixture.mergedSequence, count: 3))
    }

    /// A subset naming a merged fragment and the unmerged pair holds the pair
    /// (both mates, adjacent, first) and then the merged read, the merge
    /// bundle's own layout. Before the fix it held 4 raw mates.
    func testALegacySubsetKeepsTheUnmergedPairAsAPairBeforeTheMergedRead() async throws {
        try await requireTools()
        let subset = try fixture.legacySubset(named: "mixed-subset", readIDs: ["x2", "u1"])

        let records = try MergeBundleOverRawRootFixture.records(in: try await materialize(subset))
        XCTAssertEqual(records.map(\.id), ["u1", "u1", "x2"])
        XCTAssertEqual(records.map(\.sequence), [
            MergeBundleOverRawRootFixture.mateSequence,
            MergeBundleOverRawRootFixture.mateSequence,
            MergeBundleOverRawRootFixture.mergedSequence,
        ])
    }

    /// A subset that records the merge bundle itself as its root reads every
    /// file of it. Before the fix it read the one recorded file, so the
    /// unmerged pair was lost (1 of 3 reads).
    func testASubsetRootedAtTheMergeBundleReadsEveryFileOfIt() async throws {
        try await requireTools()
        let subset = try fixture.legacySubset(named: "rooted", readIDs: ["x2", "u1"])
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: subset))
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: manifest.name,
                parentBundleRelativePath: "@/Imports/merged.lungfishfastq",
                rootBundleRelativePath: "@/Imports/merged.lungfishfastq",
                rootFASTQFilename: "merged.fastq",
                payload: manifest.payload,
                lineage: manifest.lineage,
                operation: manifest.operation,
                cachedStatistics: manifest.cachedStatistics,
                pairingMode: manifest.pairingMode,
                sequenceFormat: .fastq
            ),
            in: subset
        )

        let records = try MergeBundleOverRawRootFixture.records(in: try await materialize(subset))
        XCTAssertEqual(records.map(\.id), ["u1", "u1", "x2"])
    }

    /// Every payload file of a merge-bundle root, in role order, is what the
    /// staleness, integrity and provenance records name. It was the one
    /// recorded file.
    func testTheRootFilesOfAMergeBundleAreItsPayloadFilesInRoleOrder() throws {
        let urls = try FASTQBundle.rootSequenceURLs(rootFASTQFilename: "merged.fastq", in: fixture.mergeBundle)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["unmerged_R1.fastq", "unmerged_R2.fastq", "merged.fastq"])
    }
}
