import XCTest
@testable import LungfishWorkflow

final class FASTQBundleCopyImportWorkflowTests: XCTestCase {
    func testImportCopiesIntoHiddenStagingBundleBeforePublishing() throws {
        let source = try String(
            contentsOf: packageRoot()
                .appendingPathComponent("Sources/LungfishWorkflow/Ingestion/FASTQBundleCopyImportWorkflow.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("copyItem(at: sourceBundleURL, to: stagingBundleURL)"))
        XCTAssertTrue(source.contains("moveItem(at: stagingBundleURL, to: destinationBundleURL)"))
        XCTAssertFalse(
            source.contains("copyItem(at: sourceBundleURL, to: destinationBundleURL)"),
            "FASTQ bundle import must not publish a visible destination before provenance is written."
        )
    }

    func testFailedImportCleanupOnlyRemovesOwnedStagingBundle() throws {
        let source = try String(
            contentsOf: packageRoot()
                .appendingPathComponent("Sources/LungfishWorkflow/Ingestion/FASTQBundleCopyImportWorkflow.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("removeItem(at: stagingBundleURL)"))
        XCTAssertFalse(
            source.contains("removeItem(at: destinationBundleURL)"),
            "Failure cleanup must not delete a final destination that another process may have created after the initial collision check."
        )
    }

    func testImportProvenanceUsesFinalBundlePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBundleCopyImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceBundleURL = root.appendingPathComponent("source.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\n!!!!\n".write(
            to: sourceBundleURL.appendingPathComponent("reads.fastq"),
            atomically: true,
            encoding: .utf8
        )

        let destinationBundleURL = root
            .appendingPathComponent("imports", isDirectory: true)
            .appendingPathComponent("copied.lungfishfastq", isDirectory: true)
        let workflow = FASTQBundleCopyImportWorkflow()
        let result = try workflow.importBundle(
            sourceBundleURL: sourceBundleURL,
            outputURL: destinationBundleURL,
            context: FASTQBundleCopyImportWorkflow.CommandContext(
                workflowName: "test fastq bundle import",
                toolName: "lungfish-cli",
                argv: ["lungfish", "fastq", "import-bundle", sourceBundleURL.path]
            )
        )

        XCTAssertEqual(result.bundleURL, destinationBundleURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationBundleURL.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: destinationBundleURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.hasPrefix(".copied.") },
            "Hidden staging bundles must be removed after publication."
        )

        let provenanceURL = destinationBundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: provenanceURL)
        )
        let allPaths = envelope.files.map(\.path) + envelope.outputs.map(\.path)
        XCTAssertTrue(allPaths.contains(destinationBundleURL.path))
        XCTAssertTrue(allPaths.contains(destinationBundleURL.appendingPathComponent("reads.fastq").path))
        XCTAssertFalse(allPaths.contains { $0.contains("/.copied.") || $0.contains(".processing") })
    }

    private func packageRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
