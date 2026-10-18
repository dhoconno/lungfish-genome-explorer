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

    /// Call Variants validation reads the bundle the viewer holds, and the viewer holds nothing until its
    /// embedded viewer has opened the displayed bundle. A disabled item then proves nothing by itself.
    /// This waits for the viewer to hold each bundle, so the item is off for the bundle with no alignment
    /// track and on for the bundle with one, and neither answer decodes a manifest.
    func testCallVariantsValidationFollowsTheBundleTheViewerHolds() async throws {
        let root = try TestTempDirectory.make(prefix: "MenuValidationCallVariants")
        defer { TestTempDirectory.cleanup(root) }
        let plainURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "plain", chromosomes: [.init(name: "chr1", length: 100)], in: root
        )
        let alignedURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "aligned", chromosomes: [.init(name: "chr1", length: 100)], in: root
        )
        try MappingRoutingFixture.addSingleSampleAlignment(to: alignedURL, sampleID: "S1")
        let plainManifest = try BundleManifest.load(from: plainURL)
        let alignedManifest = try BundleManifest.load(from: alignedURL)
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: false)
        let delegate = AppDelegate()
        let windowController = MainWindowController()
        _ = windowController.window
        delegate.mainWindowController = windowController
        let viewer = try XCTUnwrap(windowController.mainSplitViewController?.viewerController)
        let callVariants = NSMenuItem(title: "Call Variants", action: #selector(AppDelegate.showBAMVariantCalling(_:)), keyEquivalent: "")

        try viewer.display(ViewerDisplayRouteFactory.directReferenceBundle(
            bundleURL: plainURL, manifest: plainManifest
        ))
        let holdsPlain = await waitUntil(timeout: .seconds(30)) {
            delegate.heldReferenceBundle(in: windowController)?.url.standardizedFileURL == plainURL.standardizedFileURL
        }
        XCTAssertTrue(holdsPlain, "the viewer never held the bundle with no alignment track")
        XCTAssertFalse(delegate.validateMenuItem(callVariants), "the held bundle has no alignment track")

        try viewer.display(ViewerDisplayRouteFactory.directReferenceBundle(
            bundleURL: alignedURL, manifest: alignedManifest
        ))
        let holdsAligned = await waitUntil(timeout: .seconds(30)) {
            delegate.heldReferenceBundle(in: windowController)?.url.standardizedFileURL == alignedURL.standardizedFileURL
        }
        XCTAssertTrue(holdsAligned, "the viewer never held the bundle with an alignment track")
        XCTAssertTrue(delegate.validateMenuItem(callVariants), "the held bundle has an alignment track")

        XCTAssertEqual(decodes.count(.mappingResult), 0)
        XCTAssertEqual(decodes.count(.bundleManifest), 0)
    }
}
