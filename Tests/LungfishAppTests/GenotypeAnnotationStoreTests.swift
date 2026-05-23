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
        let cohort = GenotypeCohortSmartFilter(
            name: "Needs review",
            scope: "bundle",
            isStarred: true,
            predicate: .hasErrorAtAnyLocus
        )
        try store.saveSmartCohort(cohort)
        XCTAssertEqual(store.sidecar.smartCohorts.count, 1)

        // saving with same name+scope replaces
        try store.saveSmartCohort(cohort)
        XCTAssertEqual(store.sidecar.smartCohorts.count, 1)

        try store.deleteSmartCohort(name: "Needs review", scope: "bundle")
        XCTAssertEqual(store.sidecar.smartCohorts.count, 0)
    }
}
