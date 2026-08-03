import CryptoKit
import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class FullLengthONTMHCCandidateArtifactWriterTests: XCTestCase {
    func testCanonicalizesFlankVariantsIntoOneTrimmedCandidateAndKeepsRawEvidenceBindings() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let codingSequence = String(repeating: "A", count: 600)
            + "C"
            + String(repeating: "A", count: 599)
        let firstSequence = "TT" + codingSequence + "GG"
        let secondSequence = "CC" + codingSequence + "AA"
        let thirdSequence = "GG" + codingSequence + "TT"
        let firstRawID = stableID(firstSequence)
        let secondRawID = stableID(secondSequence)
        let thirdRawID = stableID(thirdSequence)
        let observations = fixture.observations + [
            FullLengthONTMHCCandidateSequenceObservation(
                sampleID: "sample-a",
                readGroupID: "sample-a",
                sourceClusterID: "source-a",
                clusterReadCount: 7,
                sequence: firstSequence,
                genotypingHitSummaries: []
            ),
            FullLengthONTMHCCandidateSequenceObservation(
                sampleID: "sample-b",
                readGroupID: "sample-b",
                sourceClusterID: "source-b",
                clusterReadCount: 11,
                sequence: secondSequence,
                genotypingHitSummaries: []
            ),
            FullLengthONTMHCCandidateSequenceObservation(
                sampleID: "sample-a",
                readGroupID: "sample-a",
                sourceClusterID: "source-a-duplicate",
                clusterReadCount: 3,
                sequence: firstSequence,
                genotypingHitSummaries: []
            ),
            FullLengthONTMHCCandidateSequenceObservation(
                sampleID: "sample-a",
                readGroupID: "sample-a",
                sourceClusterID: "source-a-flank-variant",
                clusterReadCount: 13,
                sequence: thirdSequence,
                genotypingHitSummaries: []
            ),
        ]
        fixture.additionalSAM = """
        \(firstRawID)\t0\tref-genomic\t1\t60\t2S595=5X600=2S\t*\t0\t0\t*\t*\tNM:i:5\tAS:i:1190
        \(secondRawID)\t0\tref-genomic\t1\t60\t2S595=5X600=2S\t*\t0\t0\t*\t*\tNM:i:5\tAS:i:1190
        \(thirdRawID)\t0\tref-genomic\t1\t60\t2S595=5X600=2S\t*\t0\t0\t*\t*\tNM:i:5\tAS:i:1190

        """

        let result = try await fixture.write(
            observations: observations,
            canonicalizationProvider: { input in
                try Fixture.referenceReadyCanonicalization(
                    input: input,
                    trimRange: 2..<(input.sequence.count - 2),
                    substitutionCountOverride: 6
                )
            }
        )

        let document = try JSONDecoder().decode(
            ONTMHCCandidateAllelesDocument.self,
            from: Data(contentsOf: result.candidateJSONURL)
        )
        let candidate = try XCTUnwrap(document.candidates.first {
            $0.stableClusterID == stableID(codingSequence)
        })
        let canonicalID = stableID(codingSequence)
        XCTAssertEqual(candidate.stableClusterID, canonicalID)
        XCTAssertEqual(candidate.fastaRecordID, canonicalID)
        XCTAssertEqual(candidate.sequenceSHA256, sha256HexString(codingSequence))
        XCTAssertEqual(candidate.independentSampleCount, 2)
        XCTAssertEqual(candidate.supportClass, .shared)
        XCTAssertEqual(candidate.occurrenceCount, 4)
        XCTAssertEqual(candidate.totalClusterReads, 34)
        XCTAssertEqual(candidate.snpCount, 6)
        XCTAssertEqual(
            candidate.provisionalName,
            "\(candidate.closestReferenceName)_6nt_nov"
        )
        XCTAssertEqual(
            Set(candidate.sourceSequenceClusterIDs),
            Set([firstRawID, secondRawID, thirdRawID])
        )
        XCTAssertEqual(candidate.representativeSourceSequenceClusterID, thirdRawID)
        XCTAssertEqual(candidate.selectedEvidence.queryName, thirdRawID)
        XCTAssertEqual(candidate.reciprocalHitSummary.queryName, thirdRawID)
        let canonicalObservations = document.observations.filter {
            $0.stableClusterID == canonicalID
        }
        XCTAssertEqual(canonicalObservations.count, 2)
        XCTAssertEqual(Set(canonicalObservations.map(\.sampleID)), ["sample-a", "sample-b"])
        let sampleAObservation = try XCTUnwrap(canonicalObservations.first {
            $0.sampleID == "sample-a"
        })
        XCTAssertEqual(sampleAObservation.aggregatedSampleReadCount, 23)
        XCTAssertEqual(
            Set(sampleAObservation.sourceClusterIDs),
            ["source-a", "source-a-duplicate", "source-a-flank-variant"]
        )
        let unnameable = try JSONDecoder().decode(
            ONTMHCUnnameableClustersDocument.self,
            from: Data(contentsOf: result.unnameableJSONURL)
        )
        XCTAssertNoThrow(try FullLengthONTMHCWorkbookProjection(
            candidateDocument: document,
            unnameableDocument: unnameable,
            sampleOrder: ["sample-a", "sample-b"]
        ))
        let candidateFASTA = try Dictionary(
            uniqueKeysWithValues: zip(
                fastaHeaders(result.candidateFASTAURL),
                fastaSequences(result.candidateFASTAURL)
            )
        )
        XCTAssertEqual(candidateFASTA[canonicalID], codingSequence)
        let candidateGenBankRecord = try XCTUnwrap(
            try GenBankReader(url: result.candidateGenBankURL).readAllSync().first {
                $0.accession == canonicalID
            }
        )
        XCTAssertTrue(
            candidateGenBankRecord.definition?.hasPrefix(
                candidate.provisionalName + ";"
            ) == true
        )
        XCTAssertFalse(
            candidateGenBankRecord.definition?.contains("_5nt_nov") == true
        )
        let source = try XCTUnwrap(candidateGenBankRecord.annotations.first {
            $0.type == .source
        })
        XCTAssertEqual(source.qualifier("stable_cluster_id"), canonicalID)
        XCTAssertEqual(source.qualifier("fasta_record_id"), canonicalID)
        XCTAssertEqual(
            source.qualifiers["source_sequence_cluster_ids"]?.values,
            [firstRawID, secondRawID, thirdRawID].sorted()
        )
        XCTAssertEqual(source.qualifier("representative_source_sequence_cluster_id"), thirdRawID)
        XCTAssertEqual(source.qualifier("support_class"), "shared")
        XCTAssertEqual(source.qualifier("independent_sample_count"), "2")
        XCTAssertEqual(source.qualifier("occurrence_count"), "4")
        XCTAssertEqual(source.qualifier("total_cluster_reads"), "34")
        XCTAssertEqual(source.qualifiers["supporting_sample_ids"]?.values, ["sample-a", "sample-b"])
        XCTAssertEqual(source.qualifier("sequence_sha256"), sha256HexString(codingSequence))
        XCTAssertEqual(source.qualifier("genbank_sequence_sha256"), sha256HexString(codingSequence))
        XCTAssertEqual(source.qualifier("original_sequence_length"), String(codingSequence.count))
        XCTAssertEqual(source.qualifier("trim_start"), "1")
        XCTAssertEqual(source.qualifier("trim_end"), String(codingSequence.count))
        let comments = candidateGenBankRecord.recordFields
            .filter { $0.key == "COMMENT" }
            .map(\.value)
        XCTAssertTrue(comments.contains("Lungfish stable cluster ID: \(canonicalID)"))
        XCTAssertTrue(comments.contains("Lungfish sequence SHA-256: \(sha256HexString(codingSequence))"))
        XCTAssertTrue(comments.contains(
            "Lungfish support: shared; independent samples=2; occurrences=4; reads=34"
        ))
        XCTAssertTrue(comments.contains("Lungfish supporting samples: sample-a, sample-b"))
        XCTAssertTrue(comments.contains(
            "Lungfish source sequence cluster IDs: \([firstRawID, secondRawID, thirdRawID].sorted().joined(separator: ", "))"
        ))
        XCTAssertTrue(comments.contains(
            "Lungfish representative source sequence cluster ID: \(thirdRawID)"
        ))
        XCTAssertFalse(comments.contains("Lungfish stable cluster ID: \(firstRawID)"))
        XCTAssertFalse(comments.contains("Lungfish stable cluster ID: \(secondRawID)"))
        XCTAssertFalse(comments.contains("Lungfish stable cluster ID: \(thirdRawID)"))
        XCTAssertFalse(comments.contains {
            $0.contains("original length=\(firstSequence.count)")
        })
        XCTAssertEqual(result.manifest.schemaVersion, 2)
        XCTAssertEqual(
            result.manifest.rawUnmatchedFASTA?.path,
            "artifacts/internal/raw-unmatched-consensuses.fasta"
        )
        XCTAssertEqual(
            result.manifest.sourceIdentityMap?.path,
            "artifacts/internal/mhc-candidate-source-map.json"
        )
        let sourceMap = try JSONDecoder().decode(
            ONTMHCCandidateSourceIdentityDocument.self,
            from: Data(contentsOf: fixture.outputURL.appendingPathComponent(
                "artifacts/internal/mhc-candidate-source-map.json"
            ))
        )
        XCTAssertEqual(sourceMap.schemaVersion, 2)
        let identities = Dictionary(
            uniqueKeysWithValues: sourceMap.records.map { ($0.rawStableClusterID, $0) }
        )
        XCTAssertEqual(identities[firstRawID]?.classification, "novel")
        XCTAssertEqual(identities[firstRawID]?.sampleIDs, ["sample-a"])
        XCTAssertEqual(identities[firstRawID]?.isRepresentative, false)
        XCTAssertEqual(identities[secondRawID]?.classification, "novel")
        XCTAssertEqual(identities[secondRawID]?.sampleIDs, ["sample-b"])
        XCTAssertEqual(identities[secondRawID]?.isRepresentative, false)
        XCTAssertEqual(identities[thirdRawID]?.classification, "novel")
        XCTAssertEqual(identities[thirdRawID]?.sampleIDs, ["sample-a"])
        XCTAssertEqual(identities[thirdRawID]?.isRepresentative, true)
    }

    func testRejectsIdenticalTrimmedSequenceWithNovelAndExtensionInterpretations() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let codingSequence = String(repeating: "ACGT", count: 300)
        let novelSequence = "TT" + codingSequence + "GG"
        let extensionSequence = "CC" + codingSequence + "AA"
        let novelRawID = stableID(novelSequence)
        let extensionRawID = stableID(extensionSequence)
        fixture.additionalSAM = """
        \(novelRawID)\t0\tref-genomic\t1\t60\t2S595=5X600=2S\t*\t0\t0\t*\t*\tNM:i:5\tAS:i:1190
        \(extensionRawID)\t0\tref-cdna\t1\t60\t2S500=200I500=2S\t*\t0\t0\t*\t*\tNM:i:200\tAS:i:1000

        """
        let observations = fixture.observations + [
            .init(
                sampleID: "sample-c",
                readGroupID: "sample-c",
                sourceClusterID: "source-c",
                clusterReadCount: 9,
                sequence: novelSequence,
                genotypingHitSummaries: []
            ),
            .init(
                sampleID: "sample-d",
                readGroupID: "sample-d",
                sourceClusterID: "source-d",
                clusterReadCount: 8,
                sequence: extensionSequence,
                genotypingHitSummaries: []
            ),
        ]

        do {
            _ = try await fixture.write(
                observations: observations,
                canonicalizationProvider: { input in
                    try Fixture.referenceReadyCanonicalization(
                        input: input,
                        trimRange: 2..<(input.sequence.count - 2)
                    )
                }
            )
            XCTFail("Expected conflicting canonical interpretation rejection")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("conflicting biological interpretations"),
                error.localizedDescription
            )
        }
    }

    func testUnnameableFASTAProvenanceCountsOnlyReferenceReadyExports() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let unavailableSequence = String(repeating: "T", count: 910)
        let unavailableID = stableID(unavailableSequence)
        fixture.additionalSAM = "\(unavailableID)\t4\t*\t0\t0\t*\t*\t0\t0\t*\t*\n"
        let result = try await fixture.write(
            observations: fixture.observations + [
                .init(
                    sampleID: "sample-y",
                    readGroupID: "sample-y",
                    sourceClusterID: "y1",
                    clusterReadCount: 4,
                    sequence: unavailableSequence,
                    genotypingHitSummaries: []
                ),
            ],
            canonicalizationProvider: { input in
                if input.sequence == unavailableSequence {
                    return try Fixture.unavailableCanonicalization(input: input)
                }
                return try Fixture.referenceReadyCanonicalization(
                    input: input,
                    trimRange: 0..<input.sequence.count
                )
            }
        )

        XCTAssertEqual(try fastaHeaders(result.unnameableFASTAURL).count, 1)
        let render = try XCTUnwrap(result.transformationRecords.first {
            $0.workflowName == "lungfish-in-process:render-mhc-unnameable-fasta"
        })
        XCTAssertEqual(render.resolvedOptions["recordCount"], "1")
    }

    func testIncompleteCandidatePublishesAsNamedObservedSequence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let incompleteCandidateID = fixture.novelID
        let unavailableCandidateID = fixture.extensionID

        let result = try await fixture.write(
            observations: fixture.observations,
            canonicalizationProvider: { input in
                if input.subject.stableClusterID == incompleteCandidateID {
                    return try Fixture.incompleteCanonicalization(input: input)
                }
                if input.subject.stableClusterID == unavailableCandidateID {
                    return try Fixture.unavailableCanonicalization(input: input)
                }
                return try Fixture.referenceReadyCanonicalization(
                    input: input,
                    trimRange: 0..<input.sequence.count
                )
            }
        )

        let candidates = try JSONDecoder().decode(
            ONTMHCCandidateAllelesDocument.self,
            from: Data(contentsOf: result.candidateJSONURL)
        )
        let partial = try XCTUnwrap(candidates.candidates.first {
            $0.sourceSequenceClusterIDs.contains(fixture.novelID)
        })
        XCTAssertEqual(partial.provisionalName, "Mafa-A1*018:01:01:01_5nt_nov")
        XCTAssertFalse(candidates.candidates.contains {
            $0.sourceSequenceClusterIDs.contains(fixture.extensionID)
        })

        let unnameable = try JSONDecoder().decode(
            ONTMHCUnnameableClustersDocument.self,
            from: Data(contentsOf: result.unnameableJSONURL)
        )
        XCTAssertFalse(unnameable.clusters.contains {
            $0.stableClusterID == fixture.novelID
        })
        XCTAssertTrue(unnameable.evidence.contains {
            $0.path == "artifacts/alignments/unmatched-to-reference.bam"
        })
        let unavailable = try XCTUnwrap(unnameable.clusters.first {
            $0.stableClusterID == fixture.extensionID
        })
        XCTAssertEqual(
            unavailable.reason,
            .referenceCanonicalizationUnavailable
        )
        XCTAssertNil(unavailable.candidateInterpretation)
        XCTAssertNil(unavailable.fastaRecordID)
        XCTAssertNil(unavailable.sequenceSHA256)

        XCTAssertFalse(try fastaHeaders(result.unnameableFASTAURL).contains(fixture.novelID))
        XCTAssertTrue(try fastaHeaders(result.candidateFASTAURL).contains(partial.stableClusterID))
        XCTAssertFalse(
            try fastaHeaders(result.unnameableFASTAURL).contains(fixture.extensionID)
        )
        XCTAssertFalse(
            try fastaHeaders(result.candidateFASTAURL).contains(fixture.extensionID)
        )
        let candidateGenBankRecords = try GenBankReader(
            url: result.candidateGenBankURL
        ).readAllSync()
        let partialGenBank = try XCTUnwrap(candidateGenBankRecords.first {
            $0.accession == partial.stableClusterID
        })
        XCTAssertEqual(partialGenBank.sequence.asString(), fixture.novelSequence)
        let partialEMBL = try String(contentsOf: result.candidateEMBLURL, encoding: .utf8)
        XCTAssertTrue(partialEMBL.contains("ID   \(partial.stableClusterID);"), partialEMBL)
        XCTAssertEqual(result.manifest.candidateEMBL?.path, "candidate_alleles.embl")

        let rawFASTA = try String(
            contentsOf: fixture.outputURL.appendingPathComponent(
                "artifacts/internal/raw-unmatched-consensuses.fasta"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(rawFASTA.contains(">\(fixture.novelID)"))
        XCTAssertTrue(rawFASTA.contains(fixture.novelSequence))

        let sourceMap = try JSONDecoder().decode(
            ONTMHCCandidateSourceIdentityDocument.self,
            from: Data(contentsOf: fixture.outputURL.appendingPathComponent(
                "artifacts/internal/mhc-candidate-source-map.json"
            ))
        )
        let sourceIdentity = try XCTUnwrap(sourceMap.records.first {
            $0.rawStableClusterID == fixture.novelID
        })
        XCTAssertEqual(sourceIdentity.classification, "novel")
        XCTAssertEqual(
            sourceIdentity.referenceReadiness,
            FullLengthONTMHCReferenceReadiness.incomplete.rawValue
        )
        XCTAssertEqual(sourceIdentity.canonicalStableClusterID, fixture.novelID)
        XCTAssertEqual(
            sourceIdentity.canonicalSequenceSHA256,
            sha256HexString(fixture.novelSequence)
        )

        let canonicalization = try XCTUnwrap(result.transformationRecords.first {
            $0.workflowName
                == "lungfish-in-process:canonicalize-and-aggregate-mhc-candidates"
        })
        XCTAssertEqual(
            canonicalization.resolvedOptions["partialCandidatePublicationRule"],
            "incomplete-with-resolved-observed-sequence=>named-candidate;observed-bases-only;missing-reference-bases-not-imputed"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["nonReferenceReadyCandidateDemotionCount"],
            "1"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["incompleteCandidateDemotionCount"],
            "0"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["reviewableIncompleteCandidateCount"],
            "0"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["candidateReferenceRanking"],
            "snp-count-in-shared-aligned-region;then-comparable-bases;then-alignment-score;then-deterministic-reference-evidence-order"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["unavailableCandidateDemotionCount"],
            "1"
        )
    }

    func testUnnameableGenBankPreservesRawIdentityAndDeclaresCanonicalTrimmedIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let canonicalSequence = String(fixture.unnameableSequence.dropLast()) + "T"
        let rawSequence = "TT" + canonicalSequence + "GG"
        let rawID = stableID(rawSequence)
        let canonicalID = stableID(canonicalSequence)
        fixture.additionalSAM = "\(rawID)\t4\t*\t0\t0\t*\t*\t0\t0\t*\t*\n"

        let result = try await fixture.write(
            observations: fixture.observations + [
                .init(
                    sampleID: "sample-trimmed",
                    readGroupID: "sample-trimmed",
                    sourceClusterID: "trimmed-source",
                    clusterReadCount: 9,
                    sequence: rawSequence,
                    genotypingHitSummaries: []
                ),
            ],
            canonicalizationProvider: { input in
                try Fixture.referenceReadyCanonicalization(
                    input: input,
                    trimRange: input.sequence == rawSequence
                        ? 2..<(input.sequence.count - 2)
                        : 0..<input.sequence.count
                )
            }
        )

        let document = try JSONDecoder().decode(
            ONTMHCUnnameableClustersDocument.self,
            from: Data(contentsOf: result.unnameableJSONURL)
        )
        let cluster = try XCTUnwrap(document.clusters.first { $0.stableClusterID == rawID })
        XCTAssertEqual(cluster.fastaRecordID, canonicalID)
        XCTAssertNotEqual(cluster.stableClusterID, cluster.fastaRecordID)
        let record = try XCTUnwrap(
            GenBankReader(url: result.unnameableGenBankURL).readAllSync().first {
                $0.accession == canonicalID
            }
        )
        let source = try XCTUnwrap(record.annotations.first { $0.type == .source })
        XCTAssertEqual(source.qualifier("stable_cluster_id"), rawID)
        XCTAssertEqual(source.qualifier("fasta_record_id"), canonicalID)
        XCTAssertEqual(record.sequence.asString(), canonicalSequence)
    }

    func testCanonicalizerRejectsEveryConflictingBiologicalInterpretationField() throws {
        let sequence = "ATGGCTTAA"
        let baseline = try canonicalizerInput(rawID: "raw-a", externalSequence: sequence)
        let conflicts: [(String, FullLengthONTMHCCandidateCanonicalizer.Input)] = [
            ("locus", try canonicalizerInput(
                rawID: "raw-b", externalSequence: sequence, locus: "Mafa-B"
            )),
            ("provisional name", try canonicalizerInput(
                rawID: "raw-b", externalSequence: sequence, provisionalName: "Mafa-A1*002_nov"
            )),
            ("closest allele", try canonicalizerInput(
                rawID: "raw-b", externalSequence: sequence, closestReferenceName: "Mafa-A1*002"
            )),
            ("closest raw ID", try canonicalizerInput(
                rawID: "raw-b", externalSequence: sequence, closestReferenceRawID: "ref-b"
            )),
            ("closest class", try canonicalizerInput(
                rawID: "raw-b", externalSequence: sequence, closestReferenceClass: .cDNA
            )),
            ("extension of", try canonicalizerInput(
                rawID: "raw-b", externalSequence: sequence, extensionOf: ["Mafa-A1*001"]
            )),
            ("naming ambiguity", try canonicalizerInput(
                rawID: "raw-b", externalSequence: sequence, provisionalNamingAmbiguous: true
            )),
        ]

        for (field, conflict) in conflicts {
            XCTAssertThrowsError(
                try FullLengthONTMHCCandidateCanonicalizer().aggregate([baseline, conflict]),
                field
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("conflicting biological interpretations"),
                    "\(field): \(error.localizedDescription)"
                )
            }
        }
    }

    func testCanonicalizerNormalizesExtensionOrderAndUsesLexicalRepresentativeTieBreak() throws {
        let sequence = "ATGGCTTAA"
        let result = try FullLengthONTMHCCandidateCanonicalizer().aggregate([
            canonicalizerInput(
                rawID: "raw-b",
                externalSequence: sequence,
                totalReads: 10,
                extensionOf: ["Mafa-A1*002", "Mafa-A1*001"]
            ),
            canonicalizerInput(
                rawID: "raw-a",
                externalSequence: sequence,
                totalReads: 10,
                extensionOf: ["Mafa-A1*001", "Mafa-A1*002"]
            ),
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.record.representativeSourceSequenceClusterID, "raw-a")
        XCTAssertEqual(result.first?.record.selectedEvidence.queryName, "raw-a")
        XCTAssertEqual(result.first?.record.extensionOf, ["Mafa-A1*001", "Mafa-A1*002"])
    }

    func testCanonicalizerMergesSameLocusPartialExtensionInterpretationsForIdenticalSequence() throws {
        let sequence = "ATGGCTTAA"
        let result = try FullLengthONTMHCCandidateCanonicalizer().aggregate([
            canonicalizerInput(
                rawID: "raw-a",
                externalSequence: sequence,
                classification: .partialExtension,
                provisionalName: "Mamu-DRB1*03:03:01:01_partial_ext",
                closestReferenceName: "Mamu-DRB1*03:03:01:01",
                closestReferenceRawID: "ref-a",
                totalReads: 12,
                extensionOf: ["Mamu-DRB1*03:03:01:01"],
                snpCount: 0,
                canonicalSubstitutionCount: 0
            ),
            canonicalizerInput(
                rawID: "raw-b",
                externalSequence: sequence,
                classification: .partialExtension,
                provisionalName: "Mamu-DRB1*03:09:01:01_partial_ext",
                closestReferenceName: "Mamu-DRB1*03:09:01:01",
                closestReferenceRawID: "ref-b",
                totalReads: 8,
                extensionOf: ["Mamu-DRB1*03:09:01:01"],
                snpCount: 0,
                canonicalSubstitutionCount: 0
            ),
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].record.classification, .partialExtension)
        XCTAssertEqual(
            result[0].record.extensionOf,
            ["Mamu-DRB1*03:03:01:01", "Mamu-DRB1*03:09:01:01"]
        )
        XCTAssertEqual(result[0].record.provisionalName, "Mamu-DRB1*03:03:01:01_partial_ext")
        XCTAssertTrue(result[0].record.provisionalNamingAmbiguous)
        XCTAssertEqual(result[0].record.totalClusterReads, 20)
    }

    func testCanonicalizerMergesCanonicalZeroSNPNovelIntoPartialExtension() throws {
        let sequence = "ATGGCTTAA"
        let result = try FullLengthONTMHCCandidateCanonicalizer().aggregate([
            canonicalizerInput(
                rawID: "raw-partial",
                externalSequence: sequence,
                classification: .partialExtension,
                provisionalName: "Mamu-DRB1*10:07:01:03_partial_ext",
                closestReferenceName: "Mamu-DRB1*10:07:01:03",
                closestReferenceRawID: "ref-a",
                totalReads: 8,
                extensionOf: ["Mamu-DRB1*10:07:01:03"],
                snpCount: 0,
                canonicalSubstitutionCount: 0
            ),
            canonicalizerInput(
                rawID: "raw-noncoding-snp",
                externalSequence: sequence,
                classification: .novel,
                provisionalName: "Mamu-DRB1*10:07:01:03_1nt_nov",
                closestReferenceName: "Mamu-DRB1*10:07:01:03",
                closestReferenceRawID: "ref-a",
                totalReads: 12,
                snpCount: 1,
                canonicalSubstitutionCount: 0
            ),
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].record.classification, .partialExtension)
        XCTAssertEqual(result[0].record.provisionalName, "Mamu-DRB1*10:07:01:03_partial_ext")
        XCTAssertEqual(result[0].record.extensionOf, ["Mamu-DRB1*10:07:01:03"])
        XCTAssertEqual(result[0].record.totalClusterReads, 20)
        XCTAssertEqual(
            result[0].record.representativeSourceSequenceClusterID,
            "raw-partial"
        )
    }

    func testCanonicalizerMergesAmbiguousDRBReferencesIntoPartialExtension() throws {
        let sequence = "ATGGCTTAA"
        let result = try FullLengthONTMHCCandidateCanonicalizer().aggregate([
            canonicalizerInput(
                rawID: "raw-partial",
                externalSequence: sequence,
                locus: "Mamu-DRB",
                classification: .partialExtension,
                provisionalName: "Mamu-DRB1*03:03:01:01_partial_ext",
                closestReferenceName: "Mamu-DRB1*03:03:01:01",
                closestReferenceRawID: "ref-a",
                totalReads: 8,
                extensionOf: ["Mamu-DRB1*03:03:01:01", "Mamu-DRB1*03:09:01:01"],
                provisionalNamingAmbiguous: true,
                snpCount: 0,
                canonicalSubstitutionCount: 0
            ),
            canonicalizerInput(
                rawID: "raw-novel-a",
                externalSequence: sequence,
                locus: "Mamu-DRB",
                classification: .novel,
                provisionalName: "Mamu-DRB1*03:03:01:01_1nt_nov",
                closestReferenceName: "Mamu-DRB1*03:03:01:01",
                closestReferenceRawID: "ref-a",
                totalReads: 12,
                snpCount: 1,
                canonicalSubstitutionCount: 0
            ),
            canonicalizerInput(
                rawID: "raw-novel-b",
                externalSequence: sequence,
                locus: "Mamu-DRB",
                classification: .novel,
                provisionalName: "Mamu-DRB1*03:09:01:01_1nt_nov",
                closestReferenceName: "Mamu-DRB1*03:09:01:01",
                closestReferenceRawID: "ref-b",
                totalReads: 10,
                snpCount: 1,
                canonicalSubstitutionCount: 0
            ),
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].record.classification, .partialExtension)
        XCTAssertEqual(
            result[0].record.extensionOf,
            ["Mamu-DRB1*03:03:01:01", "Mamu-DRB1*03:09:01:01"]
        )
        XCTAssertEqual(result[0].record.provisionalName, "Mamu-DRB1*03:03:01:01_partial_ext")
        XCTAssertTrue(result[0].record.provisionalNamingAmbiguous)
        XCTAssertEqual(result[0].record.totalClusterReads, 30)
        XCTAssertEqual(
            result[0].record.sourceSequenceClusterIDs,
            ["raw-novel-a", "raw-novel-b", "raw-partial"]
        )
        XCTAssertEqual(result[0].observations.count, 3)
        XCTAssertEqual(
            result[0].observations.reduce(0) { $0 + $1.aggregatedSampleReadCount },
            30
        )
        XCTAssertEqual(result[0].rawInputs.map(\.record.stableClusterID), [
            "raw-novel-a", "raw-novel-b", "raw-partial",
        ])
    }

    func testCanonicalizerRejectsNovelReferenceNotDeclaredByPartialExtension() throws {
        let sequence = "ATGGCTTAA"
        let inputs = [
            try canonicalizerInput(
                rawID: "raw-partial",
                externalSequence: sequence,
                locus: "Mamu-DRB",
                classification: .partialExtension,
                provisionalName: "Mamu-DRB1*03:03:01:01_partial_ext",
                closestReferenceName: "Mamu-DRB1*03:03:01:01",
                closestReferenceRawID: "ref-a",
                extensionOf: ["Mamu-DRB1*03:03:01:01"],
                snpCount: 0,
                canonicalSubstitutionCount: 0
            ),
            try canonicalizerInput(
                rawID: "raw-novel-b",
                externalSequence: sequence,
                locus: "Mamu-DRB",
                classification: .novel,
                provisionalName: "Mamu-DRB1*03:09:01:01_1nt_nov",
                closestReferenceName: "Mamu-DRB1*03:09:01:01",
                closestReferenceRawID: "ref-b",
                snpCount: 1,
                canonicalSubstitutionCount: 1
            ),
        ]

        XCTAssertThrowsError(try FullLengthONTMHCCandidateCanonicalizer().aggregate(inputs)) {
            XCTAssertTrue($0.localizedDescription.contains("conflicting biological interpretations"))
        }
    }

    func testCanonicalizerMergesTrimmedAwayRawSNPIntoCompatiblePartialExtension() throws {
        let sequence = "ATGGCTTAA"
        let result = try FullLengthONTMHCCandidateCanonicalizer().aggregate([
            canonicalizerInput(
                rawID: "raw-partial",
                externalSequence: sequence,
                classification: .partialExtension,
                provisionalName: "Mamu-DRB1*10:07:01:03_partial_ext",
                closestReferenceName: "Mamu-DRB1*10:07:01:03",
                closestReferenceRawID: "ref-a",
                totalReads: 8,
                extensionOf: ["Mamu-DRB1*10:07:01:03"],
                snpCount: 0,
                canonicalSubstitutionCount: 1
            ),
            canonicalizerInput(
                rawID: "raw-trimmed-snp",
                externalSequence: sequence,
                classification: .novel,
                provisionalName: "Mamu-DRB1*10:07:01:03_1nt_nov",
                closestReferenceName: "Mamu-DRB1*10:07:01:03",
                closestReferenceRawID: "ref-a",
                totalReads: 12,
                snpCount: 1,
                canonicalSubstitutionCount: 1
            ),
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].record.classification, .partialExtension)
        XCTAssertEqual(result[0].record.provisionalName, "Mamu-DRB1*10:07:01:03_partial_ext")
        XCTAssertEqual(result[0].record.extensionOf, ["Mamu-DRB1*10:07:01:03"])
        XCTAssertEqual(result[0].record.totalClusterReads, 20)
        XCTAssertEqual(result[0].record.sourceSequenceClusterIDs, ["raw-partial", "raw-trimmed-snp"])
    }

    func testCanonicalizerKeepsOneBaseDifferenceInsideTrimmedSequenceSeparate() throws {
        let first = try canonicalizerInput(
            rawID: "raw-a",
            externalSequence: "ATGGCTTAA"
        )
        let second = try canonicalizerInput(
            rawID: "raw-b",
            externalSequence: "ATGACTTAA"
        )

        let result = try FullLengthONTMHCCandidateCanonicalizer().aggregate([first, second])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.sequence)), ["ATGGCTTAA", "ATGACTTAA"])
        XCTAssertEqual(Set(result.map(\.record.provisionalName)), ["Mafa-A1*001_1nt_nov"])
    }

    func testCanonicalizerUsesRescuedSubstitutionCountToMergeClippedAndFullObservations() throws {
        let sequence = "ATGCGAAAT"
        let result = try FullLengthONTMHCCandidateCanonicalizer().aggregate([
            canonicalizerInput(
                rawID: "raw-clipped",
                externalSequence: sequence,
                provisionalName: "Mafa-A1*001_24nt_nov",
                snpCount: 24,
                canonicalSubstitutionCount: 25,
                canonicalComparableBases: 2_688,
                canonicalIdentity: Double(2_688 - 25) / 2_688,
                canonicalShorterCoverage: 1
            ),
            canonicalizerInput(
                rawID: "raw-full",
                externalSequence: sequence,
                provisionalName: "Mafa-A1*001_25nt_nov",
                snpCount: 25,
                canonicalSubstitutionCount: 25,
                canonicalComparableBases: 2_688,
                canonicalIdentity: Double(2_688 - 25) / 2_688,
                canonicalShorterCoverage: 1
            ),
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].record.snpCount, 25)
        XCTAssertEqual(result[0].record.provisionalName, "Mafa-A1*001_25nt_nov")
        XCTAssertEqual(result[0].record.comparableBases, 2_688)
        XCTAssertEqual(
            result[0].record.identity,
            Double(2_688 - 25) / 2_688,
            accuracy: 0.000_001
        )
        XCTAssertEqual(result[0].record.shorterCoverage, 1)
        XCTAssertEqual(
            Set(result[0].record.sourceSequenceClusterIDs),
            ["raw-clipped", "raw-full"]
        )
        XCTAssertEqual(result[0].representativeCanonicalization.substitutionCount, 25)
    }

    func testPublishesReciprocalEvidenceAndCanonicalCandidateArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let logicalFinalOutputURL = fixture.rootURL.appendingPathComponent(
            "published/result.lungfishgenotype",
            isDirectory: true
        )

        let result = try await fixture.write(
            observations: fixture.observations,
            finalOutputDirectoryURL: logicalFinalOutputURL
        )

        let commands = try fixture.commands()
        let minimap = try XCTUnwrap(commands.first)
        XCTAssertEqual(Array(minimap.prefix(10)), [
            "minimap2", "-a", "--eqx", "--cs=long", "-x", "asm20", "-t", "14", "-N", "2",
        ])
        XCTAssertEqual(minimap[minimap.count - 3], "--secondary=yes")
        XCTAssertEqual(minimap[minimap.count - 2], fixture.referenceFASTAURL.path)
        XCTAssertTrue(minimap.last?.hasSuffix("/deduplicated_unmatched_clusters.fasta") == true)
        XCTAssertEqual(commands.dropFirst().map { Array($0.prefix(2)) }, [
            ["samtools", "view"], ["samtools", "sort"], ["samtools", "index"],
            ["samtools", "quickcheck"], ["samtools", "idxstats"], ["samtools", "view"],
        ])

        XCTAssertEqual(try fastaHeaders(result.candidateFASTAURL), [fixture.novelID, fixture.extensionID])
        XCTAssertEqual(try fastaHeaders(result.unnameableFASTAURL), [fixture.unnameableID])
        let candidateGenBank = try String(contentsOf: result.candidateGenBankURL, encoding: .utf8)
        let unnameableGenBank = try String(contentsOf: result.unnameableGenBankURL, encoding: .utf8)
        XCTAssertTrue(candidateGenBank.contains("ACCESSION"), candidateGenBank)
        XCTAssertTrue(unnameableGenBank.contains("ACCESSION"), unnameableGenBank)
        XCTAssertEqual(result.manifest.candidateGenBank?.path, "candidate_alleles.gb")
        XCTAssertEqual(result.manifest.unnameableGenBank?.path, "unnameable_unmatched_clusters.gb")
        XCTAssertEqual(result.manifest.candidateEMBL?.path, "candidate_alleles.embl")
        XCTAssertEqual(result.manifest.unnameableEMBL?.path, "unnameable_unmatched_clusters.embl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.candidateEMBLURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.unnameableEMBLURL.path))
        let candidate = try JSONDecoder().decode(
            ONTMHCCandidateAllelesDocument.self,
            from: Data(contentsOf: result.candidateJSONURL)
        )
        let unnameable = try JSONDecoder().decode(
            ONTMHCUnnameableClustersDocument.self,
            from: Data(contentsOf: result.unnameableJSONURL)
        )
        let candidateObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: result.candidateJSONURL)) as? [String: Any]
        )
        let unnameableObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: result.unnameableJSONURL)) as? [String: Any]
        )
        let observationObjects = try XCTUnwrap(candidateObject["observations"] as? [[String: Any]])
        let unnameableObjects = try XCTUnwrap(unnameableObject["clusters"] as? [[String: Any]])
        XCTAssertTrue(observationObjects.allSatisfy { $0["evidence"] == nil })
        XCTAssertTrue(unnameableObjects.allSatisfy { $0["evidence"] == nil })
        XCTAssertEqual(candidate.schemaVersion, 5)
        XCTAssertEqual(unnameable.schemaVersion, 5)
        XCTAssertEqual(candidate.inputs.map(\.path), [
            fixture.referenceFASTAURL.path,
            "artifacts/internal/raw-unmatched-consensuses.fasta",
        ])
        XCTAssertTrue(candidate.observations.allSatisfy { !$0.genotypingHitSummaries.isEmpty })
        XCTAssertTrue(candidate.observations.flatMap(\.genotypingHitSummaries).allSatisfy {
            $0.alignmentCount == $0.queryAlignmentCounts.values.reduce(0, +)
        })
        XCTAssertTrue(candidate.candidates.allSatisfy {
            $0.selectedEvidence.bamPath == "artifacts/alignments/unmatched-to-reference.bam"
        })
        XCTAssertTrue(candidate.candidates.allSatisfy {
            $0.reciprocalHitSummary.bamPath == "artifacts/alignments/unmatched-to-reference.bam"
                && $0.reciprocalHitSummary.queryName == $0.stableClusterID
                && $0.reciprocalHitSummary.alignmentCount
                    == $0.reciprocalHitSummary.targetAlignmentCounts.values.reduce(0, +)
                && $0.reciprocalHitSummary.closestMatchTargetNames.contains(
                    $0.selectedEvidence.referenceName
                )
        })
        XCTAssertEqual(result.toolVersions.map(\.toolName), ["minimap2", "samtools"])
        XCTAssertEqual(result.toolVersions.map(\.version), ["2.28-fake", "samtools 1.21-fake"])
        XCTAssertTrue(result.commandRecords.allSatisfy { $0.toolVersion?.isEmpty == false })
        XCTAssertFalse(result.runtimeIdentity.executablePath.isEmpty)
        let transformations = Dictionary(uniqueKeysWithValues: result.transformationRecords.map {
            ($0.workflowName, $0)
        })
        XCTAssertEqual(Set(transformations.keys), [
            "lungfish-in-process:construct-stable-unmatched-cluster-fasta",
            "lungfish-in-process:parse-and-classify-reciprocal-mhc-alignments",
            "lungfish-in-process:serialize-mhc-canonicalization-input",
            "lungfish-in-process:canonicalize-and-aggregate-mhc-candidates",
            "lungfish-in-process:render-mhc-candidate-fasta",
            "lungfish-in-process:render-mhc-unnameable-fasta",
            "lungfish-in-process:render-mhc-candidate-json",
            "lungfish-in-process:render-mhc-unnameable-json",
            "lungfish-in-process:render-mhc-candidate-genbank",
            "lungfish-in-process:render-mhc-unnameable-genbank",
            "lungfish-in-process:render-mhc-candidate-embl",
            "lungfish-in-process:render-mhc-unnameable-embl",
            "lungfish-in-process:render-mhc-candidate-source-identity",
            "lungfish-in-process:publish-canonical-deduplicated-unmatched-fasta",
            "lungfish-in-process:capture-mhc-candidate-artifact-checksums",
            "lungfish-in-process:materialize-mhc-candidate-staging-generation",
        ])
        let classification = try XCTUnwrap(
            transformations["lungfish-in-process:parse-and-classify-reciprocal-mhc-alignments"]
        )
        XCTAssertEqual(classification.resolvedOptions["minimumAlignedBases"], "1000")
        XCTAssertEqual(classification.resolvedOptions["minimumIdentity"], "0.75")
        XCTAssertEqual(classification.resolvedOptions["minimumShorterCoverage"], "0.7")
        XCTAssertEqual(classification.resolvedOptions["minimumIntronGapBases"], "20")
        XCTAssertEqual(
            classification.resolvedOptions["closestReferenceRanking"],
            "snp-count-in-shared-aligned-region;then-comparable-bases;then-alignment-score;then-deterministic-reference-evidence-order"
        )
        XCTAssertEqual(
            classification.resolvedOptions["provisionalNovelNameMetric"],
            "SNP-substitutions-in-shared-aligned-region;indels-reported-separately-and-not-counted-in-_Nnt_nov-label"
        )
        XCTAssertNil(classification.resolvedOptions["novelDistanceMetric"])
        XCTAssertNil(classification.resolvedOptions["zeroSNPIndelClassification"])
        XCTAssertEqual(
            classification.resolvedOptions["zeroSNPClassificationOrder"],
            "1:exact-end-to-end-genomic-zero-snp=known;2:zero-snp-genomic-shared-sequence-with-incomplete-end-coverage=partial-extension;3:eligible-cdna-zero-snp-structural-extension+no-genomic-zero-snp=extension;4:eligible-cdna-zero-snp-end-to-end=known;5:otherwise-broad-genomic-zero-snp=known;6:otherwise=candidate"
        )
        XCTAssertEqual(
            classification.resolvedOptions["extensionRule"],
            "cdna-coverage>=0.95;each-cdna-deficit<20;no-hard-clip;cluster-flank-or-structural-segment>=20"
        )
        XCTAssertEqual(classification.resolvedOptions["documentSchemaVersion"], "5")
        XCTAssertEqual(
            classification.resolvedOptions["exactGenomicKnownRule"],
            "zero-snp;reference-start=1;full-reference-span;full-query-span;no-I-D-N-S-H"
        )
        XCTAssertEqual(
            classification.resolvedOptions["partialExtensionRule"],
            "genomic-zero-snp-shared-sequence;no-I-D-N;incomplete-reference-or-candidate-end-coverage;no-exact-end-to-end-genomic-zero-snp;cDNA-extension-evidence-retained-when-present"
        )
        XCTAssertEqual(
            classification.resolvedOptions["partialExtensionPrecedence"],
            "exact-genomic-known>partial-extension>extension>legacy-broad-genomic-known"
        )
        XCTAssertEqual(classification.resolvedOptions["partialExtensionOutcomeCount"], "0")
        XCTAssertEqual(
            classification.resolvedOptions["knownCDNARule"],
            "extension-eligibility;cluster-coverage>=0.95;each-cluster-structural-segment<20"
        )
        XCTAssertEqual(
            classification.resolvedOptions["cDNACoverageNumerator"],
            "comparable-query-reference-bases-excluding-cdna-deficit-operations"
        )
        XCTAssertEqual(classification.resolvedOptions["minimumCDNAReferenceCoverage"], "0.95")
        XCTAssertEqual(classification.resolvedOptions["minimumCDNAClusterCoverage"], "0.95")
        XCTAssertEqual(
            classification.resolvedOptions["meaningfulCDNAStructuralSegmentBases"],
            "20-per-side-or-cigar-operation"
        )
        XCTAssertEqual(classification.resolvedOptions["cDNAHardClipPolicy"], "ineligible")
        XCTAssertEqual(
            classification.resolvedOptions["cohortCDNAOrientation"],
            "query=reference-cdna,target=cluster;cluster-structure=target-flanks+D+N;cdna-deficit=I+S+H"
        )
        XCTAssertEqual(
            classification.resolvedOptions["reciprocalCDNAOrientation"],
            "query=cluster,target=reference-cdna;cluster-structure=I+S;cdna-deficit=reference-flanks+D+N+H"
        )
        XCTAssertEqual(
            classification.resolvedOptions["allCompatibleReferenceRule"],
            "secondary=yes;-N=reference-record-count;no-fixed-secondary-cap"
        )
        XCTAssertEqual(
            classification.resolvedOptions["reciprocalAlignmentCountRule"],
            "unique-locator-count-equals-sum-of-target-alignment-counts"
        )
        XCTAssertEqual(classification.resolvedOptions["unnameableBulkEvidence"], "omitted")
        XCTAssertTrue(classification.inputs.contains { $0.role == .evidenceBAM })
        XCTAssertTrue(classification.inputs.contains { $0.role == .evidenceBAI })
        let canonicalization = try XCTUnwrap(
            transformations["lungfish-in-process:canonicalize-and-aggregate-mhc-candidates"]
        )
        XCTAssertTrue(canonicalization.argv.contains("--observation-merge-key"))
        XCTAssertEqual(
            canonicalization.resolvedOptions["observationMergeKey"],
            "canonical-stable-cluster-id,sample-id,read-group-id"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["representativeRule"],
            "highest-total-cluster-reads;then-lexical-raw-stable-id"
        )
        XCTAssertEqual(canonicalization.resolvedOptions["rawCandidateCount"], "2")
        XCTAssertEqual(canonicalization.resolvedOptions["canonicalCandidateCount"], "2")
        XCTAssertEqual(
            canonicalization.resolvedOptions["partialExtensionCanonicalReconciliationRule"],
            "identical-published-sequence;same-locus;genomic-only;novel-reference-must-be-listed-by-partial-extension;partial-extension-or-novel-only;no-I-D-N;partial-extension-wins;raw-interpretations-retained-in-artifacts/internal/mhc-candidate-canonicalization-input.json"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["partialExtensionCanonicalReconciliationCount"],
            "0"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["terminalLocalClipRescueRule"],
            "complete-missing-reference-prefix-or-suffix-only;adjacent-terminal-soft-clip-must-supply-all-missing-bases;suffix-of-leading-S-or-prefix-of-trailing-S;oriented-query-base-comparison;substitution-only-no-indel-inference"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["terminalLocalClipRescueAudit"],
            "GenBank-COMMENT-records-leading+trailing-rescued-bases+rescued-substitutions+substitution-only-no-indel-inference;selected-CIGAR-and-evidence-retained"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["terminalLocalClipRescueFeatureRule"],
            "missing-range-wholly-within-one-terminal-CDS-interval"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["terminalLocalClipRescueCanonicalBases"],
            "A,C,G,T"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["terminalLocalClipRescueMismatchAllowance"],
            "max(1,floor(0.20*missing-bases))"
        )
        XCTAssertEqual(
            canonicalization.resolvedOptions["terminalLocalClipRescueMissingBasesUpperBoundExclusive"],
            "20"
        )
        XCTAssertTrue(canonicalization.inputs.contains {
            $0.path == fixture.referenceAnnotationURL.path
        })
        XCTAssertTrue(canonicalization.inputs.contains { $0.role == .referenceFASTA })
        XCTAssertTrue(canonicalization.inputs.contains { $0.role == .evidenceBAM })
        XCTAssertTrue(canonicalization.inputs.contains { $0.role == .evidenceBAI })
        let candidateRender = try XCTUnwrap(
            transformations["lungfish-in-process:render-mhc-candidate-json"]
        )
        XCTAssertEqual(candidateRender.resolvedOptions["documentSchemaVersion"], "5")
        XCTAssertEqual(candidateRender.resolvedOptions["perAlignmentLocatorArrays"], "omitted")
        XCTAssertTrue(
            candidateRender.resolvedOptions["evidenceArtifacts"]?.contains(
                "artifacts/alignments/unmatched-to-reference.bam|sha256="
            ) == true
        )
        for name in [
            "render-mhc-candidate-fasta",
            "render-mhc-candidate-json",
            "render-mhc-candidate-source-identity",
        ] {
            let render = try XCTUnwrap(transformations["lungfish-in-process:\(name)"])
            XCTAssertTrue(render.inputs.contains { $0.path == fixture.referenceFASTAURL.path }, name)
            XCTAssertTrue(render.inputs.contains { $0.path == fixture.referenceAnnotationURL.path }, name)
            XCTAssertTrue(render.inputs.contains { $0.role == .evidenceBAM }, name)
            XCTAssertTrue(render.inputs.contains { $0.role == .evidenceBAI }, name)
            XCTAssertEqual(
                render.resolvedOptions["observationMergeKey"],
                "canonical-stable-cluster-id,sample-id,read-group-id",
                name
            )
        }
        let candidateGenBankRender = try XCTUnwrap(
            transformations["lungfish-in-process:render-mhc-candidate-genbank"]
        )
        XCTAssertTrue(candidateGenBankRender.inputs.allSatisfy {
            candidateGenBankRender.argv.contains($0.path)
        })
        XCTAssertTrue(candidateGenBankRender.outputs.allSatisfy {
            candidateGenBankRender.argv.contains($0.path)
        })
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["translationRule"],
            "recomputed-from-lifted-candidate-CDS;translation-table-1-only;unsupported-omitted+unresolved;terminal-stop-removed;internal-stops-retained-and-counted"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["consequenceChangeSource"],
            "selected-closest-reference-sequence+one-based-reference-start+reciprocal-CIGAR+candidate-sequence;no-BAM-reread"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["consequenceCoordinateConvention"],
            "one-based-reference+stored-candidate-ORIGIN+CDS+codon+exon+intron+amino-acid;outside-crop-reference-only"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["codingConsequenceRule"],
            "transcript-strand+codon-start+translation-table;group-same-codon-substitutions;scope-unresolved-to-intersecting-exon-summary;group-touching-replacement-indels-by-reference-span;ordinary-indels-frame-delta"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["cDNAIntronFillRule"],
            "internal-query-insertion-at-least-minimum-intron-gap;excluded-from-cDNA-lifted-CDS+CDS-indels;genomic-long-insertions-retained;source-CDS-complete-assessment-includes-deletions"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["consequenceAmbiguityRule"],
            "partial+unsupported+ambiguous+unassessed-CDS=unresolved-never-coerced"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["candidateUTRTrimRule"],
            "resolved-complete-or-partial-lifted-CDS:crop-to-observed-outer-lifted-CDS-span-in-stored-orientation;retain-observed-intervening-introns;never-impute-missing-reference-bases"
        )
        let unnameableGenBankRender = try XCTUnwrap(
            transformations["lungfish-in-process:render-mhc-unnameable-genbank"]
        )
        XCTAssertEqual(
            unnameableGenBankRender.resolvedOptions["translationRule"],
            "unnameable-only:recomputed-from-lifted-CDS-when-five-prime-boundary-is-aligned;source-translation-table-not-gated;terminal-stop-removed;internal-stops-retained-and-counted;status-uses-boundary-coverage"
        )
        XCTAssertEqual(
            unnameableGenBankRender.resolvedOptions["unnameableSequenceRule"],
            "reference-ready:canonical-outer-CDS;incomplete-reference-span:diagnostic-observed-partial-sequence+warning+raw-stable-id;unavailable:omit"
        )
        XCTAssertEqual(
            unnameableGenBankRender.resolvedOptions["unnameableFeatureLiftoverRule"],
            "project-gene+mRNA+transcript+exon+CDS+UTR;omit-reference-introns;exclude-query-insertions-at-least-minimum-intron-gap-from-lifted-features"
        )
        XCTAssertEqual(
            unnameableGenBankRender.resolvedOptions["unnameableConsequenceRule"],
            "do-not-render-candidate-nucleotide-or-protein-consequence-COMMENT-summaries"
        )
        for key in [
            "unnameableSequenceRule", "unnameableFeatureLiftoverRule", "unnameableConsequenceRule",
        ] {
            XCTAssertNil(candidateGenBankRender.resolvedOptions[key], key)
        }
        for key in [
            "consequenceChangeSource", "consequenceCoordinateConvention", "codingConsequenceRule",
            "cDNAIntronFillRule", "consequenceAmbiguityRule", "candidateUTRTrimRule",
        ] {
            XCTAssertNil(unnameableGenBankRender.resolvedOptions[key], key)
        }
        for key in [
            "analysisName", "projectBundleName", "recordIdentity", "referenceCoordinateConvention",
            "reciprocalCIGARCoordinateSource", "reverseAlignmentRule", "minimumIntronGapBases",
            "supportMetadata", "externalRecordGate", "outerCDSTrimRule",
        ] {
            XCTAssertEqual(
                unnameableGenBankRender.resolvedOptions[key],
                candidateGenBankRender.resolvedOptions[key],
                key
            )
        }
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["recordIdentity"],
            "external-or-canonical-FASTA-record-id;raw-stable-cluster-id-retained-in-source-metadata"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["externalRecordGate"],
            "resolved-observed-sequence-required;complete-and-partial-named-candidates-published;unavailable-omitted"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["outerCDSTrimRule"],
            "complete-or-partial-lifted-CDS-span;observed-bases-only;rebase-annotations;retain-observed-intervening-introns"
        )
        let construction = try XCTUnwrap(
            transformations["lungfish-in-process:construct-stable-unmatched-cluster-fasta"]
        )
        XCTAssertEqual(construction.inputs.count, 1)
        XCTAssertEqual(
            construction.inputs.first?.path,
            logicalFinalOutputURL.appendingPathComponent(
                "artifacts/internal/raw-unmatched-consensuses.fasta"
            ).path
        )
        let rawInternalURL = fixture.outputURL.appendingPathComponent(
            "artifacts/internal/raw-unmatched-consensuses.fasta"
        )
        XCTAssertTrue(construction.argv.contains(rawInternalURL.path))
        XCTAssertEqual(construction.inputs.first?.sha256, try sha256(rawInternalURL))
        XCTAssertEqual(
            construction.inputs.first?.byteSize,
            UInt64(try fileSize(rawInternalURL))
        )
        XCTAssertEqual(construction.inputs.first?.phase, .final)
        for input in result.transformationRecords.flatMap(\.inputs) {
            XCTAssertTrue(input.path.hasPrefix("/"), "Non-absolute provenance input: \(input.path)")
            XCTAssertEqual(URL(fileURLWithPath: input.path).standardizedFileURL.path, input.path)
        }
        XCTAssertEqual(construction.outputs.count, 1)
        XCTAssertEqual(construction.outputs.first?.phase, .temporary)
        XCTAssertEqual(commands.first?.last, construction.outputs.first?.path)
        let materialization = try XCTUnwrap(
            transformations["lungfish-in-process:materialize-mhc-candidate-staging-generation"]
        )
        XCTAssertEqual(materialization.resolvedOptions["replacementAllowed"], "false")
        XCTAssertTrue(materialization.outputs.allSatisfy { $0.phase == .staging })
        XCTAssertEqual(materialization.outputs.map(\.path).sorted(), [
            result.stableUnmatchedFASTAURL.path,
            result.reciprocalBAMURL.path,
            result.reciprocalBAIURL.path,
            result.candidateFASTAURL.path,
            result.candidateJSONURL.path,
            result.candidateGenBankURL.path,
            result.candidateEMBLURL.path,
            result.unnameableFASTAURL.path,
            result.unnameableJSONURL.path,
            result.unnameableGenBankURL.path,
            result.unnameableEMBLURL.path,
            fixture.outputURL.appendingPathComponent(
                "artifacts/internal/mhc-candidate-canonicalization-input.json"
            ).path,
            fixture.outputURL.appendingPathComponent(
                "artifacts/internal/mhc-candidate-source-map.json"
            ).path,
        ].sorted())
        XCTAssertEqual(
            Set(candidate.candidates.map(\.stableClusterID)),
            Set([fixture.novelID, fixture.extensionID])
        )
        XCTAssertEqual(
            Set(candidate.candidates.map(\.provisionalName)),
            Set(["Mafa-A1*018:01:01:01_5nt_nov", "Mafa-B*001:01_ext"])
        )
        XCTAssertEqual(
            Set(candidate.observations.map(\.stableClusterID)),
            Set(candidate.candidates.map(\.stableClusterID))
        )
        XCTAssertEqual(unnameable.clusters.map(\.stableClusterID), [fixture.unnameableID])
        XCTAssertEqual(
            Set(unnameable.observations.map(\.stableClusterID)),
            Set(unnameable.clusters.map(\.stableClusterID))
        )
        XCTAssertEqual(unnameable.clusters.first?.reason, .noAlignment)
        XCTAssertEqual(unnameable.clusters.first?.reciprocalHitSummary.alignmentCount, 0)
        XCTAssertEqual(unnameable.clusters.first?.reciprocalHitSummary.targetAlignmentCounts, [:])
        XCTAssertEqual(unnameable.clusters.first?.reciprocalHitSummary.exactMatchTargetNames, [])
        XCTAssertEqual(unnameable.clusters.first?.reciprocalHitSummary.closestMatchTargetNames, [])
        XCTAssertNil(unnameable.clusters.first?.selectedEvidence)
        XCTAssertEqual(unnameable.inputs, candidate.inputs)
        XCTAssertEqual(unnameable.evidence, candidate.evidence)
        XCTAssertEqual(result.manifest.reciprocalEvidence?.bam.path, "artifacts/alignments/unmatched-to-reference.bam")
        XCTAssertEqual(result.manifest.candidateJSON?.path, "candidate-alleles.json")
        for reference in result.allArtifactReferences {
            let url = fixture.outputURL.appendingPathComponent(reference.path)
            XCTAssertEqual(reference.sha256, try sha256(url))
            XCTAssertEqual(reference.sizeBytes, try fileSize(url))
        }

        let bytes = try Data(contentsOf: result.candidateJSONURL)
        XCTAssertEqual(bytes, try canonicalizedJSON(bytes))
    }

    func testReciprocalMappingSecondaryLimitCoversEveryReferenceRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let additional = (0..<125).map { index in
            MHCReferenceRecord(
                sequenceID: "extra-\(index)",
                alleleName: "Mafa-A1*extra-\(index)",
                locus: "Mafa-A1",
                moleculeClass: .genomicDNA,
                classEvidence: .annotatedMetadata,
                sequenceLength: 1_200
            )
        }

        _ = try await fixture.write(
            observations: fixture.observations,
            referenceRecords: fixture.defaultReferenceRecords + additional
        )

        let minimap = try XCTUnwrap(try fixture.commands().first)
        let limitIndex = try XCTUnwrap(minimap.firstIndex(of: "-N"))
        XCTAssertEqual(minimap[limitIndex + 1], "127")
    }

    func testStableIDsAndArtifactsAreInvariantToSampleOrderAndKeepLabelCollisionsSeparate() async throws {
        let first = try Fixture()
        defer { first.remove() }
        let second = try Fixture()
        defer { second.remove() }
        let collisionSequence = String(repeating: "A", count: 1_194) + "CCCCCC"
        let collisionID = stableID(collisionSequence)
        let collision = FullLengthONTMHCCandidateSequenceObservation(
            sampleID: "sample-c", readGroupID: "sample-c", sourceClusterID: "source-c",
            clusterReadCount: 9, sequence: collisionSequence, genotypingHitSummaries: []
        )
        first.additionalSAM = "\(collisionID)\t0\tref-genomic\t1\t60\t1194=5X1=\t*\t0\t0\t*\t*\tNM:i:5\tAS:i:1189\n"
        second.additionalSAM = first.additionalSAM

        let forward = try await first.write(observations: first.observations + [collision])
        let reverse = try await second.write(observations: Array(([collision] + second.observations).reversed()))

        let left = try JSONDecoder().decode(ONTMHCCandidateAllelesDocument.self, from: Data(contentsOf: forward.candidateJSONURL))
        let right = try JSONDecoder().decode(ONTMHCCandidateAllelesDocument.self, from: Data(contentsOf: reverse.candidateJSONURL))
        XCTAssertEqual(left.candidates.map(\.stableClusterID), right.candidates.map(\.stableClusterID))
        XCTAssertEqual(
            left.observations.map { "\($0.stableClusterID)|\($0.sampleID)" },
            right.observations.map { "\($0.stableClusterID)|\($0.sampleID)" }
        )
        let collisionLabel = "Mafa-A1*018:01:01:01_5nt_nov"
        XCTAssertEqual(left.candidates.filter { $0.provisionalName == collisionLabel }.count, 2)
        XCTAssertEqual(Set(left.candidates.filter { $0.provisionalName == collisionLabel }.map(\.stableClusterID)).count, 2)
    }

    func testChecksumTransformationTimingBracketsDescriptorHashing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = RecordingDelayedArtifactDescriptorProvider(delay: 0.01)

        let result = try await fixture.write(
            observations: fixture.observations,
            artifactDescriptorProvider: provider
        )

        let checksum = try XCTUnwrap(result.transformationRecords.first {
            $0.workflowName == "lungfish-in-process:capture-mhc-candidate-artifact-checksums"
        })
        let captures = provider.captures
        XCTAssertEqual(captures.count, 13)
        XCTAssertLessThanOrEqual(checksum.startedAt, try XCTUnwrap(captures.first).startedAt)
        XCTAssertGreaterThanOrEqual(checksum.completedAt, try XCTUnwrap(captures.last).completedAt)
        XCTAssertEqual(
            checksum.wallTime,
            checksum.completedAt.timeIntervalSince(checksum.startedAt),
            accuracy: 0.000_001
        )
        XCTAssertGreaterThanOrEqual(checksum.wallTime, 0.10)
    }

    func testWriterRejectsReuseOfNonFreshCallerOwnedStagingDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.write(observations: fixture.observations)
        let oldCandidate = try Data(contentsOf: first.candidateJSONURL)
        do {
            _ = try await fixture.write(observations: fixture.observations)
            XCTFail("Expected non-fresh staging directory rejection")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("fresh caller-owned staging directory"),
                error.localizedDescription
            )
        }
        XCTAssertEqual(try Data(contentsOf: first.candidateJSONURL), oldCandidate)
        XCTAssertEqual(try fastaHeaders(first.candidateFASTAURL), [fixture.novelID, fixture.extensionID])
    }

    func testWriterRejectsInternalSourceMapCollisionBeforePublishingAnyOutput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceMapURL = fixture.outputURL.appendingPathComponent(
            "artifacts/internal/mhc-candidate-source-map.json"
        )
        try FileManager.default.createDirectory(
            at: sourceMapURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sentinel = Data("do-not-replace".utf8)
        try sentinel.write(to: sourceMapURL)

        do {
            _ = try await fixture.write(observations: fixture.observations)
            XCTFail("Expected internal source-map freshness rejection")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("mhc-candidate-source-map.json"),
                error.localizedDescription
            )
        }
        XCTAssertEqual(try Data(contentsOf: sourceMapURL), sentinel)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.outputURL.appendingPathComponent("candidate_alleles.fasta").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.outputURL.appendingPathComponent(
                    "deduplicated_unmatched_clusters.fasta"
                ).path
            )
        )
    }

    func testWriterRejectsRawInputOutsideCanonicalInternalPathBeforeMapping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let arbitraryURL = fixture.outputURL.appendingPathComponent("arbitrary-raw.fasta")

        do {
            _ = try await fixture.write(
                observations: fixture.observations,
                rawInputURLOverride: arbitraryURL
            )
            XCTFail("Expected canonical raw-input path rejection")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "artifacts/internal/raw-unmatched-consensuses.fasta"
                ),
                error.localizedDescription
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.toolsURL.appendingPathComponent(
                "commands.log"
            ).path)
        )
    }

    func testCanonicalizationProvenanceBindsObservationsClassificationsAndGenotypingEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let genotypingBAMURL = fixture.outputURL.appendingPathComponent(
            "artifacts/alignments/genotyping-evidence.bam"
        )
        let genotypingBAIURL = fixture.outputURL.appendingPathComponent(
            "artifacts/alignments/genotyping-evidence.bam.bai"
        )
        try FileManager.default.createDirectory(
            at: genotypingBAMURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("genotyping-bam".utf8).write(to: genotypingBAMURL)
        try Data("genotyping-bai".utf8).write(to: genotypingBAIURL)
        let evidence = ONTMHCBAMArtifactPair(
            bam: try artifactReference(
                genotypingBAMURL,
                path: "artifacts/alignments/genotyping-evidence.bam"
            ),
            bai: try artifactReference(
                genotypingBAIURL,
                path: "artifacts/alignments/genotyping-evidence.bam.bai"
            )
        )

        let result = try await fixture.write(
            observations: fixture.observations,
            genotypingEvidence: evidence
        )
        let transformations = Dictionary(uniqueKeysWithValues: result.transformationRecords.map {
            ($0.workflowName, $0)
        })
        let canonicalization = try XCTUnwrap(
            transformations["lungfish-in-process:canonicalize-and-aggregate-mhc-candidates"]
        )
        let payload = try XCTUnwrap(canonicalization.inputs.first {
            $0.path.hasSuffix("artifacts/internal/mhc-candidate-canonicalization-input.json")
        })
        XCTAssertEqual(payload.sha256, try sha256(URL(fileURLWithPath: payload.path)))
        XCTAssertTrue(canonicalization.inputs.contains { $0.path == genotypingBAMURL.path })
        XCTAssertTrue(canonicalization.inputs.contains { $0.path == genotypingBAIURL.path })
        let candidateGenBank = try XCTUnwrap(
            transformations["lungfish-in-process:render-mhc-candidate-genbank"]
        )
        XCTAssertTrue(candidateGenBank.inputs.contains(payload))
        XCTAssertTrue(candidateGenBank.inputs.contains { $0.path == genotypingBAMURL.path })
        XCTAssertTrue(candidateGenBank.inputs.contains { $0.path == genotypingBAIURL.path })
    }

    func testPublicationRollbackRemovesEarlierOutputsWhenLaterMoveFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lock = NSLock()
        var moveCount = 0
        do {
            _ = try await fixture.write(
                observations: fixture.observations,
                publicationMove: { source, destination in
                    let count = lock.withLock { () -> Int in
                        moveCount += 1
                        return moveCount
                    }
                    if count == 3 {
                        throw FullLengthONTMHCCandidateArtifactWriterError("injected move failure")
                    }
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            )
            XCTFail("Expected injected publication failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("injected move failure"))
        }
        assertNoPublishedCandidateOutputs(fixture)
    }

    func testPublicationRollbackRemovesEarlierOutputsWhenMoveIsCancelled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lock = NSLock()
        var moveCount = 0
        do {
            _ = try await fixture.write(
                observations: fixture.observations,
                publicationMove: { source, destination in
                    let count = lock.withLock { () -> Int in
                        moveCount += 1
                        return moveCount
                    }
                    if count == 3 { throw CancellationError() }
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            )
            XCTFail("Expected injected publication cancellation")
        } catch is CancellationError {
        }
        assertNoPublishedCandidateOutputs(fixture)
    }

    func testDanglingSymlinkLateTargetBlocksPublicationBeforeAnyMove() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.outputURL.appendingPathComponent(
            "artifacts/internal/mhc-candidate-source-map.json"
        )
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: target,
            withDestinationURL: fixture.rootURL.appendingPathComponent("missing-target")
        )

        do {
            _ = try await fixture.write(observations: fixture.observations)
            XCTFail("Expected dangling-symlink collision")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("mhc-candidate-source-map.json"))
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: target.path),
            fixture.rootURL.appendingPathComponent("missing-target").path
        )
        assertNoPublishedCandidateOutputs(fixture)
    }

    func testSymlinkedInternalParentIsRejectedWithoutExternalMutationOrPartialPublication() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outsideURL = fixture.rootURL.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        let rawURL = outsideURL.appendingPathComponent("raw-unmatched-consensuses.fasta")
        let rawData = Data(fixture.canonicalFASTA(records: [
            (fixture.novelID, fixture.novelSequence),
            (fixture.extensionID, fixture.extensionSequence),
            (fixture.unnameableID, fixture.unnameableSequence),
        ]).utf8)
        try rawData.write(to: rawURL)
        let sentinelURL = outsideURL.appendingPathComponent("sentinel.txt")
        let sentinel = Data("outside-must-remain-unchanged".utf8)
        try sentinel.write(to: sentinelURL)
        let artifactsURL = fixture.outputURL.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: artifactsURL.appendingPathComponent("internal"),
            withDestinationURL: outsideURL
        )

        do {
            _ = try await fixture.write(
                observations: fixture.observations,
                rawInputAlreadyStaged: true
            )
            XCTFail("Expected symlinked internal directory rejection")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains("symlink")
                    || error.localizedDescription.localizedCaseInsensitiveContains(
                        "without symlinks"
                    ),
                error.localizedDescription
            )
        }
        XCTAssertEqual(try Data(contentsOf: rawURL), rawData)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: outsideURL.path)),
            ["raw-unmatched-consensuses.fasta", "sentinel.txt"]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.toolsURL.appendingPathComponent("commands.log").path
            )
        )
        assertNoPublishedCandidateOutputs(fixture)
    }

    func testRejectsCanonicalSequenceWhoseStableHeaderDoesNotMatchBasesBeforeMapping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let changed = String(repeating: "T", count: fixture.novelSequence.count)
        let canonical = fixture.canonicalFASTA(records: [
            (fixture.novelID, changed),
            (fixture.extensionID, fixture.extensionSequence),
            (fixture.unnameableID, fixture.unnameableSequence),
        ])

        await fixture.assertRejectedBeforeMapping(
            observations: fixture.observations,
            canonicalFASTA: canonical,
            expectedMessage: "header stable ID does not match normalized sequence"
        )
    }

    func testRejectsCanonicalFASTAWithMissingObservationSequenceBeforeMapping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let canonical = fixture.canonicalFASTA(records: [
            (fixture.novelID, fixture.novelSequence),
            (fixture.extensionID, fixture.extensionSequence),
        ])

        await fixture.assertRejectedBeforeMapping(
            observations: fixture.observations,
            canonicalFASTA: canonical,
            expectedMessage: "missing stable cluster"
        )
    }

    func testRejectsCanonicalFASTAWithExtraSequenceBeforeMapping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let extraSequence = String(repeating: "T", count: 1_100)
        let extraID = stableID(extraSequence)
        let canonical = fixture.canonicalFASTA(records: [
            (fixture.novelID, fixture.novelSequence),
            (fixture.extensionID, fixture.extensionSequence),
            (fixture.unnameableID, fixture.unnameableSequence),
            (extraID, extraSequence),
        ])

        await fixture.assertRejectedBeforeMapping(
            observations: fixture.observations,
            canonicalFASTA: canonical,
            expectedMessage: "extra stable cluster"
        )
    }

    func testRejectsDuplicateCanonicalStableSequenceBeforeMapping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let canonical = fixture.canonicalFASTA(records: [
            (fixture.novelID, fixture.novelSequence),
            (fixture.novelID, fixture.novelSequence),
            (fixture.extensionID, fixture.extensionSequence),
            (fixture.unnameableID, fixture.unnameableSequence),
        ])

        await fixture.assertRejectedBeforeMapping(
            observations: fixture.observations,
            canonicalFASTA: canonical,
            expectedMessage: "duplicate stable cluster"
        )
    }

    func testZeroSNPGenomicIndelOnlyClusterIsReturnedForKnownCallFoldback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let knownSequence = String(repeating: "A", count: 600) + "C" + String(repeating: "A", count: 600)
        let knownID = stableID(knownSequence)
        fixture.additionalSAM = "\(knownID)\t0\tref-genomic\t1\t60\t600=1I600=\t*\t0\t0\t*\t*\tNM:i:1\tAS:i:1200\n"
        let knownObservation = FullLengthONTMHCCandidateSequenceObservation(
            sampleID: "known-sample",
            readGroupID: "known-sample",
            sourceClusterID: "known-source",
            clusterReadCount: 13,
            sequence: knownSequence,
            genotypingHitSummaries: [try ONTMHCGenotypingTargetHitSummary(
                bamPath: "artifacts/alignments/genotyping-evidence.bam",
                targetName: "known-sample|known-source",
                alignmentCount: 1,
                queryAlignmentCounts: ["ref-genomic": 1],
                exactMatchQueryNames: ["ref-genomic"],
                closestMatchQueryNames: ["ref-genomic"]
            )]
        )

        let result = try await fixture.write(observations: fixture.observations + [knownObservation])
        let index = try XCTUnwrap(result.classifiedClusters.firstIndex { $0.stableClusterID == knownID })
        guard case .known(let calls) = result.classifications[index] else {
            return XCTFail("Expected known reciprocal call")
        }
        XCTAssertEqual(calls.map(\.reference.sequenceID), ["ref-genomic"])
        XCTAssertEqual(calls.first?.comparableBases, 1_200)
        XCTAssertEqual(calls.first?.insertedBases, 1)
        XCTAssertEqual(calls.first?.alignmentScore, 1_200)
        XCTAssertFalse(try fastaHeaders(result.candidateFASTAURL).contains(knownID))
        XCTAssertFalse(try fastaHeaders(result.unnameableFASTAURL).contains(knownID))
        XCTAssertEqual(result.classifiedClusters[index].observations.first?.sourceClusterReadCounts, ["known-source": 13])
    }

    func testReciprocalSAMParserRejectsMalformedAndDuplicateIntegerTags() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reference = MHCReferenceRecord(
            sequenceID: "ref", alleleName: "Mafa-A1*001", locus: "Mafa-A1",
            moleculeClass: .genomicDNA, classEvidence: .annotatedMetadata, sequenceLength: 1_200
        )
        for (name, tags, expected) in [
            ("duplicate-as", "NM:i:0\tAS:i:1200\tAS:i:1199", "duplicate AS"),
            ("malformed-as", "NM:i:0\tAS:Z:1200", "malformed AS"),
            ("duplicate-nm", "NM:i:0\tNM:i:1\tAS:i:1200", "duplicate NM"),
            ("malformed-nm", "NM:Z:0\tAS:i:1200", "malformed NM"),
        ] {
            let url = root.appendingPathComponent("\(name).sam")
            try Data("cluster\t0\tref\t1\t60\t1200=\t*\t0\t0\t*\t*\t\(tags)\n".utf8).write(to: url)
            XCTAssertThrowsError(try FullLengthONTMHCReciprocalSAMParser().parse(
                url, clusterIDs: ["cluster"], references: [reference], finalBAMPath: "evidence.bam"
            )) {
                XCTAssertTrue($0.localizedDescription.contains(expected), $0.localizedDescription)
            }
        }
    }

    func testReciprocalSAMParserPreservesSelectedAlignmentOrientation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("orientation.sam")
        try Data("cluster-forward\t0\tref\t1\t60\t4=\t*\t0\t0\t*\t*\tNM:i:0\tAS:i:4\ncluster-reverse\t16\tref\t1\t60\t4=\t*\t0\t0\t*\t*\tNM:i:0\tAS:i:4\n".utf8).write(to: url)
        let reference = MHCReferenceRecord(
            sequenceID: "ref", alleleName: "Mafa-A1*001", locus: "Mafa-A1",
            moleculeClass: .genomicDNA, classEvidence: .annotatedMetadata, sequenceLength: 4
        )

        let parsed = try FullLengthONTMHCReciprocalSAMParser().parse(
            url,
            clusterIDs: ["cluster-forward", "cluster-reverse"],
            references: [reference],
            finalBAMPath: "evidence.bam"
        )

        XCTAssertEqual(parsed["cluster-forward"]?.first?.isReverse, false)
        XCTAssertEqual(parsed["cluster-reverse"]?.first?.isReverse, true)
    }

    func testReciprocalSAMParserStreamsLargeInputAndHonorsCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("large.sam")
        let count = 5_000
        let records = (0..<count).map {
            "cluster-\($0)\t0\tref\t1\t60\t1200=\t*\t0\t0\t*\t*\tNM:i:0\tAS:i:1200"
        }.joined(separator: "\n") + "\n"
        try Data(records.utf8).write(to: url)
        let reference = MHCReferenceRecord(
            sequenceID: "ref", alleleName: "Mafa-A1*001", locus: "Mafa-A1",
            moleculeClass: .genomicDNA, classEvidence: .annotatedMetadata, sequenceLength: 1_200
        )
        let clusterIDs = Set((0..<count).map { "cluster-\($0)" })
        let parsed = try FullLengthONTMHCReciprocalSAMParser().parse(
            url, clusterIDs: clusterIDs, references: [reference], finalBAMPath: "evidence.bam"
        )
        XCTAssertEqual(parsed.count, count)

        let cancelled = Task {
            try FullLengthONTMHCReciprocalSAMParser().parse(
                url, clusterIDs: clusterIDs, references: [reference], finalBAMPath: "evidence.bam"
            )
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    func testReciprocalSAMAndObservationSummariesAreDeterministicallySortedAndDeduplicated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.observations[0]
        let duplicatedObservation = FullLengthONTMHCCandidateSequenceObservation(
            sampleID: original.sampleID,
            readGroupID: original.readGroupID,
            sourceClusterID: original.sourceClusterID,
            clusterReadCount: original.clusterReadCount,
            sequence: original.sequence,
            genotypingHitSummaries: original.genotypingHitSummaries + original.genotypingHitSummaries
        )
        fixture.additionalSAM = "\(fixture.novelID)\t0\tref-genomic\t1\t60\t595=5X600=\t*\t0\t0\t*\t*\tNM:i:5\tAS:i:1190\n"
        let result = try await fixture.write(observations: [duplicatedObservation] + Array(fixture.observations.dropFirst()))
        let novelCluster = try XCTUnwrap(result.classifiedClusters.first { $0.stableClusterID == fixture.novelID })
        XCTAssertEqual(novelCluster.alignments.count, 1)
        XCTAssertTrue(novelCluster.observations.allSatisfy { $0.genotypingHitSummaries.count == 1 })
    }

    private func canonicalizerInput(
        rawID: String,
        externalSequence: String,
        locus: String = "Mafa-A1",
        classification: ONTMHCCandidateClassification = .novel,
        provisionalName: String = "Mafa-A1*001_1nt_nov",
        closestReferenceName: String = "Mafa-A1*001",
        closestReferenceRawID: String = "ref-a",
        closestReferenceClass: MHCReferenceMoleculeClass = .genomicDNA,
        totalReads: Int = 5,
        extensionOf: [String] = [],
        provisionalNamingAmbiguous: Bool = false,
        snpCount: Int = 1,
        canonicalSubstitutionCount: Int = 1,
        canonicalComparableBases: Int? = nil,
        canonicalIdentity: Double? = nil,
        canonicalShorterCoverage: Double? = nil
    ) throws -> FullLengthONTMHCCandidateCanonicalizer.Input {
        let evidence = ONTMHCEvidenceLocator(
            bamPath: "artifacts/alignments/unmatched-to-reference.bam",
            queryName: rawID,
            referenceName: closestReferenceRawID,
            readGroupID: nil,
            referenceStart: 1,
            cigar: "\(externalSequence.count)="
        )
        let record = ONTMHCCandidateRecord(
            stableClusterID: rawID,
            sourceSequenceClusterIDs: [rawID],
            representativeSourceSequenceClusterID: rawID,
            provisionalName: provisionalName,
            locus: locus,
            classification: classification,
            supportClass: .singleton,
            closestReferenceName: closestReferenceName,
            closestReferenceClass: closestReferenceClass,
            snpCount: snpCount,
            insertedBases: 0,
            deletedBases: 0,
            longGapBases: 0,
            comparableBases: externalSequence.count,
            shorterCoverage: 1,
            identity: 0.99,
            mappingQuality: 60,
            alignmentScore: externalSequence.count - 1,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: totalReads,
            supportingSampleIDs: ["sample-\(rawID)"],
            fastaRecordID: rawID,
            sequenceSHA256: sha256HexString(externalSequence),
            selectedEvidence: evidence,
            extensionOf: extensionOf,
            provisionalNamingAmbiguous: provisionalNamingAmbiguous
        )
        let observation = ONTMHCCandidateObservation(
            stableClusterID: rawID,
            sourceSequenceClusterID: rawID,
            sampleID: "sample-\(rawID)",
            readGroupID: "sample-\(rawID)",
            sourceClusterIDs: ["source-\(rawID)"],
            sourceClusterReadCounts: ["source-\(rawID)": totalReads],
            aggregatedSampleReadCount: totalReads,
            genotypingHitSummaries: []
        )
        let genBank = GenBankRecord(
            sequence: try Sequence(
                name: rawID,
                description: provisionalName,
                alphabet: .dna,
                bases: externalSequence
            ),
            annotations: [],
            locus: LocusInfo(
                name: rawID,
                length: externalSequence.count,
                moleculeType: .dna,
                topology: .linear
            ),
            accession: rawID
        )
        return .init(
            record: record,
            observations: [observation],
            canonicalization: .init(
                record: genBank,
                rawSequence: externalSequence,
                externalSequence: externalSequence,
                trimRange: 0..<externalSequence.count,
                translationStatus: .fullLength,
                referenceReadiness: .referenceReady,
                substitutionCount: canonicalSubstitutionCount,
                comparableBases: canonicalComparableBases ?? externalSequence.count,
                identity: canonicalIdentity ?? Double(
                    externalSequence.count - canonicalSubstitutionCount
                ) / Double(externalSequence.count),
                shorterCoverage: canonicalShorterCoverage ?? 1
            )
        )
    }

    private func fastaHeaders(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            line.first == ">" ? String(line.dropFirst()).split(separator: " ").first.map(String.init) : nil
        }
    }

    private func fastaSequences(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: ">").compactMap { record in
            let lines = record.split(separator: "\n")
            guard lines.count > 1 else { return nil }
            return lines.dropFirst().joined()
        }
    }

    private func stableID(_ sequence: String) -> String {
        FullLengthONTMHCCandidateArtifactWriter.stableClusterID(for: sequence)
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256HexString(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
    }

    private func artifactReference(_ url: URL, path: String) throws -> ONTMHCArtifactReference {
        .init(path: path, sha256: try sha256(url), sizeBytes: try fileSize(url))
    }

    private func assertNoPublishedCandidateOutputs(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for relative in [
            "deduplicated_unmatched_clusters.fasta",
            "candidate_alleles.fasta",
            "candidate-alleles.json",
            "candidate_alleles.gb",
            "unnameable_unmatched_clusters.fasta",
            "unnameable-unmatched-clusters.json",
            "unnameable_unmatched_clusters.gb",
            "artifacts/alignments/unmatched-to-reference.bam",
            "artifacts/alignments/unmatched-to-reference.bam.bai",
            "artifacts/internal/mhc-candidate-canonicalization-input.json",
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.outputURL.appendingPathComponent(relative).path
                ),
                relative,
                file: file,
                line: line
            )
        }
    }

    private func canonicalizedJSON(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([0x0a])
    }
}

private extension FullLengthONTMHCCandidateArtifactWriterTests {
    final class Fixture {
        let rootURL: URL
        let outputURL: URL
        let workURL: URL
        let toolsURL: URL
        let referenceFASTAURL: URL
        let referenceAnnotationURL: URL
        var additionalSAM = ""

        let novelSequence = String(repeating: "A", count: 1_200)
        let extensionSequence = String(repeating: "C", count: 1_050)
        let unnameableSequence = String(repeating: "G", count: 900)
        var novelID: String { FullLengthONTMHCCandidateArtifactWriter.stableClusterID(for: novelSequence) }
        var extensionID: String { FullLengthONTMHCCandidateArtifactWriter.stableClusterID(for: extensionSequence) }
        var unnameableID: String { FullLengthONTMHCCandidateArtifactWriter.stableClusterID(for: unnameableSequence) }

        var observations: [FullLengthONTMHCCandidateSequenceObservation] { [
            .init(sampleID: "sample-b", readGroupID: "sample-b", sourceClusterID: "b1", clusterReadCount: 7, sequence: novelSequence, genotypingHitSummaries: evidence(sample: "sample-b", source: "b1")),
            .init(sampleID: "sample-a", readGroupID: "sample-a", sourceClusterID: "a1", clusterReadCount: 5, sequence: novelSequence, genotypingHitSummaries: evidence(sample: "sample-a", source: "a1")),
            .init(sampleID: "sample-a", readGroupID: "sample-a", sourceClusterID: "a2", clusterReadCount: 11, sequence: extensionSequence, genotypingHitSummaries: evidence(sample: "sample-a", source: "a2")),
            .init(sampleID: "sample-z", readGroupID: "sample-z", sourceClusterID: "z1", clusterReadCount: 3, sequence: unnameableSequence, genotypingHitSummaries: evidence(sample: "sample-z", source: "z1")),
        ] }

        var defaultReferenceRecords: [MHCReferenceRecord] {
            [
                .init(sequenceID: "ref-genomic", alleleName: "Mafa-A1*018:01:01:01", locus: "Mafa-A1", moleculeClass: .genomicDNA, classEvidence: .annotatedMetadata, sequenceLength: 1_200),
                .init(sequenceID: "ref-cdna", alleleName: "Mafa-B*001:01", locus: "Mafa-B", moleculeClass: .cDNA, classEvidence: .annotatedMetadata, sequenceLength: 1_000),
            ]
        }

        private func evidence(sample: String, source: String) -> [ONTMHCGenotypingTargetHitSummary] {
            [try! ONTMHCGenotypingTargetHitSummary(
                bamPath: "artifacts/alignments/genotyping-evidence.bam",
                targetName: "\(sample)|\(source)",
                alignmentCount: 1,
                queryAlignmentCounts: ["ref-genomic": 1],
                exactMatchQueryNames: ["ref-genomic"],
                closestMatchQueryNames: ["ref-genomic"]
            )]
        }

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            outputURL = rootURL.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
            workURL = rootURL.appendingPathComponent("work", isDirectory: true)
            toolsURL = rootURL.appendingPathComponent("tools", isDirectory: true)
            referenceFASTAURL = rootURL.appendingPathComponent("reference.fa")
            referenceAnnotationURL = rootURL.appendingPathComponent("reference-annotations.json")
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: toolsURL, withIntermediateDirectories: true)
            try Data(">ref-genomic\n\(String(repeating: "A", count: 1_200))\n>ref-cdna\n\(String(repeating: "C", count: 1_000))\n".utf8).write(to: referenceFASTAURL)
            try Data("{\"schemaVersion\":1}\n".utf8).write(to: referenceAnnotationURL)
            try writeExecutable(Self.minimapScript, to: toolsURL.appendingPathComponent("minimap2"))
            try writeExecutable(Self.samtoolsScript, to: toolsURL.appendingPathComponent("samtools"))
        }

        func write(
            observations: [FullLengthONTMHCCandidateSequenceObservation],
            canonicalFASTAOverride: String? = nil,
            rawInputURLOverride: URL? = nil,
            rawInputAlreadyStaged: Bool = false,
            finalOutputDirectoryURL: URL? = nil,
            referenceRecords: [MHCReferenceRecord]? = nil,
            genotypingEvidence: ONTMHCBAMArtifactPair? = nil,
            canonicalizationProvider: FullLengthONTMHCCandidateArtifactWriter.CanonicalizationProvider? = nil,
            publicationMove: FullLengthONTMHCCandidateArtifactWriter.PublicationMove? = nil,
            artifactDescriptorProvider: any FullLengthONTMHCArtifactDescriptorProviding =
                DefaultFullLengthONTMHCArtifactDescriptorProvider()
        ) async throws -> FullLengthONTMHCCandidateArtifactResult {
            try Data(samText.utf8).write(to: toolsURL.appendingPathComponent("sam-template"), options: .atomic)
            let records = Dictionary(
                observations.map { (FullLengthONTMHCCandidateArtifactWriter.stableClusterID(for: $0.sequence), $0.sequence) },
                uniquingKeysWith: { first, _ in first }
            ).sorted { $0.key < $1.key }
            let stagedUnmatched = canonicalFASTAOverride
                ?? records.map { ">\($0.key)\n\($0.value)\n" }.joined()
            let rawInternalURL = rawInputURLOverride ?? outputURL.appendingPathComponent(
                "artifacts/internal/raw-unmatched-consensuses.fasta"
            )
            if !rawInputAlreadyStaged {
                try FileManager.default.createDirectory(
                    at: rawInternalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(stagedUnmatched.utf8).write(
                    to: rawInternalURL,
                    options: .atomic
                )
            }
            let writer = FullLengthONTMHCCandidateArtifactWriter(
                executableDirectoryURL: toolsURL,
                canonicalizationProvider: canonicalizationProvider ?? {
                    try Self.referenceReadyCanonicalization(
                        input: $0,
                        trimRange: 0..<$0.sequence.count
                    )
                },
                publicationMove: publicationMove,
                artifactDescriptorProvider: artifactDescriptorProvider
            )
            return try await writer.stage(.init(
                observations: observations,
                referenceAlleleFASTAURL: referenceFASTAURL,
                rawUnmatchedConsensusesFASTAURL: rawInternalURL,
                referenceAnnotationInputURLs: [referenceAnnotationURL],
                referenceRecords: referenceRecords ?? defaultReferenceRecords,
                genotypingEvidence: genotypingEvidence,
                threads: 14,
                outputDirectoryURL: outputURL,
                finalOutputDirectoryURL: finalOutputDirectoryURL,
                workDirectoryURL: workURL,
                analysisName: "fixture-run",
                projectBundleName: "Fixture Project.lungfish"
            ))
        }

        static func referenceReadyCanonicalization(
            input: FullLengthONTMHCCandidateGenBankArtifactBuilder.Input,
            trimRange: Range<Int>,
            substitutionCountOverride: Int? = nil
        ) throws -> FullLengthONTMHCCandidateCanonicalization {
            let substitutionCount = substitutionCountOverride
                ?? input.subject.candidateRecord?.snpCount
                ?? 0
            let external = String(input.sequence[input.sequence.index(
                input.sequence.startIndex,
                offsetBy: trimRange.lowerBound
            )..<input.sequence.index(
                input.sequence.startIndex,
                offsetBy: trimRange.upperBound
            )])
            let externalID = FullLengthONTMHCCandidateArtifactWriter.stableClusterID(
                for: external
            )
            let record = GenBankRecord(
                sequence: try Sequence(
                    name: externalID,
                    description: input.subject.definition,
                    alphabet: .dna,
                    bases: external
                ),
                annotations: [
                    SequenceAnnotation(
                        type: .source,
                        name: input.subject.definition,
                        start: 0,
                        end: external.count,
                        strand: .forward,
                        qualifiers: input.subject.subjectQualifiers.merging([
                            "original_sequence_length": .init(String(input.sequence.count)),
                            "trim_start": .init(String(trimRange.lowerBound + 1)),
                            "trim_end": .init(String(trimRange.upperBound)),
                            "genbank_sequence_sha256": .init(sha256HexString(external)),
                            "trim_status": .init("trimmed-to-outer-lifted-CDS"),
                            "reference_readiness_status": .init("reference-ready"),
                        ]) { current, _ in current }
                    ),
                ],
                locus: LocusInfo(
                    name: externalID,
                    length: external.count,
                    moleculeType: .dna,
                    topology: .linear
                ),
                definition: input.subject.definition,
                accession: externalID,
                recordFields: [
                    .init(
                        key: "COMMENT",
                        value: "Lungfish stable cluster ID: \(input.subject.stableClusterID)",
                        ordinal: 0
                    ),
                    .init(
                        key: "COMMENT",
                        value: "Lungfish sequence SHA-256: \(input.subject.sequenceSHA256 ?? "unavailable")",
                        ordinal: 1
                    ),
                    .init(
                        key: "COMMENT",
                        value: "Lungfish support: \(input.subject.supportClass.rawValue); independent samples=\(input.subject.independentSampleCount); occurrences=\(input.subject.occurrenceCount); reads=\(input.subject.totalClusterReads)",
                        ordinal: 2
                    ),
                    .init(
                        key: "COMMENT",
                        value: "Lungfish supporting samples: \(input.subject.supportingSampleIDs.sorted().joined(separator: ", "))",
                        ordinal: 3
                    ),
                    .init(
                        key: "COMMENT",
                        value: "Lungfish candidate sequence trim: outer lifted CDS span; original length=\(input.sequence.count); trim start=\(trimRange.lowerBound + 1); trim end=\(trimRange.upperBound); retained length=\(external.count)",
                        ordinal: 4
                    ),
                    .init(
                        key: "COMMENT",
                        value: "Lungfish GenBank sequence SHA-256: \(sha256HexString(external))",
                        ordinal: 5
                    ),
                ]
            )
            return .init(
                record: record,
                rawSequence: input.sequence,
                externalSequence: external,
                trimRange: trimRange,
                translationStatus: .fullLength,
                referenceReadiness: .referenceReady,
                substitutionCount: substitutionCount,
                comparableBases: external.count,
                identity: external.isEmpty
                    ? 0
                    : Double(max(0, external.count - substitutionCount))
                        / Double(external.count),
                shorterCoverage: 1
            )
        }

        private static func sha256HexString(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }

        static func unavailableCanonicalization(
            input: FullLengthONTMHCCandidateGenBankArtifactBuilder.Input
        ) throws -> FullLengthONTMHCCandidateCanonicalization {
            let diagnostic = try referenceReadyCanonicalization(
                input: input,
                trimRange: 0..<input.sequence.count
            )
            return .init(
                record: diagnostic.record,
                rawSequence: input.sequence,
                externalSequence: nil,
                trimRange: nil,
                translationStatus: .incompleteUnresolved,
                referenceReadiness: .unavailable,
                substitutionCount: diagnostic.substitutionCount,
                comparableBases: diagnostic.comparableBases,
                identity: diagnostic.identity,
                shorterCoverage: diagnostic.shorterCoverage
            )
        }

        static func incompleteCanonicalization(
            input: FullLengthONTMHCCandidateGenBankArtifactBuilder.Input
        ) throws -> FullLengthONTMHCCandidateCanonicalization {
            let diagnostic = try referenceReadyCanonicalization(
                input: input,
                trimRange: 0..<input.sequence.count
            )
            return .init(
                record: diagnostic.record,
                rawSequence: input.sequence,
                externalSequence: diagnostic.externalSequence,
                trimRange: diagnostic.trimRange,
                translationStatus: .incompleteUnresolved,
                referenceReadiness: .incomplete,
                substitutionCount: diagnostic.substitutionCount,
                comparableBases: diagnostic.comparableBases,
                identity: diagnostic.identity,
                shorterCoverage: diagnostic.shorterCoverage
            )
        }

        func canonicalFASTA(records: [(String, String)]) -> String {
            records.map { ">\($0.0)|fixture=true\n\($0.1)\n" }.joined()
        }

        func assertRejectedBeforeMapping(
            observations: [FullLengthONTMHCCandidateSequenceObservation],
            canonicalFASTA: String,
            expectedMessage: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try await write(
                    observations: observations,
                    canonicalFASTAOverride: canonicalFASTA
                )
                XCTFail("Expected canonical unmatched FASTA validation failure", file: file, line: line)
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains(expectedMessage),
                    error.localizedDescription,
                    file: file,
                    line: line
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: toolsURL.appendingPathComponent("commands.log").path),
                "Reciprocal mapping/version discovery must not run before canonical FASTA validation.",
                file: file,
                line: line
            )
        }

        func commands() throws -> [[String]] {
            let text = try String(contentsOf: toolsURL.appendingPathComponent("commands.log"), encoding: .utf8)
            return text.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
                .filter { $0.first != "minimap2-version" && $0.first != "samtools-version" }
        }

        func remove() { try? FileManager.default.removeItem(at: rootURL) }

        private var samText: String {
            """
            @HD\tVN:1.6\tSO:coordinate
            @SQ\tSN:ref-genomic\tLN:1200
            @SQ\tSN:ref-cdna\tLN:1000
            \(novelID)\t0\tref-genomic\t1\t60\t595=5X600=\t*\t0\t0\t*\t*\tNM:i:5\tAS:i:1190
            \(extensionID)\t0\tref-cdna\t1\t55\t500=50I500=\t*\t0\t0\t*\t*\tNM:i:50\tAS:i:1000
            \(unnameableID)\t4\t*\t0\t0\t*\t*\t0\t0\t*\t*
            \(additionalSAM)
            """
        }

        private func writeExecutable(_ text: String, to url: URL) throws {
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        private static let minimapScript = #"""
        #!/bin/sh
        tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        if [ "$1" = "--version" ]; then
          printf 'minimap2-version\n' >> "$tool_dir/commands.log"
          printf '2.28-fake\n'
          exit 0
        fi
        printf 'minimap2' >> "$tool_dir/commands.log"
        for arg in "$@"; do printf '\t%s' "$arg" >> "$tool_dir/commands.log"; done
        printf '\n' >> "$tool_dir/commands.log"
        cat "$tool_dir/sam-template"
        """#

        private static let samtoolsScript = #"""
        #!/bin/sh
        tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        if [ "$1" = "--version" ]; then
          printf 'samtools-version\n' >> "$tool_dir/commands.log"
          printf 'samtools 1.21-fake\n'
          exit 0
        fi
        printf 'samtools' >> "$tool_dir/commands.log"
        for arg in "$@"; do printf '\t%s' "$arg" >> "$tool_dir/commands.log"; done
        printf '\n' >> "$tool_dir/commands.log"
        if [ -f "$tool_dir/fail-command" ] && [ "$(cat "$tool_dir/fail-command")" = "$1" ]; then
          printf 'forced failure\n' >&2
          exit 23
        fi
        case "$1" in
          view)
            if [ "$2" = "-b" ]; then cp "$5" "$4"; else cat "$3"; fi ;;
          sort) cp "$4" "$3" ;;
          index) printf 'index\n' > "$3" ;;
          quickcheck) test -s "$2" && test -s "$2.bai" ;;
          idxstats) printf 'ref-genomic\t1200\t1\t0\n' ;;
        esac
        """#
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}

private final class RecordingDelayedArtifactDescriptorProvider:
    FullLengthONTMHCArtifactDescriptorProviding,
    @unchecked Sendable
{
    struct Capture {
        let startedAt: Date
        let completedAt: Date
    }

    private let delay: TimeInterval
    private let lock = NSLock()
    private var recordedCaptures: [Capture] = []

    init(delay: TimeInterval) {
        self.delay = delay
    }

    var captures: [Capture] {
        lock.withLock { recordedCaptures }
    }

    func descriptor(
        for url: URL,
        role: FullLengthONTMHCArtifactRole,
        phase: FullLengthONTMHCArtifactPhase
    ) throws -> FullLengthONTMHCArtifactDescriptor {
        let startedAt = Date()
        Thread.sleep(forTimeInterval: delay)
        let descriptor = try DefaultFullLengthONTMHCArtifactDescriptorProvider().descriptor(
            for: url,
            role: role,
            phase: phase
        )
        let completedAt = Date()
        lock.withLock {
            recordedCaptures.append(.init(startedAt: startedAt, completedAt: completedAt))
        }
        return descriptor
    }
}
