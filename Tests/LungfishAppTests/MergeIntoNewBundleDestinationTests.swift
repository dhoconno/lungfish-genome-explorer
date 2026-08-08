// MergeIntoNewBundleDestinationTests.swift - Tests for the "Merge into New Bundle" pre-flight resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Task E2 (2026-08-08 repo review fix campaign): coordinator-flagged silent
// noop — contextMenuMergeIntoNewBundle's pre-flight guard
// (`guard selectedURLs.count == items.count, let destinationDirectory = ...
// else { return }`) returned with zero user-facing feedback when a selected
// item had no URL, or when the selection had no common parent directory.
// SidebarViewController.resolveMergeDestination is the pure, testable
// extraction of that guard; the @objc handler now surfaces an alert for
// each failure case instead of silently doing nothing.
//
// NOTE: this does NOT touch BundleMergeSelection.detectKind or the merge
// services themselves (ReferenceBundleMergeService / FASTQBundleMergeService)
// — those are owned by task GB1.

import XCTest
@testable import LungfishApp

@MainActor
final class MergeIntoNewBundleDestinationTests: XCTestCase {

    private func makeItem(type: SidebarItemType, title: String, url: URL?) -> SidebarItem {
        SidebarItem(title: title, type: type, url: url)
    }

    func testResolvesCommonParentWhenAllItemsHaveURLs() {
        let items = [
            makeItem(type: .referenceBundle, title: "a", url: URL(fileURLWithPath: "/tmp/project/a.lungfishref")),
            makeItem(type: .referenceBundle, title: "b", url: URL(fileURLWithPath: "/tmp/project/b.lungfishref")),
        ]

        let resolution = SidebarViewController.resolveMergeDestination(for: items)

        XCTAssertEqual(resolution, .resolved(URL(fileURLWithPath: "/tmp/project", isDirectory: true)))
    }

    func testReportsMissingURLsInsteadOfSilentlyNoOpping() {
        let items = [
            makeItem(type: .referenceBundle, title: "a", url: URL(fileURLWithPath: "/tmp/project/a.lungfishref")),
            makeItem(type: .referenceBundle, title: "b (no URL)", url: nil),
        ]

        let resolution = SidebarViewController.resolveMergeDestination(for: items)

        XCTAssertEqual(resolution, .missingURLs(titles: ["b (no URL)"]))
    }

    func testReportsAllMissingURLTitlesWhenMultipleItemsLackURLs() {
        let items = [
            makeItem(type: .referenceBundle, title: "a (no URL)", url: nil),
            makeItem(type: .referenceBundle, title: "b (no URL)", url: nil),
        ]

        let resolution = SidebarViewController.resolveMergeDestination(for: items)

        XCTAssertEqual(resolution, .missingURLs(titles: ["a (no URL)", "b (no URL)"]))
    }

    func testReportsNoCommonParentForEmptySelection() {
        let resolution = SidebarViewController.resolveMergeDestination(for: [])

        XCTAssertEqual(resolution, .noCommonParent)
    }
}
