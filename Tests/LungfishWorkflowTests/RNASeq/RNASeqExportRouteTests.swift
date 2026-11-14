// RNASeqExportRouteTests.swift - The export refuses a table whose columns come from more than one route or set (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ADJ-BULK-5 item 6. A route is the tool, its version and every setting that changes counts. Route and set are read
// from each result at export, so a moved project refuses the same joins and a replaced file is refused in words.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class RNASeqExportRouteTests: RNASeqExportTestCase {
    typealias Fix = RNASeqExportFixture

    private func refusal(_ first: RNASeqExportRoute, _ second: RNASeqExportRoute) -> String {
        "These samples were counted by different routes: \(RNASeqExportWords.route(first)) (2 samples) and "
            + "\(RNASeqExportWords.route(second)) (3 samples). Counts from different routes differ gene by gene, so comparing them "
            + "finds differences the samples do not have. Export samples counted by one route, or count them all again by one route."
    }

    /// Salmon on reads, STAR then salmon, STAR GeneCounts and featureCounts, each against each.
    func testEachPairOfRoutesIsRefusedInTheWordsOfTheRuling() throws {
        let routes = [Fix.salmonReads, Fix.starSalmon, Fix.geneCounts2, Fix.featureCounts]
        var pairs = 0
        for first in routes.indices {
            for second in routes.indices where second > first {
                pairs += 1
                let a = try make(.init(name: "a\(pairs)", route: routes[first], samples: ["S1", "S2"]))
                let b = try make(.init(name: "b\(pairs)", route: routes[second], samples: ["T1", "T2", "T3"]))
                XCTAssertThrowsError(try Fix.join([a, b])) { XCTAssertEqual($0.localizedDescription, self.refusal(routes[first], routes[second])) }
            }
        }
        XCTAssertEqual(pairs, 6)
    }

    func testASettingThatChangesCountsMakesAnotherRoute() throws {
        var noM = Fix.featureCounts
        noM.settings["-M"] = "off"
        let a = try make(.init(name: "gc2", route: Fix.geneCounts2, samples: ["S1", "S2"]))
        let b = try make(.init(name: "gc3", route: Fix.geneCounts3, samples: ["T1", "T2", "T3"]))
        XCTAssertThrowsError(try Fix.join([a, b])) { XCTAssertEqual($0.localizedDescription, self.refusal(Fix.geneCounts2, Fix.geneCounts3)) }
        let c = try make(.init(name: "fc", route: Fix.featureCounts, samples: ["U1", "U2"]))
        let d = try make(.init(name: "fcno", route: noM, samples: ["V1", "V2", "V3"]))
        XCTAssertThrowsError(try Fix.join([c, d])) { XCTAssertEqual($0.localizedDescription, self.refusal(Fix.featureCounts, noM)) }
    }

    func testTheSameToolAtTwoVersionsIsTwoRoutes() throws {
        var older = Fix.salmonReads
        older.toolVersion = "1.10.0"
        let a = try make(.init(name: "new", route: Fix.salmonReads, samples: ["S1", "S2"]))
        let b = try make(.init(name: "old", route: older, samples: ["T1", "T2", "T3"]))
        XCTAssertThrowsError(try Fix.join([a, b])) {
            XCTAssertEqual($0.localizedDescription, self.refusal(Fix.salmonReads, older))
            XCTAssertTrue($0.localizedDescription.contains("1.10.0") && $0.localizedDescription.contains("2.11.0"))
        }
    }

    func testTwoReferenceSetsAreRefusedByIdOrByLayout() throws {
        let other = RNASeqResultManifest.ReferenceSet(id: "human-lge-2", layout: .lge)
        let deposit = RNASeqResultManifest.ReferenceSet(id: "human-lge-1", layout: .deposit)
        let a = try make(.init(name: "set1", samples: ["S1", "S2"]))
        for (index, set) in [other, deposit].enumerated() {
            let b = try make(.init(name: "set2-\(index)", set: set, samples: ["T1", "T2", "T3"]))
            XCTAssertThrowsError(try Fix.join([a, b])) {
                let words = $0.localizedDescription
                XCTAssertTrue(words.hasPrefix("These samples were counted against different reference sets: "), words)
                XCTAssertTrue(words.contains("\(RNASeqExportWords.referenceSet(Fix.humanSet)) (2 samples)"), words)
                XCTAssertTrue(words.contains("\(RNASeqExportWords.referenceSet(set)) (3 samples)"), words)
                XCTAssertTrue(words.hasSuffix("Export samples counted against one reference set, or count them all again against one reference set."), words)
            }
        }
    }

    func testASetThatReadsNotRecordedRefusesAJoinAndOneSuchResultAloneExports() throws {
        let a = try make(.init(name: "imported1", set: nil, samples: ["S1", "S2"]))
        let b = try make(.init(name: "imported2", set: nil, samples: ["T1", "T2"]))
        XCTAssertThrowsError(try Fix.join([a, b])) {
            let words = $0.localizedDescription
            XCTAssertTrue(words.contains("Not recorded"), words)
            XCTAssertTrue(words.contains("imported1") && words.contains("imported2"), words)
        }
        let alone = try Fix.join([a])
        XCTAssertEqual(alone.counts.sampleIDs, ["S1", "S2"])
        XCTAssertNil(alone.referenceSet)
    }

    func testPairedAndSingleEndSamplesOfOneRoutePassAsOneRoute() throws {
        let paired = RNASeqQualityTable(columns: ["library_type"], rows: [.init(sample: "P1", values: ["IU"]), .init(sample: "P2", values: ["IU"])])
        let single = RNASeqQualityTable(columns: ["library_type"], rows: [.init(sample: "U1", values: ["SF"]), .init(sample: "U2", values: ["SF"])])
        let a = try make(.init(name: "pairs", samples: ["P1", "P2"], quality: paired))
        let b = try make(.init(name: "singles", samples: ["U1", "U2"], quality: single))
        let joined = try Fix.join([a, b])
        XCTAssertEqual(joined.counts.sampleIDs, ["P1", "P2", "U1", "U2"])
        XCTAssertEqual(joined.route, Fix.salmonReads)
    }

    func testAJoinNeedsTheSameGenesAndDistinctSamples() throws {
        let a = try make(.init(name: "four", samples: ["S1", "S2"]))
        let fewer = try make(.init(name: "three", samples: ["T1", "T2"], genes: ["G1", "G2", "G3"]))
        XCTAssertThrowsError(try Fix.join([a, fewer])) { XCTAssertTrue($0.localizedDescription.contains("different genes"), $0.localizedDescription) }
        let again = try make(.init(name: "again", samples: ["S2", "S3"]))
        XCTAssertThrowsError(try Fix.join([a, again])) { XCTAssertTrue($0.localizedDescription.contains("S2"), $0.localizedDescription) }
    }
}
