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
/// A member that lacks a final line break runs into the next member's first
/// line in the resolver's and the materializer's joins, since both copy
/// bytes. The pins record that as it is today, and the report names it.
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

    private struct JoinCase {
        let name: String
        let members: [Data]
        let expected: Data
        /// The text the joined bytes decode to when the members are gzip.
        var decoded: String?
    }

    private func joinCases() throws -> [JoinCase] {
        let plainTwo = Data("@a1\nACGT\n+\nIIII\n@a2\nACGT\n+\nIIII\n@b1\nACGT\n+\nIIII\n".utf8)
        let plainThree = Data("@a1\nACGT\n+\nIIII\n@b1\nACGT\n+\nIIII\n@c1\nACGT\n+\nIIII\n".utf8)
        let gzipped = [
            try Fixtures.gzip(Fixtures.fastq("g1", "g2")),
            try Fixtures.gzip(Fixtures.fastq("g3")),
            try Fixtures.gzip(Fixtures.fastq("g4")),
        ]
        // The resolver reads in 1 MiB chunks and the materializer in 4 MiB chunks.
        let large = [
            Data(repeating: UInt8(ascii: "A"), count: (4 << 20) + 3),
            Data(repeating: UInt8(ascii: "C"), count: 1 << 20),
            Data(repeating: UInt8(ascii: "G"), count: (1 << 20) - 1),
        ]
        return [
            JoinCase(
                name: "two plain members, final line breaks",
                members: [Fixtures.fastq("a1", "a2"), Fixtures.fastq("b1")],
                expected: plainTwo
            ),
            JoinCase(
                name: "three plain members, final line breaks",
                members: [Fixtures.fastq("a1"), Fixtures.fastq("b1"), Fixtures.fastq("c1")],
                expected: plainThree
            ),
            JoinCase(
                name: "two plain members, the first lacks its final line break",
                members: [Fixtures.fastq("a1", finalLineBreak: false), Fixtures.fastq("b1")],
                expected: Data("@a1\nACGT\n+\nIIII@b1\nACGT\n+\nIIII\n".utf8)
            ),
            JoinCase(
                name: "three plain members, the last lacks its final line break",
                members: [Fixtures.fastq("a1"), Fixtures.fastq("b1"), Fixtures.fastq("c1", finalLineBreak: false)],
                expected: plainThree.dropLast()
            ),
            JoinCase(
                name: "three plain members, the middle one lacks its final line break",
                members: [Fixtures.fastq("a1"), Fixtures.fastq("b1", finalLineBreak: false), Fixtures.fastq("c1")],
                expected: Data("@a1\nACGT\n+\nIIII\n@b1\nACGT\n+\nIIII@c1\nACGT\n+\nIIII\n".utf8)
            ),
            JoinCase(
                name: "an empty member adds nothing",
                members: [Fixtures.fastq("a1"), Data(), Fixtures.fastq("c1")],
                expected: Fixtures.fastq("a1") + Fixtures.fastq("c1")
            ),
            JoinCase(
                name: "two gzip members",
                members: Array(gzipped[0..<2]),
                expected: gzipped[0] + gzipped[1],
                decoded: "@g1\nACGT\n+\nIIII\n@g2\nACGT\n+\nIIII\n@g3\nACGT\n+\nIIII\n"
            ),
            JoinCase(
                name: "three gzip members",
                members: gzipped,
                expected: gzipped[0] + gzipped[1] + gzipped[2],
                decoded: "@g1\nACGT\n+\nIIII\n@g2\nACGT\n+\nIIII\n@g3\nACGT\n+\nIIII\n@g4\nACGT\n+\nIIII\n"
            ),
            JoinCase(
                name: "members that end on and cross the chunk sizes",
                members: large,
                expected: large[0] + large[1] + large[2]
            ),
        ]
    }

    private func stage(_ joinCase: JoinCase, index: Int) throws -> (sources: [URL], destination: URL, folder: URL) {
        let folder = root.appendingPathComponent("join-\(index)", isDirectory: true)
        let gzipped = joinCase.decoded != nil
        let sources = try joinCase.members.enumerated().map { memberIndex, data in
            try Fixtures.write(data, named: "m\(memberIndex).fastq" + (gzipped ? ".gz" : ""), in: folder)
        }
        return (sources, folder.appendingPathComponent("joined.fastq" + (gzipped ? ".gz" : "")), folder)
    }

    private func checkJoin(
        _ joinCase: JoinCase,
        destination: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try Data(contentsOf: destination), joinCase.expected, joinCase.name, file: file, line: line)
        if let decoded = joinCase.decoded {
            XCTAssertEqual(try Fixtures.gunzip(destination), decoded, joinCase.name, file: file, line: line)
        }
    }

    func testTheResolverJoinsByteForByte() async throws {
        let resolver = ClassifierReadResolver()
        for (index, joinCase) in try joinCases().enumerated() {
            let staged = try stage(joinCase, index: index)
            try await resolver.concatenateFiles(staged.sources, into: staged.destination)
            try checkJoin(joinCase, destination: staged.destination)
        }
    }

    func testTheMaterializerJoinsByteForByte() throws {
        let materializer = FASTQCLIMaterializer(runner: .shared)
        for (index, joinCase) in try joinCases().enumerated() {
            let staged = try stage(joinCase, index: index)
            try materializer.concatenateFiles(staged.sources, to: staged.destination)
            try checkJoin(joinCase, destination: staged.destination)
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

    /// One record per name, with `base` as its sequence and quality II.
    private func mates(_ names: [String], base: Character, finalLineBreak: Bool = true) -> Data {
        var text = names.map { "@\($0)\n\(base)\(base)\(base)\(base)\n+\nIIII\n" }.joined()
        if !finalLineBreak { text.removeLast() }
        return Data(text.utf8)
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
