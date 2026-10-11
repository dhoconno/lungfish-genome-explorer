import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishGenotypeUI

/// The Haplotype Calls and Genotype Matrix choice is app state (plan decision
/// S11). A switch writes only the bundle's declared app state file, after a
/// user event. Opening, reopening and a programmatic restore write nothing,
/// and an older sidecar's view field is the starting view and stays as it is.
/// Each case compares every file under the test root, hidden files and the
/// publication lock beside the bundle included, by bytes and modification
/// date before and after.
@MainActor
final class GenotypeResultViewAppStateTests: GenotypeResultViewportTestCase {
    func testAViewSwitchWritesOnlyTheDeclaredAppStateFile() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = configuredController(fixture)
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)

        switchView(controller, to: .matrix)

        let after = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)
        XCTAssertEqual(
            after.filter { $0.key != fixture.appStatePath }, before,
            "a view switch changes no file outside the declared app state"
        )
        XCTAssertEqual(GenotypeResultViewState.load(fromBundleAt: fixture.bundleURL)?.preferredSummaryViewMode, "matrix")
        XCTAssertEqual(
            BundleKindRegistry.descriptor(forLowercasedExtensionOf: fixture.bundleURL)?.appStateFileNames,
            [GenotypeResultViewState.filename]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.annotationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: fixture.annotationURL).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ONTGenotypeBundlePublicationLock.lockURL(for: fixture.bundleURL).path
        ))
    }

    func testSwitchingBackAndForthLeavesTheSidecarAndItsRecordUntouched() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        try writeAnnotatedSidecar(fixture, preferredSummaryViewMode: nil)
        let controller = configuredController(fixture)
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)

        switchView(controller, to: .matrix)
        switchView(controller, to: .outline)

        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root).filter { $0.key != fixture.appStatePath }, before)
        XCTAssertEqual(GenotypeResultViewState.load(fromBundleAt: fixture.bundleURL)?.preferredSummaryViewMode, "outline")
        XCTAssertEqual(controller.annotationStore?.sidecar.auditLog.map(\.action), ["setSampleStatus"])
    }

    func testReopeningRestoresTheChosenViewAndWritesNothing() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        switchView(configuredController(fixture), to: .matrix)
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)

        let reopened = configuredController(fixture)
        reopened.configure(result: fixture.result)

        XCTAssertEqual(reopened.testingDisplayState.summaryViewMode, .matrix)
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before, "opening writes nothing")
    }

    func testAnOlderSidecarsViewFieldIsTheStartingViewAndIsNeverRewritten() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        try writeAnnotatedSidecar(fixture, preferredSummaryViewMode: "matrix")
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)

        let controller = configuredController(fixture)

        XCTAssertEqual(controller.testingDisplayState.summaryViewMode, .matrix)
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before, "a read never migrates the field")
        XCTAssertNil(GenotypeResultViewState.load(fromBundleAt: fixture.bundleURL))
    }

    func testTheAppStateFileWinsOverAnOlderSidecarsViewField() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        try writeAnnotatedSidecar(fixture, preferredSummaryViewMode: "matrix")
        var chosen = GenotypeResultViewState(startingFrom: .default)
        chosen.preferredSummaryViewMode = "outline"
        try chosen.save(toBundleAt: fixture.bundleURL)
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)

        let controller = configuredController(fixture)

        XCTAssertEqual(controller.testingDisplayState.summaryViewMode, .outline)
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before)
    }

    /// Every programmatic restore applies its state directly, as the restore
    /// after a refused locus order or candidate display save does, so a
    /// changed presentation in it writes nothing.
    func testAProgrammaticRestoreOfAnotherViewWritesNothing() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = configuredController(fixture)
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)
        var state = controller.testingDisplayState
        state.summaryViewMode = .matrix

        controller.testingApplyDisplayStateImmediately(state)

        XCTAssertEqual(controller.testingDisplayState.summaryViewMode, .matrix)
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before)
    }

    func testAReadOnlyBundleKeepsTheSwitchForTheSessionOnly() throws {
        try XCTSkipIf(getuid() == 0, "a read-only folder is writable to root")
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: fixture.bundleURL.path)
            TestTempDirectory.cleanup(fixture.root)
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: fixture.bundleURL.path)
        let controller = configuredController(fixture)
        let before = try GenotypeBundleTreeSnapshot.entries(of: fixture.root)

        switchView(controller, to: .matrix)

        XCTAssertEqual(controller.testingDisplayState.summaryViewMode, .matrix)
        XCTAssertEqual(try GenotypeBundleTreeSnapshot.entries(of: fixture.root), before)
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
        XCTAssertEqual(GenotypeResultViewState.load(fromBundleAt: scenario.bundleURL)?.preferredSummaryViewMode, "outline")
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let bundleURL: URL
        let result: ONTGenotypeResultBundleData

        var annotationURL: URL {
            bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        }

        /// The app state file's key in `GenotypeBundleTreeSnapshot.entries(of: root)`.
        var appStatePath: String {
            "/" + bundleURL.lastPathComponent + "/" + GenotypeResultViewState.filename
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = try TestTempDirectory.make(prefix: "GenotypeViewAppState")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try installCallOverrideManifest(in: bundleURL)
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        )
        return Fixture(root: root, bundleURL: bundleURL, result: result)
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

    private func configuredController(_ fixture: Fixture) -> GenotypeResultViewController {
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view
        controller.configure(result: fixture.result)
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
