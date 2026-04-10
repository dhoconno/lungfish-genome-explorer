// ClassifierToolLayoutTests.swift — Tests for ClassifierTool.expectedResultLayout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class ClassifierToolLayoutTests: XCTestCase {

    /// NVD's result directory contains sibling `*.bam` files that the
    /// resolver discovers by scanning (`ClassifierReadResolver.resolveBAMURL`).
    /// No fixed sentinel filename — the directory itself is the handle.
    func testNvd_hasDirectorySentinelLayout() {
        XCTAssertEqual(ClassifierTool.nvd.expectedResultLayout, .directorySentinel)
    }

    /// Kraken2's result directory contains a fixed `classification-result.json`
    /// sentinel parsed via `ClassificationResult.load(from:)`, which treats
    /// its argument as a directory (not a file). The user-facing handle is
    /// the enclosing directory, passed through by
    /// `TaxonomyViewController.resolveKraken2ResultPath` and the
    /// AppDelegate auto-extract path.
    func testKraken2_hasDirectorySentinelLayout() {
        XCTAssertEqual(ClassifierTool.kraken2.expectedResultLayout, .directorySentinel)
    }

    /// EsViritu, TaxTriage, and NAO-MGS each expose a single SQLite database
    /// file that the resolver opens directly.
    func testBamBackedTools_haveFileLayout() {
        let fileLayoutTools: [ClassifierTool] = [.esviritu, .taxtriage, .naomgs]
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
