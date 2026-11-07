// DemultiplexSearchRouteTests.swift - The route owner reads the first read names before a run searches the bases
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXRUN (L1, L4). A kit whose platform has `indexesInSeparateReads` was always searched in the
// read bases, whatever the read names carried (DEMUX-HEADER-INDEX-NOT-READ).

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexSearchRouteTests: XCTestCase {
    private func config(_ kit: BarcodeKitDefinition, engine: DemultiplexEngine? = nil) -> DemultiplexConfig {
        DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            barcodeKit: kit,
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            engine: engine
        )
    }

    private func names(_ comments: [String]) -> [FASTQReadNameIndex] {
        comments.enumerated().map { FASTQReadNameIndex(rawName: "r\($0.offset) \($0.element)") }
    }

    private func label(_ route: DemultiplexSearchRoute) -> String {
        switch route {
        case .headerIndex: return "headerIndex"
        case .inline: return "inline"
        case .refuse(let words): return "refuse: \(words)"
        }
    }

    func testProbeTakesTheHeaderRouteOnlyAboveTheChanceShare() {
        let kit = BarcodeKitRegistry.truseqSingleA
        let d701 = Array(repeating: "1:N:0:ATTACTCG", count: 1_000)
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(d701))), "headerIndex")
        let library = Array(repeating: "1:N:0:GTCAGTAC", count: 1_000)
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(library))), "inline")
        let sra = (1...1_000).map { "\($0) length=150" }
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(sra))), "inline")
        // Ten names of a kit index among 1,000 random-looking library indexes sit within chance.
        let few = Array(repeating: "1:N:0:GTCAGTAC", count: 990) + Array(repeating: "1:N:0:ATTACTCG", count: 10)
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(few))), "inline")
        let many = Array(repeating: "1:N:0:GTCAGTAC", count: 900) + Array(repeating: "1:N:0:ATTACTCA", count: 100)
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(kit), names: names(many))), "headerIndex")
        // An explicit engine searches the bases, as a recorded command of an earlier version ran.
        XCTAssertEqual(
            label(DemultiplexSearchRouteOwner.route(for: config(kit, engine: .cutadapt), names: names(d701))), "inline"
        )
        // A long-read kit never reads the names.
        XCTAssertEqual(
            label(DemultiplexSearchRouteOwner.route(for: config(BarcodeKitDefinition(
                id: "ont", displayName: "ONT", vendor: "oxford-nanopore", platform: .oxfordNanopore,
                barcodes: [BarcodeEntry(id: "B1", i7Sequence: "ATTACTCG")]
            )), names: names(d701))),
            "inline"
        )
    }

    func testDualIndexKitRefusesOnlyWhenBothIndexesCollide() {
        func kit(_ pairs: [(String, String, String)]) -> BarcodeKitDefinition {
            BarcodeKitDefinition(
                id: "plate", displayName: "Plate", platform: .illumina, isDualIndexed: true, pairingMode: .fixedDual,
                barcodes: pairs.map { BarcodeEntry(id: $0.0, i7Sequence: $0.1, i5Sequence: $0.2) }
            )
        }
        // A combinatorial plate: four samples on one i7 with four i5s still splits (BIO, L6).
        let plate = kit([
            ("S1", "ATTACTCG", "TATAGCCT"), ("S2", "ATTACTCG", "ATAGAGGC"),
            ("S3", "ATTACTCG", "CCTATCCT"), ("S4", "ATTACTCG", "GGCTCTGA"),
        ])
        let plateNames = names(Array(repeating: "1:N:0:ATTACTCG+TATAGCCT", count: 1_000))
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(plate), names: plateNames)), "headerIndex")

        // Two barcodes within two mismatches in both i7 and i5 refuse, and the words name both.
        let close = kit([("S1", "ATTACTCG", "TATAGCCT"), ("S2", "ATTACTAA", "TATAGCAA")])
        let words = label(DemultiplexSearchRouteOwner.route(for: config(close), names: plateNames))
        XCTAssertTrue(words.hasPrefix("refuse: Barcodes S1 and S2 differ at 4 bases"), words)
        XCTAssertTrue(words.contains("Correct the definition, or remove one of the two barcodes."), words)

        // Close in i7 only is no collision.
        let farI5 = kit([("S1", "ATTACTCG", "TATAGCCT"), ("S2", "ATTACTAA", "GGCTCTGA")])
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(farI5), names: plateNames)), "headerIndex")

        // i5 matches as listed or reverse complemented.
        let reversed = names(Array(repeating: "1:N:0:ATTACTCG+\(PlatformAdapters.reverseComplement("TATAGCCT"))", count: 1_000))
        XCTAssertEqual(label(DemultiplexSearchRouteOwner.route(for: config(plate), names: reversed)), "headerIndex")
    }

    func testChanceCeilingIsTheOneSidedBinomialBound() {
        XCTAssertEqual(DemultiplexChanceFloor.chanceCeiling(trials: 10_000, probability: 0, tail: 1e-6), 0)
        XCTAssertEqual(DemultiplexChanceFloor.chanceCeiling(trials: 10, probability: 1, tail: 1e-6), 10)
        for (trials, probability, tail) in [(10_000, 0.00078, 1e-6 / 12), (1_000, 0.0046, 1e-6), (2_000_000, 0.004, 1e-8)] {
            let ceiling = DemultiplexChanceFloor.chanceCeiling(trials: trials, probability: probability, tail: tail)
            XCTAssertGreaterThanOrEqual(
                DemultiplexChanceFloor.upperTail(trials: trials, probability: probability, from: ceiling), tail
            )
            XCTAssertLessThan(
                DemultiplexChanceFloor.upperTail(trials: trials, probability: probability, from: ceiling + 1), tail
            )
            XCTAssertGreaterThan(Double(ceiling), Double(trials) * probability)
        }
    }
}
