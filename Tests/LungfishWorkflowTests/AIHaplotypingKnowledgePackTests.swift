import XCTest
@testable import LungfishWorkflow

final class AIHaplotypingKnowledgePackTests: XCTestCase {
    func testBundledMacaqueKnowledgePackLoadsWithStableCoreContent() throws {
        let pack = try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC()

        XCTAssertEqual(pack.id, "macaque-mhc")
        XCTAssertEqual(pack.version, "2026-06-15.2")
        XCTAssertTrue(pack.digest.hasPrefix("sha256:"))
        XCTAssertEqual(pack.digest.count, "sha256:".count + 64)
        XCTAssertTrue(pack.sources.contains { $0.id == "source:notebook:miseq-genotyping-without-labkey" })
        XCTAssertTrue(pack.populationProfiles.contains { $0.id == "mcm" })
        XCTAssertTrue(pack.populationProfiles.contains { $0.id == "indian-rhesus" })
        XCTAssertEqual(pack.haplotypeBlockDefinitions.filter { $0.populationID == "mcm" }.count, 45)
        XCTAssertEqual(pack.haplotypeBlockDefinitions.filter { $0.populationID == "indian-rhesus" }.count, 204)
        XCTAssertEqual(pack.haplotypeBlockDefinitions.count, 249)
        XCTAssertEqual(pack.alleleRecords.count, 284)
        XCTAssertTrue(pack.haplotypeBlockDefinitions.contains { $0.displayLabel == "M1A" && $0.reportLabel == "M1A" })
        XCTAssertTrue(pack.haplotypeBlockDefinitions.contains { $0.displayLabel == "A008.01" && $0.reportLabel == "A008.01" })
        XCTAssertTrue(pack.haplotypeBlockDefinitions.contains { $0.displayLabel == "DR01.01" && $0.region == "MHC-DRB" })
        let m3A = try XCTUnwrap(pack.haplotypeBlockDefinitions.first {
            $0.displayLabel == "M3A" && $0.populationID == "mcm"
        })
        XCTAssertEqual(m3A.definingMarkers.map(\.marker), [
            "05_M1M2M3_A1_063g",
            "07_M3_70_156bp",
        ])
        let mamuB = try XCTUnwrap(pack.haplotypeBlockDefinitions.first {
            $0.displayLabel == "B069.02" && $0.populationID == "indian-rhesus"
        })
        XCTAssertEqual(mamuB.definingMarkers.map(\.marker), ["B_068", "B_069", "B_075"])
        let a1063 = try XCTUnwrap(pack.alleleRecords.first {
            $0.officialDesignation == "Mafa-A1*063:01:01:01"
        })
        XCTAssertEqual(a1063.accession, "OR823435")
        XCTAssertEqual(a1063.haplotypes, ["M1", "M2"])
    }

    func testKnowledgePackDigestIgnoresStoredDigestAndChangesWhenContentChanges() throws {
        let pack = try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC()
        let recomputed = pack.recomputingDigest()

        XCTAssertEqual(pack.digest, recomputed.digest)

        var changed = recomputed
        changed.analystGuidance.append(AIHaplotypingAnalystGuidance(
            id: "guidance:test-only",
            title: "Test-only rule",
            text: "Changing guidance changes the digest.",
            sourceIDs: ["source:notebook:miseq-genotyping-without-labkey"]
        ))
        XCTAssertNotEqual(changed.recomputingDigest().digest, pack.digest)
    }

    func testCompactKnowledgePackDoesNotFetchAllAllelesForCollapsedMarkerEvidence() throws {
        let pack = try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC()
        let sample = SampleEvidence(id: "sample:B25276", sample: "B25276")
        let locus = LocusEvidence(id: "locus:MHC-DRB", locus: "MHC-DRB")
        let markerLabels = [
            "06_M1_DRB_w_19",
            "06_M2_DRB_w_20",
            "06_M3_DRB_w_21",
            "06_M4_DRB_w_22",
            "06_M5_DRB_w_23",
            "06_M6_DRB_w_24",
            "06_M7_DRB_w_25",
        ]
        let registry = AIHaplotypingEvidenceRegistry(
            mode: .aiRefinement,
            parentRevisionID: nil,
            inputSnapshotDigest: "sha256:\(String(repeating: "a", count: 64))",
            samples: [sample],
            loci: [locus],
            observations: markerLabels.enumerated().map { index, genotype in
                ObservationEvidence(
                    id: "obs:B25276:MHC-DRB:\(genotype)",
                    evidenceClass: .directObservation,
                    sampleID: sample.id,
                    locusID: locus.id,
                    genotype: genotype,
                    passedAlignments: 100 - index,
                    passedUniqueReads: 100 - index,
                    sampleUniqueRetainedReads: 1_000
                )
            }
        )
        let runContext = AIHaplotypingRunContext(
            speciesPrefix: "Mafa",
            populationHint: "mcm",
            assayResolution: "short_exon_amplicon",
            workflowKind: "ont_genotyping",
            haplotypeFrameworkHint: "mcm-m1-m7",
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            haplotypeAssayID: "MHC-exon2-miSeq",
            observedRegions: ["MHC-DRB"],
            notes: []
        )

        let compact = AIHaplotypingKnowledgePackRetriever.compact(
            pack,
            for: registry,
            runContext: runContext
        )

        XCTAssertLessThan(compact.haplotypeBlockDefinitions.count, pack.haplotypeBlockDefinitions.count)
        XCTAssertLessThan(compact.alleleRecords.count, 25)
        XCTAssertTrue(compact.haplotypeBlockDefinitions.contains { $0.reportLabel == "M3DR" })
    }

    func testCompactKnowledgePackUsesChunkLocalRegionsInsteadOfRunWideRegions() throws {
        let pack = try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC()
        let sample = SampleEvidence(id: "sample:B25276", sample: "B25276")
        let locus = LocusEvidence(id: "locus:MHC-DRB", locus: "MHC-DRB")
        let registry = AIHaplotypingEvidenceRegistry(
            mode: .aiRefinement,
            parentRevisionID: nil,
            inputSnapshotDigest: "sha256:\(String(repeating: "b", count: 64))",
            samples: [sample],
            loci: [locus],
            observations: [
                ObservationEvidence(
                    id: "obs:B25276:MHC-DRB:06_M3_DRB_w_21",
                    evidenceClass: .directObservation,
                    sampleID: sample.id,
                    locusID: locus.id,
                    genotype: "06_M3_DRB_w_21",
                    passedAlignments: 100,
                    passedUniqueReads: 100,
                    sampleUniqueRetainedReads: 1_000
                )
            ]
        )
        let runContext = AIHaplotypingRunContext(
            speciesPrefix: "Mafa",
            populationHint: "mcm",
            assayResolution: "short_exon_amplicon",
            workflowKind: "ont_genotyping",
            haplotypeFrameworkHint: "mcm-m1-m7",
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            haplotypeAssayID: "MHC-exon2-miSeq",
            observedRegions: ["MHC-A", "MHC-DRB"],
            notes: []
        )

        let compact = AIHaplotypingKnowledgePackRetriever.compact(
            pack,
            for: registry,
            runContext: runContext
        )

        XCTAssertTrue(compact.haplotypeBlockDefinitions.contains { $0.region == "MHC-DRB" })
        XCTAssertFalse(compact.haplotypeBlockDefinitions.contains { $0.region == "MHC-A" })
    }

    func testCompactKnowledgePackDoesNotFallbackToAllPopulationBlocksForUnsupportedChunkRegion() throws {
        let pack = try AIHaplotypingKnowledgePackLoader.bundledMacaqueMHC()
        let sample = SampleEvidence(id: "sample:B25276", sample: "B25276")
        let locus = LocusEvidence(id: "locus:MHC-F", locus: "MHC-F")
        let registry = AIHaplotypingEvidenceRegistry(
            mode: .aiRefinement,
            parentRevisionID: nil,
            inputSnapshotDigest: "sha256:\(String(repeating: "c", count: 64))",
            samples: [sample],
            loci: [locus],
            observations: [
                ObservationEvidence(
                    id: "obs:B25276:MHC-F:01_M1_F_01_w_06",
                    evidenceClass: .directObservation,
                    sampleID: sample.id,
                    locusID: locus.id,
                    genotype: "01_M1_F_01_w_06",
                    passedAlignments: 100,
                    passedUniqueReads: 100,
                    sampleUniqueRetainedReads: 1_000
                )
            ]
        )
        let runContext = AIHaplotypingRunContext(
            speciesPrefix: "Mafa",
            populationHint: "mcm",
            assayResolution: "short_exon_amplicon",
            workflowKind: "ont_genotyping",
            haplotypeFrameworkHint: "mcm-m1-m7",
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            haplotypeAssayID: "MHC-exon2-miSeq",
            observedRegions: ["MHC-A", "MHC-B", "MHC-F"],
            notes: []
        )

        let compact = AIHaplotypingKnowledgePackRetriever.compact(
            pack,
            for: registry,
            runContext: runContext
        )

        XCTAssertEqual(compact.haplotypeBlockDefinitions.count, 0)
    }

    func testKnowledgePackValidationRejectsUnknownSourceReferences() {
        let invalid = AIHaplotypingKnowledgePack(
            id: "invalid",
            version: "1",
            sources: [],
            populationProfiles: [],
            alleleRecords: [],
            haplotypeBlockDefinitions: [
                AIHaplotypingHaplotypeBlockDefinition(
                    id: "block:invalid",
                    internalID: "invalid",
                    displayLabel: "Invalid",
                    reportLabel: "Invalid",
                    speciesPrefix: "Mafa",
                    populationID: "mcm",
                    frameworkID: "mcm-m1-m7",
                    region: "MHC-A",
                    assayResolution: "short_exon_amplicon",
                    definitionStatus: "curated",
                    sourceIDs: ["source:missing"],
                    definingMarkers: [],
                    extendedHaplotype: nil,
                    notes: ""
                )
            ],
            markerRules: [],
            analystGuidance: [],
            digest: "sha256:\(String(repeating: "0", count: 64))"
        )

        XCTAssertThrowsError(try invalid.validate()) { error in
            XCTAssertEqual(error as? AIHaplotypingKnowledgePackError, .unknownSourceID("source:missing"))
        }
    }
}
