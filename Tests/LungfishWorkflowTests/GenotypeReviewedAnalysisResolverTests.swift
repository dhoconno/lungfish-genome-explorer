import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class GenotypeReviewedAnalysisResolverTests: XCTestCase {
    func testRunThresholdMetricsArePercentagesIncludingValuesAtOrBelowOne() throws {
        let fixture = try makeFixture(metrics: [
            "minSupport": "5", "haplotypeMinSamplePercent": "0.5", "haplotypeMinLocusPercent": "1",
            "haplotypeMinLocusPercentOverrides": "[\"MHC-DQB=0.1\",\"MHC-DQA=2\"]",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evaluator = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: fixture.result))
        XCTAssertEqual(evaluator.absolute, 5)
        XCTAssertEqual(evaluator.sampleFraction, 0.005)
        XCTAssertEqual(evaluator.locusFraction, 0.01)
        XCTAssertEqual(evaluator.locusFractionOverrides["MHC-DQB"], 0.001)
        XCTAssertEqual(evaluator.locusFractionOverrides["MHC-DQA"], 0.02)
    }

    func testRunThresholdDictionaryAndLegacyListOverridesUseSameUnits() throws {
        for value in [#"{"MHC-DQB":1}"#, "MHC-DQB=1"] {
            let fixture = try makeFixture(metrics: ["haplotypeMinLocusPercentOverrides": value])
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let evaluator = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: fixture.result))
            XCTAssertEqual(evaluator.locusFractionOverrides["MHC-DQB"], 0.01)
        }
    }

    func testDefinitionProvenanceDoesNotChooseWrongAssayStoreFileOverConsumedSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wrong = definition(assay: "other-assay")
        let store = HaplotypeDefinitionStore(projectRoot: fixture.project)
        try store.save(wrong)
        let snapshot = fixture.result.bundleURL.appendingPathComponent(".amplicon-genotyping/inputs/haplotype-definition.json")
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(definition()).write(to: snapshot)

        XCTAssertEqual(GenotypeHaplotypeAnalysisResolver.activeDefinitionSet(for: fixture.result, sidecar: nil), definition())
        XCTAssertEqual(GenotypeHaplotypeAnalysisResolver.activeDefinitionFileURL(for: fixture.result, sidecar: nil), snapshot)
    }

    func testRecordedReferenceRecoveryRebasesCopiedProjectAndAttestsConsumedDefinition() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reference = fixture.project.appendingPathComponent("Reference allele databases/cohort.lungfishmhcref")
        let definitionURL = reference.appendingPathComponent("haplotypes/definition.json")
        try FileManager.default.createDirectory(at: definitionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(definition()).write(to: definitionURL)
        let referenceManifest = MHCAmpliconReferenceBundleManifest(
            name: "Recorded cohort reference", referenceFastaPath: "reference.fasta",
            haplotypeDefinitionPaths: ["haplotypes/definition.json"], defaultHaplotypeDefinitionID: "review-defs",
            metrics: .init(referenceCount: 1, haplotypeDefinitionCount: 1), createdAt: "2026-09-11T00:00:00Z"
        )
        try JSONEncoder().encode(referenceManifest).write(to: reference.appendingPathComponent("mhc-reference.json"))
        let provenance: [String: Any] = ["argv": ["lungfish-cli", "--reference", "/old/location/Project.lungfish/Reference allele databases/cohort.lungfishmhcref"]]
        try JSONSerialization.data(withJSONObject: provenance).write(to: fixture.result.artifacts.provenanceURL)

        XCTAssertEqual(GenotypeHaplotypeAnalysisResolver.activeDefinitionSet(for: fixture.result, sidecar: nil), definition())
        XCTAssertEqual(GenotypeHaplotypeAnalysisResolver.activeDefinitionFileURL(for: fixture.result, sidecar: nil), definitionURL)
        let active = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.activeAnalysis(for: fixture.result, sidecar: nil))
        XCTAssertEqual(active.samples.first?.calls.first?.haplotype1, "M4DQ")
    }

    private func definition(assay: String = "review-assay") -> GenotypeHaplotypeDefinitionSet {
        .init(id: "review-defs", assayID: assay, displayName: "Review definitions", speciesName: "MCM",
              speciesCode: "MCM", prefix: "Mafa", locusDefinitions: [
                .init(locus: "MHC-DQ", sourceLocus: "MHC-DQ", haplotypes: [
                    .init(name: "M4DQ", diagnosticAlleles: ["M4_marker"]),
                ]),
              ])
    }

    private func makeFixture(metrics: [String: String] = ["minSupport": "1"]) throws -> (root: URL, project: URL, result: ONTGenotypeResultBundleData) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewedResolver-\(UUID().uuidString)")
        let project = root.appendingPathComponent("Project.lungfish")
        let bundle = project.appendingPathComponent("Analyses/Run/cohort.lungfishgenotype")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "cohort", analysisName: "Cohort", primaryWorkbookPath: "cohort.xlsx",
            longSummaryCSVPath: "long.csv", sampleSummaryCSVPath: "samples.csv", statsJSONPath: "stats.json",
            provenancePath: "provenance.json", haplotypeDefinitionSetID: "review-defs", haplotypeAssayID: "review-assay",
            createdAt: "2026-09-11T00:00:00Z"
        )
        let result = ONTGenotypeResultBundleData(
            bundleURL: bundle, manifest: manifest,
            artifacts: .init(workbookURL: bundle.appendingPathComponent("cohort.xlsx"),
                             longSummaryCSVURL: bundle.appendingPathComponent("long.csv"),
                             sampleSummaryCSVURL: bundle.appendingPathComponent("samples.csv"),
                             statsJSONURL: bundle.appendingPathComponent("stats.json"),
                             provenanceURL: bundle.appendingPathComponent("provenance.json"), haplotypeAnalysisURL: nil),
            stats: .init(rawMetrics: metrics),
            calls: [.init(sample: "sample", genotype: "M4_marker|source_loci=MHC-DQB1|haplotype_groups=MHC-DQ",
                          passedAlignments: 54, passedUniqueReads: 54, sampleTotalReads: nil,
                          sampleUniqueRetainedReads: nil, sampleUniqueRetainedPercent: nil, overallInputReads: nil,
                          overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil)],
            samples: [], haplotypeAnalysis: nil
        )
        return (root, project, result)
    }

    // MARK: Finding SF1, the thresholds a re-inference uses

    func testRunEvaluatorIsRecoveredFromTheRecordedArgvWhenStatsRecordNoThresholds() throws {
        let fixture = try makeFullLengthFixture(
            metrics: [:], sampleFraction: 0.005, locusFraction: 0.01, overrides: ["MHC-DQ": 0.1]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let evaluator = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: fixture.result))
        XCTAssertEqual(evaluator, fixture.request.haplotypeDropoutEvaluator)
        XCTAssertEqual(evaluator.absolute, 1)
        XCTAssertEqual(evaluator.sampleFraction, 0.005)
        XCTAssertEqual(evaluator.locusFraction, 0.01)
        XCTAssertEqual(evaluator.locusFractionOverrides, ["MHC-DQ": 0.1])
    }

    func testRunEvaluatorIsNilWhenNeitherStatsNorRecordedArgvCarryThresholds() throws {
        let unfiltered = try makeFullLengthFixture(metrics: [:])
        defer { try? FileManager.default.removeItem(at: unfiltered.root) }
        XCTAssertNil(unfiltered.request.haplotypeDropoutEvaluator)
        XCTAssertFalse(unfiltered.request.argv.contains { $0.hasPrefix("--haplotype-min-") })
        XCTAssertNil(GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: unfiltered.result))

        let unrecorded = try makeFullLengthFixture(metrics: [:], locusFraction: 0.01, recordsProvenance: false)
        defer { try? FileManager.default.removeItem(at: unrecorded.root) }
        XCTAssertNil(GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: unrecorded.result))
    }

    func testRecordedStatsThresholdsDecideTheEvaluatorBeforeTheRecordedArgv() throws {
        let recorded = try makeFullLengthFixture(
            metrics: [
                "minSupport": "1", "haplotypeMinSamplePercent": "0", "haplotypeMinLocusPercent": "2",
                "haplotypeMinLocusPercentOverrides": "[]",
            ],
            locusFraction: 0.01
        )
        defer { try? FileManager.default.removeItem(at: recorded.root) }
        XCTAssertEqual(
            GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: recorded.result),
            GenotypeDropoutEvaluator(absolute: nil, sampleFraction: nil, locusFraction: 0.02)
        )

        let disabled = try makeFullLengthFixture(
            metrics: [
                "minSupport": "1", "haplotypeMinSamplePercent": "0", "haplotypeMinLocusPercent": "0",
                "haplotypeMinLocusPercentOverrides": "[]",
            ],
            locusFraction: 0.01
        )
        defer { try? FileManager.default.removeItem(at: disabled.root) }
        XCTAssertNil(GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: disabled.result))
    }

    func testCLIAndGUIReinferenceAgreeOnTheRunThresholdsWhenStatsRecordNone() throws {
        let fixture = try makeFullLengthFixture(metrics: [:], locusFraction: 0.01)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // The CLI exports resolve the definition from the bundle and pass its
        // sidecar, or an empty one, whose Settings.default used to supply a
        // floor of 50 reads that no run chose.
        let cli = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.activeAnalysis(for: fixture.result, sidecar: nil))
        let export = try XCTUnwrap(GenotypeHaplotypeAnalysisResolver.activeAnalysis(
            for: fixture.result, sidecar: .empty(generatedAt: "2026-10-09T00:00:00Z"), definitionSet: sf1Definition()
        ))
        // The GUI's live re-inference (recomputeLiveHaplotypeAnalysis).
        let gui = GenotypeHaplotypeAnalyzer.analyze(
            calls: fixture.result.calls, definitionSet: sf1Definition(), generatedAt: nil,
            dropoutFilter: GenotypeHaplotypeAnalysisResolver.runHaplotypeDropoutEvaluator(for: fixture.result),
            matrixReviews: [], locusDenominator: GenotypeLocusDenominator(result: fixture.result)
        )

        // One read of C_marker is 0.97 percent of the 103 reads at the locus,
        // below the run's 1 percent, so the run called M-A and M-B. With no
        // threshold the three markers are too many haplotypes, and under the
        // sidecar default's 50 read floor the two reads of B_marker drop too.
        let call = try XCTUnwrap(cli.samples.first?.calls.first)
        XCTAssertEqual([call.haplotype1, call.haplotype2], ["M-A", "M-B"])
        XCTAssertEqual(call.status, .called)
        XCTAssertEqual(export, cli)
        XCTAssertEqual(gui, cli)
    }

    private struct FullLengthFixture {
        let root: URL
        let result: ONTGenotypeResultBundleData
        let request: FullLengthONTMHCGenotypingRunRequest
    }

    private func sf1Definition() -> GenotypeHaplotypeDefinitionSet {
        .init(id: "sf1-defs", assayID: "sf1-assay", displayName: "SF1 definitions", speciesName: "Test species",
              speciesCode: "TST", prefix: "Test", locusDefinitions: [
                .init(locus: "MHC-A", sourceLocus: "MHC-A", haplotypes: [
                    .init(name: "M-A", diagnosticAlleles: ["A_marker"]),
                    .init(name: "M-B", diagnosticAlleles: ["B_marker"]),
                    .init(name: "M-C", diagnosticAlleles: ["C_marker"]),
                ]),
              ])
    }

    /// A full-length ONT MHC bundle under Project.lungfish/Analyses/Run with the
    /// definition snapshot the run retains, one sample whose three MHC-A calls
    /// carry 100, 2 and 1 reads of the three diagnostic markers, the given stats
    /// metrics and, unless `recordsProvenance` is false, the provenance envelope
    /// whose argv the run's request wrote.
    private func makeFullLengthFixture(
        metrics: [String: String],
        sampleFraction: Double? = nil,
        locusFraction: Double? = nil,
        overrides: [String: Double] = [:],
        recordsProvenance: Bool = true
    ) throws -> FullLengthFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewedResolverSF1-\(UUID().uuidString)")
        let project = root.appendingPathComponent("Project.lungfish")
        let bundle = project.appendingPathComponent("Analyses/Run/cohort.lungfishgenotype")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [project.appendingPathComponent("Imports/reads.lungfishfastq/reads.fastq")],
            referenceSourceURL: project.appendingPathComponent("Reference allele databases/cohort.lungfishmhcref"),
            outputDirectory: bundle,
            outputName: "cohort",
            projectURL: project,
            haplotypeDropoutSampleFraction: sampleFraction,
            haplotypeDropoutLocusFraction: locusFraction,
            haplotypeDropoutLocusFractionOverrides: overrides,
            haplotypeAssayID: "sf1-assay",
            haplotypeDefinitionSetID: "sf1-defs"
        )
        let snapshotURL = GenotypeHaplotypeAnalysisResolver.retainedDefinitionSnapshotURL(for: bundle)
        try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(sf1Definition()).write(to: snapshotURL)
        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .haplotyped,
            outputName: "cohort", analysisName: "Cohort",
            primaryWorkbookPath: request.workbookURL.lastPathComponent,
            longSummaryCSVPath: request.reportCSVURL.lastPathComponent,
            sampleSummaryCSVPath: request.sampleSummaryCSVURL.lastPathComponent,
            statsJSONPath: request.statsJSONURL.lastPathComponent,
            provenancePath: request.provenanceURL.lastPathComponent,
            haplotypeDefinitionSetID: "sf1-defs", haplotypeAssayID: "sf1-assay"
        )
        if recordsProvenance {
            let envelope = ProvenanceEnvelope(
                workflowName: "lungfish fastq full-length-ont-mhc-genotype",
                toolName: "lungfish-cli",
                argv: request.argv,
                durableReplayArgv: request.argv
            )
            try ProvenanceJSON.encoder.encode(envelope).write(to: request.provenanceURL)
        }
        func call(_ marker: String, reads: Int) -> ONTGenotypeCall {
            .init(sample: "sample", genotype: "\(marker)|source_loci=MHC-A|haplotype_groups=MHC-A",
                  passedAlignments: reads, passedUniqueReads: reads, sampleTotalReads: nil,
                  sampleUniqueRetainedReads: nil, sampleUniqueRetainedPercent: nil, overallInputReads: nil,
                  overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil)
        }
        let result = ONTGenotypeResultBundleData(
            bundleURL: bundle, manifest: manifest,
            artifacts: .init(workbookURL: request.workbookURL,
                             longSummaryCSVURL: request.reportCSVURL,
                             sampleSummaryCSVURL: request.sampleSummaryCSVURL,
                             statsJSONURL: request.statsJSONURL,
                             provenanceURL: request.provenanceURL, haplotypeAnalysisURL: nil),
            stats: .init(rawMetrics: metrics),
            calls: [call("A_marker", reads: 100), call("B_marker", reads: 2), call("C_marker", reads: 1)],
            samples: [], haplotypeAnalysis: nil
        )
        return FullLengthFixture(root: root, result: result, request: request)
    }
}
