// TaxaCollectionPairingLiveConformanceTests.swift - The walk's extraction and ingest with the managed clumpify
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane PAIRING (walk WF-1, 2.9 O5). `TaxaCollectionPairingTests` holds the pairing and the
// sidecar rules with clumpify skipped. This runs the two commands of the walk as the app starts them,
// `extract taxa-collection` and then `fastq ingest <file> --delete-originals`, with the real clumpify,
// so the clumped file replaces the plain one as it did for HSV-1 in SRR12486983.
//
// The class needs the managed clumpify, so it is named `Conformance` and never runs in the unit
// tier. It skips without the tool, and fails under `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class TaxaCollectionPairingLiveConformanceTests: XCTestCase {
    func testTheClumpedFileIsInterleavedAndTheFolderHoldsOneRecordForEachFile() async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: .clumpify)) != nil else {
            try ToolAvailability.skipOrFail("Managed clumpify is not available")
        }
        let workspace = try TaxaCollectionPairingWorkspace()
        defer { workspace.cleanup() }
        let plain = try await workspace.extractedFile("10298,children,HSV-1")
        let clumped = workspace.output.appendingPathComponent("HSV-1_taxid10298.clumped.fastq.gz")

        try await workspace.ingest(plain, ["--threads", "2"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: clumped.path), "clumpify replaced the plain file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path))
        let ingestion = try XCTUnwrap(FASTQMetadataStore.load(for: clumped)?.ingestion)
        XCTAssertTrue(ingestion.isClumpified)
        XCTAssertEqual(ingestion.pairingMode, .interleaved, "the walk recorded single_end here")
        XCTAssertEqual(FASTQReadLayoutClassifier.metadataHints(for: clumped).pairingMode, .interleaved)
        let counts = try FASTQMixedLayoutHint.countPairsAndSingles(in: clumped)
        XCTAssertEqual(counts.pairs, 4, "clumpify keeps the 8 reads of the 4 pairs together")
        XCTAssertEqual(counts.singles, 0)
        XCTAssertEqual(
            try workspace.sidecarsOfMissingFiles(), [],
            "no record or metadata sidecar of the folder names the plain file that clumpify replaced"
        )
    }
}
