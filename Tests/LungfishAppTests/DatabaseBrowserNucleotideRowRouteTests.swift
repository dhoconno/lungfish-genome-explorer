// DatabaseBrowserNucleotideRowRouteTests.swift - The route of the NCBI browser's nucleotide and virus rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45, panel decision C4. A nucleotide or virus row runs `lungfish-cli fetch ncbi
// --bundle` by default. A declared difference between the routes (the sequence's name, the record)
// keeps the in-process route behind a hidden key for one release, and each key value has a test.

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishTestSupport

final class DatabaseBrowserNucleotideRowRouteTests: XCTestCase {
    func testTheHiddenKeyPicksTheRoute() {
        let suite = makeTestDefaultsSuite(prefix: "nucleotide-row-route")
        let settings = NucleotideRowDownloadRouteSettings(defaults: suite.defaults)
        XCTAssertEqual(NucleotideRowDownloadRouteSettings.defaultRoute, .cli, "the flip: the CLI route is the default")
        XCTAssertEqual(settings.route, .cli, "an unset key")
        let cases: [(Any, NucleotideRowDownloadRoute)] = [
            ("cli", .cli), ("legacy", .legacy), ("LEGACY", .legacy), (true, .cli), (false, .legacy),
            ("NO", NucleotideRowDownloadRouteSettings.defaultRoute),
        ]
        for (value, route) in cases {
            suite.defaults.set(value, forKey: NucleotideRowDownloadRouteSettings.defaultsKey)
            XCTAssertEqual(settings.route, route, "\(value)")
        }
    }

    func testTheKeyIsNotTheGenomeRowsKey() {
        XCTAssertNotEqual(NucleotideRowDownloadRouteSettings.defaultsKey, GenomeRowDownloadRouteSettings.defaultsKey)
    }

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
