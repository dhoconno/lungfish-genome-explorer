import XCTest
@testable import LungfishIO

final class GenotypeAIHaplotypeRevisionTests: XCTestCase {
    func testManifestRoundTripsAIHaplotypeAnalysisRevision() throws {
        let revision = ONTGenotypeHaplotypeAnalysisRevision(
            id: "haprev-ai-0001",
            method: .aiRefinement,
            path: "artifacts/haplotypes/active.haplotype-analysis.json",
            predecessorID: "haprev-det-0001",
            predecessorPath: "amplicon-genotyping.haplotype-analysis.json",
            createdAt: "2026-06-14T18:00:00Z",
            reviewState: .needsReview,
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 2048,
            provenancePath: "artifacts/ai-haplotyping/provenance/ai-refine.lungfish-provenance.json",
            provider: "openai",
            model: "gpt-5-mini",
            promptTemplateID: "lungfish.ai-haplotyping.refinement",
            promptTemplateVersion: "2026-06-14.1",
            promptHash: String(repeating: "b", count: 64),
            evidenceSnapshotPath: "artifacts/ai-haplotyping/evidence/evidence.json",
            validationReportPath: "artifacts/ai-haplotyping/validation/report.json"
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "run1",
            analysisName: "run1",
            primaryWorkbookPath: "run1.xlsx",
            currentWorkbookPath: "artifacts/workbooks/current.xlsx",
            workbookRevisions: [
                ONTGenotypeWorkbookRevision(
                    id: "wbrev-ai-0001",
                    role: .aiRefinement,
                    path: "artifacts/workbooks/current.xlsx",
                    label: "AI refinement current workbook",
                    createdAt: "2026-06-14T18:01:00Z",
                    predecessorID: "wbrev-initial",
                    predecessorPath: "artifacts/workbooks/revisions/initial.xlsx",
                    sha256: String(repeating: "c", count: 64),
                    sizeBytes: 4096,
                    provenancePath: revision.provenancePath
                )
            ],
            longSummaryCSVPath: "run1.genotypes.csv",
            sampleSummaryCSVPath: "run1.samples.csv",
            statsJSONPath: "run1.stats.json",
            provenancePath: "retained-demux-genotyping-provenance.json",
            haplotypeAnalysisPath: revision.path,
            haplotypeDefinitionSetID: nil,
            haplotypeAssayID: nil,
            createdAt: "2026-06-14T17:59:00Z",
            activeHaplotypeAnalysisRevisionID: revision.id,
            haplotypeAnalysisRevisions: [revision]
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: data)

        XCTAssertEqual(decoded.activeHaplotypeAnalysisRevisionID, "haprev-ai-0001")
        XCTAssertEqual(decoded.haplotypeAnalysisRevisions, [revision])
        XCTAssertEqual(decoded.workbookRevisions?.first?.role, .aiRefinement)
        XCTAssertEqual(decoded.haplotypeAnalysisPath, revision.path)
    }

    func testLegacyManifestDecodesWithoutRevisionFields() throws {
        let json = """
        {
          "schemaVersion": 1,
          "kind": "ont-barcode-genotype",
          "outputName": "legacy",
          "analysisName": "legacy",
          "primaryWorkbookPath": "legacy.xlsx",
          "longSummaryCSVPath": "legacy.genotypes.csv",
          "sampleSummaryCSVPath": "legacy.samples.csv",
          "statsJSONPath": "legacy.stats.json",
          "provenancePath": "legacy-provenance.json",
          "haplotypeAnalysisPath": "legacy.haplotype-analysis.json"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: json)

        XCTAssertNil(decoded.activeHaplotypeAnalysisRevisionID)
        XCTAssertNil(decoded.haplotypeAnalysisRevisions)
        XCTAssertEqual(decoded.haplotypeAnalysisPath, "legacy.haplotype-analysis.json")
    }

    func testAIHaplotypeCallMetadataRoundTripsOnAnalysis() throws {
        let h1Metadata = GenotypeHaplotypeAICallMetadata(
            patchOpID: "patch-call-h1",
            source: .ai,
            sourceState: .deterministic,
            reviewState: .needsReview,
            callState: .novelCandidate,
            confidenceTier: .medium,
            proposedHaplotypeLabel: "M9A-provisional",
            supportEvidenceRefs: ["obs:DW472:MHC-A:M1A"],
            counterevidenceRefs: ["dropout:DW472:MHC-A:M2A"],
            alternates: ["M2A"],
            rationaleCode: "cohort_recurrence",
            rationale: "Repeated cohort support with one dropout signal.",
            provenancePath: "artifacts/ai-haplotyping/provenance/ai-refine.lungfish-provenance.json"
        )
        let h2Metadata = GenotypeHaplotypeAICallMetadata(
            patchOpID: "patch-call-h2",
            source: .ai,
            sourceState: .manual,
            reviewState: .needsReview,
            callState: .retainCurrent,
            confidenceTier: .high,
            proposedHaplotypeLabel: "M2A",
            supportEvidenceRefs: ["manual:DW472:MHC-A:h2"],
            counterevidenceRefs: ["sample:DW472"],
            alternates: [],
            rationaleCode: "retain_manual_review",
            rationale: "Manual review remains the active call.",
            provenancePath: "artifacts/ai-haplotyping/provenance/ai-refine.lungfish-provenance.json"
        )
        let call = GenotypeHaplotypeLocusCall(
            locus: "MHC-A",
            sourceLocus: "MHC-A",
            haplotype1: "M1A",
            haplotype2: "M2A",
            status: .called,
            matchedHaplotypes: [],
            observedGenotypeCount: 2,
            observedGenotypes: ["M1A", "M2A"],
            notes: "AI review required",
            aiMetadata: h1Metadata,
            aiSlotMetadata: [
                GenotypeHaplotypeAISlotMetadata(slot: .h1, metadata: h1Metadata),
                GenotypeHaplotypeAISlotMetadata(slot: .h2, metadata: h2Metadata),
            ]
        )
        let analysis = GenotypeHaplotypeAnalysis(
            schemaVersion: 2,
            assayID: "ai-discovery",
            definitionSetID: "ai-provisional",
            definitionSetName: "AI provisional calls",
            speciesName: "Unknown",
            generatedAt: "2026-06-14T18:00:00Z",
            analysisRevisionID: "haprev-ai-0001",
            source: .ai,
            samples: [GenotypeHaplotypeSampleAnalysis(sample: "DW472", calls: [call])]
        )

        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(GenotypeHaplotypeAnalysis.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.analysisRevisionID, "haprev-ai-0001")
        XCTAssertEqual(decoded.source, .ai)
        XCTAssertEqual(decoded.samples[0].calls[0].aiMetadata, h1Metadata)
        XCTAssertEqual(decoded.samples[0].calls[0].aiSlotMetadata.map(\.slot), [.h1, .h2])
        XCTAssertEqual(decoded.samples[0].calls[0].aiSlotMetadata[0].metadata, h1Metadata)
        XCTAssertEqual(decoded.samples[0].calls[0].aiSlotMetadata[1].metadata, h2Metadata)
    }

    func testAIHaplotypeSourceEnumsCoverManualAndCurrentEvidenceStates() throws {
        XCTAssertEqual(GenotypeHaplotypeAnalysisSource.manual.rawValue, "manual")
        XCTAssertEqual(GenotypeHaplotypeAICallSourceState.raw.rawValue, "raw")
        XCTAssertEqual(GenotypeHaplotypeAICallSourceState.deterministic.rawValue, "deterministic")
        XCTAssertEqual(GenotypeHaplotypeAICallSourceState.manual.rawValue, "manual")
        XCTAssertEqual(GenotypeHaplotypeAICallSourceState.current.rawValue, "current")
        XCTAssertEqual(GenotypeHaplotypeAICallState.retainCurrent.rawValue, "retain_current")
    }

    func testLegacyHaplotypeAnalysisDecodesWithLegacySourceDefaults() throws {
        let json = """
        {
          "schemaVersion": 1,
          "assayID": "MHC-exon2-miSeq",
          "definitionSetID": "MHC-exon2-miSeq.mcm",
          "definitionSetName": "Legacy MCM",
          "speciesName": "Macaca fascicularis",
          "generatedAt": "2026-06-01T00:00:00Z",
          "samples": [
            {
              "sample": "DW472",
              "calls": [
                {
                  "locus": "MHC-A",
                  "sourceLocus": "MHC-A",
                  "haplotype1": "M1A",
                  "haplotype2": "M2A",
                  "status": "called",
                  "matchedHaplotypes": [],
                  "observedGenotypeCount": 2,
                  "observedGenotypes": ["M1A", "M2A"],
                  "notes": ""
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GenotypeHaplotypeAnalysis.self, from: json)

        XCTAssertNil(decoded.analysisRevisionID)
        XCTAssertEqual(decoded.source, .legacy)
        XCTAssertNil(decoded.samples[0].calls[0].aiMetadata)
    }
}
