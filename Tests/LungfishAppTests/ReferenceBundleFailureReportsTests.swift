// ReferenceBundleFailureReportsTests.swift - The reference bundle viewport's failure alert (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit
import XCTest
@testable import LungfishApp

@MainActor
final class ReferenceBundleFailureReportsTests: XCTestCase {
    func testCopySequencesNamesTheStepAndKeepsTheRawErrorInTheDetails() {
        let raw = "posix_spawn ENOENT /tmp/x.fai"
        let error = NSError(domain: "ALERTTestDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: raw])
        let alert = FailurePresenter.alert(for: ReferenceBundleFailureReports.copySequences(error))
        XCTAssertEqual(alert.messageText, "Could not copy the reference sequences")
        XCTAssertEqual(
            alert.informativeText,
            "Lungfish could not read the sequences from the bundle, so nothing was copied.\n\n"
                + "Check that the bundle is still in the project and can be read, then copy the sequences again."
        )
        XCTAssertFalse(alert.informativeText.contains(raw), "raw error text stays out of the body")
        XCTAssertEqual((alert.accessoryView as? FailureDetailsView)?.textView.string.contains(raw), true)
    }
}
