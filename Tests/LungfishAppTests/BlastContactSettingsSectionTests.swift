// BlastContactSettingsSectionTests.swift - The contact address row of the General settings tab
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore
import ViewInspector
import XCTest
@testable import LungfishApp

/// Phase 3.2 lane BLASTNET, milestone N5 (UX-BLAST-WORDS Q6). The inspector runs neither `task` nor `onChange`, so
/// this test reads and writes no address.
@MainActor
final class BlastContactSettingsSectionTests: XCTestCase {
    func testTheGeneralTabHoldsTheContactRowWithItsWords() throws {
        let tab = try GeneralSettingsTab().inspect()
        let field = try tab.find(viewWithAccessibilityIdentifier: SettingsAccessibilityID.blastContactEmailField)
        XCTAssertEqual(try field.textField().labelView().text().string(), BlastContactAddress.Words.label)
        XCTAssertNoThrow(try tab.find(text: BlastContactAddress.Words.caption))
        XCTAssertNoThrow(try tab.find(text: BlastContactAddress.Words.state(.empty)), "an empty row says what NCBI gets")
    }
}
