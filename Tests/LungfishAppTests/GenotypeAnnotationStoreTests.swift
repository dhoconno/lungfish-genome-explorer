import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishApp

@MainActor
final class GenotypeAnnotationStoreTests: XCTestCase {
    private func makeBundleURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testLoadEmptyAndAppendOverride() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        XCTAssertEqual(store.sidecar.callOverrides.count, 0)

        try store.applyOverride(
            sample: "H22C112", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .contamination, rationale: "Adjacent contamination"
        )
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        XCTAssertEqual(store.sidecar.auditLog.count, 1)
        XCTAssertEqual(store.sidecar.auditLog[0].action, "override")

        let reloaded = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        XCTAssertEqual(reloaded.sidecar.callOverrides.count, 1)
    }

    func testApplyOverrideTwiceReplacesSameCellEntry() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.applyOverride(
            sample: "H1", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .contamination, rationale: "first"
        )
        try store.applyOverride(
            sample: "H1", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "M3A",
            reasonTag: .misCall, rationale: "second"
        )
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        XCTAssertEqual(store.sidecar.callOverrides[0].overrideCall, "M3A")
        XCTAssertEqual(store.sidecar.auditLog.count, 2)
    }

    func testUndoOverride() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.applyOverride(
            sample: "H22C112", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .contamination, rationale: ""
        )
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        try store.undoLastOverride()
        XCTAssertEqual(store.sidecar.callOverrides.count, 0)
        XCTAssertEqual(store.sidecar.auditLog.count, 2)
        XCTAssertEqual(store.sidecar.auditLog[1].action, "undoOverride")
    }

    func testSetSampleStatusOverrideExistingValue() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.setSampleStatus(.needsReview, sample: "H1")
        try store.setSampleStatus(.reviewed, sample: "H1")
        XCTAssertEqual(store.sidecar.sampleStatusFlags.count, 1)
        XCTAssertEqual(store.sidecar.sampleStatusFlags[0].value, .reviewed)
    }

    func testHighlightAndComment() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.setCellHighlight(
            sample: "H1", locus: "MHC-A", slot: .h1,
            fillHex: "#FFEB3B", borderHex: nil
        )
        XCTAssertEqual(store.sidecar.cellHighlights.count, 1)

        try store.setCellHighlight(
            sample: "H1", locus: "MHC-A", slot: .h1,
            fillHex: nil, borderHex: nil
        )
        XCTAssertEqual(store.sidecar.cellHighlights.count, 0)

        try store.addCellComment(
            sample: "H1", locus: "MHC-A", slot: .h1, body: "needs review"
        )
        XCTAssertEqual(store.sidecar.cellComments.count, 1)
    }

    func testSmartCohortPersistence() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        // GenotypeAnnotationStore seeds three default cohorts on first open
        // (Needs review, Homozygous, Recombinants). Saving an analyst cohort
        // with a colliding name replaces the seeded one; deleting it does
        // not remove the others.
        let initialCount = store.sidecar.smartCohorts.count
        XCTAssertGreaterThanOrEqual(initialCount, 3)

        let customCohort = GenotypeCohortSmartFilter(
            name: "Analyst custom",
            scope: "bundle",
            isStarred: true,
            predicate: .hasErrorAtAnyLocus
        )
        try store.saveSmartCohort(customCohort)
        XCTAssertEqual(store.sidecar.smartCohorts.count, initialCount + 1)

        // saving with same name+scope replaces
        try store.saveSmartCohort(customCohort)
        XCTAssertEqual(store.sidecar.smartCohorts.count, initialCount + 1)

        try store.deleteSmartCohort(name: "Analyst custom", scope: "bundle")
        XCTAssertEqual(store.sidecar.smartCohorts.count, initialCount)
    }

    func testDefaultCohortsSeededOnFirstOpen() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let names = Set(store.sidecar.smartCohorts.map(\.name))
        XCTAssertTrue(names.contains("Needs review"))
        XCTAssertTrue(names.contains("Homozygous"))
        XCTAssertTrue(names.contains("Recombinants"))
    }

    func testDefaultCohortsDoNotOverwriteAnalystCustomVersion() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First open: seed.
        let initial = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let customNeedsReview = GenotypeCohortSmartFilter(
            name: "Needs review",
            description: "Custom analyst predicate.",
            scope: "bundle",
            isStarred: true,
            predicate: .commentContains("escalate")
        )
        try initial.saveSmartCohort(customNeedsReview)

        // Reopen: should not re-seed Needs review now that one exists.
        let reopened = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let needsReview = reopened.sidecar.smartCohorts.first { $0.name == "Needs review" }
        XCTAssertEqual(needsReview?.description, "Custom analyst predicate.")
    }
}
