import XCTest
@testable import LungfishGenotypeUI
import LungfishIO
import LungfishTestSupport

/// GEN-05 (D13) and GEN-06 (D14) acceptance: the matrix, the haplotype
/// evidence pane and the haplotype caller give the same percentage for the
/// same allele, and "Min percent" is a per-sample read fraction for known and
/// candidate rows alike, with prevalence as its own control.
@MainActor
final class GenotypeLocusDenominatorAgreementTests: GenotypeResultViewportTestCase {
    private static let gGenotypes = [
        "MCM_MHC_MiSeq_0003|source_loci=MHC-G|haplotype_groups=MHC-A|haplotypes=M1|alleles=Mafa-G_02:14:01:01",
        "MCM_MHC_MiSeq_0004|source_loci=MHC-G|haplotype_groups=MHC-A|haplotypes=M2|alleles=Mafa-G_02:31:01:01",
    ]

    /// Audit worked example: A1 3,000, AG 2,000, E 1,500 and two G alleles
    /// of 75 each, all filed under haplotype_groups=MHC-A.
    private static func workedExampleCalls() -> [ONTGenotypeCall] {
        [
            GenotypeTestFixtures.makeCall(sample: "LF1", genotype: "MCM_MHC_MiSeq_0101|source_loci=MHC-A1|haplotype_groups=MHC-A|haplotypes=M1|alleles=Mafa-A1_063:01", reads: 3_000),
            GenotypeTestFixtures.makeCall(sample: "LF1", genotype: "MCM_MHC_MiSeq_0102|source_loci=MHC-AG1|haplotype_groups=MHC-A|haplotypes=M1|alleles=Mafa-AG_05:02", reads: 2_000),
            GenotypeTestFixtures.makeCall(sample: "LF1", genotype: "MCM_MHC_MiSeq_0103|source_loci=MHC-E|haplotype_groups=MHC-A|haplotypes=M1|alleles=Mafa-E_02:19", reads: 1_500),
            GenotypeTestFixtures.makeCall(sample: "LF1", genotype: gGenotypes[0], reads: 75),
            GenotypeTestFixtures.makeCall(sample: "LF1", genotype: gGenotypes[1], reads: 75),
        ]
    }

    func testMatrixEvidencePaneAndCallerAgreeOnEachGAllelePercentage() throws {
        let calls = Self.workedExampleCalls()

        // Matrix ("Source Locus" percent basis).
        let projection = GenotypeMatrixBaseProjection(
            calls: calls,
            samples: [],
            candidateDocument: nil,
            logicalSampleNames: ["LF1"],
            candidateSettings: .default
        )
        let matrixFractions = projection.supportFractions(for: .viewedLocus)
        var matrixPercentByG: [String: Double] = [:]
        for genotype in Self.gGenotypes {
            let identity = GenotypeMatrixBaseProjection.CellIdentity(
                locus: "MHC-G", genotype: genotype, sample: "LF1", stableClusterID: nil
            )
            matrixPercentByG[genotype] = try XCTUnwrap(matrixFractions[identity])
        }
        let visibleAtFive = projection.derive(.init(matrixMinimumPercent: 5)).rows.map(\.genotype)
        XCTAssertTrue(Set(Self.gGenotypes).isSubset(of: Set(visibleAtFive)))

        // Haplotype evidence pane.
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "worked-example",
            definitionSetName: "Worked example",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(sample: "LF1", calls: [
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-A",
                        sourceLocus: "MHC-A",
                        haplotype1: "M1A",
                        haplotype2: "M2A",
                        status: .called,
                        matchedHaplotypes: [],
                        observedGenotypeCount: 2,
                        observedGenotypes: Self.gGenotypes
                    ),
                ]),
            ]
        )
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))
        let evidence = try XCTUnwrap(controller.callEvidence(sample: "LF1", locus: "MHC-A"))
        var panePercentByG: [String: Double] = [:]
        for allele in evidence.diagnosticAlleles where Self.gGenotypes.contains(allele.allele) {
            panePercentByG[allele.allele] = allele.percentOfLocus
        }

        // Haplotype caller: the locus fraction boundary sits at exactly the
        // matrix percentage (kept at 50%, dropped just above it).
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "worked-example",
            assayID: "MHC-exon2-miSeq",
            displayName: "Worked example",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(locus: "MHC-A", sourceLocus: "MHC-A", haplotypes: [
                    GenotypeHaplotypeDefinition(name: "M1A", diagnosticAlleles: ["MCM_MHC_MiSeq_0003"], minimumMatches: 1),
                    GenotypeHaplotypeDefinition(name: "M2A", diagnosticAlleles: ["MCM_MHC_MiSeq_0004"], minimumMatches: 1),
                ]),
            ]
        )
        func callerKeeps(_ genotype: String, locusFraction: Double) -> Bool {
            GenotypeHaplotypeAnalyzer.analyze(
                calls: calls,
                definitionSet: definition,
                dropoutFilter: GenotypeDropoutEvaluator(absolute: nil, sampleFraction: nil, locusFraction: locusFraction)
            ).samples.first?.calls.first { $0.locus == "MHC-A" }?.observedGenotypes.contains(genotype) == true
        }

        for genotype in Self.gGenotypes {
            let matrix = try XCTUnwrap(matrixPercentByG[genotype])
            let pane = try XCTUnwrap(panePercentByG[genotype])
            XCTAssertEqual(matrix, 0.5, accuracy: 1e-12, genotype)
            XCTAssertEqual(pane, matrix, accuracy: 1e-12, genotype)
            XCTAssertTrue(callerKeeps(genotype, locusFraction: 0.05), genotype)
            XCTAssertTrue(callerKeeps(genotype, locusFraction: matrix), genotype)
            XCTAssertFalse(callerKeeps(genotype, locusFraction: matrix + 0.0001), genotype)
        }
    }

    // MARK: GEN-06 (D14)

    /// 30 animals. A01 carries a private novel allele at 60% of its MHC-A1
    /// reads; A02 and A03 share a candidate at 0.2% each (a chimera or
    /// cross-talk profile). Every animal has a known allele at the locus.
    private static func cohort() -> (calls: [ONTGenotypeCall], candidates: ONTMHCCandidateAllelesDocument, animals: [String]) {
        let animals = (1...30).map { String(format: "A%02d", $0) }
        let calls = animals.map { animal -> ONTGenotypeCall in
            let reads: Int
            switch animal {
            case "A01": reads = 40
            case "A02", "A03": reads = 998
            default: reads = 1_000
            }
            return GenotypeTestFixtures.makeCall(sample: animal, genotype: "Mafa-A1*001:01", reads: reads)
        }
        let document = GenotypeCandidateCohortFixture.candidateDocument(
            candidates: [
                ("private", "Mafa-A1*900:01_nov", "MHC-A1"),
                ("shared", "Mafa-A1*901:01_nov", "MHC-A1"),
            ],
            observations: [
                ("private", "A01", 60),
                ("shared", "A02", 2),
                ("shared", "A03", 2),
            ]
        )
        return (calls, document, animals)
    }

    func testMinPercentIsAPerSampleReadFractionForCandidateRows() throws {
        let cohort = Self.cohort()
        let projection = GenotypeMatrixBaseProjection(
            calls: cohort.calls,
            samples: [],
            candidateDocument: cohort.candidates,
            logicalSampleNames: cohort.animals,
            candidateSettings: .default
        )
        let fractions = projection.supportFractions(for: .viewedLocus)
        XCTAssertEqual(try XCTUnwrap(fractions[.init(locus: "MHC-A1", genotype: "Mafa-A1*900:01_nov", sample: "A01", stableClusterID: "private")]), 0.6, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(fractions[.init(locus: "MHC-A1", genotype: "Mafa-A1*901:01_nov", sample: "A02", stableClusterID: "shared")]), 0.002, accuracy: 1e-12)

        let minFive = projection.derive(.init(matrixMinimumPercent: 5))
        let privateRow = try XCTUnwrap(minFive.rows.first { $0.stableClusterID == "private" })
        XCTAssertEqual(privateRow.sampleSupport.map(\.sample), ["A01"])
        XCTAssertNil(minFive.rows.first { $0.stableClusterID == "shared" }, "0.2% cross-talk is hidden")
        XCTAssertEqual(minFive.rows.first { $0.genotype == "Mafa-A1*001:01" }?.sampleCount, 30)
    }

    func testSeenInAnimalsIsASeparatePrevalenceControl() throws {
        let cohort = Self.cohort()
        let projection = GenotypeMatrixBaseProjection(
            calls: cohort.calls,
            samples: [],
            candidateDocument: cohort.candidates,
            logicalSampleNames: cohort.animals,
            candidateSettings: .default
        )
        let withPrevalence = projection.derive(.init(matrixMinimumPercent: 5, minimumPrevalencePercent: 5))
        XCTAssertNil(withPrevalence.rows.first { $0.stableClusterID == "private" }, "1 of 30 animals is 3.3%")
        XCTAssertNil(withPrevalence.rows.first { $0.stableClusterID == "shared" })
        XCTAssertEqual(withPrevalence.rows.first { $0.genotype == "Mafa-A1*001:01" }?.sampleCount, 30)

        // Prevalence alone keeps a candidate seen in 2 of 30 animals (6.7%).
        let prevalenceOnly = projection.derive(.init(minimumPrevalencePercent: 5))
        XCTAssertNotNil(prevalenceOnly.rows.first { $0.stableClusterID == "shared" })
        XCTAssertNil(prevalenceOnly.rows.first { $0.stableClusterID == "private" })

        // Off by default.
        XCTAssertEqual(GenotypeMatrixBaseProjection.Filter().minimumPrevalencePercent, 0)
        XCTAssertEqual(GenotypeResultDisplayState().matrixMinimumPrevalencePercent, 0)
    }

    func testFilterDecodesCapturesMadeBeforeThePrevalenceControl() throws {
        let legacy = #"{"globalDenominator":"viewedLocus","globalMinimumPercent":0,"matrixDenominator":"sampleRetained","matrixMinimumPercent":2,"matrixMinimumReads":5}"#
        let decoded = try JSONDecoder().decode(GenotypeMatrixBaseProjection.Filter.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded, .init(matrixMinimumReads: 5, matrixMinimumPercent: 2, matrixDenominator: .sampleRetained))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(decoded), as: UTF8.self), legacy)
        let withPrevalence = GenotypeMatrixBaseProjection.Filter(minimumPrevalencePercent: 5)
        XCTAssertEqual(
            try JSONDecoder().decode(GenotypeMatrixBaseProjection.Filter.self, from: encoder.encode(withPrevalence)),
            withPrevalence
        )
    }
}

enum GenotypeCandidateCohortFixture {
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
                    closestReferenceName: "Mafa-A1*001:01",
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
                        referenceName: "Mafa-A1*001:01",
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
