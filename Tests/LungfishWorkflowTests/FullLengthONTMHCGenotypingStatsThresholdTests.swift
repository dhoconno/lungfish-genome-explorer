import Foundation
import XCTest
import LungfishCore
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

    /// 6.6 and 3.33 percent are two of the 139 two-decimal percents that came
    /// back one ulp off when the stats wrote `fraction * 100` and the loader
    /// read the number back as text. The stats path and the argv path must both
    /// recover the run's fractions bit for bit, so a cell sitting exactly on the
    /// threshold, 33 of 500 locus reads at 6.6 percent, is kept on both as the
    /// run kept it.
    func testAwkwardPercentsRecoverTheRunFractionsBitForBitOnBothPaths() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The CLI parses "3.33" and "6.6" as Double and divides by 100.
        let request = makeRequest(root: root, sampleFraction: 3.33 / 100, locusFraction: 6.6 / 100, overrides: [:])
        let run = try XCTUnwrap(request.haplotypeDropoutEvaluator)
        try publishBundle(for: request, calls: [])

        let fromStats = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(
            for: try ONTGenotypeResultBundle.loadResult(from: request.outputDirectory)
        ))
        XCTAssertEqual(fromStats.sampleFraction?.bitPattern, run.sampleFraction?.bitPattern)
        XCTAssertEqual(fromStats.locusFraction?.bitPattern, run.locusFraction?.bitPattern)

        // The same bundle as a run before SF1 left it, with no threshold key in
        // its stats, is read from the argv its provenance recorded.
        try Data("{}".utf8).write(to: request.statsJSONURL)
        let fromArgv = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(
            for: try ONTGenotypeResultBundle.loadResult(from: request.outputDirectory)
        ))
        XCTAssertEqual(fromArgv, run)
        XCTAssertEqual(fromArgv.sampleFraction?.bitPattern, run.sampleFraction?.bitPattern)
        XCTAssertEqual(fromArgv.locusFraction?.bitPattern, run.locusFraction?.bitPattern)

        for (name, evaluator) in [("run", run), ("stats", fromStats), ("argv", fromArgv)] {
            XCTAssertFalse(
                evaluator.isLowSupport(reads: 33, sampleTotal: 500, locusTotal: 500, locus: "MHC-A"),
                "\(name) must keep 33 of 500 reads at 6.6 percent"
            )
        }
        // One ulp above the run's fraction, what the old encoding recovered,
        // drops that cell.
        let oneUlpUp = GenotypeDropoutEvaluator(absolute: nil, sampleFraction: nil, locusFraction: run.locusFraction?.nextUp)
        XCTAssertTrue(oneUlpUp.isLowSupport(reads: 33, sampleTotal: 500, locusTotal: 500, locus: "MHC-A"))
    }

    /// A bundle the GUI makes, end to end. The dialog's request (its default is
    /// 1 percent of the locus once a definition is chosen) becomes the CLI
    /// arguments the app launches, the CLI parses the percent back into a
    /// fraction, the pipeline writes the stats and the provenance envelope, the
    /// published bundle loads, and the resolver recovers the run's threshold on
    /// the stats path and on the argv path. The dialog and the argument parser
    /// live in LungfishApp and LungfishCLI, which this target cannot import, so
    /// their two arithmetic steps are spelled out here as they are written there
    /// (`WorkflowOperationDialogState.fraction(fromPercent:)` and
    /// `FastqGenotypingSubcommand.fraction(fromPercent:)`, both `min(percent, 100) / 100`).
    func testGUIMadeBundleRecoversTheDialogThresholdOnBothPaths() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dialogLocusPercent = 1.0
        let dialogRequest = makeRequest(
            root: root, sampleFraction: nil, locusFraction: min(dialogLocusPercent, 100.0) / 100.0, overrides: [:]
        )

        // WorkflowOperationExecutionService launches the request's argv without
        // the executable name, its thresholds through appendHaplotypeThresholdArguments.
        let arguments = Array(dialogRequest.argv.dropFirst())
        let flagIndex = try XCTUnwrap(arguments.firstIndex(of: "--haplotype-min-locus-percent"))
        XCTAssertEqual(arguments[flagIndex + 1], "1")
        XCTAssertFalse(arguments.contains("--haplotype-min-sample-percent"))
        XCTAssertFalse(arguments.contains("--haplotype-min-locus-percent-override"))

        // The CLI parses the Double and builds the request the pipeline runs.
        let parsedPercent = try XCTUnwrap(Double(arguments[flagIndex + 1]))
        let cliRequest = makeRequest(root: root, sampleFraction: nil, locusFraction: min(parsedPercent, 100) / 100, overrides: [:])
        XCTAssertEqual(cliRequest.haplotypeDropoutEvaluator, dialogRequest.haplotypeDropoutEvaluator)
        let run = try XCTUnwrap(cliRequest.haplotypeDropoutEvaluator)

        try publishBundle(for: cliRequest, calls: [("A_marker", 100), ("B_marker", 2), ("C_marker", 1)])
        let published = try ONTGenotypeResultBundle.loadResult(from: cliRequest.outputDirectory)
        XCTAssertEqual(published.stats.rawMetrics["haplotypeMinLocusPercent"], "1")
        let fromStats = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: published))
        XCTAssertEqual(fromStats.locusFraction?.bitPattern, run.locusFraction?.bitPattern)
        XCTAssertNil(fromStats.sampleFraction)
        XCTAssertEqual(fromStats.locusFractionOverrides, [:])
        // One read of C_marker is 0.97 percent of the locus, below the run's 1
        // percent, so the published bundle re-infers the run's M-A and M-B.
        let analysis = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.activeAnalysis(for: published, sidecar: nil))
        let call = try XCTUnwrap(analysis.samples.first?.calls.first)
        XCTAssertEqual([call.haplotype1, call.haplotype2], ["M-A", "M-B"])

        // The same bundle as a run before SF1 left it, without the threshold
        // keys, recovers the dialog's threshold from the envelope the real
        // writer wrote.
        try Data("{}".utf8).write(to: cliRequest.statsJSONURL)
        let beforeSF1 = try ONTGenotypeResultBundle.loadResult(from: cliRequest.outputDirectory)
        XCTAssertEqual(GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: beforeSF1), run)
        XCTAssertEqual(GenotypeHaplotypeAnalysisResolver.activeAnalysis(for: beforeSF1, sidecar: nil), analysis)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullLengthStatsThresholds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Project.lungfish/Analyses/Run/cohort.lungfishgenotype", isDirectory: true),
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
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        return FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [project.appendingPathComponent("Imports/reads.lungfishfastq/reads.fastq")],
            referenceSourceURL: project.appendingPathComponent("Reference allele databases/cohort.lungfishmhcref", isDirectory: true),
            outputDirectory: project.appendingPathComponent("Analyses/Run/cohort.lungfishgenotype", isDirectory: true),
            outputName: "cohort",
            projectURL: project,
            haplotypeDropoutSampleFraction: sampleFraction,
            haplotypeDropoutLocusFraction: locusFraction,
            haplotypeDropoutLocusFractionOverrides: overrides,
            haplotypeAssayID: "sf1-assay",
            haplotypeDefinitionSetID: "sf1-defs"
        )
    }

    private func definition() -> GenotypeHaplotypeDefinitionSet {
        .init(id: "sf1-defs", assayID: "sf1-assay", displayName: "SF1 definitions", speciesName: "Test species",
              speciesCode: "TST", prefix: "Test", locusDefinitions: [
                .init(locus: "MHC-A", sourceLocus: "MHC-A", haplotypes: [
                    .init(name: "M-A", diagnosticAlleles: ["A_marker"]),
                    .init(name: "M-B", diagnosticAlleles: ["B_marker"]),
                    .init(name: "M-C", diagnosticAlleles: ["C_marker"]),
                ]),
              ])
    }

    private func manifest(for request: FullLengthONTMHCGenotypingRunRequest) -> ONTGenotypeResultBundleManifest {
        ONTGenotypeResultBundleManifest(
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
    }

    /// Loads the bundle the way `writeHaplotypeAnalysisIfRequested` does, so the
    /// stats reach the resolver through `ONTGenotypeRunStats.load`.
    private func loadResult(for request: FullLengthONTMHCGenotypingRunRequest) throws -> ONTGenotypeResultBundleData {
        try writeCalls([], for: request)
        return try ONTGenotypeResultBundle.loadResult(from: request.outputDirectory, manifest: manifest(for: request))
    }

    private func writeCalls(_ calls: [(marker: String, reads: Int)], for request: FullLengthONTMHCGenotypingRunRequest) throws {
        let rows = calls.map { "sample,\($0.marker)|source_loci=MHC-A|haplotype_groups=MHC-A,\($0.reads),\($0.reads)" }
        try (["sample,genotype,passed_alignments,passed_unique_reads"] + rows).joined(separator: "\n")
            .appending("\n")
            .write(to: request.reportCSVURL, atomically: true, encoding: .utf8)
        try "sample,passed_alignments,passed_unique_reads\n"
            .write(to: request.sampleSummaryCSVURL, atomically: true, encoding: .utf8)
    }

    /// Publishes what a run leaves behind that the resolver reads. The stats go
    /// through the real writer, the provenance envelope through the real
    /// ProvenanceRunBuilder and ProvenanceWriter with the run's argv, plus the
    /// retained definition snapshot, the calls and the manifest.
    private func publishBundle(
        for request: FullLengthONTMHCGenotypingRunRequest,
        calls: [(marker: String, reads: Int)]
    ) throws {
        try FullLengthONTMHCGenotypingPipeline().writeStatsJSON(request: request, sampleSummaries: [], genotypeRows: [])
        try writeCalls(calls, for: request)
        let snapshotURL = GenotypeHaplotypeAnalysisResolver.retainedDefinitionSnapshotURL(for: request.outputDirectory)
        try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(definition()).write(to: snapshotURL)
        let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let envelope = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq full-length-ont-mhc-genotype",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish-cli",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(request.argv)
        .durableReplayArgv(request.argv)
        .runtime(ProvenanceRuntimeIdentity())
        .output(request.statsJSONURL, format: .json, role: .report)
        .complete(exitStatus: 0, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60))
        _ = try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: request.provenanceURL)
        try ONTGenotypeResultBundle.writeManifest(manifest(for: request), to: request.outputDirectory)
    }
}
