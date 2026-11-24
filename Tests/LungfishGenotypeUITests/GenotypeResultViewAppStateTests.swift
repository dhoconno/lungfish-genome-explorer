import AppKit
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishGenotypeUI

/// The Haplotype Calls and Genotype Matrix choice and the panel layout are view memory in the store, outside every
/// bundle and project (the revisit of plan decision S11, VS-GENO). A switch, a reopen, a programmatic restore and
/// Reset View write nothing into the bundle. An older bundle's own `.genotype-viewstate.json` is a starting view only
/// while the item has no store entry and no retire mark, and nothing writes or deletes it. Each case compares every
/// file under the test root, hidden files and the publication lock beside the bundle included, by bytes and
/// modification date before and after. Each store lives in its own test folder (QA 6).
@MainActor
final class GenotypeResultViewAppStateTests: GenotypeResultViewportTestCase {
    /// The base wrote the choice into the bundle. It now writes no byte there and the store keeps it.
    func testAViewSwitchWritesNothingIntoTheBundle() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let controller = try await openRemembered(fixture)
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)

        switchView(controller, to: .matrix)
        controller.detachHostPresentationCallbacks()

        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before, "a view switch writes nothing")
        XCTAssertNil(GenotypeResultViewState.load(fromBundleAt: fixture.bundleURL))
        XCTAssertEqual(
            BundleKindRegistry.descriptor(forLowercasedExtensionOf: fixture.bundleURL)?.appStateFileNames,
            [GenotypeResultViewState.filename], "older bundles keep the file, which the record still leaves out"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.annotationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: fixture.annotationURL).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeBundlePublicationLock.lockURL(for: fixture.bundleURL).path
        ))
    }

    func testSwitchingBackAndForthLeavesTheSidecarAndItsRecordUntouched() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        try writeAnnotatedSidecar(fixture, preferredSummaryViewMode: nil)
        let controller = try await openRemembered(fixture)
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)

        switchView(controller, to: .matrix)
        switchView(controller, to: .outline)
        controller.detachHostPresentationCallbacks()

        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before)
        XCTAssertNil(GenotypeResultViewState.load(fromBundleAt: fixture.bundleURL))
        XCTAssertEqual(controller.annotationStore?.sidecar.auditLog.map(\.action), ["setSampleStatus"])
    }

    func testReopeningRestoresTheChosenViewFromTheStoreAndWritesNothing() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let first = try await openRemembered(fixture)
        switchView(first, to: .matrix)
        first.detachHostPresentationCallbacks()
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)

        let reopened = try await openRemembered(fixture)

        XCTAssertEqual(reopened.testingDisplayState.summaryViewMode, .matrix, "the store brought the choice back")
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before, "opening writes nothing")
    }

    func testAnOlderSidecarsViewFieldIsTheStartingViewAndIsNeverRewritten() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        try writeAnnotatedSidecar(fixture, preferredSummaryViewMode: "matrix")
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)

        let controller = configuredController(fixture)

        XCTAssertEqual(controller.testingDisplayState.summaryViewMode, .matrix)
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before, "a read never migrates the field")
        XCTAssertNil(GenotypeResultViewState.load(fromBundleAt: fixture.bundleURL))
    }

    /// BIO's condition for the revisit: an older bundle's own file is the starting view while the item has no entry,
    /// and showing it and leaving makes no entry (VS S3), so the file stays the starting view.
    func testAnOlderBundleFileIsTheStartingViewWhileTheItemHasNoEntry() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        try writeAnnotatedSidecar(fixture, preferredSummaryViewMode: "matrix")
        try writeOlderViewStateFile(fixture, preferredSummaryViewMode: "outline")
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)

        let first = try await openRemembered(fixture)
        XCTAssertEqual(first.testingDisplayState.summaryViewMode, .outline, "the older file wins over the sidecar")
        first.detachHostPresentationCallbacks()
        let key = try XCTUnwrap(fixture.store.key(for: ViewMemoryItem.read(at: fixture.bundleURL)))
        XCTAssertFalse(fixture.store.hasRecord(for: key), "showing an older bundle's look and leaving made an entry")

        let second = try await openRemembered(fixture)
        XCTAssertEqual(second.testingDisplayState.summaryViewMode, .outline)
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before, "nothing writes the older file")
    }

    /// BIO's condition for the revisit: an item's first entry in the store ends the reading of the older file.
    func testTheFirstStoreEntryEndsTheReadingOfTheOlderFile() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        try writeOlderViewStateFile(fixture, preferredSummaryViewMode: "matrix")
        XCTAssertNotNil(
            GenotypeViewMemoryRead.read(bundleURL: fixture.bundleURL, store: fixture.store).olderFile,
            "with no entry the older file is the starting view")

        let controller = try await openRemembered(fixture)
        XCTAssertEqual(controller.testingDisplayState.summaryViewMode, .matrix)
        switchView(controller, to: .outline) // a person's change
        controller.detachHostPresentationCallbacks()

        XCTAssertNil(
            GenotypeViewMemoryRead.read(bundleURL: fixture.bundleURL, store: fixture.store).olderFile,
            "an item with an entry read the older file again")
    }

    /// Reset View leaves a retire mark, so the older file is not read again and the reset stands at the next open. It
    /// writes and deletes nothing in the bundle.
    func testResetViewLeavesARetireMarkSoTheOlderFileIsNotReadAgain() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        try writeOlderViewStateFile(fixture, preferredSummaryViewMode: "matrix")
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)
        let controller = try await openRemembered(fixture)
        XCTAssertEqual(controller.testingDisplayState.summaryViewMode, .matrix)

        controller.resetViewMemory()
        XCTAssertEqual(controller.testingDisplayState.summaryViewMode, .outline, "Reset View shows the result's own view")
        controller.detachHostPresentationCallbacks()

        let reopened = try await openRemembered(fixture)
        XCTAssertEqual(reopened.testingDisplayState.summaryViewMode, .outline, "the next open read the older file again")
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before, "Reset View writes nothing")
    }

    /// SWIFT SF-2 of VS-REF, copied: a change made before the restore lands stands and is kept.
    func testAChangeMadeBeforeTheRestoreLandsIsStillKept() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let first = try await openRemembered(fixture)
        switchView(first, to: .matrix)
        first.detachHostPresentationCallbacks()

        let second = configuredController(fixture, store: fixture.store)
        var state = second.testingDisplayState
        state.layout = .listLeading
        second.applyDisplayState(state) // before the main actor's next turn, so before the read lands
        await waitUntil(budget: .standard) { second.viewMemoryIsSettled }
        XCTAssertEqual(second.testingDisplayState.summaryViewMode, .outline, "the late restore undid a change")
        XCTAssertEqual(second.testingDisplayState.layout, .listLeading)
        // The change is kept when the restore lands, not only at the leave (VS-GENO SWIFT SF-2).
        let item = ViewMemoryItem.read(at: fixture.bundleURL)
        let key = try XCTUnwrap(fixture.store.key(for: item))
        guard case .view(let kept, _, _) = fixture.store.restorable(GenotypeViewMemory.self, for: key, folder: item.folder) else {
            return XCTFail("the change made before the restore landed was not kept at once")
        }
        XCTAssertEqual(kept.layout, GenotypeResultPanelLayout.listLeading.rawValue)
        second.detachHostPresentationCallbacks()

        let third = try await openRemembered(fixture)
        XCTAssertEqual(third.testingDisplayState.layout, .listLeading, "a change made before the restore landed was not kept")
        XCTAssertEqual(third.testingDisplayState.summaryViewMode, .outline)
    }

    /// SWIFT SF-2 of VS-REF, copied: Reset View made before the restore lands is not undone by it.
    func testResetViewBeforeTheRestoreLandsIsNotUndone() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let first = try await openRemembered(fixture)
        switchView(first, to: .matrix)
        first.detachHostPresentationCallbacks()

        let second = configuredController(fixture, store: fixture.store)
        second.resetViewMemory()
        await waitUntil(budget: .standard) { second.viewMemoryIsSettled }
        XCTAssertEqual(second.testingDisplayState.summaryViewMode, .outline, "the late restore undid Reset View")
        second.detachHostPresentationCallbacks()

        let third = try await openRemembered(fixture)
        XCTAssertEqual(third.testingDisplayState.summaryViewMode, .outline, "the next open undid Reset View")
    }

    /// Every programmatic restore applies its state directly, as the restore
    /// after a refused locus order or candidate display save does, so a
    /// changed presentation in it writes nothing.
    func testAProgrammaticRestoreOfAnotherViewWritesNothing() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let controller = configuredController(fixture)
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)
        var state = controller.testingDisplayState
        state.summaryViewMode = .matrix

        controller.testingApplyDisplayStateImmediately(state)

        XCTAssertEqual(controller.testingDisplayState.summaryViewMode, .matrix)
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before)
    }

    /// A read-only bundle writes nothing, as before, and the store outside it keeps the choice (VS U9).
    func testAReadOnlyBundleKeepsTheSwitchForTheSessionOnly() async throws {
        try XCTSkipIf(getuid() == 0, "a read-only folder is writable to root")
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: fixture.bundleURL.path)
            cleanup(fixture)
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: fixture.bundleURL.path)
        let controller = try await openRemembered(fixture)
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)

        switchView(controller, to: .matrix)
        controller.detachHostPresentationCallbacks()

        XCTAssertEqual(controller.testingDisplayState.summaryViewMode, .matrix)
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before)
        let reopened = try await openRemembered(fixture)
        XCTAssertEqual(reopened.testingDisplayState.summaryViewMode, .matrix, "the store keeps a read-only bundle's view")
    }

    /// The export keeps the viewed sidecar, so after a switch it still records
    /// the settings block the bundle's file holds.
    func testAViewSwitchLeavesTheExcelExportSettingsBlockAsTheFileHoldsIt() throws {
        let scenario = try makeThresholdedMiSeqScenario()
        defer { scenario.cleanup() }
        let annotationURL = scenario.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let fileBytes = try Data(contentsOf: annotationURL)
        var state = scenario.controller.testingDisplayState
        state.summaryViewMode = .outline

        scenario.controller.applyDisplayState(state)
        let snapshot = try scenario.withAquaDrawingAppearance { try scenario.controller.captureExcelExportSnapshot() }

        XCTAssertEqual(try Data(contentsOf: annotationURL), fileBytes, "the switch leaves annotations.json as it was")
        let block = try GenotypeExportSettingsBlockPinTests.settingsBlock(of: XCTUnwrap(snapshot.annotationSidecarData))
        XCTAssertEqual(block, try GenotypeExportSettingsBlockPinTests.settingsBlock(of: fileBytes))
        XCTAssertEqual(block.values["preferredSummaryViewMode"], #"["matrix"]"#)
        XCTAssertNil(GenotypeResultViewState.load(fromBundleAt: scenario.bundleURL), "the switch writes no app state file")
    }

    // MARK: - Pickers and percent bases (item 2, VS B6)

    /// The cell colour is presentation and the percent bases change values. On the same data both come back, and the
    /// viewport says once that settings from the last visit change the values (word 5c).
    func testTheKeptColorAndPercentBasesComeBackOnTheSameDataWithTheSettingsLine() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let first = try await openRemembered(fixture)
        changePickersAndBases(first)
        XCTAssertNil(settingsLine(in: first), "a person's own change shows no line")
        first.detachHostPresentationCallbacks()

        let reopened = try await openRemembered(fixture)
        XCTAssertEqual(reopened.testingDisplayState.cellColorMode, .none)
        XCTAssertFalse(reopened.testingDisplayState.hideFilteredHighlights)
        XCTAssertEqual(reopened.testingDisplayState.supportDenominator, .sampleRetained)
        XCTAssertEqual(reopened.testingDisplayState.matrixPercentDenominator, .sampleRetained)
        XCTAssertEqual(settingsLine(in: reopened), ViewMemoryFilterLineForm.changesValues.text)
        XCTAssertNil(resetLine(in: reopened), "nothing was lost")

        var state = reopened.testingDisplayState
        state.supportDenominator = .viewedLocus
        reopened.applyDisplayState(state)
        XCTAssertNil(settingsLine(in: reopened), "the person changed a basis, so the line is gone")
    }

    /// A changed bundle keeps the colour, starts the percent bases at the open's and names the filters in one line.
    func testAChangedBundleDropsThePercentBasesKeepsTheColorAndSaysSo() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let first = try await openRemembered(fixture)
        changePickersAndBases(first)
        first.detachHostPresentationCallbacks()
        try Data("sample,genotype\n".utf8).write(to: fixture.bundleURL.appendingPathComponent("rerun-calls.csv"))

        let reopened = try await openRemembered(fixture)
        XCTAssertEqual(reopened.testingDisplayState.cellColorMode, .none, "the colour needs no data key")
        XCTAssertEqual(reopened.testingDisplayState.supportDenominator, .viewedLocus)
        XCTAssertEqual(reopened.testingDisplayState.matrixPercentDenominator, .viewedLocus)
        XCTAssertEqual(resetLine(in: reopened), ViewMemoryWords.dataChanged(.filters))
        XCTAssertNil(settingsLine(in: reopened), "no basis came back")
    }

    /// Reset View ends the settings line and shows the open's percent bases, and the next open keeps them.
    func testResetViewEndsTheSettingsLineAndTheRestoredPercentBases() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let first = try await openRemembered(fixture)
        changePickersAndBases(first)
        first.detachHostPresentationCallbacks()

        let reopened = try await openRemembered(fixture)
        XCTAssertNotNil(settingsLine(in: reopened))
        reopened.resetViewMemory()
        XCTAssertNil(settingsLine(in: reopened))
        XCTAssertEqual(reopened.testingDisplayState.matrixPercentDenominator, .viewedLocus)
        XCTAssertEqual(reopened.testingDisplayState.cellColorMode, .support)
        reopened.detachHostPresentationCallbacks()

        let third = try await openRemembered(fixture)
        XCTAssertEqual(third.testingDisplayState.matrixPercentDenominator, .viewedLocus, "the next open undid Reset View")
        XCTAssertNil(settingsLine(in: third))
    }

    /// BIO: after a restore the viewport export writes the percent basis the view shows.
    func testTheExportAfterARestoreWritesThePercentBasisTheViewShows() async throws {
        let scenario = try makeThresholdedMiSeqScenario()
        defer { scenario.cleanup() }
        let storeRoot = try TestTempDirectory.make(prefix: "GenotypeViewMemoryExport")
        defer { TestTempDirectory.cleanup(storeRoot) }
        let store = ViewMemoryStore(root: storeRoot.appendingPathComponent("view-memory", isDirectory: true))
        let first = try await open(scenario.result, store: store)
        var state = first.testingDisplayState
        state.matrixPercentDenominator = .sampleRetained
        first.applyDisplayState(state)
        first.detachHostPresentationCallbacks()

        let reopened = try await open(scenario.result, store: store)
        XCTAssertEqual(reopened.testingDisplayState.matrixPercentDenominator, .sampleRetained)
        let snapshot = try scenario.withAquaDrawingAppearance { try reopened.captureExcelExportSnapshot() }
        XCTAssertEqual(
            snapshot.filters["matrixPercentDenominator"], ONTGenotypeSupportDenominator.sampleRetained.displayName,
            "the export writes the basis the view shows")
    }

    // MARK: - Fix round 1 (the BIO and SWIFT reviews)

    /// BIO SF-1: the matrix a malformed analysis shows in place of Haplotype Calls is never kept as the person's mode,
    /// so the kept mode is there again once the analysis is usable.
    func testAMalformedAnalysisFallbackNeverReplacesTheKeptSummaryMode() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let first = try await openRemembered(fixture)
        var state = first.testingDisplayState
        state.layout = .listLeading
        first.applyDisplayState(state)
        first.detachHostPresentationCallbacks()

        let malformed = try await open(malformedResult(fixture), store: fixture.store)
        XCTAssertEqual(malformed.presentationPolicy?.persistencePolicy, .preserveStoredPreference)
        XCTAssertEqual(malformed.testingDisplayState.summaryViewMode, .matrix, "the fallback shows the matrix")
        malformed.detachHostPresentationCallbacks()

        let repaired = try await openRemembered(fixture)
        XCTAssertEqual(repaired.testingDisplayState.summaryViewMode, .outline, "the fallback matrix replaced the kept mode")
        XCTAssertEqual(repaired.testingDisplayState.layout, .listLeading)
    }

    /// BIO SF-1 on the path of SWIFT SF-2: a change made before the restore lands on a malformed analysis is kept
    /// with the kept mode, not with the fallback matrix.
    func testAChangeBeforeTheRestoreOnAMalformedAnalysisKeepsTheKeptSummaryMode() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let first = try await openRemembered(fixture)
        var state = first.testingDisplayState
        state.layout = .listLeading
        first.applyDisplayState(state)
        first.detachHostPresentationCallbacks()

        let malformed = configuredController(fixture, result: malformedResult(fixture), store: fixture.store)
        var early = malformed.testingDisplayState
        early.cellColorMode = .none
        malformed.applyDisplayState(early) // before the main actor's next turn, so before the read lands
        let settled = await waitUntil(budget: .standard) { malformed.viewMemoryIsSettled }
        XCTAssertTrue(settled, "the open's restore did not run")
        malformed.detachHostPresentationCallbacks()

        let repaired = try await openRemembered(fixture)
        XCTAssertEqual(repaired.testingDisplayState.summaryViewMode, .outline, "the fallback matrix replaced the kept mode")
        XCTAssertEqual(repaired.testingDisplayState.cellColorMode, .none, "the early change was kept")
    }

    /// BIO SF-2: word 2 at the top and word 5c at the foot sit beside the viewer's content, never over it, and the
    /// room they take goes when they go.
    func testTheViewMemoryLinesDoNotCoverTheViewersContent() async throws {
        // Word 2: the bundle changed, so the kept percent bases were dropped.
        let changed = try makeFixture()
        defer { cleanup(changed) }
        let left = try await openRemembered(changed)
        changePickersAndBases(left)
        left.detachHostPresentationCallbacks()
        try Data("sample,genotype\n".utf8).write(to: changed.bundleURL.appendingPathComponent("rerun-calls.csv"))
        let (withWord2, window2) = try await openInWindow(changed)
        XCTAssertEqual(resetLine(in: withWord2), ViewMemoryWords.dataChanged(.filters))
        assertLinesCoverNothing(in: withWord2)
        withWord2.detachHostPresentationCallbacks()
        XCTAssertEqual(withWord2.view.additionalSafeAreaInsets.top, 0, "the line went, so its room goes")
        window2.contentView = nil

        // Word 5c: the kept percent bases came back on the same data.
        let same = try makeFixture()
        defer { cleanup(same) }
        let kept = try await openRemembered(same)
        changePickersAndBases(kept)
        kept.detachHostPresentationCallbacks()
        let (withWord5c, window5c) = try await openInWindow(same)
        XCTAssertEqual(settingsLine(in: withWord5c), ViewMemoryFilterLineForm.changesValues.text)
        assertLinesCoverNothing(in: withWord5c)
        var state = withWord5c.testingDisplayState
        state.supportDenominator = .viewedLocus
        withWord5c.applyDisplayState(state)
        XCTAssertNil(settingsLine(in: withWord5c))
        XCTAssertEqual(withWord5c.view.additionalSafeAreaInsets.bottom, 0, "the line went, so its room goes")
        withWord5c.detachHostPresentationCallbacks()
        XCTAssertEqual(withWord5c.view.additionalSafeAreaInsets.top, 0)
        XCTAssertEqual(withWord5c.view.additionalSafeAreaInsets.bottom, 0)
        window5c.contentView = nil
    }

    private func malformedResult(_ fixture: Fixture) -> ONTGenotypeResultBundleData {
        makeResult(bundleURL: fixture.bundleURL, samples: [], calls: [], haplotypeAnalysis: makeEmptyHaplotypeAnalysis())
    }

    /// Opens the result in a window, as the app shows it, and waits for the open's restore.
    private func openInWindow(_ fixture: Fixture) async throws -> (GenotypeResultViewController, NSWindow) {
        let controller = makeMatrixAnnotationGuardedController()
        controller.viewMemoryStore = fixture.store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = controller.view
        controller.configure(result: fixture.result)
        let settled = await waitUntil(budget: .standard) { controller.viewMemoryIsSettled }
        XCTAssertTrue(settled, "the open's restore did not run")
        return (controller, window)
    }

    /// Every line on show has a height and covers no point of another visible part of the viewer.
    private func assertLinesCoverNothing(
        in controller: GenotypeResultViewController, file: StaticString = #filePath, line: UInt = #line
    ) {
        let root = controller.view
        root.layoutSubtreeIfNeeded()
        let isMemoryLine: (NSView) -> Bool = { $0 is ViewMemoryResetLineView || $0 is ViewMemoryFilterLineView }
        let lines = root.subviews.filter { isMemoryLine($0) && !$0.isHidden }
        XCTAssertFalse(lines.isEmpty, "no line shows", file: file, line: line)
        for memoryLine in lines {
            XCTAssertGreaterThan(memoryLine.frame.height, 0, file: file, line: line)
            for other in root.subviews where !isMemoryLine(other) && !other.isHidden {
                let overlap = memoryLine.frame.intersection(other.frame)
                let covered = overlap.isNull || overlap.width == 0 ? 0 : overlap.height
                XCTAssertLessThan(
                    covered, 0.5, "\(type(of: memoryLine)) covers \(covered) points of \(type(of: other))",
                    file: file, line: line)
            }
        }
    }

    private func changePickersAndBases(_ controller: GenotypeResultViewController) {
        var state = controller.testingDisplayState
        state.cellColorMode = .none
        state.hideFilteredHighlights = false
        state.supportDenominator = .sampleRetained
        state.matrixPercentDenominator = .sampleRetained
        controller.applyDisplayState(state)
    }

    private func open(_ result: ONTGenotypeResultBundleData, store: ViewMemoryStore) async throws -> GenotypeResultViewController {
        let controller = makeMatrixAnnotationGuardedController()
        controller.viewMemoryStore = store
        _ = controller.view
        controller.configure(result: result)
        let settled = await waitUntil(budget: .standard) { controller.viewMemoryIsSettled }
        XCTAssertTrue(settled, "the open's restore did not run")
        return controller
    }

    private func settingsLine(in controller: GenotypeResultViewController) -> String? {
        let line = controller.view.subviews.compactMap { $0 as? ViewMemoryFilterLineView }.first
        return line.flatMap { $0.isHidden ? nil : $0.displayedText }
    }

    private func resetLine(in controller: GenotypeResultViewController) -> String? {
        controller.view.subviews.compactMap { $0 as? ViewMemoryResetLineView }.first?.words
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let bundleURL: URL
        let result: ONTGenotypeResultBundleData
        let storeRoot: URL
        let store: ViewMemoryStore

        var annotationURL: URL {
            bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = try TestTempDirectory.make(prefix: "GenotypeViewAppState")
        let storeRoot = try TestTempDirectory.make(prefix: "GenotypeViewMemoryStore")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try installCallOverrideManifest(in: bundleURL)
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        )
        return Fixture(
            root: root, bundleURL: bundleURL, result: result, storeRoot: storeRoot,
            store: ViewMemoryStore(root: storeRoot.appendingPathComponent("view-memory", isDirectory: true)))
    }

    private func cleanup(_ fixture: Fixture) {
        TestTempDirectory.cleanup(fixture.root)
        TestTempDirectory.cleanup(fixture.storeRoot)
    }

    /// A sidecar the command line annotated, with its record beside it.
    private func writeAnnotatedSidecar(_ fixture: Fixture, preferredSummaryViewMode: String?) throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-01T00:00:00Z")
        sidecar.settings.preferredSummaryViewMode = preferredSummaryViewMode
        sidecar.sampleStatusFlags = [
            .init(sample: "AnimalA", value: .reviewed, author: "cli", timestamp: "2026-08-01T00:00:00Z"),
        ]
        sidecar.append(audit: .init(
            action: "setSampleStatus", sample: "AnimalA", locus: nil, slot: nil,
            before: nil, after: "reviewed", color: nil, reason: nil, rationale: nil,
            author: "cli", timestamp: "2026-08-01T00:00:00Z"
        ))
        try sidecar.encoded().write(to: fixture.annotationURL)
        try Data(#"{"outputs":[{"checksumSHA256":"recorded"}]}"#.utf8).write(
            to: ProvenanceRecorder.fileSidecarURL(for: fixture.annotationURL)
        )
    }

    /// The app state file an older build wrote into the bundle.
    private func writeOlderViewStateFile(_ fixture: Fixture, preferredSummaryViewMode: String) throws {
        var older = GenotypeResultViewState(startingFrom: .default)
        older.preferredSummaryViewMode = preferredSummaryViewMode
        try older.save(toBundleAt: fixture.bundleURL)
    }

    private func configuredController(
        _ fixture: Fixture, result: ONTGenotypeResultBundleData? = nil, store: ViewMemoryStore? = nil
    ) -> GenotypeResultViewController {
        let controller = makeMatrixAnnotationGuardedController()
        controller.viewMemoryStore = store
        _ = controller.view
        controller.configure(result: result ?? fixture.result)
        return controller
    }

    /// Opens the result as the route does, with the fixture's store, and waits for the open's restore.
    private func openRemembered(_ fixture: Fixture) async throws -> GenotypeResultViewController {
        let controller = configuredController(fixture, store: fixture.store)
        let settled = await waitUntil(budget: .standard) { controller.viewMemoryIsSettled }
        XCTAssertTrue(settled, "the open's restore did not run")
        return controller
    }

    /// The viewport's presentation control and the Inspector both reach the
    /// controller through `applyDisplayState(_:)`.
    private func switchView(_ controller: GenotypeResultViewController, to mode: GenotypeSummaryViewMode) {
        var state = controller.testingDisplayState
        state.summaryViewMode = mode
        controller.applyDisplayState(state)
        XCTAssertEqual(controller.testingDisplayState.summaryViewMode, mode)
    }
}
