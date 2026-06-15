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
        XCTAssertEqual(pack.legacyBlockDefinitions.filter { $0.populationID == "mcm" }.count, 45)
        XCTAssertEqual(pack.legacyBlockDefinitions.filter { $0.populationID == "indian-rhesus" }.count, 204)
        XCTAssertEqual(pack.legacyBlockDefinitions.count, 249)
        XCTAssertEqual(pack.alleleRecords.count, 284)
        XCTAssertTrue(pack.legacyBlockDefinitions.contains { $0.displayLabel == "M1A" && $0.reportLabel == "M1A" })
        XCTAssertTrue(pack.legacyBlockDefinitions.contains { $0.displayLabel == "A008.01" && $0.reportLabel == "A008.01" })
        XCTAssertTrue(pack.legacyBlockDefinitions.contains { $0.displayLabel == "DR01.01" && $0.region == "MHC-DRB" })
        let m3A = try XCTUnwrap(pack.legacyBlockDefinitions.first {
            $0.displayLabel == "M3A" && $0.populationID == "mcm"
        })
        XCTAssertEqual(m3A.definingMarkers.map(\.marker), [
            "05_M1M2M3_A1_063g",
            "07_M3_70_156bp",
        ])
        let mamuB = try XCTUnwrap(pack.legacyBlockDefinitions.first {
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

    func testKnowledgePackValidationRejectsUnknownSourceReferences() {
        let invalid = AIHaplotypingKnowledgePack(
            id: "invalid",
            version: "1",
            sources: [],
            populationProfiles: [],
            alleleRecords: [],
            legacyBlockDefinitions: [
                AIHaplotypingLegacyBlockDefinition(
                    id: "block:invalid",
                    internalID: "invalid",
                    displayLabel: "Invalid",
                    reportLabel: "Invalid",
                    speciesPrefix: "Mafa",
                    populationID: "mcm",
                    frameworkID: "mcm-m1-m7",
                    region: "MHC-A",
                    assayResolution: "short_exon_amplicon",
                    definitionStatus: "legacy_curated",
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
