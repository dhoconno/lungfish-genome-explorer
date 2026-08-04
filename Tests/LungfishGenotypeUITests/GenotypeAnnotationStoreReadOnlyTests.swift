import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeAnnotationStoreReadOnlyTests: XCTestCase {
    func testReadOnlyVolumeSuppressesPersistAndSeeding() throws {
        // Construct a directory we then make read-only via chmod, exercising
        // the same code path a mounted-share bundle would hit.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: dir.path
        )

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        XCTAssertTrue(store.isReadOnly, "Store should detect read-only directory")
        // Seeding skipped — no default cohorts should be written to disk
        // (the on-disk sidecar simply does not exist).
        let sidecarPath = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarPath),
                       "Read-only volume should not have a freshly-created sidecar")

        let before = store.sidecar
        XCTAssertThrowsError(try store.applyOverride(
            sample: "H1", locus: "MHC-A", slot: .h1,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .crossContamination, rationale: ""
        )) { error in
            XCTAssertEqual(error as? CallOverrideMutationError, .readOnly)
        }
        XCTAssertEqual(store.sidecar, before)
        XCTAssertEqual(store.callOverrideMutationRevision, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarPath),
                       "Read-only store should not have persisted to disk")
    }

    func testCallOverrideBatchRejectsReadOnlyBeforeObservableMutation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: dir.path
            )
            try? FileManager.default.removeItem(at: dir)
        }
        try Data("{}".utf8).write(
            to: dir.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let annotationURL = dir.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(
            for: annotationURL
        )
        let annotationBefore = try Data(contentsOf: annotationURL)
        let provenanceBefore = try Data(contentsOf: provenanceURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: dir.path
        )
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "Read-only Analyst"
        )
        let memoryBefore = store.sidecar

        XCTAssertThrowsError(try store.mutateCallOverrides(
            [
                .init(
                    target: .init(
                        sample: "Animal-1",
                        locus: "MHC-A",
                        slot: .h1
                    ),
                    baseline: "M1A",
                    after: "M2A",
                    reason: .misCall,
                    rationale: "Reviewed reads"
                ),
            ],
            author: "Read-only Analyst",
            analysisIdentity: .init(
                assayID: "MHC-exon2-miSeq",
                analysisRevisionID: "revision-7",
                definitionSetID: "definition-2"
            )
        )) { error in
            XCTAssertEqual(error as? CallOverrideMutationError, .readOnly)
        }
        XCTAssertEqual(store.sidecar, memoryBefore)
        XCTAssertEqual(store.callOverrideMutationRevision, 0)
        XCTAssertEqual(try Data(contentsOf: annotationURL), annotationBefore)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), provenanceBefore)
    }

    func testWritableVolumeAllowsPersistAndSeeding() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        XCTAssertFalse(store.isReadOnly)
        XCTAssertGreaterThanOrEqual(store.sidecar.smartCohorts.count, 3,
                                    "Writable bundle should auto-seed default cohorts")
        // Persist happens implicitly during seeding.
        let sidecarPath = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarPath))
    }

    func testManualHaplotypeReplacementRejectsReadOnlyWithoutMutation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: dir.path
            )
            try? FileManager.default.removeItem(at: dir)
        }
        try Data("{}".utf8).write(
            to: dir.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let annotationURL = dir.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let beforeAnnotation = try Data(contentsOf: annotationURL)
        let beforeProvenance = try Data(contentsOf: provenanceURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: dir.path
        )
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "Read-only Analyst"
        )

        XCTAssertThrowsError(try store.replaceManualHaplotypeAssignments(
            for: "Animal-1",
            with: [
                ManualHaplotypeAssignment(
                    sample: "Animal-1",
                    locus: "MHC-A",
                    slot: .h1,
                    label: "Manual-A",
                    colorTokenIndex: 2,
                    diagnosticAlleles: [],
                    notes: ""
                ),
            ],
            copySource: nil,
            author: nil
        )) {
            XCTAssertEqual(
                $0 as? ManualHaplotypeReplacementError,
                .readOnly
            )
        }
        XCTAssertEqual(try Data(contentsOf: annotationURL), beforeAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), beforeProvenance)
        XCTAssertEqual(store.manualHaplotypeAssignmentMutationRevision, 0)
    }
}
