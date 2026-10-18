// AppDelegateMenuValidationTests.swift - Menu validation never decodes a manifest or a mapping result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

/// AppKit validates menu items each time a menu opens. Import BAM validation
/// decoded a selected mapping folder's mapping-result.json (252 MB for a large
/// reference) even with a bundle on screen, and Call Variants validation
/// decoded the whole manifest of the displayed bundle.
@MainActor
final class AppDelegateMenuValidationTests: XCTestCase {
    override func tearDown() async throws {
        BundleLoadProbe.install(nil)
        try await super.tearDown()
    }

    func testImportBAMValidationDoesNotLoadMappingResult() throws {
        let root = try TestTempDirectory.make(prefix: "MenuValidationDecodes")
        defer { TestTempDirectory.cleanup(root) }
        let resultURL = root.appendingPathComponent("minimap2-run", isDirectory: true)
        let copyURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "ref", chromosomes: [.init(name: "chr1", length: 100)], in: resultURL
        )
        try MappingRoutingFixture.makeMappingResult(
            resultDirectory: resultURL, viewerBundleURL: copyURL
        ).save(to: resultURL)
        let displayedURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "displayed", chromosomes: [.init(name: "chr1", length: 100)], in: root
        )
        let displayedManifest = try BundleManifest.load(from: displayedURL)
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: false)
        let delegate = AppDelegate()
        let windowController = MainWindowController()
        _ = windowController.window
        delegate.mainWindowController = windowController
        let viewer = try XCTUnwrap(windowController.mainSplitViewController?.viewerController)

        // Nothing on screen: the selected mapping folder stands for its reference copy.
        XCTAssertEqual(
            delegate.currentReferenceBundleURL(for: viewer, sidebarSelection: [resultURL])?.standardizedFileURL,
            copyURL.standardizedFileURL
        )
        // A displayed bundle wins, so the selection is never read.
        try viewer.display(ViewerDisplayRouteFactory.directReferenceBundle(
            bundleURL: displayedURL, manifest: displayedManifest
        ))
        XCTAssertEqual(
            delegate.currentReferenceBundleURL(for: viewer, sidebarSelection: [resultURL]),
            displayedURL.standardizedFileURL
        )
        let importBAM = NSMenuItem(title: "Import BAM", action: #selector(AppDelegate.importBAMToBundle(_:)), keyEquivalent: "")
        XCTAssertTrue(delegate.validateMenuItem(importBAM))
        let callVariants = NSMenuItem(title: "Call Variants", action: #selector(AppDelegate.showBAMVariantCalling(_:)), keyEquivalent: "")
        XCTAssertFalse(delegate.validateMenuItem(callVariants), "the displayed bundle has no alignment track")

        XCTAssertEqual(decodes.count(.mappingResult), 0)
        XCTAssertEqual(decodes.count(.bundleManifest), 0)
    }
}
