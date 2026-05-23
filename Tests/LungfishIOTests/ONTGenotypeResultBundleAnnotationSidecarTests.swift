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

        var sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: tempDir)
        sidecar.sampleNotes.append(.init(
            sample: "S1", body: "note", author: "u", timestamp: "2026-05-22T00:00:00Z"
        ))
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: tempDir)

        let reloaded = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: tempDir)
        XCTAssertEqual(reloaded.sampleNotes.count, 1)
        XCTAssertEqual(reloaded.sampleNotes[0].body, "note")
    }
}
