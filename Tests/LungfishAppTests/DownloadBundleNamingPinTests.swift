// DownloadBundleNamingPinTests.swift - Pins the bundle names the download builders give today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow
import LungfishTestSupport

/// Pins the names `BundleBuildHelpers.sanitizedFilename` and `makeUniqueBundleURL` give, recorded
/// at the base of Phase 2.10 lane A44 (c68381a62) before both moved into LungfishWorkflow. The plan
/// moves one sanitizer and one uniquer down with today's names pinned, and lane A48 folds the
/// private pair of `SequenceExtractionBundleBuilder` into them later.
final class DownloadBundleNamingPinTests: XCTestCase {

    func testSanitizerKeepsTodaysNames() {
        let cases: [(raw: String, name: String)] = [
            ("Homo sapiens - GRCh38.p14", "Homo_sapiens_-_GRCh38.p14"),
            ("  MN908947.3\n", "MN908947.3"),
            ("Influenza A virus (A/California/07/2009(H1N1)) - ASM:1",
             "Influenza_A_virus_(A-California-07-2009(H1N1))_-_ASM-1"),
            ("Mus musculus  - GRCm39", "Mus_musculus__-_GRCm39"),
            ("a\tb", "a\tb"),
            ("", ""),
        ]
        for (raw, name) in cases {
            XCTAssertEqual(BundleBuildHelpers.sanitizedFilename(raw), name, "for \(raw.debugDescription)")
        }
    }

    func testUniquerAddsTodaysSuffixes() throws {
        let directory = try TestTempDirectory.make(prefix: "bundle-naming-pin")
        defer { TestTempDirectory.cleanup(directory) }

        let first = BundleBuildHelpers.makeUniqueBundleURL(baseName: "MN908947.3", in: directory)
        XCTAssertEqual(first.lastPathComponent, "MN908947.3.lungfishref")
        XCTAssertTrue(first.hasDirectoryPath)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)

        let second = BundleBuildHelpers.makeUniqueBundleURL(baseName: "MN908947.3", in: directory)
        XCTAssertEqual(second.lastPathComponent, "MN908947.3_1.lungfishref")
        XCTAssertTrue(FileManager.default.createFile(atPath: second.path, contents: Data()))

        // A plain file of the name is taken too.
        let third = BundleBuildHelpers.makeUniqueBundleURL(baseName: "MN908947.3", in: directory)
        XCTAssertEqual(third.lastPathComponent, "MN908947.3_2.lungfishref")

        // An empty name is not replaced here. The sequence path gives its own fallback first.
        let empty = BundleBuildHelpers.makeUniqueBundleURL(baseName: "", in: directory)
        XCTAssertEqual(empty.lastPathComponent, ".lungfishref")
    }
}
