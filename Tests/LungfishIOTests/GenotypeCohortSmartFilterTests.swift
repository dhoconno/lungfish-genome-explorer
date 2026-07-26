import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeCohortSmartFilterTests: XCTestCase {
    private func subject(animal: String,
                         calls: [(locus: String, h1: String, h2: String)],
                         qc: ONTGenotypeQCStatus = .ok,
                         comments: String = "",
                         metadata: [String: String] = [:],
                         rawGenotypes: [String] = [],
                         status: GenotypeAnnotationSidecar.StatusValue = .unflagged) -> GenotypeCohortSubject {
        let callValues = calls.flatMap { c -> [GenotypeCohortSubject.Call] in
            [
                GenotypeCohortSubject.Call(
                    locus: c.locus, slot: .h1, name: c.h1,
                    isHomozygous: c.h1 == c.h2,
                    isError: c.h1.hasPrefix("ERR:") || c.h2.hasPrefix("ERR:"),
                    isRecombinant: c.h1.hasPrefix("rec") || c.h2.hasPrefix("rec"),
                    readCount: 100
                ),
                GenotypeCohortSubject.Call(
                    locus: c.locus, slot: .h2, name: c.h2,
                    isHomozygous: c.h1 == c.h2,
                    isError: c.h1.hasPrefix("ERR:") || c.h2.hasPrefix("ERR:"),
                    isRecombinant: c.h1.hasPrefix("rec") || c.h2.hasPrefix("rec"),
                    readCount: 100
                ),
            ]
        }
        return GenotypeCohortSubject(
            animalId: animal, gsId: nil, qcStatus: qc, totalReads: 50000,
            unmappedPercent: 45, comments: comments, metadata: metadata,
            rawGenotypes: rawGenotypes, calls: callValues,
            hasAnyComment: !comments.isEmpty,
            hasErrorAtAnyLocus: callValues.contains { $0.isError },
            isHomozygousAcrossAll: calls.allSatisfy { $0.h1 == $0.h2 },
            hasRegionalRecombinant: callValues.contains { $0.isRecombinant },
            hasAtypicalPattern: false,
            statusValue: status,
            highlightFills: [], highlightBorders: []
        )
    }

    func testAnimalIdMatches() {
        let predicate = SmartCohortPredicate.animalIdMatches("H18C153")
        XCTAssertTrue(predicate.evaluate(subject(animal: "H18C153", calls: [])))
        XCTAssertFalse(predicate.evaluate(subject(animal: "H18C174", calls: [])))
    }

    func testHaplotypeMatchAtLocus() {
        let predicate = SmartCohortPredicate.hasHaplotypeAt(locus: "MHC-A", slot: nil, names: ["M1A"])
        XCTAssertTrue(predicate.evaluate(subject(animal: "A", calls: [(locus: "MHC-A", h1: "M1A", h2: "M3A")])))
        XCTAssertFalse(predicate.evaluate(subject(animal: "B", calls: [(locus: "MHC-A", h1: "M2A", h2: "M3A")])))
    }

    func testIsHomozygousAcrossAll() {
        let predicate = SmartCohortPredicate.isHomozygousAcrossAll
        XCTAssertTrue(predicate.evaluate(subject(animal: "A", calls: [
            (locus: "MHC-A", h1: "M1A", h2: "M1A"),
            (locus: "MHC-B", h1: "M1B", h2: "M1B"),
        ])))
        XCTAssertFalse(predicate.evaluate(subject(animal: "B", calls: [
            (locus: "MHC-A", h1: "M1A", h2: "M3A"),
        ])))
    }

    func testAnyOfPredicates() {
        let predicate = SmartCohortPredicate.any([
            .animalIdMatches("H1"),
            .animalIdMatches("H2"),
        ])
        XCTAssertTrue(predicate.evaluate(subject(animal: "H1", calls: [])))
        XCTAssertTrue(predicate.evaluate(subject(animal: "H2", calls: [])))
        XCTAssertFalse(predicate.evaluate(subject(animal: "H3", calls: [])))
    }

    func testAllOfPredicates() {
        let predicate = SmartCohortPredicate.all([
            .animalIdMatches("H1"),
            .qcStatus([.ok]),
        ])
        XCTAssertTrue(predicate.evaluate(subject(animal: "H1", calls: [], qc: .ok)))
        XCTAssertFalse(predicate.evaluate(subject(animal: "H1", calls: [], qc: .review)))
        XCTAssertFalse(predicate.evaluate(subject(animal: "H2", calls: [], qc: .ok)))
    }

    func testNotPredicate() {
        let predicate = SmartCohortPredicate.not(.animalIdMatches("H1"))
        XCTAssertFalse(predicate.evaluate(subject(animal: "H1", calls: [])))
        XCTAssertTrue(predicate.evaluate(subject(animal: "H2", calls: [])))
    }

    func testCommentContainsCaseInsensitive() {
        let predicate = SmartCohortPredicate.commentContains("bw6+")
        XCTAssertTrue(predicate.evaluate(subject(animal: "A", calls: [], comments: "Bw6+, duplicate")))
        XCTAssertFalse(predicate.evaluate(subject(animal: "A", calls: [], comments: "nothing here")))
    }

    func testMetadataFieldContainsMatchesImportedMetadataCaseInsensitively() {
        let predicate = SmartCohortPredicate.metadataFieldContains(field: "cohort", value: "kenyon")

        XCTAssertTrue(predicate.evaluate(subject(
            animal: "DW472",
            calls: [],
            metadata: ["Cohort": "Kenyon20", "Animal ID": "H18C153"]
        )))
        XCTAssertFalse(predicate.evaluate(subject(
            animal: "DW473",
            calls: [],
            metadata: ["Cohort": "Indonesia", "Animal ID": "H18C174"]
        )))
    }

    func testTextContainsMatchesBroadVisibleFilterFields() {
        let predicate = SmartCohortPredicate.textContains("MHC-B")

        XCTAssertTrue(predicate.evaluate(subject(
            animal: "DW472",
            calls: [(locus: "MHC-B", h1: "M2B", h2: "M3B")],
            rawGenotypes: ["12_M2_B_019_03"]
        )))
        XCTAssertFalse(predicate.evaluate(subject(
            animal: "DW473",
            calls: [(locus: "MHC-A", h1: "M1A", h2: "M3A")],
            rawGenotypes: ["05_M1M2M3_A1_063g"]
        )))
    }

    func testJSONRoundTripPreservesPredicate() throws {
        let original = GenotypeCohortSmartFilter(
            name: "Test",
            scope: "bundle",
            isStarred: true,
            predicate: .all([
                .hasHaplotypeAt(locus: "MHC-A", slot: .h1, names: ["M1A", "M2A"]),
                .metadataFieldContains(field: "Cohort", value: "Kenyon20"),
                .textContains("MHC-B"),
                .qcStatus([.ok]),
            ])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GenotypeCohortSmartFilter.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSharedSearchProjectionHasExactBackwardCompatibleJSONShape() throws {
        let original = GenotypeCohortSmartFilter(
            name: "Shared alias",
            scope: "bundle",
            isStarred: true,
            predicate: .animalIdIn(["CR2", "CR10"]),
            searchProjectionText: "A1*007"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(original)

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"isStarred":true,"name":"Shared alias","predicate":{"ids":["CR2","CR10"],"kind":"animalIdIn"},"scope":"bundle","searchProjectionText":"A1*007"}"#
        )
        XCTAssertEqual(
            try JSONDecoder().decode(GenotypeCohortSmartFilter.self, from: data),
            original
        )
    }

    func testLegacySmartCohortFixtureDecodesWithoutSearchProjection() throws {
        let legacy = Data(
            #"{"name":"Legacy","scope":"bundle","isStarred":false,"predicate":{"kind":"animalIdIn","ids":["B","A"]}}"#
                .utf8
        )

        let decoded = try JSONDecoder().decode(
            GenotypeCohortSmartFilter.self,
            from: legacy
        )

        XCTAssertNil(decoded.searchProjectionText)
        XCTAssertEqual(decoded.predicate, .animalIdIn(["B", "A"]))
    }

    func testCanonicalSampleIDsProduceStableSavedCohortBytes() throws {
        func encoded(_ ids: [String]) throws -> Data {
            let filter = GenotypeCohortSmartFilter(
                name: "Stable",
                predicate: .animalIdIn(
                    GenotypeCohortSmartFilter.canonicalSampleIDs(ids)
                ),
                searchProjectionText: "1178"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(filter)
        }

        let first = try encoded(["CR10", "CR2", "CR1", "CR2"])
        let second = try encoded(["CR2", "CR10", "CR1"])

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            GenotypeCohortSmartFilter.canonicalSampleIDs(
                ["CR10", "CR2", "CR1", "CR2"]
            ),
            ["CR1", "CR2", "CR10"]
        )
    }

    func testJSONRoundTripPreservesNestedPredicates() throws {
        let original = GenotypeCohortSmartFilter(
            name: "Complex",
            predicate: .any([
                .all([
                    .hasErrorAtAnyLocus,
                    .totalReadsAtLeast(1000),
                ]),
                .hasAnalystFlag(.needsReview),
            ])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GenotypeCohortSmartFilter.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testJSONRoundTripPreservesNewPerLocusPredicates() throws {
        let original = GenotypeCohortSmartFilter(
            name: "Per-locus checks",
            predicate: .all([
                .hasErrorAt(locus: "MHC-DRB"),
                .isHomozygousAt(locus: "MHC-A"),
                .hasRegionalRecombinantAt(locus: "MHC-DRB"),
                .needsHaplotypeReview,
                .hasHighlightBorder("#FF0000"),
                .hasHighlightFill(nil),
            ])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GenotypeCohortSmartFilter.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testHasErrorAtLocusEvaluator() {
        let predicate = SmartCohortPredicate.hasErrorAt(locus: "MHC-DRB")
        let withDRBError = subject(
            animal: "A",
            calls: [
                (locus: "MHC-A", h1: "M1A", h2: "M2A"),
                (locus: "MHC-DRB", h1: "ERR: TMH", h2: "ERR: TMH"),
            ]
        )
        let cleanCalls = subject(
            animal: "B",
            calls: [
                (locus: "MHC-A", h1: "M1A", h2: "M2A"),
                (locus: "MHC-DRB", h1: "M1DR", h2: "M2DR"),
            ]
        )
        XCTAssertTrue(predicate.evaluate(withDRBError))
        XCTAssertFalse(predicate.evaluate(cleanCalls))
    }

    func testIsHomozygousAtLocusEvaluator() {
        let predicate = SmartCohortPredicate.isHomozygousAt(locus: "MHC-A")
        let homozygous = subject(
            animal: "A",
            calls: [
                (locus: "MHC-A", h1: "M1A", h2: "M1A"),
                (locus: "MHC-B", h1: "M1B", h2: "M3B"),
            ]
        )
        let heterozygous = subject(
            animal: "B",
            calls: [(locus: "MHC-A", h1: "M1A", h2: "M3A")]
        )
        XCTAssertTrue(predicate.evaluate(homozygous))
        XCTAssertFalse(predicate.evaluate(heterozygous))
    }

    func testNeedsHaplotypeReviewPredicateMatchesIncompleteOrUnconfidentCalls() {
        let predicate = SmartCohortPredicate.needsHaplotypeReview

        XCTAssertTrue(predicate.evaluate(subject(
            animal: "ERR",
            calls: [(locus: "MHC-B", h1: "ERR: TMH", h2: "ERR: TMH")]
        )))
        XCTAssertTrue(predicate.evaluate(subject(
            animal: "UNKNOWN",
            calls: [(locus: "MHC-DQ", h1: "?", h2: "?")]
        )))
        XCTAssertTrue(predicate.evaluate(subject(
            animal: "NOT_ASSAYED",
            calls: [(locus: "MHC-DP", h1: "Not assayed", h2: "Not assayed")]
        )))
        XCTAssertFalse(predicate.evaluate(subject(
            animal: "CLEAN",
            calls: [
                (locus: "MHC-A", h1: "M1A", h2: "M1A"),
                (locus: "MHC-B", h1: "M1B", h2: "-"),
            ]
        )))
    }
}
