import Foundation
import XCTest
@testable import LungfishIO

final class ONTMHCCandidateAllelesV2Tests: XCTestCase {
    func testCompactGenotypingHitSummaryRoundTripsWithoutLegacyLocatorArray() throws {
        let summary = try ONTMHCGenotypingTargetHitSummary(
            bamPath: "artifacts/alignments/genotyping-evidence.bam",
            targetName: "SampleA|cluster-1",
            alignmentCount: 3,
            queryAlignmentCounts: ["NHP0001": 2, "NHP0002": 1],
            exactMatchQueryNames: ["NHP0001"],
            closestMatchQueryNames: ["NHP0001", "NHP0002"]
        )
        let observation = ONTMHCCandidateObservation(
            stableClusterID: "stable-1",
            sampleID: "SampleA",
            readGroupID: "SampleA",
            sourceClusterIDs: ["cluster-1"],
            sourceClusterReadCounts: ["cluster-1": 8],
            aggregatedSampleReadCount: 8,
            genotypingHitSummaries: [summary]
        )

        let data = try JSONEncoder().encode(observation)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(object["evidence"])
        XCTAssertNotNil(object["genotyping_hit_summaries"])
        XCTAssertEqual(summary.queryEdgeCount, 2)
        XCTAssertEqual(observation.genotypingAlignmentCount, 3)
        XCTAssertEqual(observation.genotypingEdgeCount, 2)
        XCTAssertEqual(
            try JSONDecoder().decode(ONTMHCCandidateObservation.self, from: data),
            observation
        )
    }

    func testHitSummaryInitializersRejectUnreconciledCountsAndUnknownRelationships() {
        XCTAssertThrowsError(try ONTMHCGenotypingTargetHitSummary(
            bamPath: "genotyping.bam",
            targetName: "SampleA|cluster-1",
            alignmentCount: 3,
            queryAlignmentCounts: ["query-a": 1],
            exactMatchQueryNames: [],
            closestMatchQueryNames: []
        ))
        XCTAssertThrowsError(try ONTMHCReciprocalQueryHitSummary(
            bamPath: "reciprocal.bam",
            queryName: "stable-1",
            alignmentCount: 1,
            targetAlignmentCounts: ["target-a": 1],
            exactMatchTargetNames: ["missing-target"],
            closestMatchTargetNames: ["target-a"]
        ))
    }

    func testLegacyEvidenceArraysDecodeIntoCompactHitSummaries() throws {
        let observationData = Data(#"""
        {
          "stable_cluster_id": "stable-1",
          "sample_id": "SampleA",
          "read_group_id": "SampleA",
          "source_cluster_ids": ["cluster-1"],
          "source_cluster_read_counts": {"cluster-1": 8},
          "aggregated_sample_read_count": 8,
          "evidence": [
            {
              "bam_path": "artifacts/alignments/genotyping-evidence.bam",
              "query_name": "query-a",
              "reference_name": "SampleA|cluster-1",
              "read_group_id": "SampleA",
              "reference_start": 1,
              "cigar": "4="
            },
            {
              "bam_path": "artifacts/alignments/genotyping-evidence.bam",
              "query_name": "query-b",
              "reference_name": "SampleA|cluster-1",
              "read_group_id": "SampleA",
              "reference_start": 2,
              "cigar": "4="
            }
          ]
        }
        """#.utf8)

        let observation = try JSONDecoder().decode(
            ONTMHCCandidateObservation.self,
            from: observationData
        )

        XCTAssertEqual(observation.evidence.count, 2)
        XCTAssertEqual(observation.genotypingHitSummaries.count, 1)
        XCTAssertEqual(observation.genotypingHitSummaries.first?.alignmentCount, 2)
        XCTAssertEqual(
            observation.genotypingHitSummaries.first?.queryAlignmentCounts,
            ["query-a": 1, "query-b": 1]
        )

        let legacyUnnameable = ONTMHCUnnameableRecord(
            stableClusterID: "stable-1",
            reason: .insufficientIdentity,
            failedMetrics: ["identity": 0.5],
            supportClass: .singleton,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 8,
            supportingSampleIDs: ["SampleA"],
            fastaRecordID: "stable-1",
            sequenceSHA256: String(repeating: "a", count: 64),
            evidence: [reciprocalLocator(referenceName: "target-a")]
        )
        let decodedUnnameable = try JSONDecoder().decode(
            ONTMHCUnnameableRecord.self,
            from: JSONEncoder().encode(legacyUnnameable)
        )

        XCTAssertEqual(decodedUnnameable.evidence.count, 1)
        XCTAssertEqual(decodedUnnameable.reciprocalHitSummary.alignmentCount, 1)
        XCTAssertEqual(decodedUnnameable.reciprocalHitSummary.targetAlignmentCounts, ["target-a": 1])
        XCTAssertNil(decodedUnnameable.selectedEvidence)
    }

    func testCompactCandidateAndUnnameableEncodingOmitBulkEvidence() throws {
        let reciprocal = try ONTMHCReciprocalQueryHitSummary(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: "stable-1",
            alignmentCount: 2,
            targetAlignmentCounts: ["target-a": 1, "target-b": 1],
            exactMatchTargetNames: [],
            closestMatchTargetNames: ["target-a"]
        )
        let selected = reciprocalLocator(referenceName: "target-a")
        let candidate = makeCandidate(
            reciprocalHitSummary: reciprocal,
            selectedEvidence: selected
        )
        let unnameable = ONTMHCUnnameableRecord(
            stableClusterID: "stable-1",
            reason: .insufficientIdentity,
            failedMetrics: ["identity": 0.5],
            supportClass: .singleton,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 8,
            supportingSampleIDs: ["SampleA"],
            fastaRecordID: "stable-1",
            sequenceSHA256: String(repeating: "a", count: 64),
            reciprocalHitSummary: reciprocal,
            selectedEvidence: nil
        )

        let candidateObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any]
        )
        let unnameableObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(unnameable)) as? [String: Any]
        )

        XCTAssertNotNil(candidateObject["reciprocal_hit_summary"])
        XCTAssertNotNil(candidateObject["selected_evidence"])
        XCTAssertNil(candidateObject["evidence"])
        XCTAssertNotNil(unnameableObject["reciprocal_hit_summary"])
        XCTAssertNil(unnameableObject["selected_evidence"])
        XCTAssertNil(unnameableObject["evidence"])
        XCTAssertEqual(candidate.reciprocalAlignmentCount, 2)
        XCTAssertEqual(candidate.reciprocalEdgeCount, 2)
        XCTAssertEqual(unnameable.reciprocalAlignmentCount, 2)
        XCTAssertEqual(unnameable.reciprocalEdgeCount, 2)
    }

    private func reciprocalLocator(referenceName: String) -> ONTMHCEvidenceLocator {
        ONTMHCEvidenceLocator(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: "stable-1",
            referenceName: referenceName,
            readGroupID: nil,
            referenceStart: 1,
            cigar: "4="
        )
    }

    private func makeCandidate(
        reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary,
        selectedEvidence: ONTMHCEvidenceLocator
    ) -> ONTMHCCandidateRecord {
        ONTMHCCandidateRecord(
            stableClusterID: "stable-1",
            provisionalName: "Mafa-A1*001:01_1nt_nov",
            locus: "Mafa-A1",
            classification: .novel,
            supportClass: .singleton,
            closestReferenceName: "Mafa-A1*001:01",
            closestReferenceClass: .genomicDNA,
            snpCount: 1,
            insertedBases: 0,
            deletedBases: 0,
            longGapBases: 0,
            comparableBases: 4,
            shorterCoverage: 1,
            identity: 0.75,
            mappingQuality: 60,
            alignmentScore: 3,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 8,
            supportingSampleIDs: ["SampleA"],
            fastaRecordID: "stable-1",
            sequenceSHA256: String(repeating: "a", count: 64),
            reciprocalHitSummary: reciprocalHitSummary,
            selectedEvidence: selectedEvidence
        )
    }
}
