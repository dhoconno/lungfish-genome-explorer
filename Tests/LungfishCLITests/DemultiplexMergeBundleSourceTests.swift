// DemultiplexMergeBundleSourceTests.swift - Demultiplexing a merge bundle gives barcode bundles of its merged reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli fastq demultiplex` on a PE merge bundle (`fullMixed`) wrote
// virtual barcode bundles rooted at the merge bundle's own root, the raw
// import. Their read-ID lists name merged fragments, which the raw import
// holds as two short mates, so a barcode bundle materialized to raw mates and
// its read count and preview were rebuilt from them too (D1, Phase 1.5 lane
// A7). The barcode bundles now root at the merge bundle, and their preview
// and statistics come from the demultiplexed reads.
//
// The exact-bare engine and the subset run seqkit, so the test skips when
// the managed seqkit is missing.

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class DemultiplexMergeBundleSourceTests: XCTestCase {
    private var root: URL!
    private var fixture: MergeBundleOverRawRootFixture!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demultiplex-merge-bundle")
        fixture = try MergeBundleOverRawRootFixture(project: root.appendingPathComponent("Project.lungfish", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func requireTools() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed")
        }
    }

    /// Before the fix the BC01 bundle counted 8 reads and materialized 8 raw
    /// mates of 20 bases. It counts the 5 reads of the merge bundle and
    /// materializes the unmerged pair, then the 3 merged reads of 30 bases.
    func testABarcodeBundleOfAMergeBundleHoldsItsMergedReads() async throws {
        try await requireTools()
        let kitCSV = root.appendingPathComponent("barcodes.csv")
        try "id,sequence\nBC01,\(MergeBundleOverRawRootFixture.barcode)\n".write(to: kitCSV, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("Project.lungfish/Demux", isDirectory: true)

        try await FastqDemultiplexSubcommand.parse([
            fixture.mergeBundle.path, "--kit", kitCSV.path, "--output", output.path,
            "--engine", "exact-bare", "--location", "5prime",
        ]).run()

        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output))
        let barcode = try XCTUnwrap(manifest.barcodes.first { $0.barcodeID == "BC01" })
        XCTAssertEqual(barcode.readCount, 5, "the 5 reads of the merge bundle, not 8 raw mates")

        let bundle = output.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let materialized = try await FASTQCLIMaterializer(runner: .shared).materialize(bundleURL: bundle, tempDirectory: work)
        let records = try MergeBundleOverRawRootFixture.records(in: materialized)
        XCTAssertEqual(records.map(\.id), ["u1", "u1"] + MergeBundleOverRawRootFixture.mergedFragments)
        XCTAssertEqual(records.map(\.sequence), [
            MergeBundleOverRawRootFixture.mateSequence,
            MergeBundleOverRawRootFixture.mateSequence,
        ] + Array(repeating: MergeBundleOverRawRootFixture.mergedSequence, count: 3))

        let preview = try MergeBundleOverRawRootFixture.records(in: bundle.appendingPathComponent("preview.fastq"))
        XCTAssertEqual(preview.count, 5, "the preview holds the demultiplexed reads, not raw mates")
        XCTAssertFalse(preview.contains { $0.sequence == MergeBundleOverRawRootFixture.mateSequence && $0.id.hasPrefix("x") })
    }
}
