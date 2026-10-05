// TreeInferenceResolverTests.swift - Which alignment the Build Tree item acts on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class TreeInferenceResolverTests: XCTestCase {
    private let displayed = URL(fileURLWithPath: "/p/Analyses/shown.lungfishmsa")
    private let one = URL(fileURLWithPath: "/p/Analyses/one.lungfishmsa")
    private let two = URL(fileURLWithPath: "/p/Analyses/two.lungfishmsa")
    private let reference = URL(fileURLWithPath: "/p/genome.lungfishref")

    func testDisplayedAlignmentWinsOverTheSidebarSelection() {
        XCTAssertEqual(
            AppDelegate.resolveTreeInferenceBundleURL(displayedBundleURL: displayed, sidebarSelection: [one]),
            displayed
        )
    }

    func testOneSelectedSidebarAlignmentIsUsedWhenNothingIsDisplayed() {
        XCTAssertEqual(
            AppDelegate.resolveTreeInferenceBundleURL(displayedBundleURL: nil, sidebarSelection: [one, reference]),
            one.standardizedFileURL
        )
    }

    func testTwoSelectedSidebarAlignmentsAreAmbiguous() {
        XCTAssertNil(AppDelegate.resolveTreeInferenceBundleURL(displayedBundleURL: nil, sidebarSelection: [one, two]))
    }

    func testNoAlignmentResolvesToNil() {
        XCTAssertNil(AppDelegate.resolveTreeInferenceBundleURL(displayedBundleURL: nil, sidebarSelection: []))
        XCTAssertNil(AppDelegate.resolveTreeInferenceBundleURL(displayedBundleURL: reference, sidebarSelection: [reference]))
    }

    func testBuildTreeActionIsImplementedByTheAppDelegate() {
        XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(AppDelegate.showIQTreeInference(_:))))
    }
}
