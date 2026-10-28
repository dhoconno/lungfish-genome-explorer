// PhylogeneticSubtreeExportFailureTests.swift - The Export Subtree failure alert (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import XCTest
@testable import LungfishPhylogeneticsUI

@MainActor
final class PhylogeneticSubtreeExportFailureTests: XCTestCase {
    func testSubtreeExportFailureNamesTheStepAndKeepsTheErrorInDetails() throws {
        let error = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSLocalizedDescriptionKey: "raw write error 513"])
        let alert = FailurePresenter.alert(for: PhylogeneticTreeViewController.subtreeExportFailure(error))
        XCTAssertEqual(alert.messageText, "Could not export the subtree")
        XCTAssertEqual(alert.informativeText.components(separatedBy: "\n\n").count, 2)
        XCTAssertFalse(alert.informativeText.contains("raw write error 513"))
        let details = try XCTUnwrap(alert.accessoryView as? FailureDetailsView)
        XCTAssertTrue(details.textView.string.contains("raw write error 513"))
        XCTAssertTrue(details.textView.string.contains("code 513"))
    }
}
