// FASTQMeasuringBehindTests.swift - A read set that is being measured shows none of the previous read set's numbers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishTestSupport

/// Phase 3.0 lane DEMUX-STATS-BEHIND (BIO ruling DEMUX-STATS-BEHIND, walk 3 continued). Selecting a read set whose
/// statistics were never counted starts a measurement, and the viewer shows a spinner with words for it. The spinner
/// sat below the previous dashboard, viewer and Inspector sections, so the cards, the reads list and the Inspector kept
/// the previous read set's read count, Mean Q and GC for the whole count while the sidebar named the new one.
///
/// These tests run at the `MainSplitViewController` level in a real window, which sees the subview order and the
/// Inspector. The measurement is detached and reports back through the main actor, so each assertion made right after
/// the synchronous call sees the measuring state and no test waits.
@MainActor
final class FASTQMeasuringBehindTests: XCTestCase {
    private var root: URL!
    private var split: MainSplitViewController!
    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "fastq-measuring-behind")
        let controller = MainSplitViewController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        host.contentViewController = controller
        host.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        split = controller
        window = host
    }

    override func tearDown() async throws {
        window.contentViewController = nil
        window = nil
        split = nil
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The numbers of the read set that is on screen first (the walk's SRR12486983).
    private static let previousStatistics = statistics(readCount: 9_639_520, meanQuality: 4.9, gcContent: 0.437)

    /// Counted numbers of a derived bundle that shows at once.
    private static let countedStatistics = statistics(readCount: 1_710_778, meanQuality: 25.4, gcContent: 0.619)

    private static func statistics(readCount: Int, meanQuality: Double, gcContent: Double) -> FASTQDatasetStatistics {
        FASTQDatasetStatistics(
            readCount: readCount, baseCount: Int64(readCount) * 100,
            meanReadLength: 100, minReadLength: 88, maxReadLength: 118,
            medianReadLength: 98, n50ReadLength: 108,
            meanQuality: meanQuality, q20Percentage: 60, q30Percentage: 40, gcContent: gcContent,
            readLengthHistogram: [88: 1, 98: 1, 108: 1, 118: 1],
            qualityScoreHistogram: [2: 80, 10: 80, 20: 80, 30: 80, 40: 80],
            perPositionQuality: []
        )
    }

    /// A `.lungfishfastq` folder that holds a tiny FASTQ and no statistics file, the shape of an import whose
    /// statistics were never stored.
    private func makePlainBundle(named name: String) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "@r1\nACGTACGT\n+\nIIIIIIII\n".write(
            to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8
        )
        return bundle
    }

    /// The same fixture `DerivedFASTQStatisticsDisplayTests` uses. A derived bundle whose manifest stores counts only
    /// is measured when it is shown. With `statistics` given, the manifest stores counted numbers and shows at once.
    private func makeDerivedBundle(named name: String, statistics: FASTQDatasetStatistics? = nil) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let operation = FASTQDerivativeOperation(kind: .demultiplex, toolUsed: "exact-barcode-demux", toolVersion: nil)
        let manifest = FASTQDerivedBundleManifest(
            name: name, parentBundleRelativePath: "../root.lungfishfastq",
            rootBundleRelativePath: "../root.lungfishfastq", rootFASTQFilename: "reads.fastq",
            lineage: [operation], operation: operation,
            cachedStatistics: statistics ?? .countsOnlyFixture(readCount: 4, baseCount: 400), pairingMode: nil
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundle)
        return bundle
    }

    /// Shows `bundle` the way the end of a count does, and checks that the dashboard and the Inspector took it.
    private func showDashboard(of bundle: URL, statistics: FASTQDatasetStatistics) {
        split.viewerController.displayFASTQDataset(
            statistics: statistics, records: [],
            fastqURL: bundle.appendingPathComponent("reads.fastq"),
            sraRunInfo: nil, enaReadRecord: nil, ingestionMetadata: nil,
            fastqSourceURL: bundle, fastqDerivativeManifest: nil
        )
        XCTAssertTrue(split.viewerController.isDisplayingFASTQDataset, "the dashboard of \(bundle.lastPathComponent) shows")
        XCTAssertEqual(
            split.inspectorController.viewModel.documentSectionViewModel.fastqStatistics?.readCount, statistics.readCount,
            "the Inspector shows the numbers of \(bundle.lastPathComponent)"
        )
        XCTAssertEqual(
            split.inspectorController.fastqMetadataSectionViewModel.bundleURL?.standardizedFileURL,
            bundle.standardizedFileURL, "the Inspector's sample metadata belongs to \(bundle.lastPathComponent)"
        )
    }

    /// Stops the detached count of a test, so that nothing shows an alert or a dashboard after the test ends.
    private func endRequests() {
        split.cancelFASTQLoadIfNeeded(hideProgress: false, reason: "test end")
    }

    /// The assertions all four routes share while a count runs: none of the previous read set's content is installed,
    /// the Inspector holds nothing of it, and the spinner shows on top with its words.
    private func assertMeasuringStateShowsNothingOf(previous: URL, words: String, file: StaticString = #filePath, line: UInt = #line) {
        let viewer = split.viewerController!
        let inspector = split.inspectorController!
        XCTAssertFalse(viewer.isDisplayingFASTQDataset, "the previous dashboard is gone", file: file, line: line)
        XCTAssertNil(viewer.currentFASTQDatasetURL, "no dataset URL of the previous read set remains", file: file, line: line)
        XCTAssertNil(
            inspector.viewModel.documentSectionViewModel.fastqStatistics,
            "the Inspector holds none of the previous numbers", file: file, line: line
        )
        XCTAssertNotEqual(
            inspector.fastqMetadataSectionViewModel.bundleURL?.standardizedFileURL, previous.standardizedFileURL,
            "the sample metadata section is not the previous read set's", file: file, line: line
        )
        XCTAssertTrue(
            viewer.progressOverlayIsShownOnTop, "the spinner shows with nothing above it", file: file, line: line
        )
        XCTAssertEqual(viewer.progressOverlay.message, words, "the spinner names the work", file: file, line: line)
    }

    // MARK: - The tests

    /// Walk 3 continued: SRR12486983 is on screen, then `lengthFilter-old`, a derived bundle whose statistics were
    /// never counted, is selected. Its own cards must not show 9,639,520 reads, Mean Q 4.9 and GC 43.7%.
    func testUncountedDerivedBundleAfterADashboardShowsNoNumberOfThePreviousBundle() throws {
        defer { endRequests() }
        let previous = try makePlainBundle(named: "SRR12486983")
        showDashboard(of: previous, statistics: Self.previousStatistics)

        split.loadFASTQDatasetInBackground(sourceURL: try makeDerivedBundle(named: "BC02"))

        assertMeasuringStateShowsNothingOf(
            previous: previous, words: FASTQStatisticsDisplayRules.measuringWords(for: "BC02")
        )
    }

    /// A reference bundle's viewport covers the whole container, so the spinner sat under it as well.
    func testUncountedDerivedBundleAfterAReferenceViewportShowsTheOverlayOnTop() throws {
        defer { endRequests() }
        let viewer = split.viewerController!
        viewer.displayReferenceBundleViewportLoading(
            title: "Reference", documentURL: root.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        )
        XCTAssertNotNil(viewer.referenceBundleViewportController, "the reference viewport is up before the selection")

        split.loadFASTQDatasetInBackground(sourceURL: try makeDerivedBundle(named: "BC02"))

        XCTAssertNil(viewer.referenceBundleViewportController, "the reference viewport is gone")
        XCTAssertTrue(viewer.progressOverlayIsShownOnTop, "the spinner shows with nothing above it")
        XCTAssertEqual(viewer.progressOverlay.message, FASTQStatisticsDisplayRules.measuringWords(for: "BC02"))
    }

    /// The plain path, for a bundle that is not derived and has no stored statistics, has the same shape and shipped
    /// in Stable 2026.9.78.
    func testPlainUncountedBundleAfterADashboardShowsNoNumberOfThePreviousBundle() throws {
        defer { endRequests() }
        let previous = try makePlainBundle(named: "SRR12486983")
        showDashboard(of: previous, statistics: Self.previousStatistics)

        split.loadFASTQDatasetInBackground(sourceURL: try makePlainBundle(named: "NoStoredStatistics"))

        assertMeasuringStateShowsNothingOf(previous: previous, words: "Computing FASTQ statistics...")
    }

    /// Walk W4a: the count is abandoned for a bundle whose numbers are stored. That bundle's dashboard shows, and the
    /// abandoned count's spinner must not stay behind it.
    func testCancelledMeasurementLeavesNoOverlayBehindTheNextDashboard() throws {
        defer { endRequests() }
        let viewer = split.viewerController!
        let counted = try makeDerivedBundle(named: "BC01", statistics: Self.countedStatistics)
        split.loadFASTQDatasetInBackground(sourceURL: try makeDerivedBundle(named: "BC02"))
        XCTAssertFalse(viewer.progressOverlay.isHidden, "the count of BC02 shows its spinner")

        split.loadFASTQDatasetInBackground(sourceURL: counted)

        XCTAssertTrue(viewer.isDisplayingFASTQDataset, "the dashboard of BC01 shows")
        XCTAssertTrue(viewer.progressOverlay.isHidden, "the abandoned count leaves no spinner behind")
    }

    // MARK: - The Inspector around the clear (item 5)

    /// The sample metadata section saves an edit 0.5 s after the last keystroke, and clearing the section for the next
    /// selection cancels that wait. An edit made just before the person selected the next read set was dropped. It is
    /// saved to its own bundle first, and it is never written into the next bundle.
    func testAnEditToOneBundlesMetadataIsSavedToItWhenAnUncountedBundleIsSelected() throws {
        defer { endRequests() }
        let previous = try makePlainBundle(named: "SRR12486983")
        showDashboard(of: previous, statistics: Self.previousStatistics)
        let section = split.inspectorController.fastqMetadataSectionViewModel
        section.metadata?.sampleType = "nasal swab"
        section.scheduleAutosave()
        XCTAssertTrue(section.hasUnsavedChanges, "the edit waits for its autosave")

        let next = try makeDerivedBundle(named: "BC02")
        split.loadFASTQDatasetInBackground(sourceURL: next)

        let saved = try? String(
            contentsOf: previous.appendingPathComponent(FASTQBundleCSVMetadata.filename), encoding: .utf8
        )
        XCTAssertTrue(saved?.contains("nasal swab") == true, "the edit is saved to the bundle it was made in")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: next.appendingPathComponent(FASTQBundleCSVMetadata.filename).path),
            "the edit is not written into the next bundle"
        )
    }

    /// The clear drops what the sidebar's notification told the Inspector (the selection identity and the targets), so
    /// this pins that the Inspector still takes the bundle's own numbers and sample metadata when its count ends.
    func testTheInspectorShowsTheBundlesOwnNumbersWhenItsCountEnds() throws {
        defer { endRequests() }
        let previous = try makePlainBundle(named: "SRR12486983")
        showDashboard(of: previous, statistics: Self.previousStatistics)
        let next = try makeDerivedBundle(named: "BC02")
        split.inspectorController.activeContentSelectionIdentity = split.contentSelectionIdentity(
            url: next, kind: "fastqBundle", resultID: "BC02"
        )

        split.loadFASTQDatasetInBackground(sourceURL: next)
        showDashboard(of: next, statistics: Self.countedStatistics)

        XCTAssertEqual(
            split.inspectorController.fastqMetadataSectionViewModel.metadata?.sampleName, "BC02",
            "the sample metadata section shows the bundle's own sample"
        )
    }

    // MARK: - The section around a counted bundle and a moved target (review should-fix 1)

    /// A counted bundle's dashboard loads its own sample metadata into the section without a clear, so the edit made a
    /// moment earlier was dropped, and its armed autosave then wrote into the next bundle. The edit is saved to its own
    /// bundle first and the wait is cancelled.
    func testAnEditToOneBundlesMetadataIsSavedToItWhenACountedBundleIsShown() throws {
        defer { endRequests() }
        let previous = try makePlainBundle(named: "SRR12486983")
        showDashboard(of: previous, statistics: Self.previousStatistics)
        let section = split.inspectorController.fastqMetadataSectionViewModel
        section.metadata?.sampleType = "nasal swab"
        section.scheduleAutosave()
        XCTAssertTrue(section.hasUnsavedChanges, "the edit waits for its autosave")

        let next = try makePlainBundle(named: "BC01")
        showDashboard(of: next, statistics: Self.countedStatistics)

        let saved = try? String(
            contentsOf: previous.appendingPathComponent(FASTQBundleCSVMetadata.filename), encoding: .utf8
        )
        XCTAssertTrue(saved?.contains("nasal swab") == true, "the edit is saved to the bundle it was made in")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: next.appendingPathComponent(FASTQBundleCSVMetadata.filename).path),
            "the edit is not written into the next bundle"
        )
    }

    /// The sidebar moves the read-type targets to the clicked bundle (`selectionDidChange`) while the section still
    /// shows the previous one. A read-type change made just before the click belongs to the previous bundle alone.
    func testAReadTypeEditIsSentToItsOwnBundleWhenTheSidebarMovesTheTargets() throws {
        defer { endRequests() }
        let previous = try makePlainBundle(named: "SRR12486983")
        showDashboard(of: previous, statistics: Self.previousStatistics)
        let section = split.inspectorController.fastqMetadataSectionViewModel
        var seen: [[URL]] = []
        section.platformLabelChanger = { _, bundleURLs, _ in seen.append(bundleURLs.map(\.standardizedFileURL)) }
        section.setAssemblyReadType(.ontReads)

        section.setReadTypeTargetBundleURLs([try makePlainBundle(named: "BC02")])

        XCTAssertEqual(
            seen, [[previous.standardizedFileURL]], "the read-type change goes to the bundle it was made in"
        )
    }
}
