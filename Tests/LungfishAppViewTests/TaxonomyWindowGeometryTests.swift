// TaxonomyWindowGeometryTests.swift - Classification views must never resize the window
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKit

/// Regression tests for the Preview 2026.9.57 defect where selecting a CZ-ID
/// classification grew the main window from 1129 pt to 5355 pt tall. The
/// summary bar computed its preferred height while it still had zero width,
/// which wrapped the long "Dominant" name one character per line, and a
/// required height constraint pushed that height up to the window.
@MainActor
final class TaxonomyWindowGeometryTests: XCTestCase {

    private static let longName =
        "Severe acute respiratory syndrome coronavirus 2 isolate with an exceptionally long strain designation"

    private func makeLongNameResult() -> ClassificationResult {
        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 1200, fractionClade: 1.0, fractionDirect: 0,
            parentTaxId: nil
        )
        let viruses = TaxonNode(
            taxId: 10239, name: "Viruses", rank: .domain, depth: 1,
            readsDirect: 88, readsClade: 130, fractionClade: 0.11, fractionDirect: 0.07,
            parentTaxId: 1
        )
        viruses.parent = root
        root.children = [viruses]
        let species = TaxonNode(
            taxId: 2697049, name: Self.longName, rank: .species, depth: 2,
            readsDirect: 42, readsClade: 42, fractionClade: 0.035, fractionDirect: 0.035,
            parentTaxId: 10239
        )
        species.parent = viruses
        viruses.children = [species]
        let tree = TaxonTree(root: root, unclassifiedNode: nil, totalReads: 1200)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxonomy-geometry-\(UUID().uuidString)")
        let config = ClassificationConfig(
            inputFiles: [tempDir.appendingPathComponent("reads.fastq")],
            isPairedEnd: false,
            databaseName: "test-db",
            databasePath: tempDir.appendingPathComponent("db"),
            outputDirectory: tempDir
        )
        return ClassificationResult(
            config: config,
            tree: tree,
            reportURL: tempDir.appendingPathComponent("classification.kreport"),
            outputURL: tempDir.appendingPathComponent("classification.kraken"),
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.1.3",
            provenanceId: nil
        )
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1800, height: 1129),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    /// Mirrors `ViewerViewController.displayTaxonomyResult` and
    /// `CzIdResultViewController`: the controller is configured before its
    /// view joins the hierarchy, then pinned to the host's edges.
    func testLongDominantNameConfiguredBeforeHostingDoesNotGrowWindow() {
        let window = makeWindow()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1800, height: 1129))
        window.contentView = host
        window.layoutIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil }
        let startFrame = window.frame

        let vc = TaxonomyViewController()
        let taxView = vc.view
        vc.configure(result: makeLongNameResult())
        taxView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(taxView)
        NSLayoutConstraint.activate([
            taxView.topAnchor.constraint(equalTo: host.topAnchor),
            taxView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            taxView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            taxView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        window.layoutIfNeeded()

        XCTAssertEqual(window.frame.height, startFrame.height, accuracy: 0.5)
        XCTAssertEqual(window.frame.width, startFrame.width, accuracy: 0.5)
        XCTAssertLessThanOrEqual(vc.testSummaryBar.frame.height, 120)
    }

    func testLongDominantNameConfiguredWhileHostedDoesNotGrowWindow() {
        let window = makeWindow()
        defer { window.orderOut(nil); window.contentViewController = nil }
        let vc = TaxonomyViewController()
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1800, height: 1129))
        window.layoutIfNeeded()
        let startHeight = window.frame.height

        vc.configure(result: makeLongNameResult())
        window.layoutIfNeeded()

        XCTAssertEqual(window.frame.height, startHeight, accuracy: 0.5)
        XCTAssertLessThanOrEqual(vc.testSummaryBar.frame.height, 120)
    }

    func testSummaryBarPreferredHeightIsBoundedBeforeItHasAWidth() {
        let bar = TaxonomySummaryBar()
        bar.update(tree: makeLongNameResult().tree)
        XCTAssertEqual(bar.bounds.width, 0)
        XCTAssertLessThanOrEqual(bar.preferredContentHeight, 120)
    }

    func testSummaryBarPreferredHeightIsBoundedAtNarrowWidth() {
        let bar = TaxonomySummaryBar(frame: NSRect(x: 0, y: 0, width: 130, height: 48))
        bar.update(tree: makeLongNameResult().tree)
        // One column of six cards: every card keeps a fixed, bounded height.
        let frames = bar.testingCardFrames
        XCTAssertEqual(frames.count, 6)
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.height, 80, "\(frame)")
        }
    }
}
