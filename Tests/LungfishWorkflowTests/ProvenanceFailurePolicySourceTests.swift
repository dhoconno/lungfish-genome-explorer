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

    func testManagedDatabaseInstallersWriteSuccessProvenanceAndFailClosed() throws {
        let root = try repoRoot()
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift"),
            encoding: .utf8
        )
        let installerMethods = [
            "installChecksummedManagedDatabase",
            "installDeaconManagedDatabase",
            "installDeaconRibokmersDatabase",
        ]

        for method in installerMethods {
            let source = sourceSlice(in: text, from: "private func \(method)", to: "\n    private func ")
            XCTAssertTrue(
                source.contains("writeManagedDatabaseInstallProvenance("),
                "\(method) must write durable managed database install provenance before reporting success"
            )
            XCTAssertFalse(
                source.contains("try? writeManagedDatabaseInstallProvenance("),
                "\(method) must not discard managed database install provenance write failures"
            )
        }

        XCTAssertFalse(
            text.contains("try? writeDeaconRibokmersInstallProvenance("),
            "Managed database install provenance failures must not be warning-only for any success-capable install path"
        )
    }

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) -> String {
        guard let startRange = source.range(of: startMarker),
              let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex) else {
            return ""
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
