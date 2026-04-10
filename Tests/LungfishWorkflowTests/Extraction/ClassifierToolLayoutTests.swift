// ClassifierToolLayoutTests.swift — Tests for ClassifierTool.expectedResultLayout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class ClassifierToolLayoutTests: XCTestCase {

    /// NVD's result is a sentinel file alongside sibling per-contig BAMs; the
    /// resolver discovers artifacts by scanning the parent directory.
    func testNvd_hasDirectorySentinelLayout() {
        XCTAssertEqual(ClassifierTool.nvd.expectedResultLayout, .directorySentinel)
    }

    /// EsViritu, TaxTriage, NAO-MGS, and Kraken2 all expose a single result
    /// file that the resolver opens directly.
    func testBamBackedAndKraken2_haveFileLayout() {
        let fileLayoutTools: [ClassifierTool] = [.esviritu, .taxtriage, .naomgs, .kraken2]
        for tool in fileLayoutTools {
            XCTAssertEqual(
                tool.expectedResultLayout,
                .file,
                "\(tool.rawValue) should have .file layout"
            )
        }
    }

    /// Sanity: exercising `expectedResultLayout` for every case ensures that
    /// adding a new `ClassifierTool` without updating the switch forces a
    /// compile error here rather than silently falling through at runtime.
    func testAllCases_haveDeclaredLayout() {
        for tool in ClassifierTool.allCases {
            _ = tool.expectedResultLayout
        }
    }
}
