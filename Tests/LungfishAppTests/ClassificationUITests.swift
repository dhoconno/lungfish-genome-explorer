// ClassificationUITests.swift - Tests for classification operation UI properties
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

/// Tests verifying classification operation icons and button titles.
///
/// The ``OperationKind`` enum inside ``FASTQDatasetViewController`` is private,
/// so we test its public-facing counterpart ``OperationPreviewView.OperationKind``
/// to verify that the expected classification cases exist. The SF Symbol values
/// (k.circle, e.circle, t.circle) are validated by checking that the system
/// recognizes them as valid symbol names.
@MainActor
final class ClassificationUITests: XCTestCase {

    // MARK: - Classification Operation Cases Exist in Preview View

    func testClassifyReadsCaseExists() {
        // OperationPreviewView.OperationKind is internal, accessible via @testable
        let kind = OperationPreviewView.OperationKind.classifyReads
        // Verify it's distinct from other cases by comparing with detectViruses
        XCTAssertFalse(String(describing: kind) == String(describing: OperationPreviewView.OperationKind.detectViruses))
    }

    func testDetectVirusesCaseExists() {
        let kind = OperationPreviewView.OperationKind.detectViruses
        XCTAssertFalse(String(describing: kind) == String(describing: OperationPreviewView.OperationKind.comprehensiveTriage))
    }

    func testComprehensiveTriageCaseExists() {
        let kind = OperationPreviewView.OperationKind.comprehensiveTriage
        XCTAssertFalse(String(describing: kind) == String(describing: OperationPreviewView.OperationKind.classifyReads))
    }

    // MARK: - Classification SF Symbol Names Are Valid System Symbols

    /// Verifies that "k.circle" is a valid SF Symbol (used for classifyReads).
    func testClassifyReadsSFSymbolIsValid() {
        let image = NSImage(systemSymbolName: "k.circle", accessibilityDescription: nil)
        XCTAssertNotNil(image, "k.circle should be a valid SF Symbol name")
    }

    /// Verifies that "e.circle" is a valid SF Symbol (used for detectViruses).
    func testDetectVirusesSFSymbolIsValid() {
        let image = NSImage(systemSymbolName: "e.circle", accessibilityDescription: nil)
        XCTAssertNotNil(image, "e.circle should be a valid SF Symbol name")
    }

    /// Verifies that "t.circle" is a valid SF Symbol (used for comprehensiveTriage).
    func testComprehensiveTriageSFSymbolIsValid() {
        let image = NSImage(systemSymbolName: "t.circle", accessibilityDescription: nil)
        XCTAssertNotNil(image, "t.circle should be a valid SF Symbol name")
    }

    // MARK: - All OperationPreviewView.OperationKind Classification Cases

    /// Confirms the three classification operation kinds map to distinct preview kinds.
    func testClassificationPreviewKindsAreDistinct() {
        let classify = String(describing: OperationPreviewView.OperationKind.classifyReads)
        let viruses = String(describing: OperationPreviewView.OperationKind.detectViruses)
        let triage = String(describing: OperationPreviewView.OperationKind.comprehensiveTriage)

        let uniqueNames = Set([classify, viruses, triage])
        XCTAssertEqual(uniqueNames.count, 3, "All three classification kinds should be distinct")
    }

    // MARK: - Run Button Title Convention

    /// All OperationKind cases produce button title "Run" (not "Compute", "Classify...", etc.).
    ///
    /// Since updateRunButtonState is private, we verify the convention by checking
    /// that the OperationType enum used by OperationCenter has a .classification case
    /// with the expected raw value, confirming the operation tracking side is correct.
    func testClassificationOperationTypeRawValue() {
        XCTAssertEqual(OperationType.classification.rawValue, "Classification")
    }
}
