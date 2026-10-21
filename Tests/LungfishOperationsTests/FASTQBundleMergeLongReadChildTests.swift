// FASTQBundleMergeLongReadChildTests.swift - The bundle merge reads a long-read child as the read set planner does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.42 M2, BIO ruling test T7 (Q6). The merge service's own copy of the long-read rule read only
// the file's sidecar, so a derived child of an Oxford Nanopore bundle, whose sidecar records nothing, fell through to
// the scan and was read as pairs. The resolver now walks to the parent, and the root keeps its answer.

import XCTest
@testable import LungfishOperations
import LungfishIO
import LungfishTestSupport

@MainActor
final class FASTQBundleMergeLongReadChildTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "bundle-merge-long-read-child")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testChildOfAnOxfordNanoporeRootIsReadAsSingleReads() throws {
        let sequence = "ACGTACGTACGTACGTAC"
        let quality = String(repeating: "I", count: sequence.count)
        let text = ["8f2e0c7a-0001-4f7a-9d1a-0123456789ab runid=abc", "8f2e0c7a-0002-4f7a-9d1a-0123456789ab runid=abc"]
            .flatMap { [$0, $0] }
            .map { "@\($0)\n\(sequence)\n+\n\(quality)\n" }
            .joined()
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        let parent = imports.appendingPathComponent("ont.lungfishfastq", isDirectory: true)
        let child = imports.appendingPathComponent("ont-subset.lungfishfastq", isDirectory: true)
        for bundle in [parent, child] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: bundle.appendingPathComponent("reads.fastq"))
        }
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore),
            for: parent.appendingPathComponent("reads.fastq")
        )
        let operation = FASTQDerivativeOperation(kind: .deduplicate)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "ont-subset",
                parentBundleRelativePath: "@/Imports/ont.lungfishfastq",
                rootBundleRelativePath: "@/Imports/ont.lungfishfastq",
                rootFASTQFilename: "reads.fastq",
                payload: .full(fastqFilename: "reads.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 4, baseCount: 72),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: child
        )
        XCTAssertNil(FASTQMetadataStore.load(for: child.appendingPathComponent("reads.fastq")))

        XCTAssertTrue(FASTQBundleMergeService.readSetResolverReadsOnlySingleReads(
            in: child.appendingPathComponent("reads.fastq")
        ))
        XCTAssertTrue(FASTQBundleMergeService.readSetResolverReadsOnlySingleReads(
            in: parent.appendingPathComponent("reads.fastq")
        ))
    }
}
