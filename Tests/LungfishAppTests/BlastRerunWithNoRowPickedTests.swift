// BlastRerunWithNoRowPickedTests.swift - Re-run BLAST never does nothing and says nothing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Row RERUN-SILENT (ROWPANE-UX Backlog 4, ruling R4), one test a viewer. No search starts and no modal opens.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishAssemblyUI
@testable import LungfishKit
@testable import LungfishTwelveSUI

@MainActor
final class BlastRerunWithNoRowPickedTests: XCTestCase {
    func testAssemblyGreysReRunWithNoContigSelected() {
        let viewer = AssemblyResultViewController()
        _ = viewer.view
        let button = viewer.ensureBlastDrawer().rerunBlastButton

        viewer.selectedContigNames = []
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.toolTip, ClassifierActionWords.selectRowToVerify)

        viewer.selectedContigNames = ["contig_1"]
        XCTAssertTrue(button.isEnabled)
        XCTAssertNil(button.toolTip)
    }

    func testTwelveSGreysReRunWithNoRowListed() {
        let viewer = TwelveSAmpliconResultViewController()
        _ = viewer.view
        let button = viewer.ensureBlastDrawer().rerunBlastButton

        viewer.updateBlastRerunRule()

        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.toolTip, ClassifierActionWords.selectRowToVerify)
    }

    /// FASTA's Re-run repeats the last search and reads no selection, so it stays enabled, as TaxTriage's does (R2), and a
    /// press with nothing selected still hands on. Greying it from the selection would switch off a working action.
    func testFASTAReRunRepeatsTheLastSearchWithNothingSelected() {
        let viewer = FASTACollectionViewController()
        _ = viewer.view
        var handedOn = 0
        viewer.onBlastRerunRequested = { handedOn += 1 }
        let button = viewer.ensureBlastDrawer().rerunBlastButton

        XCTAssertTrue(button.isEnabled)
        button.performClick(nil)

        XCTAssertEqual(handedOn, 1)
    }
}
