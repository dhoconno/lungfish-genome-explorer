import Foundation
import XCTest
import LungfishIO
@testable import LungfishCLI

final class GenotypeActiveHaplotypeAnalysisResolverTests: XCTestCase {
    func testPersistedAIAnalysisIsActiveWhenNoSidecarDefinitionOverrideExists() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let active = try XCTUnwrap(GenotypeActiveHaplotypeAnalysisResolver.activeAnalysis(
            for: fixture.result,
            sidecar: fixture.sidecar
        ))

        XCTAssertEqual(active.source, .ai)
        XCTAssertEqual(active.analysisRevisionID, "haprev-ai-0001")
        let mhcA = try XCTUnwrap(active.samples.first { $0.sample == "S1" }?.calls.first { $0.locus == "MHC-A" })
        XCTAssertEqual(mhcA.haplotype1, "AI-M9A")
    }

    func testPersistedAIAnalysisWinsOverStaleSidecarDefinitionOverride() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var sidecar = fixture.sidecar
        sidecar.settings.activeHaplotypeDefinitionSetID = "deterministic-defs"
        sidecar.settings.activeHaplotypeAssayID = "assay"

        let active = try XCTUnwrap(GenotypeActiveHaplotypeAnalysisResolver.activeAnalysis(
            for: fixture.result,
            bundleURL: fixture.result.bundleURL,
            sidecar: sidecar
        ))

        XCTAssertEqual(active.source, .ai)
        XCTAssertEqual(active.analysisRevisionID, "haprev-ai-0001")
        let mhcA = try XCTUnwrap(active.samples.first { $0.sample == "S1" }?.calls.first { $0.locus == "MHC-A" })
        XCTAssertEqual(mhcA.haplotype1, "AI-M9A")
    }
}

private extension GenotypeActiveHaplotypeAnalysisResolverTests {
    struct Fixture {
        let root: URL
        let result: ONTGenotypeResultBundleData
        let sidecar: GenotypeAnnotationSidecar
    }

    func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeActiveHaplotypeAnalysisResolverTests-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("Project", isDirectory: true)
        let analysisRoot = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("Run", isDirectory: true)
        let bundleURL = analysisRoot.appendingPathComponent("fixture.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try writeDeterministicDefinition(in: projectRoot)

        let workbookURL = bundleURL.appendingPathComponent("fixture.xlsx")
        let longCSV = bundleURL.appendingPathComponent("long.csv")
        let sampleCSV = bundleURL.appendingPathComponent("samples.csv")
        let statsURL = bundleURL.appendingPathComponent("stats.json")
        let provenanceURL = bundleURL.appendingPathComponent("run.lungfish-provenance.json")
        let aiAnalysisURL = bundleURL.appendingPathComponent("ai-haplotypes.json")
        try Data("workbook".utf8).write(to: workbookURL)
        try Data("sample,genotype\nS1,01_DET_A_001\n".utf8).write(to: longCSV)
        try Data("sample\nS1\n".utf8).write(to: sampleCSV)
        try Data("{}".utf8).write(to: statsURL)
        try Data("{}".utf8).write(to: provenanceURL)

        let aiAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "assay",
            definitionSetID: "ai-provisional:haprev-ai-0001",
            definitionSetName: "AI provisional haplotype calls",
            speciesName: "Test species",
            generatedAt: "2026-06-14T18:00:00Z",
            analysisRevisionID: "haprev-ai-0001",
            source: .ai,
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "S1",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "MHC-A",
                            haplotype1: "AI-M9A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_DET_A_001"]
                        )
                    ]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(aiAnalysis).write(to: aiAnalysisURL)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "fixture",
            analysisName: "Fixture",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: longCSV.lastPathComponent,
            sampleSummaryCSVPath: sampleCSV.lastPathComponent,
            statsJSONPath: statsURL.lastPathComponent,
            provenancePath: provenanceURL.lastPathComponent,
            haplotypeAnalysisPath: aiAnalysisURL.lastPathComponent,
            haplotypeDefinitionSetID: "deterministic-defs",
            haplotypeAssayID: "assay",
            createdAt: "2026-06-14T18:00:00Z",
            activeHaplotypeAnalysisRevisionID: "haprev-ai-0001",
            haplotypeAnalysisRevisions: []
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: workbookURL,
            longSummaryCSVURL: longCSV,
            sampleSummaryCSVURL: sampleCSV,
            statsJSONURL: statsURL,
            provenanceURL: provenanceURL,
            haplotypeAnalysisURL: aiAnalysisURL
        )
        let result = ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: artifacts,
            stats: ONTGenotypeRunStats(totalInputReads: 1),
            calls: [
                ONTGenotypeCall(
                    sample: "S1",
                    genotype: "01_DET_A_001",
                    passedAlignments: 10,
                    passedUniqueReads: 10,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    overallInputReads: nil,
                    overallUniqueRetainedReads: nil,
                    overallUniqueRetainedPercent: nil
                )
            ],
            samples: [],
            haplotypeAnalysis: aiAnalysis
        )
        return Fixture(root: root, result: result, sidecar: .empty(generatedAt: "2026-06-14T18:00:00Z"))
    }

    func writeDeterministicDefinition(in projectRoot: URL) throws {
        let folderURL = projectRoot.appendingPathComponent(HaplotypeDefinitionStore.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "deterministic-defs",
            assayID: "assay",
            displayName: "Deterministic test definitions",
            speciesName: "Test species",
            speciesCode: "TST",
            prefix: "DET",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "MHC-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "DET-A",
                            diagnosticAlleles: ["01_DET_A_001"],
                            minimumMatches: 1
                        )
                    ]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(
            to: folderURL.appendingPathComponent("deterministic-defs\(HaplotypeDefinitionStore.fileSuffix)")
        )
    }
}
