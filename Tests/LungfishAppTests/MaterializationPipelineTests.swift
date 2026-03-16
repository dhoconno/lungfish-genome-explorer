import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class MaterializationPipelineTests: XCTestCase {

    // MARK: - BatchSource

    func testBatchSourceInit() {
        let url = URL(fileURLWithPath: "/project/sample.lungfishfastq")
        let source = BatchSource(bundleURL: url, displayName: "Sample A", readCount: 1000)
        XCTAssertEqual(source.bundleURL, url)
        XCTAssertEqual(source.displayName, "Sample A")
        XCTAssertEqual(source.readCount, 1000)
    }

    func testBatchSourceDefaultReadCount() {
        let url = URL(fileURLWithPath: "/project/sample.lungfishfastq")
        let source = BatchSource(bundleURL: url, displayName: "Sample B")
        XCTAssertEqual(source.readCount, 0)
    }

    // MARK: - MaterializationError

    func testMaterializationErrorDescriptions() {
        let url = URL(fileURLWithPath: "/project/test.lungfishfastq")
        let taskID = UUID()

        let notVirtual = MaterializationError.notVirtual(url)
        XCTAssertTrue(notVirtual.localizedDescription.contains("not virtual"))

        let alreadyMaterializing = MaterializationError.alreadyMaterializing(taskID)
        XCTAssertTrue(alreadyMaterializing.localizedDescription.contains("Already materializing"))

        let notFound = MaterializationError.bundleNotFound(url)
        XCTAssertTrue(notFound.localizedDescription.contains("not found"))

        let failed = MaterializationError.materializationFailed(
            url,
            underlying: NSError(domain: "test", code: 42)
        )
        XCTAssertTrue(failed.localizedDescription.contains("failed"))
    }

    // MARK: - MaterializationProgress

    func testMaterializationProgressSnapshot() {
        let jobID = UUID()
        let url = URL(fileURLWithPath: "/project/test.lungfishfastq")
        let progress = MaterializationProgress(
            jobID: jobID,
            fraction: 0.5,
            message: "Processing...",
            bundleURL: url
        )
        XCTAssertEqual(progress.jobID, jobID)
        XCTAssertEqual(progress.fraction, 0.5)
        XCTAssertEqual(progress.message, "Processing...")
        XCTAssertEqual(progress.bundleURL, url)
    }

    // MARK: - MaterializationResult

    func testMaterializationResultInit() {
        let jobID = UUID()
        let url = URL(fileURLWithPath: "/project/test.lungfishfastq")
        let result = MaterializationResult(
            jobID: jobID,
            bundleURL: url,
            checksum: "abc12345",
            duration: 2.5
        )
        XCTAssertEqual(result.jobID, jobID)
        XCTAssertEqual(result.checksum, "abc12345")
        XCTAssertEqual(result.duration, 2.5, accuracy: 0.001)
    }

    // MARK: - Pipeline Lifecycle

    func testPipelineRejectsBundleNotFound() async throws {
        let pipeline = MaterializationPipeline(maxConcurrency: 1)
        let descriptor = VirtualFASTQDescriptor(
            id: UUID(),
            bundleURL: URL(fileURLWithPath: "/nonexistent/test.lungfishfastq"),
            rootBundleRelativePath: "../parent.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            payload: .subset(readIDListFilename: "ids.txt"),
            lineage: [],
            pairingMode: .singleEnd,
            sequenceFormat: .fastq
        )
        do {
            _ = try await pipeline.materialize(descriptor)
            XCTFail("Expected bundleNotFound error")
        } catch let error as MaterializationError {
            if case .bundleNotFound = error {
                // expected
            } else {
                XCTFail("Expected bundleNotFound, got \(error)")
            }
        }
    }

    func testPipelineActiveJobsStartsEmpty() async {
        let pipeline = MaterializationPipeline(maxConcurrency: 2)
        let ids = await pipeline.activeJobIDs
        XCTAssertTrue(ids.isEmpty)
    }

    func testPipelineRejectsAlreadyMaterialized() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatPipeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("test.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Create a manifest that is already materialized
        let op = FASTQDerivativeOperation(kind: .subsampleCount, count: 100)
        var manifest = FASTQDerivedBundleManifest(
            name: "test",
            parentBundleRelativePath: "../parent.lungfishfastq",
            rootBundleRelativePath: "../parent.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            payload: .subset(readIDListFilename: "ids.txt"),
            lineage: [op],
            operation: op,
            cachedStatistics: .empty,
            pairingMode: .singleEnd,
            materializationState: .materialized(checksum: "abc123")
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)

        let pipeline = MaterializationPipeline(maxConcurrency: 1)
        let descriptor = VirtualFASTQDescriptor(bundleURL: bundleURL, manifest: manifest)
        do {
            _ = try await pipeline.materialize(descriptor)
            XCTFail("Expected notVirtual error")
        } catch let error as MaterializationError {
            if case .notVirtual = error {
                // expected
            } else {
                XCTFail("Expected notVirtual, got \(error)")
            }
        }
    }
}
