// NaoMgsResultViewControllerSmokeTests.swift - Standalone smoke test for the NAO-MGS leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishNaoMgsUI
@testable import LungfishIO
import LungfishWorkflow
import LungfishKit

final class NaoMgsResultViewControllerSmokeTests: XCTestCase {
    @MainActor func testViewControllerInstantiates() {
        let vc = NaoMgsResultViewController()
        XCTAssertNotNil(vc.view)
    }

    @MainActor func testResultViewportExportWritesTSVToProvidedURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsResultViewportExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("naomgs-summary.tsv")
        let vc = NaoMgsResultViewController()
        vc.loadViewIfNeeded()
        vc.configureWithCachedRows(
            [
                NaoMgsTaxonSummaryRow(
                    sample: "sample-1",
                    taxId: 1234,
                    name: "Example\tvirus",
                    hitCount: 10,
                    uniqueReadCount: 8,
                    avgIdentity: 99.5,
                    avgBitScore: 200,
                    avgEditDistance: 1,
                    pcrDuplicateCount: 2,
                    accessionCount: 1,
                    topAccessions: ["NC_000001.1"],
                    bamPath: nil,
                    bamIndexPath: nil
                ),
            ],
            manifest: NaoMgsManifest(
                sampleName: "sample-1",
                sourceFilePath: "/tmp/naomgs.tsv",
                hitCount: 10,
                taxonCount: 1,
                topTaxon: "Example virus",
                topTaxonId: 1234
            )
        )

        try vc.exportResults(to: outputURL, format: .tsv)

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(
            content.hasPrefix(
                "sample\ttaxon_id\tname\thit_count\tunique_read_count\tpcr_duplicate_count\tavg_identity\tavg_bit_score\tavg_edit_distance\taccession_count\n"
            )
        )
        XCTAssertTrue(content.contains("sample-1\t1234\tExample virus\t10\t8\t2\t99.50\t200.0\t1.0\t1\n"))
    }
}
