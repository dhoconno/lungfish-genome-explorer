// LongReadLooseFileLayoutTests.swift - A loose file whose own sidecar records PacBio is planned as single reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.42 M2, BIO ruling test T4 (row B17). A file outside every bundle reads the platform its own
// sidecar records, as `fastq translate` has since 2.12, so the layout resolver and the read set planner read a
// PacBio file whose ids repeat as single reads.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class LongReadLooseFileLayoutTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "long-read-loose-file")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testLooseFileWhoseSidecarRecordsPacBioIsSingleReads() async throws {
        let sequence = "ACGTACGTACGTACGTAC"
        let quality = String(repeating: "I", count: sequence.count)
        let text = ["m64011_190830_220126/101/ccs", "m64011_190830_220126/102/ccs"]
            .flatMap { [$0, $0] }
            .map { "@\($0)\n\(sequence)\n+\n\(quality)\n" }
            .joined()
        let folder = root.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("reads.fastq")
        try Data(text.utf8).write(to: file)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .pacbio), for: file)

        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [file])

        XCTAssertEqual(resolution.layout, .singleEnd)
        XCTAssertEqual(resolution.source, .bundleMetadata)
        XCTAssertEqual(resolution.reason, "The file's metadata records PacBio reads, which are never paired.")

        let resolver = ReadSetResolver(
            materializationDirectory: root.appendingPathComponent("work", isDirectory: true),
            materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
        )
        let plan = try await resolver.plan(for: file, capability: .bothInOneRunAsSeparateFiles)
        XCTAssertEqual(plan.sourceLayout.rawValue, "single_end_file")
    }
}
