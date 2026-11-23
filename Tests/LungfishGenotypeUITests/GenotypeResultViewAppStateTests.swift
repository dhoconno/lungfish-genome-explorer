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

    private func configuredController(_ fixture: Fixture, store: ViewMemoryStore? = nil) -> GenotypeResultViewController {
        let controller = makeMatrixAnnotationGuardedController()
        controller.viewMemoryStore = store
        _ = controller.view
        controller.configure(result: fixture.result)
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
