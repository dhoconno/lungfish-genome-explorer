import XCTest

final class ProvenanceFailurePolicySourceTests: XCTestCase {
    private func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        for _ in 0..<10 {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate Package.swift above \(#filePath)")
    }

    func testMetagenomicsPipelinesDoNotSwallowProvenanceSaveFailures() throws {
        let root = try repoRoot()
        let files = [
            "Sources/LungfishApp/App/AppDelegate+Classification.swift",
            "Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift",
            "Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift",
            "Sources/LungfishWorkflow/Metagenomics/MetagenomicsBatchProvenanceWriter.swift",
            "Sources/LungfishWorkflow/Metagenomics/TaxonomyExtractionPipeline.swift",
            "Sources/LungfishWorkflow/TaxTriage/TaxTriageSerialBatchRunner.swift",
            "Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift",
        ]

        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(
                text.contains("Failed to save provenance"),
                "\(file) still treats provenance save failure as a warning"
            )
            XCTAssertFalse(
                text.contains("Failed to save extraction provenance"),
                "\(file) still treats extraction provenance save failure as a warning"
            )
            XCTAssertFalse(
                text.contains(#"logger.warning("Failed to save TaxTriage"#),
                "\(file) still treats TaxTriage provenance/result persistence failure as a warning"
            )
            XCTAssertFalse(
                text.contains("Failed to write root provenance"),
                "\(file) still treats root provenance save failure as a warning"
            )
            XCTAssertFalse(
                text.contains("return try? write"),
                "\(file) still discards provenance writer failures"
            )
            XCTAssertFalse(
                text.contains("try? await ProvenanceRecorder.shared.save"),
                "\(file) still discards provenance recorder save failures"
            )
        }
    }
}
