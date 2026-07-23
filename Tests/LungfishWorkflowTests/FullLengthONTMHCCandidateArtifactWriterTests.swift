import CryptoKit
import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class FullLengthONTMHCCandidateArtifactWriterTests: XCTestCase {
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
            "minimap2", "-a", "--eqx", "--cs=long", "-x", "asm20", "-t", "14", "-N", "100",
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
        XCTAssertTrue(candidateGenBank.contains(fixture.novelID))
        XCTAssertTrue(candidateGenBank.contains("Lungfish project: Fixture Project.lungfish"))
        XCTAssertTrue(candidateGenBank.contains("sample-a, sample-b"))
        XCTAssertTrue(candidateGenBank.contains("Lungfish selected reference raw ID:"))
        for prefix in FullLengthONTMHCCandidateConsequenceAnnotator.summaryPrefixes {
            XCTAssertTrue(candidateGenBank.contains(prefix), "Missing \(prefix)")
        }
        XCTAssertTrue(candidateGenBank.contains("/original_sequence_length="), candidateGenBank)
        XCTAssertTrue(candidateGenBank.contains("/genbank_sequence_sha256="), candidateGenBank)
        XCTAssertTrue(candidateGenBank.contains("/trim_status="), candidateGenBank)
        XCTAssertTrue(candidateGenBank.contains("/reference_readiness_status="), candidateGenBank)
        XCTAssertFalse(unnameableGenBank.contains("/trim_status="), unnameableGenBank)
        XCTAssertFalse(candidateGenBank.contains("annotation unavailable: no selected reciprocal alignment"))
        XCTAssertTrue(unnameableGenBank.contains(fixture.unnameableID))
        XCTAssertTrue(unnameableGenBank.contains("annotation unavailable: no selected reciprocal alignment"))
        XCTAssertEqual(result.manifest.candidateGenBank?.path, "candidate_alleles.gb")
        XCTAssertEqual(result.manifest.unnameableGenBank?.path, "unnameable_unmatched_clusters.gb")
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
        XCTAssertEqual(candidate.schemaVersion, 2)
        XCTAssertEqual(candidate.inputs.map(\.path), [
            fixture.referenceFASTAURL.path,
            "deduplicated_unmatched_clusters.fasta",
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
            "lungfish-in-process:render-mhc-candidate-fasta",
            "lungfish-in-process:render-mhc-unnameable-fasta",
            "lungfish-in-process:render-mhc-candidate-json",
            "lungfish-in-process:render-mhc-unnameable-json",
            "lungfish-in-process:render-mhc-candidate-genbank",
            "lungfish-in-process:render-mhc-unnameable-genbank",
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
        XCTAssertEqual(classification.resolvedOptions["novelDistanceMetric"], "SNP-substitutions-only")
        XCTAssertNil(classification.resolvedOptions["zeroSNPIndelClassification"])
        XCTAssertEqual(
            classification.resolvedOptions["zeroSNPClassificationOrder"],
            "1:eligible-genomic-zero-snp=known;2:eligible-cdna-zero-snp-complete-reference-and-query-intron-fill=extension;3:eligible-other-cdna-zero-snp=known"
        )
        XCTAssertEqual(
            classification.resolvedOptions["extensionRule"],
            "complete-cdna-zero-snp-intron-fill-indels-allowed"
        )
        XCTAssertEqual(classification.resolvedOptions["documentSchemaVersion"], "2")
        XCTAssertEqual(
            classification.resolvedOptions["reciprocalAlignmentCountRule"],
            "unique-locator-count-equals-sum-of-target-alignment-counts"
        )
        XCTAssertEqual(classification.resolvedOptions["unnameableBulkEvidence"], "omitted")
        XCTAssertTrue(classification.inputs.contains { $0.role == .evidenceBAM })
        XCTAssertTrue(classification.inputs.contains { $0.role == .evidenceBAI })
        let candidateRender = try XCTUnwrap(
            transformations["lungfish-in-process:render-mhc-candidate-json"]
        )
        XCTAssertEqual(candidateRender.resolvedOptions["documentSchemaVersion"], "2")
        XCTAssertEqual(candidateRender.resolvedOptions["perAlignmentLocatorArrays"], "omitted")
        XCTAssertTrue(
            candidateRender.resolvedOptions["evidenceArtifacts"]?.contains(
                "artifacts/alignments/unmatched-to-reference.bam|sha256="
            ) == true
        )
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
            "recomputed-from-lifted-candidate-CDS;terminal-stop-removed;internal-stops-retained-and-counted"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["consequenceChangeSource"],
            "selected-closest-reference-sequence+one-based-reference-start+reciprocal-CIGAR+candidate-sequence;no-BAM-reread"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["consequenceCoordinateConvention"],
            "one-based-reference+stored-candidate-ORIGIN+CDS+codon+exon+intron+amino-acid"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["codingConsequenceRule"],
            "transcript-strand+codon-start+translation-table;group-same-codon-substitutions;ordinary-indels-frame-delta"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["cDNAIntronFillRule"],
            "internal-query-insertion-at-least-minimum-intron-gap;excluded-from-CDS-indels"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["consequenceAmbiguityRule"],
            "partial+unsupported+ambiguous=unresolved-never-coerced"
        )
        XCTAssertEqual(
            candidateGenBankRender.resolvedOptions["candidateUTRTrimRule"],
            "candidate-only:outer-lifted-CDS-span-in-stored-orientation;retain-intervening-introns;rebase-annotations-and-consequence-candidate-coordinates;preserve-full-FASTA-identity+record-cropped-GenBank-identity;partial-crop-remains-non-reference-ready;no-CDS-untrimmed"
        )
        let unnameableGenBankRender = try XCTUnwrap(
            transformations["lungfish-in-process:render-mhc-unnameable-genbank"]
        )
        for key in [
            "consequenceChangeSource", "consequenceCoordinateConvention", "codingConsequenceRule",
            "cDNAIntronFillRule", "consequenceAmbiguityRule", "candidateUTRTrimRule",
        ] {
            XCTAssertEqual(unnameableGenBankRender.resolvedOptions[key], candidateGenBankRender.resolvedOptions[key])
        }
        let construction = try XCTUnwrap(
            transformations["lungfish-in-process:construct-stable-unmatched-cluster-fasta"]
        )
        XCTAssertEqual(construction.inputs.count, 1)
        XCTAssertEqual(
            construction.inputs.first?.path,
            logicalFinalOutputURL.appendingPathComponent("deduplicated_unmatched_clusters.fasta").path
        )
        let stagedCanonicalURL = fixture.outputURL.appendingPathComponent(
            "deduplicated_unmatched_clusters.fasta"
        )
        XCTAssertTrue(construction.argv.contains(stagedCanonicalURL.path))
        XCTAssertEqual(construction.inputs.first?.sha256, try sha256(stagedCanonicalURL))
        XCTAssertEqual(construction.inputs.first?.byteSize, UInt64(try fileSize(stagedCanonicalURL)))
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
            result.reciprocalBAMURL.path,
            result.reciprocalBAIURL.path,
            result.candidateFASTAURL.path,
            result.candidateJSONURL.path,
            result.candidateGenBankURL.path,
            result.unnameableFASTAURL.path,
            result.unnameableJSONURL.path,
            result.unnameableGenBankURL.path,
        ].sorted())
        XCTAssertEqual(candidate.candidates.map(\.stableClusterID), [fixture.novelID, fixture.extensionID])
        XCTAssertEqual(candidate.candidates.map(\.provisionalName), [
            "Mafa-A1*018:01:01:01_5nt_nov", "Mafa-B*001:01_ext",
        ])
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
        XCTAssertEqual(captures.count, 8)
        XCTAssertLessThanOrEqual(checksum.startedAt, try XCTUnwrap(captures.first).startedAt)
        XCTAssertGreaterThanOrEqual(checksum.completedAt, try XCTUnwrap(captures.last).completedAt)
        XCTAssertEqual(
            checksum.wallTime,
            checksum.completedAt.timeIntervalSince(checksum.startedAt),
            accuracy: 0.000_001
        )
        XCTAssertGreaterThanOrEqual(checksum.wallTime, 0.08)
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

    private func fastaHeaders(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            line.first == ">" ? String(line.dropFirst()).split(separator: " ").first.map(String.init) : nil
        }
    }

    private func stableID(_ sequence: String) -> String {
        FullLengthONTMHCCandidateArtifactWriter.stableClusterID(for: sequence)
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
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
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: toolsURL, withIntermediateDirectories: true)
            try Data(">ref-genomic\n\(String(repeating: "A", count: 1_200))\n>ref-cdna\n\(String(repeating: "C", count: 1_000))\n".utf8).write(to: referenceFASTAURL)
            try writeExecutable(Self.minimapScript, to: toolsURL.appendingPathComponent("minimap2"))
            try writeExecutable(Self.samtoolsScript, to: toolsURL.appendingPathComponent("samtools"))
        }

        func write(
            observations: [FullLengthONTMHCCandidateSequenceObservation],
            canonicalFASTAOverride: String? = nil,
            finalOutputDirectoryURL: URL? = nil,
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
            try Data(stagedUnmatched.utf8).write(
                to: outputURL.appendingPathComponent("deduplicated_unmatched_clusters.fasta"),
                options: .atomic
            )
            let writer = FullLengthONTMHCCandidateArtifactWriter(
                executableDirectoryURL: toolsURL,
                artifactDescriptorProvider: artifactDescriptorProvider
            )
            return try await writer.stage(.init(
                observations: observations,
                referenceAlleleFASTAURL: referenceFASTAURL,
                referenceRecords: [
                    .init(sequenceID: "ref-genomic", alleleName: "Mafa-A1*018:01:01:01", locus: "Mafa-A1", moleculeClass: .genomicDNA, classEvidence: .annotatedMetadata, sequenceLength: 1_200),
                    .init(sequenceID: "ref-cdna", alleleName: "Mafa-B*001:01", locus: "Mafa-B", moleculeClass: .cDNA, classEvidence: .annotatedMetadata, sequenceLength: 1_000),
                ],
                genotypingEvidence: nil,
                threads: 14,
                outputDirectoryURL: outputURL,
                finalOutputDirectoryURL: finalOutputDirectoryURL,
                workDirectoryURL: workURL,
                analysisName: "fixture-run",
                projectBundleName: "Fixture Project.lungfish"
            ))
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
