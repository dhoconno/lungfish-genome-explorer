import Foundation
import XCTest
@testable import LungfishIO

final class ONTMHCCandidateAllelesV2Tests: XCTestCase {
    func testSchemaV4RawAndCanonicalBindingsRoundTripWhileLegacyPayloadsDefaultOneToOne() throws {
        let rawID = "raw-consensus-a"
        let representativeRawID = "raw-consensus-b"
        let reciprocal = try ONTMHCReciprocalQueryHitSummary(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: representativeRawID,
            alignmentCount: 1,
            targetAlignmentCounts: ["target-a": 1],
            exactMatchTargetNames: [],
            closestMatchTargetNames: ["target-a"]
        )
        let selected = ONTMHCEvidenceLocator(
            bamPath: reciprocal.bamPath,
            queryName: representativeRawID,
            referenceName: "target-a",
            readGroupID: nil,
            referenceStart: 1,
            cigar: "4="
        )
        let observation = ONTMHCCandidateObservation(
            stableClusterID: "canonical-a",
            sourceSequenceClusterID: rawID,
            sampleID: "SampleA",
            readGroupID: "SampleA",
            sourceClusterIDs: ["savont-1"],
            sourceClusterReadCounts: ["savont-1": 7],
            aggregatedSampleReadCount: 7,
            genotypingHitSummaries: []
        )
        let candidate = ONTMHCCandidateRecord(
            stableClusterID: "canonical-a",
            sourceSequenceClusterIDs: [rawID, representativeRawID],
            representativeSourceSequenceClusterID: representativeRawID,
            provisionalName: "Mafa-A1*001:01_1nt_nov",
            locus: "Mafa-A1",
            classification: .novel,
            supportClass: .shared,
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
            independentSampleCount: 2,
            occurrenceCount: 2,
            totalClusterReads: 12,
            supportingSampleIDs: ["SampleA", "SampleB"],
            fastaRecordID: "canonical-a",
            sequenceSHA256: String(repeating: "a", count: 64),
            reciprocalHitSummary: reciprocal,
            selectedEvidence: selected
        )

        let observationData = try JSONEncoder().encode(observation)
        let candidateData = try JSONEncoder().encode(candidate)
        let observationObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: observationData) as? [String: Any]
        )
        let candidateObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: candidateData) as? [String: Any]
        )

        XCTAssertEqual(observationObject["source_sequence_cluster_id"] as? String, rawID)
        XCTAssertEqual(
            candidateObject["source_sequence_cluster_ids"] as? [String],
            [rawID, representativeRawID]
        )
        XCTAssertEqual(
            candidateObject["representative_source_sequence_cluster_id"] as? String,
            representativeRawID
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ONTMHCCandidateObservation.self, from: observationData),
            observation
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ONTMHCCandidateRecord.self, from: candidateData),
            candidate
        )

        var legacyObservationObject = observationObject
        legacyObservationObject.removeValue(forKey: "source_sequence_cluster_id")
        let legacyObservation = try JSONDecoder().decode(
            ONTMHCCandidateObservation.self,
            from: JSONSerialization.data(withJSONObject: legacyObservationObject)
        )
        XCTAssertEqual(legacyObservation.sourceSequenceClusterID, legacyObservation.stableClusterID)

        var legacyCandidateObject = candidateObject
        legacyCandidateObject.removeValue(forKey: "source_sequence_cluster_ids")
        legacyCandidateObject.removeValue(forKey: "representative_source_sequence_cluster_id")
        let legacyCandidate = try JSONDecoder().decode(
            ONTMHCCandidateRecord.self,
            from: JSONSerialization.data(withJSONObject: legacyCandidateObject)
        )
        XCTAssertEqual(legacyCandidate.sourceSequenceClusterIDs, ["canonical-a"])
        XCTAssertEqual(legacyCandidate.representativeSourceSequenceClusterID, "canonical-a")
    }

    func testSchemaV4NonExportableUnnameableRecordOmitsExternalSequenceIdentity() throws {
        let record = ONTMHCUnnameableRecord(
            stableClusterID: "raw-unnameable",
            reason: .unresolvedLocus,
            failedMetrics: [:],
            supportClass: .singleton,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 4,
            supportingSampleIDs: ["SampleA"],
            reciprocalHitSummary: try ONTMHCReciprocalQueryHitSummary(
                bamPath: "artifacts/alignments/unmatched-to-reference.bam",
                queryName: "raw-unnameable",
                alignmentCount: 0,
                targetAlignmentCounts: [:],
                exactMatchTargetNames: [],
                closestMatchTargetNames: []
            ),
            selectedEvidence: nil
        )

        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(ONTMHCUnnameableRecord.self, from: data)

        XCTAssertNil(object["fasta_record_id"])
        XCTAssertNil(object["sequence_sha256"])
        XCTAssertNil(decoded.fastaRecordID)
        XCTAssertNil(decoded.sequenceSHA256)
    }

    func testSourceIdentityDocumentRoundTripsRawCanonicalReadiness() throws {
        let rawFASTA = ONTMHCArtifactReference(
            path: "artifacts/mhc-candidates/raw-unmatched.fasta",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 120
        )
        let record = ONTMHCCandidateSourceIdentityRecord(
            rawStableClusterID: "raw-a",
            rawSequenceSHA256: String(repeating: "b", count: 64),
            rawSequenceLength: 1_200,
            canonicalStableClusterID: "canonical-a",
            canonicalSequenceSHA256: String(repeating: "c", count: 64),
            trimStart: 100,
            trimEnd: 1_100,
            referenceReadiness: "reference-ready",
            classification: "extension",
            sampleIDs: ["SampleA", "SampleB"],
            isRepresentative: true
        )
        let document = ONTMHCCandidateSourceIdentityDocument(
            schemaVersion: 2,
            createdAt: "2026-07-23T00:00:00Z",
            rawSequenceFASTA: rawFASTA,
            records: [record]
        )

        let data = try JSONEncoder().encode(document)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])

        XCTAssertEqual(object["schema_version"] as? Int, 2)
        XCTAssertNotNil(object["raw_sequence_fasta"])
        XCTAssertEqual(records.first?["raw_stable_cluster_id"] as? String, "raw-a")
        XCTAssertEqual(records.first?["canonical_stable_cluster_id"] as? String, "canonical-a")
        XCTAssertEqual(records.first?["classification"] as? String, "extension")
        XCTAssertEqual(records.first?["sample_ids"] as? [String], ["SampleA", "SampleB"])
        XCTAssertEqual(records.first?["is_representative"] as? Bool, true)
        XCTAssertEqual(
            try JSONDecoder().decode(ONTMHCCandidateSourceIdentityDocument.self, from: data),
            document
        )
    }

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

    func testSelectedReciprocalOrientationRoundTripsForFreshCompactRecords() throws {
        let reciprocal = try ONTMHCReciprocalQueryHitSummary(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: "stable-1",
            alignmentCount: 1,
            targetAlignmentCounts: ["target-a": 1],
            exactMatchTargetNames: [],
            closestMatchTargetNames: ["target-a"]
        )
        let selected = reciprocalLocator(referenceName: "target-a")
        let candidate = makeCandidate(
            reciprocalHitSummary: reciprocal,
            selectedEvidence: selected,
            selectedAlignmentIsReverse: true
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
            selectedEvidence: selected,
            selectedAlignmentIsReverse: false
        )

        let candidateData = try JSONEncoder().encode(candidate)
        let candidateObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: candidateData) as? [String: Any]
        )
        XCTAssertEqual(candidateObject["selected_alignment_is_reverse"] as? Bool, true)
        XCTAssertEqual(
            try JSONDecoder().decode(ONTMHCCandidateRecord.self, from: candidateData)
                .selectedAlignmentIsReverse,
            true
        )

        let unnameableData = try JSONEncoder().encode(unnameable)
        XCTAssertEqual(
            try JSONDecoder().decode(ONTMHCUnnameableRecord.self, from: unnameableData)
                .selectedAlignmentIsReverse,
            false
        )
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
        selectedEvidence: ONTMHCEvidenceLocator,
        selectedAlignmentIsReverse: Bool? = nil
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
            selectedEvidence: selectedEvidence,
            selectedAlignmentIsReverse: selectedAlignmentIsReverse
        )
    }
}
