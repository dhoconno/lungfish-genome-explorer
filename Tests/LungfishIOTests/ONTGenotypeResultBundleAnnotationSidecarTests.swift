import XCTest
import LungfishCore
@testable import LungfishIO

final class ONTGenotypeResultBundleAnnotationSidecarTests: XCTestCase {
    func testAnnotationSidecarURLIsPredictable() {
        let bundleURL = URL(fileURLWithPath: "/tmp/test.lungfishgenotype")
        let url = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        XCTAssertEqual(url.lastPathComponent, "annotations.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "test.lungfishgenotype")
    }

    func testLoadOrCreateReturnsEmptyWhenAbsent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: tempDir)
        XCTAssertEqual(sidecar.callOverrides.count, 0)
        XCTAssertEqual(sidecar.schemaVersion, GenotypeAnnotationSidecar.currentSchemaVersion)
    }

    func testLoadOrCreatePersistsAcrossCalls() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshot = try ONTGenotypeResultBundleData.loadAnnotationSidecarSnapshot(
            forBundleAt: tempDir
        )
        var sidecar = snapshot.sidecar
        sidecar.sampleNotes.append(.init(
            sample: "S1", body: "note", author: "u", timestamp: "2026-05-22T00:00:00Z"
        ))
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            expectedRevision: snapshot.revision,
            forBundleAt: tempDir
        )

        let reloaded = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: tempDir)
        XCTAssertEqual(reloaded.sampleNotes.count, 1)
        XCTAssertEqual(reloaded.sampleNotes[0].body, "note")
    }

    func testWriteRejectsStaleV3WhenDiskAdvancedToFutureSchema() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(
            forBundleAt: bundle
        )
        let initial = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T20:00:00Z"
        )
        try initial.encoded().write(to: annotationURL, options: .atomic)
        let snapshot = try ONTGenotypeResultBundleData.loadAnnotationSidecarSnapshot(
            forBundleAt: bundle
        )
        var desired = snapshot.sidecar
        desired.sampleNotes.append(.init(
            sample: "S1",
            body: "stale edit",
            author: "analyst",
            timestamp: "2026-07-26T20:01:00Z"
        ))
        var future = initial
        future.schemaVersion = GenotypeAnnotationSidecar.currentSchemaVersion + 1
        let concurrentData = try future.encoded()
        try concurrentData.write(to: annotationURL, options: .atomic)

        XCTAssertThrowsError(
            try ONTGenotypeResultBundleData.writeAnnotationSidecar(
                desired,
                expectedRevision: snapshot.revision,
                forBundleAt: bundle
            )
        ) { error in
            XCTAssertEqual(
                error as? GenotypeAnnotationSidecar.SchemaMutationError,
                .unsupportedFutureSchemaVersion(
                    found: future.schemaVersion,
                    current: GenotypeAnnotationSidecar.currentSchemaVersion
                )
            )
        }

        XCTAssertEqual(try Data(contentsOf: annotationURL), concurrentData)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: bundle.path),
            [GenotypeAnnotationSidecar.filename]
        )
    }

    func testWriteRejectsStaleV3WhenDiskHasDifferentSupportedRevision() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(
            forBundleAt: bundle
        )
        let initial = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T20:00:00Z"
        )
        try initial.encoded().write(to: annotationURL, options: .atomic)
        let snapshot = try ONTGenotypeResultBundleData.loadAnnotationSidecarSnapshot(
            forBundleAt: bundle
        )
        var desired = snapshot.sidecar
        desired.sampleNotes.append(.init(
            sample: "S1",
            body: "stale edit",
            author: "analyst",
            timestamp: "2026-07-26T20:01:00Z"
        ))
        var concurrent = initial
        concurrent.sampleNotes.append(.init(
            sample: "S2",
            body: "concurrent edit",
            author: "other",
            timestamp: "2026-07-26T20:02:00Z"
        ))
        let concurrentData = try concurrent.encoded()
        try concurrentData.write(to: annotationURL, options: .atomic)
        let concurrentSnapshot =
            try ONTGenotypeResultBundleData.loadAnnotationSidecarSnapshot(
                forBundleAt: bundle
            )

        XCTAssertThrowsError(
            try ONTGenotypeResultBundleData.writeAnnotationSidecar(
                desired,
                expectedRevision: snapshot.revision,
                forBundleAt: bundle
            )
        ) { error in
            XCTAssertEqual(
                error as? GenotypeAnnotationSidecarPublicationError,
                .staleRevision(
                    expected: snapshot.revision,
                    actual: concurrentSnapshot.revision
                )
            )
        }

        XCTAssertEqual(try Data(contentsOf: annotationURL), concurrentData)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: bundle.path),
            [GenotypeAnnotationSidecar.filename]
        )
    }

    private func makeBundle() throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString + ".lungfishgenotype",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: bundle,
            withIntermediateDirectories: true
        )
        return bundle
    }
}
