// SampleFolderNamingTests.swift - The folder names of a batch's samples, byte for byte as the base gave them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.32, K1b (ARCH 4). `sanitizedDirectoryName` and `uniqueDirectoryName` moved whole from the serial
// batch runner to `SampleFolderNaming`, which the TaxTriage read layout and the Viral Recon result ingest call. The
// names below are those the runner's pair gave at the base 916a79b07 for a hostile list of sample ids, with dots,
// slashes, a backslash, repeats and the empty string, compared as UTF-8 bytes.

import XCTest
@testable import LungfishWorkflow

final class SampleFolderNamingTests: XCTestCase {
    private static let hostileIDs = [
        "S.1", "S 1", "S__1", "a/b", "../x", ".", "..", "", "S 1", "S_1", "-lead", "trail.", "a\\b", "\u{00E9}1",
    ]

    func testAHostileListGivesTheBaseFolderNamesByteForByte() {
        var used = Set<String>()
        let names = Self.hostileIDs.map { SampleFolderNaming.uniqueDirectoryName(for: $0, usedNames: &used) }

        let expected = [
            "S.1", "S_1", "S__1", "a_b", "x", "sample", "sample-2", "sample-3", "S_1-2", "S_1-3", "lead", "trail", "a_b-2",
            "\u{00E9}1",
        ]
        XCTAssertEqual(names.map { Array($0.utf8) }, expected.map { Array($0.utf8) })
        // Taken once whatever its case (trust session VR-SAME-NAME: the set holds each name under its case-folded key).
        XCTAssertEqual(Set(used.map { $0.lowercased() }), Set(expected.map { $0.lowercased() }), "each name is taken once")
    }

    // Trust session VR-SAME-NAME (BIO-PROBES-F Q2, S1 as if). A project folder on APFS or ExFAT ignores letter case, so
    // "Sample_1" and "sample_1" were one folder and the second sample read the first one's results. Only names that
    // differ in more than case keep the names they had (the test above), and a case-only repeat takes a suffix.
    func testNamesThatDifferOnlyInLetterCaseGetTwoFolderNames() {
        var used = Set<String>()
        let names = ["Sample_1", "sample_1", "SAMPLE_1", "Sample_2", "S 1", "s_1"]
            .map { SampleFolderNaming.uniqueDirectoryName(for: $0, usedNames: &used) }

        XCTAssertEqual(names, ["Sample_1", "sample_1-2", "SAMPLE_1-3", "Sample_2", "S_1", "s_1-2"])
        XCTAssertEqual(Set(names.map { $0.lowercased() }).count, names.count, "no two folders share a name once case is ignored")
    }

    func testTheSanitizerAloneCollapsesWhatTheUniqueNameKeepsApart() {
        let sanitized = ["S 1", "S_1", "/", ".hidden", "a b/c"].map(SampleFolderNaming.sanitizedDirectoryName(for:))

        XCTAssertEqual(sanitized.map { Array($0.utf8) }, ["S_1", "S_1", "sample", "hidden", "a_b_c"].map { Array($0.utf8) })
    }
}
