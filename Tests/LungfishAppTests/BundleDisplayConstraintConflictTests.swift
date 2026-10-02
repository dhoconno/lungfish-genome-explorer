// BundleDisplayConstraintConflictTests.swift - Displaying a bundle raises no Auto Layout conflict
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Opening a reference bundle made AppKit report "Conflicting constraints
// detected" from `displayBundleSequence` in ViewerViewController+BundleDisplay.swift.
// The reference viewport's detail pane is 96 pt wide on its first layout, and
// the embedded viewer's hidden gene tab bar required 148 pt, so AppKit broke
// the overflow pop-up's minimum width. XCTest records every such report as a
// runtime issue and symbolicates it on the main thread, which held the main
// thread for seconds in each gate test process.

import os
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

@MainActor
final class BundleDisplayConstraintConflictTests: XCTestCase {
    private var tempRoot: URL!

    /// The "Conflicting constraints" issues XCTest recorded during the test.
    private nonisolated let recordedConstraintConflicts = OSAllocatedUnfairLock<[String]>(initialState: [])

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleDisplayConstraintConflictTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    /// XCTest records an Auto Layout conflict as a warning, which never fails
    /// a test. Recording it as an error fails the test that caused it, even
    /// when XCTest delivers the issue after the test's own assertion.
    nonisolated override func record(_ issue: XCTIssue) {
        let description = issue.compactDescription
        guard description.contains("Conflicting constraints")
            || description.contains("Unable to simultaneously satisfy constraints") else {
            super.record(issue)
            return
        }
        recordedConstraintConflicts.withLock { $0.append(description) }
        var failure = issue
        failure.severity = .error
        super.record(failure)
    }

    /// The gate case. `ReferenceBundleAnnotationPersistenceTests` opens bundles
    /// the same way and recorded this conflict in each test that opens one.
    func testDisplayingAReferenceBundleInTheMainWindowRaisesNoConstraintConflict() async throws {
        let bundleURL = try makeReferenceBundle()
        let (windowController, delegate) = try makeMainWindowAndDelegate()
        let viewer: ViewerViewController = try XCTUnwrap(windowController.mainSplitViewController.viewerController)

        try viewer.displayBundle(at: bundleURL, mode: .browse)

        // The browse route embeds a second viewer that shows the sequence.
        let embeddedViewer = try XCTUnwrap(viewer.referenceBundleViewportController?.testEmbeddedViewerController)
        XCTAssertEqual(embeddedViewer.currentBundleURL?.standardizedFileURL, bundleURL.standardizedFileURL)

        // XCTest records a runtime issue on the main thread after the call
        // that raised it, so let the work queued during the display run
        // before reading the record.
        let drained = XCTestExpectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 30)

        XCTAssertEqual(
            recordedConstraintConflicts.withLock { $0 },
            [],
            "displaying a bundle must not leave AppKit any constraint to break"
        )
        withExtendedLifetime(delegate) {}
    }

    /// The fix lets the overflow pop-up's 96 pt minimum yield only when the
    /// bar is too narrow for it. With room, the pop-up keeps that width even
    /// though the segmented control wants more space than the bar has.
    func testGeneTabBarOverflowPopUpKeepsItsMinimumWidthWhenTheBarHasRoom() throws {
        let bar = GeneTabBarView(frame: .zero)
        let regions = (0..<(GeneTabBarView.maxVisibleTabs + 3)).map {
            GeneRegion(name: "GENE\($0 + 1)", chromosome: "chr1", start: 1000 + $0 * 100, end: 1050 + $0 * 100)
        }
        // Filled before it has a superview, so no animated layout runs here.
        bar.setGeneRegions(regions)

        // The viewer pins the bar's width, so the tabs must fit inside it. A
        // free-standing window would grow to fit the segmented control
        // instead, so the width is pinned here too, below what the tabs want.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.widthAnchor.constraint(equalToConstant: 600),
        ])
        container.layoutSubtreeIfNeeded()

        let popUp = bar.testOverflowPopup
        XCTAssertFalse(popUp.isHidden, "more genes than tabs must show the overflow pop-up")
        XCTAssertEqual(bar.frame.width, 600, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(popUp.frame.width, 96)
    }

    // MARK: - Fixtures

    private func makeMainWindowAndDelegate() throws -> (MainWindowController, AppDelegate) {
        let delegate = AppDelegate()
        let directory = tempRoot.appendingPathComponent("window-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        delegate.projectWindowStateStore = ProjectWindowStateStore(stateURL: directory.appendingPathComponent("windows.json"))

        let windowController = delegate.createAndShowMainWindow()
        // Layout runs the same off screen, and an ordered-out window keeps the
        // display link from redrawing the viewer while the test waits.
        windowController.window?.orderOut(nil)
        addTeardownBlock {
            windowController.close()
        }
        return (windowController, delegate)
    }

    /// A one-sequence `.lungfishref` bundle with an uncompressed FASTA and index.
    private func makeReferenceBundle() throws -> URL {
        let bundleURL = tempRoot.appendingPathComponent("Constraints.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("genome", isDirectory: true),
            withIntermediateDirectories: true
        )
        try ">chr1\nACGTACGTACGTACGTACGTACGTACGTACGTA\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "chr1\t33\t6\t33\t34\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa.fai"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = BundleManifest(
            name: "Constraints",
            identifier: "org.lungfish.test.\(UUID().uuidString.lowercased())",
            source: SourceInfo(organism: "Test", assembly: "Constraints"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 33,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 33, offset: 6, lineBases: 33, lineWidth: 34)
                ]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
