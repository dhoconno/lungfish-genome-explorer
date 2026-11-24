// DemultiplexOneEndLineCapTests.swift - A distance typed for one read end gives Cutadapt a bounded number of lines
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

/// The one-end writers of the adapter file build a line for each barcode and each distance from 0 to the one typed, and
/// built an array of every distance up to it for both ends, so a typed `Int.max` trapped the process and 10^8 asked for
/// gigabytes (DEMUX-ONEEND-INTMAX-CRASH, DEMUX-CAP-BIO re-rate). The route is bounded by the cap of the dual route,
/// ``DemultiplexingPipeline/observedPairLineCap``, as the barcodes times the strands times one more than the distance of
/// the end the writer reads. The refusal is read by its name and values (`Mirror`) so that this file builds at the base,
/// where the case `tooManyOneEndSearchLines` does not exist, and the red tests can run there, each alone, since a trap ends
/// the test host.
final class DemultiplexOneEndLineCapTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// A short-read single-index kit of 12 barcodes, the route that reaches `writeSingleEndAdapterFASTA`.
    static let kit = BarcodeKitRegistry.truseqSingleA
    static let cap = DemultiplexingPipeline.observedPairLineCap

    typealias Attempt = (refusal: DemultiplexError?, file: URL?)

    /// What `createAdapterConfiguration` does for `kit` at `location`, the call the dialog's background check, `preflight` and
    /// `run` make: the refusal it throws, and the adapter file it left, nil when it left none.
    private func adapterAttempt(
        _ kit: BarcodeKitDefinition = DemultiplexOneEndLineCapTests.kit, location: BarcodeLocation, fivePrime: Int,
        threePrime: Int, sheet: [FASTQSampleBarcodeAssignment] = [], symmetry: BarcodeSymmetryMode? = nil
    ) async throws -> Attempt {
        let input = folder.appendingPathComponent("reads.fastq")
        try "@r0\nACGTACGTACGT\n+\nIIIIIIIIIIII\n".write(to: input, atomically: true, encoding: .utf8)
        let work = folder.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let config = DemultiplexConfig(
            inputURL: input, barcodeKit: kit, outputDirectory: folder.appendingPathComponent("out", isDirectory: true),
            barcodeLocation: location, symmetryMode: symmetry, errorRate: 0.15, maxDistanceFrom5Prime: fivePrime,
            maxDistanceFrom3Prime: threePrime,
            engine: .cutadapt, sampleAssignments: sheet
        )
        var refusal: DemultiplexError?
        do {
            _ = try await DemultiplexingPipeline().createAdapterConfiguration(for: config, workDirectory: work)
        } catch let error as DemultiplexError {
            refusal = error
        }
        let file = work.appendingPathComponent("adapters.fasta")
        return (refusal, FileManager.default.fileExists(atPath: file.path) ? file : nil)
    }

    private func records(_ url: URL) throws -> Int {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix(">") }.count
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// The values of a `tooManyOneEndSearchLines` refusal by label, nil for any other refusal or none.
    private func oneEndValues(_ error: DemultiplexError?) -> [String: Any]? {
        guard let error, let child = Mirror(reflecting: error).children.first,
              child.label == "tooManyOneEndSearchLines" else { return nil }
        var values: [String: Any] = [:]
        for part in Mirror(reflecting: child.value).children {
            if let label = part.label { values[label] = part.value }
        }
        return values
    }

    private func assertRefused(
        _ result: Attempt, kit: BarcodeKitDefinition, barcodes: Int, fromThreePrime: Bool, distance: Int, lines: Int,
        _ setting: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let values = oneEndValues(result.refusal) else {
            return XCTFail(
                "\(setting) was refused as \(String(describing: result.refusal)), not for its lines, and \(result.file == nil ? "wrote no adapter file" : "wrote an adapter file")",
                file: file, line: line
            )
        }
        XCTAssertEqual(values["kitName"] as? String, kit.displayName, setting, file: file, line: line)
        XCTAssertEqual(values["barcodes"] as? Int, barcodes, setting, file: file, line: line)
        XCTAssertEqual(values["fromThreePrime"] as? Bool, fromThreePrime, setting, file: file, line: line)
        XCTAssertEqual(values["distance"] as? Int, distance, setting, file: file, line: line)
        XCTAssertEqual(values["lines"] as? Int, lines, setting, file: file, line: line)
        XCTAssertNil(result.file, "\(setting): no adapter file is written", file: file, line: line)
    }

    /// The words of the refusal as the re-rate gives them (DEMUX-CAP-BIO, section 5, "The words"), written out to the letter.
    /// `lines` is the grouped count; the distance and the barcode count below 1,000 are written as they are.
    static func words(kit: String, barcodes: Int, fromThreePrime: Bool, distance: Int, lines: String) -> String {
        let side = fromThreePrime ? "end" : "start"
        let name = fromThreePrime ? "3' Distance" : "5' Distance"
        let flag = fromThreePrime ? "--max-distance-3prime" : "--max-distance-5prime"
        let searched = barcodes == 1 ? "the barcode of \"\(kit)\"" : "the \(barcodes) barcodes of \"\(kit)\""
        let each = barcodes == 1 ? "one for each \(side) distance" : "one for each barcode and \(side) distance"
        return "Searching \(searched) up to \(distance) bases from the \(side) of the read takes \(lines) Cutadapt search lines, \(each). "
            + "That is more than the 6,000 a run can take, since Cutadapt spends time on every line before it reads the first read, so nothing was run. "
            + "If the barcodes sit inside a known adapter sequence, trim that sequence from the reads first and run again with the \(name) at 0, "
            + "or lower the \(name) until the lines fit (on the command line, \(flag))."
    }

    // MARK: - R1: a typed Int.max (DEMUX-ONEEND-INTMAX-CRASH)

    /// A 5' Distance of `Int.max` with 5' End picked trapped at `Array(0...Int.max)` in the writer, in the app's background
    /// check and in the CLI child. It is refused in words, with no adapter file. Base: the host traps (signal 5).
    func testAFiveDistanceOfIntMaxAtFivePrimeEndIsRefusedInWordsAndWritesNothing() async throws {
        let kit = Self.kit
        let result = try await adapterAttempt(location: .fivePrime, fivePrime: Int.max, threePrime: 0)
        assertRefused(result, kit: kit, barcodes: kit.barcodes.count, fromThreePrime: false, distance: Int.max, lines: Int.max, "5' End at Int.max")
        let words = try XCTUnwrap(result.refusal?.errorDescription)
        XCTAssertTrue(words.contains("nothing was run"), words)
        XCTAssertTrue(words.contains("--max-distance-5prime"), words)
        XCTAssertEqual(words, Self.words(
            kit: kit.displayName, barcodes: kit.barcodes.count, fromThreePrime: false, distance: Int.max,
            lines: "9,223,372,036,854,775,807"
        ))
    }

    /// The same at 3' End with a 3' Distance of `Int.max`. Base: the host traps (signal 5).
    func testAThreeDistanceOfIntMaxAtThreePrimeEndIsRefusedInWordsAndWritesNothing() async throws {
        let kit = Self.kit
        let result = try await adapterAttempt(location: .threePrime, fivePrime: 0, threePrime: Int.max)
        assertRefused(result, kit: kit, barcodes: kit.barcodes.count, fromThreePrime: true, distance: Int.max, lines: Int.max, "3' End at Int.max")
        let words = try XCTUnwrap(result.refusal?.errorDescription)
        XCTAssertTrue(words.contains("--max-distance-3prime"), words)
    }

    // MARK: - R2: the side the writer does not read is not refused

    /// A stale 3' Distance of `Int.max` with 5' End picked must run as before, with the 5' Distance: 12 x 9 records. The
    /// writer builds the unused side as well. Base: the host traps (signal 5).
    func testAnUnusedThreeDistanceOfIntMaxAtFivePrimeEndRunsWithTheFiveDistance() async throws {
        let result = try await adapterAttempt(location: .fivePrime, fivePrime: 8, threePrime: Int.max)
        XCTAssertNil(result.refusal, "a 3' Distance of Int.max with 5' End picked is not refused")
        let file = try XCTUnwrap(result.file)
        XCTAssertEqual(try records(file), Self.kit.barcodes.count * 9)
    }

    /// The same at 3' End with a stale 5' Distance of `Int.max`. Base: the host traps (signal 5).
    func testAnUnusedFiveDistanceOfIntMaxAtThreePrimeEndRunsWithTheThreeDistance() async throws {
        let result = try await adapterAttempt(location: .threePrime, fivePrime: Int.max, threePrime: 8)
        XCTAssertNil(result.refusal, "a 5' Distance of Int.max with 3' End picked is not refused")
        let file = try XCTUnwrap(result.file)
        XCTAssertEqual(try records(file), Self.kit.barcodes.count * 9)
    }

    // MARK: - R3: the boundary

    /// `fit` is the last distance whose lines, 12 x (fit + 1), are 6,000 or fewer. It writes them, and the next distance is
    /// refused with its count, 12 x (fit + 2), at each end. Base: red by assertion, the next distance is written.
    func testTheCapAdmitsTheLastFittingDistanceAtEachEndAndRefusesTheNext() async throws {
        let kit = Self.kit
        let n = kit.barcodes.count
        let fit = Self.cap / n - 1
        for fromThreePrime in [false, true] {
            let location: BarcodeLocation = fromThreePrime ? .threePrime : .fivePrime
            let end = fromThreePrime ? "3'" : "5'"
            let fits = try await adapterAttempt(location: location, fivePrime: fromThreePrime ? 0 : fit, threePrime: fromThreePrime ? fit : 0)
            XCTAssertNil(fits.refusal, "\(end) End at \(fit) is not refused")
            if let file = fits.file {
                XCTAssertEqual(try records(file), n * (fit + 1), "\(end) End at \(fit)")
            } else {
                XCTFail("\(end) End at \(fit) wrote no adapter file")
            }
            let over = try await adapterAttempt(location: location, fivePrime: fromThreePrime ? 0 : fit + 1, threePrime: fromThreePrime ? fit + 1 : 0)
            assertRefused(over, kit: kit, barcodes: n, fromThreePrime: fromThreePrime, distance: fit + 1, lines: n * (fit + 2), "\(end) End at \(fit + 1)")
        }
    }

    // MARK: - R4: the control, a run of 6,000 lines or fewer writes the file it wrote

    /// The 5' End file at 8/0 and the 3' End file at 0/8 are the rows the writer gives (`>id` then `^N{k}SEQ`, or `SEQ` then
    /// `N{k}$`, for k from 0 to 8), and their SHA-256 is the one a run of the base gave (BIO 3). Green at the base and the head.
    static let digestFivePrimeEightZero = "6d427606b1b01b0e1aa0b4657425ed439c2dea5f28cb5ca9250357e75691c6d9"
    static let digestThreePrimeZeroEight = "8cdfb7803b3b6cb696c7bf5f87d873af76064f756a9678c1ebe73d4061133f08"

    func testTheEightBaseFilesAtEachEndAreTheFilesTheWriterGaveBeforeTheCap() async throws {
        let kit = Self.kit
        func wildcard(_ k: Int) -> String { k > 0 ? "N{\(k)}" : "" }
        func file(_ pattern: (String, Int) -> String) -> String {
            kit.barcodes.flatMap { barcode in
                (0...8).flatMap { [">\(barcode.id)", pattern(barcode.i7Sequence.uppercased(), $0)] }
            }.joined(separator: "\n") + "\n"
        }
        let five = try await adapterAttempt(location: .fivePrime, fivePrime: 8, threePrime: 0)
        let fiveFile = try XCTUnwrap(five.file)
        XCTAssertNil(five.refusal)
        XCTAssertEqual(try String(contentsOf: fiveFile, encoding: .utf8), file { "^\(wildcard($1))\($0)" })
        XCTAssertEqual(try sha256(fiveFile), Self.digestFivePrimeEightZero, "5' End 8/0")
        let three = try await adapterAttempt(location: .threePrime, fivePrime: 0, threePrime: 8)
        let threeFile = try XCTUnwrap(three.file)
        XCTAssertNil(three.refusal)
        XCTAssertEqual(try String(contentsOf: threeFile, encoding: .utf8), file { "\($0)\(wildcard($1))$" })
        XCTAssertEqual(try sha256(threeFile), Self.digestThreePrimeZeroEight, "3' End 0/8")
    }

    // MARK: - The words at 3' End and for one barcode

    /// 3' End at 500 gives 12 x 501 = 6,012 lines: the words name the end, the 3' Distance and `--max-distance-3prime`.
    /// Base: red by assertion, the file is written.
    func testTheRefusalAtThreePrimeEndNamesTheEndAndTheThreeDistance() async throws {
        let kit = Self.kit
        let result = try await adapterAttempt(location: .threePrime, fivePrime: 0, threePrime: 500)
        assertRefused(result, kit: kit, barcodes: 12, fromThreePrime: true, distance: 500, lines: 6012, "3' End at 500")
        XCTAssertEqual(result.refusal?.errorDescription, Self.words(
            kit: kit.displayName, barcodes: 12, fromThreePrime: true, distance: 500, lines: "6,012"
        ))
    }

    /// One barcode at 5' End at 6,000 gives 6,001 lines: "the barcode of", "one for each start distance". Base: red by
    /// assertion, the file is written.
    func testTheRefusalOfOneBarcodeNamesOneBarcodeAndOneLineForEachDistance() async throws {
        let one = BarcodeKitDefinition(
            id: "one-barcode", displayName: "One Barcode Kit", platform: .illumina, kitType: .truseq,
            barcodes: [Self.kit.barcodes[0]]
        )
        let result = try await adapterAttempt(one, location: .fivePrime, fivePrime: 6000, threePrime: 0)
        assertRefused(result, kit: one, barcodes: 1, fromThreePrime: false, distance: 6000, lines: 6001, "one barcode at 6000")
        XCTAssertEqual(result.refusal?.errorDescription, Self.words(
            kit: "One Barcode Kit", barcodes: 1, fromThreePrime: false, distance: 6000, lines: "6,001"
        ))
    }

    // MARK: - The linked writer's calls, off Both Ends and from a sample sheet

    /// A built-in dual kit at 5' End reached `writeLinkedAdapterFASTA` with no cap off Both Ends. Base: the host traps (signal 5).
    func testADualKitAtFivePrimeEndWithAFiveDistanceOfIntMaxIsRefusedInWords() async throws {
        let kit = BarcodeKitRegistry.truseqHTDual
        let pairs = kit.barcodes.filter { $0.i5Sequence != nil }.count
        let result = try await adapterAttempt(kit, location: .fivePrime, fivePrime: Int.max, threePrime: 0)
        assertRefused(result, kit: kit, barcodes: pairs, fromThreePrime: false, distance: Int.max, lines: Int.max, "dual kit, 5' End at Int.max")
    }

    // MARK: - The sample-sheet branch (the linked writer's call at DemultiplexingPipeline.swift:1387)

    /// A sheet reaches that branch with a symmetry other than single-end on a kit that is neither dual nor a long-read symmetric
    /// kit. A single-index kit with its default symmetry takes the first branch (`:1258`), which builds no offsets array, so the
    /// symmetry is given. One sample whose pair, the first two barcodes of the kit, reads as two strands.
    private func sheetAttempt(location: BarcodeLocation, fivePrime: Int, threePrime: Int) async throws -> Attempt {
        let kit = Self.kit
        let sheet = [FASTQSampleBarcodeAssignment(
            sampleID: "S1", forwardBarcodeID: kit.barcodes[0].id, reverseBarcodeID: kit.barcodes[1].id
        )]
        return try await adapterAttempt(
            kit, location: location, fivePrime: fivePrime, threePrime: threePrime, sheet: sheet, symmetry: .symmetric
        )
    }

    /// One sample, two strands: 2 x (d + 1) lines at 5' End. 2,999 gives 6,000 records and is written, 3,000 gives 6,002 and is
    /// refused. Base: red by assertion at 3,000, the file is written.
    func testASampleSheetAtFivePrimeEndFitsAt2999AndIsRefusedAt3000() async throws {
        let fits = try await sheetAttempt(location: .fivePrime, fivePrime: 2_999, threePrime: 0)
        XCTAssertNil(fits.refusal, "the sheet at 5' End at 2999 is not refused")
        XCTAssertEqual(try records(XCTUnwrap(fits.file)), 6_000)
        let over = try await sheetAttempt(location: .fivePrime, fivePrime: 3_000, threePrime: 0)
        assertRefused(over, kit: Self.kit, barcodes: 1, fromThreePrime: false, distance: 3_000, lines: 6_002, "the sheet at 5' End at 3000")
    }

    /// Base: the host traps (signal 5), so run it alone.
    func testASampleSheetAtFivePrimeEndWithAFiveDistanceOfIntMaxIsRefusedInWords() async throws {
        let over = try await sheetAttempt(location: .fivePrime, fivePrime: Int.max, threePrime: 0)
        assertRefused(over, kit: Self.kit, barcodes: 1, fromThreePrime: false, distance: Int.max, lines: Int.max, "the sheet at 5' End at Int.max")
    }

    /// At Both Ends the sheet is bounded by the dual route's cap, 2 x (d5 + 1) x (d3 + 1) lines. 54/53 gives 5,940 records and
    /// is written, 54/54 gives 6,050 and is refused as `tooManySearchLines`. Base: red by assertion at 54/54.
    func testASampleSheetAtBothEndsFitsAt54And53AndIsRefusedAt54And54() async throws {
        let fits = try await sheetAttempt(location: .bothEnds, fivePrime: 54, threePrime: 53)
        XCTAssertNil(fits.refusal, "the sheet at 54/53 is not refused")
        XCTAssertEqual(try records(XCTUnwrap(fits.file)), 5_940)
        let over = try await sheetAttempt(location: .bothEnds, fivePrime: 54, threePrime: 54)
        guard case .tooManySearchLines(_, let pairs, let five, let three, let lines)? = over.refusal else {
            return XCTFail("the sheet at 54/54 was refused as \(String(describing: over.refusal)), not for its lines")
        }
        XCTAssertEqual([pairs, five, three, lines], [1, 54, 54, 6_050])
        XCTAssertNil(over.file)
    }

    // MARK: - The words for pairs (DEMUX-CAP-2-UX fix 1)

    /// A sample sheet at one end and a dual kit off Both Ends give each pair two strands (`linkedStrandCount`), so the lines are
    /// twice the pairs times one more than the distance, and the words name the pairs and their strands, not "one for each
    /// barcode". 96 pairs at 5' and a distance of 31 are 96 x 2 x 32 = 6,144 lines. Head: red, the words say "the 96 barcodes"
    /// and "one for each barcode and start distance".
    func testTheRefusalOfPairsNamesTheStrandsOfEachPair() {
        let error = DemultiplexError.tooManyOneEndSearchLines(kitName: "Pair Kit", barcodes: 96, fromThreePrime: false, distance: 31, lines: 6_144)
        XCTAssertEqual(
            error.errorDescription,
            "Searching the 96 barcode pairs of \"Pair Kit\" up to 31 bases from the start of the read takes 6,144 Cutadapt search lines, one for each strand of each pair and start distance. "
                + "That is more than the 6,000 a run can take, since Cutadapt spends time on every line before it reads the first read, so nothing was run. "
                + "If the barcodes sit inside a known adapter sequence, trim that sequence from the reads first and run again with the 5' Distance at 0, "
                + "or lower the 5' Distance until the lines fit (on the command line, --max-distance-5prime)."
        )
    }

    /// One pair at 3' End and a distance of 3,000 is 2 x 3,001 = 6,002 lines: "the barcode pair", "one for each strand and end
    /// distance". Head: red, the words say "the barcode" and "one for each end distance".
    func testTheRefusalOfOnePairNamesTheStrands() {
        let error = DemultiplexError.tooManyOneEndSearchLines(kitName: "Pair Kit", barcodes: 1, fromThreePrime: true, distance: 3_000, lines: 6_002)
        XCTAssertEqual(
            error.errorDescription,
            "Searching the barcode pair of \"Pair Kit\" up to 3000 bases from the end of the read takes 6,002 Cutadapt search lines, one for each strand and end distance. "
                + "That is more than the 6,000 a run can take, since Cutadapt spends time on every line before it reads the first read, so nothing was run. "
                + "If the barcodes sit inside a known adapter sequence, trim that sequence from the reads first and run again with the 3' Distance at 0, "
                + "or lower the 3' Distance until the lines fit (on the command line, --max-distance-3prime)."
        )
    }
}
