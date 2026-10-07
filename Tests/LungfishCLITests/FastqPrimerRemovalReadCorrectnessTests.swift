// FastqPrimerRemovalReadCorrectnessTests.swift - fastq primer-remove trims the 5' primer and keeps mates together
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Operations dialog runs `lungfish-cli fastq primer-remove` for primer
// trimming: bbduk with a literal primer, or cutadapt linked primers from a
// reference FASTA. Measured with the managed bbmap 40.02 and cutadapt 5.2 on
// the SARS-CoV-2 amplicons below (lane A8):
//
// - bbduk ran ktrim=r, which trims a match and every base to its right
//   (bbduk.sh, and BBDukGuide.txt: "ktrim=l is for left-trimming (5'
//   adapters)"). Every read that starts with the primer was cut to 0 bases
//   and dropped. 50 single reads gave 20, the reads that never had it.
// - ktrim=l with bbduk's default rcomp=t also left-trims at a reverse
//   complement match, so a read that runs through into the other end of a
//   short amplicon kept only the bases after that primer.
// - ktrim=l with no window trims at a primer of another amplicon inside a
//   full-length read of a tiled scheme, and the read loses everything before it.
// - Both engines judged every record on its own, so a mate dropped by the
//   trim orphaned its partner in an interleaved file.
//
// Amplicons are ARTIC nCoV-2019 pairs 5 and 6 at their MT192765.1
// coordinates (Tests/Fixtures/sarscov2/test.bed) on the fixture genome.

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class FastqPrimerRemovalReadCorrectnessTests: XCTestCase {
    private var root: URL!
    private var amplicons: Amplicons!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-primer-remove")
        amplicons = try Amplicons(repositoryRoot: CLITestBinaryResolver.repositoryRoot(containing: #filePath))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Fixture

    /// ARTIC pairs 5 and 6 cut from the fixture genome.
    struct Amplicons {
        let left5: String
        let right5: String
        let left6: String
        let right6: String
        let amplicon5: String
        let amplicon6: String
        let genome: String

        init(repositoryRoot: URL) throws {
            let fixtures = repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2")
            genome = try String(contentsOf: fixtures.appendingPathComponent("genome.fasta"), encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.hasPrefix(">") }
                .joined()
            var primers: [String: (start: Int, end: Int)] = [:]
            for line in try String(contentsOf: fixtures.appendingPathComponent("test.bed"), encoding: .utf8).split(separator: "\n") {
                let fields = line.split(separator: "\t")
                guard fields.count >= 4, let start = Int(fields[1]), let end = Int(fields[2]) else { continue }
                primers[String(fields[3])] = (start, end)
            }
            let genome = self.genome
            func slice(_ name: String) throws -> (start: Int, end: Int) {
                try XCTUnwrap(primers[name], "test.bed lists \(name)")
            }
            func bases(_ start: Int, _ end: Int) -> String {
                let from = genome.index(genome.startIndex, offsetBy: start)
                let to = genome.index(genome.startIndex, offsetBy: end)
                return String(genome[from..<to])
            }
            let l5 = try slice("nCoV-2019_5_LEFT"), r5 = try slice("nCoV-2019_5_RIGHT")
            let l6 = try slice("nCoV-2019_6_LEFT"), r6 = try slice("nCoV-2019_6_RIGHT")
            left5 = bases(l5.start, l5.end)
            right5 = Self.reverseComplement(bases(r5.start, r5.end))
            left6 = bases(l6.start, l6.end)
            right6 = Self.reverseComplement(bases(r6.start, r6.end))
            amplicon5 = bases(l5.start, r5.end)
            amplicon6 = bases(l6.start, r6.end)
        }

        static func reverseComplement(_ sequence: String) -> String {
            let complement: [Character: Character] = ["A": "T", "C": "G", "G": "C", "T": "A", "N": "N"]
            return String(sequence.reversed().map { complement[$0] ?? "N" })
        }

        /// A 110-base insert that a 110-base read runs through: the left
        /// primer, 60 bases behind it, and the right primer's reverse complement.
        func shortInsert(_ index: Int) -> String {
            let start = genome.index(genome.startIndex, offsetBy: 1264 + index * 7)
            let end = genome.index(start, offsetBy: 60)
            return left5 + String(genome[start..<end]) + Self.reverseComplement(right5)
        }

        /// The fragments of the paired fixture, mate 1 then mate 2:
        /// 10 pairs of each long amplicon at 2x150 (no read-through), 3
        /// read-through pairs of a short insert, and 2 pairs whose mate 1 is
        /// the primer and 5 bases.
        var pairs: [(name: String, mate1: String, mate2: String)] {
            var pairs: [(String, String, String)] = []
            for index in 0..<10 {
                pairs.append(("long5_\(index)", String(amplicon5.prefix(150)), String(Self.reverseComplement(amplicon5).prefix(150))))
                pairs.append(("long6_\(index)", String(amplicon6.prefix(150)), String(Self.reverseComplement(amplicon6).prefix(150))))
            }
            for index in 0..<3 {
                let insert = shortInsert(index)
                pairs.append(("short_\(index)", insert, Self.reverseComplement(insert)))
            }
            for index in 0..<2 {
                let start = amplicon5.index(amplicon5.startIndex, offsetBy: left5.count + index)
                let end = amplicon5.index(start, offsetBy: 5)
                pairs.append(("dimer_\(index)", left5 + String(amplicon5[start..<end]), String(Self.reverseComplement(amplicon5).prefix(150))))
            }
            return pairs
        }
    }

    private func record(_ name: String, _ sequence: String) -> String {
        "@\(name)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
    }

    private func writeInterleaved(_ pairs: [(name: String, mate1: String, mate2: String)], to url: URL) throws {
        try pairs.map { record("\($0.name) 1:N:0:1", $0.mate1) + record("\($0.name) 2:N:0:1", $0.mate2) }
            .joined()
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func reads(_ url: URL) async throws -> [(name: String, sequence: String)] {
        try await InterleavedFASTQFixture.readRecords(at: url).map { ($0.identifier, $0.sequence) }
    }

    private func runPrimerRemove(_ arguments: [String]) async throws {
        try await FastqPrimerRemovalSubcommand.parse(arguments).run()
    }

    /// The arguments the dialog records for a literal primer.
    private func literalArguments(_ input: URL, _ output: URL) -> [String] {
        [input.path, "--literal", amplicons.left5, "--kmer", "15", "--mink", "11", "--hdist", "1", "-o", output.path]
    }

    // MARK: - bbduk, literal primer

    func testLiteralPrimerIsTrimmedFromTheStartOfEachSingleReadAndTheReadIsKept() async throws {
        try await requireNativeTool(.bbduk)
        let inputURL = root.appendingPathComponent("single.fastq")
        let pairs = amplicons.pairs
        try pairs.map { record($0.name, $0.mate1) }.joined().write(to: inputURL, atomically: true, encoding: .utf8)
        let outputURL = root.appendingPathComponent("single.trimmed.fastq")
        try await runPrimerRemove(literalArguments(inputURL, outputURL))

        let output = try await reads(outputURL)
        let primer = amplicons.left5
        let expected = pairs.compactMap { pair -> (String, String)? in
            guard pair.mate1.hasPrefix(primer) else { return (pair.name, pair.mate1) }
            let trimmed = String(pair.mate1.dropFirst(primer.count))
            return trimmed.count >= 10 ? (pair.name, trimmed) : nil
        }
        XCTAssertEqual(output.map(\.name), expected.map(\.0), "every read is kept but the two that are only the primer and 5 bases")
        XCTAssertEqual(output.map(\.sequence), expected.map(\.1), "the primer and nothing else is trimmed from each read that starts with it")
    }

    func testLiteralPrimerOnInterleavedPairsKeepsEveryPairWholeAndTheReadThroughMates() async throws {
        try await requireNativeTool(.bbduk)
        let inputURL = root.appendingPathComponent("interleaved.fastq")
        let pairs = amplicons.pairs
        try writeInterleaved(pairs, to: inputURL)
        let outputURL = root.appendingPathComponent("interleaved.trimmed.fastq")
        try await runPrimerRemove(literalArguments(inputURL, outputURL))

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        InterleavedFASTQFixture.assertWholePairs(records)
        let primer = amplicons.left5
        let kept = pairs.filter { !$0.name.hasPrefix("dimer") }
        XCTAssertEqual(records.count, kept.count * 2, "only the pairs whose mate 1 is the primer and 5 bases are dropped, whole")
        var expected: [String] = []
        for pair in kept {
            expected.append(pair.mate1.hasPrefix(primer) ? String(pair.mate1.dropFirst(primer.count)) : pair.mate1)
            // Mate 2 of a read-through pair ends in the primer's reverse
            // complement. It is not left-trimmed at that match, and the
            // second pass trims it where mate 1's primer-trimmed start lies.
            expected.append(pair.name.hasPrefix("short") ? String(pair.mate2.dropLast(primer.count)) : pair.mate2)
        }
        XCTAssertEqual(records.map(\.sequence), expected)
    }

    // MARK: - bbduk, the read-through primer at the 3' end (L5 item 3)

    /// The fixture's single reads plus full-length amplicon reads in both orientations.
    private func singleReadsWithFullLengthReads() -> [(name: String, sequence: String)] {
        amplicons.pairs.map { ($0.name, $0.mate1) }
            + amplicons.pairs.filter { $0.name.hasPrefix("short") }.map { ("\($0.name)_mate2", $0.mate2) }
            + [
                ("full5_forward", amplicons.amplicon5),
                ("full5_reverse", Amplicons.reverseComplement(amplicons.amplicon5)),
            ]
    }

    func testLiteralPrimerIsTrimmedFromTheThreePrimeEndOfASingleReadThatRunsThroughIt() async throws {
        try await requireNativeTool(.bbduk)
        let inputURL = root.appendingPathComponent("single-read-through.fastq")
        let inputs = singleReadsWithFullLengthReads()
        try inputs.map { record($0.name, $0.sequence) }.joined().write(to: inputURL, atomically: true, encoding: .utf8)
        let outputURL = root.appendingPathComponent("single-read-through.trimmed.fastq")
        try await runPrimerRemove(literalArguments(inputURL, outputURL))

        let output = Dictionary(uniqueKeysWithValues: try await reads(outputURL).map { ($0.name, $0.sequence.count) })
        let primer = amplicons.left5.count
        // Forward reads keep their length but the 5' primer.
        XCTAssertEqual(output["long5_0"], 150 - primer)
        XCTAssertEqual(output["long6_0"], 150)
        XCTAssertEqual(output["full5_forward"], amplicons.amplicon5.count - primer)
        // A read that runs through the primer's binding site loses its
        // reverse complement at the 3' end.
        XCTAssertEqual(output["short_0_mate2"], 110 - primer)
        XCTAssertEqual(output["full5_reverse"], amplicons.amplicon5.count - primer)
    }

    private func writeTiledReference() throws -> URL {
        let url = root.appendingPathComponent("tiled.fasta")
        try ">amp5-F\n\(amplicons.left5)\n>amp5-R\n\(amplicons.right5)\n>amp6-F\n\(amplicons.left6)\n>amp6-R\n\(amplicons.right6)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A tiled scheme's reads of one amplicon carry the other amplicon's
    /// primer sites, which the second pass must not trim at.
    func testATiledSchemeTrimsReadThroughPrimersOfPairsAndKeepsEveryOtherBase() async throws {
        try await requireNativeTool(.bbduk)
        let inputURL = root.appendingPathComponent("tiled-interleaved.fastq")
        try writeInterleaved(amplicons.pairs, to: inputURL)
        let outputURL = root.appendingPathComponent("tiled-interleaved.trimmed.fastq")
        try await runPrimerRemove([
            inputURL.path, "--ref", try writeTiledReference().path, "--kmer", "15", "--mink", "11", "--hdist", "1",
            "-o", outputURL.path,
        ])

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        InterleavedFASTQFixture.assertWholePairs(records)
        var lengths: [String: [Int]] = [:]
        for record in records {
            lengths[InterleavedFASTQFixture.fragmentKey(record), default: []].append(record.sequence.count)
        }
        XCTAssertEqual(lengths["long5_0"], [150 - amplicons.left5.count, 150 - amplicons.right5.count])
        XCTAssertEqual(lengths["long6_0"], [150 - amplicons.left6.count, 150 - amplicons.right6.count], "an internal site of amplicon 5 is kept")
        XCTAssertEqual(lengths["short_0"], [60, 60], "both read-through primers go")
        XCTAssertNil(lengths["dimer_0"])
    }

    func testATiledSchemeTrimsBothPrimersOfAMergedRead() async throws {
        try await requireNativeTool(.bbduk)
        let merged = (0..<3).map { ("merged_\($0)", amplicons.shortInsert($0)) }
        let inputURL = root.appendingPathComponent("tiled-mixed.fastq")
        try (merged.map { record($0.0, $0.1) }.joined()
            + amplicons.pairs.map { record("\($0.name) 1:N:0:1", $0.mate1) + record("\($0.name) 2:N:0:1", $0.mate2) }.joined())
            .write(to: inputURL, atomically: true, encoding: .utf8)
        let outputURL = root.appendingPathComponent("tiled-mixed.trimmed.fastq")
        try await runPrimerRemove([
            inputURL.path, "--ref", try writeTiledReference().path, "--kmer", "15", "--mink", "11", "--hdist", "1",
            "-o", outputURL.path,
        ])

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        XCTAssertEqual(
            records.suffix(3).map(\.sequence),
            merged.map { String($0.1.dropFirst(amplicons.left5.count).dropLast(amplicons.right5.count)) },
            "a merged read loses its left primer and its right primer's reverse complement"
        )
    }

    func testTheTwoPassesAreRecordedAsTwoSteps() async throws {
        try await requireNativeTool(.bbduk)
        let inputURL = root.appendingPathComponent("provenance.fastq")
        try writeInterleaved(amplicons.pairs, to: inputURL)
        let outputURL = root.appendingPathComponent("provenance.trimmed.fastq")
        try await runPrimerRemove(literalArguments(inputURL, outputURL))

        // The run's envelope beside the output holds every step. The output's
        // own sidecar keeps only the steps that wrote the output.
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputURL.deletingLastPathComponent()))
        let bbdukSteps = envelope.steps.filter { $0.toolName == NativeTool.bbduk.rawValue }
        guard bbdukSteps.count == 2 else {
            XCTFail("the 5' pass and the 3' pass are two steps, found \(bbdukSteps.map(\.argv))")
            return
        }
        XCTAssertTrue(bbdukSteps[0].argv.contains("ktrim=l"))
        XCTAssertTrue(bbdukSteps[1].argv.contains("tbo=t"), "pairs are trimmed where their mates overlap")
        XCTAssertEqual(bbdukSteps[1].dependsOn, [bbdukSteps[0].id])
        XCTAssertEqual(bbdukSteps[1].outputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, [outputURL.lastPathComponent])
    }

    // MARK: - bbduk, a k-mer longer than a primer

    func testAKmerLongerThanTheShortestPrimerIsRefusedBeforeBBDukRuns() async throws {
        let inputURL = root.appendingPathComponent("kmer.fastq")
        try writeInterleaved(Array(amplicons.pairs.prefix(2)), to: inputURL)
        let outputURL = root.appendingPathComponent("kmer.trimmed.fastq")
        do {
            try await runPrimerRemove([inputURL.path, "--literal", amplicons.left5, "--kmer", "23", "-o", outputURL.path])
            XCTFail("a 23-mer cannot be taken from a 22-base primer")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("22"), error.message)
            XCTAssertFalse(error.message.contains("\n"), error.message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    // MARK: - bbduk, the default k-mer

    // `--kmer` defaulted to 23 while the dialog's k is 15, so a dialog run
    // recorded `--kmer 15` and a run without `--kmer` ran 23. The default is
    // now 15 (L5, ruling on concern 3). FastqPrimerRemovalBundledSchemeTests
    // runs the default on the bundled schemes.

    func testADialogRunAndARunWithoutKmerMinkOrHdistRecordOneCommand() async throws {
        try await requireNativeTool(.bbduk)
        let inputURL = root.appendingPathComponent("defaults.fastq")
        try record("long5", String(amplicons.amplicon5.prefix(150))).write(to: inputURL, atomically: true, encoding: .utf8)
        var commands: [[String]] = []
        for label in ["dialog", "command-line"] {
            let folder = root.appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let outputURL = folder.appendingPathComponent("trimmed.fastq")
            let arguments = label == "dialog"
                ? literalArguments(inputURL, outputURL)
                : [inputURL.path, "--literal", amplicons.left5, "-o", outputURL.path]
            try await runPrimerRemove(arguments)
            let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: folder), label)
            commands.append(envelope.argv.map { $0 == outputURL.path ? "<output>" : $0 })
        }
        XCTAssertEqual(commands.first, commands.last, "the dialog's k, mink and hdist are the command's defaults")
    }

    func testPrimerInsideAFullLengthReadIsNotTrimmedWithEverythingBeforeIt() async throws {
        try await requireNativeTool(.bbduk)
        let primersURL = root.appendingPathComponent("tiled-primers.fasta")
        try ">amp5-F\n\(amplicons.left5)\n>amp5-R\n\(amplicons.right5)\n>amp6-F\n\(amplicons.left6)\n>amp6-R\n\(amplicons.right6)\n"
            .write(to: primersURL, atomically: true, encoding: .utf8)
        // A basecalled native-barcoded ONT read starts with the Y-adapter,
        // the outer flank, the barcode (NB01) and the inner flank.
        let lead = PlatformAdapters.ontYAdapterTop + PlatformAdapters.ontNativeOuterFlank5
            + "AAGAAAGTTGTCGGTGTCTTTGTG" + PlatformAdapters.ontNativeBarcodeFlank5
        XCTAssertEqual(lead.count, 67)
        // Full-length reads of amplicon 5 carry the left primer of amplicon 6
        // at base 331 and the right primer's reverse complement at their end.
        let amplicon = amplicons.amplicon5
        XCTAssertEqual(amplicon.range(of: amplicons.left6).map { amplicon.distance(from: amplicon.startIndex, to: $0.lowerBound) }, 331)
        let inputURL = root.appendingPathComponent("full-length.fastq")
        try (record("illumina_full", amplicon) + record("ont_full", lead + amplicon))
            .write(to: inputURL, atomically: true, encoding: .utf8)
        let outputURL = root.appendingPathComponent("full-length.trimmed.fastq")
        try await runPrimerRemove([inputURL.path, "--ref", primersURL.path, "--kmer", "15", "--mink", "11", "--hdist", "1", "-o", outputURL.path])

        let output = try await reads(outputURL)
        let insert = String(amplicon.dropFirst(amplicons.left5.count).dropLast(amplicons.right5.count))
        XCTAssertEqual(output.map(\.name), ["illumina_full", "ont_full"])
        XCTAssertEqual(
            output.map(\.sequence), [insert, insert],
            "only the left primer of amplicon 5 with the bases before it, and the right primer's reverse complement at the 3' end, go"
        )
    }

    func testLiteralPrimerOnAMixedFileTrimsPairsAsPairsAndMergedReadsAlone() async throws {
        try await requireNativeTool(.bbduk)
        let pairs = amplicons.pairs
        let merged = (0..<3).map { ("merged_\($0)", amplicons.shortInsert($0)) }
        let inputURL = root.appendingPathComponent("mixed.fastq")
        try (merged.map { record($0.0, $0.1) }.joined()
            + pairs.map { record("\($0.name) 1:N:0:1", $0.mate1) + record("\($0.name) 2:N:0:1", $0.mate2) }.joined())
            .write(to: inputURL, atomically: true, encoding: .utf8)
        let outputURL = root.appendingPathComponent("mixed.trimmed.fastq")
        try await runPrimerRemove(literalArguments(inputURL, outputURL))

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        let counts = try FASTQPairInterleaver.countMixed(interleaved: outputURL)
        XCTAssertEqual(counts, FASTQPairInterleaver.MixedCounts(pairs: pairs.count - 2, unpaired: 3), "the pairs stay whole, the merged reads stay single")
        let primer = amplicons.left5
        let pairBlock = Array(records.prefix((pairs.count - 2) * 2))
        InterleavedFASTQFixture.assertWholePairs(pairBlock)
        XCTAssertEqual(
            records.suffix(3).map(\.sequence),
            merged.map { String($0.1.dropFirst(primer.count)) },
            "the merged reads follow the pairs, each trimmed of the primer"
        )
    }

    // MARK: - cutadapt, linked primers

    private func writeLinkedReference() throws -> URL {
        let url = root.appendingPathComponent("primers.fasta")
        try ">amp5-F\n\(amplicons.left5)\n>amp5-R\n\(amplicons.right5)\n>amp6-F\n\(amplicons.left6)\n>amp6-R\n\(amplicons.right6)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The arguments the dialog records for a reference primer FASTA.
    private func linkedArguments(_ input: URL, _ reference: URL, _ output: URL) -> [String] {
        [input.path, "--ref", reference.path, "--engine", "cutadapt-linked", "--minimum-overlap", "12", "--error-rate", "0.12", "-o", output.path]
    }

    func testLinkedPrimersOnInterleavedPairsDropAPairWholeWhenOneMateLacksItsPrimer() async throws {
        try await requireNativeTool(.cutadapt)
        // Three read-through pairs span the whole short insert. Mate 2 of
        // short_1 lost its last 30 bases, its read-through primer with them.
        var pairs = amplicons.pairs.filter { $0.name.hasPrefix("short") }
        pairs[1].mate2 = String(pairs[1].mate2.dropLast(30))
        let inputURL = root.appendingPathComponent("linked-interleaved.fastq")
        try writeInterleaved(pairs, to: inputURL)
        let outputURL = root.appendingPathComponent("linked-interleaved.trimmed.fastq")
        try await runPrimerRemove(linkedArguments(inputURL, try writeLinkedReference(), outputURL))

        let records = try await InterleavedFASTQFixture.readRecords(at: outputURL)
        InterleavedFASTQFixture.assertWholePairs(records)
        XCTAssertEqual(
            records.map { InterleavedFASTQFixture.fragmentKey($0) },
            ["short_0", "short_0", "short_2", "short_2"],
            "the pair whose mate 2 lacks its linked primer is dropped whole, and the others are kept as the per-record run kept them"
        )
    }

    func testLinkedPrimersOnSingleReadsTrimEveryFullLengthReadAsBefore() async throws {
        try await requireNativeTool(.cutadapt)
        let pairs = amplicons.pairs
        let inputURL = root.appendingPathComponent("linked-single.fastq")
        try pairs.map { record($0.name, $0.mate1) }.joined().write(to: inputURL, atomically: true, encoding: .utf8)
        let outputURL = root.appendingPathComponent("linked-single.trimmed.fastq")
        try await runPrimerRemove(linkedArguments(inputURL, try writeLinkedReference(), outputURL))

        // Linked adapters given with -g are both required, so only the reads
        // that span a whole amplicon are kept, each without its primers.
        let output = try await reads(outputURL)
        XCTAssertEqual(output.map(\.name), ["short_0", "short_1", "short_2"])
        XCTAssertEqual(
            output.map(\.sequence),
            (0..<3).map { String(amplicons.shortInsert($0).dropFirst(amplicons.left5.count).dropLast(amplicons.right5.count)) }
        )
    }

    private func requireNativeTool(_ tool: NativeTool, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(tool) else {
            try ToolAvailability.skipOrFail("\(tool.executableName) is not available in this test environment", file: file, line: line)
        }
    }
}
