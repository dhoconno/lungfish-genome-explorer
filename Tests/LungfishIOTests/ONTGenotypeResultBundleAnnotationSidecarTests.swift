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

    func testLoadReadsTrustedGenerationLinkedSidecar() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let expected = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-31T12:00:00Z"
        )
        try installTrustedGenerationLinkedSidecar(
            expected.encoded(),
            in: bundle
        )

        let snapshot = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: bundle)

        XCTAssertEqual(snapshot.sidecar, expected)
        XCTAssertEqual(snapshot.data, try expected.encoded())
    }

    func testWriteMigratesTrustedGenerationLinkedSidecarToRegularFile() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let initial = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-31T12:00:00Z"
        )
        let generationURL = try installTrustedGenerationLinkedSidecar(
            initial.encoded(),
            in: bundle
        )
        let snapshot = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: bundle)
        var updated = snapshot.sidecar
        updated.sampleNotes.append(.init(
            sample: "CR1178",
            body: "Manual haplotypes reviewed.",
            author: "analyst",
            timestamp: "2026-07-31T12:01:00Z"
        ))

        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            updated,
            expectedRevision: snapshot.revision,
            forBundleAt: bundle
        )

        let annotationURL = ONTGenotypeResultBundleData
            .annotationSidecarURL(forBundleAt: bundle)
        let values = try annotationURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertEqual(values.isSymbolicLink, false)
        XCTAssertEqual(
            try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(
                forBundleAt: bundle
            ),
            updated
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: generationURL
                    .appendingPathComponent(GenotypeAnnotationSidecar.filename)
                    .path
            ),
            "Migration must preserve the prior generation for traceability."
        )
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

    func testRawRestoreUsesRevisionCASAndAtomicallyRestoresExactPriorBytes() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(
            forBundleAt: bundle
        )
        let initial = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T20:00:00Z"
        )
        let priorObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: initial.encoded())
                as? [String: Any]
        )
        let priorData = try JSONSerialization.data(
            withJSONObject: priorObject,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try priorData.write(to: annotationURL)
        let priorSnapshot =
            try ONTGenotypeResultBundleData.loadAnnotationSidecarSnapshot(
                forBundleAt: bundle
            )
        var replayed = priorSnapshot.sidecar
        replayed.sampleNotes.append(.init(
            sample: "S1",
            body: "replayed edit",
            author: "analyst",
            timestamp: "2026-07-26T20:01:00Z"
        ))
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            replayed,
            expectedRevision: priorSnapshot.revision,
            forBundleAt: bundle
        )
        let replayedSnapshot =
            try ONTGenotypeResultBundleData.loadAnnotationSidecarSnapshot(
                forBundleAt: bundle
            )
        let replayedData = try XCTUnwrap(replayedSnapshot.data)

        let publicationLock = try ONTGenotypeBundlePublicationLock.acquire(
            for: bundle
        )
        var observedExistingReplayAtRenameBoundary = false
        try ONTGenotypeResultBundleData.restoreAnnotationSidecarData(
            priorData,
            expectedRevision: replayedSnapshot.revision,
            forBundleAt: bundle,
            assuming: publicationLock,
            beforeRename: {
                observedExistingReplayAtRenameBoundary =
                    try FileManager.default.fileExists(
                        atPath: annotationURL.path
                    ) && Data(contentsOf: annotationURL) == replayedData
            }
        )
        publicationLock.release()

        XCTAssertTrue(observedExistingReplayAtRenameBoundary)
        XCTAssertEqual(try Data(contentsOf: annotationURL), priorData)
        let reacquired = try ONTGenotypeBundlePublicationLock.acquire(
            for: bundle
        )
        reacquired.release()
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

    @discardableResult
    private func installTrustedGenerationLinkedSidecar(
        _ data: Data,
        in bundle: URL
    ) throws -> URL {
        let annotationRoot = bundle
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("genotype-annotations", isDirectory: true)
        let generationID = "46fc3db4-ea08-483d-9f6c-f67f4e2d6caa"
        let generationURL = annotationRoot
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(generationID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: generationURL,
            withIntermediateDirectories: true
        )
        try data.write(
            to: generationURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            )
        )
        try FileManager.default.createSymbolicLink(
            atPath: annotationRoot.appendingPathComponent("active").path,
            withDestinationPath: "generations/\(generationID)"
        )
        try FileManager.default.createSymbolicLink(
            atPath: ONTGenotypeResultBundleData
                .annotationSidecarURL(forBundleAt: bundle).path,
            withDestinationPath:
                "artifacts/genotype-annotations/active/\(GenotypeAnnotationSidecar.filename)"
        )
        return generationURL
    }
}
