import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishGenotypeUI

/// Phase 2.11 lane U64 (K9, decision B3). The last line of the refusal that `genotype export-labkey` prints for smart
/// cohorts that share a cohort id tells a person to delete the cohorts it names, save each one they still need again
/// from its filter, and export again. It adds that a delete removes every cohort with the same name and scope. Three
/// facts of the store make those words true, and these tests pin them so that the store and the words change together.
///
/// - After a delete no cohort holds the name, so a cohort saved under it stores a derived id that no other cohort of
///   the sidecar holds.
/// - A delete removes every cohort of the name and scope, an unlisted twin included.
/// - Saving a cohort again under a name that a cohort still holds keeps the stored id of that cohort
///   (`GenotypeCohortSmartFilter.inheritingID(from:)`), so a save alone never ends a shared id.
@MainActor
final class GenotypeCohortSharedIDRemedyTests: XCTestCase {
    /// An id that a sidecar stores and that no derivation from a scope and a name produces.
    private static let sharedID = UUID(uuidString: "6f2c7d1e-4b8a-4c35-9e07-3a1d5b9f8c42")!

    func testDeletingTheNamedCohortsAndSavingAgainLeavesNoSharedId() async throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        try writeSidecar(
            [
                cohort("Errors at MHC-A", .hasErrorAt(locus: "MHC-A"), id: Self.sharedID),
                cohort("Late calls", .hasAnyComment, id: Self.sharedID),
            ],
            to: layout
        )
        let store = try open(layout)
        XCTAssertEqual(store.sidecar.resolvedSmartCohortIDs, [Self.sharedID, Self.sharedID])

        try await store.deleteSmartCohort(name: "Errors at MHC-A", scope: "bundle")
        try await store.deleteSmartCohort(name: "Late calls", scope: "bundle")
        try await store.saveSmartCohort(cohort("Filter: Errors at MHC-A", .hasErrorAt(locus: "MHC-A")))
        try await store.saveSmartCohort(cohort("Filter: Late calls", .hasAnyComment))

        let onDisk = try reread(layout)
        XCTAssertEqual(onDisk.smartCohorts.count, 2)
        XCTAssertEqual(Set(onDisk.smartCohorts.map(\.name)), ["Filter: Errors at MHC-A", "Filter: Late calls"])
        XCTAssertEqual(Set(onDisk.resolvedSmartCohortIDs).count, 2, "each cohort now has an id of its own")
        XCTAssertFalse(onDisk.resolvedSmartCohortIDs.contains(Self.sharedID), "and neither is the shared id")
    }

    func testADeleteRemovesEveryCohortWithTheSameNameAndScope() async throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        try writeSidecar(
            [
                cohort("Errors", .hasErrorAt(locus: "MHC-A"), id: Self.sharedID),
                cohort("Errors", .hasAnyComment, id: Self.sharedID),
                cohort("Other", .needsHaplotypeReview),
            ],
            to: layout
        )
        let store = try open(layout)

        try await store.deleteSmartCohort(name: "Errors", scope: "bundle")

        XCTAssertEqual(try reread(layout).smartCohorts.map(\.name), ["Other"], "the unlisted twin goes with the named one")
    }

    /// The evidence that a save alone is not the remedy. If the store changes how a save treats the id of the
    /// cohort it replaces, this test and the refusal's words change together.
    func testSavingAgainAloneKeepsASharedIdSoTheLineDeletesFirst() async throws {
        let layout = try makeFreshBundle()
        defer { TestTempDirectory.cleanup(layout.root) }
        try writeSidecar(
            [
                cohort("Filter: Errors at MHC-A", .hasErrorAt(locus: "MHC-A"), id: Self.sharedID),
                cohort("Late calls", .hasAnyComment, id: Self.sharedID),
            ],
            to: layout
        )
        let store = try open(layout)

        try await store.saveSmartCohort(cohort("Filter: Errors at MHC-A", .hasErrorAt(locus: "MHC-A")))

        let onDisk = try reread(layout)
        XCTAssertEqual(onDisk.smartCohorts.count, 2)
        XCTAssertEqual(Set(onDisk.resolvedSmartCohortIDs).count, 1, "the saved cohort keeps the id it replaced")
    }

    // MARK: - Fixtures

    private struct Layout {
        let root: URL
        let bundleURL: URL

        var annotationURL: URL {
            bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        }
    }

    private func makeFreshBundle() throws -> Layout {
        let root = try TestTempDirectory.make(prefix: "GenotypeCohortSharedIDRemedy")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(#"{"analysis":"cohort-shared-id-remedy"}"#.utf8).write(
            to: bundleURL.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
        )
        return Layout(root: root, bundleURL: bundleURL)
    }

    /// Opens the store without the built-in cohorts, so a sidecar holds only the cohorts a test writes.
    private func open(_ layout: Layout) throws -> GenotypeAnnotationStore {
        try GenotypeAnnotationStore(bundleURL: layout.bundleURL, author: "analyst", seedBuiltInSmartCohorts: false)
    }

    /// A cohort of scope `bundle`. One built with no id stores none, as the viewer's save does.
    private func cohort(_ name: String, _ predicate: SmartCohortPredicate, id: UUID? = nil) -> GenotypeCohortSmartFilter {
        var cohort = GenotypeCohortSmartFilter(name: name, scope: "bundle", isStarred: false, predicate: predicate)
        cohort.id = id
        return cohort
    }

    private func writeSidecar(_ cohorts: [GenotypeCohortSmartFilter], to layout: Layout) throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-16T00:00:00Z")
        sidecar.smartCohorts = cohorts
        try sidecar.encoded().write(to: layout.annotationURL)
    }

    private func reread(_ layout: Layout) throws -> GenotypeAnnotationSidecar {
        try GenotypeAnnotationSidecar.decode(Data(contentsOf: layout.annotationURL))
    }
}
