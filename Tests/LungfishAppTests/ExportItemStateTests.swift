// ExportItemStateTests.swift - the Export item follows what a viewer can export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.40 M2 (UX ruling W3). The shared action bar disables the Export button with a help tag and
// restores the shared help when it enables again. EsViritu disables it while a batch has no sample picked, and NVD
// disables it while the cached rows show (no database) and while no sample is picked.

import AppKit
import XCTest
@testable import LungfishEsVirituUI
import LungfishIO
import LungfishKit
@testable import LungfishNvdUI
import LungfishTestSupport

@MainActor
final class ExportItemStateTests: XCTestCase {
    private var window: NSWindow?
    private var root: URL?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.contentViewController = nil
        window = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try await super.tearDown()
    }

    private func assertDisabled(
        _ bar: ClassifierActionBar, with words: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(bar.exportButton.isEnabled, "disabled", file: file, line: line)
        XCTAssertEqual(bar.exportButton.toolTip, words, "tag", file: file, line: line)
        XCTAssertEqual(bar.exportButton.accessibilityHelp(), words, "accessibility help", file: file, line: line)
    }

    private func assertEnabledWithSharedHelp(_ bar: ClassifierActionBar, file: StaticString = #filePath, line: UInt = #line) {
        let shared = LungfishHelpContent.resultExport
        XCTAssertTrue(bar.exportButton.isEnabled, "enabled", file: file, line: line)
        XCTAssertEqual(bar.exportButton.toolTip, shared.summary, "tag", file: file, line: line)
        XCTAssertEqual(
            bar.exportButton.accessibilityHelp(), shared.detail ?? shared.summary, "accessibility help",
            file: file, line: line
        )
    }

    func testTheWordsReadAsRuled() {
        XCTAssertEqual(ClassifierExportWords.pickASample, "Pick a sample to export.")
        XCTAssertEqual(
            ClassifierExportWords.missingDatabaseHelp,
            "Export needs this result's database, which is missing. Import the result again to export it."
        )
        XCTAssertEqual(
            ClassifierExportWords.missingDatabaseText,
            "Its database is missing from the result folder. Import the result again, then export."
        )
        XCTAssertEqual(ClassifierExportWords.missingDatabaseTitle(tool: "NAO-MGS"), "The NAO-MGS result could not be exported")
    }

    func testSetExportEnabledDisablesWithTheReasonAndRestoresTheSharedHelp() {
        let bar = ClassifierActionBar()
        bar.setExportEnabled(false, reason: ClassifierExportWords.pickASample)
        assertDisabled(bar, with: "Pick a sample to export.")

        bar.setExportEnabled(true)
        assertEnabledWithSharedHelp(bar)

        bar.setExportEnabled(false)
        XCTAssertFalse(bar.exportButton.isEnabled)
        XCTAssertEqual(
            bar.exportButton.toolTip, LungfishHelpContent.resultExport.summary,
            "a disabled button given no reason keeps the shared help"
        )
    }

    func testEsVirituExportButtonFollowsTheBatchPicker() throws {
        let vc = EsVirituResultViewController()
        _ = vc.view
        vc.isBatchMode = true
        vc.samplePickerState = ClassifierSamplePickerState(allSamples: Set(["sample-A", "sample-B"]))

        vc.samplePickerState.selectedSamples = []
        vc.applyBatchSampleFilter()
        assertDisabled(vc.actionBar, with: ClassifierExportWords.pickASample)

        vc.samplePickerState.selectedSamples = ["sample-A"]
        vc.applyBatchSampleFilter()
        XCTAssertNotNil(vc.esVirituResult)
        assertEnabledWithSharedHelp(vc.actionBar)

        vc.samplePickerState.selectedSamples = []
        vc.applyBatchSampleFilter()
        assertDisabled(vc.actionBar, with: ClassifierExportWords.pickASample)
    }

    func testEsVirituExportButtonStaysEnabledOutsideBatchMode() throws {
        let vc = EsVirituResultViewController()
        _ = vc.view
        vc.actionBar.setExportEnabled(false, reason: "stale")
        vc.refreshExportItem()
        assertEnabledWithSharedHelp(vc.actionBar)
    }

    func testNvdExportButtonFollowsTheDatabaseAndTheSamplePick() throws {
        NvdResultViewController.testMetadataUserDefaultsOverride = makeTestDefaultsSuite(prefix: "ExportItemStateTests").defaults
        addTeardownBlock { NvdResultViewController.testMetadataUserDefaultsOverride = nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd-export-item-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder
        let database = try NvdDatabase.create(
            at: folder.appendingPathComponent("nvd.sqlite"),
            hits: [],
            samples: [NvdSampleMetadata(
                sampleId: "sample1", bamPath: "sample1.bam", fastaPath: "sample1.fasta",
                totalReads: 1000, contigCount: 0, hitCount: 0
            )]
        )
        let manifest = NvdManifest(
            experiment: "exp-1", sampleCount: 1, contigCount: 0, hitCount: 0, blastDbVersion: "db",
            snakemakeRunId: "run-1", sourceDirectoryPath: folder.path,
            samples: [NvdSampleSummary(
                sampleId: "sample1", contigCount: 0, hitCount: 0, totalReads: 1000,
                bamRelativePath: "sample1.bam", bamIndexRelativePath: "sample1.bam.bai",
                fastaRelativePath: "sample1.fasta"
            )],
            cachedTopContigs: nil
        )
        let vc = NvdResultViewController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        host.isReleasedWhenClosed = false
        host.contentViewController = vc
        window = host
        _ = vc.view

        // The cached rows show first, with no database and no sample picked, and the database is checked first.
        vc.configureWithCachedRows([], manifest: manifest, bundleURL: folder)
        XCTAssertTrue(vc.selectedSamples.isEmpty)
        assertDisabled(vc.actionBar, with: ClassifierExportWords.missingDatabaseHelp)

        // The database view replaces them and picks every sample.
        vc.configure(database: database, manifest: manifest, bundleURL: folder)
        XCTAssertEqual(vc.selectedSamples, ["sample1"])
        assertEnabledWithSharedHelp(vc.actionBar)

        // Emptying the picker disables the item and picking a sample enables it again.
        vc.samplePickerState.selectedSamples = []
        vc.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertTrue(vc.selectedSamples.isEmpty)
        assertDisabled(vc.actionBar, with: ClassifierExportWords.pickASample)

        vc.samplePickerState.selectedSamples = ["sample1"]
        vc.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        assertEnabledWithSharedHelp(vc.actionBar)
    }
}
