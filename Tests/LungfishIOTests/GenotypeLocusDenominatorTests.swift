import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// One read denominator per source locus, shared by
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

    /// Before this fix the caller divided each G allele by the pooled MHC-A
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
        // Version 4, D2 (a tied cluster counts once) and N1 (a zero-read row
        // is not an observation), changed the calls users see. Version 5, N9
        // (a full-length call takes its source locus from its reference
        // record), changes them again.
        XCTAssertEqual(GenotypeHaplotypeAnalyzer.callingRulesVersion, 5)
    }

    // MARK: D2, a tied cluster counts once

    /// Full-length results give each equal-best reference of a cluster its
    /// own call with the full cluster reads and the tie list in
    /// `ambiguousWith`. A 1,000-read cluster tied between two MHC-A
    /// references beside a 15-read MHC-A allele.
    static func tiedClusterCalls(sample: String = "S1") -> [ONTGenotypeCall] {
        let tie = ["Mamu-A1*001:01", "Mamu-A1*001:02"]
        return [
            call(sample, "Mamu-A1*001:01", 1_000, ambiguousWith: tie),
            call(sample, "Mamu-A1*001:02", 1_000, ambiguousWith: tie),
            call(sample, "Mamu-A1*002:01", 15),
        ]
    }

    static func tiedClusterDefinition() -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: "tied-cluster",
            assayID: "full-length-test",
            displayName: "Tied cluster",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "MHC-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1A", diagnosticAlleles: ["Mamu-A1*001:01"], minimumMatches: 1),
                        GenotypeHaplotypeDefinition(name: "M2A", diagnosticAlleles: ["Mamu-A1*002:01"], minimumMatches: 1),
                    ]
                ),
            ]
        )
    }

    /// The locus total counts the tied cluster once, 1,015 reads and not
    /// 2,015, so the minor allele is 1.48 percent and not 0.74. Each tied
    /// reference keeps its full reads as its own support.
    func testATiedClusterCountsOnceInTheLocusTotal() throws {
        let calls = Self.tiedClusterCalls()
        for call in calls {
            XCTAssertEqual(GenotypeLocusDenominator.sourceLocus(for: call), "MHC-A", call.genotype)
        }
        let denominator = GenotypeLocusDenominator(calls: calls)

        XCTAssertEqual(denominator.total(for: calls[2]), 1_015)
        XCTAssertEqual(try XCTUnwrap(denominator.fraction(for: calls[2])), 0.01478, accuracy: 0.00001)
        XCTAssertEqual(calls[0].passedUniqueReads, 1_000, "a tied reference keeps the full cluster reads")
        XCTAssertEqual(try XCTUnwrap(denominator.fraction(for: calls[0])), 1_000.0 / 1_015.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(denominator.fraction(for: calls[1])), 1_000.0 / 1_015.0, accuracy: 1e-12)
    }

    /// With a 1 percent locus dropout the analyzer keeps the 15-read allele,
    /// and the sample fraction uses the same once-counted total.
    func testHaplotypeCallerKeepsTheMinorAlleleBesideATiedClusterAtOnePercent() throws {
        let calls = Self.tiedClusterCalls()
        func mhcA(_ evaluator: GenotypeDropoutEvaluator) throws -> GenotypeHaplotypeLocusCall {
            let analysis = GenotypeHaplotypeAnalyzer.analyze(
                calls: calls,
                definitionSet: Self.tiedClusterDefinition(),
                dropoutFilter: evaluator
            )
            return try XCTUnwrap(analysis.samples.first?.calls.first { $0.locus == "MHC-A" })
        }

        let locusCall = try mhcA(GenotypeDropoutEvaluator(absolute: nil, sampleFraction: nil, locusFraction: 0.01))
        XCTAssertTrue(locusCall.observedGenotypes.contains("Mamu-A1*002:01"), "\(locusCall.observedGenotypes)")
        XCTAssertEqual(Set(locusCall.matchedHaplotypes.map(\.name)), ["M1A", "M2A"])

        let sampleCall = try mhcA(GenotypeDropoutEvaluator(absolute: nil, sampleFraction: 0.01, locusFraction: nil))
        XCTAssertTrue(sampleCall.observedGenotypes.contains("Mamu-A1*002:01"), "\(sampleCall.observedGenotypes)")
        XCTAssertEqual(Set(sampleCall.matchedHaplotypes.map(\.name)), ["M1A", "M2A"])

        // 1.48 percent is the boundary, and the allele is dropped just above it.
        let aboveBoundary = try mhcA(GenotypeDropoutEvaluator(absolute: nil, sampleFraction: nil, locusFraction: 0.0148))
        XCTAssertFalse(aboveBoundary.observedGenotypes.contains("Mamu-A1*002:01"), "\(aboveBoundary.observedGenotypes)")
    }

    /// The three-way tie of the pipeline test, refA, refB and refC at 20
    /// reads each, all tied, plus refD at 7, all at one locus, is 27 reads.
    func testAThreeWayTieBesideAMinorAlleleCountsOnce() {
        let tie = ["refA|source_loci=MHC-A", "refB|source_loci=MHC-A", "refC|source_loci=MHC-A"]
        let calls = tie.map { Self.call("S1", $0, 20, ambiguousWith: tie) }
            + [Self.call("S1", "refD|source_loci=MHC-A", 7)]
        let denominator = GenotypeLocusDenominator(calls: calls)
        for call in calls {
            XCTAssertEqual(denominator.total(for: call), 27, call.genotype)
        }
    }

    /// An amplicon row stands for identical references collapsed before
    /// mapping, and lists members that are not calls. The total is unchanged.
    func testAnAmpliconTieGroupNamingCollapsedMembersLeavesTheTotalUnchanged() {
        let grouped = Self.call(
            "LF1", "MCM_MHC_MiSeq_0003|source_loci=MHC-G|haplotype_groups=MHC-A", 75,
            ambiguousWith: [
                "MCM_MHC_MiSeq_0003|source_loci=MHC-G|haplotype_groups=MHC-A",
                "MCM_MHC_MiSeq_0005|source_loci=MHC-G|haplotype_groups=MHC-A",
                "MCM_MHC_MiSeq_0006|source_loci=MHC-G|haplotype_groups=MHC-A",
            ]
        )
        let other = Self.call("LF1", "MCM_MHC_MiSeq_0004|source_loci=MHC-G|haplotype_groups=MHC-A", 75)
        let denominator = GenotypeLocusDenominator(calls: [grouped, other])
        XCTAssertEqual(denominator.total(for: grouped), 150)
        XCTAssertEqual(denominator.total(for: other), 150)
    }

    /// Tied references at two loci count once at each locus.
    func testATieSpanningTwoLociCountsOnceAtEachLocus() {
        let tie = ["Mamu-A1*001:01", "Mamu-B*001:01"]
        let calls = [
            Self.call("S1", "Mamu-A1*001:01", 1_000, ambiguousWith: tie),
            Self.call("S1", "Mamu-B*001:01", 1_000, ambiguousWith: tie),
            Self.call("S1", "Mamu-A1*002:01", 15),
            Self.call("S1", "Mamu-B*002:01", 30),
        ]
        let denominator = GenotypeLocusDenominator(calls: calls)
        XCTAssertEqual(GenotypeLocusDenominator.sourceLocus(for: calls[1]), "MHC-B")
        XCTAssertEqual(denominator.total(sample: "S1", sourceLocus: "MHC-A"), 1_015)
        XCTAssertEqual(denominator.total(sample: "S1", sourceLocus: "MHC-B"), 1_030)
    }

    /// Calls that name each other but carry different reads (a reference with
    /// a cluster of its own beside the shared one) are summed as before.
    func testTiedCallsWithDifferentReadsAreSummedAsBefore() {
        let tie = ["Mamu-A1*001:01", "Mamu-A1*001:02"]
        let calls = [
            Self.call("S1", "Mamu-A1*001:01", 1_000, ambiguousWith: tie),
            Self.call("S1", "Mamu-A1*001:02", 600, ambiguousWith: tie),
            Self.call("S1", "Mamu-A1*002:01", 15),
        ]
        XCTAssertEqual(GenotypeLocusDenominator(calls: calls).total(for: calls[2]), 1_615)
    }

    /// The tie rule is per animal. The same tie in two animals counts once in
    /// each, and never merges the animals.
    /// The call evidence pane pools an animal's reads across source loci for
    /// its summary. The pool counts a tied cluster once and sums every other
    /// locus, so it agrees with the per-locus totals it is built from.
    func testPooledKnownReadsCountATiedClusterOnceAcrossLoci() {
        let tie = ["Mamu-A1*001:01", "Mamu-A1*001:02"]
        let calls = [
            Self.call("S1", tie[0], 1_000, ambiguousWith: tie),
            Self.call("S1", tie[1], 1_000, ambiguousWith: tie),
            Self.call("S1", "Mamu-A1*002:01", 15),
            Self.call("S1", "Mamu-B*001:01", 300),
        ]
        XCTAssertEqual(GenotypeLocusDenominator.pooledKnownReads(calls: calls), 1_315)
        XCTAssertEqual(GenotypeLocusDenominator.pooledKnownReads(calls: Array(calls.prefix(3))), 1_015)
        XCTAssertEqual(GenotypeLocusDenominator.pooledKnownReads(calls: []), 0)
    }

    func testTheTieRuleIsPerAnimal() {
        let calls = Self.tiedClusterCalls(sample: "S1") + Self.tiedClusterCalls(sample: "S2")
        let denominator = GenotypeLocusDenominator(calls: calls)
        XCTAssertEqual(denominator.total(sample: "S1", sourceLocus: "MHC-A"), 1_015)
        XCTAssertEqual(denominator.total(sample: "S2", sourceLocus: "MHC-A"), 1_015)
    }

    /// Candidate clusters still add to the once-counted known total.
    func testCandidateReadsAddToTheOnceCountedKnownTotal() {
        let document = GenotypeLocusDenominatorFixtures.candidateDocument(
            candidates: [("novel", "Mamu-A1*900:01_nov", "MHC-A")],
            observations: [("novel", "S1", 85)]
        )
        let denominator = GenotypeLocusDenominator(calls: Self.tiedClusterCalls(), candidateDocument: document)
        XCTAssertEqual(denominator.total(sample: "S1", sourceLocus: "MHC-A"), 1_100)
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

    // MARK: D5b, one occurrence per animal, locus and allele

    /// Two rows for one animal and allele collapse to the highest-read row
    /// when the result is built, so the locus total counts that row once. The
    /// matrix-projection fixture's pair (reads 17 and 91) gives 91, not 108.
    func testADuplicateRowPairCountsItsKeptRowOnceInTheLocusTotal() throws {
        let result = GenotypeTestFixtures.makeResult(calls: [
            Self.call("AnimalA", "03_Mafa_B_075_01", 17),
            Self.call("AnimalA", "03_Mafa_B_075_01", 91),
        ])
        XCTAssertEqual(result.calls.map(\.passedUniqueReads), [91])
        let kept = try XCTUnwrap(result.calls.first)
        let denominator = GenotypeLocusDenominator(result: result)
        XCTAssertEqual(denominator.total(for: kept), 91, "the kept row counts once, the rows are never summed")
        XCTAssertEqual(try XCTUnwrap(denominator.fraction(for: kept)), 1, accuracy: 1e-12)
    }

    // MARK: D3, the basis a result's locus totals count

    private static func candidateDeclaration() -> ONTMHCCandidateArtifactManifest {
        ONTMHCCandidateArtifactManifest(
            schemaVersion: 2,
            genotypingEvidence: nil,
            reciprocalEvidence: nil,
            candidateJSON: ONTMHCArtifactReference(
                path: "candidate-alleles.json", sha256: String(repeating: "a", count: 64), sizeBytes: 1
            ),
            candidateFASTA: ONTMHCArtifactReference(
                path: "candidate_alleles.fasta", sha256: String(repeating: "b", count: 64), sizeBytes: 1
            ),
            unnameableJSON: nil,
            unnameableFASTA: nil
        )
    }

    /// The loader keeps its all-or-nothing contract. A full-length bundle whose
    /// manifest declares candidate artifacts while no candidate document
    /// loaded counts known alleles only, and every surface says so from this
    /// one basis.
    func testBasisIsKnownAllelesOnlyWhenDeclaredCandidateArtifactsWereRejected() {
        let rejected = GenotypeTestFixtures.makeResult(
            calls: [Self.call("S1", "Mamu-A1*001:01", 40)],
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            mhcCandidateArtifacts: Self.candidateDeclaration()
        )
        XCTAssertNil(rejected.mhcCandidates)
        XCTAssertEqual(GenotypeLocusDenominator.basis(for: rejected), .knownAllelesOnlyAfterRejectedCandidateArtifacts)
        XCTAssertEqual(
            GenotypeLocusDenominator.basisDescription(for: .knownAllelesOnlyAfterRejectedCandidateArtifacts),
            "Unique retained reads of the same sample at the same source locus "
                + "(known alleles only, because the bundle's candidate artifacts failed validation)"
        )
        XCTAssertEqual(
            GenotypeLocusDenominator.rejectedCandidateArtifactsDisclosure,
            "Candidate files failed validation, so candidate alleles are hidden and locus percents and "
                + "haplotype calls count known-allele reads only. These values can differ from the run's own workbook."
        )
    }

    func testBasisCountsCandidateClustersUnlessDeclaredArtifactsWereRejected() {
        let fullLength = GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue
        let calls = [Self.call("S1", "Mamu-A1*001:01", 40)]

        let undeclared = GenotypeTestFixtures.makeResult(calls: calls, kind: fullLength)
        XCTAssertEqual(GenotypeLocusDenominator.basis(for: undeclared), .knownAllelesAndCandidateClusters)
        XCTAssertEqual(
            GenotypeLocusDenominator.basisDescription(for: .knownAllelesAndCandidateClusters),
            GenotypeLocusDenominator.basisDescription
        )

        // Declared and loaded.
        let declared = GenotypeTestFixtures.makeResult(calls: calls, kind: fullLength, mhcCandidateArtifacts: Self.candidateDeclaration())
        let loaded = ONTGenotypeResultBundleData(
            bundleURL: declared.bundleURL, manifest: declared.manifest, artifacts: declared.artifacts,
            stats: declared.stats, calls: calls, samples: [], haplotypeAnalysis: nil,
            mhcCandidates: GenotypeLocusDenominatorFixtures.candidateDocument(
                candidates: [("novel", "Mamu-A1*900:01_nov", "MHC-A")], observations: [("novel", "S1", 60)]
            ),
            mhcUnnameableClusters: nil, mhcCandidateSequencesByStableClusterID: [:],
            integrityWarnings: [], referenceMetadata: nil
        )
        XCTAssertEqual(GenotypeLocusDenominator.basis(for: loaded), .knownAllelesAndCandidateClusters)

        // An amplicon bundle never loads candidate documents, so a declaration
        // there is not a rejection.
        let amplicon = GenotypeTestFixtures.makeResult(calls: calls, mhcCandidateArtifacts: Self.candidateDeclaration())
        XCTAssertEqual(GenotypeLocusDenominator.basis(for: amplicon), .knownAllelesAndCandidateClusters)
    }

    static func call(
        _ sample: String, _ genotype: String, _ reads: Int, ambiguousWith: [String]? = nil
    ) -> ONTGenotypeCall {
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
            overallUniqueRetainedPercent: nil,
            ambiguousWith: ambiguousWith
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
