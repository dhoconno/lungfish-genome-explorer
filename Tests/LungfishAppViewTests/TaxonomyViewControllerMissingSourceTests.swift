// TaxonomyViewControllerMissingSourceTests.swift - Copied Kraken result with its reads elsewhere
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKit

/// A Kraken 2 result copied from another project still shows its taxonomy,
/// tells the user which source data is missing, and switches off the actions
/// that would need it instead of letting them fail.
@MainActor
final class TaxonomyViewControllerMissingSourceTests: XCTestCase {

    private func makeRecord(missingReads: Bool) -> ProjectItemCopyRecord {
        let link = ProjectItemCopyLink(
            file: "classification-result.json",
            keyPath: missingReads ? "config.inputFiles[0]" : "config.databasePath",
            originalPath: missingReads
                ? "/Volumes/Old/Source.lungfish/Imports/HG002.lungfishfastq/reads.fastq.gz"
                : "/Volumes/Old/Source.lungfish/Databases/standard-8",
            resolvedPath: nil,
            role: missingReads ? ProjectItemLinkRewriter.Role.inputReads : ProjectItemLinkRewriter.Role.database
        )
        return ProjectItemCopyRecord(
            copiedAt: Date(),
            sourceItemPath: "/Volumes/Old/Source.lungfish/Analyses/kraken2-2026-09-24T10-00-00",
            sourceProjectPath: "/Volumes/Old/Source.lungfish",
            targetProjectPath: "/Volumes/New/Target.lungfish",
            links: [link]
        )
    }

    private func makeResult() throws -> ClassificationResult {
        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 100, fractionClade: 1.0, fractionDirect: 0.0,
            parentTaxId: 0
        )
        let species = TaxonNode(
            taxId: 562, name: "Escherichia coli", rank: .species, depth: 1,
            readsDirect: 90, readsClade: 90, fractionClade: 0.9, fractionDirect: 0.9,
            parentTaxId: 1
        )
        species.parent = root
        root.children = [species]
        let tree = TaxonTree(root: root, unclassifiedNode: nil, totalReads: 100)
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("missing-source-\(UUID().uuidString)", isDirectory: true)
        let config = ClassificationConfig(
            inputFiles: [URL(fileURLWithPath: "/Volumes/Old/Source.lungfish/Imports/HG002.lungfishfastq/reads.fastq.gz")],
            isPairedEnd: false,
            databaseName: "standard-8",
            databasePath: URL(fileURLWithPath: "/tmp/db"),
            outputDirectory: outputDirectory
        )
        return ClassificationResult(
            config: config,
            tree: tree,
            reportURL: outputDirectory.appendingPathComponent("classification.kreport"),
            outputURL: outputDirectory.appendingPathComponent("classification.kraken"),
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.1.3",
            provenanceId: nil
        )
    }

    /// UX-3E-LABELS R7 (approved as O86). A result that cannot reach its reads, with no reason from the copy receipt,
    /// gives both greyed buttons the ruled sentence and not "Read-level actions are unavailable for this result".
    func testTheFallbackReasonIsTheRuledSentence() throws {
        let controller = TaxonomyViewController()
        isolateLayouts(controller)
        _ = controller.view
        controller.configure(result: try makeResult())

        controller.readLevelActionsAvailable = false

        let bar = controller.testActionBar
        let reason = ClassifierActionWords.sourceReadsMissing + " "
        XCTAssertEqual(bar.extractButton.toolTip?.hasPrefix(reason), true)
        XCTAssertEqual(bar.blastButton.toolTip?.hasPrefix(reason), true)
        XCTAssertEqual(bar.extractButton.accessibilityHelp()?.hasPrefix(reason), true)
    }

    /// UX-3E-LABELS line 19 (approved as O86). VoiceOver speaks the toggle as BLAST Results, the name the button shows,
    /// and not as Toggle BLAST Results Drawer.
    func testTheBlastResultsToggleIsSpokenAsBlastResults() throws {
        let controller = TaxonomyViewController()
        isolateLayouts(controller)
        _ = controller.view

        let buttons = controller.testActionBar.subviews.compactMap { $0 as? NSButton }
        let toggle = try XCTUnwrap(buttons.first { $0.title == "BLAST Results" }, "the bar holds the toggle")
        XCTAssertEqual(toggle.accessibilityLabel(), "BLAST Results")
    }

    func testMissingReadsShowNoticeAndDisableReadLevelActionsWithReason() throws {
        let controller = TaxonomyViewController()
        isolateLayouts(controller)
        _ = controller.view
        controller.configure(result: try makeResult())
        XCTAssertTrue(controller.missingSourceNotice.isHidden)

        controller.applyProjectCopyRecord(makeRecord(missingReads: true))

        XCTAssertFalse(controller.missingSourceNotice.isHidden)
        XCTAssertNotNil(controller.tree, "the taxonomy still renders from the result's own files")
        XCTAssertFalse(controller.readLevelActionsAvailable)
        XCTAssertEqual(controller.readLevelActionsUnavailableReason, "Source reads are not in this project (reads.fastq.gz)")

        let extract = controller.actionBar.extractButton
        XCTAssertFalse(extract.isEnabled)
        XCTAssertFalse(controller.actionBar.blastButton.isEnabled)
        XCTAssertTrue(extract.toolTip?.hasPrefix("Source reads are not in this project (reads.fastq.gz)") == true, "tooltip was \(extract.toolTip ?? "nil")")

        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.missingSourceNotice.frame.height, MissingSourceNoticeView.preferredHeight)
    }

    func testMissingDatabaseKeepsReadLevelActionsButShowsNotice() throws {
        let controller = TaxonomyViewController()
        isolateLayouts(controller)
        _ = controller.view
        controller.configure(result: try makeResult())

        controller.applyProjectCopyRecord(makeRecord(missingReads: false))

        XCTAssertFalse(controller.missingSourceNotice.isHidden)
        XCTAssertTrue(controller.readLevelActionsAvailable)
        XCTAssertNil(controller.readLevelActionsUnavailableReason)
    }

    func testNoRecordLeavesViewportUnchanged() throws {
        let controller = TaxonomyViewController()
        isolateLayouts(controller)
        _ = controller.view
        controller.configure(result: try makeResult())

        controller.applyProjectCopyRecord(nil)

        XCTAssertTrue(controller.missingSourceNotice.isHidden)
        XCTAssertTrue(controller.readLevelActionsAvailable)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.missingSourceNotice.frame.height, 0)
    }
}
