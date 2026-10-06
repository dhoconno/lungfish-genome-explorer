// AppDelegateMenuValidationReachabilityTests.swift - AppKit must be able to call AppDelegate.validateMenuItem
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp

/// AppKit asks a menu item's target `validateMenuItem(_:)` through the Objective-C runtime.
/// A Swift method that satisfies no `@objc` requirement is invisible to it, so every
/// enablement rule in `AppDelegate.validateMenuItem` was skipped and items such as
/// Tools > Build Tree with IQ-TREE… stayed enabled with nothing to act on.
@MainActor
final class AppDelegateMenuValidationReachabilityTests: XCTestCase {
    func testAppKitCanReachAppDelegateMenuValidation() {
        let delegate = AppDelegate()
        XCTAssertTrue(
            (delegate as AnyObject).responds(to: #selector(NSMenuItemValidation.validateMenuItem(_:))),
            "AppDelegate must expose validateMenuItem(_:) to the Objective-C runtime"
        )
    }

    func testBuildTreeItemIsDisabledWithoutAnAlignment() {
        let delegate = AppDelegate()
        let item = NSMenuItem(
            title: "Build Tree with IQ-TREE\u{2026}",
            action: #selector(ToolsMenuActions.showIQTreeInference(_:)),
            keyEquivalent: ""
        )
        let validator = delegate as NSMenuItemValidation
        XCTAssertFalse(validator.validateMenuItem(item))
        XCTAssertEqual(item.toolTip, AppDelegate.treeInferenceDisabledToolTip)
    }
}
