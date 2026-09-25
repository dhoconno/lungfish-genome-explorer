// BlastFragmentSamplingTests.swift - Mate selection and unbiased sampling for BLAST verification
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

/// Regression tests for BLAST verification of Kraken 2 taxa on paired reads.
///
/// The bug: on an interleaved HSV-1 metagenome the app sent mate 1 of every
/// sampled pair, and its "longest first" sampler picked the first 76 bp
/// records in file order. The first HSV-1 pairs in that file all had a
/// low-complexity mate 1 with no k-mer hits (`0:42 |:| 10298:42`), so BLAST
/// reported "No significant hit" for reads whose mate 2 was pure HSV-1.
/// No test here touches the network.
final class BlastFragmentSamplingTests: XCTestCase {

    private var service: BlastService!
    private var tempDir: URL!

    private let hsvTaxId = 10298
    private let hsvClade: Set<Int> = [3050292, 10298]

    override func setUp() async throws {
        try await super.setUp()
        service = BlastService()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlastFragmentSamplingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        service = nil
        try await super.tearDown()
    }

    // MARK: - Hit-string parsing

    func testMateEvidencePrefersMate2WhenMate1HasNoHits() {
        let evidence = KrakenMateEvidence(hitString: "0:42 |:| 10298:42", targetTaxIds: hsvClade)
        XCTAssertTrue(evidence.isPaired)
        XCTAssertEqual(evidence.mate1TargetKmers, 0)
        XCTAssertEqual(evidence.mate2TargetKmers, 42)
        XCTAssertEqual(evidence.preferredMate, 2)
    }

    func testMateEvidenceCountsOnlyTargetTaxa() {
        // Mate 1 has 20 HSV-1 k-mers. Mate 2 has more classified k-mers,
        // but mostly to the genus (10294) and an unrelated taxon.
        let hits = "10298:20 0:22 |:| 10294:3 10298:6 10294:5 10298:1 10294:16 0:1 332937:3 0:1 10294:2 0:3"
        let evidence = KrakenMateEvidence(hitString: hits, targetTaxIds: hsvClade)
        XCTAssertEqual(evidence.mate1TargetKmers, 20)
        XCTAssertEqual(evidence.mate2TargetKmers, 7)
        XCTAssertEqual(evidence.preferredMate, 1)
    }

    func testMateEvidenceFallsBackToAnyClassifiedKmersThenMate1() {
        // Neither mate hits the target set: choose the mate with any hits.
        XCTAssertEqual(
            KrakenMateEvidence(hitString: "0:30 A:4 |:| 10294:12 0:18", targetTaxIds: hsvClade).preferredMate,
            2
        )
        // Complete tie: mate 1.
        XCTAssertEqual(
            KrakenMateEvidence(hitString: "10298:5 0:37 |:| 0:37 10298:5", targetTaxIds: hsvClade).preferredMate,
            1
        )
    }

    func testSingleEndHitStringIsNotPaired() {
        let evidence = KrakenMateEvidence(hitString: "0:10 562:100 0:5", targetTaxIds: [562])
        XCTAssertFalse(evidence.isPaired)
        XCTAssertNil(evidence.mate2TargetKmers)
        XCTAssertEqual(evidence.mate1TargetKmers, 100)
        XCTAssertEqual(evidence.preferredMate, 1)
    }

    // MARK: - End-to-end request building (no network)

    func testInterleavedPairsSubmitMate2WhenOnlyMate2CarriesHits() async throws {
        let fixture = try writeInterleavedFixture(
            pairs: (0..<12).map { i in
                SyntheticPair(index: i, evidenceMate: 2, mate1Length: 76, mate2Length: 76)
            }
        )

        let request = try await service.buildVerificationRequest(
            taxonName: "Human alphaherpesvirus 1",
            taxId: hsvTaxId,
            targetTaxIds: hsvClade,
            classificationOutputURL: fixture.kraken,
            sourceURL: fixture.fastq,
            readCount: 5
        )

        XCTAssertEqual(request.sequences.count, 5)
        XCTAssertEqual(Set(request.sequences.map(\.id)).count, 5, "Each fragment is submitted once")
        for (id, sequence) in request.sequences {
            let pair = try XCTUnwrap(fixture.pairsById[id])
            XCTAssertEqual(sequence, pair.mate2Sequence, "\(id) must submit mate 2, which carries the HSV-1 k-mers")
            XCTAssertNotEqual(sequence, pair.mate1Sequence)
            XCTAssertEqual(request.sequenceMates[id], 2)
        }
        XCTAssertFalse(request.toMultiFASTA().contains(fixture.pairs[0].mate1Sequence))
    }

    func testInterleavedPairsSubmitWhicheverMateCarriesHits() async throws {
        let pairs = (0..<10).map { i in
            SyntheticPair(index: i, evidenceMate: i.isMultiple(of: 2) ? 1 : 2, mate1Length: 76, mate2Length: 76)
        }
        let fixture = try writeInterleavedFixture(pairs: pairs)

        let request = try await service.buildVerificationRequest(
            taxonName: "Human alphaherpesvirus 1",
            taxId: hsvTaxId,
            targetTaxIds: hsvClade,
            classificationOutputURL: fixture.kraken,
            sourceURL: fixture.fastq,
            readCount: 10
        )

        XCTAssertEqual(request.sequences.count, 10)
        for (id, sequence) in request.sequences {
            let pair = try XCTUnwrap(fixture.pairsById[id])
            XCTAssertEqual(sequence, pair.evidenceSequence)
            XCTAssertEqual(request.sequenceMates[id], pair.evidenceMate)
        }
    }

    func testIndexedPathUsesHitStringsWhenClassificationOutputIsGiven() async throws {
        let fixture = try writeInterleavedFixture(
            pairs: (0..<4).map { SyntheticPair(index: $0, evidenceMate: 2, mate1Length: 76, mate2Length: 76) }
        )

        let request = try await service.buildVerificationRequestFromReadIds(
            taxonName: "Simplexvirus humanalpha1",
            taxId: 3050292,
            matchingReadIds: Set(fixture.pairs.map(\.id)),
            sourceURL: fixture.fastq,
            readCount: 4,
            targetTaxIds: hsvClade,
            classificationOutputURL: fixture.kraken,
            acceptedTaxonNames: ["Human alphaherpesvirus 1", "Simplexvirus humanalpha1"]
        )

        XCTAssertEqual(request.sequences.count, 4)
        for (id, sequence) in request.sequences {
            XCTAssertEqual(sequence, fixture.pairsById[id]?.mate2Sequence)
        }
        XCTAssertEqual(request.acceptedTaxIds, hsvClade)
        XCTAssertEqual(request.acceptedTaxonNames, ["Human alphaherpesvirus 1", "Simplexvirus humanalpha1"])
    }

    func testSingleEndInputSubmitsTheOnlyRecord() async throws {
        let fastq = tempDir.appendingPathComponent("single.fastq")
        let kraken = tempDir.appendingPathComponent("single.kraken")
        var fastqText = ""
        var krakenText = ""
        for i in 0..<6 {
            let seq = String(repeating: "ACGT", count: 20) + String(i)
                .map { _ in "G" }.joined()
            fastqText += "@read_\(i)\n\(seq)\n+\n\(String(repeating: "I", count: seq.count))\n"
            krakenText += "C\tread_\(i)\t562\t\(seq.count)\t562:\(seq.count - 34)\n"
        }
        try fastqText.write(to: fastq, atomically: true, encoding: .utf8)
        try krakenText.write(to: kraken, atomically: true, encoding: .utf8)

        let request = try await service.buildVerificationRequest(
            taxonName: "Escherichia coli",
            taxId: 562,
            targetTaxIds: [562],
            classificationOutputURL: kraken,
            sourceURL: fastq,
            readCount: 3
        )

        XCTAssertEqual(request.sequences.count, 3)
        XCTAssertTrue(request.sequenceMates.isEmpty, "Single-end reads have no mate to record")
        for (id, sequence) in request.sequences {
            XCTAssertTrue(fastqText.contains("@\(id)\n\(sequence)\n"))
        }
    }

    // MARK: - Unbiased sampling

    func testSamplingIsNotBiasedByFileOrderOrReadLength() async throws {
        // 10 of 200 pairs (5%) have a junk mate 1. They come first in the file
        // and are 76 bp while the rest are 75 bp, which is what made the old
        // "longest first" sampler pick them every time.
        let junkCount = 10
        let pairs = (0..<200).map { i in
            SyntheticPair(
                index: i,
                evidenceMate: i < junkCount ? 2 : 1,
                mate1Length: i < junkCount ? 76 : 75,
                mate2Length: i < junkCount ? 76 : 75
            )
        }
        let fixture = try writeInterleavedFixture(pairs: pairs)
        let junkIds = Set(pairs.prefix(junkCount).map(\.id))

        var drawn = 0
        var junkDrawn = 0
        for seed in UInt64(0)..<20 {
            let request = try await service.buildVerificationRequest(
                taxonName: "Human alphaherpesvirus 1",
                taxId: hsvTaxId,
                targetTaxIds: hsvClade,
                classificationOutputURL: fixture.kraken,
                sourceURL: fixture.fastq,
                readCount: 20,
                seed: seed
            )
            XCTAssertEqual(request.sequences.count, 20)
            drawn += request.sequences.count
            junkDrawn += request.sequences.filter { junkIds.contains($0.id) }.count
        }

        // Expected 5% of 400 = 20. The old sampler put at least 3 junk
        // fragments in every 20-read request (at least 60 of 400).
        let fraction = Double(junkDrawn) / Double(drawn)
        XCTAssertLessThan(fraction, 0.10, "junk-mate-1 pairs are over-sampled: \(junkDrawn)/\(drawn)")
        XCTAssertGreaterThan(junkDrawn, 0, "junk-mate-1 pairs must still be eligible")
    }

    func testSampleFragmentIdsIsUniformAcrossClasses() {
        // Two equal classes of fragment IDs. Over many seeds each class
        // should make up about half of the draws.
        let classA = (0..<500).map { "A_\($0)" }
        let classB = (0..<500).map { "B_\($0)" }
        let ids = Set(classA + classB)

        var aCount = 0
        var total = 0
        for seed in UInt64(1)...200 {
            let sample = service.sampleFragmentIds(ids, count: 20, seed: seed)
            XCTAssertEqual(sample.count, 20)
            XCTAssertEqual(Set(sample).count, 20, "no fragment is drawn twice")
            aCount += sample.filter { $0.hasPrefix("A_") }.count
            total += sample.count
        }
        let fraction = Double(aCount) / Double(total)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.04, "class A fraction \(fraction)")
    }

    func testSampleFragmentIdsIsDeterministicUnderSeed() {
        let ids = Set((0..<1000).map { "frag_\($0)" })
        let first = service.sampleFragmentIds(ids, count: 20, seed: 7)
        let again = service.sampleFragmentIds(Set(ids.shuffled()), count: 20, seed: 7)
        let other = service.sampleFragmentIds(ids, count: 20, seed: 8)
        XCTAssertEqual(first, again, "same seed and ID set must give the same sample")
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(service.sampleFragmentIds(Set(["a", "b"]), count: 5).sorted(), ["a", "b"])
    }

    // MARK: - Verdicts

    func testAssignVerdictsRecordsSubmittedMateAndMatchesRenamedSpecies() {
        let hit = BlastHit(
            accession: "MN136523.1",
            title: "Human alphaherpesvirus 1 strain 17, complete genome",
            organism: "Human alphaherpesvirus 1",
            taxId: 10298,
            hsps: [BlastHSP(bitScore: 140, evalue: 1e-30, identity: 76, alignLength: 76, queryFrom: 1, queryTo: 76)]
        )
        let results = service.assignVerdicts(
            searchResults: [
                BlastSearchResult(queryId: "frag_1", queryLength: 76, hits: [hit]),
                BlastSearchResult(queryId: "frag_2", queryLength: 76, hits: []),
            ],
            eValueThreshold: 1e-10,
            queriedTaxonName: "Simplexvirus humanalpha1",
            sequenceMates: ["frag_1": 2, "frag_2": 1],
            acceptedTaxIds: hsvClade,
            acceptedTaxonNames: ["Human alphaherpesvirus 1", "Simplexvirus humanalpha1"]
        )

        XCTAssertEqual(results[0].verdict, .verified)
        XCTAssertTrue(results[0].matchesQueriedTaxon, "Human alphaherpesvirus 1 is Simplexvirus humanalpha1")
        XCTAssertEqual(results[0].submittedMate, 2)
        XCTAssertEqual(results[1].submittedMate, 1)
    }

    func testHitMatchesQueriedTaxonByTaxIdOrAlternateName() {
        XCTAssertTrue(BlastService.hitMatchesQueriedTaxon(
            hitOrganism: "Human alphaherpesvirus 1",
            hitTaxId: 10298,
            queriedTaxonName: "Simplexvirus humanalpha1",
            acceptedTaxIds: hsvClade,
            acceptedTaxonNames: []
        ))
        XCTAssertTrue(BlastService.hitMatchesQueriedTaxon(
            hitOrganism: "Human alphaherpesvirus 1 strain KOS",
            hitTaxId: nil,
            queriedTaxonName: "Simplexvirus humanalpha1",
            acceptedTaxIds: [],
            acceptedTaxonNames: ["Human alphaherpesvirus 1"]
        ))
        XCTAssertFalse(BlastService.hitMatchesQueriedTaxon(
            hitOrganism: "Homo sapiens",
            hitTaxId: 9606,
            queriedTaxonName: "Simplexvirus humanalpha1",
            acceptedTaxIds: hsvClade,
            acceptedTaxonNames: ["Human alphaherpesvirus 1"]
        ))
        // Without the clade, the renamed species does not match by name alone.
        XCTAssertFalse(BlastService.organismMatchesTaxon(
            hitOrganism: "Human alphaherpesvirus 1",
            queriedTaxonName: "Simplexvirus humanalpha1"
        ))
    }

    func testReadResultDecodesWithoutSubmittedMate() throws {
        let json = #"{"id":"r1","verdict":"verified","topHits":[],"hasLCADisagreement":false,"matchesQueriedTaxon":true}"#
        let decoded = try JSONDecoder().decode(BlastReadResult.self, from: Data(json.utf8))
        XCTAssertNil(decoded.submittedMate)
    }

    // MARK: - Fixture helpers

    private struct SyntheticPair {
        let index: Int
        let evidenceMate: Int
        let mate1Length: Int
        let mate2Length: Int

        var id: String { "SRR0000001.\(index + 1)" }

        /// Deterministic, per-pair unique sequences. The junk mate is
        /// low-complexity, the evidence mate is "viral".
        var mate1Sequence: String { sequence(mate: 1, length: mate1Length) }
        var mate2Sequence: String { sequence(mate: 2, length: mate2Length) }
        var evidenceSequence: String { evidenceMate == 1 ? mate1Sequence : mate2Sequence }

        private func sequence(mate: Int, length: Int) -> String {
            let tag = String(index, radix: 4)
                .map { ["0": "A", "1": "C", "2": "G", "3": "T"][$0] ?? "A" }
                .joined()
            let body = mate == evidenceMate
                ? String(repeating: "GATTACAC", count: 12)
                : "GTGCCCCCCCCCCCAAAAAACCCGGGAATTTTTGGTTTTTAAAAAAAAAACGCGG" + String(repeating: "T", count: 40)
            let marker = mate == 1 ? "CCCC" : "GGGG"
            return String((marker + tag + "N" + body).prefix(length))
        }

        /// Kraken 2 line: the evidence mate is all HSV-1, the other has no hits.
        var krakenLine: String {
            let k1 = mate1Length - 34
            let k2 = mate2Length - 34
            let m1 = evidenceMate == 1 ? "10298:\(k1)" : "0:\(k1)"
            let m2 = evidenceMate == 2 ? "10298:\(k2)" : "0:\(k2)"
            return "C\t\(id)\t10298\t\(mate1Length)|\(mate2Length)\t\(m1) |:| \(m2)\n"
        }
    }

    private struct Fixture {
        let fastq: URL
        let kraken: URL
        let pairs: [SyntheticPair]
        var pairsById: [String: SyntheticPair] {
            Dictionary(uniqueKeysWithValues: pairs.map { ($0.id, $0) })
        }
    }

    /// Writes an SRA-style interleaved FASTQ (`@SRR.n SRR.m/1`, both mates
    /// share the first token) and the matching Kraken 2 output.
    private func writeInterleavedFixture(pairs: [SyntheticPair]) throws -> Fixture {
        let fastq = tempDir.appendingPathComponent("interleaved-\(UUID().uuidString).fastq")
        let kraken = tempDir.appendingPathComponent("classification-\(UUID().uuidString).kraken")
        var fastqText = ""
        var krakenText = ""
        for pair in pairs {
            for (mate, sequence) in [(1, pair.mate1Sequence), (2, pair.mate2Sequence)] {
                fastqText += "@\(pair.id) SRR0000001.\(pair.index + 9000)/\(mate)\n"
                fastqText += "\(sequence)\n+\n\(String(repeating: "?", count: sequence.count))\n"
            }
            krakenText += pair.krakenLine
        }
        try fastqText.write(to: fastq, atomically: true, encoding: .utf8)
        try krakenText.write(to: kraken, atomically: true, encoding: .utf8)
        return Fixture(fastq: fastq, kraken: kraken, pairs: pairs)
    }
}
