import XCTest
import LungfishTestSupport

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
            "Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift",
            // The save of a TaxTriage run's own record moved here from TaxTriagePipeline.swift (2.8 B2 M1).
            "Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline+Provenance.swift",
        ]

        for file in files {
            let text = try readRepositorySource(root.appendingPathComponent(file))
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
                text.contains(#"logger.warning("Failed to save result sidecar"#),
                "\(file) still treats result sidecar persistence failure as a warning"
            )
            XCTAssertFalse(
                text.contains(#"logger.warning("runClassification: Failed to save result sidecar"#),
                "\(file) still treats classification result sidecar persistence failure as a warning"
            )
            XCTAssertFalse(
                text.contains(#"logger.warning("runClassificationBatch: Failed to save sidecar"#),
                "\(file) still treats result sidecar persistence failure as a warning"
            )
            XCTAssertFalse(
                text.contains("Failed to write root provenance"),
                "\(file) still treats root provenance save failure as a warning"
            )
            XCTAssertFalse(
                text.contains("try? result.save"),
                "\(file) still discards result sidecar persistence failures"
            )
            XCTAssertFalse(
                text.contains("return try? write"),
                "\(file) still discards provenance writer failures"
            )
            XCTAssertFalse(
                text.contains("try? await ProvenanceRecorder.shared.save"),
                "\(file) still discards provenance recorder save failures"
            )
            XCTAssertFalse(
                text.contains("try? await provenanceRecorder.save"),
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
        // C2-RIBOPIN replaced installDeaconRibokmersDatabase with the pinned download and the sibling clone, which
        // install the hosted ribokmers index and write its receipt.
        let installerMethods = [
            "installChecksummedManagedDatabase",
            "installDeaconManagedDatabase",
            "installPinnedDownloadDatabase",
            "cloneManagedDatabaseFromSibling",
        ]

        for method in installerMethods {
            let source = sourceSlice(in: text, from: "func \(method)(", to: "\n    private func ")
            XCTAssertFalse(source.isEmpty, "\(method) was not found in DatabaseRegistry.swift")
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
