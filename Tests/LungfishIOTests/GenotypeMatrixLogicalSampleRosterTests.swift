import XCTest
import LungfishTestSupport
@testable import LungfishIO

/// The one sample roster the comparison matrix shows as columns and that
/// prevalence and the Samples and Unique Reads columns count over, in the GUI
/// and the Excel builder alike (Phase 2.3 decision D1, finding T2).
final class GenotypeMatrixLogicalSampleRosterTests: XCTestCase {
    /// Run samples in result order, then call samples the summary lacks in
    /// first-seen order, then the animals the displayed candidate and the
    /// interpreted incomplete-span observations name, sorted, then catalog
    /// animals in catalog order. An animal named only by the haplotype
    /// analysis or only by an uninterpreted un-nameable cluster is left out.
    func testRosterOrdersRunCallObservationAndCatalogAnimalsAndLeavesOutAnalysisOnlyNames() throws {
        let calls = [
            GenotypeTestFixtures.makeCall(sample: "Run2", genotype: "01_Mafa_A1_001_01", reads: 9),
            GenotypeTestFixtures.makeCall(sample: "CallOnly", genotype: "01_Mafa_A1_001_01", reads: 3),
            GenotypeTestFixtures.makeCall(sample: "Run1", genotype: "03_Mafa_B_075_01", reads: 12),
        ]
        let candidates = GenotypeLocusDenominatorFixtures.candidateDocument(
            candidates: [("shared-1", "Mafa-A1*900:01_nov", "MHC-A1")],
            observations: [("shared-1", "Zeta", 6), ("shared-1", "Run1", 4), ("shared-1", "Alpha", 2)]
        )
        let unnameable = ONTMHCUnnameableClustersDocument(
            schemaVersion: 1,
            createdAt: "2026-07-20T00:00:00Z",
            thresholds: .defaults,
            sequenceFASTA: .init(path: "unnameable.fasta", sha256: String(repeating: "a", count: 64), sizeBytes: 1),
            clusters: [
                try unnameableRecord(id: "span-3", reason: .incompleteReferenceSpan, interpreting: candidates.candidates[0]),
                try unnameableRecord(id: "plain-5", reason: .noAlignment, interpreting: nil),
            ],
            observations: [
                observation(cluster: "span-3", sample: "Span"),
                observation(cluster: "plain-5", sample: "Ghost"),
            ]
        )
        let result = makeResult(
            calls: calls, samples: ["Run1", "Run2"], analysisSamples: ["AnalysisOnly", "Run1"],
            candidates: candidates, unnameable: unnameable, catalogSamples: ["Run1", "CatalogOnly", "Zeta"]
        )

        XCTAssertEqual(
            GenotypeMatrixBaseProjection.logicalSampleRoster(result: result, candidateDocument: candidates),
            ["Run1", "Run2", "CallOnly", "Alpha", "Span", "Zeta", "CatalogOnly"]
        )
        // The candidate document is the one the caller displays. Without it
        // the candidate observations name nobody, and Zeta enters through the
        // catalog instead.
        XCTAssertEqual(
            GenotypeMatrixBaseProjection.logicalSampleRoster(result: result, candidateDocument: nil),
            ["Run1", "Run2", "CallOnly", "Span", "CatalogOnly", "Zeta"]
        )
    }

    /// A bundle from a current pipeline names every animal in its sample
    /// summary, and its analysis names the same animals, so the roster is the
    /// summary in its own order.
    func testRosterIsTheSampleSummaryWhenNoOtherSourceNamesAnotherAnimal() {
        let calls = [
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: "01_Mafa_A1_001_01", reads: 9),
            GenotypeTestFixtures.makeCall(sample: "S2", genotype: "01_Mafa_A1_001_01", reads: 0),
        ]
        let result = makeResult(
            calls: calls, samples: ["S2", "S1"], analysisSamples: ["S1", "S2"],
            candidates: nil, unnameable: nil, catalogSamples: ["S1", "S2"]
        )
        XCTAssertEqual(GenotypeMatrixBaseProjection.logicalSampleRoster(result: result, candidateDocument: nil), ["S2", "S1"])
    }

    private func makeResult(
        calls: [ONTGenotypeCall],
        samples: [String],
        analysisSamples: [String],
        candidates: ONTMHCCandidateAllelesDocument?,
        unnameable: ONTMHCUnnameableClustersDocument?,
        catalogSamples: [String]
    ) -> ONTGenotypeResultBundleData {
        let base = GenotypeTestFixtures.makeResult(calls: calls)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq", definitionSetID: "roster", definitionSetName: "Roster",
            speciesName: "Test macaque", generatedAt: "2026-10-09T00:00:00Z", analysisRevisionID: "roster-1",
            source: .deterministic, samples: analysisSamples.map { .init(sample: $0, calls: []) }
        )
        return ONTGenotypeResultBundleData(
            bundleURL: base.bundleURL, manifest: base.manifest, artifacts: base.artifacts, stats: base.stats,
            calls: calls,
            samples: samples.map {
                ONTGenotypeSampleResult(sample: $0, passedAlignments: 0, passedUniqueReads: 0,
                                        sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [])
            },
            haplotypeAnalysis: analysis, mhcCandidates: candidates, mhcUnnameableClusters: unnameable,
            mhcCandidateSequencesByStableClusterID: [:], mhcCandidateGenBankArtifactURLs: .empty,
            mhcAlignmentArtifactURLs: .empty, mhcReferenceVisualizations: nil, integrityWarnings: [],
            referenceMetadata: nil, provisionalExon2SequencesByGenotype: [:], provisionalExon2ArtifactURLs: .empty,
            reviewableRowCatalog: GenotypeReviewableRowCatalog(samples: catalogSamples, rows: [])
        )
    }

    private func observation(cluster: String, sample: String) -> ONTMHCCandidateObservation {
        ONTMHCCandidateObservation(
            stableClusterID: cluster, sampleID: sample, readGroupID: sample, sourceClusterIDs: ["source-\(cluster)"],
            sourceClusterReadCounts: ["source-\(cluster)": 5], aggregatedSampleReadCount: 5, evidence: []
        )
    }

    private func unnameableRecord(
        id: String,
        reason: ONTMHCUnnameableReason,
        interpreting candidate: ONTMHCCandidateRecord?
    ) throws -> ONTMHCUnnameableRecord {
        ONTMHCUnnameableRecord(
            stableClusterID: id,
            reason: reason,
            failedMetrics: ["reference_span": 0.5],
            supportClass: .shared,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 5,
            supportingSampleIDs: ["Span"],
            fastaRecordID: id,
            sequenceSHA256: String(repeating: "b", count: 64),
            reciprocalHitSummary: try ONTMHCReciprocalQueryHitSummary(
                bamPath: "unmatched.bam",
                queryName: id,
                alignmentCount: 1,
                targetAlignmentCounts: ["reference": 1],
                exactMatchTargetNames: [],
                closestMatchTargetNames: ["reference"]
            ),
            selectedEvidence: nil,
            selectedAlignmentIsReverse: nil,
            candidateInterpretation: candidate.map(ONTMHCIncompleteCandidateInterpretation.init(candidate:))
        )
    }
}
