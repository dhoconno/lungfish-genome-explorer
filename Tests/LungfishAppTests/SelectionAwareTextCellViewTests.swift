// SelectionAwareTextCellViewTests.swift - Colored table text stays readable on the selection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp

/// Capture on 9.59: green SNP text in the variants table could not be read on
/// the blue selection because a fixed color does not flip like `labelColor`.
@MainActor
final class SelectionAwareTextCellViewTests: XCTestCase {
    func testAccentTextSwitchesToSelectedTextColorWhenEmphasized() {
        let cell = SelectionAwareTextCellView()
        let field = NSTextField(labelWithString: "SNP")
        cell.addSubview(field)
        cell.textField = field

        cell.accentTextColor = .systemGreen
        XCTAssertEqual(field.textColor, .systemGreen)

        cell.backgroundStyle = .emphasized
        XCTAssertEqual(field.textColor, .alternateSelectedControlTextColor)

        cell.backgroundStyle = .normal
        XCTAssertEqual(field.textColor, .systemGreen)

        // A recycled cell without an accent falls back to the label color.
        cell.accentTextColor = nil
        XCTAssertEqual(field.textColor, .labelColor)
    }
}
