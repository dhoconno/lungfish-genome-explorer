import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishApp

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

        // In-memory operations on a read-only store don't throw — they
        // mutate the in-memory copy and skip persist().
        try store.applyOverride(
            sample: "H1", locus: "MHC-A", slot: .h1,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .contamination, rationale: ""
        )
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarPath),
                       "Read-only store should not have persisted to disk")
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
}
