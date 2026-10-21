// LayoutSuiteSeams.swift - Points the keyed tables of a result view at a suite that the test owns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishNaoMgsUI

/// A test that opens a result in one of these views calls `isolateLayouts(_:)` first, so the tables of the view
/// keep their column layouts in a suite that the test removes when it ends and write nothing to
/// `UserDefaults.standard` (Phase 2.13 lane 13.69, review 13.52-SWIFT R1).
extension XCTestCase {
    @nonobjc @MainActor
    func isolateLayouts(_ view: NaoMgsResultViewController) {
        view.metadataColumnController.userDefaults = makeTestDefaultsSuite(prefix: "NaoMgsLayoutSeam").defaults
    }
}
