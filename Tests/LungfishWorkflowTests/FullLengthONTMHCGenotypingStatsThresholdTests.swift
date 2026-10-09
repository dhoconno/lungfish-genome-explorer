import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// Finding SF1 (lane SF1). A full-length ONT MHC run applies haplotype dropout
/// thresholds when it infers haplotypes, and its stats JSON recorded none of
/// them, so every later re-inference of the bundle used thresholds the run did
/// not. The stats now carry the four keys the barcode script records, in its
/// units (percent of reads, overrides as LOCUS=PERCENT), and the resolver reads
/// them back the way it reads a barcode bundle.
final class FullLengthONTMHCGenotypingStatsThresholdTests: XCTestCase {
    func testStatsJSONRecordsTheRunHaplotypeThresholdsInTheBarcodeKeysAndUnits() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = makeRequest(
            root: root,
            sampleFraction: 0.005,
            locusFraction: 0.01,
            overrides: ["MHC-DQ": 0.1, "MHC-DP": 0.025]
        )

        try FullLengthONTMHCGenotypingPipeline().writeStatsJSON(
            request: request,
            sampleSummaries: [],
            genotypeRows: []
        )

        let stats = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: request.statsJSONURL)) as? [String: Any]
        )
        XCTAssertEqual(stats["minSupport"] as? Int, 1)
        XCTAssertEqual(stats["haplotypeMinSamplePercent"] as? Double, 0.5)
        XCTAssertEqual(stats["haplotypeMinLocusPercent"] as? Double, 1)
        XCTAssertEqual(stats["haplotypeMinLocusPercentOverrides"] as? [String], ["MHC-DP=2.5", "MHC-DQ=10"])

        // Read back through the bundle loader the GUI and the CLI share. The
        // resolver reads a floor of one read as no floor, as it does for the
        // barcode stats, and the fractions and overrides are the run's.
        let result = try loadResult(for: request)
        XCTAssertEqual(
            GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: result),
            GenotypeDropoutEvaluator(
                absolute: nil,
                sampleFraction: 0.005,
                locusFraction: 0.01,
                locusFractionOverrides: ["MHC-DQ": 0.1, "MHC-DP": 0.025]
            )
        )
    }

    func testStatsJSONRecordsDisabledThresholdsTheWayTheBarcodeScriptDoes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = makeRequest(root: root, sampleFraction: nil, locusFraction: nil, overrides: [:])
        XCTAssertNil(request.haplotypeDropoutEvaluator)

        try FullLengthONTMHCGenotypingPipeline().writeStatsJSON(
            request: request,
            sampleSummaries: [],
            genotypeRows: []
        )

        let stats = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: request.statsJSONURL)) as? [String: Any]
        )
        XCTAssertEqual(stats["minSupport"] as? Int, 1)
        XCTAssertEqual(stats["haplotypeMinSamplePercent"] as? Double, 0)
        XCTAssertEqual(stats["haplotypeMinLocusPercent"] as? Double, 0)
        XCTAssertEqual(stats["haplotypeMinLocusPercentOverrides"] as? [String], [])
        XCTAssertNil(GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: try loadResult(for: request)))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullLengthStatsThresholds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cohort.lungfishgenotype", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeRequest(
        root: URL,
        sampleFraction: Double?,
        locusFraction: Double?,
        overrides: [String: Double]
    ) -> FullLengthONTMHCGenotypingRunRequest {
        FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [root.appendingPathComponent("reads.fastq")],
            referenceSourceURL: root.appendingPathComponent("reference.lungfishmhcref", isDirectory: true),
            outputDirectory: root.appendingPathComponent("cohort.lungfishgenotype", isDirectory: true),
            outputName: "cohort",
            haplotypeDropoutSampleFraction: sampleFraction,
            haplotypeDropoutLocusFraction: locusFraction,
            haplotypeDropoutLocusFractionOverrides: overrides,
            haplotypeAssayID: "sf1-assay",
            haplotypeDefinitionSetID: "sf1-defs"
        )
    }

    /// Loads the bundle the way `writeHaplotypeAnalysisIfRequested` does, so the
    /// stats reach the resolver through `ONTGenotypeRunStats.load`.
    private func loadResult(for request: FullLengthONTMHCGenotypingRunRequest) throws -> ONTGenotypeResultBundleData {
        try "sample,genotype,passed_alignments,passed_unique_reads\n"
            .write(to: request.reportCSVURL, atomically: true, encoding: .utf8)
        try "sample,passed_alignments,passed_unique_reads\n"
            .write(to: request.sampleSummaryCSVURL, atomically: true, encoding: .utf8)
        let outputDirectory = request.outputDirectory
        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .haplotyped,
            outputName: request.outputName,
            analysisName: request.outputName,
            primaryWorkbookPath: request.workbookURL.lastPathComponent,
            longSummaryCSVPath: request.reportCSVURL.lastPathComponent,
            sampleSummaryCSVPath: request.sampleSummaryCSVURL.lastPathComponent,
            statsJSONPath: request.statsJSONURL.lastPathComponent,
            provenancePath: request.provenanceURL.lastPathComponent,
            haplotypeDefinitionSetID: request.haplotypeDefinitionSetID,
            haplotypeAssayID: request.haplotypeAssayID
        )
        return try ONTGenotypeResultBundle.loadResult(from: outputDirectory, manifest: manifest)
    }
}
