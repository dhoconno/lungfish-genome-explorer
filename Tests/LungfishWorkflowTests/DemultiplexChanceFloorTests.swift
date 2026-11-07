// DemultiplexChanceFloorTests.swift - BIO's chance floor of a search of the read bases (L5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXRUN item 3. A search of the read bases for a bare 8-base index at -e 0.15 gives about 0.93%
// of reads that carry no barcode one of the default kit's 12 (BIO, `S33-R1-BIO.md:43`), and the run published
// those chance matches as samples.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexChanceFloorTests: XCTestCase {
    private let kit = BarcodeKitRegistry.truseqSingleA

    private var defaultKitPatterns: [String: [String]] {
        Dictionary(uniqueKeysWithValues: kit.barcodes.map { ($0.id, ["^\($0.i7Sequence)"]) })
    }

    func testDefaultKitChanceShareMatchesBIOsModel() {
        var total = 0.0
        for (barcode, lines) in defaultKitPatterns {
            let share = DemultiplexChanceFloor.chanceProbability(ofLines: lines, errorRate: 0.15, allowsIndels: true)
            XCTAssertGreaterThan(share, 0.0005, barcode)
            XCTAssertLessThan(share, 0.0010, barcode)
            total += share
        }
        XCTAssertGreaterThan(total, 0.0085, "BIO's exact share is 0.932%")
        XCTAssertLessThan(total, 0.0100, "BIO's exact share is 0.932%")
        print("DEMUXRUN default kit chance share at -e 0.15: \(total)")
        XCTAssertEqual(DemultiplexChanceFloor.anchoredMatchProbability(Array(repeating: 0, count: 4), errors: 0, allowsIndels: true), 1.0 / 256)
    }

    func testChanceOnlyCountsBeatNoFloorAndARealSampleDoes() {
        let chance = Dictionary(uniqueKeysWithValues: kit.barcodes.map { ($0.id, 12) })
        let none = DemultiplexChanceFloor.evaluate(
            patterns: defaultKitPatterns, counts: chance, readsSearched: 10_000, errorRate: 0.15, allowsIndels: true,
            pairedFragments: false
        )
        XCTAssertFalse(none.anyBarcodeBeatsTheFloor, "\(none.barcodes)")
        var real = chance
        real["D701"] = 80
        let one = DemultiplexChanceFloor.evaluate(
            patterns: defaultKitPatterns, counts: real, readsSearched: 10_000, errorRate: 0.15, allowsIndels: true,
            pairedFragments: false
        )
        XCTAssertTrue(one.anyBarcodeBeatsTheFloor)
        XCTAssertEqual(one.barcodesWithinChance.count, 11, "the other barcodes keep their outputs and are named")
    }

    /// QA's case (L5): an even 384-sample inline pool with 4-base barcodes keeps every real sample. 384 distinct
    /// barcodes cannot all be 4 bases (there are 256), so the pool takes 192 of 4 bases and 192 of 5, prefix free,
    /// as a GBS key mixes lengths, at 100 reads a sample.
    func testEven384SampleInlinePoolWithFourBaseBarcodesKeepsEverySample() {
        let letters = Array("ACGT")
        let fours = (0..<256).map { value in String((0..<4).map { letters[(value >> (2 * (3 - $0))) & 3] }) }
        let shortBarcodes = Array(fours.prefix(192))
        let longBarcodes = Array(fours.suffix(64).flatMap { prefix in letters.map { prefix + String($0) } }.prefix(192))
        let barcodes = shortBarcodes + longBarcodes
        XCTAssertEqual(Set(barcodes).count, 384)
        let patterns = Dictionary(uniqueKeysWithValues: barcodes.map { ($0, ["^\($0)"]) })
        let counts = Dictionary(uniqueKeysWithValues: barcodes.map { ($0, 100) })
        let outcome = DemultiplexChanceFloor.evaluate(
            patterns: patterns, counts: counts, readsSearched: 38_400, errorRate: 0.15, allowsIndels: true,
            pairedFragments: false
        )
        XCTAssertTrue(outcome.anyBarcodeBeatsTheFloor, "the run publishes, so every sample keeps its output")
        XCTAssertEqual(outcome.barcodes.count, 384)
        print("DEMUXRUN 384 pool: \(outcome.barcodesWithinChance.count) of 384 samples named within chance")
    }
}
