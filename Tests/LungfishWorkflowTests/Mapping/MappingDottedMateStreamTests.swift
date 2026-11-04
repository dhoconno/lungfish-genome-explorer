// MappingDottedMateStreamTests.swift - Who gets the shared-name copy of a stream of dotted mates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Review DOTTED should-fix 3. `MappingDottedMateStream.executionURLs` writes its copy only for one input, a strict or
/// mixed layout, a mapper that pairs one stream by name (minimap2's short-read preset and bwa-mem2) and a first read
/// named in the dotted form. Every other run keeps its input and creates no folder.
final class MappingDottedMateStreamTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "dotted-stream")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func write(_ names: [String], to file: String) throws -> URL {
        let url = root.appendingPathComponent(file)
        try names.map { "@\($0)\nACGTACGT\n+\nIIIIIIII\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func request(tool: MappingTool, inputs: [URL]) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: inputs,
            referenceFASTAURL: root.appendingPathComponent("reference.fa"),
            outputDirectory: root.appendingPathComponent("out", isDirectory: true),
            sampleName: "sample",
            threads: 1
        )
    }

    /// A fresh `.lungfish-map-inputs` folder for each case, which must exist after a case only when it wrote the copy.
    private func freshDirectory(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true).appendingPathComponent(".lungfish-map-inputs", isDirectory: true)
    }

    private func headers(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .enumerated()
            .filter { $0.offset % 4 == 0 }
            .map { String($0.element) }
    }

    func testTheCopyIsWrittenOnlyForANamePairingMapperOnOneFileOfDottedPairs() throws {
        let dotted = try write((1...3).flatMap { ["SRR1.\($0).1", "SRR1.\($0).2"] }, to: "dotted.fastq")
        let plain = try write((1...3).flatMap { ["read\($0)/1", "read\($0)/2"] }, to: "plain.fastq")
        let other = try write(["SRR2.1.1", "SRR2.1.2"], to: "other.fastq")
        let mixed = try write(["SRR3.1.1", "SRR3.1.2", "SRR3.2.1"], to: "mixed.fastq")

        // (a) minimap2's short-read preset, one file of dotted pairs, strict layout: the copy under shared names.
        let directoryA = freshDirectory("a")
        let copied = try MappingDottedMateStream.executionURLs(
            [dotted], request: request(tool: .minimap2, inputs: [dotted]),
            layout: .strictlyInterleaved, into: directoryA, progress: nil
        )
        XCTAssertEqual(copied, [directoryA.appendingPathComponent("shared-mate-names.fastq")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(copied.first).path))
        XCTAssertEqual(
            try headers(of: try XCTUnwrap(copied.first)),
            ["@SRR1.1/1", "@SRR1.1/2", "@SRR1.2/1", "@SRR1.2/2", "@SRR1.3/1", "@SRR1.3/2"]
        )

        // (b) bowtie2 takes -1, -2 and -U, so the same file and layout keep their input and no folder is made.
        let directoryB = freshDirectory("b")
        let bowtie2 = try MappingDottedMateStream.executionURLs(
            [dotted], request: request(tool: .bowtie2, inputs: [dotted]),
            layout: .strictlyInterleaved, into: directoryB, progress: nil
        )
        XCTAssertEqual(bowtie2, [dotted])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryB.path))

        // (c) minimap2 with mates named read1/1 and read1/2 has nothing to rename.
        let directoryC = freshDirectory("c")
        let slash = try MappingDottedMateStream.executionURLs(
            [plain], request: request(tool: .minimap2, inputs: [plain]),
            layout: .strictlyInterleaved, into: directoryC, progress: nil
        )
        XCTAssertEqual(slash, [plain])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryC.path))

        // (d) a single-end layout, and two inputs, keep their input.
        let directoryD = freshDirectory("d")
        let single = try MappingDottedMateStream.executionURLs(
            [dotted], request: request(tool: .minimap2, inputs: [dotted]),
            layout: .singleEnd, into: directoryD, progress: nil
        )
        XCTAssertEqual(single, [dotted])
        let twoInputs = try MappingDottedMateStream.executionURLs(
            [dotted, other], request: request(tool: .minimap2, inputs: [dotted, other]),
            layout: .strictlyInterleaved, into: directoryD, progress: nil
        )
        XCTAssertEqual(twoInputs, [dotted, other])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryD.path))

        // (e) a mixed layout is read the same way, and bwa-mem2 is the other mapper that pairs one stream by name.
        let directoryE = freshDirectory("e")
        let mixedCopy = try MappingDottedMateStream.executionURLs(
            [mixed], request: request(tool: .bwaMem2, inputs: [mixed]),
            layout: .mixedMergedAndPairs, into: directoryE, progress: nil
        )
        XCTAssertEqual(mixedCopy, [directoryE.appendingPathComponent("shared-mate-names.fastq")])
        XCTAssertEqual(try headers(of: try XCTUnwrap(mixedCopy.first)), ["@SRR3.1/1", "@SRR3.1/2", "@SRR3.2.1"])
    }
}
