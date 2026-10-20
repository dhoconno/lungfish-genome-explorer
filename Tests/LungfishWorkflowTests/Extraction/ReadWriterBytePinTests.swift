// ReadWriterBytePinTests.swift - Output bytes of the writers that put read files on disk
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

/// Phase 2.10 lane S31, M1. The bytes each read writer puts on disk, pinned
/// before the writers move onto `DurableReplace` so the move cannot change a
/// read or a digest. These pass at the base and pass again after every step.
///
/// Since 2.13 lane 13.15 (SW5) a member that lacks a final line break gets
/// one before the next member's record in every join, where the base let it
/// run into the next member's first line. Those two pins moved by prediction,
/// and every other pinned byte stayed.
final class ReadWriterBytePinTests: XCTestCase {
    private typealias Fixtures = ReadWriterFixtures
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "read-writer-pins")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Joins

    func testTheResolverJoinsByteForByte() async throws {
        let resolver = ClassifierReadResolver()
        for (index, joinCase) in try Fixtures.joinCases().enumerated() {
            let staged = try Fixtures.stage(joinCase, in: root.appendingPathComponent("join-\(index)", isDirectory: true))
            try await resolver.concatenateFiles(staged.sources, into: staged.destination)
            try Fixtures.check(joinCase, destination: staged.destination)
        }
    }

    func testTheMaterializerJoinsByteForByte() throws {
        let materializer = FASTQCLIMaterializer(runner: .shared)
        for (index, joinCase) in try Fixtures.joinCases().enumerated() {
            let staged = try Fixtures.stage(joinCase, in: root.appendingPathComponent("join-\(index)", isDirectory: true))
            try materializer.concatenateFiles(staged.sources, to: staged.destination)
            try Fixtures.check(joinCase, destination: staged.destination)
        }
    }

    func testBothJoinsReplaceAnExistingDestinationWithExactlyTheNewBytes() async throws {
        let folder = root.appendingPathComponent("replace", isDirectory: true)
        let source = try Fixtures.write(Fixtures.fastq("new"), named: "new.fastq", in: folder)
        let old = Data(repeating: UInt8(ascii: "X"), count: 4096)

        let resolverDestination = try Fixtures.write(old, named: "resolver.fastq", in: folder)
        try await ClassifierReadResolver().concatenateFiles([source], into: resolverDestination)
        let materializerDestination = try Fixtures.write(old, named: "materializer.fastq", in: folder)
        try FASTQCLIMaterializer(runner: .shared).concatenateFiles([source], to: materializerDestination)

        XCTAssertEqual(try Data(contentsOf: resolverDestination), Fixtures.fastq("new"))
        XCTAssertEqual(try Data(contentsOf: materializerDestination), Fixtures.fastq("new"))
    }

    func testBothJoinsWriteAnEmptyFileForNoSources() async throws {
        let folder = root.appendingPathComponent("none", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try await ClassifierReadResolver().concatenateFiles([], into: folder.appendingPathComponent("resolver.fastq"))
        try FASTQCLIMaterializer(runner: .shared).concatenateFiles([], to: folder.appendingPathComponent("materializer.fastq"))

        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("resolver.fastq")), Data())
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("materializer.fastq")), Data())
    }

    func testBothJoinsThrowForASourceThatIsMissing() async throws {
        let folder = root.appendingPathComponent("missing", isDirectory: true)
        let present = try Fixtures.write(Fixtures.fastq("a1"), named: "a.fastq", in: folder)
        let missing = folder.appendingPathComponent("gone.fastq")

        do {
            try await ClassifierReadResolver().concatenateFiles([present, missing], into: folder.appendingPathComponent("r.fastq"))
            XCTFail("the resolver must refuse a missing source")
        } catch {}
        XCTAssertThrowsError(
            try FASTQCLIMaterializer(runner: .shared).concatenateFiles([present, missing], to: folder.appendingPathComponent("m.fastq"))
        )
    }

    /// 2.13 lane 13.15, SW5 under BIO's ruling. A plain member without a final line break gets one before the next
    /// member's first record, so each of the three joins gives a FASTQ whose read count is the sum of its members'.
    func testEveryJoinOfAMemberWithoutAFinalLineBreakHoldsEveryRead() async throws {
        let folder = root.appendingPathComponent("sum", isDirectory: true)
        let members = [
            Fixtures.fastq("a1", finalLineBreak: false), Fixtures.fastq("b1", finalLineBreak: false), Fixtures.fastq("c1"),
        ]
        let sources = try members.enumerated().map { index, data in
            try Fixtures.write(data, named: "m\(index).fastq", in: folder)
        }
        let joined = ["resolver", "materializer", "importer"].map { folder.appendingPathComponent("\($0).fastq") }

        try await ClassifierReadResolver().concatenateFiles(sources, into: joined[0])
        try FASTQCLIMaterializer(runner: .shared).concatenateFiles(sources, to: joined[1])
        try FASTQBatchImporter.concatenateFiles(sources, to: joined[2])

        for url in joined {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(text, "@a1\nACGT\n+\nIIII\n@b1\nACGT\n+\nIIII\n@c1\nACGT\n+\nIIII\n", url.lastPathComponent)
            XCTAssertEqual(text.split(separator: "\n").count, 12, "three reads of four lines")
        }
    }

    // MARK: - FASTQ to FASTA

    private func convert(_ input: Data) async throws -> Data {
        let folder = root.appendingPathComponent("fasta-\(UUID().uuidString)", isDirectory: true)
        let source = try Fixtures.write(input, named: "in.fastq", in: folder)
        let output = folder.appendingPathComponent("out.fasta")
        try await ClassifierReadResolver().convertFASTQToFASTA(input: source, output: output)
        return try Data(contentsOf: output)
    }

    func testFASTQToFASTAKeepsHeaderAndSequenceOfTwoAndThreeRecords() async throws {
        let two = Data("@r1\nACGT\n+\nIIII\n@r2 desc text\nTTGA\n+\nIIII\n".utf8)
        let three = two + Data("@r3/1\nGGCC\n+r3/1\nIIII\n".utf8)

        let twoBytes = try await convert(two)
        let threeBytes = try await convert(three)

        XCTAssertEqual(String(decoding: twoBytes, as: UTF8.self), ">r1\nACGT\n>r2 desc text\nTTGA\n")
        XCTAssertEqual(String(decoding: threeBytes, as: UTF8.self), ">r1\nACGT\n>r2 desc text\nTTGA\n>r3/1\nGGCC\n")
    }

    func testFASTQToFASTAWithAndWithoutAFinalLineBreak() async throws {
        let withBreak = try await convert(Fixtures.fastq("r1", "r2"))
        let withoutBreak = try await convert(Fixtures.fastq("r1", "r2", finalLineBreak: false))
        // The file ends on the sequence line, so the record is cut short.
        let cutAfterSequence = try await convert(Data("@r1\nACGT\n+\nIIII\n@r2\nTTGA".utf8))
        let cutAfterHeader = try await convert(Data("@r1\nACGT\n+\nIIII\n@r2".utf8))

        XCTAssertEqual(String(decoding: withBreak, as: UTF8.self), ">r1\nACGT\n>r2\nACGT\n")
        XCTAssertEqual(withoutBreak, withBreak)
        XCTAssertEqual(String(decoding: cutAfterSequence, as: UTF8.self), ">r1\nACGT\n>r2\nTTGA\n")
        XCTAssertEqual(String(decoding: cutAfterHeader, as: UTF8.self), ">r1\nACGT\n>r2\n")
    }

    func testFASTQToFASTAKeepsAHeaderWithoutAnAtSignAndCarriageReturns() async throws {
        let bytes = try await convert(Data("r1\nACGT\n+\nIIII\n@r2\r\nTTGA\r\n+\r\nIIII\r\n".utf8))

        XCTAssertEqual(bytes, Data("r1\nACGT\n>r2\r\nTTGA\r\n".utf8))
    }

    func testFASTQToFASTAOfAnEmptyFileIsAnEmptyFile() async throws {
        let bytes = try await convert(Data())

        XCTAssertEqual(bytes, Data())
    }

    func testFASTQToFASTAKeepsALineThatCrossesTheReaderChunk() async throws {
        let sequence = String(repeating: "ACGT", count: (1 << 20) / 2 + 5)
        let input = Data("@big\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n@small\nTT\n+\nII\n".utf8)

        let bytes = try await convert(input)

        XCTAssertEqual(bytes, Data(">big\n\(sequence)\n>small\nTT\n".utf8))
    }

    func testFASTQToFASTAReplacesAnExistingOutputWithExactlyTheNewBytes() async throws {
        let folder = root.appendingPathComponent("fasta-replace", isDirectory: true)
        let source = try Fixtures.write(Fixtures.fastq("r1"), named: "in.fastq", in: folder)
        let output = try Fixtures.write(Data(repeating: UInt8(ascii: "X"), count: 4096), named: "out.fasta", in: folder)

        try await ClassifierReadResolver().convertFASTQToFASTA(input: source, output: output)

        XCTAssertEqual(try Data(contentsOf: output), Data(">r1\nACGT\n".utf8))
    }

    // MARK: - Interleaving mates

    private func mates(_ names: [String], base: Character, finalLineBreak: Bool = true) -> Data {
        Fixtures.mates(names, base: base, finalLineBreak: finalLineBreak)
    }

    private func interleave(_ r1: Data, _ r2: Data, gzipped: Bool = false) throws -> String {
        let folder = root.appendingPathComponent("mates-\(UUID().uuidString)", isDirectory: true)
        let suffix = gzipped ? ".fastq.gz" : ".fastq"
        let r1URL = try Fixtures.write(gzipped ? try Fixtures.gzip(r1) : r1, named: "R1" + suffix, in: folder)
        let r2URL = try Fixtures.write(gzipped ? try Fixtures.gzip(r2) : r2, named: "R2" + suffix, in: folder)
        let output = folder.appendingPathComponent("interleaved.fastq")
        try FASTQCLIMaterializer(runner: .shared).interleaveMates(r1URL: r1URL, r2URL: r2URL, outputURL: output)
        return String(decoding: try Data(contentsOf: output), as: UTF8.self)
    }

    func testInterleavingTwoAndThreePairsPutsEachMateAfterItsFirstMate() throws {
        let two = try interleave(mates(["p1/1", "p2/1"], base: "A"), mates(["p1/2", "p2/2"], base: "C"))
        let three = try interleave(
            mates(["p1/1", "p2/1", "p3/1"], base: "A"),
            mates(["p1/2", "p2/2", "p3/2"], base: "C")
        )

        let pair = { (name: String) in "@\(name)/1\nAAAA\n+\nIIII\n@\(name)/2\nCCCC\n+\nIIII\n" }
        XCTAssertEqual(two, pair("p1") + pair("p2"))
        XCTAssertEqual(three, pair("p1") + pair("p2") + pair("p3"))
    }

    func testInterleavingGzipMatesWritesPlainFASTQ() throws {
        let joined = try interleave(
            mates(["p1/1", "p2/1"], base: "A"),
            mates(["p1/2", "p2/2"], base: "C"),
            gzipped: true
        )

        XCTAssertEqual(
            joined,
            "@p1/1\nAAAA\n+\nIIII\n@p1/2\nCCCC\n+\nIIII\n@p2/1\nAAAA\n+\nIIII\n@p2/2\nCCCC\n+\nIIII\n"
        )
    }

    func testInterleavingMatesWithoutAFinalLineBreakEndsTheOutputWithOne() throws {
        let joined = try interleave(
            mates(["p1/1", "p2/1"], base: "A", finalLineBreak: false),
            mates(["p1/2", "p2/2"], base: "C", finalLineBreak: false)
        )
        let gzipped = try interleave(
            mates(["p1/1"], base: "A", finalLineBreak: false),
            mates(["p1/2"], base: "C", finalLineBreak: false),
            gzipped: true
        )

        XCTAssertEqual(
            joined,
            "@p1/1\nAAAA\n+\nIIII\n@p1/2\nCCCC\n+\nIIII\n@p2/1\nAAAA\n+\nIIII\n@p2/2\nCCCC\n+\nIIII\n"
        )
        XCTAssertEqual(gzipped, "@p1/1\nAAAA\n+\nIIII\n@p1/2\nCCCC\n+\nIIII\n")
    }

    // MARK: - FASTA from root files

    private func fasta(_ text: String, named name: String) throws -> URL {
        try Fixtures.write(Data(text.utf8), named: name, in: root.appendingPathComponent("roots", isDirectory: true))
    }

    private func outputFASTA() -> URL {
        root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("out.fasta")
    }

    func testTrimmedFASTAReadsFromTwoRootFilesKeepTheTrimmedWindows() async throws {
        let roots = [
            try fasta(">r1 first read\nAACCGGTT\n>r2\nTTGGCCAA\n", named: "a.fasta"),
            try fasta(">r3\nACGTACGT", named: "b.fasta"),
        ]
        let output = outputFASTA()
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        try await FASTQCLIMaterializer(runner: .shared).extractTrimmedFASTAReads(
            fromRootFASTAs: roots,
            positions: ["r1": (start: 1, end: 5), "r3": (start: 2, end: 6), "r9": (start: 0, end: 4)],
            outputFASTA: output
        )

        XCTAssertEqual(String(decoding: try Data(contentsOf: output), as: UTF8.self), ">r1\nACCG\n>r3\nGTAC\n")
    }

    func testTrimmedFASTAReadsWithPositionalKeysCountOccurrencesAcrossThreeRootFiles() async throws {
        let roots = [
            try fasta(">r1\nAAAACCCC\n", named: "a.fasta"),
            try fasta(">r1\nGGGGTTTT\n", named: "b.fasta"),
            try fasta(">r1\nACGTACGT", named: "c.fasta"),
        ]
        let output = outputFASTA()
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        try await FASTQCLIMaterializer(runner: .shared).extractTrimmedFASTAReads(
            fromRootFASTAs: roots,
            positions: ["r1#0": (start: 0, end: 4), "r1#2": (start: 4, end: 20)],
            outputFASTA: output
        )

        XCTAssertEqual(String(decoding: try Data(contentsOf: output), as: UTF8.self), ">r1\nAAAA\n>r1\nACGT\n")
    }

    func testOrientedFASTAReadsReverseComplementOnlyTheNamedReads() async throws {
        let roots = [
            try fasta(">r1\nAACCGGTT\n>r2\nAAAACCCG\n", named: "a.fasta"),
            try fasta(">r3\nACGTAC", named: "b.fasta"),
            try fasta(">r4\nGGGG\n>r2\nAAAACCCG\n", named: "c.fasta"),
        ]
        let output = outputFASTA()
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        try await FASTQCLIMaterializer(runner: .shared).materializeOrientedFASTAReads(
            fromRootFASTAs: roots,
            allReadIDs: ["r1", "r2", "r3"],
            rcReadIDs: ["r2"],
            outputFASTA: output
        )

        XCTAssertEqual(
            String(decoding: try Data(contentsOf: output), as: UTF8.self),
            ">r1\nAACCGGTT\n>r2\nCGGGTTTT\n>r3\nACGTAC\n>r2\nCGGGTTTT\n"
        )
    }

    func testFASTAFromRootFilesWithNothingToKeepWritesAnEmptyFile() async throws {
        let roots = [try fasta(">r1\nAACC\n", named: "a.fasta")]
        let output = outputFASTA()
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        try await FASTQCLIMaterializer(runner: .shared).materializeOrientedFASTAReads(
            fromRootFASTAs: roots,
            allReadIDs: [],
            rcReadIDs: [],
            outputFASTA: output
        )

        XCTAssertEqual(try Data(contentsOf: output), Data())
    }
}
