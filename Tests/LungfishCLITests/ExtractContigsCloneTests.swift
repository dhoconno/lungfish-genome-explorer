// ExtractContigsCloneTests.swift - extract contigs reads the assembly folder it is given
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane ASSEMBLY-PATH (BIO-ASSEMBLY-RECORDED-PATH). The command reads `contigsPath` beside the sidecar and never the
// recorded `outputDirectory`, so a clone whose JSON names another folder returns its own bytes. This guards that science.

import XCTest
import Foundation
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

extension ExtractContigsCommandTests {
    func testExtractContigsOfACloneReturnsItsOwnBytes() async throws {
        let fixture = try CLIAssemblyCloneFixture()
        defer { fixture.remove() }
        let outputURL = fixture.root.appendingPathComponent("k141_0.fa")

        let command = try ExtractContigsSubcommand.parse([
            "--assembly", fixture.clone.path,
            "--contig", "k141_0",
            "--output", outputURL.path,
            "--line-width", "200",
        ])
        try await command.run()

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), CLIAssemblyCloneFixture.cloneRecord)
        XCTAssertNotEqual(CLIAssemblyCloneFixture.cloneRecord, CLIAssemblyCloneFixture.otherRecord, "the two folders differ")
    }
}

/// `Other` and `Clone` result folders, with `Clone`'s JSON naming `Other` and `k141_0` different in 20 bases.
struct CLIAssemblyCloneFixture {
    static let cloneRecord = ">k141_0 len=64\n" + String(repeating: "ACGTTGCA", count: 8) + "\n"
    static let otherRecord: String = {
        let bases = String(repeating: "ACGTTGCA", count: 8)
        return ">k141_0 len=64\n" + "CATGGTACCATGGTACCATG" + String(bases.dropFirst(20)) + "\n"
    }()

    let root: URL
    let other: URL
    let clone: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("extract-clone-\(UUID().uuidString)", isDirectory: true)
        other = root.appendingPathComponent("Other", isDirectory: true)
        clone = root.appendingPathComponent("Clone", isDirectory: true)
        try Self.write(Self.otherRecord, into: other, recordedAs: other)
        try Self.write(Self.cloneRecord, into: clone, recordedAs: other)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func write(_ firstRecord: String, into folder: URL, recordedAs recorded: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let contigsURL = folder.appendingPathComponent("contigs.fasta")
        try (firstRecord + ">k141_1 len=24\n" + String(repeating: "GGATCC", count: 4) + "\n")
            .write(to: contigsURL, atomically: true, encoding: .utf8)
        try FASTAIndexBuilder.buildAndWrite(for: contigsURL)
        let result = AssemblyResult(
            tool: .megahit, readType: .illuminaShortReads, contigsPath: contigsURL, graphPath: nil, logPath: nil,
            assemblerVersion: "1.2.9", commandLine: "megahit -o \(recorded.path)", outputDirectory: recorded,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL), wallTimeSeconds: 1
        )
        try result.save(to: folder)
    }
}
