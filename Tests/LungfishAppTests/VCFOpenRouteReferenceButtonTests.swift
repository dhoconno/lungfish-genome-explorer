// VCFOpenRouteReferenceButtonTests.swift - A VCF that opens in the app never shows a Download Reference button that does nothing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
import LungfishTestSupport

/// Probe of the trust session, lane PROBES-C, row VCF-DOWNLOAD-REFERENCE-DEAD-BUTTON.
///
/// The row feared a VCF dashboard with a Download Reference button whose `onDownloadReferenceRequested` handler
/// nothing set. The dashboard (`VCFDatasetViewController`) and its display route went in 9a1a63580, so the button
/// has no home. A VCF now goes through `MainSplitViewController.loadVCFFilesInBackground`, which imports it into a
/// `.lungfishref` bundle with `VCFAutoIngestor` and shows that bundle with
/// `displayReferenceBundleViewportFromSidebar(at:)`. The window cannot answer the bundle-name sheet in a test, so
/// this test runs the ingest and the display the route runs after the sheet, and reads every control the app then
/// shows. The pin holds when no control that offers a reference download is left without an action.
@MainActor
final class VCFOpenRouteReferenceButtonTests: XCTestCase {
    private var retainedSplit: MainSplitViewController?

    override func tearDown() async throws {
        retainedSplit = nil
        try await super.tearDown()
    }

    func testAVCFOpenedThroughTheImportRouteShowsNoDownloadReferenceButtonWithoutAnAction() async throws {
        let root = try TestTempDirectory.make(prefix: "VCFOpenRouteReferenceButton")
        defer { TestTempDirectory.cleanup(root) }
        let vcf = root.appendingPathComponent("calls.vcf")
        try """
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs1\tA\tG\t30.0\tPASS\t.
        chr1\t200\trs2\tC\tT\t25.0\tPASS\t.
        """.write(to: vcf, atomically: true, encoding: .utf8)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        // The ingest the route runs after the person names the bundle.
        let result = try await VCFAutoIngestor.ingest(vcfURL: vcf, outputDirectory: project)
        XCTAssertEqual(result.variantCount, 2, "the VCF became a bundle of 2 variants")

        // The display the route runs when the ingest ends (`MainSplitViewController+GenomicsDisplay.swift:197`).
        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        retainedSplit = split
        split.displayReferenceBundleViewportFromSidebar(at: result.bundleURL)

        let opened = await waitUntil(budget: .lookup) {
            split.viewerController.referenceBundleViewportController?
                .testEmbeddedViewerController.currentReferenceBundle?.url.standardizedFileURL
                == result.bundleURL.standardizedFileURL
        }
        XCTAssertTrue(opened, "the VCF bundle never opened in the reference bundle viewport")
        XCTAssertNotNil(
            split.viewerController.referenceBundleViewportController,
            "a VCF opens in the reference bundle viewport, which holds no dashboard"
        )

        split.view.layoutSubtreeIfNeeded()
        let scan = Self.scanControls(in: split.view)
        XCTAssertGreaterThan(scan.controlsRead, 0, "the scan read no control, so it could not have found a button")
        // A control that offers a reference download and has no action is the dead button the row feared.
        let dead = scan.downloadReference.filter { $0.action == nil }
        XCTAssertTrue(
            dead.isEmpty,
            "a Download Reference control with no action shows on the VCF route: \(dead.map(Self.describe))"
        )
    }

    // MARK: - The scan

    private struct ControlScan {
        var controlsRead = 0
        var downloadReference: [NSControl] = []
    }

    /// Every control under `root`, and the ones whose title, tool tip or accessibility label offers a reference download.
    private static func scanControls(in root: NSView) -> ControlScan {
        var scan = ControlScan()
        func visit(_ view: NSView) {
            if let control = view as? NSControl {
                scan.controlsRead += 1
                if offersReferenceDownload(control) {
                    scan.downloadReference.append(control)
                }
            }
            for sub in view.subviews { visit(sub) }
        }
        visit(root)
        return scan
    }

    private static func words(of control: NSControl) -> String {
        var parts: [String?] = [control.toolTip, control.accessibilityLabel()]
        if let button = control as? NSButton {
            parts += [button.title, button.alternateTitle]
        }
        if let field = control as? NSTextField {
            parts.append(field.stringValue)
        }
        if let segments = control as? NSSegmentedControl {
            parts += (0..<segments.segmentCount).map { segments.label(forSegment: $0) }
        }
        return parts.compactMap { $0 }.joined(separator: " ").lowercased()
    }

    private static func offersReferenceDownload(_ control: NSControl) -> Bool {
        let text = words(of: control)
        return text.contains("download") && text.contains("reference")
    }

    private static func describe(_ control: NSControl) -> String {
        "\(type(of: control)) '\(words(of: control))' enabled=\(control.isEnabled) action=\(String(describing: control.action))"
    }
}
