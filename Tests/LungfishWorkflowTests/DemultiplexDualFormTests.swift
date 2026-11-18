// DemultiplexDualFormTests.swift - Which way a run reads the secondary sequence of a Custom Definition at Both Ends
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-DUAL-FORM (ruling BIO-DUAL-FORM items 2 and 3, words UX-WORDS-2 section 3 (a) as BIO-WORDS-CONFIRM corrects
// them). At Both Ends with no sample sheet a run read the secondary sequence of a custom dual-index definition only as it
// appears at the end of the read. A file that lists the i5 primer's barcodes then placed no read and stopped at the chance
// check, and two rows with the same first barcode and secondary sequences that are reverse complements of each other got
// each other's reads. The run now reads the column the way the first 10,000 reads carry it, or stops in words. The run's
// choice is read by the label of the result's field, so the tests build at the base, which has no such field. Each test
// runs Cutadapt.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexDualFormTests: XCTestCase {
    var project: URL!
    var dir: URL!

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemultiplexDualFormTests-\(UUID().uuidString).lungfish", isDirectory: true)
        dir = project.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let project { try? FileManager.default.removeItem(at: project) }
    }

    typealias Row = (name: String, first: String, second: String)
    typealias Read = (name: String, sequence: String)

    static let threePairs: [Row] = [
        ("D01", "TGGGCGAA", "AGGAGTTA"), ("N701-S502", "TAAGGCGA", "CTCTCTAT"), ("T01", "GAAGTTGCCG", "GGATCTTCCC"),
    ]
    /// The swap layout of BIO-DUAL-FORM test (b): under each first barcode, the seconds 1 and 2 are exact reverse
    /// complements and the seconds 3 and 4 are one base from it.
    static let swap: [Row] = [("X", "TGGGCGAA"), ("Y", "CAGTCTAG")].flatMap { prefix, first in
        ["AGGAGTTA", "TAACTCCT", "CTCTCTAT", "ATAGTGAG", "GTAAGGAG", "ACTGCATA"].enumerated().map { index, second in
            (name: "\(prefix)-\(index + 1)", first: first, second: second)
        }
    }
    static let pair: [Row] = [("X", "TGGGCGAA", "AGGAGTTA"), ("Y", "TGGGCGAA", "TAACTCCT")]
    static let twoPairs: [Row] = [
        ("A", "TGGGCGAA", "AGGAGTTA"), ("B", "TGGGCGAA", "TAACTCCT"), ("C", "CAGTCTAG", "AGGAGTTA"), ("D", "CAGTCTAG", "TAACTCCT"),
    ]
    /// Eight rows with no two first barcodes within a base of each other, so no two rows collide.
    static let eight: [Row] = Array(zip(
        ["TAAGGCGA", "CGTACTAG", "AGGCAGAA", "TCCTGAGC", "GGACTCCT", "TAGGCATG", "CTCTCTAC", "CAGAGAGG"],
        ["TAGATCGC", "CTCTCTAT", "TATCCTCT", "AGAGTAGA", "GTAAGGAG", "ACTGCATA", "AAGGAGTA", "CTAAGCCT"]
    ).enumerated().map { index, pair in (name: "D0\(index + 1)", first: pair.0, second: pair.1) })
    /// A row whose secondary sequence is its own reverse complement, which both forms read the same way.
    static let selfReverse: [Row] = [("PAL", "TGGGCGAA", "GATCGATC")]

    static func rc(_ sequence: String) -> String { PlatformAdapters.reverseComplement(sequence) }

    /// Bases from a fixed seed, so every run reads the same file.
    struct Bases {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next(_ count: Int) -> String {
            String((0..<count).map { _ -> Character in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Array("ACGT")[Int((state >> 33) % 4)]
            })
        }
    }

    /// The reads of `rows`, `perOffset` reads at each offset and each on both strands, with the first barcode at the start
    /// and the secondary sequence at the end of the forward strand. A row in primer form lists the i5 primer's barcode, so
    /// its reads carry the reverse complement of the column. A read's name starts with its row.
    static func reads(_ rows: [(row: Row, primer: Bool)], perOffset: Int = 5, offsets: [Int] = [0]) -> [Read] {
        var bases = Bases()
        var reads: [Read] = []
        for (row, primer) in rows {
            let end = primer ? rc(row.second) : row.second
            for offset in offsets {
                for index in 0..<perOffset {
                    let forward = bases.next(offset) + row.first + bases.next(60) + end + bases.next(offset)
                    reads.append(("\(row.name)|F\(offset)-\(index)", forward))
                    reads.append(("\(row.name)|R\(offset)-\(index)", rc(forward)))
                }
            }
        }
        return reads
    }

    static func reads(_ rows: [Row], primer: Bool, perOffset: Int = 5, offsets: [Int] = [0]) -> [Read] {
        reads(rows.map { ($0, primer) }, perOffset: perOffset, offsets: offsets)
    }

    func writeFASTQ(_ reads: [Read]) throws -> URL {
        let url = dir.appendingPathComponent("reads-\(UUID().uuidString).fastq")
        let text = reads.map { "@\($0.name)\n\($0.sequence)\n+\n\(String(repeating: "I", count: $0.sequence.count))\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The definition "K" of `rows`, loaded as the command loads a Custom Definition.
    func kit(_ rows: [Row]) throws -> BarcodeKitDefinition {
        let csv = dir.appendingPathComponent("K-\(UUID().uuidString).csv")
        let text = "id,i7_sequence,i5_sequence\n" + rows.map { "\($0.name),\($0.first),\($0.second)\n" }.joined()
        try text.write(to: csv, atomically: true, encoding: .utf8)
        let kit = try BarcodeKitRegistry.loadCustomKit(from: csv, name: "K")
        XCTAssertEqual(kit.pairingMode, .fixedDual)
        XCTAssertEqual(kit.platform, .unknown)
        return kit
    }

    func config(_ kit: BarcodeKitDefinition, _ input: URL, _ output: URL, distance: Int, errorRate: Double) -> DemultiplexConfig {
        DemultiplexConfig(
            inputURL: input,
            barcodeKit: kit,
            outputDirectory: output,
            barcodeLocation: .bothEnds,
            errorRate: errorRate,
            maxDistanceFrom5Prime: distance,
            maxDistanceFrom3Prime: distance,
            trimBarcodes: true,
            threads: 1
        )
    }

    /// The run's choice as the result names it, read by the field's label so the tests build at the base, or "none".
    static func chosenForm(_ result: DemultiplexResult) -> String {
        guard let field = Mirror(reflecting: result).children.first(where: { $0.label == "secondaryForm" }),
              let choice = Mirror(reflecting: field.value).children.first?.value else { return "none" }
        return String(describing: choice)
    }

    struct Outcome {
        let form: String
        let placed: [String: [String]]
        let unassigned: Int
    }

    /// Runs `rows` on `reads` and gives the rows the reads of each published sample came from.
    func run(_ rows: [Row], _ reads: [Read], distance: Int = 0, errorRate: Double) async throws -> Outcome {
        let output = dir.appendingPathComponent("demux-\(UUID().uuidString)", isDirectory: true)
        let result = try await DemultiplexingPipeline().run(
            config: config(try kit(rows), try writeFASTQ(reads), output, distance: distance, errorRate: errorRate),
            progress: { _, _ in }
        )
        var placed: [String: [String]] = [:]
        for barcode in result.manifest.barcodes {
            let bundle = output.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
            let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle), barcode.barcodeID)
            for try await record in FASTQReader(validateSequence: false).records(from: fastq) {
                placed[barcode.barcodeID, default: []].append(String(record.identifier.prefix { $0 != "|" }))
            }
        }
        return Outcome(form: Self.chosenForm(result), placed: placed, unassigned: result.manifest.unassigned.readCount)
    }

    /// The words of the run's refusal, and whether it left a sample file in the output folder.
    func refusal(_ rows: [Row], _ reads: [Read], errorRate: Double = 0.15) async throws -> (words: String, published: Bool) {
        let output = dir.appendingPathComponent("demux-\(UUID().uuidString)", isDirectory: true)
        let config = config(try kit(rows), try writeFASTQ(reads), output, distance: 0, errorRate: errorRate)
        do {
            _ = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
            XCTFail("the run of \(rows.map(\.name)) published")
            return ("", true)
        } catch {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
            let words = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return (words, contents.contains { $0.hasSuffix(".\(FASTQBundle.directoryExtension)") })
        }
    }

    func assertEveryReadInItsOwnRow(_ rows: [Row], _ outcome: Outcome, perRow: Int, _ label: String) {
        for row in rows {
            XCTAssertEqual(outcome.placed[row.name] ?? [], Array(repeating: row.name, count: perRow), "\(label): \(row.name)")
        }
        XCTAssertEqual(Set(outcome.placed.keys).subtracting(rows.map(\.name)), [], label)
        XCTAssertEqual(outcome.unassigned, 0, label)
    }

    /// No em dash, semicolon or colon inside a sentence (`AffectedResultsTests.swift:107`).
    func assertProse(_ words: String, _ label: String) {
        XCTAssertFalse(words.contains("\u{2014}") || words.contains(";") || words.contains(":"), "\(label): \(words)")
    }

    // MARK: - (a) Primer form, every read in its own row

    /// The three pairs in primer form, read on both strands, at 0/0 with reads at offset 0 and at 3/3 with reads at
    /// offsets 0 and 3, at error 0 and 0.15: each read lands in its own row, read reverse complemented. At the base the
    /// run read the column only as written, placed no read and stopped at the chance check (BIO-DUAL-FORM test (a)).
    func testAPrimerFormFilePlacesEveryReadInItsOwnRow() async throws {
        for (distance, offsets) in [(0, [0]), (3, [0, 3])] {
            for errorRate in [0, 0.15] {
                let label = "(a) \(distance)/\(distance) e \(errorRate)"
                let outcome = try await run(
                    Self.threePairs, Self.reads(Self.threePairs, primer: true, offsets: offsets),
                    distance: distance, errorRate: errorRate
                )
                print("DUALFORM \(label): \(outcome.form)")
                XCTAssertTrue(outcome.form.hasPrefix("reverse-complemented "), "\(label): \(outcome.form)")
                XCTAssertEqual(
                    outcome.form,
                    distance == 0
                        ? "reverse-complemented readsRead 30 asWritten 0 reverseComplemented 30 disputed 0 rowsCarrying 3"
                        : "reverse-complemented readsRead 60 asWritten 0 reverseComplemented 60 disputed 0 rowsCarrying 3",
                    label
                )
                assertEveryReadInItsOwnRow(Self.threePairs, outcome, perRow: 10 * offsets.count, label)
            }
        }
    }

    // MARK: - (b) The swap layout

    /// The twelve rows of the swap layout in primer form: the rows that collide carry disputed reads, the others carry the
    /// form reverse complemented, so every read lands in its own row and none swaps. At the base the colliding rows got
    /// each other's reads (BIO-DUAL-FORM test (b)).
    func testThePrimerFormSwapLayoutSwapsNoRead() async throws {
        for errorRate in [0, 0.15] {
            let label = "(b) e \(errorRate)"
            let outcome = try await run(Self.swap, Self.reads(Self.swap, primer: true), errorRate: errorRate)
            print("DUALFORM \(label): \(outcome.form)")
            XCTAssertTrue(outcome.form.hasPrefix("reverse-complemented "), "\(label): \(outcome.form)")
            XCTAssertEqual(
                outcome.form,
                errorRate == 0
                    ? "reverse-complemented readsRead 120 asWritten 0 reverseComplemented 80 disputed 40 rowsCarrying 8"
                    : "reverse-complemented readsRead 120 asWritten 0 reverseComplemented 40 disputed 80 rowsCarrying 4",
                label
            )
            assertEveryReadInItsOwnRow(Self.swap, outcome, perRow: 10, label)
        }
    }

    // MARK: - (c) Reads that fit both forms

    /// The rows X and Y alone, in either form, fit both ways, so the run stops in words and publishes nothing. At the base
    /// it placed them, swapped in primer form (BIO-DUAL-FORM test (c), UX-WORDS-2 section 3 (a)).
    func testTwoRowsThatCollideStopTheRunInEitherForm() async throws {
        let expected = "The rows X and Y of \"K\" have first barcodes that match and secondary sequences that are reverse "
            + "complements of each other, each within the error rate. The first reads fit these rows both ways, with the "
            + "secondary sequence as it appears at the end of the read and as the i5 primer's barcode, so Demultiplex Barcodes "
            + "cannot tell which sample each read belongs to, and nothing was run. If one of these rows is not in this pool, "
            + "remove it from the definition and run again."
        for primer in [true, false] {
            for errorRate in [0, 0.15] {
                let (words, published) = try await refusal(Self.pair, Self.reads(Self.pair, primer: primer), errorRate: errorRate)
                XCTAssertEqual(words, expected, "primer \(primer) e \(errorRate)")
                XCTAssertFalse(published, "primer \(primer) e \(errorRate)")
                assertProse(words, "dualFormUndecided")
            }
        }
    }

    /// Two colliding pairs name their four rows in the definition's order, in the words for more than two rows.
    func testTwoCollidingPairsNameTheirFourRows() async throws {
        let (words, published) = try await refusal(Self.twoPairs, Self.reads(Self.twoPairs, primer: true))
        XCTAssertEqual(words, "The rows A, B, C and D of \"K\" come in pairs, and the two rows of each pair have first barcodes "
                       + "that match and secondary sequences that are reverse complements of each other, each within the error "
                       + "rate. The first reads fit these rows both ways, with the secondary sequence as it appears at the end of "
                       + "the read and as the i5 primer's barcode, so Demultiplex Barcodes cannot tell which sample each read "
                       + "belongs to, and nothing was run. If one row of a pair is not in this pool, remove it from the "
                       + "definition and run again.")
        XCTAssertFalse(published)
        assertProse(words, "dualFormUndecided, four rows")
    }

    // MARK: - (d) A file of mixed forms

    /// Eight rows that do not collide, written in two forms in one file, stop the run in words that name the rows of the
    /// form fewer rows carry, or both sets on a tie, the reverse-complemented set first. At the base the run published
    /// with the rows of the other form empty (BIO-DUAL-FORM test (d), UX-WORDS-2 section 3 (a)).
    func testAFileOfMixedFormsStopsTheRunNamingTheOtherRows() async throws {
        let advice = " Write the secondary sequence of every row the same way, either as it appears at the end of the read or "
            + "as the i5 primer's barcode, and run again."
        let cases: [(primerRows: Int, words: String)] = [
            (4, "In the first reads, the rows D01, D02, D03 and D04 of \"K\" carry the secondary sequence reverse complemented "
                + "and the rows D05, D06, D07 and D08 carry it as written, so nothing was run." + advice),
            (7, "In the first reads, most rows of \"K\" carry the secondary sequence reverse complemented, but the row D08 "
                + "carries it as written, so nothing was run." + advice),
        ]
        for (primerRows, expected) in cases {
            let rows = Self.eight.enumerated().map { ($0.element, $0.offset < primerRows) }
            let (words, published) = try await refusal(Self.eight, Self.reads(rows))
            XCTAssertEqual(words, expected, "\(primerRows) rows in primer form")
            XCTAssertFalse(published)
            assertProse(words, "dualFormMixed")
        }
        // Seven rows as written and the eighth in primer form name the eighth as reverse complemented.
        let rows = Self.eight.enumerated().map { ($0.element, $0.offset == 7) }
        let (words, _) = try await refusal(Self.eight, Self.reads(rows))
        XCTAssertEqual(words, "In the first reads, most rows of \"K\" carry the secondary sequence as written, but the row D08 "
                       + "carries it reverse complemented, so nothing was run." + advice)
    }

    // MARK: - (e) A file written as the read ends show it

    /// The three pairs as written give the lines of the base byte for byte and place every read in its own row, read as
    /// written. These hold at the base too (BIO-DUAL-FORM test (e) and item 7).
    func testAFileAsTheReadEndsShowItKeepsTheLinesAndCountsOfTheBase() async throws {
        for (distance, offsets) in [(0, [0]), (3, [0, 3])] {
            let kit = try kit(Self.threePairs)
            let input = try writeFASTQ(Self.reads(Self.threePairs, primer: false, offsets: offsets))
            let work = dir.appendingPathComponent("lines-\(distance)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let adapters = try await DemultiplexingPipeline().createAdapterConfiguration(
                for: config(kit, input, dir.appendingPathComponent("unused"), distance: distance, errorRate: 0.15),
                workDirectory: work
            )
            XCTAssertEqual(try String(contentsOf: adapters.adapterFASTA, encoding: .utf8),
                           Self.writtenLines(Self.threePairs, distance: distance), "\(distance)/\(distance)")
            for errorRate in [0, 0.15] {
                let label = "(e) \(distance)/\(distance) e \(errorRate)"
                let outcome = try await run(
                    Self.threePairs, Self.reads(Self.threePairs, primer: false, offsets: offsets),
                    distance: distance, errorRate: errorRate
                )
                print("DUALFORM \(label): \(outcome.form)")
                XCTAssertFalse(outcome.form.hasPrefix("reverse-complemented"), "\(label): \(outcome.form)")
                XCTAssertEqual(
                    outcome.form,
                    distance == 0
                        ? "as-written readsRead 30 asWritten 30 reverseComplemented 0 disputed 0 rowsCarrying 3"
                        : "as-written readsRead 60 asWritten 60 reverseComplemented 0 disputed 0 rowsCarrying 3",
                    label
                )
                assertEveryReadInItsOwnRow(Self.threePairs, outcome, perRow: 10 * offsets.count, label)
            }
        }
    }

    /// The lines the writer of the base gives for `rows` as written at the distance `distance` at both ends.
    static func writtenLines(_ rows: [Row], distance: Int) -> String {
        func wildcard(_ count: Int) -> String { count == 0 ? "" : "N{\(count)}" }
        var lines: [String] = []
        for row in rows {
            for (suffix, front, back) in [("__lge_forward", row.first, row.second),
                                          ("__lge_reverse_complement", rc(row.second), rc(row.first))] {
                for offset5 in 0...distance {
                    for offset3 in 0...distance {
                        lines.append(">\(row.name)\(suffix)")
                        lines.append("^\(wildcard(offset5))\(front)...\(back)\(wildcard(offset3))$")
                    }
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - (f) A secondary sequence that is its own reverse complement

    /// Both forms read a self-reverse secondary sequence the same way, so its reads are no vote and no dispute, and the
    /// run reads the column as written with no refusal, in either form (BIO-DUAL-FORM test (f)).
    func testASelfReverseSecondarySequenceRunsAsAtTheBase() async throws {
        for primer in [true, false] {
            let label = "(f) primer \(primer)"
            let outcome = try await run(Self.selfReverse, Self.reads(Self.selfReverse, primer: primer), errorRate: 0.15)
            print("DUALFORM \(label): \(outcome.form)")
            XCTAssertFalse(outcome.form.hasPrefix("reverse-complemented"), "\(label): \(outcome.form)")
            XCTAssertEqual(
                outcome.form, "as-written readsRead 10 asWritten 0 reverseComplemented 0 disputed 0 rowsCarrying 0", label
            )
            assertEveryReadInItsOwnRow(Self.selfReverse, outcome, perRow: 10, label)
        }
    }
}
