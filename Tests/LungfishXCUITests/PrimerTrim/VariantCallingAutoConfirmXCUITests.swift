// VariantCallingAutoConfirmXCUITests.swift - Auto-confirm toggle visible on primer-trimmed BAMs
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

/// Confirms the variant-calling dialog's iVar panel shows an auto-confirmed
/// (disabled, pre-checked) toggle plus the "Primer-trimmed by Lungfish"
/// caption when the selected BAM carries a primer-trim provenance sidecar.
///
/// The state-level behavior is covered by `PrimerTrimThenIVarTests` and
/// `BAMVariantCallingAutoConfirmTests`; this UI test remains as the dialog
/// rendering check.
final class VariantCallingAutoConfirmXCUITests: XCTestCase {
    @MainActor
    func testVariantCallingDialogAutoConfirmsTrimForLungfishTrimmedBAM() throws {
        throw XCTSkip(
            "Pending: LungfishProjectFixtureBuilder.makePrimerTrimmedBundleProject(..) and the corresponding Tests/Fixtures/xcui/sarscov2-primer-trimmed-bundle/ snapshot. Unblock by landing a fixture whose BAM has a primer-trim-provenance.json sidecar, then verify the auto-confirm caption text in BAMVariantCallingToolPanes is UI-queryable."
        )

        // Reference implementation:
        //
        // let projectURL = try LungfishProjectFixtureBuilder.makePrimerTrimmedBundleProject(
        //     named: "PrimerTrimmedXCUIFixture"
        // )
        // let app = XCUIApplication()
        // app.launchArguments = LungfishUITestLaunchOptions.launchArguments(openingProject: projectURL)
        // app.launch()
        // defer {
        //     app.terminate()
        //     try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        // }
        //
        // app.buttons["Call Variants…"].click()
        //
        // let dialog = app.windows.containing(
        //     NSPredicate(format: "title == %@", "Call Variants")
        // ).firstMatch
        // XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        //
        // app.buttons["iVar"].click()
        //
        // let toggle = app.checkBoxes["This BAM has already been primer-trimmed for iVar."]
        // XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // XCTAssertEqual(toggle.value as? String, "1", "Auto-confirmed toggle must be checked.")
        // XCTAssertFalse(toggle.isEnabled, "Auto-confirmed toggle must be disabled.")
        //
        // let auto = app.staticTexts.matching(
        //     NSPredicate(format: "label CONTAINS 'Primer-trimmed by Lungfish'")
        // ).firstMatch
        // XCTAssertTrue(auto.exists, "Caption announcing the Lungfish-run trim must be visible.")
    }
}
