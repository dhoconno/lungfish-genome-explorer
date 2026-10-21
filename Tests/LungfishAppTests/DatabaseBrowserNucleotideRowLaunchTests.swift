// DatabaseBrowserNucleotideRowLaunchTests.swift - The route of the NCBI browser's nucleotide and virus rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45, panel decision C4. A nucleotide or virus row runs `lungfish-cli fetch ncbi
// --bundle`. Lane A60 of 2.11 deleted the in-process route with its hidden key.

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishTestSupport

final class DatabaseBrowserNucleotideRowLaunchTests: XCTestCase {
    @MainActor
    func testTheArgumentsHoldNoKeyAndFollowTheGFF3Setting() {
        let folder = URL(fileURLWithPath: "/tmp/lane a45/Project.lungfish/Downloads", isDirectory: true)
        XCTAssertEqual(
            DatabaseBrowserViewModel.nucleotideFetchArguments(
                accessions: ["MN908947.3"], folder: folder, includeGFF3Annotations: true),
            ["fetch", "ncbi", "MN908947.3", "--bundle", "--output-dir", folder.path, "--format", "json"])
        let withoutGFF3 = DatabaseBrowserViewModel.nucleotideFetchArguments(
            accessions: ["MN908947.3"], folder: folder, includeGFF3Annotations: false)
        XCTAssertEqual(withoutGFF3, [
            "fetch", "ncbi", "MN908947.3", "--bundle", "--output-dir", folder.path, "--no-gff3", "--format", "json",
        ])
        for arguments in [withoutGFF3] {
            XCTAssertFalse(arguments.contains("--api-key"))
            XCTAssertFalse(arguments.contains { $0.contains("lge-test-not-a-key") })
        }
    }
}
