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
}
