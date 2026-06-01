// TaxTriageResultViewControllerSmokeTests.swift - Standalone smoke test for the TaxTriage leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishTaxTriageUI
import LungfishWorkflow
import LungfishKit

final class TaxTriageResultViewControllerSmokeTests: XCTestCase {
    @MainActor func testViewControllerInstantiates() {
        let vc = TaxTriageResultViewController()
        XCTAssertNotNil(vc.view)
    }
}
