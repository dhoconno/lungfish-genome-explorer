import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishWorkflow

@MainActor
final class GenotypeSampleMetadataImportTests: XCTestCase {
    func testImportPersistsGenotypeMetadataAndProvenanceWithFinalBundlePayload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSampleMetadataImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundleURL = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent("genotype-result.json"))

        let sourceURL = root.appendingPathComponent("metadata.tsv")
        let metadata = Data("""
        Sample\tCohort\tAnimal
        AnimalA\ttreated\tmacaque
        """.utf8)
        try metadata.write(to: sourceURL)
        let knownSampleIds: Set<String> = ["AnimalA"]
        let scanResult = try SampleMetadataStore.scanForSampleColumn(
            csvData: metadata,
            knownSampleIds: knownSampleIds
        )
        let bestColumn = try XCTUnwrap(scanResult.bestColumn)

        let result = try SampleMetadataBundleImportService().importMetadata(
            data: metadata,
            sourceURL: sourceURL,
            scanResult: scanResult,
            sampleColumnIndex: bestColumn.index,
            knownSampleIds: knownSampleIds,
            bundleURL: bundleURL
        )

        let finalMetadataURL = bundleURL.appendingPathComponent("metadata/sample_metadata.tsv")
        XCTAssertEqual(result.store.records["AnimalA"]?["Cohort"], "treated")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalMetadataURL.path))
        let provenanceURL = try XCTUnwrap(result.provenanceURL)
        XCTAssertEqual(provenanceURL, bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        let provenance = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(provenance.workflowName, "Sample metadata import")
        XCTAssertTrue(provenance.files.contains(where: { $0.path == sourceURL.path && $0.role == .input }))
        XCTAssertTrue(provenance.outputs.contains(where: { $0.path == finalMetadataURL.path && $0.role == .output }))
    }

    func testInspectorMetadataImportUsesGenotypeContextAndRefreshesViewportCallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSampleMetadataImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundleURL = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent("genotype-result.json"))
        let sourceURL = root.appendingPathComponent("metadata.tsv")
        try """
        Sample\tCohort
        AnimalA\ttreated
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let inspector = InspectorViewController()
        _ = inspector.view
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        inspector.updateGenotypeResultDocument(makeResult(bundleURL: bundleURL, calls: [call]))

        var callbackStore: SampleMetadataStore?
        inspector.onGenotypeSampleMetadataImported = { store in
            callbackStore = store
        }

        try inspector.testingImportMetadata(from: sourceURL)

        let documentStore = inspector.viewModel.documentSectionViewModel
            .genotypeResultDocument?
            .sampleMetadataStore
        XCTAssertEqual(documentStore?.records["AnimalA"]?["Cohort"], "treated")
        XCTAssertEqual(callbackStore?.records["AnimalA"]?["Cohort"], "treated")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("metadata/sample_metadata.tsv").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename).path
        ))
    }

    private func makeResult(
        bundleURL: URL,
        calls: [ONTGenotypeCall]
    ) -> ONTGenotypeResultBundleData {
        ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "barcode05-mhc",
                analysisName: "barcode05-mhc",
                primaryWorkbookPath: "barcode05-mhc.xlsx",
                longSummaryCSVPath: "barcode05-mhc.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "barcode05-mhc.retained-demux-samples.csv",
                statsJSONPath: "barcode05-mhc.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: bundleURL.appendingPathComponent("barcode05-mhc.xlsx"),
                longSummaryCSVURL: bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-samples.csv"),
                statsJSONURL: bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-stats.json"),
                provenanceURL: bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 60),
            calls: calls,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 42,
                    passedUniqueReads: 42,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            ]
        )
    }
}
