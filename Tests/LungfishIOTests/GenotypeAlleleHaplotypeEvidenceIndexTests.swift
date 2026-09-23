import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeAlleleHaplotypeEvidenceIndexTests: XCTestCase {
    private func call(_ genotype: String, sample: String = "animal", reads: Int = 20) -> ONTGenotypeCall {
        ONTGenotypeCall(sample: sample, genotype: genotype, passedAlignments: reads, passedUniqueReads: reads,
                       sampleTotalReads: nil, sampleUniqueRetainedReads: nil, sampleUniqueRetainedPercent: nil,
                       overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil)
    }

    private func definitions(_ loci: [GenotypeHaplotypeLocusDefinition]) -> GenotypeHaplotypeDefinitionSet {
        .init(id: "custom", assayID: "assay", displayName: "Custom", speciesName: "Macaque", speciesCode: "Mafa", prefix: "",
              locusDefinitions: loci)
    }

    private var definitionSet: GenotypeHaplotypeDefinitionSet {
        definitions([.init(locus: "MHC-A", sourceLocus: "MHC-A", haplotypes: [
            .init(name: "M1", diagnosticAlleles: ["Mafa-A1_01", "Mafa-A1_03"]),
            .init(name: "M3", diagnosticAlleles: ["Mafa-A1_02", "Mafa-A1_03"])
        ])])
    }

    func testDiagnosticRowsIncludeUnresolvedAndOtherHaplotypesButExcludeSupplementalAlleles() {
        let diagnostic = call("Mafa-A1_01")
        let supplemental = call("Mafa-A1_04|haplotypes=M1")
        let index = GenotypeAlleleHaplotypeEvidenceIndex(calls: [diagnostic, supplemental], definitionSet: definitionSet, effectiveCalls: [])
        XCTAssertTrue(index.isDiagnostic(locus: diagnostic.locusGroup, genotype: diagnostic.genotype))
        XCTAssertFalse(index.isDiagnostic(locus: supplemental.locusGroup, genotype: supplemental.genotype))
        XCTAssertTrue(index.support(locus: diagnostic.locusGroup, genotype: diagnostic.genotype, sample: diagnostic.sample).isEmpty)
    }

    func testSingleSharedAndAbsentSupportPreserveDistinctHaplotypes() {
        let one = call("Mafa-A1_01")
        let three = call("Mafa-A1_02")
        let shared = call("Mafa-A1_03")
        let absent = call("Mafa-A1_01", sample: "absent", reads: 0)
        let index = GenotypeAlleleHaplotypeEvidenceIndex(calls: [one, three, shared, absent], definitionSet: definitionSet,
            effectiveCalls: [.init(sample: "animal", locus: "MHC-A", haplotypeNames: ["M1", "M3"]),
                             .init(sample: "absent", locus: "MHC-A", haplotypeNames: ["M1", "M3"])])
        XCTAssertEqual(index.support(locus: one.locusGroup, genotype: one.genotype, sample: one.sample).map(\.name), ["M1"])
        XCTAssertEqual(index.support(locus: three.locusGroup, genotype: three.genotype, sample: three.sample).map(\.name), ["M3"])
        XCTAssertEqual(index.support(locus: shared.locusGroup, genotype: shared.genotype, sample: shared.sample).map(\.name), ["M1", "M3"])
        XCTAssertTrue(index.support(locus: absent.locusGroup, genotype: absent.genotype, sample: absent.sample).isEmpty)
        XCTAssertTrue(index.support(locus: one.locusGroup, genotype: one.genotype, sample: "missing").isEmpty)
    }

    func testEffectiveCallsReplacePipelineAndHomozygotesDoNotDuplicateSupport() {
        let row = call("Mafa-A1_03")
        let index = GenotypeAlleleHaplotypeEvidenceIndex(calls: [row], definitionSet: definitionSet,
            effectiveCalls: [.init(sample: row.sample, locus: "MHC-A", haplotypeNames: ["M3", "M3"])])
        XCTAssertEqual(index.support(locus: row.locusGroup, genotype: row.genotype, sample: row.sample).map(\.name), ["M3"])
    }

    func testAssociationsRequireEffectiveDefinedHaplotypeAndCorrectLocus() {
        let valid = call("Mafa-A1_04|haplotypes=M1,M7")
        let wrongLocus = call("Mafa-B_04|haplotypes=M1")
        let staleHeader = call("Mafa-A1_01|haplotypes=M3")
        let index = GenotypeAlleleHaplotypeEvidenceIndex(calls: [valid, wrongLocus, staleHeader], definitionSet: definitionSet,
            effectiveCalls: [.init(sample: "animal", locus: "MHC-A", haplotypeNames: ["M1", "M3", "M7"])])
        XCTAssertEqual(index.support(locus: valid.locusGroup, genotype: valid.genotype, sample: valid.sample).map(\.name), ["M1"])
        XCTAssertTrue(index.support(locus: wrongLocus.locusGroup, genotype: wrongLocus.genotype, sample: wrongLocus.sample).isEmpty)
        XCTAssertEqual(index.support(locus: staleHeader.locusGroup, genotype: staleHeader.genotype, sample: staleHeader.sample).map(\.name), ["M1"])
    }

    func testCustomHaplotypeNamesColorsAndCombinedClassIILoci() {
        let color = AnnotationColor(red: 0.2, green: 0.7, blue: 0.4)
        let row = call("007_Mafa-DQA1_01")
        let set = definitions([.init(locus: "MHC-DQ", sourceLocus: "MHC-DQ", haplotypes: [
            .init(name: "Custom-17", diagnosticAlleles: ["Mafa-DQA1_01"], colorOverride: color)
        ])])
        let index = GenotypeAlleleHaplotypeEvidenceIndex(calls: [row], definitionSet: set,
            effectiveCalls: [.init(sample: row.sample, locus: "MHC-DQ", haplotypeNames: ["Custom-17"])])
        XCTAssertTrue(index.isDiagnostic(locus: row.locusGroup, genotype: row.genotype))
        XCTAssertEqual(index.support(locus: row.locusGroup, genotype: row.genotype, sample: row.sample).first?.fillColor, color)
        XCTAssertEqual(index.legend.map(\.name), ["Custom-17"])
    }

    func testRepertoireHeaderTokensResolveOnlyExactLocusQualifiedNames() {
        let row = call("MCM_MHC_MiSeq_0200|source_loci=MHC-G|haplotype_groups=MHC-A|haplotypes=M1,Founder")
        let set = definitions([.init(locus: "MHC-A", sourceLocus: "Mafa-A", haplotypes: [
            .init(name: "M1A", diagnosticAlleles: ["diagnostic-1"]),
            .init(name: "M10A", diagnosticAlleles: ["diagnostic-10"]),
            .init(name: "FounderA", diagnosticAlleles: ["diagnostic-founder"]),
            .init(name: "M1B", diagnosticAlleles: ["diagnostic-b"])
        ])])
        let index = GenotypeAlleleHaplotypeEvidenceIndex(calls: [row], definitionSet: set,
            effectiveCalls: [.init(sample: row.sample, locus: "MHC-A", haplotypeNames: ["M1A", "M10A", "FounderA", "M1B"])])
        XCTAssertFalse(index.isDiagnostic(locus: row.locusGroup, genotype: row.genotype))
        XCTAssertEqual(index.support(locus: row.locusGroup, genotype: row.genotype, sample: row.sample).map(\.name), ["M1A", "FounderA"])
    }

    func testCrossFamilyDiagnosticsFollowExistingLocusResolver() {
        let row = call("Mafa-G_01")
        let set = definitions([.init(locus: "MHC-A", sourceLocus: "Mafa-A", haplotypes: [
            .init(name: "A-H1", diagnosticAlleles: ["Mafa-G_01"])
        ])])
        let index = GenotypeAlleleHaplotypeEvidenceIndex(calls: [row], definitionSet: set,
            effectiveCalls: [.init(sample: row.sample, locus: "MHC-A", haplotypeNames: ["A-H1"])])
        XCTAssertTrue(index.isDiagnostic(locus: row.locusGroup, genotype: row.genotype))
        XCTAssertEqual(index.support(locus: row.locusGroup, genotype: row.genotype, sample: row.sample).map(\.name), ["A-H1"])
    }
    func testExplicitAssociatedAllelesColorWithoutBecomingDiagnosticAndPreserveSharedSupport() throws {
        // Decode so this fixture also exercises the persisted bundle format.
        let first = try JSONDecoder().decode(GenotypeHaplotypeDefinition.self, from: Data(#"{"name":"M1","diagnosticAlleles":["Mafa-A1_01"],"associatedAlleles":["Mafa-A1_01","Mafa-A1_04"]}"#.utf8))
        let second = try JSONDecoder().decode(GenotypeHaplotypeDefinition.self, from: Data(#"{"name":"M3","diagnosticAlleles":["Mafa-A1_02"],"associatedAlleles":["Mafa-A1_02","Mafa-A1_01","Mafa-A1_04"]}"#.utf8))
        let set = definitions([.init(locus: "MHC-A", sourceLocus: "MHC-A", haplotypes: [first, second])])
        let sharedDiagnostic = call("Mafa-A1_01")
        let supportive = call("Mafa-A1_04")
        let removed = call("Mafa-A1_05|haplotypes=M1")
        let absent = call("Mafa-A1_04", sample: "absent", reads: 0)
        let index = GenotypeAlleleHaplotypeEvidenceIndex(calls: [sharedDiagnostic, supportive, removed, absent], definitionSet: set,
            effectiveCalls: [.init(sample: "animal", locus: "MHC-A", haplotypeNames: ["M1", "M3"]),
                             .init(sample: "absent", locus: "MHC-A", haplotypeNames: ["M1"])])
        XCTAssertTrue(index.isDiagnostic(locus: sharedDiagnostic.locusGroup, genotype: sharedDiagnostic.genotype))
        XCTAssertFalse(index.isDiagnostic(locus: supportive.locusGroup, genotype: supportive.genotype))
        for row in [sharedDiagnostic, supportive] {
            XCTAssertEqual(index.support(locus: row.locusGroup, genotype: row.genotype, sample: row.sample).map(\.name), ["M1", "M3"])
        }
        XCTAssertTrue(index.support(locus: removed.locusGroup, genotype: removed.genotype, sample: removed.sample).isEmpty,
                      "Explicit membership must override stale reference headers")
        XCTAssertTrue(index.support(locus: absent.locusGroup, genotype: absent.genotype, sample: absent.sample).isEmpty)
        XCTAssertTrue(index.support(locus: supportive.locusGroup, genotype: supportive.genotype, sample: "uncalled").isEmpty)
    }

    func testExplicitCrossFamilyAssociatedAlleleUsesSameLocusPolicyAsDiagnostic() throws {
        let haplotype = try JSONDecoder().decode(GenotypeHaplotypeDefinition.self, from: Data(#"{"name":"A-H1","diagnosticAlleles":["Mafa-A1_01"],"associatedAlleles":["Mafa-A1_01","Mafa-G_01"]}"#.utf8))
        let set = definitions([.init(locus: "MHC-A", sourceLocus: "Mafa-A", haplotypes: [haplotype])])
        let row = call("Mafa-G_01")
        let index = GenotypeAlleleHaplotypeEvidenceIndex(calls: [row], definitionSet: set,
            effectiveCalls: [.init(sample: row.sample, locus: "MHC-A", haplotypeNames: ["A-H1"])])
        XCTAssertFalse(index.isDiagnostic(locus: row.locusGroup, genotype: row.genotype))
        XCTAssertEqual(index.support(locus: row.locusGroup, genotype: row.genotype, sample: row.sample).map(\.name), ["A-H1"])
    }

}
