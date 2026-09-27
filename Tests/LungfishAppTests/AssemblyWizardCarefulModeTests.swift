// AssemblyWizardCarefulModeTests.swift - The Careful mode tick box follows the SPAdes profile
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The wizard cannot be click-tested here; these cover the static rules the
// tick box, its caption, and the curated argument list are built from.

import Foundation
import LungfishWorkflow
import XCTest
@testable import LungfishApp

final class AssemblyWizardCarefulModeTests: XCTestCase {
    func testCarefulModeIsDisabledWithACaptionForIsolateAndMeta() {
        XCTAssertFalse(AssemblyWizardSheet.carefulModeIsAvailable(spadesProfileID: "isolate"))
        XCTAssertFalse(AssemblyWizardSheet.carefulModeIsAvailable(spadesProfileID: "meta"))
        XCTAssertFalse(AssemblyWizardSheet.carefulModeIsAvailable(spadesProfileID: ""))
        XCTAssertTrue(AssemblyWizardSheet.carefulModeIsAvailable(spadesProfileID: "plasmid"))
        XCTAssertEqual(
            AssemblyWizardSheet.carefulModeCaption(spadesProfileID: "meta"),
            "Careful mode is unavailable with the Meta profile: SPAdes rejects --careful in metagenomic mode."
        )
        XCTAssertNil(AssemblyWizardSheet.carefulModeCaption(spadesProfileID: "plasmid"))
    }

    func testStaleCarefulTickNeverReachesAnIncompatibleProfile() {
        XCTAssertEqual(
            AssemblyWizardSheet.curatedAdvancedArguments(
                for: .spades, spadesCareful: true, spadesSkipErrorCorrection: true,
                flyeMetagenomeMode: false, hifiasmPrimaryOnly: false, spadesProfileID: "isolate"
            ),
            ["--only-assembler"]
        )
        XCTAssertEqual(
            AssemblyWizardSheet.curatedAdvancedArguments(
                for: .spades, spadesCareful: true, spadesSkipErrorCorrection: false,
                flyeMetagenomeMode: false, hifiasmPrimaryOnly: false, spadesProfileID: "plasmid"
            ),
            ["--careful"]
        )
    }
}
