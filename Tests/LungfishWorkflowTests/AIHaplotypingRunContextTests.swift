import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class AIHaplotypingRunContextTests: XCTestCase {
    func testInfersMCMShortAmpliconContextFromMafaMarkersAndDefinitionID() {
        let result = makeResult(
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            assayID: "MHC-exon2-miSeq",
            calls: [
                makeCall(genotype: "05_M1M2M3_A1_063g"),
                makeCall(genotype: "12_M1_B_134_02")
            ]
        )

        let context = AIHaplotypingRunContext.infer(from: result)

        XCTAssertEqual(context.speciesPrefix, "Mafa")
        XCTAssertEqual(context.populationHint, "mcm")
        XCTAssertEqual(context.assayResolution, "short_exon_amplicon")
        XCTAssertEqual(context.haplotypeFrameworkHint, "mcm-m1-m7")
        XCTAssertEqual(context.haplotypeDefinitionSetID, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
        XCTAssertEqual(context.haplotypeAssayID, "MHC-exon2-miSeq")
        XCTAssertTrue(context.notes.contains { $0.contains("MCM") })
    }

    func testInfersIndianRhesusRegionalContextFromMamuMarkers() {
        let result = makeResult(
            definitionSetID: nil,
            assayID: "MHC-exon2-miSeq",
            calls: [
                makeCall(genotype: "01_Mamu-A1_008g"),
                makeCall(genotype: "15_Mamu-AG2_01g1")
            ]
        )

        let context = AIHaplotypingRunContext.infer(from: result)

        XCTAssertEqual(context.speciesPrefix, "Mamu")
        XCTAssertEqual(context.populationHint, "indian-rhesus")
        XCTAssertEqual(context.assayResolution, "short_exon_amplicon")
        XCTAssertEqual(context.haplotypeFrameworkHint, "indian-rhesus-regional-blocks")
        XCTAssertTrue(context.observedRegions.contains("MHC-A"))
        XCTAssertTrue(context.observedRegions.contains("MHC-AG"))
        XCTAssertTrue(context.notes.contains { $0.contains("MHC-AG") })
    }

    func testInfersFullLengthContextWhenAlleleNamesUseStarNomenclature() {
        let result = makeResult(
            definitionSetID: "MHC-full-length-ONT.mamu",
            assayID: "MHC-full-length-ONT",
            calls: [
                makeCall(genotype: "Mamu-A1*008:01:01:01"),
                makeCall(genotype: "Mamu-B*069:02:01")
            ]
        )

        let context = AIHaplotypingRunContext.infer(from: result)

        XCTAssertEqual(context.speciesPrefix, "Mamu")
        XCTAssertEqual(context.assayResolution, "full_length_or_high_resolution")
        XCTAssertEqual(context.haplotypeFrameworkHint, "indian-rhesus-regional-blocks")
        XCTAssertTrue(context.notes.contains { $0.contains("full-length") })
    }

    private func makeCall(genotype: String) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: "Sample1",
            genotype: genotype,
            passedAlignments: 42,
            passedUniqueReads: 21,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }

    private func makeResult(
        definitionSetID: String?,
        assayID: String?,
        calls: [ONTGenotypeCall]
    ) -> ONTGenotypeResultBundleData {
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "out",
            analysisName: "Test",
            primaryWorkbookPath: "workbook.xlsx",
            longSummaryCSVPath: "long.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json",
            haplotypeDefinitionSetID: definitionSetID,
            haplotypeAssayID: assayID
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: URL(fileURLWithPath: "/tmp/workbook.xlsx"),
            longSummaryCSVURL: URL(fileURLWithPath: "/tmp/long.csv"),
            sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/samples.csv"),
            statsJSONURL: URL(fileURLWithPath: "/tmp/stats.json"),
            provenanceURL: URL(fileURLWithPath: "/tmp/provenance.json")
        )
        return ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/out.lungfishgenotype"),
            manifest: manifest,
            artifacts: artifacts,
            stats: ONTGenotypeRunStats(),
            calls: calls,
            samples: []
        )
    }
}
