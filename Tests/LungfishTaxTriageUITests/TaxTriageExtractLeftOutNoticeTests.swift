// TaxTriageExtractLeftOutNoticeTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.68 (TT-EXTRACT-NOTICE). Extract Reads leaves out a selected TaxTriage row whose own sample holds no
// reference accession for the organism. When other rows still go out, the extraction dialog names the rows it left
// out in one line under its selection label. These tests pin the words of that line.

import XCTest
@testable import LungfishTaxTriageUI

@MainActor
final class TaxTriageExtractLeftOutNoticeTests: XCTestCase {

    func testNoRowLeftOutGivesNoNotice() {
        XCTAssertNil(TaxTriageResultViewController.leftOutNotice(for: []))
    }

    func testOneRowLeftOutNamesTheOrganismAndItsSample() {
        XCTAssertEqual(
            TaxTriageResultViewController.leftOutNotice(for: [("Alpha virus", "sample-2")]),
            "1 selected row is left out because Alpha virus in sample-2 has no reference accession of its own."
        )
    }

    func testTwoAndThreeRowsLeftOutAreListedWithAnd() {
        XCTAssertEqual(
            TaxTriageResultViewController.leftOutNotice(for: [("Alpha virus", "sample-2"), ("Beta virus", "sample-3")]),
            "2 selected rows are left out because Alpha virus in sample-2 and Beta virus in sample-3 have no reference accession of their own."
        )
        let three: [(organism: String, sample: String?)] = [
            ("Alpha virus", "sample-2"), ("Beta virus", "sample-3"), ("Gamma virus", "sample-4"),
        ]
        XCTAssertEqual(
            TaxTriageResultViewController.leftOutNotice(for: three),
            "3 selected rows are left out because Alpha virus in sample-2, Beta virus in sample-3 and Gamma virus in sample-4 have no reference accession of their own."
        )
    }

    /// Four rows are all named. "and 1 more" would hide the fourth name to save a few characters.
    func testFourRowsLeftOutAreAllNamed() {
        let four: [(organism: String, sample: String?)] = [
            ("Alpha virus", "sample-2"), ("Beta virus", "sample-3"), ("Gamma virus", "sample-4"),
            ("Delta virus", "sample-5"),
        ]
        XCTAssertEqual(
            TaxTriageResultViewController.leftOutNotice(for: four),
            "4 selected rows are left out because Alpha virus in sample-2, Beta virus in sample-3, Gamma virus in sample-4 and Delta virus in sample-5 have no reference accession of their own."
        )
    }

    func testMoreThanThreeRowsLeftOutListThreeAndCountTheRest() {
        let five: [(organism: String, sample: String?)] = [
            ("Alpha virus", "sample-2"), ("Beta virus", "sample-3"), ("Gamma virus", "sample-4"),
            ("Delta virus", "sample-5"), ("Epsilon virus", "sample-6"),
        ]
        XCTAssertEqual(
            TaxTriageResultViewController.leftOutNotice(for: five),
            "5 selected rows are left out because Alpha virus in sample-2, Beta virus in sample-3, Gamma virus in sample-4 and 2 more have no reference accession of their own."
        )
    }

    func testARowWithoutASampleIsNamedByItsOrganismAlone() {
        XCTAssertEqual(
            TaxTriageResultViewController.leftOutNotice(for: [("Alpha virus", nil)]),
            "1 selected row is left out because Alpha virus has no reference accession of its own."
        )
    }
}
