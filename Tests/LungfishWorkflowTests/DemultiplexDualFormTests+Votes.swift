// DemultiplexDualFormTests+Votes.swift - The line between a form and no form, pinned on the choice itself
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Fix round FIX-DUAL-FORM item 2 (review DEMUX-DUAL-FORM-BIO, should-fix 2). The ruling BIO-DUAL-FORM item 2 makes more than
// 3 votes the line between a row that carries a form and one that does not, and floor(error rate x length) the line between
// a vote and none. The end to end tests of this class use 5 to 20 reads a row with exact barcodes, so the threshold, the
// floor, the wildcard of an N and the limit of 10,000 records could each change with every one of them green. These tests
// call the choice itself, which starts no Cutadapt run, on the reads of one row at a time.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

extension DemultiplexDualFormTests {
    typealias Choice = DemultiplexingPipeline.SecondaryFormChoice

    /// The choice the first reads of `reads` make for `rows` at the distances 0 and 0. `kitRows` are the rows the kit file
    /// holds, for entries whose barcodes the file may not hold (the choice reads only the name of the kit).
    func choose(_ rows: [Row], _ reads: [Read], errorRate: Double, kitRows: [Row]? = nil) async throws -> Choice {
        let config = config(
            try kit(kitRows ?? rows), try writeFASTQ(reads), dir.appendingPathComponent("unused"),
            distance: 0, errorRate: errorRate
        )
        let choice = try await DemultiplexingPipeline().chooseSecondaryForm(of: rows, config: config)
        return try XCTUnwrap(choice)
    }

    /// `count` forward reads of `row` in primer form, the first barcode at the start and the reverse complement of the
    /// secondary sequence at the end, with `readFirst` and `readEnd` in their places when given.
    func forwardReads(_ row: Row, count: Int, readFirst: String? = nil, readEnd: String? = nil) -> [Read] {
        var bases = Bases()
        return (0..<count).map { index in
            (name: "\(row.name)|F0-\(index)",
             sequence: (readFirst ?? row.first) + bases.next(60) + (readEnd ?? Self.rc(row.second)))
        }
    }

    /// `sequence` with the base at each of `indexes` changed to another base.
    static func substituted(_ sequence: String, at indexes: [Int]) -> String {
        var bases = Array(sequence)
        for index in indexes { bases[index] = bases[index] == "A" ? "C" : "A" }
        return String(bases)
    }

    /// The choice for one row of the first barcode `first` and the secondary sequence AGGAGTTA, on 5 forward reads in primer
    /// form that carry `readFirst` and `readEnd` in place of the barcodes.
    func chooseOne(first: String, readFirst: String, readEnd: String? = nil, errorRate: Double) async throws -> Choice {
        let row: Row = ("R", first, "AGGAGTTA")
        return try await choose(
            [row], forwardReads(row, count: 5, readFirst: readFirst, readEnd: readEnd), errorRate: errorRate,
            kitRows: [("R", "TGGGCGAA", "AGGAGTTA")]
        )
    }

    /// All 5 reads of `chooseOne` voted for the reverse complemented form, or none voted for any form.
    func assertVotes(_ choice: Choice, placed: Bool, _ label: String) {
        let form: DemultiplexingPipeline.SecondaryForm = placed ? .reverseComplemented : .asWritten
        XCTAssertEqual(choice.reverseComplemented, placed ? 5 : 0, "\(label): \(choice)")
        XCTAssertEqual(choice.asWritten + choice.disputed, 0, "\(label): \(choice)")
        XCTAssertEqual(choice.form, form, "\(label): \(choice)")
        XCTAssertEqual(choice.rowsCarrying, placed ? 1 : 0, "\(label): \(choice)")
    }

    /// Three votes in a row carry no form and four do (BIO-DUAL-FORM item 2, Detect's reject threshold).
    func testARowCarriesAFormOnlyWithMoreThanThreeVotes() async throws {
        let row = Self.eight[0]
        let cases: [(count: Int, form: DemultiplexingPipeline.SecondaryForm, carrying: Int)] = [
            (3, .asWritten, 0), (4, .reverseComplemented, 1),
        ]
        for (count, form, carrying) in cases {
            let choice = try await choose([row], forwardReads(row, count: count), errorRate: 0)
            XCTAssertEqual(choice.form, form, "\(count) votes: \(choice)")
            XCTAssertEqual(choice.rowsCarrying, carrying, "\(count) votes: \(choice)")
            XCTAssertEqual(choice.readsRead, count, "\(count) votes: \(choice)")
            XCTAssertEqual(choice.reverseComplemented, count, "\(count) votes: \(choice)")
            XCTAssertEqual(choice.asWritten + choice.disputed, 0, "\(count) votes: \(choice)")
        }
    }

    /// Reads of X in primer form fit Y as written and X reverse complemented, so each is disputed. Three of them are read
    /// as written, four stop the run naming X and Y.
    func testMoreThanThreeDisputedReadsWithNoRowCarryingRefuse() async throws {
        let three = try await choose(Self.pair, forwardReads(Self.pair[0], count: 3), errorRate: 0)
        XCTAssertEqual(three.form, .asWritten, "\(three)")
        XCTAssertEqual(three.disputed, 3, "\(three)")
        XCTAssertEqual(three.rowsCarrying, 0, "\(three)")
        do {
            let four = try await choose(Self.pair, forwardReads(Self.pair[0], count: 4), errorRate: 0)
            XCTFail("4 disputed reads and no row carrying a form did not refuse: \(four)")
        } catch DemultiplexError.dualFormUndecided(let kitName, let rows) {
            XCTAssertEqual(kitName, "K")
            XCTAssertEqual(rows, ["X", "Y"])
        } catch {
            XCTFail("the refusal is not dualFormUndecided: \(error)")
        }
    }

    /// Each barcode may hold floor(error rate x its counted length) substitutions, and an N matches any base and is not
    /// counted in the length (BIO-DUAL-FORM item 2, the budget of Cutadapt for each side of a linked line).
    func testTheBudgetIsFlooredForEachBarcodeAndNIsNeverCounted() async throws {
        let first = "TGGGCGAA"
        let end = Self.rc("AGGAGTTA")
        // Eight bases at 0.15 allow floor(1.2) = 1 substitution in each barcode, and at 0 none.
        var choice = try await chooseOne(
            first: first, readFirst: Self.substituted(first, at: [2]), readEnd: Self.substituted(end, at: [3]), errorRate: 0.15
        )
        assertVotes(choice, placed: true, "one substitution in each barcode at 0.15")
        choice = try await chooseOne(first: first, readFirst: Self.substituted(first, at: [1, 4]), errorRate: 0.15)
        assertVotes(choice, placed: false, "two substitutions in the first barcode at 0.15")
        choice = try await chooseOne(
            first: first, readFirst: first, readEnd: Self.substituted(end, at: [1, 5]), errorRate: 0.15
        )
        assertVotes(choice, placed: false, "two substitutions in the last barcode at 0.15")
        choice = try await chooseOne(first: first, readFirst: Self.substituted(first, at: [2]), errorRate: 0)
        assertVotes(choice, placed: false, "one substitution in the first barcode at 0")
        // An N is no substitution. TGGGCGAN has 7 counted bases, which allow floor(1.05) = 1 substitution at 0.15 and none
        // at 0.
        let withN = "TGGGCGAN"
        let anyBase = "TGGGCGAC"
        choice = try await chooseOne(first: withN, readFirst: anyBase, errorRate: 0)
        assertVotes(choice, placed: true, "any base at the N at 0")
        choice = try await chooseOne(first: withN, readFirst: Self.substituted(anyBase, at: [2]), errorRate: 0.15)
        assertVotes(choice, placed: true, "any base at the N and one other substitution at 0.15")
        choice = try await chooseOne(first: withN, readFirst: Self.substituted(anyBase, at: [2, 4]), errorRate: 0.15)
        assertVotes(choice, placed: false, "any base at the N and two other substitutions at 0.15")
        // TGGGCGNN has 6 counted bases, which allow floor(0.9) = 0 substitutions at 0.15, so an N is not in the length.
        let twoN = "TGGGCGNN"
        choice = try await chooseOne(first: twoN, readFirst: anyBase, errorRate: 0.15)
        assertVotes(choice, placed: true, "any bases at both Ns at 0.15")
        choice = try await chooseOne(first: twoN, readFirst: Self.substituted(anyBase, at: [2]), errorRate: 0.15)
        assertVotes(choice, placed: false, "one other substitution beside two Ns at 0.15")
    }

    /// The choice reads the first 10,000 records and no more (BIO-DUAL-FORM item 2, the count Detect reads).
    func testTheChoiceReadsAtMost10000Records() async throws {
        let row = Self.eight[0]
        // 5,025 reads on each strand, 10,050 in all.
        let reads = Self.reads([(row, true)], perOffset: 5_025)
        XCTAssertEqual(reads.count, 10_050)
        let choice = try await choose([row], reads, errorRate: 0)
        XCTAssertEqual(choice.readsRead, 10_000, "\(choice)")
        XCTAssertEqual(choice.reverseComplemented, 10_000, "\(choice)")
    }
}
