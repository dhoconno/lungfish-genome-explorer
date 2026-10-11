import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishGenotypeUI

/// The viewer's smart cohort state. Restore Built-In Cohorts from the
/// Inspector reaches the viewer's own store (plan decision S13).
@MainActor
final class GenotypeActiveSmartCohortTests: GenotypeResultViewportTestCase {
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
