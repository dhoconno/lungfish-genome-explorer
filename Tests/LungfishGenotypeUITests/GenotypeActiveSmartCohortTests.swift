import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishGenotypeUI

/// Walk star 10. The viewer's `activeSmartCohort` is the one state behind
/// the quick filter bar pill and the Inspector's checkmark, and a second
/// click on the active cohort clears it. Restore Built-In Cohorts from the
/// Inspector reaches the viewer's own store (plan decision S13).
@MainActor
final class GenotypeActiveSmartCohortTests: GenotypeResultViewportTestCase {
    func testASecondClickOnTheActiveCohortClearsIt() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = configuredController(fixture)
        let needsReview = try builtIn("Needs review")

        controller.testingApplySmartCohort(needsReview)
        XCTAssertEqual(controller.testingActiveSmartCohort, needsReview)
        XCTAssertEqual(controller.testingSavedCohortChipTitle, "Cohort: Needs review")

        controller.testingApplySmartCohort(needsReview)
        XCTAssertNil(controller.testingActiveSmartCohort)
        XCTAssertNil(controller.testingSavedCohortChipTitle)
    }

    func testClickingAnotherCohortSwitchesTheActiveOne() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = configuredController(fixture)

        controller.testingApplySmartCohort(try builtIn("Needs review"))
        controller.testingApplySmartCohort(try builtIn("Homozygous"))

        XCTAssertEqual(controller.testingActiveSmartCohort?.name, "Homozygous")
        XCTAssertEqual(controller.testingSavedCohortChipTitle, "Cohort: Homozygous")
    }

    func testThePillAndTheInspectorFollowTheOneState() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = configuredController(fixture)
        var handedToInspector: [String?] = []
        controller.onActiveSmartCohortChanged = { handedToInspector.append($0?.name) }

        controller.testingApplySmartCohort(try builtIn("Recombinants"))
        XCTAssertEqual(controller.quickFilterBar.testingSavedCohortChipAccessibilityLabel, "Cohort: Recombinants")
        XCTAssertTrue(
            controller.quickFilterBar.testingVisibleButtonTitles.contains("Cohort: Recombinants"),
            "the pill is in the bar's view tree"
        )
        XCTAssertTrue(controller.quickFilterBar.testingSavedCohortChipShowsClearGlyphAfterTheName)

        controller.quickFilterBar.testingClearSavedCohort()

        XCTAssertNil(controller.testingActiveSmartCohort)
        XCTAssertNil(controller.testingSavedCohortChipTitle)
        XCTAssertNil(controller.quickFilterBar.testingSavedCohortChipAccessibilityLabel)
        XCTAssertEqual(handedToInspector, ["Recombinants", nil])
    }

    /// The Inspector builds its rows from the sidecar, so a saved filter's
    /// sidecar must reach it before the mark, or the mark finds no row.
    func testASavedFiltersSidecarReachesTheInspectorBeforeItsMark() async throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = configuredController(fixture)
        var events: [String] = []
        controller.onAnnotationSidecarChanged = { events.append("sidecar " + ($0.smartCohorts.last?.name ?? "")) }
        controller.onActiveSmartCohortChanged = { events.append("mark " + ($0?.name ?? "none")) }
        controller.testingSetUnifiedSampleFilter("AnimalA")

        try await controller.testingSaveCurrentFilterAsSmartCohort()

        XCTAssertEqual(events, ["sidecar Filter: AnimalA", "mark Filter: AnimalA"])
    }

    func testDeletingTheActiveCohortClearsItEverywhere() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = configuredController(fixture)
        let homozygous = try builtIn("Homozygous")
        var handedToInspector: [String?] = []
        controller.onActiveSmartCohortChanged = { handedToInspector.append($0?.name) }
        controller.testingApplySmartCohort(homozygous)

        NotificationCenter.default.post(
            name: .genotypeResultSmartCohortDeleteRequested, object: nil,
            userInfo: ScopedEventFilter.scopedUserInfo(["cohort": try JSONEncoder().encode(homozygous)], scope: fixture.scope)
        )

        XCTAssertNil(controller.testingActiveSmartCohort)
        XCTAssertNil(controller.testingSavedCohortChipTitle)
        XCTAssertEqual(handedToInspector, ["Homozygous", nil])
        XCTAssertFalse(controller.annotationStore?.sidecar.smartCohorts.map(\.name).contains("Homozygous") ?? true)
    }

    func testRestoreFromTheInspectorBringsTheDismissedCohortBackThroughTheViewersStore() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = configuredController(fixture)
        let homozygous = try builtIn("Homozygous")
        let scoped = ScopedEventFilter.scopedUserInfo(["cohort": try JSONEncoder().encode(homozygous)], scope: fixture.scope)
        NotificationCenter.default.post(name: .genotypeResultSmartCohortDeleteRequested, object: nil, userInfo: scoped)
        var inspectorSidecars: [GenotypeAnnotationSidecar] = []
        controller.onAnnotationSidecarChanged = { inspectorSidecars.append($0) }

        NotificationCenter.default.post(
            name: .genotypeResultSmartCohortsRestoreRequested, object: nil,
            userInfo: ScopedEventFilter.scopedUserInfo(scope: WindowStateScope())
        )
        XCTAssertTrue(inspectorSidecars.isEmpty, "another window's request must not reach this viewer")

        NotificationCenter.default.post(
            name: .genotypeResultSmartCohortsRestoreRequested, object: nil,
            userInfo: ScopedEventFilter.scopedUserInfo(scope: fixture.scope)
        )

        let onDisk = try GenotypeAnnotationSidecar.decode(Data(contentsOf: fixture.annotationURL))
        XCTAssertTrue(onDisk.smartCohorts.map(\.name).contains("Homozygous"))
        XCTAssertNil(onDisk.settings.dismissedBuiltInSmartCohorts)
        XCTAssertEqual(onDisk.auditLog.last?.action, "restoreBuiltInSmartCohorts")
        XCTAssertEqual(inspectorSidecars.last, controller.annotationStore?.sidecar)
        XCTAssertEqual(controller.annotationStore?.sidecar, onDisk)
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let bundleURL: URL
        let result: ONTGenotypeResultBundleData
        let scope: WindowStateScope

        var annotationURL: URL {
            bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = try TestTempDirectory.make(prefix: "GenotypeActiveCohort")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try installCallOverrideManifest(in: bundleURL)
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        )
        return Fixture(root: root, bundleURL: bundleURL, result: result, scope: WindowStateScope())
    }

    private func configuredController(_ fixture: Fixture) -> GenotypeResultViewController {
        let controller = makeMatrixAnnotationGuardedController()
        controller.windowStateScope = fixture.scope
        _ = controller.view
        controller.configure(result: fixture.result)
        XCTAssertTrue(controller.testingHasHaplotypingResult)
        return controller
    }

    private func builtIn(_ name: String) throws -> GenotypeCohortSmartFilter {
        try XCTUnwrap(GenotypeAnnotationStore.builtInSmartCohorts.first { $0.name == name })
    }
}
