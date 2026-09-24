import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// GEN-05 (decision D13): one read denominator per source locus, shared by
/// the matrix, the evidence pane, the haplotype caller and the Excel filter.
final class GenotypeLocusDenominatorTests: XCTestCase {
    /// Audit worked example: one animal with A1 3,000 reads, AG 2,000, E 1,500
    /// and two G alleles of 75 each, all filed under haplotype_groups=MHC-A.
    static func workedExampleCalls(sample: String = "LF1") -> [ONTGenotypeCall] {
        [
            call(sample, "MCM_MHC_MiSeq_0101|source_loci=MHC-A1|haplotype_groups=MHC-A|haplotypes=M1|alleles=Mafa-A1_063:01", 3_000),
            call(sample, "MCM_MHC_MiSeq_0102|source_loci=MHC-AG1|haplotype_groups=MHC-A|haplotypes=M1|alleles=Mafa-AG_05:02", 2_000),
            call(sample, "MCM_MHC_MiSeq_0103|source_loci=MHC-E|haplotype_groups=MHC-A|haplotypes=M1|alleles=Mafa-E_02:19", 1_500),
            call(sample, "MCM_MHC_MiSeq_0003|source_loci=MHC-G|haplotype_groups=MHC-A|haplotypes=M1|alleles=Mafa-G_02:14:01:01", 75),
            call(sample, "MCM_MHC_MiSeq_0004|source_loci=MHC-G|haplotype_groups=MHC-A|haplotypes=M2|alleles=Mafa-G_02:31:01:01", 75),
        ]
    }

    func testSourceLociGroupingIsPinnedForAGRecordFiledUnderTheMHCAHaplotypeGroup() {
        let g = Self.call("LF1", "MCM_MHC_MiSeq_0003|source_loci=MHC-G|haplotype_groups=MHC-A|haplotypes=M1", 75)

        // The denominator groups by the source locus...
        XCTAssertEqual(GenotypeLocusDenominator.sourceLocus(for: g), "MHC-G")
        // ...while the haplotype grouping (for calling, never for a
        // denominator) still follows the reference metadata.
        XCTAssertEqual(GenotypeHaplotypeLocusResolver.metadataHaplotypeGroupLocus(for: g.genotype), "MHC-A")
        XCTAssertEqual(GenotypeHaplotypeLocusResolver.haplotypeEvidenceLocus(for: g), "MHC-A")
    }

    func testWorkedExampleNormalizesEachSourceLocusOnItsOwn() throws {
        let calls = Self.workedExampleCalls()
        let denominator = GenotypeLocusDenominator(calls: calls)
        let gAlleles = calls.filter { $0.genotype.contains("source_loci=MHC-G") }
        XCTAssertEqual(gAlleles.count, 2)
        for allele in gAlleles {
            XCTAssertEqual(denominator.total(for: allele), 150)
            XCTAssertEqual(try XCTUnwrap(denominator.fraction(for: allele)), 0.5, accuracy: 1e-12)
        }
        XCTAssertEqual(denominator.total(for: calls[0]), 3_000, "A1 is its own source locus")
        XCTAssertEqual(denominator.total(for: calls[1]), 2_000, "AG is its own source locus")
        XCTAssertEqual(denominator.total(for: calls[2]), 1_500, "E is its own source locus")
    }

    static func workedExampleDefinition() -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: "worked-example",
            assayID: "MHC-exon2-miSeq",
            displayName: "Worked example",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "MHC-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1A", diagnosticAlleles: ["MCM_MHC_MiSeq_0003"], minimumMatches: 1),
                        GenotypeHaplotypeDefinition(name: "M2A", diagnosticAlleles: ["MCM_MHC_MiSeq_0004"], minimumMatches: 1),
                    ]
                ),
            ]
        )
    }

    /// Before GEN-05 the caller divided each G allele by the pooled MHC-A
    /// haplotype group (6,650 reads, 1.1%) and dropped both at a 5% locus
    /// threshold while the matrix showed them at 50%. The caller now uses the
    /// source-locus denominator: exactly 50%, pinned from both sides.
    func testHaplotypeCallerDividesEachGAlleleByItsSourceLocus() throws {
        let calls = Self.workedExampleCalls()
        let gGenotypes = Set(calls.map(\.genotype).filter { $0.contains("source_loci=MHC-G") })
        func mhcA(locusFraction: Double) throws -> GenotypeHaplotypeLocusCall {
            let analysis = GenotypeHaplotypeAnalyzer.analyze(
                calls: calls,
                definitionSet: Self.workedExampleDefinition(),
                dropoutFilter: GenotypeDropoutEvaluator(absolute: nil, sampleFraction: nil, locusFraction: locusFraction)
            )
            XCTAssertEqual(analysis.schemaVersion, GenotypeHaplotypeAnalyzer.callingRulesVersion)
            return try XCTUnwrap(analysis.samples.first?.calls.first { $0.locus == "MHC-A" })
        }

        let atFive = try mhcA(locusFraction: 0.05)
        XCTAssertTrue(gGenotypes.isSubset(of: Set(atFive.observedGenotypes)))
        XCTAssertEqual(Set(atFive.matchedHaplotypes.map(\.name)), ["M1A", "M2A"])

        // 50% is the boundary: kept at 50%, dropped just above it.
        let atFifty = try mhcA(locusFraction: 0.50)
        XCTAssertTrue(gGenotypes.isSubset(of: Set(atFifty.observedGenotypes)))
        let aboveFifty = try mhcA(locusFraction: 0.5001)
        XCTAssertTrue(gGenotypes.isDisjoint(with: Set(aboveFifty.observedGenotypes)))
        XCTAssertEqual(GenotypeHaplotypeAnalyzer.callingRulesVersion, 3)
    }

    func testCandidateClusterReadsCountTowardTheirSourceLocus() throws {
        let known = Self.call("S1", "Mafa-A1*001:01", 40)
        let document = GenotypeLocusDenominatorFixtures.candidateDocument(
            candidates: [("novel", "Mafa-A1*900:01_nov", "MHC-A1")],
            observations: [("novel", "S1", 60)]
        )
        let denominator = GenotypeLocusDenominator(calls: [known], candidateDocument: document)

        XCTAssertEqual(denominator.total(for: known), 100)
        XCTAssertEqual(try XCTUnwrap(denominator.fraction(reads: 60, sample: "S1", sourceLocus: "MHC-A1")), 0.6, accuracy: 1e-12)
        XCTAssertNil(denominator.fraction(reads: 1, sample: "S2", sourceLocus: "MHC-A1"))
    }

    func testSourceLocusKeyIsIdempotentForCallGroupsAndCandidateLabels() {
        for label in ["MHC-A", "MHC-AG", "MHC-G", "MHC-DQA1", "MHC-DPB1", "MHC-B", "KIR-KIR3DL01", "Unknown"] {
            XCTAssertEqual(GenotypeLocusDenominator.sourceLocus(forLocusLabel: label), label, label)
        }
        XCTAssertEqual(GenotypeLocusDenominator.sourceLocus(forLocusLabel: "MHC-A1"), "MHC-A")
    }

    func testBundleSupportFractionUsesTheSharedDenominator() throws {
        let calls = Self.workedExampleCalls()
        let result = GenotypeTestFixtures.makeResult(calls: calls)
        for allele in calls where allele.genotype.contains("source_loci=MHC-G") {
            XCTAssertEqual(try XCTUnwrap(result.supportFraction(for: allele, denominator: .viewedLocus)), 0.5, accuracy: 1e-12)
        }
        XCTAssertEqual(result.hiddenSupportCallCount(minimumSupportPercent: 5, denominator: .viewedLocus), 0)
    }

    static func call(_ sample: String, _ genotype: String, _ reads: Int) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }
}

enum GenotypeLocusDenominatorFixtures {
    static func candidateDocument(
        candidates: [(id: String, name: String, locus: String)],
        observations: [(id: String, sample: String, reads: Int)]
    ) -> ONTMHCCandidateAllelesDocument {
        ONTMHCCandidateAllelesDocument(
            schemaVersion: 1,
            createdAt: "2026-09-24T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: [],
            sequenceFASTA: ONTMHCArtifactReference(
                path: "candidate.fasta",
                sha256: String(repeating: "a", count: 64),
                sizeBytes: 1
            ),
            candidates: candidates.map { candidate in
                let samples = Array(Set(observations.filter { $0.id == candidate.id }.map(\.sample))).sorted()
                return ONTMHCCandidateRecord(
                    stableClusterID: candidate.id,
                    provisionalName: candidate.name,
                    locus: candidate.locus,
                    classification: .novel,
                    supportClass: samples.count > 1 ? .shared : .singleton,
                    closestReferenceName: "reference",
                    closestReferenceClass: .genomicDNA,
                    snpCount: 1,
                    insertedBases: 0,
                    deletedBases: 0,
                    longGapBases: 0,
                    comparableBases: 2_000,
                    shorterCoverage: 1,
                    identity: 0.99,
                    mappingQuality: 60,
                    alignmentScore: 2_000,
                    independentSampleCount: samples.count,
                    occurrenceCount: samples.count,
                    totalClusterReads: observations.filter { $0.id == candidate.id }.reduce(0) { $0 + $1.reads },
                    supportingSampleIDs: samples,
                    fastaRecordID: candidate.id,
                    sequenceSHA256: String(repeating: "b", count: 64),
                    selectedEvidence: ONTMHCEvidenceLocator(
                        bamPath: "evidence.bam",
                        queryName: candidate.id,
                        referenceName: "reference",
                        readGroupID: nil,
                        referenceStart: 1,
                        cigar: "2000M"
                    )
                )
            },
            observations: observations.map { observation in
                ONTMHCCandidateObservation(
                    stableClusterID: observation.id,
                    sampleID: observation.sample,
                    readGroupID: observation.sample,
                    sourceClusterIDs: ["source-\(observation.id)-\(observation.sample)"],
                    sourceClusterReadCounts: ["source-\(observation.id)-\(observation.sample)": observation.reads],
                    aggregatedSampleReadCount: observation.reads,
                    evidence: []
                )
            }
        )
    }
}
