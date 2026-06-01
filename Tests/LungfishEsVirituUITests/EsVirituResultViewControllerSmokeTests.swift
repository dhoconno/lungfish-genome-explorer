// EsVirituResultViewControllerSmokeTests.swift - Standalone smoke test for the EsViritu leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishEsVirituUI
import LungfishWorkflow
import LungfishKit

final class EsVirituResultViewControllerSmokeTests: XCTestCase {
    @MainActor func testViewControllerInstantiates() {
        let vc = EsVirituResultViewController()
        XCTAssertNotNil(vc.view)
    }
}
