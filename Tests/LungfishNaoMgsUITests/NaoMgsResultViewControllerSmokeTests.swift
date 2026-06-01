// NaoMgsResultViewControllerSmokeTests.swift - Standalone smoke test for the NAO-MGS leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishNaoMgsUI
import LungfishWorkflow
import LungfishKit

final class NaoMgsResultViewControllerSmokeTests: XCTestCase {
    @MainActor func testViewControllerInstantiates() {
        let vc = NaoMgsResultViewController()
        XCTAssertNotNil(vc.view)
    }
}
